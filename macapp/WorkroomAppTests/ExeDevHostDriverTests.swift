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

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
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
}
