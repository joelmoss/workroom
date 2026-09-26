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
  /// Mac-only parts of it (the shell, the app bundle's paths) stay behind. The terminal type and
  /// the shell integration are the host's set's, when it has one (#239).
  func testARemotePanesCommandCarriesTheSessionAndNothingOfTheMacs() throws {
    let session = UUID()
    let fresh = ContainerHostDriver.remoteAttachCommand(
      binary: "/run/workroom/wr-agent", session: session, socket: "/run/workroom/agent.sock",
      resources: "/run/workroom/ghostty", workingDirectory: "/home/w/it's here", restored: false)
    XCTAssertEqual(
      fresh,
      "test -x '/run/workroom/wr-agent' || { echo "
        + "'workroom: no agent is installed at /run/workroom/wr-agent yet' >&2; exit 255; }; "
        + "if test -r '/run/workroom/ghostty/terminfo/x/xterm-ghostty'; then set -- "
        + "'TERM=xterm-ghostty' 'TERMINFO=/run/workroom/ghostty/terminfo' "
        + "'WORKROOM_SESSION_RESOURCES=/run/workroom/ghostty' "
        + "'GHOSTTY_SHELL_FEATURES=cursor,sudo,title'; else unset WORKROOM_SESSION_RESOURCES "
        + "GHOSTTY_SHELL_FEATURES; set -- 'TERM=xterm-256color'; fi; "
        + "'env' \"$@\" 'WORKROOM_SESSION_ID=\(session.uuidString)' "
        + "'WORKROOM_SESSION_SOCKET=/run/workroom/agent.sock' "
        + "'WORKROOM_SESSION_CWD=/home/w/it'\\''s here' '/run/workroom/wr-agent' 'attach' "
        + "'--no-spawn'")
    let restored = ContainerHostDriver.remoteAttachCommand(
      binary: "/b", session: session, socket: "/s", resources: "/r", workingDirectory: "/w",
      restored: true)
    XCTAssertTrue(restored.hasSuffix("'--no-spawn' '--no-create'"), restored)
    for absent in ["WORKROOM_SESSION_SHELL", "AWAKE", "Contents/Resources"] {
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
    let log = ContainerHostDriver.attachLog(
      session, in: directory.appendingPathComponent(id.uuidString)
    ).path
    XCTAssertTrue(
      command.hasPrefix("'/bin/sh' '-c' ")
        && command.contains(" 'workroom-attach' '\(log)' '/usr/bin/ssh' '-F' "), command)
    XCTAssertTrue(command.contains(" '-E' '\(log)' "), command)
    XCTAssertTrue(command.contains(" '-t' 'workroom-host' "), command)
  }

  /// A pane's attach to a host that is not there (#241): it says what it is waiting for, then
  /// ssh's own reason, and exits 255; and the driver does not read that reason as a refusal, so
  /// its pane keeps retrying.
  func testAnUnreachableHostsAttachSaysSoAndIsNotReadAsARefusal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    // Port 1 on loopback: nothing listens, so the connect is refused at once.
    let driver = ContainerHostDriver(
      hosts: [
        id: .init(
          address: "127.0.0.1", port: 1, user: "workroom", identityFile: "/keys/id",
          hostKey: "ssh-ed25519 AAAA", agentSocket: "/s")
      ], directory: directory)
    let session = UUID()
    let attach = try SessionBackendProbe.run(
      URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        try driver.attachCommand(
          to: .remote(id), session: session, workingDirectory: "/w", restored: true),
      ], timeout: 15)
    XCTAssertEqual(attach.status, 255, attach.output)
    XCTAssertTrue(
      attach.output.hasPrefix("\u{1b}7workroom: waiting for this terminal's host...\r\n"),
      attach.output)
    XCTAssertTrue(attach.output.contains("Connection refused"), attach.output)
    let log = try String(
      contentsOf: ContainerHostDriver.attachLog(
        session, in: directory.appendingPathComponent(id.uuidString)),
      encoding: .utf8)
    XCTAssertTrue(log.contains("Connection refused"), log)
    XCTAssertFalse(driver.hostRefusedLastAttach(of: session, on: .remote(id)))
  }

  /// ssh's wording for a host that answered and will keep refusing, which stops a pane's retries,
  /// against the failures that heal and must not (#241), on the Mac and on Linux. An empty log is
  /// one of those: a host that accepts and closes before its banner leaves ssh nothing to say at
  /// `LogLevel ERROR`, and so does a far side that itself exited 255.
  func testOnlyAHostThatRefusesForGoodReadsAsARefusal() {
    for refusal in [
      "Host key verification failed.",
      "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @",
      "workroom@127.0.0.1: Permission denied (publickey).",
      "Received disconnect from 10.0.0.9 port 22:2: Too many authentication failures",
      "Unable to negotiate with 10.0.0.9 port 22: no matching host key type found.",
      "Load key \"/keys/id\": invalid format",
      "Bad owner or permissions on /keys/config",
    ] {
      XCTAssertTrue(ContainerHostDriver.isRefusal(refusal), refusal)
    }
    for heals in [
      "",
      "ssh: connect to host 10.0.0.9 port 22: Operation timed out",
      "ssh: connect to host 10.0.0.9 port 22: Connection timed out",
      "ssh: connect to host 127.0.0.1 port 2222: Connection refused",
      "ssh: connect to host 10.0.0.9 port 22: No route to host",
      "ssh: connect to host 10.0.0.9 port 22: Network is unreachable",
      "ssh: connect to host 10.0.0.9 port 22: Permission denied",
      "ssh: Could not resolve hostname box.example: nodename nor servname provided, or not known",
      "kex_exchange_identification: read: Connection reset by peer",
      "Connection timed out during banner exchange",
      "client_loop: send disconnect: Broken pipe",
    ] {
      XCTAssertFalse(ContainerHostDriver.isRefusal(heals), heals)
    }
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
    // Still remote: the session runs on, and a retry or a reattach must not go local.
    XCTAssertTrue(service.isRemote(session))
    let again = await service.endSession(sessionID: session)
    XCTAssertFalse(again)
    XCTAssertTrue(
      service.attachCommand(forSession: session, restored: true)?.contains("/usr/bin/ssh") == true)
  }

  /// Why a carrier ended, read from its termination handler (#231 moved it off `isRunning` and
  /// `terminationStatus`): its own exit status, our SIGTERM, or still running when the wait gave up.
  func testAFailedCarrierSaysHowItEnded() async throws {
    let exited = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 7"], environment: [:], handshakeTimeout: 5)
    let said = await exited.failure()
    XCTAssertEqual(said, "sh exited with status 7")
    // `exec`, so the process ended is the one holding the stderr pipe.
    let ended = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "exec sleep 30"], environment: [:],
      handshakeTimeout: 5)
    ended.end()
    let asked = ContinuousClock.now
    let stopped = await ended.failure()
    XCTAssertEqual(stopped, "sh did not answer in time")
    // Promptly, from the recorded exit: `failure()` says the same of a carrier still running,
    // after its 2 s wait, which is what an `end()` that did nothing would look like.
    XCTAssertLessThan(ContinuousClock.now - asked, .seconds(1))
    let running = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "exec sleep 30"], environment: [:],
      handshakeTimeout: 5)
    defer { running.end() }
    let waited = await running.failure()
    XCTAssertEqual(waited, "sh did not answer in time")
  }

  /// The binary is derived from the socket and run by path from any cwd, so a relative socket is
  /// refused before anything is written.
  func testARelativeAgentSocketIsRefused() {
    let host = ContainerHostDriver.Host(
      address: "127.0.0.1", port: 22, user: "workroom", identityFile: "/keys/id",
      hostKey: "ssh-ed25519 AAAA", agentSocket: "run/agent.sock")
    XCTAssertThrowsError(
      try ContainerHostDriver.writeConfiguration(
        for: host, in: FileManager.default.temporaryDirectory)
    ) {
      XCTAssertEqual(
        $0 as? HostDriverError,
        .invalidConfiguration("agent socket must be an absolute path"))
    }
  }

  /// A remote pane's command, run by a shell: with no agent installed it exits 255, ssh's status
  /// for a lost link, which the app reattaches on, and says why; with one it runs the attach.
  func testARemotePanesCommandExits255UntilAnAgentIsInstalled() throws {
    let missing = "/nonexistent-\(UUID().uuidString.prefix(8))/wr-agent"
    let absent = try SessionBackendProbe.run(
      URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        ContainerHostDriver.remoteAttachCommand(
          binary: missing, session: UUID(), socket: "/s", resources: "/r", workingDirectory: "/w",
          restored: true),
      ], timeout: 5)
    XCTAssertEqual(absent.status, 255)
    XCTAssertTrue(absent.output.contains("no agent is installed at \(missing)"), absent.output)
    let present = try SessionBackendProbe.run(
      URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        ContainerHostDriver.remoteAttachCommand(
          binary: "/usr/bin/true", session: UUID(), socket: "/s", resources: "/r",
          workingDirectory: "/w", restored: false),
      ], timeout: 5)
    XCTAssertEqual(present.status, 0, present.output)
  }

  /// A remote pane's terminal, run by a shell (#239): `xterm-ghostty` with the shell integration
  /// once the host holds the resource set, and `xterm-256color` without it on a host that does
  /// not, as before the set was pushed.
  func testARemotePaneIsAGhosttyTerminalOnlyOnAHostHoldingTheSet() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-set-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("ghostty")
    // Stands in for the agent: prints what it was started with.
    let binary = root.appendingPathComponent("wr-agent")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(
      "#!/bin/sh\necho \"TERM=$TERM TERMINFO=${TERMINFO-} RESOURCES=${WORKROOM_SESSION_RESOURCES-} FEATURES=${GHOSTTY_SHELL_FEATURES-}\"\n"
        .utf8
    ).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    func attach() throws -> String {
      // A clean environment, as ssh gives the host's shell: the app host exports `TERMINFO`.
      let result = try SessionBackendProbe.run(
        URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [
          "-i", "PATH=/usr/bin:/bin", "WORKROOM_SESSION_RESOURCES=/stale",
          "GHOSTTY_SHELL_FEATURES=stale", "/bin/sh", "-c",
          ContainerHostDriver.remoteAttachCommand(
            binary: binary.path, session: UUID(), socket: "/s", resources: resources.path,
            workingDirectory: "/w", restored: false),
        ], timeout: 5)
      XCTAssertEqual(result.status, 0, result.output)
      return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    XCTAssertEqual(try attach(), "TERM=xterm-256color TERMINFO= RESOURCES= FEATURES=")
    let entry = resources.appendingPathComponent("terminfo/x")
    try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
    try Data().write(to: entry.appendingPathComponent("xterm-ghostty"))
    XCTAssertEqual(
      try attach(),
      "TERM=xterm-ghostty TERMINFO=\(resources.path)/terminfo RESOURCES=\(resources.path) "
        + "FEATURES=cursor,sudo,title")
  }

  func testAnUnknownHostIsRefusedByExecAndOpenStream() async {
    let driver = ContainerHostDriver(hosts: [:], directory: FileManager.default.temporaryDirectory)
    let host = HostID.remote(UUID())
    do {
      _ = try await driver.exec("true", on: host)
      XCTFail("exec reached an unknown host")
    } catch {
      XCTAssertEqual(error as? HostDriverError, .unknownHost(host))
    }
    do {
      _ = try await driver.openStream(to: host)
      XCTFail("openStream reached an unknown host")
    } catch {
      XCTAssertEqual(error as? HostDriverError, .unknownHost(host))
    }
  }

  /// The installed binary by its path, beside the socket (#231): a host has no `wr-agent` on its
  /// PATH.
  func testTheRelayCommandRunsTheInstalledBinaryAndQuotesForTheRemoteShell() {
    let host = ContainerHostDriver.Host(
      address: "h", port: 22, user: "u", identityFile: "/k", hostKey: "ssh-ed25519 AAAA",
      agentSocket: "/run/it's here/a.sock")
    XCTAssertEqual(host.agentBinary, "/run/it's here/wr-agent")
    XCTAssertEqual(
      ContainerHostDriver.relayCommand(binary: host.agentBinary, socket: host.agentSocket),
      "'/run/it'\\''s here/wr-agent' relay --socket '/run/it'\\''s here/a.sock'")
  }
}
