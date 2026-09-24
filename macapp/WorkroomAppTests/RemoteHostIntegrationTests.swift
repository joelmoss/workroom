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
        agentSocket: try need("WR_SSH_FIXTURE_SOCKET")))
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

  /// VCS reads, File, Status and Forward, all through one ssh-stdio connection and the same manager
  /// and router the app uses.
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

    // Writes are refused by name, not attempted: see `AgentVCSConnection.writer`.
    do {
      _ = try await router.writer(for: location)
      XCTFail("a remote writer was handed out")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("remote repository"), detail)
    }

    // File.
    let files = try connection.files(
      context: FileContext(location: location, sharedLocation: nil))
    let listing = try await files.list(.git)
    XCTAssertEqual(FileListing.parse(listing.stdout, vcs: .git), ["file"])
    let data = try await files.read(path: "file", symlinks: .refuse, maxBytes: 100)
    XCTAssertEqual(data, Data("base\n".utf8))

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
