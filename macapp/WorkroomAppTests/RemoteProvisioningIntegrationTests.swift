import CryptoKit
import Defaults
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

  /// The base clone token the fixture's GitHub accepts (run.sh reads it out of the image).
  private static var token: String {
    ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_CLONE_TOKEN"] ?? ""
  }
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
    // Read where they are used (`token`, the disconnected test's broker); needed here so an
    // older run.sh skips these tests rather than failing them.
    _ = try need("WR_SSH_FIXTURE_CLONE_TOKEN")
    _ = try need("WR_SSH_FIXTURE_BROKER_URL")
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

  private static var cloneToken: BrokerStub.Answer {
    BrokerStub.Answer(
      body: #"{"token":"\#(token)","expires_at":"2026-10-01T18:00:00Z"}"#)
  }
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

  /// The fixture with a runtime that runs the real one, except for the subcommand named in the
  /// returned file while it exists: a provider failing one step on purpose.
  private func failingFixture() throws -> (Fixture, failing: URL) {
    let script = directory.appendingPathComponent("runtime")
    let failing = directory.appendingPathComponent("failing")
    let fixture = try fixture(runtime: script)
    try """
    #!/bin/sh
    if [ "$1" = "$(cat \(PosixShell.quoted(failing.path)) 2>/dev/null)" ]; then
      echo "injected failure" >&2; exit 1
    fi
    exec \(PosixShell.quoted(runtime.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (fixture, failing)
  }

  // MARK: Creating from the app (#253)

  /// What `RemoteWorkrooms.create` wrote to config, in order, in place of the CLI.
  private final class Recorded: @unchecked Sendable {
    enum Call: Equatable {
      case reserve(path: String, HostDescriptor)
      case record(workroom: String?, HostDescriptor)
      case forget(String)
    }
    private let lock = NSLock()
    private var log: [Call] = []
    private var next = 0
    var calls: [Call] { lock.withLock { log } }

    var recorder: RemoteWorkrooms.Recorder {
      RemoteWorkrooms.Recorder(
        reserve: { path, descriptor in
          self.lock.withLock {
            self.log.append(.reserve(path: path, descriptor))
            self.next += 1
            return "w\(self.next)"
          }
        },
        record: { workroom, descriptor in
          self.lock.withLock { self.log.append(.record(workroom: workroom, descriptor)) }
        },
        forget: { workroom in self.lock.withLock { self.log.append(.forget(workroom)) } })
    }
  }

  /// The project the tests create for, with the fixture's GitHub serving `/srv/origin.git`.
  private static let repository = GitHubRepository(host: "github.com", owner: "o", name: "r")!
  private static let originURL = "https://github.com/origin.git"

  /// The first create builds and records the base, then names the workroom before deriving it,
  /// and records everything a later launch needs to reach it; the second reuses the base.
  @MainActor
  func testCreatingRemoteWorkroomsBuildsTheBaseOnceAndRecordsWhatALaterLaunchNeeds() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    // The workroom fetches https://github.com with its own credentials, so its agent enrols with
    // the fixture's own broker, which the fixture's GitHub takes tokens from.
    let environment = environment(
      fixture, driver: driver, revoked: Revoked(),
      brokerURL: URL(string: ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_BROKER_URL"] ?? "")
    )
    let recorded = Recorded()

    BrokerStub.reset([Self.cloneToken, Self.grant])
    let first = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, base: nil, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await first.instance.connection.close()
    guard case .record(nil, let base) = recorded.calls.first, let baseID = base.id else {
      return XCTFail("the base was not recorded first: \(recorded.calls)")
    }
    cleanups.append { try? await driver.destroy(.remote(baseID)) }
    cleanups.append { try? await driver.destroy(first.instance.host) }

    XCTAssertEqual(base.driver, RemoteWorkrooms.containerDriver)
    XCTAssertEqual(base.repository, "o/r")
    XCTAssertEqual(base.path, RemoteWorkrooms.clonePath(for: Self.repository))
    XCTAssertNotNil(base.container)
    guard recorded.calls.count == 5, case .reserve(let path, let creating) = recorded.calls[1],
      case .record("w1", let hostMade) = recorded.calls[2],
      case .record("w1", let grantMade) = recorded.calls[3],
      case .record("w1", let workroom) = recorded.calls[4]
    else { return XCTFail("calls: \(recorded.calls)") }
    XCTAssertEqual(path, base.path)
    XCTAssertEqual(creating.state, "creating")
    // Each live thing is recorded as soon as it exists, so a crash mid-create leaves a delete what to
    // take down (#253).
    XCTAssertEqual(hostMade.state, "creating")
    XCTAssertEqual(hostMade.id, workroom.id)
    XCTAssertNotNil(hostMade.container)
    XCTAssertNil(hostMade.grantID)
    XCTAssertEqual(grantMade.state, "creating")
    XCTAssertEqual(grantMade.grantID, "g1")
    XCTAssertTrue(RemoteWorkrooms.isLive(hostMade) && RemoteWorkrooms.isLive(grantMade))
    XCTAssertNil(workroom.state, "a serving workroom's descriptor has a state")
    XCTAssertEqual(workroom.grantID, "g1")
    XCTAssertEqual(workroom.workroomID, creating.workroomID)
    XCTAssertEqual(workroom.container, driver.record(of: first.instance.host))
    XCTAssertEqual(first.name, "w1")

    // The workroom's branch is named for it, and another launch reaches it from its record.
    let later = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("later"),
      provisioning: fixture.provisioning)
    try later.adopt(try XCTUnwrap(workroom.id), try XCTUnwrap(workroom.container))
    let head = try await onHost(
      later, first.instance.host, "git -C \(base.path!) rev-parse --abbrev-ref HEAD")
    XCTAssertEqual(head.output, RemoteWorkrooms.branch(for: "w1"))

    // A pane mounts there as the app mounts one: its session registered with the host, its
    // command from the app's routing, starting in the workroom's checkout on its branch.
    let session = UUID()
    PersistentSessionService.shared.registerRemoteSession(
      session, on: first.instance.host, via: driver, workingDirectory: try XCTUnwrap(base.path))
    let pane = try RemoteHostIntegrationTests.Pane(
      command: try XCTUnwrap(PersistentSessionService.shared.attachCommand(forSession: session)))
    defer { pane.dropLink() }
    try await Task.sleep(for: .seconds(1))
    // Typed with a split marker, so only the shell's answer reads `:END`.
    pane.type("echo \"AT:$(pwd):ON:$(git rev-parse --abbrev-ref HEAD):E\"\"ND\"\n")
    let seen = pane.read(until: ":END")
    XCTAssertTrue(seen.contains("AT:\(base.path!):ON:workroom/w1:END"), seen)

    // A second create derives from the recorded base: no new base, no clone token asked for.
    BrokerStub.reset([Self.grant])
    let second = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, base: base, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await second.instance.connection.close()
    cleanups.append { try? await driver.destroy(second.instance.host) }
    XCTAssertEqual(second.name, "w2")
    XCTAssertFalse(
      BrokerStub.requests.contains { $0.request.url?.path == "/broker/base-clone-tokens" })
    XCTAssertEqual(try leftovers("ps", label: label).count, 3, "one base and two workrooms")
  }

  /// Deleting a remote workroom from the app (#253) cancels its grant and removes its box, then
  /// drops its entry. One whose grant can't be cancelled loses its box anyway and keeps its entry,
  /// `failed` with the live grant, until deleting it again finishes the job. The base goes last,
  /// then its record.
  @MainActor
  func testDeletingRemoteWorkroomsTakesThemDownAndThenTheirBase() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(
      fixture, driver: driver, revoked: Revoked(),
      brokerURL: URL(string: ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_BROKER_URL"] ?? "")
    )
    let recorded = Recorded()
    BrokerStub.reset([Self.cloneToken, Self.grant])
    let first = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, base: nil, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await first.instance.connection.close()
    guard case .record(nil, let base) = recorded.calls.first, let baseID = base.id,
      case .record("w1", let w1) = recorded.calls.last
    else { return XCTFail("calls: \(recorded.calls)") }
    cleanups.append { try? await driver.destroy(.remote(baseID)) }
    cleanups.append { try? await driver.destroy(first.instance.host) }
    BrokerStub.reset([Self.grant])
    let second = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, base: base, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await second.instance.connection.close()
    cleanups.append { try? await driver.destroy(second.instance.host) }
    guard case .record("w2", let w2) = recorded.calls.last else {
      return XCTFail("calls: \(recorded.calls)")
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 3, "one base and two workrooms")

    BrokerStub.reset([Self.cancelled])
    try await RemoteWorkrooms.delete(
      "w1", host: w1, environment: environment, recorder: recorded.recorder)
    XCTAssertEqual(grantsCancelled, 1, "the grant was not cancelled")
    XCTAssertEqual(recorded.calls.last, .forget("w1"))
    XCTAssertEqual(try leftovers("ps", label: label).count, 2, "the workroom's box was kept")

    BrokerStub.reset([.init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    do {
      try await RemoteWorkrooms.delete(
        "w2", host: w2, environment: environment, recorder: recorded.recorder)
      XCTFail("a failed grant cancel was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete {}
    guard case .record("w2", let left) = recorded.calls.last else {
      return XCTFail("what is still live was not recorded: \(recorded.calls)")
    }
    XCTAssertEqual(left.state, "failed")
    XCTAssertEqual(left.grantID, "g1", "the live grant was not kept")
    XCTAssertNil(left.id, "a box already gone was kept")
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the second box was kept")

    BrokerStub.reset([Self.cancelled])
    try await RemoteWorkrooms.delete(
      "w2", host: left, environment: environment, recorder: recorded.recorder)
    XCTAssertEqual(grantsCancelled, 1)
    XCTAssertEqual(recorded.calls.last, .forget("w2"))

    let cleared = Revoked()
    try await RemoteWorkrooms.deleteBase(base, environment: environment) { cleared.add("base") }
    XCTAssertEqual(cleared.all, ["base"])
    XCTAssertEqual(try leftovers("ps", label: label), [], "the base was kept")
  }

  /// A checkpoint that cannot be recorded is a failed step (#253): the derive undoes itself, so the
  /// grant it minted is cancelled and its box removed, rather than either living on unrecorded.
  @MainActor
  func testADeriveWhoseCheckpointFailsUndoesItself() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    BrokerStub.reset([Self.grant, Self.cancelled])

    do {
      _ = try await RemoteProvisioning.derive(
        from: base, workroom: UUID(), branch: "wr-checkpoint", in: environment
      ) { _, grant in
        if grant != nil { throw WorkroomCLIError.timedOut }
      }
      XCTFail("a derive whose checkpoint failed succeeded")
    } catch WorkroomCLIError.timedOut {}
    XCTAssertEqual(grantsCancelled, 1, "the grant was left live")
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "only the base should be left")
  }

  /// A derive that fails and undoes itself drops the name it took; nothing is recorded for it.
  @MainActor
  func testACreateWhoseDeriveFailsForgetsTheNameItTook() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    BrokerStub.reset([Self.cloneToken])
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: Self.originURL, path: Self.path, in: environment,
      record: { _ in })
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    try "commit".write(to: failing, atomically: true, encoding: .utf8)
    let recorded = Recorded()

    do {
      _ = try await RemoteWorkrooms.create(
        repository: Self.repository, cloneURL: Self.originURL,
        base: HostDescriptor(
          provisioner: RemoteWorkrooms.provisioner, id: base.host, repository: base.repository,
          cloneURL: base.cloneURL, path: base.path),
        driver: driver, environment: environment, recorder: recorded.recorder)
      XCTFail("a create whose derive failed succeeded")
    } catch {}
    guard recorded.calls.count == 2, case .reserve = recorded.calls[0] else {
      return XCTFail("calls: \(recorded.calls)")
    }
    XCTAssertEqual(recorded.calls[1], .forget("w1"))
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "only the base should be left")
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

    // Over https, so git really sends the token: a clone by path never would.
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git", path: Self.path,
      in: environment(fixture, driver: driver, revoked: revoked),
      record: { recorded.add(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) })
    cleanups.append { try? await driver.destroy(.remote(base.host)) }

    let host = HostID.remote(base.host)
    let readme = try await onHost(driver, host, "cat \(Self.path)/README")
    XCTAssertEqual(readme.output, "origin")
    let remote = try await onHost(driver, host, "git -C \(Self.path) remote get-url origin")
    XCTAssertEqual(
      remote.output, "https://github.com/origin.git",
      "the remote URL carries something besides the repository")
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

  /// A remote workroom registered as the project listing registers it reads through the router,
  /// which connects its host itself, as git reports it on the box: its status, log, file listing,
  /// file contents and a working diff (#253).
  @MainActor
  func testARegisteredRemoteWorkroomReadsThroughTheRouterAsGitReportsItOnTheBox() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    BrokerStub.reset([Self.grant])
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: UUID(), branch: "wr-read", in: environment)
    await instance.connection.close()
    cleanups.append { try? await driver.destroy(instance.host) }
    guard case .remote(let id) = instance.host else { return XCTFail("\(instance.host)") }

    // A change on the box: a tracked file edited and a new file.
    let path = instance.path
    let tracked = try await onHost(driver, instance.host, "git -C \(path) ls-files | head -n 1")
      .output
    XCTAssertFalse(tracked.isEmpty)
    let edit = try await onHost(
      driver, instance.host, "cd \(path) && echo edited >> '\(tracked)' && echo new > fresh.txt")
    XCTAssertEqual(edit.status, 0, edit.output)
    let mine = RemoteWorkrooms.provisioner
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: path, vcsName: "workroom/w", warnings: [],
          host: HostDescriptor(provisioner: mine, id: id))
      ],
      host: HostDescriptor(provisioner: mine, id: base.host, repository: "o/r"))
    let manager = HostConnectionManager()
    let router = RepositoryRouter(
      connections: manager,
      connectRemote: { host in
        _ = try await manager.connectIfDisconnected(host: host) {
          try await AgentBootstrap.connect(
            host: host, driver: driver, socket: RemoteWorkrooms.agentSocket)
        }
      })
    router.replaceRemote(RemoteWorkrooms.registrations([project]))
    let location = try XCTUnwrap(
      project.workrooms[0].target(inProject: project.path).remoteLocation)

    let reader = try await router.reader(for: location)
    let status = try await reader.workingStatus()
    // Cut on the host: `onHost` trims, which would take a first line's leading status space.
    let changed = try await onHost(
      driver, instance.host, "git -C \(path) status --porcelain | cut -c4-")
    XCTAssertEqual(status.dirty, true)
    XCTAssertEqual(
      Set(status.changedFiles?.map(\.path) ?? []),
      Set(changed.output.split(separator: "\n").map(String.init)))

    let log = try await reader.log(limit: 5)
    let gitLog = try await onHost(driver, instance.host, "git -C \(path) log -n 5 --format=%H")
    XCTAssertEqual(
      log.commits.map(\.commitID), gitLog.output.split(separator: "\n").map(String.init))

    let files = try await router.files(for: location)
    let listing = try await files.list()
    XCTAssertTrue(listing.ok, listing.stderr)
    XCTAssertTrue(listing.stdout.contains(tracked), listing.stdout)
    XCTAssertTrue(listing.stdout.contains("fresh.txt"), listing.stdout)
    let data = try await files.read(path: tracked, symlinks: .followWithinRoot, maxBytes: 1 << 20)
    let cat = try await onHost(driver, instance.host, "cat '\(path)/\(tracked)'")
    XCTAssertEqual(
      String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
      cat.output)

    let diff = try await reader.workingFileDiff(path: tracked)
    let gitDiff = try await onHost(driver, instance.host, "git -C \(path) diff -- '\(tracked)'")
    XCTAssertTrue(diff.contains("+edited"), diff)
    XCTAssertTrue(gitDiff.output.contains("+edited"), gitDiff.output)
  }

  /// A failure at each step after the derive starts leaves no instance and no live grant behind.
  @MainActor
  func testAWorkroomThatFailsAtEachStepLeavesNoInstanceAndNoGrant() async throws {
    // The runtime fails `commit` only when told to, so the base is built with it as it is.
    let (fixture, failing) = try failingFixture()
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
        try "commit".write(to: failing, atomically: true, encoding: .utf8)
      } else {
        try? FileManager.default.removeItem(at: failing)
      }
      BrokerStub.reset([Self.grant, Self.cancelled])

      do {
        _ = try await RemoteProvisioning.derive(
          from: base, workroom: UUID(), branch: branch, in: environment)
        XCTFail("a workroom that failed at \(step) was made")
      } catch {
        // The failure is the step's own, so the assertions below are about that step.
        switch (step, error) {
        case ("derive", HostDriverError.provisioning), ("connect", is Injected),
          ("enrol", BrokerError.agent), ("checkout", RemoteProvisioning.Failure.git("switch", _)):
          break
        default: XCTFail("\(step) failed for another reason: \(error)")
        }
      }

      XCTAssertEqual(
        try leftovers("ps", label: label), containers, "a failure at \(step) left an instance")
      XCTAssertEqual(
        try leftovers("images", label: label), [], "a failure at \(step) left an image")
      XCTAssertEqual(
        grantsCancelled, granted ? 1 : 0, "a failure at \(step) left its grant live")
    }
  }

  /// The box authenticates on its own (#252): with the Mac's connection gone, a derived workroom
  /// fetches and pushes over https to the fixture's GitHub, its credential helper minting from the
  /// fixture's broker on the box (`fake-github.py`). The base clones over https too, with the
  /// broker's clone token as git's header. Commands run through the runtime's exec, the provider's
  /// control plane, not over the Mac's link.
  @MainActor
  func testADerivedWorkroomFetchesAndPushesWithTheMacDisconnected() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(
      fixture, driver: driver, revoked: Revoked(),
      brokerURL: URL(string: ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_BROKER_URL"] ?? "")
    )
    BrokerStub.reset([Self.cloneToken])
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git", path: Self.path,
      in: environment, record: { _ in })
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    BrokerStub.reset([Self.grant])
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: UUID(), branch: "wr-pushed", in: environment)
    cleanups.append { try? await driver.destroy(instance.host) }
    await instance.connection.close()

    // The driver names each container after its host.
    guard case .remote(let id) = instance.host else { return XCTFail("not a remote host") }
    let container = "workroom-\(id.uuidString.lowercased())"
    func onBox(_ script: String) throws -> String {
      try docker(
        runtime,
        [
          "exec", "--user", "workroom", "--env", "HOME=/home/workroom", "--workdir", Self.path,
          container, "sh", "-c", script + "; echo exit=$?",
        ])
    }
    // Disconnected: no relay to the Mac's agent connection is left on the box, once the closed
    // link's ssh has gone. `[w]`, so the pattern does not match the shell running it.
    var relays = ""
    for _ in 0..<50 {
      relays = try onBox("pgrep -f '[w]r-agent relay'")
      if relays == "exit=1" { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertEqual(relays, "exit=1", "a relay to the Mac is still running")

    let commit = try onBox(
      "git -c user.name=W -c user.email=w@example.com commit -q --allow-empty -m pushed"
        + " && git rev-parse HEAD")
    let pushed = try XCTUnwrap(commit.split(separator: "\n").first.map(String.init), commit)
    // The fixture's GitHub refuses a push with no token, so the one below is the helper's doing.
    let refused = try onBox("git -c credential.https://github.com.helper= push -q origin HEAD 2>&1")
    XCTAssertFalse(refused.hasSuffix("exit=0"), "the fixture's GitHub took a push with no token")

    XCTAssertTrue(try onBox("git fetch -q origin").hasSuffix("exit=0"), "the fetch failed")
    let push = try onBox("git push -q origin HEAD 2>&1")
    XCTAssertTrue(push.hasSuffix("exit=0"), push)
    XCTAssertEqual(
      try onBox("git -C /srv/origin.git rev-parse refs/heads/wr-pushed"), "\(pushed)\nexit=0")
  }

  /// Signed out of Codaset (#309), a local container's base clones with the Mac's own GitHub token,
  /// its workroom never enrols, and git in the workroom gets credentials through the Mac's relay:
  /// a push works while the app is connected and says so when it isn't. The fixture's GitHub takes
  /// its clone token, which stands in for the Mac's `gh`.
  @MainActor
  func testARelayedWorkroomPushesThroughTheMacWithoutEnrolling() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let agent = fixture.agent
    let socket = fixture.provisioning.agentSocket
    let token = Self.token
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: socket, client: nil, gitHubToken: { token },
      connect: { host in
        try await AgentBootstrap.connect(
          host: host, driver: driver, socket: socket,
          agent: { $0 == "aarch64" || $0 == "x86_64" ? agent : nil }, handOff: false,
          resources: nil)
      })
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git", path: Self.path,
      in: environment, record: { _ in })
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    XCTAssertEqual(base.relayed, true)
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: UUID(), branch: "wr-relayed", in: environment)
    cleanups.append { try? await driver.destroy(instance.host) }
    XCTAssertNil(instance.grantID, "a relayed workroom enrolled")

    // The relay, over a connection of its own as the app's registry holds one.
    let generation = UUID()
    let relay = CredentialRelay(
      answer: { _ in "username=x-access-token\npassword=\(token)\n" },
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
        }))
    try await relay.install(
      on: instance.host, driver: driver, agentBinary: AgentBootstrap.binary(besideSocket: socket))

    guard case .remote(let id) = instance.host else { return XCTFail("not a remote host") }
    let container = "workroom-\(id.uuidString.lowercased())"
    func onBox(_ script: String) throws -> String {
      try docker(
        runtime,
        [
          "exec", "--user", "workroom", "--env", "HOME=/home/workroom", "--workdir", Self.path,
          container, "sh", "-c", script + "; echo exit=$?",
        ])
    }
    XCTAssertEqual(
      try onBox("test -e \(socket.replacingOccurrences(of: "agent.sock", with: "broker.json"))"),
      "exit=1", "a relayed workroom has a broker enrolment")
    _ = try onBox(
      "git -c user.name=W -c user.email=w@example.com commit -q --allow-empty -m relayed")
    let push = try onBox("git push -q origin HEAD 2>&1")
    XCTAssertTrue(push.hasSuffix("exit=0"), push)
    XCTAssertTrue(
      try onBox("git -C /srv/origin.git rev-parse --verify -q refs/heads/wr-relayed")
        .hasSuffix("exit=0"))

    // With the relay gone, git is told why rather than asked for a password.
    relay.close(id)
    var failed = ""
    for _ in 0..<50 {
      failed = try onBox("git -c credential.interactive=false push -q origin HEAD:wr-later 2>&1")
      if !failed.hasSuffix("exit=0") { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertTrue(failed.contains("isn't connected to this workroom"), failed)
  }

  /// A workroom branches from the remote's default branch as it is now, not as it was when the
  /// base was cloned: `fetch` never moves `origin/HEAD`, and once `--prune` drops the old default
  /// it names nothing.
  @MainActor
  func testAWorkroomBranchesFromTheDefaultBranchAfterTheRemoteRenamedIt() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    let renamed = try await onHost(
      driver, .remote(base.host),
      "git -C /srv/origin.git branch -m main trunk"
        + " && git -C /srv/origin.git symbolic-ref HEAD refs/heads/trunk")
    XCTAssertEqual(renamed.status, 0, renamed.output)

    BrokerStub.reset([Self.grant])
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: UUID(), branch: "wr-renamed", in: environment)
    cleanups.append { try? await driver.destroy(instance.host) }

    let head = try await RemoteProvisioning.git(
      ["symbolic-ref", "refs/remotes/origin/HEAD"], in: instance.path, on: instance.connection)
    XCTAssertEqual(
      head.trimmingCharacters(in: .whitespacesAndNewlines), "refs/remotes/origin/trunk")
  }

  /// A project's base branch setting: the workroom starts from origin's copy of that branch, which
  /// appeared after the base was cloned, not from the default branch.
  @MainActor
  func testAWorkroomStartsFromTheProjectsBaseBranch() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    let branched = try await onHost(
      driver, .remote(base.host),
      "git -C /srv/origin.git -c user.name=t -c user.email=t@t commit-tree -p main"
        + " -m develop main^{tree} | xargs git -C /srv/origin.git branch develop"
        + " && git -C /srv/origin.git rev-parse develop")
    XCTAssertEqual(branched.status, 0, branched.output)
    let develop = branched.output.trimmingCharacters(in: .whitespacesAndNewlines)

    BrokerStub.reset([Self.grant])
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: UUID(), branch: "wr-develop", startBranch: "develop", in: environment)
    cleanups.append { try? await driver.destroy(instance.host) }

    let head = try await RemoteProvisioning.git(
      ["rev-parse", "HEAD"], in: instance.path, on: instance.connection)
    XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), develop)
  }

  @MainActor
  func testABaseWhoseCloneTokenIsRefusedIsRemovedWithNothingToRevoke() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let revoked = Revoked()
    BrokerStub.reset([.init(status: 403, body: #"{"error":"no_read_access"}"#)])

    do {
      _ = try await RemoteProvisioning.buildBase(
        repository: "o/r", cloneURL: "/srv/origin.git", path: Self.path,
        in: environment(fixture, driver: driver, revoked: revoked), record: { _ in })
      XCTFail("a base was built without a clone token")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "no_read_access")
    }
    XCTAssertEqual(revoked.all, [], "a token that was never minted was revoked")
    XCTAssertEqual(try leftovers("ps", label: label), [], "the base outlived its refused token")
  }

  @MainActor
  func testDestroyingABaseRemovesItAndForgetsItsRecordOnlyOnceItIsGone() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    let forgotten = Revoked()

    // Forgetting fails the first time: the box is gone, and a retry gets past the destroy it
    // already did to forget the record.
    do {
      try await RemoteProvisioning.destroyBase(
        base.host, in: environment, forget: { throw WorkroomCLIError.timedOut })
      XCTFail("a failed forget was swallowed")
    } catch WorkroomCLIError.timedOut {}
    XCTAssertEqual(try leftovers("ps", label: label), [])
    try await RemoteProvisioning.destroyBase(
      base.host, in: environment, forget: { forgotten.add("forgot") })
    XCTAssertEqual(forgotten.all, ["forgot"])

    // A base this driver never knew (an app relaunched since) keeps its record: nothing has shown
    // it is gone.
    let relaunched = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    do {
      try await RemoteProvisioning.destroyBase(
        base.host, in: self.environment(fixture, driver: relaunched, revoked: Revoked()),
        forget: { forgotten.add("forgot again") })
      XCTFail("an unknown base was destroyed")
    } catch HostDriverError.unknownHost {}
    XCTAssertEqual(forgotten.all, ["forgot"])
  }

  @MainActor
  func testDestroyingAWorkroomWhoseGrantCannotBeCancelledStillRemovesItsBox() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    BrokerStub.reset([Self.grant])
    let workroom = UUID()
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: workroom, branch: "wr-cancel", in: environment)

    BrokerStub.reset([.init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    do {
      try await RemoteProvisioning.destroy(instance, workroom: workroom, in: environment)
      XCTFail("a failed grant cancel was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, let cleanup) {
      XCTAssertNil(host, "the box is gone, but was reported live")
      XCTAssertEqual(grant, "g1", "the grant still live was not named")
      XCTAssertEqual(cleanup.count, 1, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the instance's box was kept")
  }

  /// Both halves of a workroom's teardown failing are both reported.
  @MainActor
  func testDestroyingAWorkroomReportsBothAFailedCancelAndAFailedRemoval() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    BrokerStub.reset([Self.grant])
    let workroom = UUID()
    let instance = try await RemoteProvisioning.derive(
      from: base, workroom: workroom, branch: "wr-both", in: environment)
    BrokerStub.reset([.init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    try "rm".write(to: failing, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: failing) }

    do {
      try await RemoteProvisioning.destroy(instance, workroom: workroom, in: environment)
      XCTFail("a failed teardown was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, let cleanup) {
      XCTAssertEqual(host, instance.host, "the box still up was not named")
      XCTAssertEqual(grant, "g1", "the grant still live was not named")
      XCTAssertEqual(cleanup.count, 2, "\(cleanup)")
    }
  }

  /// A failure whose undoing fails too names what is still live (#252 review), rather than
  /// leaving a box holding an enrolled key and a live grant that nothing records.
  @MainActor
  func testAWorkroomWhoseRollbackFailsSaysWhatIsStillLive() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver, revoked: Revoked())
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    // The checkout fails on its branch name, then the grant cancel and the box's removal fail.
    BrokerStub.reset([Self.grant, .init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    try "rm".write(to: failing, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: failing) }

    do {
      _ = try await RemoteProvisioning.derive(
        from: base, workroom: UUID(), branch: "bad..name", in: environment)
      XCTFail("a workroom with an unusable branch was made")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(
      let cause, let host, let grant, let cleanup)
    {
      XCTAssertTrue(cause.contains("switch"), cause)
      XCTAssertNotNil(host, "the box still up was not named")
      XCTAssertEqual(grant, "g1", "the grant still live was not named")
      XCTAssertEqual(cleanup.count, 2, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 2, "the instance should still be up")
  }

  /// An enrolment whose own grant cancel fails hands that grant to the rollback's report rather
  /// than losing it (#280 review).
  @MainActor
  func testAWorkroomWhoseEnrolmentAndGrantCancelFailNamesTheLiveGrant() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let base = try await build(environment(fixture, driver: driver, revoked: Revoked()))
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    let containers = try leftovers("ps", label: label)
    // Nothing listens there, so the agent's enrolment fails after the grant is made.
    let failing = environment(
      fixture, driver: driver, revoked: Revoked(), brokerURL: URL(string: "http://127.0.0.1:9"))
    BrokerStub.reset([Self.grant, .init(status: 503, body: #"{"error":"github_unavailable"}"#)])

    do {
      _ = try await RemoteProvisioning.derive(
        from: base, workroom: UUID(), branch: "wr-enrol", in: failing)
      XCTFail("a workroom that could not enrol was made")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, let cleanup) {
      XCTAssertNil(host, "the box is gone, but was reported live")
      XCTAssertEqual(grant, "g1", "the enrolment's live grant was lost")
      XCTAssertEqual(cleanup.count, 1, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label), containers, "the instance was kept")
  }

  /// A refresh brings the base's clone up to date with a fresh clone token, revoked after, and a
  /// workroom derived after it starts from what the refresh fetched.
  @MainActor
  func testARefreshedBaseHandsItsWorkroomsWhatItFetched() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let revoked = Revoked()
    let environment = environment(fixture, driver: driver, revoked: revoked)
    let base = try await build(environment)
    cleanups.append { try? await driver.destroy(.remote(base.host)) }
    let host = HostID.remote(base.host)
    let pushed = try await onHost(
      driver, host,
      "seed=$(mktemp -d) && git clone -q /srv/origin.git $seed"
        + " && git -C $seed -c user.name=a -c user.email=a@b commit -q --allow-empty -m later"
        + " && git -C $seed push -q origin HEAD && git -C $seed rev-parse HEAD")
    XCTAssertEqual(pushed.status, 0, pushed.output)

    BrokerStub.reset([Self.cloneToken])
    try await RemoteProvisioning.refreshBase(base, in: environment)

    XCTAssertEqual(revoked.all, [Self.token, Self.token], "the refresh's token outlived it")
    let fetched = try await onHost(
      driver, host, "git -C \(Self.path) rev-parse refs/remotes/origin/main")
    XCTAssertEqual(fetched.output, pushed.output, "the refresh did not fetch")

    // A refused token leaves the base as it was, with nothing to revoke.
    BrokerStub.reset([.init(status: 403, body: #"{"error":"no_read_access"}"#)])
    do {
      try await RemoteProvisioning.refreshBase(base, in: environment)
      XCTFail("a refresh ran without a token")
    } catch BrokerError.refused {}
    XCTAssertEqual(revoked.all.count, 2)
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "a refused refresh took the base")
  }
}
