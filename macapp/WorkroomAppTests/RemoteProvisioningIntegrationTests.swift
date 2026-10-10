import CryptoKit
import Defaults
import XCTest

@testable import Workroom

/// The provisioning sequence (#252) on the ssh fixture's containers: workrooms made, enrolled,
/// cloned and checked out, each on a host of its own, with every failure undoing what it made.
/// A workroom clones its host's `/srv/origin.git` by path unless a test says otherwise; the
/// credentials' choice is pinned by `RemoteProvisioningTests`. The Mac's broker calls go to
/// `BrokerStub`, and each agent's enrolment to a `StubBroker` on this Mac through the agent's own
/// loopback, as a Debug build's does. Skipped unless run through the fixture script:
///
///   vcs/scripts/ssh-fixture/run.sh <linux wr-agent> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/RemoteProvisioningIntegrationTests
final class RemoteProvisioningIntegrationTests: XCTestCase {
  private var directory: URL!
  private var label: String!
  private var runtime: URL!
  private var broker: StubBroker!
  private var cleanups: [() async -> Void] = []

  /// The clone token the fixture's GitHub accepts (run.sh reads it out of the image), which stands
  /// in for the Mac's own `gh` token.
  private static var token: String {
    ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_CLONE_TOKEN"] ?? ""
  }
  private static let path = "/home/workroom/project"

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-provision-\(UUID().uuidString.prefix(8))")
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

  /// The sequence's environment over `driver`. The agent's broker is a reverse forward to
  /// `broker` (or `brokerURL`, to make the agent's enrolment fail), over a connection of its own
  /// to the host, as the app's registry holds one.
  @MainActor
  private func environment(
    _ fixture: Fixture, driver: ContainerHostDriver,
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
      })
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

  /// `-a` for both: `images` lists an untagged image only with it.
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

  private func provision(
    _ environment: RemoteProvisioning.Environment, branch: String, workroom: UUID = UUID(),
    cloneURL: String = "/srv/origin.git", startBranch: String? = nil,
    checkpoint: @Sendable (_ host: HostID, _ grant: String?) async throws -> Void = { _, _ in }
  ) async throws -> RemoteProvisioning.Instance {
    try await RemoteProvisioning.provision(
      repository: "o/r", cloneURL: cloneURL, path: Self.path, workroom: workroom, branch: branch,
      startBranch: startBranch, in: environment, checkpoint: checkpoint)
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

  /// A create names the workroom before its host is made, records each live thing as soon as it
  /// exists, and records everything a later launch needs to reach it. The project records nothing.
  @MainActor
  func testCreatingARemoteWorkroomRecordsWhatALaterLaunchNeeds() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    // The workroom clones and fetches https://github.com with its own credentials, so its agent
    // enrols with the fixture's own broker, which the fixture's GitHub takes tokens from.
    let environment = environment(
      fixture, driver: driver,
      brokerURL: URL(string: ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_BROKER_URL"] ?? "")
    )
    let recorded = Recorded()

    BrokerStub.reset([Self.grant])
    let first = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await first.instance.connection.close()
    cleanups.append { try? await driver.destroy(first.instance.host) }

    guard recorded.calls.count == 4, case .reserve(let path, let creating) = recorded.calls[0],
      case .record("w1", let hostMade) = recorded.calls[1],
      case .record("w1", let grantMade) = recorded.calls[2],
      case .record("w1", let workroom) = recorded.calls[3]
    else { return XCTFail("calls: \(recorded.calls)") }
    XCTAssertEqual(path, RemoteWorkrooms.clonePath(for: Self.repository))
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
    XCTAssertEqual(workroom.driver, RemoteWorkrooms.containerDriver)
    XCTAssertEqual(workroom.grantID, "g1")
    XCTAssertEqual(workroom.workroomID, creating.workroomID)
    XCTAssertEqual(workroom.repository, "o/r")
    XCTAssertEqual(workroom.container, driver.record(of: first.instance.host))
    XCTAssertEqual(first.name, "w1")

    // The workroom's branch is named for it, and another launch reaches it from its record.
    let later = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("later"),
      provisioning: fixture.provisioning)
    try later.adopt(try XCTUnwrap(workroom.id), try XCTUnwrap(workroom.container))
    let head = try await onHost(
      later, first.instance.host, "git -C \(path) rev-parse --abbrev-ref HEAD")
    XCTAssertEqual(head.output, RemoteWorkrooms.branch(for: "w1"))

    // A pane mounts there as the app mounts one: its session registered with the host, its
    // command from the app's routing, starting in the workroom's checkout on its branch.
    let session = UUID()
    PersistentSessionService.shared.registerRemoteSession(
      session, on: first.instance.host, via: driver, workingDirectory: path)
    let pane = try RemoteHostIntegrationTests.Pane(
      command: try XCTUnwrap(PersistentSessionService.shared.attachCommand(forSession: session)))
    defer { pane.dropLink() }
    try await Task.sleep(for: .seconds(1))
    // Typed with a split marker, so only the shell's answer reads `:END`.
    pane.type("echo \"AT:$(pwd):ON:$(git rev-parse --abbrev-ref HEAD):E\"\"ND\"\n")
    let seen = pane.read(until: ":END")
    XCTAssertTrue(seen.contains("AT:\(path):ON:workroom/w1:END"), seen)

    // A second create makes a host of its own.
    BrokerStub.reset([Self.grant])
    let second = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await second.instance.connection.close()
    cleanups.append { try? await driver.destroy(second.instance.host) }
    XCTAssertEqual(second.name, "w2")
    XCTAssertFalse(recorded.calls.contains { if case .record(nil, _) = $0 { true } else { false } })
    XCTAssertEqual(try leftovers("ps", label: label).count, 2, "two workrooms, and nothing else")
  }

  /// Deleting a remote workroom from the app (#253) cancels its grant and removes its box, then
  /// drops its entry. One whose grant can't be cancelled loses its box anyway and keeps its entry,
  /// `failed` with the live grant, until deleting it again finishes the job.
  @MainActor
  func testDeletingRemoteWorkroomsTakesThemDown() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(
      fixture, driver: driver,
      brokerURL: URL(string: ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_BROKER_URL"] ?? "")
    )
    let recorded = Recorded()
    var made: [String: HostDescriptor] = [:]
    for name in ["w1", "w2"] {
      BrokerStub.reset([Self.grant])
      let created = try await RemoteWorkrooms.create(
        repository: Self.repository, cloneURL: Self.originURL, driver: driver,
        environment: environment, recorder: recorded.recorder)
      await created.instance.connection.close()
      cleanups.append { try? await driver.destroy(created.instance.host) }
      guard case .record(name, let descriptor) = recorded.calls.last else {
        return XCTFail("calls: \(recorded.calls)")
      }
      made[name] = descriptor
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 2, "two workrooms")

    BrokerStub.reset([Self.cancelled])
    try await RemoteWorkrooms.delete(
      "w1", host: try XCTUnwrap(made["w1"]), environment: environment,
      recorder: recorded.recorder)
    XCTAssertEqual(grantsCancelled, 1, "the grant was not cancelled")
    XCTAssertEqual(recorded.calls.last, .forget("w1"))
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the workroom's box was kept")

    BrokerStub.reset([.init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    do {
      try await RemoteWorkrooms.delete(
        "w2", host: try XCTUnwrap(made["w2"]), environment: environment,
        recorder: recorded.recorder)
      XCTFail("a failed grant cancel was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete {}
    guard case .record("w2", let left) = recorded.calls.last else {
      return XCTFail("what is still live was not recorded: \(recorded.calls)")
    }
    XCTAssertEqual(left.state, "failed")
    XCTAssertEqual(left.grantID, "g1", "the live grant was not kept")
    XCTAssertNil(left.id, "a box already gone was kept")
    XCTAssertEqual(try leftovers("ps", label: label), [], "the second box was kept")

    BrokerStub.reset([Self.cancelled])
    try await RemoteWorkrooms.delete(
      "w2", host: left, environment: environment, recorder: recorded.recorder)
    XCTAssertEqual(grantsCancelled, 1)
    XCTAssertEqual(recorded.calls.last, .forget("w2"))
  }

  /// A checkpoint that cannot be recorded is a failed step (#253): the create undoes itself, so the
  /// grant it minted is cancelled and its box removed, rather than either living on unrecorded.
  @MainActor
  func testAProvisionWhoseCheckpointFailsUndoesItself() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    BrokerStub.reset([Self.grant, Self.cancelled])

    do {
      _ = try await provision(
        environment(fixture, driver: driver), branch: "wr-checkpoint"
      ) { _, grant in
        if grant != nil { throw WorkroomCLIError.timedOut }
      }
      XCTFail("a create whose checkpoint failed succeeded")
    } catch WorkroomCLIError.timedOut {}
    XCTAssertEqual(grantsCancelled, 1, "the grant was left live")
    XCTAssertEqual(try leftovers("ps", label: label), [], "its box was left")
  }

  /// A create whose machine fails, and undoes itself, drops the name it took; nothing is recorded
  /// for it.
  @MainActor
  func testACreateWhoseMachineFailsForgetsTheNameItTook() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    try "run".write(to: failing, atomically: true, encoding: .utf8)
    let recorded = Recorded()

    do {
      _ = try await RemoteWorkrooms.create(
        repository: Self.repository, cloneURL: Self.originURL, driver: driver,
        environment: environment(fixture, driver: driver), recorder: recorded.recorder)
      XCTFail("a create whose machine failed succeeded")
    } catch {}
    guard recorded.calls.count == 2, case .reserve = recorded.calls[0] else {
      return XCTFail("calls: \(recorded.calls)")
    }
    XCTAssertEqual(recorded.calls[1], .forget("w1"))
    XCTAssertEqual(try leftovers("ps", label: label), [], "a box was left")
  }

  /// A workroom whose clone fails is removed, and its grant cancelled.
  @MainActor
  func testAWorkroomWhoseCloneFailsIsRemovedWithItsGrant() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    BrokerStub.reset([Self.grant, Self.cancelled])

    do {
      _ = try await provision(
        environment(fixture, driver: driver), branch: "wr-clone", cloneURL: "/srv/no-such.git")
      XCTFail("a clone of nothing succeeded")
    } catch RemoteProvisioning.Failure.git(let command, _) {
      XCTAssertEqual(command, "clone")
    }
    XCTAssertEqual(grantsCancelled, 1, "the grant was left live")
    XCTAssertEqual(try leftovers("ps", label: label), [], "a failed workroom was left running")
  }

  // MARK: Workrooms

  @MainActor
  func testWorkroomsServeOnTheirOwnBranchWithTheirOwnEnrolment() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)

    var keys: [String] = []
    for branch in ["wr-one", "wr-two"] {
      BrokerStub.reset([Self.grant])
      let workroom = UUID()
      let instance = try await provision(environment, branch: branch, workroom: workroom)
      cleanups.append { try? await driver.destroy(instance.host) }

      XCTAssertEqual(instance.grantID, "g1")
      XCTAssertFalse(instance.relayed)
      let remote = try await onHost(
        driver, instance.host, "git -C \(Self.path) remote get-url origin")
      XCTAssertEqual(
        remote.output, "/srv/origin.git", "the remote URL carries something besides the repository")
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
    XCTAssertEqual(try leftovers("ps", label: label), [], "a workroom's box was left")
  }

  /// A remote workroom registered as the project listing registers it reads through the router,
  /// which connects its host itself, as git reports it on the box: its status, log, file listing,
  /// file contents and a working diff (#253).
  @MainActor
  func testARegisteredRemoteWorkroomReadsThroughTheRouterAsGitReportsItOnTheBox() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    BrokerStub.reset([Self.grant])
    let instance = try await provision(environment, branch: "wr-read")
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
          host: HostDescriptor(provisioner: mine, id: id, repository: "o/r"))
      ])
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

  /// A failure at each step leaves no host and no live grant behind.
  @MainActor
  func testAWorkroomThatFailsAtEachStepLeavesNoHostAndNoGrant() async throws {
    // The runtime fails `run` only when told to.
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)

    struct Injected: Error {}
    // The step, the environment that fails it, the branch, and whether a grant was made by then.
    let steps: [(String, RemoteProvisioning.Environment, String, Bool)] = [
      ("machine", environment(fixture, driver: driver), "wr-a", false),
      (
        "connect", environment(fixture, driver: driver, connect: { _ in throw Injected() }),
        "wr-b", false
      ),
      (
        "enrol",
        // Nothing listens there, so the agent's enrolment fails after the grant is made.
        environment(fixture, driver: driver, brokerURL: URL(string: "http://127.0.0.1:9")),
        "wr-c", true
      ),
      // git refuses the name only once the workroom is enrolled and cloned.
      ("checkout", environment(fixture, driver: driver), "bad..name", true),
    ]
    for (step, environment, branch, granted) in steps {
      if step == "machine" {
        try "run".write(to: failing, atomically: true, encoding: .utf8)
      } else {
        try? FileManager.default.removeItem(at: failing)
      }
      BrokerStub.reset([Self.grant, Self.cancelled])

      do {
        _ = try await provision(environment, branch: branch)
        XCTFail("a workroom that failed at \(step) was made")
      } catch {
        // The failure is the step's own, so the assertions below are about that step.
        switch (step, error) {
        case ("machine", HostDriverError.provisioning), ("connect", is Injected),
          ("enrol", BrokerError.agent), ("checkout", RemoteProvisioning.Failure.git("switch", _)):
          break
        default: XCTFail("\(step) failed for another reason: \(error)")
        }
      }

      XCTAssertEqual(try leftovers("ps", label: label), [], "a failure at \(step) left a host")
      XCTAssertEqual(
        grantsCancelled, granted ? 1 : 0, "a failure at \(step) left its grant live")
    }
  }

  /// The box authenticates on its own (#252): it clones over https from the fixture's GitHub, and
  /// with the Mac's connection gone it fetches and pushes there, its credential helper minting from
  /// the fixture's broker on the box (`fake-github.py`). Commands run through the runtime's exec,
  /// the provider's control plane, not over the Mac's link.
  @MainActor
  func testAWorkroomFetchesAndPushesWithTheMacDisconnected() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(
      fixture, driver: driver,
      brokerURL: URL(string: ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_BROKER_URL"] ?? "")
    )
    BrokerStub.reset([Self.grant])
    let instance = try await provision(
      environment, branch: "wr-pushed", cloneURL: "https://github.com/origin.git")
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

  /// Signed out of Codaset (#309), a local container workroom clones with the Mac's own GitHub
  /// token, never enrols, and git in it gets credentials through the Mac's relay:
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
    let instance = try await provision(
      environment, branch: "wr-relayed", cloneURL: "https://github.com/origin.git")
    cleanups.append { try? await driver.destroy(instance.host) }
    XCTAssertTrue(instance.relayed)
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

  /// A project's base branch setting: the workroom starts from origin's copy of that branch, not
  /// from the default branch. The branch is made on the host's origin before the clone.
  @MainActor
  func testAWorkroomStartsFromTheProjectsBaseBranch() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    let develop = Develop()

    BrokerStub.reset([Self.grant])
    let instance = try await provision(
      environment, branch: "wr-develop", startBranch: "develop"
    ) { host, grant in
      guard grant == nil else { return }
      let (status, output) = try await driver.exec(
        "git -C /srv/origin.git -c user.name=t -c user.email=t@t commit-tree -p main"
          + " -m develop main^{tree} | xargs git -C /srv/origin.git branch develop"
          + " && git -C /srv/origin.git rev-parse develop", on: host
      ).communicate(nil, timeout: 30)
      XCTAssertEqual(status, 0, output)
      develop.set(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    cleanups.append { try? await driver.destroy(instance.host) }

    let head = try await RemoteProvisioning.git(
      ["rev-parse", "HEAD"], in: instance.path, on: instance.connection)
    XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), develop.get())
  }

  private final class Develop: @unchecked Sendable {
    private let lock = NSLock()
    private var commit: String?
    func set(_ value: String) { lock.withLock { commit = value } }
    func get() -> String? { lock.withLock { commit } }
  }

  /// A base an older build made goes, and its record only once it is gone.
  @MainActor
  func testDestroyingABaseRemovesItAndForgetsItsRecordOnlyOnceItIsGone() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    guard case .remote(let host) = try await driver.create() else { return XCTFail("not remote") }
    let forgotten = Forgotten()

    // Forgetting fails the first time: the box is gone, and a retry gets past the destroy it
    // already did to forget the record.
    do {
      try await RemoteProvisioning.destroyBase(
        host, in: environment, forget: { throw WorkroomCLIError.timedOut })
      XCTFail("a failed forget was swallowed")
    } catch WorkroomCLIError.timedOut {}
    XCTAssertEqual(try leftovers("ps", label: label), [])
    try await RemoteProvisioning.destroyBase(
      host, in: environment, forget: { forgotten.add("forgot") })
    XCTAssertEqual(forgotten.all, ["forgot"])

    // A base this driver never knew (an app relaunched since) keeps its record: nothing has shown
    // it is gone.
    let relaunched = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    do {
      try await RemoteProvisioning.destroyBase(
        host, in: self.environment(fixture, driver: relaunched),
        forget: { forgotten.add("forgot again") })
      XCTFail("an unknown base was destroyed")
    } catch HostDriverError.unknownHost {}
    XCTAssertEqual(forgotten.all, ["forgot"])
  }

  private final class Forgotten: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    func add(_ what: String) { lock.withLock { said.append(what) } }
    var all: [String] { lock.withLock { said } }
  }

  @MainActor
  func testDestroyingAWorkroomWhoseGrantCannotBeCancelledStillRemovesItsBox() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    BrokerStub.reset([Self.grant])
    let workroom = UUID()
    let instance = try await provision(environment, branch: "wr-cancel", workroom: workroom)

    BrokerStub.reset([.init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    do {
      try await RemoteProvisioning.destroy(instance, workroom: workroom, in: environment)
      XCTFail("a failed grant cancel was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, let cleanup) {
      XCTAssertNil(host, "the box is gone, but was reported live")
      XCTAssertEqual(grant, "g1", "the grant still live was not named")
      XCTAssertEqual(cleanup.count, 1, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label), [], "the workroom's box was kept")
  }

  /// Both halves of a workroom's teardown failing are both reported.
  @MainActor
  func testDestroyingAWorkroomReportsBothAFailedCancelAndAFailedRemoval() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    BrokerStub.reset([Self.grant])
    let workroom = UUID()
    let instance = try await provision(environment, branch: "wr-both", workroom: workroom)
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
    let environment = environment(fixture, driver: driver)
    // The checkout fails on its branch name, then the grant cancel and the box's removal fail.
    BrokerStub.reset([Self.grant, .init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    try "rm".write(to: failing, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: failing) }

    do {
      _ = try await provision(environment, branch: "bad..name")
      XCTFail("a workroom with an unusable branch was made")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(
      let cause, let host, let grant, let cleanup)
    {
      XCTAssertTrue(cause.contains("switch"), cause)
      XCTAssertNotNil(host, "the box still up was not named")
      XCTAssertEqual(grant, "g1", "the grant still live was not named")
      XCTAssertEqual(cleanup.count, 2, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the workroom should still be up")
  }

  /// An enrolment whose own grant cancel fails hands that grant to the rollback's report rather
  /// than losing it (#280 review).
  @MainActor
  func testAWorkroomWhoseEnrolmentAndGrantCancelFailNamesTheLiveGrant() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    // Nothing listens there, so the agent's enrolment fails after the grant is made.
    let failing = environment(
      fixture, driver: driver, brokerURL: URL(string: "http://127.0.0.1:9"))
    BrokerStub.reset([Self.grant, .init(status: 503, body: #"{"error":"github_unavailable"}"#)])

    do {
      _ = try await provision(failing, branch: "wr-enrol")
      XCTFail("a workroom that could not enrol was made")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, let cleanup) {
      XCTAssertNil(host, "the box is gone, but was reported live")
      XCTAssertEqual(grant, "g1", "the enrolment's live grant was lost")
      XCTAssertEqual(cleanup.count, 1, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label), [], "the workroom was kept")
  }
}
