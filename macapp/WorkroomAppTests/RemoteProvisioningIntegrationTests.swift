import CryptoKit
import XCTest

@testable import Workroom

/// The derivation sequence (#252) on the ssh fixture's containers: a base built and cloned, and
/// workrooms derived, enrolled and checked out from it, with every failure undoing what it made.
/// The base clones the fixture image's `/srv/origin.git` by path, since the fixture has no
/// GitHub; the token's handling is pinned by `RemoteProvisioningTests`. The Mac's broker calls go
/// to `BrokerStub`, and each agent's enrolment to a `StubBroker` on this Mac through the agent's
/// own loopback, as a Debug build's does. Skipped unless run through the fixture script:
///
///   vcs/scripts/ssh-fixture/run.sh <linux wr-agent> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/RemoteProvisioningIntegrationTests
final class RemoteProvisioningIntegrationTests: XCTestCase {
  private var directory: URL!
  private var label: String!
  private var runtime: URL!
  private var broker: StubBroker!
  private var cleanups: [() async -> Void] = []

  private static let token = "ghs_fixture_clone_token_0123456789"
  private static let path = "/home/workroom/project"

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-derive-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    label = "workroom.test=\(UUID().uuidString.lowercased())"
    broker = try StubBroker()
  }

  override func tearDown() async throws {
    for cleanup in cleanups.reversed() { await cleanup() }
    cleanups.removeAll()
    broker?.stop()
    if let runtime, let label {
      for container in (try? leftovers("ps", label: label)) ?? [] {
        _ = try? docker(runtime, ["rm", "--force", "--volumes", container])
      }
      for image in (try? leftovers("images", label: label)) ?? [] {
        _ = try? docker(runtime, ["rmi", "--force", image])
      }
    }
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private struct Fixture {
    let provisioning: ContainerHostDriver.Provisioning
    let agent: URL
  }

  private func fixture(runtime override: URL? = nil) throws -> Fixture {
    let environment = ProcessInfo.processInfo.environment
    func need(_ name: String) throws -> String {
      guard let value = environment[name], !value.isEmpty else {
        throw XCTSkip("\(name) is unset; run these through vcs/scripts/ssh-fixture/run.sh")
      }
      return value
    }
    runtime = URL(fileURLWithPath: try need("WR_SSH_FIXTURE_RUNTIME_PATH"))
    return Fixture(
      provisioning: ContainerHostDriver.Provisioning(
        runtime: override ?? runtime, image: try need("WR_SSH_FIXTURE_IMAGE"),
        user: try need("WR_SSH_FIXTURE_USER"), identityFile: try need("WR_SSH_FIXTURE_IDENTITY"),
        publicKey: try need("WR_SSH_FIXTURE_PUBLIC_KEY"),
        agentSocket: try need("WR_SSH_FIXTURE_SOCKET"),
        labels: [try need("WR_SSH_FIXTURE_LABEL"), label]),
      agent: URL(fileURLWithPath: try need("WR_SSH_FIXTURE_AGENT")))
  }

  /// Revoked clone tokens, in order.
  private final class Revoked: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    func add(_ token: String) { lock.withLock { tokens.append(token) } }
    var all: [String] { lock.withLock { tokens } }
  }

  /// The sequence's environment over `driver`. The agent's broker is a reverse forward to
  /// `broker` (or `brokerURL`, to make the agent's enrolment fail), over a connection of its own
  /// to the host, as the app's registry holds one.
  @MainActor
  private func environment(
    _ fixture: Fixture, driver: ContainerHostDriver, revoked: Revoked,
    connect: (@Sendable (HostID) async throws -> AgentVCSConnection)? = nil,
    brokerURL: URL? = nil
  ) -> RemoteProvisioning.Environment {
    let broker = self.broker!
    let generation = UUID()
    let registry = BrokerReverseForwards(
      transport: .init(
        forwarding: { host in
          let connection = try await AgentVCSConnection.connect(
            host: host, stream: try await driver.openStream(to: host))
          return (.init(host: host, generation: generation), try connection.forwarding())
        },
        updates: { host in
          AsyncStream {
            $0.yield(.init(lease: .init(host: host, generation: generation), status: .connected))
          }
        }),
      target: { broker.port })
    let agent = fixture.agent
    return RemoteProvisioning.Environment(
      driver: driver, agentSocket: fixture.provisioning.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey()),
        session: BrokerStub.session),
      agentBroker: .init(
        url: { _, workroom, host in
          if let brokerURL { return brokerURL }
          return try await registry.open(workroom: workroom, host: host)
        },
        release: { workroom in await registry.close(workroom: workroom) }),
      connect: connect ?? { host in
        try await AgentBootstrap.connect(
          host: host, driver: driver, socket: fixture.provisioning.agentSocket,
          agent: { $0 == "aarch64" || $0 == "x86_64" ? agent : nil }, handOff: false,
          resources: nil)
      },
      revoke: { revoked.add($0.token) })
  }

  private static let cloneToken = BrokerStub.Answer(
    body: #"{"token":"\#(token)","expires_at":"2026-10-01T18:00:00Z"}"#)
  private static let grant = BrokerStub.Answer(
    status: 201,
    body: #"{"grant_id":"g1","enrolment_code":"one-time","repository_id":1,"expires_at":"x"}"#)
  private static let cancelled = BrokerStub.Answer(body: #"{"grant_id":"g1","state":"cancelled"}"#)

  @discardableResult
  private func docker(_ runtime: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = runtime
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `-a` for both: a commit is untagged, and `images` lists an untagged image only with it.
  private func leftovers(_ kind: String, label: String) throws -> [String] {
    try docker(runtime, [kind, "-a", "-q", "--filter", "label=\(label)"])
      .split(separator: "\n").map(String.init)
  }

  /// A shell command on the host and its exit status: through the driver's ssh, never the agent.
  private func onHost(_ driver: ContainerHostDriver, _ host: HostID, _ command: String)
    async throws -> (status: Int32, output: String)
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 30)
    return (status, output.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func build(_ environment: RemoteProvisioning.Environment) async throws
    -> RemoteProvisioning.Base
  {
    BrokerStub.reset([Self.cloneToken])
    return try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "/srv/origin.git", path: Self.path, in: environment,
      record: { _ in })
  }

  private var grantsCancelled: Int {
    BrokerStub.requests.filter {
      $0.request.httpMethod == "DELETE" && $0.request.url?.path == "/broker/grants/g1"
    }.count
  }

  // MARK: The base

  @MainActor
  func testABaseIsClonedAndRecordedAndHoldsNoEnrolmentAndNoToken() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let revoked = Revoked()
    let recorded = Revoked()
    BrokerStub.reset([Self.cloneToken])

    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "/srv/origin.git", path: Self.path,
      in: environment(fixture, driver: driver, revoked: revoked),
      record: { recorded.add(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) })
    cleanups.append { try? await driver.destroy(.remote(base.host)) }

    let host = HostID.remote(base.host)
    let readme = try await onHost(driver, host, "cat \(Self.path)/README")
    XCTAssertEqual(readme.output, "origin")
    let remote = try await onHost(driver, host, "git -C \(Self.path) remote get-url origin")
    XCTAssertEqual(
      remote.output, "/srv/origin.git", "the remote URL carries something besides the repository")
    XCTAssertEqual(revoked.all, [Self.token], "the clone token outlived the clone")
    XCTAssertEqual(recorded.all.count, 1)
    let seen = try XCTUnwrap(BrokerStub.requests.first)
    XCTAssertEqual(seen.request.url?.path, "/broker/base-clone-tokens")
    XCTAssertEqual(seen.json["repository"] as? String, "o/r")
    // The base never enrols, and the token is nowhere on its disk.
    let enrolment = try await onHost(driver, host, "test -e /run/workroom/broker.json")
    XCTAssertNotEqual(enrolment.status, 0, "the base holds an enrolment")
    let helper = try await onHost(driver, host, "git config --global --get-regexp '^credential'")
    XCTAssertNotEqual(helper.status, 0, "the base has a credential helper")
    XCTAssertTrue(broker.requests.isEmpty, "the base reached the agents' broker")
    // Every file the ssh user can have written (git and the agent run as that user), for the
    // token as it is and as git's header carries it. A file holding the token is then written on
    // purpose, so the search is shown able to find one.
    let encoded = Data("x-access-token:\(Self.token)".utf8).base64EncodedString()
    let search =
      "find /home /run /tmp /srv /var /etc -xdev -type f -user workroom "
      + "-exec grep -lF -e \(Self.token) -e \(encoded) {} + 2>/dev/null; echo end"
    let found = try await onHost(driver, host, search).output
    XCTAssertEqual(found, "end", "the clone token is on the base's disk")
    _ = try await onHost(driver, host, "echo \(Self.token) > /tmp/probe")
    let control = try await onHost(driver, host, search).output
    XCTAssertEqual(control, "/tmp/probe\nend", "the search cannot find the token")
  }

  @MainActor
  func testABaseWhoseCloneFailsIsRemovedAndItsTokenRevoked() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let revoked = Revoked()
    BrokerStub.reset([Self.cloneToken])

    do {
      _ = try await RemoteProvisioning.buildBase(
        repository: "o/r", cloneURL: "/srv/no-such.git", path: Self.path,
        in: environment(fixture, driver: driver, revoked: revoked), record: { _ in })
      XCTFail("a clone of nothing succeeded")
    } catch RemoteProvisioning.Failure.git(let command, _) {
      XCTAssertEqual(command, "clone")
    }

    XCTAssertEqual(revoked.all, [Self.token])
    XCTAssertEqual(try leftovers("ps", label: label), [], "a failed base was left running")
  }

  @MainActor
  func testABaseThatCannotBeRecordedIsRemoved() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    BrokerStub.reset([Self.cloneToken])

    do {
      _ = try await RemoteProvisioning.buildBase(
        repository: "o/r", cloneURL: "/srv/origin.git", path: Self.path,
        in: environment(fixture, driver: driver, revoked: Revoked()),
        record: { _ in throw WorkroomCLIError.timedOut })
      XCTFail("a base that was never recorded was kept")
    } catch WorkroomCLIError.timedOut {}

    XCTAssertEqual(try leftovers("ps", label: label), [])
  }

  // MARK: Workrooms

  @MainActor
  func testWorkroomsDerivedFromABaseServeOnTheirOwnBranchWithTheirOwnEnrolment() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }

    var keys: [String] = []
    for branch in ["wr-one", "wr-two"] {
      BrokerStub.reset([Self.grant])
      let workroom = UUID()
      let instance = try await RemoteProvisioning.derive(
        from: base, workroom: workroom, branch: branch, in: environment)
      cleanups.append { try? await driver.destroy(instance.host) }

      XCTAssertEqual(instance.grantID, "g1")
      // It serves: a request over its own connection, answered by its own agent.
      let head = try await RemoteProvisioning.git(
        ["rev-parse", "--abbrev-ref", "HEAD"], in: instance.path, on: instance.connection)
      XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), branch)
      let state = try await onHost(driver, instance.host, "cat /run/workroom/broker.json").output
      let enrolment = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
      XCTAssertEqual(enrolment["enrolled"] as? Bool, true)
      XCTAssertEqual(enrolment["workroom_id"] as? String, workroom.uuidString.lowercased())
      keys.append(try XCTUnwrap(enrolment["key"] as? String))

      BrokerStub.reset([Self.cancelled])
      try await RemoteProvisioning.destroy(instance, workroom: workroom, in: environment)
      XCTAssertEqual(grantsCancelled, 1, "destroying a workroom left its grant live")
    }
    XCTAssertNotEqual(keys[0], keys[1], "two workrooms share an enrolment key")
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "only the base should be left")
  }

  /// A failure at each step after the derive starts leaves no instance and no live grant behind.
  @MainActor
  func testAWorkroomThatFailsAtEachStepLeavesNoInstanceAndNoGrant() async throws {
    // The runtime fails `commit` only when told to, so the base is built with it as it is.
    let script = directory.appendingPathComponent("runtime")
    let failing = directory.appendingPathComponent("failing")
    let fixture = try fixture(runtime: script)
    try """
    #!/bin/sh
    if [ -f \(PosixShell.quoted(failing.path)) ] && [ "$1" = commit ]; then
      echo "injected failure" >&2; exit 1
    fi
    exec \(PosixShell.quoted(runtime.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let base = try await build(environment(fixture, driver: driver, revoked: Revoked()))
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    let containers = try leftovers("ps", label: label)

    struct Injected: Error {}
    // The step, the environment that fails it, the branch, and whether a grant was made by then.
    let steps: [(String, RemoteProvisioning.Environment, String, Bool)] = [
      ("derive", environment(fixture, driver: driver, revoked: Revoked()), "wr-a", false),
      (
        "connect",
        environment(
          fixture, driver: driver, revoked: Revoked(), connect: { _ in throw Injected() }),
        "wr-b", false
      ),
      (
        "enrol",
        // Nothing listens there, so the agent's enrolment fails after the grant is made.
        environment(
          fixture, driver: driver, revoked: Revoked(), brokerURL: URL(string: "http://127.0.0.1:9")),
        "wr-c", true
      ),
      // git refuses the name only once the instance is enrolled.
      ("checkout", environment(fixture, driver: driver, revoked: Revoked()), "bad..name", true),
    ]
    for (step, environment, branch, granted) in steps {
      if step == "derive" {
        try Data().write(to: failing)
      } else {
        try? FileManager.default.removeItem(at: failing)
      }
      BrokerStub.reset([Self.grant, Self.cancelled])

      do {
        _ = try await RemoteProvisioning.derive(
          from: base, workroom: UUID(), branch: branch, in: environment)
        XCTFail("a workroom that failed at \(step) was made")
      } catch {}

      XCTAssertEqual(
        try leftovers("ps", label: label), containers, "a failure at \(step) left an instance")
      XCTAssertEqual(
        try leftovers("images", label: label), [], "a failure at \(step) left an image")
      XCTAssertEqual(
        grantsCancelled, granted ? 1 : 0, "a failure at \(step) left its grant live")
    }
  }
}
