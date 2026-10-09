import XCTest

@testable import Workroom

/// The exe.dev driver (#259) with exe.dev's ssh API stubbed: the user's own ssh it runs, its account
/// guard, what it refuses to derive from, and how it reads `rm`. What it
/// runs on a VM (setup, `sync`, the readiness waits) goes over real ssh, so the live suite covers it.
final class ExeDevHostDriverTests: XCTestCase {
  /// Both of exe.dev's not-found answers, matched whole: anything else is not a removal.
  func testNotFoundIsExeDevsAnswerMatchedWhole() {
    XCTAssertTrue(ExeDevHostDriver.isNotFound(#"VM "workroom-x" not found"#))
    XCTAssertTrue(ExeDevHostDriver.isNotFound(#"vm "workroom-x" not found"#))
    XCTAssertFalse(ExeDevHostDriver.isNotFound("not found"))
    XCTAssertFalse(ExeDevHostDriver.isNotFound(#"VM "a" is fine, "b" not found"#))
    XCTAssertFalse(ExeDevHostDriver.isNotFound("ssh: Could not resolve hostname: not found"))
  }

  /// The ssh-agent is the app's own when it was launched with one, else the login shell's.
  func testTheSSHAgentIsTheAppsElseTheShells() {
    XCTAssertEqual(
      ExeDevHostDriver.userSSHAgent(
        inherited: ["SSH_AUTH_SOCK": "/app"], probed: ["SSH_AUTH_SOCK": "/shell"]), "/app")
    XCTAssertEqual(
      ExeDevHostDriver.userSSHAgent(inherited: [:], probed: ["SSH_AUTH_SOCK": "/shell"]), "/shell")
    XCTAssertNil(ExeDevHostDriver.userSSHAgent(inherited: ["SSH_AUTH_SOCK": ""], probed: [:]))
  }

  // MARK: With exe.dev stubbed

  /// Answers each lobby command from `answers` by its name, as `whoami` for `email`, or, unless
  /// ssh `signsIn`, as ssh refused by the gateway. Records every command and ssh's arguments.
  private final class StubExeDev: StatusCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(command: String, ssh: [String], arguments: [String])] = []
    let answers: [String: CommandResult]
    let signsIn: Bool
    let email: String

    init(_ answers: [String: CommandResult], signsIn: Bool = true, email: String = "me@x.dev") {
      self.answers = answers
      self.signsIn = signsIn
      self.email = email
    }

    /// Every command but the account checks, in order.
    var commands: [String] {
      lock.withLock { calls.map(\.command) }.filter { $0 != "whoami" }
    }
    func arguments(of command: String) -> [String]? {
      lock.withLock { calls.last { $0.command == command }?.arguments }
    }
    /// ssh's own arguments for the last lobby command, up to and including the destination.
    var ssh: [String] { lock.withLock { calls.last?.ssh ?? [] } }

    /// Only `runNetwork` answers: it is the runner that brings the login shell's ssh agent to an
    /// app launched from Finder, so a lobby command run without it is a failure.
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      XCTFail("exe.dev ran without the login shell's ssh agent: \(args)")
      return CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: false)
    }

    func runNetwork(
      _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval
    ) async -> CommandResult {
      let lobby = args.firstIndex(of: ExeDevHostDriver.lobby) ?? args.endIndex - 1
      let command = args[lobby + 1]
      lock.withLock {
        calls.append((command, Array(args[...lobby]), Array(args[(lobby + 2)...])))
      }
      guard signsIn else {
        return CommandResult(
          stdout: "", stderr: "exe.dev: Permission denied (publickey,keyboard-interactive).\n",
          exitCode: 255, timedOut: false)
      }
      if command == "whoami" { return ExeDevHostDriverTests.ok(#"{"email":"\#(email)"}"#) }
      // A rollback removes a VM the stub never made: not found, as exe.dev says it.
      if command == "rm", answers[command] == nil {
        let name = args[lobby + 2]
        return ExeDevHostDriverTests.ok(
          #"{"error":"VM \"\#(name)\" not found"}"# + "\n"
            + #"{"deleted":[],"failed":["\#(name)"]}"#)
      }
      return answers[command]
        ?? CommandResult(
          stdout: #"{"error":"unexpected"}"#, stderr: "", exitCode: 1, timedOut: false)
    }
  }

  fileprivate static func ok(_ json: String) -> CommandResult {
    CommandResult(stdout: json + "\n", stderr: "", exitCode: 0, timedOut: false)
  }

  private func driver(_ exe: StubExeDev, account: String? = nil) -> ExeDevHostDriver {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-exedev-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return ExeDevHostDriver(
      configuration: .init(account: account, sshAgent: "/agent.sock"), directory: root,
      runner: exe)
  }

  /// The driver's ssh is the user's own, as `ssh exe.dev` in Terminal: no configuration of its own
  /// and no key of its own, so the user's `~/.ssh/config`, agent and Keychain pick the key. A VM's
  /// host key is checked as exe.dev's, and nothing is forwarded to it.
  func testItRunsTheUsersOwnSSH() async throws {
    let exe = StubExeDev([:])
    let driver = driver(exe)
    let email = try await driver.signedIn()
    XCTAssertEqual(email, "me@x.dev")
    let options = Set(
      exe.ssh.enumerated().filter { $0.offset > 0 && exe.ssh[$0.offset - 1] == "-o" }
        .map(\.element))
    XCTAssertEqual(exe.ssh.last, "exe.dev")
    for forced in [
      "BatchMode=yes", "HostKeyAlias=exe.dev", "ForwardAgent=no", "RemoteCommand=none",
    ] {
      XCTAssertTrue(options.contains(forced), "\(forced) in \(exe.ssh)")
    }
    for own in ["-F", "-i"] { XCTAssertFalse(exe.ssh.contains(own), "\(own) in \(exe.ssh)") }
    XCTAssertFalse(exe.ssh.contains { $0.hasPrefix("Identit") }, "\(exe.ssh)")

    // A pane needs nothing asked of exe.dev first, so one after a relaunch attaches straight away.
    let id = UUID()
    let attach = try driver.attachCommand(
      to: .remote(id), session: UUID(), workingDirectory: "/home/exedev/r", restored: false,
      metadata: [])
    XCTAssertTrue(attach.contains("'exedev@\(driver.name(of: id)).exe.xyz'"), attach)
    XCTAssertTrue(
      attach.contains("'/usr/bin/env' 'SSH_AUTH_SOCK=/agent.sock' '/usr/bin/ssh'"), attach)
    XCTAssertTrue(attach.contains("'HostKeyAlias=exe.dev'"), attach)
    XCTAssertFalse(attach.contains("'-F'"), attach)

    // An ssh the app spawns has no environment of its own, so it gets the login shell's PATH for a
    // ProxyCommand's helper; a pane's ssh keeps the pane's.
    XCTAssertEqual(
      driver.route(id, spawned: true).environment,
      ["SSH_AUTH_SOCK": "/agent.sock", "PATH": ShellEnvironment.path()])
    XCTAssertEqual(driver.route(id, spawned: false).environment, ["SSH_AUTH_SOCK": "/agent.sock"])
  }

  /// When the user's ssh can't sign in to exe.dev, or doesn't know its host key, nothing runs and
  /// the error says to run `ssh exe.dev` once, naming the key's published fingerprint.
  func testWhenSSHCantSignInItSaysHowToFixIt() async throws {
    let exe = StubExeDev(["new": Self.ok("{}")], signsIn: false)
    do {
      _ = try await driver(exe).create()
      XCTFail("created without signing in")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("Permission denied"), detail)
      XCTAssertTrue(detail.contains("Run `ssh exe.dev`"), detail)
      XCTAssertTrue(detail.contains(ExeDevHostDriver.gatewayFingerprint), detail)
    }
    XCTAssertEqual(exe.commands, [], "a command ran without signing in")
  }

  /// Another exe.dev account than the host's refuses every change before it is made: its VMs read
  /// as not found there, which a delete would take for gone.
  func testAnotherAccountIsRefusedBeforeAnythingChanges() async throws {
    let exe = StubExeDev(
      ["rm": Self.ok(#"{"deleted":[],"failed":[]}"#)],
      email: "other@x.dev")
    let driver = driver(exe, account: "me@x.dev")
    let attempts: [() async throws -> Void] = [
      { try await driver.destroy(.remote(UUID())) },
      { _ = try await driver.create() },
      { _ = try await driver.deriveFromBase(.remote(UUID())) },
    ]
    for attempt in attempts {
      do {
        try await attempt()
        XCTFail("acted in another account")
      } catch HostDriverError.invalidConfiguration(let detail) {
        XCTAssertTrue(detail.contains("other@x.dev"), detail)
      }
    }
    XCTAssertEqual(exe.commands, [], "a change ran in another account")
  }

  /// Only a base is derived from: a VM without the base tag is a workroom, whose disk holds its
  /// own enrolment, and is refused before anything is copied. A base that's gone is unknown.
  func testOnlyATaggedBaseIsDerivedFrom() async throws {
    let base = UUID()
    let name = driver(StubExeDev([:])).name(of: base)
    for (listing, expected) in [
      (#"{"vms":[{"vm_name":"\#(name)"}]}"#, "untagged"),
      (#"{"vms":[{"vm_name":"\#(name)","tags":["prod"]}]}"#, "untagged"),
      (#"{"vms":[]}"#, "gone"),
    ] {
      let exe = StubExeDev(["ls": Self.ok(listing)])
      let driver = driver(exe)
      do {
        _ = try await driver.deriveFromBase(.remote(base))
        XCTFail("derived from \(listing)")
      } catch HostDriverError.invalidConfiguration(let detail) {
        XCTAssertEqual(expected, "untagged")
        XCTAssertEqual(detail, "a workroom instance cannot be derived from")
      } catch HostDriverError.unknownHost(let host) {
        XCTAssertEqual(expected, "gone")
        XCTAssertEqual(host, .remote(base))
      }
      XCTAssertEqual(exe.commands, ["ls"], "\(listing): a copy was attempted")
      XCTAssertEqual(exe.arguments(of: "ls"), [name, "--json"])
    }
  }

  /// exe.dev failing to list the base is a provisioning error the app can show, never the driver's
  /// own failure type escaping it.
  func testAFailedListingIsAProvisioningError() async throws {
    let exe = StubExeDev(
      [
        "ls": CommandResult(
          stdout: #"{"error":"rate limited"}"#, stderr: "", exitCode: 1, timedOut: false)
      ])
    let driver = driver(exe)
    do {
      _ = try await driver.deriveFromBase(.remote(UUID()))
      XCTFail("derived with no listing")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "exe.dev ls: rate limited")
    }
  }

  /// A base is made with the base tag, which a copy is made without.
  func testABaseIsTaggedAndARefusedOneHasNothingToRemove() async throws {
    let exe = StubExeDev(
      [
        "new": CommandResult(
          stdout: #"{"error":"VM limit reached"}"#, stderr: "", exitCode: 1, timedOut: false)
      ])
    let driver = driver(exe)
    do {
      _ = try await driver.create()
      XCTFail("a refused VM became a base")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "exe.dev new: VM limit reached")
    }
    XCTAssertEqual(PendingMachines.entries(in: driver.directory), [], "a removed VM stayed pending")
    let new = try XCTUnwrap(exe.arguments(of: "new"))
    XCTAssertEqual(
      Array(new[new.firstIndex(of: "--tag")!...].prefix(2)), ["--tag", "workroom-base"])
    XCTAssertEqual(exe.commands, ["new", "rm"])
  }

  /// `rm` exits 0 whatever happened (spike), so a delete reads what it printed: deleted, or not
  /// found, is gone; anything else keeps the host and says why.
  func testADeleteReadsWhatRmPrintedNotItsStatus() async throws {
    let id = UUID()
    let name = driver(StubExeDev([:])).name(of: id)
    for (printed, gone) in [
      (#"{"deleted":["\#(name)"],"failed":[]}"#, true),
      (
        #"{"error":"VM \"\#(name)\" not found"}"# + "\n" + #"{"deleted":[],"failed":["\#(name)"]}"#,
        true
      ),
      (#"{"error":"VM is busy"}"# + "\n" + #"{"deleted":[],"failed":["\#(name)"]}"#, false),
      ("", false),
    ] {
      let exe = StubExeDev(["rm": Self.ok(printed)])
      let driver = driver(exe)
      // Value: protects=a deleted VM leaves the pending list and a kept one stays on it (#373);
      // fails_when=destroy skips the forget, or forgets a VM it failed to remove;
      // why_new=only a create's rollback is checked; seam=none
      try PendingMachines.add(
        .init(id: id, driver: RemoteWorkrooms.exeDevDriver), in: driver.directory)
      defer {
        XCTAssertEqual(
          PendingMachines.entries(in: driver.directory).map(\.id), gone ? [] : [id], printed)
      }
      do {
        try await driver.destroy(.remote(id))
        XCTAssertTrue(gone, "\(printed): reported gone")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertFalse(gone, "\(printed): \(detail)")
        XCTAssertTrue(detail.hasPrefix("VM \(name): "), detail)
      }
      XCTAssertEqual(exe.commands, ["rm"])
    }
  }

  /// What the user is told when exe.dev or their ssh says no: exe.dev's own `error`, from stdout or
  /// stderr, else ssh's first line without its `error: ` label; ssh's own failure (255) says to
  /// fix the user's ssh unless exe.dev answered in JSON; a silent failure still says how it ended.
  func testTheUsersErrorIsWhatExeDevOrSSHActuallySaid() async throws {
    func result(stdout: String = "", stderr: String = "", exit: Int32 = 1) -> CommandResult {
      CommandResult(stdout: stdout, stderr: stderr, exitCode: exit, timedOut: false)
    }
    // Value: protects=the failure text a user reads in New Workroom when exe.dev refuses;
    // fails_when=a stream, label or the 255 case is read wrong; why_new=only the sign-in and
    // stdout-JSON shapes were pinned; seam=none
    XCTAssertEqual(
      ExeDevHostDriver.errorLine(result(stderr: #"{"error":"quota"}"#)), "quota")
    XCTAssertEqual(
      ExeDevHostDriver.errorLine(result(stderr: #"{"error":"denied"}"#, exit: 255)), "denied")
    XCTAssertEqual(
      ExeDevHostDriver.errorLine(result(stderr: "\n error: no such command\nmore\n")),
      "no such command")
    XCTAssertNil(ExeDevHostDriver.errorLine(result()))

    let timedOut = CommandResult(stdout: "", stderr: "", exitCode: 15, timedOut: true)
    for (answer, expected) in [
      (result(), "exe.dev new: exited 1"),
      (timedOut, "exe.dev new: timed out after 120s"),
    ] {
      let driver = driver(StubExeDev(["new": answer]))
      do {
        _ = try await driver.create()
        XCTFail("created on \(expected)")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertEqual(detail, expected)
      }
    }
  }

  /// A failed create whose VM can't be removed names it and records it (`host`), so the app keeps
  /// the host for a later delete rather than losing a VM that bills.
  func testACreateThatCantRemoveItsVMRecordsIt() async throws {
    // Value: protects=a half-made VM stays recorded and named when its removal fails;
    // fails_when=undo drops the leftover or the host; why_new=the tests only cover a clean rollback;
    // seam=none
    let exe = StubExeDev(
      [
        "new": CommandResult(
          stdout: #"{"error":"VM limit reached"}"#, stderr: "", exitCode: 1, timedOut: false),
        "rm": Self.ok(#"{"error":"VM is busy"}"# + "\n" + #"{"deleted":[],"failed":[]}"#),
      ])
    let driver = driver(exe, account: "me@x.dev")
    do {
      _ = try await driver.create()
      XCTFail("a VM that couldn't be removed was reported removed")
    } catch HostDriverError.leftBehind(let cause, let leftover, let host) {
      XCTAssertEqual(cause, "Couldn't provision the host: exe.dev new: VM limit reached")
      let name = try XCTUnwrap(leftover.first)
      XCTAssertEqual(leftover.count, 1)
      XCTAssertTrue(name.hasPrefix("VM workroom-") && name.hasSuffix(": VM is busy"), name)
      guard case .remote(let id)? = host else { return XCTFail("no host recorded: \(name)") }
      XCTAssertTrue(name.contains(id.uuidString.lowercased()), name)
      // Pending too, with its account, so the launch sweep takes it if no record ever does (#373).
      let pending = PendingMachines.entries(in: driver.directory)
      XCTAssertEqual(pending.map(\.id), [id])
      XCTAssertEqual(pending.map(\.driver), [RemoteWorkrooms.exeDevDriver])
      XCTAssertEqual(pending.map(\.account), ["me@x.dev"])
      XCTAssertNotNil(pending.first?.made, "an entry was written down with no age")
    }
    XCTAssertEqual(exe.commands, ["new", "rm"])
  }

  /// A pane stops retrying when ssh's log for its session says exe.dev refused the key: read from
  /// the same per-host directory `attachCommand` has ssh log to, and only for a VM.
  func testAPaneStopsRetryingOnARefusedKey() throws {
    // Value: protects=a refused key or host key ends a pane's reconnect loop (#241);
    // fails_when=the refusal is read from another directory than the attach logs to;
    // why_new=attach is only checked for its command line; seam=none
    let driver = driver(StubExeDev([:]))
    let id = UUID()
    let session = UUID()
    let command = try driver.attachCommand(
      to: .remote(id), session: session, workingDirectory: "/w", restored: true)
    let log = ContainerHostDriver.attachLog(
      session, in: driver.directory.appendingPathComponent(id.uuidString))
    XCTAssertTrue(command.contains("'\(log.path)'"), command)
    XCTAssertFalse(driver.hostRefusedLastAttach(of: session, on: .remote(id)))
    try "Connection refused\n".write(to: log, atomically: true, encoding: .utf8)
    XCTAssertFalse(driver.hostRefusedLastAttach(of: session, on: .remote(id)))
    try "exedev@x.exe.xyz: Permission denied (publickey).\n".write(
      to: log, atomically: true, encoding: .utf8)
    XCTAssertTrue(driver.hostRefusedLastAttach(of: session, on: .remote(id)))
    XCTAssertFalse(driver.hostRefusedLastAttach(of: session, on: .local))
  }

  // MARK: The readiness wait both remote drivers share

  /// A `HostDriver` whose "host" is a local shell: `exec` runs the check line with `/bin/sh`.
  private struct ShellHost: HostDriver {
    var traits: HostDriverTraits {
      HostDriverTraits(
        transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
        durableDisk: true, maxLifetime: nil)
    }
    func create() async throws -> HostID { .local }
    func deriveFromBase(_ base: HostID) async throws -> HostID { .local }
    func destroy(_ host: HostID) async throws {}
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: [:],
        handshakeTimeout: 5, purpose: .exchange)
    }
  }

  /// `poll` is the gate every create waits at (boot, identity, agent): it passes once the check
  /// exits 0, however many tries it took; gives up with the last answer; and ends at once on a cancel.
  func testPollWaitsForTheCheckThenGivesUpWithTheLastAnswer() async throws {
    // Value: protects=a create waits for a host to come up and says why it never did;
    // fails_when=poll gives up early, never gives up, or swallows a cancel;
    // why_new=poll moved out of BoxdHostDriver and only the live suites ran it; seam=none
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-poll-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
    let path = PosixShell.quoted(marker.path)
    try await ShellHost().poll(.local, "test -e \(path) || { touch \(path); exit 1; }", tries: 3) {
      "never: \($0)"
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the check never ran")

    do {
      try await ShellHost().poll(.local, "echo not yet; exit 3", tries: 2) { "never: \($0)" }
      XCTFail("passed a failing check")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "never: not yet\n")
    }

    let waiting = Task {
      try await ShellHost().poll(.local, "exit 1", tries: 1000) { "never: \($0)" }
    }
    try await Task.sleep(for: .milliseconds(200))
    waiting.cancel()
    do {
      try await waiting.value
      XCTFail("a cancelled wait went on")
    } catch is CancellationError {}
  }
}
