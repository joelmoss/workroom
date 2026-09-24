import Darwin
import XCTest

@testable import Workroom

/// A driver's stream with no ssh in it: `wr-agent relay` to a local agent, carried over a
/// socketpair exactly as ssh carries it. Runs wherever `make app-test` does, so CI covers the
/// transport's plumbing; the ssh leg is `RemoteHostIntegrationTests`, against the container.
final class HostStreamTests: XCTestCase {
  private var agents: [AgentHarness] = []

  override func tearDown() {
    for agent in agents { agent.stop() }
    agents.removeAll()
    super.tearDown()
  }

  private func agent() throws -> AgentHarness {
    let agent = try AgentHarness.start()
    agents.append(agent)
    return agent
  }

  private func relay(to socket: String) throws -> HostStream {
    try HostStream.spawn(
      try AgentHarness.binaryURL(), ["relay", "--socket", socket], environment: [:],
      handshakeTimeout: 5)
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  private static func exited(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

  func testRequestsAnswerThroughARelayedStream() async throws {
    let socket = try agent().socketPath
    let host = HostID.remote(UUID())
    let connection = try await AgentVCSConnection.connect(host: host, stream: try relay(to: socket))
    // `connect` already negotiated; this proves the stream keeps carrying traffic after it.
    let reply = try await connection.request(AgentVCSRequest(method: "capabilities"), timeout: 5)
    XCTAssertEqual(try AgentVCSReply<AgentVCSCapabilities>.decode(reply).version, 1)
    await connection.close()
  }

  /// The carrier dying is the link dying: the manager must see the connection go, with no request
  /// in flight to notice it. Without the parent closing its copy of the child's end, the pair never
  /// reads EOF and this waits forever.
  func testACarrierThatDiesIsALostConnection() async throws {
    let socket = try agent().socketPath
    let host = HostID.remote(UUID())
    let stream = try relay(to: socket)
    let manager = HostConnectionManager()
    _ = try await manager.connect(host: host) {
      try await AgentVCSConnection.connect(host: host, stream: stream)
    }
    let connected = await manager.snapshot(for: host).status
    XCTAssertEqual(connected, .connected)
    kill(stream.processIdentifier, SIGKILL)
    let lost = await eventually { await manager.snapshot(for: host).status == .disconnected }
    XCTAssertTrue(lost, "the manager never noticed the carrier die")
  }

  /// A closed connection must not leave its ssh behind.
  func testClosingTheConnectionEndsTheCarrier() async throws {
    let socket = try agent().socketPath
    let stream = try relay(to: socket)
    let connection = try await AgentVCSConnection.connect(host: .remote(UUID()), stream: stream)
    let pid = stream.processIdentifier
    await connection.close()
    let ended = await eventually { Self.exited(pid) }
    XCTAssertTrue(ended, "the carrier outlived its connection")
  }

  /// No agent is the relay's own diagnosis, surfaced as it said it: nothing on a remote host can
  /// be respawned, so `connectionLost` (which `LocalAgentVCS` answers by spawning an agent) would
  /// be the wrong error and would lose the reason.
  func testARelayWithNoAgentFailsWithItsOwnReason() async throws {
    let missing = "/tmp/wr-none-\(UUID().uuidString.prefix(8)).sock"
    let stream = try relay(to: missing)
    do {
      _ = try await AgentVCSConnection.connect(host: .remote(UUID()), stream: stream)
      XCTFail("connected to nothing")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("no agent listening"), detail)
    }
    let ended = await eventually { Self.exited(stream.processIdentifier) }
    XCTAssertTrue(ended)
  }

  func testTheSSHConfigurationCannotPromptOrForwardAnything() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = ContainerHostDriver.Host(
      address: "127.0.0.1", port: 2222, user: "workroom", identityFile: "/keys/id",
      hostKey: "ssh-ed25519 AAAAC3Nza", agentSocket: "/run/workroom/agent.sock")
    let config = try String(
      contentsOf: ContainerHostDriver.writeConfiguration(for: host, in: directory),
      encoding: .utf8)
    for line in [
      "BatchMode yes", "StrictHostKeyChecking yes", "GlobalKnownHostsFile /dev/null",
      "IdentitiesOnly yes", "IdentityAgent none",
      "ForwardAgent no", "ClearAllForwardings yes", "ServerAliveInterval 15",
      "EscapeChar none",
    ] {
      XCTAssertTrue(config.contains("  \(line)\n"), "missing \(line)")
    }
    XCTAssertFalse(config.contains("SendEnv"))
    let known = try String(
      contentsOf: directory.appendingPathComponent("known_hosts"), encoding: .utf8)
    XCTAssertEqual(known, "[127.0.0.1]:2222 ssh-ed25519 AAAAC3Nza\n")
  }

  /// A value is written into `ssh_config`, where a newline would start a directive of its own.
  func testAConfigurationValueCannotInjectADirective() {
    let host = ContainerHostDriver.Host(
      address: "127.0.0.1\n  ProxyCommand touch /tmp/owned", port: 22, user: "workroom",
      identityFile: "/keys/id", hostKey: "ssh-ed25519 AAAA", agentSocket: "/run/a.sock")
    XCTAssertThrowsError(
      try ContainerHostDriver.writeConfiguration(
        for: host, in: FileManager.default.temporaryDirectory))
  }

  /// A remote pane's command (#229): the session contract rides in `env` on the host, and the
  /// Mac-only parts of it (the shell, the app bundle's resources) stay behind.
  func testARemotePanesCommandCarriesTheSessionAndNothingOfTheMacs() throws {
    let session = UUID()
    let fresh = ContainerHostDriver.remoteAttachCommand(
      session: session, socket: "/run/workroom/agent.sock",
      workingDirectory: "/home/w/it's here", restored: false)
    XCTAssertEqual(
      fresh,
      "'env' 'TERM=xterm-256color' 'WORKROOM_SESSION_ID=\(session.uuidString)' "
        + "'WORKROOM_SESSION_SOCKET=/run/workroom/agent.sock' "
        + "'WORKROOM_SESSION_CWD=/home/w/it'\\''s here' 'wr-agent' 'attach' '--no-spawn'")
    let restored = ContainerHostDriver.remoteAttachCommand(
      session: session, socket: "/s", workingDirectory: "/w", restored: true)
    XCTAssertTrue(restored.hasSuffix("'--no-spawn' '--no-create'"), restored)
    for absent in ["WORKROOM_SESSION_SHELL", "WORKROOM_SESSION_RESOURCES", "AWAKE"] {
      XCTAssertFalse(fresh.contains(absent), absent)
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let driver = ContainerHostDriver(
      hosts: [
        id: .init(
          address: "127.0.0.1", port: 2222, user: "workroom", identityFile: "/keys/id",
          hostKey: "ssh-ed25519 AAAA", agentSocket: "/s")
      ], directory: directory)
    let command = try driver.attachCommand(
      to: .remote(id), session: session, workingDirectory: "/w", restored: true)
    XCTAssertTrue(command.hasPrefix("'/usr/bin/ssh' '-F' "), command)
    XCTAssertTrue(command.contains(" '-t' 'workroom-host' "), command)
  }

  /// A remote session is routed to its driver, not to a local helper: its command is the driver's,
  /// the pane's own environment carries no session variables, and a restored pane is not asked
  /// about locally (the host's agent answers that, in the attach).
  @MainActor
  func testARemoteSessionIsRoutedToItsDriverNotALocalHelper() async throws {
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "none here") },
      ownership: { _ in
        XCTFail("a local helper was asked about a remote session")
        return .notOwned
      })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = UUID()
    let driver = ContainerHostDriver(
      hosts: [
        host: .init(
          address: "127.0.0.1", port: 2222, user: "workroom", identityFile: "/keys/id",
          hostKey: "ssh-ed25519 AAAA", agentSocket: "/s")
      ], directory: directory)
    let session = UUID()
    service.registerRemoteSession(
      session, on: .remote(host), via: driver, workingDirectory: "/home/w")

    XCTAssertEqual(service.confirmBeforeAttach(sessionID: session, wasRestored: true), .attachable)
    let command = try XCTUnwrap(service.attachCommand(forSession: session, restored: true))
    XCTAssertTrue(command.contains("/usr/bin/ssh"), command)
    XCTAssertTrue(command.contains("--no-create"), command)
    XCTAssertTrue(service.launchEnvironment(sessionID: session, workingDirectory: "/w").isEmpty)

    // A host the driver cannot reach gets a pane that says so, never a plain shell on this Mac.
    let stranded = UUID()
    service.registerRemoteSession(
      stranded, on: .remote(UUID()), via: driver, workingDirectory: "/home/w")
    let notice = try XCTUnwrap(service.attachCommand(forSession: stranded))
    XCTAssertTrue(notice.hasPrefix("/bin/sh -c "), notice)
    XCTAssertTrue(notice.contains("Could not reach this terminal"), notice)

    // Closing it reaches no local helper (the ownership closure above fails the test if asked),
    // and reports it not killed, which is true.
    let killed = await service.endSession(sessionID: session)
    XCTAssertFalse(killed)
    XCTAssertFalse(service.isRemote(session))
  }

  func testTheRelayCommandQuotesItsSocketForTheRemoteShell() {
    XCTAssertEqual(
      ContainerHostDriver.relayCommand(socket: "/run/it's here/a.sock"),
      "wr-agent relay --socket '/run/it'\\''s here/a.sock'")
  }
}
