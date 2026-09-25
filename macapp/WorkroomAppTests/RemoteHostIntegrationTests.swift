import Darwin
import XCTest

@testable import Workroom

/// The app's half of the remote path against a real host (#229): `ContainerHostDriver` over ssh
/// into the container fixture, driven by the real Swift clients. Skipped unless run through the
/// fixture script, which starts the container and says where it is:
///
///     vcs/scripts/ssh-fixture/run.sh <linux wr-agent> \
///       make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/RemoteHostIntegrationTests
///
/// The macOS CI runners have no Docker, so CI covers the stream without ssh (`HostStreamTests`)
/// and the ssh leg from Rust (`remote_transport.rs`, on the Linux runner).
final class RemoteHostIntegrationTests: XCTestCase {
  private var directory: URL!
  private var connections: [AgentVCSConnection] = []

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-remote-\(UUID().uuidString.prefix(8))")
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private struct Fixture {
    let config: String
    let host: ContainerHostDriver.Host
    /// The Linux agent the fixture was built around: what the bootstrap tests push as the app's
    /// bundled one, since a Debug build carries none.
    let agent: URL
  }

  private func fixture() throws -> Fixture {
    let environment = ProcessInfo.processInfo.environment
    func need(_ name: String) throws -> String {
      guard let value = environment[name], !value.isEmpty else {
        throw XCTSkip("\(name) is unset; run these through vcs/scripts/ssh-fixture/run.sh")
      }
      return value
    }
    return Fixture(
      config: try need("WR_SSH_FIXTURE_CONFIG"),
      host: ContainerHostDriver.Host(
        address: try need("WR_SSH_FIXTURE_ADDRESS"),
        port: Int(try need("WR_SSH_FIXTURE_PORT")) ?? 0,
        user: try need("WR_SSH_FIXTURE_USER"),
        identityFile: try need("WR_SSH_FIXTURE_IDENTITY"),
        hostKey: try need("WR_SSH_FIXTURE_HOST_KEY"),
        agentSocket: try need("WR_SSH_FIXTURE_SOCKET")),
      agent: URL(fileURLWithPath: try need("WR_SSH_FIXTURE_AGENT")))
  }

  private func connect(_ host: ContainerHostDriver.Host) async throws -> (
    AgentVCSConnection, UUID
  ) {
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: host], directory: directory)
    let connection = try await AgentVCSConnection.connect(
      host: .remote(id), stream: try await driver.openStream(to: .remote(id)))
    connections.append(connection)
    return (connection, id)
  }

  /// Runs `command` on the fixture over the script's own ssh, to set the host up. Not through the
  /// driver, so a setup step can never be the thing under test.
  @discardableResult
  private func onHost(_ fixture: Fixture, _ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-F", fixture.config, "fixture", command]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      XCTFail("on the host, \(command) failed: \(text)")
      throw VCSError.io(text)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A git repository on the host, with its identity in the repository's own config: the host has
  /// no global one, and nothing from the Mac supplies it.
  private func repository(_ fixture: Fixture) throws -> String {
    let path = "/home/workroom/repo-\(UUID().uuidString.prefix(8))"
    try onHost(
      fixture,
      """
      set -e; git init -q -b main \(path); cd \(path)
      git config user.name Remote; git config user.email remote@example.com
      echo base > file; git add .; git commit -qm initial
      """)
    return path
  }

  /// VCS reads and writes, File, Status and Forward, all through one ssh-stdio connection and the
  /// same manager and router the app uses.
  func testEveryServiceAnswersThroughTheDriversStream() async throws {
    let fixture = try fixture()
    let path = try repository(fixture)
    let (connection, id) = try await connect(fixture.host)
    let host = HostID.remote(id)
    let manager = HostConnectionManager()
    _ = try await manager.connect(host: host) { connection }
    let router = RepositoryRouter(connections: manager)
    let location = try RepositoryLocation.remote(host: id, path: path)
    try router.register(.init(location: location, backend: .git, sharedLocation: location))

    // VCS reads.
    let reader = try await router.reader(for: location)
    let ref = try await reader.currentRef()
    XCTAssertEqual(ref, VCSRef(name: "main", kind: .branch))
    let page = try await reader.log(limit: 5)
    XCTAssertEqual(page.commits.map(\.summary), ["initial"])

    // A VCS write, through the exec service in the host's environment.
    try onHost(fixture, "echo next > \(path)/file")
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(
        message: "remote commit",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)],
        mode: .commit))
    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(
      try onHost(fixture, "git -C \(path) log -1 --format='%s %ae'"),
      "remote commit remote@example.com")

    // File.
    let files = try connection.files(
      context: FileContext(location: location, sharedLocation: nil))
    let listing = try await files.list(.git)
    XCTAssertEqual(FileListing.parse(listing.stdout, vcs: .git), ["file"])
    let data = try await files.read(path: "file", symlinks: .refuse, maxBytes: 100)
    XCTAssertEqual(data, Data("next\n".utf8))

    // Status.
    _ = try await connection.wakefulness().status()

    // Forward, to a process listening in the container: its own sshd, which speaks first.
    let forward = try connection.forwarding().listen(remotePort: 22) { _ in }
    defer { forward.stop() }
    let client = try TCPClient(port: forward.localPort)
    defer { client.close() }
    let banner = String(decoding: try client.read(8, timeout: 10), as: UTF8.self)
    XCTAssertEqual(banner, "SSH-2.0-")
  }

  /// A failed remote write is classified from the HOST's disk (#229): a leftover `index.lock` there
  /// is named by its path on the host. Read from this Mac's disk, that path is not there, and the
  /// failure would name no lock at all.
  func testARemoteCommitBlockedByALockNamesTheLockOnTheHost() async throws {
    let fixture = try fixture()
    let path = try repository(fixture)
    try onHost(fixture, "echo next > \(path)/file && touch \(path)/.git/index.lock")
    let (connection, id) = try await connect(fixture.host)
    let host = HostID.remote(id)
    let manager = HostConnectionManager()
    _ = try await manager.connect(host: host) { connection }
    let router = RepositoryRouter(connections: manager)
    let location = try RepositoryLocation.remote(host: id, path: path)
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(
        message: "blocked",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)],
        mode: .commit))
    guard case .failed(.locked(let lock)) = result else {
      return XCTFail("expected a lock failure, got \(result)")
    }
    XCTAssertEqual(lock?.path, "\(path)/.git/index.lock")
  }

  /// A pane's process, running the command the driver hands libghostty, with its output collected.
  /// Run through `/bin/sh -c`, as libghostty runs a pane's command. No local terminal, so ssh
  /// allocates none on the host either, and the attach there relays over pipes, as the Rust
  /// harnesses' do.
  private final class Pane: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var seen = ""
    /// From `terminationHandler`: `waitUntilExit`/`isRunning` are not reliable for a process
    /// launched from an async test (see `HostStream.spawn`).
    private var exited: Int32?

    init(command: String) throws {
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = [:]
      process.standardInput = input
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      output.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          handle.readabilityHandler = nil
          return
        }
        self?.lock.withLock { self?.seen += String(decoding: data, as: UTF8.self) }
      }
      process.terminationHandler = { [weak self] finished in
        self?.lock.withLock { self?.exited = finished.terminationStatus }
      }
      try process.run()
    }

    func type(_ text: String) { input.fileHandleForWriting.write(Data(text.utf8)) }

    func read(until needle: String, within seconds: TimeInterval = 20) -> String {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline, !lock.withLock({ seen.contains(needle) }) {
        Thread.sleep(forTimeInterval: 0.05)
      }
      return lock.withLock { seen }
    }

    /// The link dropping hard: ssh killed, with no goodbye to the host.
    func dropLink() {
      // Never a pid already reaped, which may be someone else's by now.
      guard lock.withLock({ exited == nil }) else { return }
      kill(process.processIdentifier, SIGKILL)
      _ = exitCode(within: 10)
    }

    /// ssh's exit status, which is the attach's: the shell's own once it exits, or 255 for a
    /// lost link. Nil while it is still running at the deadline.
    func exitCode(within seconds: TimeInterval) -> Int32? {
      let deadline = Date().addingTimeInterval(seconds)
      while lock.withLock({ exited }) == nil, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      return lock.withLock { exited }
    }
  }

  /// The supervised agent's pid on the fixture, by argv0: the installed binary, or the staged
  /// file a hand-off exec'd. Not `pkill -x wr-agent`, which misses the latter.
  private static let supervisedAgent = "pgrep -f '^/run/workroom/wr-agent[^ ]* serve'"

  /// A "bundled" agent for a bootstrap test: a file written beside the fixture's ELF.
  private func bundledAgent(named name: String, _ contents: Data) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try contents.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  /// The app's first connect to a host with no agent (#231): the bootstrap installs the one this
  /// build bundles for the host's architecture, the supervisor starts it, and the services answer
  /// through it. The fixture models the host by having its installed agent removed and killed;
  /// its supervisor then idles until something is installed.
  func testAHostWithNoAgentGetsThisBuildInstalledAndConnects() async throws {
    let fixture = try fixture()
    try onHost(
      fixture,
      "rm -f /run/workroom/wr-agent; \(Self.supervisedAgent.replacingOccurrences(of: "pgrep", with: "pkill")) || true"
    )
    let gone = Date().addingTimeInterval(10)
    while try onHost(fixture, "\(Self.supervisedAgent) || true") != "", Date() < gone {
      Thread.sleep(forTimeInterval: 0.2)
    }
    XCTAssertEqual(try onHost(fixture, "\(Self.supervisedAgent) || true"), "")
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: fixture.host], directory: directory)
    let outcome = try await AgentBootstrap.ensure(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in fixture.agent }, handOff: true)
    XCTAssertTrue(outcome.pushed)
    XCTAssertEqual(outcome.agent, .installed)
    let connection = try await AgentBootstrap.connect(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in fixture.agent }, handOff: true)
    connections.append(connection)
    _ = try await connection.wakefulness().status()
  }

  /// Connecting again with the same build pushes nothing: the probe finds the file, and the
  /// running agent answers that it is current. Self-contained, whatever an earlier test left
  /// running: the first `ensure` gets the host to this build, the second is the one measured.
  func testConnectingAgainWithTheSameBuildPushesNothing() async throws {
    let fixture = try fixture()
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: fixture.host], directory: directory)
    _ = try await AgentBootstrap.ensure(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in fixture.agent }, handOff: true)
    let again = try await AgentBootstrap.ensure(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in fixture.agent }, handOff: true)
    XCTAssertEqual(again, .init(architecture: again.architecture, pushed: false, agent: .current))
  }

  /// A newer app reconnecting (#231): the host's agent is handed off to the pushed binary (#230)
  /// with an attached pane's shell, its pid and its exit code intact. The pane's link ends with
  /// the exec and it exits 255, which is what the app reattaches on; the pane that comes back is
  /// repainted by the new program and reaches the same shell.
  func testANewerAppHandsOffAndAnAttachedPaneComesBack() async throws {
    let fixture = try fixture()
    // The same ELF with a byte appended: the loader ignores it, and both hashes notice.
    let newer = try bundledAgent(
      named: "wr-agent-newer", try Data(contentsOf: fixture.agent) + Data("\n".utf8))
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: fixture.host], directory: directory)
    // Whatever build is there, get it to the fixture's ELF first, so the hand-off below is real.
    _ = try await AgentBootstrap.ensure(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in fixture.agent }, handOff: true)
    let session = UUID()
    let first = try Pane(
      command: driver.attachCommand(
        to: .remote(id), session: session, workingDirectory: "/home/workroom", restored: false))
    defer { first.dropLink() }
    Thread.sleep(forTimeInterval: 1)
    first.type("echo PID=$$; echo READ\"\"Y\n")
    let before = first.read(until: "READY")
    let pid = try XCTUnwrap(
      before.range(of: #"PID=\d+"#, options: .regularExpression).map { String(before[$0]) },
      before)

    let outcome = try await AgentBootstrap.ensure(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in newer }, handOff: true)
    XCTAssertEqual(outcome.agent, .handedOff)
    XCTAssertTrue(outcome.pushed)
    XCTAssertEqual(first.exitCode(within: 10), 255)

    let second = try Pane(
      command: driver.attachCommand(
        to: .remote(id), session: session, workingDirectory: "/home/workroom", restored: true))
    defer { second.dropLink() }
    let repainted = second.read(until: "READY")
    XCTAssertTrue(repainted.contains(pid), repainted)
    Thread.sleep(forTimeInterval: 0.5)
    second.type("echo NOW=$$ DO\"\"NE; exit 7\n")
    let after = second.read(until: "DONE")
    XCTAssertTrue(after.contains("NOW=\(pid.dropFirst(4)) DONE"), after)
    XCTAssertEqual(second.exitCode(within: 10), 7)
  }

  /// Refuse rather than kill (#231): a pushed binary that fails the restore check leaves the old
  /// agent running, with its sessions, and the app connects to it. Here the binary runs on the
  /// host (`protocol` answers, and `hand-off` asks, both handed to the installed agent) but its
  /// `handoff-check` fails, so the agent refuses it.
  func testABinaryThatFailsItsCheckLeavesTheOldAgentRunningAndConnects() async throws {
    let fixture = try fixture()
    let broken = try bundledAgent(
      named: "wr-agent-broken",
      Data(
        """
        #!/bin/sh
        case $1 in protocol|hand-off) exec /run/workroom/wr-agent "$@" ;; esac
        exit 1

        """.utf8))
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: fixture.host], directory: directory)
    let agentBefore = try onHost(fixture, Self.supervisedAgent)
    let outcome = try await AgentBootstrap.ensure(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in broken }, handOff: true)
    XCTAssertTrue(outcome.pushed)
    guard case .keptOlder(let why) = outcome.agent else { return XCTFail("\(outcome)") }
    XCTAssertTrue(why.hasPrefix("refused: ") && why.contains("cannot restore"), why)
    XCTAssertEqual(try onHost(fixture, Self.supervisedAgent), agentBefore)
    // The same pid is also what a hand-off keeps, so the file is what tells the two apart.
    XCTAssertEqual(
      try onHost(fixture, "sha256sum < /run/workroom/wr-agent | cut -c1-64"),
      try AgentBootstrap.digest(of: fixture.agent))
    // Nothing staged is left where the supervisor starts from.
    XCTAssertEqual(
      try onHost(fixture, "ls /run/workroom/wr-agent.new.* 2>/dev/null || echo none"), "none")
    let connection = try await AgentBootstrap.connect(
      host: .remote(id), driver: driver, socket: fixture.host.agentSocket,
      agent: { _ in broken }, handOff: true)
    connections.append(connection)
    _ = try await connection.wakefulness().status()
  }

  /// The app half of the Phase 3 acceptance (#229): a pane attached through the driver keeps its
  /// session across a dropped link, and the pane that comes back (a reconnect after sleep, or a
  /// relaunch) reaches the SAME shell: its pid, and a variable set before the drop.
  func testARemotePaneSurvivesADroppedLinkAndReachesTheSameShell() throws {
    let fixture = try fixture()
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: fixture.host], directory: directory)
    let session = UUID()

    let first = try Pane(
      command: driver.attachCommand(
        to: .remote(id), session: session, workingDirectory: "/home/workroom", restored: false))
    defer { first.dropLink() }
    Thread.sleep(forTimeInterval: 1)
    // Quotes split each marker, so the terminal echoing the typed line cannot satisfy the wait.
    first.type("MARK=kept; echo PID=$$; echo READ\"\"Y\n")
    let before = first.read(until: "READY")
    let pid = try XCTUnwrap(
      before.range(of: #"PID=\d+"#, options: .regularExpression).map { String(before[$0]) },
      before)
    first.dropLink()

    let second = try Pane(
      command: driver.attachCommand(
        to: .remote(id), session: session, workingDirectory: "/home/workroom", restored: true))
    defer { second.dropLink() }
    Thread.sleep(forTimeInterval: 1)
    second.type("echo VALUE=$MARK PID=$$ DO\"\"NE\n")
    let after = second.read(until: "DONE")
    XCTAssertTrue(after.contains("VALUE=kept \(pid) DONE"), after)
    XCTAssertFalse(after.contains("has ended"), after)
  }

  /// A restored pane whose session ended on the host gets a shell that says so, never a fresh
  /// session passed off as the old one: the host's agent refuses to create it (`--no-create`).
  func testARestoredPaneWhoseSessionEndedGetsAShellThatSaysSo() throws {
    let fixture = try fixture()
    let id = UUID()
    let driver = ContainerHostDriver(hosts: [id: fixture.host], directory: directory)
    let pane = try Pane(
      command: driver.attachCommand(
        to: .remote(id), session: UUID(), workingDirectory: "/home/workroom", restored: true))
    defer { pane.dropLink() }
    let seen = pane.read(until: "has ended")
    XCTAssertTrue(seen.contains("has ended"), seen)
  }

  /// Nothing from the Mac's environment reaches a remote git (#229): the child runs with the
  /// host's `HOME` and `PATH`, no `SSH_AUTH_SOCK`, and no way for ssh to prompt. Read back from the
  /// child itself, through a git alias that prints its environment.
  func testARemoteCommandRunsInTheHostsEnvironmentNotTheMacs() async throws {
    let fixture = try fixture()
    let path = try repository(fixture)
    let (connection, _) = try await connect(fixture.host)
    let result = await AgentCommandRunner(connection: connection).runNetwork(
      "git", ["-c", "alias.environment=!env", "environment"], in: path, timeout: 20)
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    let environment = Dictionary(
      result.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return (String(line[..<equals]), String(line[line.index(after: equals)...]))
      }, uniquingKeysWith: { first, _ in first })
    XCTAssertEqual(environment["HOME"], "/home/workroom")
    XCTAssertEqual(environment["LC_ALL"], "C")
    XCTAssertNil(environment["SSH_AUTH_SOCK"])
    // Not set: it would outrank a repository's own `core.sshCommand` (see `host_environment`).
    XCTAssertNil(environment["GIT_SSH_COMMAND"])
    XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "never")
    let mac = ProcessInfo.processInfo.environment
    for key in ["HOME", "PATH", "USER"] {
      if let value = mac[key] {
        XCTAssertNotEqual(environment[key], value, "the Mac's \(key) reached the host")
      }
    }
  }

  /// A host key that is not the pinned one fails the connection, closed and at once: `BatchMode`
  /// means there is no prompt to hang on, and the error says why.
  func testAMismatchedHostKeyFailsClosedWithoutAPrompt() async throws {
    let fixture = try fixture()
    // A well-formed ed25519 key that is not the host's: the client's own.
    let impostor = try String(
      contentsOfFile: fixture.host.identityFile + ".pub", encoding: .utf8
    ).split(separator: " ").prefix(2).joined(separator: " ")
    let host = ContainerHostDriver.Host(
      address: fixture.host.address, port: fixture.host.port, user: fixture.host.user,
      identityFile: fixture.host.identityFile, hostKey: impostor,
      agentSocket: fixture.host.agentSocket)
    let started = ContinuousClock.now
    do {
      _ = try await connect(host)
      XCTFail("connected to a host whose key is not the pinned one")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("Host key verification failed"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
  }

  /// The supervised agent is reached, not started: the relay fails fast with its own reason when
  /// nothing listens at the socket the host was configured with.
  func testAHostWithNoAgentAtItsSocketSaysSo() async throws {
    let fixture = try fixture()
    let host = ContainerHostDriver.Host(
      address: fixture.host.address, port: fixture.host.port, user: fixture.host.user,
      identityFile: fixture.host.identityFile, hostKey: fixture.host.hostKey,
      agentSocket: "/run/workroom/nothing.sock")
    do {
      _ = try await connect(host)
      XCTFail("connected to an agent that is not there")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("no agent listening"), detail)
    }
  }
}
