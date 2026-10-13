import AgentConnection
import CryptoKit
import HostDrivers
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The exe.dev driver (#259) with exe.dev's ssh API stubbed: the user's own ssh it runs, its account
/// guard, and how it reads `rm`. What it runs on a VM (setup, the readiness waits) goes over real
/// ssh, so the live suite covers it.
final class ExeDevHostDriverTests: XCTestCase {
  /// Both of exe.dev's not-found answers, matched whole: anything else is not a removal.
  func testNotFoundIsExeDevsAnswerMatchedWhole() {
    XCTAssertTrue(ExeDevHostDriver.isNotFound(#"VM "workroom-x" not found"#))
    XCTAssertTrue(ExeDevHostDriver.isNotFound(#"vm "workroom-x" not found"#))
    XCTAssertFalse(ExeDevHostDriver.isNotFound("not found"))
    XCTAssertFalse(ExeDevHostDriver.isNotFound(#"VM "a" is fine, "b" not found"#))
    XCTAssertFalse(ExeDevHostDriver.isNotFound("ssh: Could not resolve hostname: not found"))
  }

  // Value: protects=every exe.dev create can set up the VM's git; fails_when=the script is renamed,
  // moved out of host-setup, or the name it is loaded by drifts; why_new=exedev-github_test.sh reads
  // the source tree, not the app bundle, and the live suite is not run in CI; seam=none;
  // no_claim=what the script does on a VM
  /// The git setup a create runs on each VM ships in the app's bundle.
  func testTheGitHubSetupScriptShipsInTheBundle() throws {
    XCTAssertTrue(try HostSetup.exeDevGitHubScript().contains("github.int.exe.xyz"))
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
      if command == "whoami" {
        return answers[command] ?? ExeDevHostDriverTests.ok(#"{"email":"\#(email)"}"#)
      }
      // A rollback removes a VM the stub never made: not found, as exe.dev says it.
      if command == "rm", answers[command] == nil {
        let name = args[lobby + 2]
        return ExeDevHostDriverTests.ok(
          #"{"error":"VM \"\#(name)\" not found"}"# + "\n"
            + #"{"deleted":[],"failed":["\#(name)"]}"#)
      }
      // A command with subcommands is answered by both words first: `integrations list`.
      let subcommand = args.indices.contains(lobby + 2) ? "\(command) \(args[lobby + 2])" : command
      return answers[subcommand] ?? answers[command]
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
    } catch let required as ExeDevHostDriver.SignInRequired {
      XCTAssertTrue(required.said.contains("Permission denied"), required.said)
      XCTAssertTrue(required.said.contains("Run `ssh exe.dev`"), required.said)
      XCTAssertTrue(required.said.contains(ExeDevHostDriver.gatewayFingerprint), required.said)
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

  /// A repository's first exe.dev create adds its GitHub integration, acting as the user and
  /// attached to every VM; one an integration already names, in any case, adds nothing; and one
  /// on another host than github.com is left to the clone.
  func testACreateAddsTheRepositorysGitHubIntegrationOnce() async throws {
    let none = StubExeDev([
      "integrations list": Self.ok(#"[{"type":"llm","config":{"providers":{}},"name":"llm"}]"#),
      "integrations add": Self.ok(""),
    ])
    try await driver(none).grantGitHub(host: "github.com", owner: "Joel", name: "my.app")
    XCTAssertEqual(
      none.arguments(of: "integrations"),
      [
        "add", "github", "--name", ExeDevHostDriver.integrationName(owner: "Joel", name: "my.app"),
        "--repository", "Joel/my.app", "--act-as-user", "--attach", "auto:all", "--json",
      ])

    let named = StubExeDev([
      "integrations list": Self.ok(
        #"[{"type":"github","attachments":["auto:all"],"config":{"repositories":["joel/MY.app"],"act_as_user":true},"name":"mine"}]"#
      )
    ])
    try await driver(named).grantGitHub(host: "github.com", owner: "Joel", name: "my.app")
    XCTAssertEqual(named.commands, ["integrations"], "added one already there")

    // One a new VM can't use (attached to one VM, or pushing as exe.dev's App) gets one beside it.
    for unusable in [
      #"[{"type":"github","attachments":["vm:old"],"config":{"repositories":["Joel/my.app"],"act_as_user":true}}]"#,
      #"[{"type":"github","attachments":["auto:all"],"config":{"repositories":["Joel/my.app"]}}]"#,
    ] {
      let exe = StubExeDev([
        "integrations list": Self.ok(unusable), "integrations add": Self.ok(""),
      ])
      try await driver(exe).grantGitHub(host: "github.com", owner: "Joel", name: "my.app")
      XCTAssertEqual(exe.arguments(of: "integrations")?.first, "add", unusable)
    }

    let elsewhere = StubExeDev([:])
    try await driver(elsewhere).grantGitHub(host: "ghe.acme.com", owner: "o", name: "r")
    XCTAssertEqual(elsewhere.commands, [])
  }

  /// A repository exe.dev won't add an integration for (its owner hasn't installed exe.dev's
  /// GitHub App, as for a public upstream) is left to the clone: exe.dev serves public ones anyway.
  func testARepositoryExeDevWontGrantIsLeftToTheClone() async throws {
    let exe = StubExeDev([
      "integrations list": Self.ok("[]"),
      "integrations add": CommandResult(
        stdout: #"{"error":"no GitHub App installed on \"rails\"; connected: joelmoss."}"#,
        stderr: "", exitCode: 1, timedOut: false),
    ])
    try await driver(exe).grantGitHub(host: "github.com", owner: "rails", name: "rails")
    XCTAssertEqual(exe.commands, ["integrations", "integrations"], "listed, then tried to add")
  }

  /// An integration name is exe.dev's form (lowercase letters, digits and hyphens, 63 at most),
  /// and repositories the rest maps alike still get names of their own.
  func testAnIntegrationNameIsOneExeDevTakesAndNoOtherRepositorysName() throws {
    func name(_ owner: String, _ repo: String) -> String {
      ExeDevHostDriver.integrationName(owner: owner, name: repo)
    }
    let long = name("o", String(repeating: "a", count: 90) + "_b")
    XCTAssertLessThanOrEqual(long.count, 63)
    for made in [long, name("Joel", "my.app"), name("joel", ".github")] {
      XCTAssertNil(made.range(of: "[^a-z0-9-]", options: .regularExpression), made)
      XCTAssertFalse(made.contains("--"), made)
      XCTAssertNotNil(
        made.range(of: "^workroom-.+-[0-9a-f]{8}$", options: .regularExpression), made)
    }
    XCTAssertNotEqual(name("acme", "my.app"), name("acme", "my-app"))
    XCTAssertNotEqual(name("a-b", "c"), name("a", "b-c"))
    XCTAssertNotEqual(
      name("o", String(repeating: "a", count: 90) + "1"),
      name("o", String(repeating: "a", count: 90) + "2"))
    XCTAssertEqual(name("Joel", "My.App"), name("joel", "my.app"), "GitHub ignores case")
  }

  /// exe.dev's gateway key is appended on a line of its own, whatever the file ends with, and a
  /// missing file and directory are made.
  func testTheGatewayKeyGoesOnALineOfItsOwn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let fresh = root.appendingPathComponent("ssh/known_hosts")
    try ExeDevHostDriver.appendKnownHost("exe.dev ssh-rsa KEY", to: fresh)
    XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), "exe.dev ssh-rsa KEY\n")
    for existing in ["other ssh-rsa A", "other ssh-rsa A\n"] {
      let file = root.appendingPathComponent(UUID().uuidString)
      try Data(existing.utf8).write(to: file)
      try ExeDevHostDriver.appendKnownHost("exe.dev ssh-rsa KEY", to: file)
      XCTAssertEqual(
        try String(contentsOf: file, encoding: .utf8), "other ssh-rsa A\nexe.dev ssh-rsa KEY\n",
        existing)
    }
  }

  /// A scan that reached no key is told apart from one whose key doesn't match, so a user behind a
  /// proxy isn't told exe.dev's key may be forged.
  func testAnUnreachableScanIsNotAMismatch() {
    XCTAssertFalse(ExeDevHostDriver.hasScannedKey(""))
    XCTAssertFalse(ExeDevHostDriver.hasScannedKey("# exe.dev:22 SSH-2.0\n"))
    XCTAssertTrue(ExeDevHostDriver.hasScannedKey("exe.dev ssh-rsa AAAA\n"))
  }

  /// A new key is offered only when ssh would use it: no identity or agent of the user's own in
  /// their config, and none of ssh's default keys there yet. One already there is never replaced.
  func testANewKeyIsOfferedOnlyWhenSshWouldUseIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaults = ExeDevHostDriver.defaultKeyNames.map { "identityfile \(dir.path)/\($0)" }
      .joined(separator: "\n")
    XCTAssertTrue(ExeDevHostDriver.mayCreateDefaultKey(resolved: defaults, in: dir))
    XCTAssertFalse(
      ExeDevHostDriver.mayCreateDefaultKey(
        resolved: "identityfile ~/.ssh/work_key\n" + defaults, in: dir), "the user's own key")
    XCTAssertFalse(
      ExeDevHostDriver.mayCreateDefaultKey(
        resolved: defaults + "\nidentityagent ~/1password/agent.sock", in: dir), "an agent")

    let key = dir.appendingPathComponent("id_ed25519")
    try Data("PRIVATE".utf8).write(to: key)
    XCTAssertFalse(ExeDevHostDriver.mayCreateDefaultKey(resolved: defaults, in: dir))
    // StubExeDev fails any command run outside ssh's own runner, so ssh-keygen never runs here.
    try await driver(StubExeDev([:])).createDefaultKey(in: dir)
    XCTAssertEqual(try Data(contentsOf: key), Data("PRIVATE".utf8))
  }

  /// A sign-up says when exe.dev sent its link, ends when its connection does, and says ssh's own
  /// words when it never got as far as exe.dev.
  func testASignUpSaysWhatExeDevOrSshSaid() async throws {
    func session(_ script: String) throws -> ExeDevHostDriver.SignUp {
      ExeDevHostDriver.SignUp(
        stream: try HostStream.spawn(
          URL(fileURLWithPath: "/bin/sh"), ["-c", script], environment: [:],
          handshakeTimeout: 5, purpose: .connection))
    }
    let exeDev = try session(
      #"printf 'Please enter your email address: '; read e; printf 'Verification email sent to: %s\nWaiting for verification...\n' "$e"; sleep 0.2"#
    )
    let sent = await exeDev.submit("me@x.dev")
    XCTAssertEqual(sent, .sent)
    await exeDev.waitForEnd()

    let refused = try session(
      "echo 'ssh: connect to host exe.dev port 22: Connection refused' >&2; exit 255")
    let said = await refused.submit("me@x.dev")
    XCTAssertEqual(said, .said("ssh: connect to host exe.dev port 22: Connection refused"))
  }

  /// An account already ready goes straight to its create, checked once a launch; one that isn't
  /// gets the setup, already read from the account.
  @MainActor
  func testOnlyAnAccountNotYetReadyHoldsTheCreate() async throws {
    ExeDevSetup.confirmedThisLaunch = false
    defer { ExeDevSetup.confirmedThisLaunch = false }
    let ready = StubExeDev([
      "billing plan": Self.ok(#"{"max_vms":5}"#), "integrations setup": Self.ok("  me ✓"),
    ])
    let none = await ExeDevSetup.needed(driver: driver(ready))
    XCTAssertNil(none)
    XCTAssertTrue(ExeDevSetup.confirmedThisLaunch)
    let unchecked = StubExeDev([:])
    let again = await ExeDevSetup.needed(driver: driver(unchecked))
    XCTAssertNil(again)
    XCTAssertEqual(unchecked.commands, [], "checked again in the same launch")

    ExeDevSetup.confirmedThisLaunch = false
    let unpaid = StubExeDev([
      "billing plan": Self.ok(#"{"max_vms":0}"#), "integrations setup": Self.ok("  me ✓"),
    ])
    let setup = await ExeDevSetup.needed(driver: driver(unpaid))
    XCTAssertEqual(setup?.plan, .needed)
    XCTAssertFalse(ExeDevSetup.confirmedThisLaunch)
  }

  /// A check that fails says so under its step, rather than reading as a step not done; and a
  /// link that answers after the sheet is gone opens nothing.
  @MainActor
  func testAFailedCheckSaysSoAndACancelledSheetOpensNothing() async throws {
    var opened: [URL] = []
    let exe = StubExeDev(
      [
        "billing plan": CommandResult(
          stdout: #"{"error":"billing is down"}"#, stderr: "", exitCode: 1, timedOut: false),
        "integrations setup": Self.ok("  me ✓"),
        "browser": Self.ok(#"{"magic_link":"https://exe.dev/auth/verify?token=T"}"#),
      ])
    let setup = ExeDevSetup(driver: driver(exe), open: { opened.append($0) })
    await setup.refresh()
    XCTAssertEqual(setup.plan, .needed)
    XCTAssertTrue(setup.planError?.contains("billing is down") == true, "\(setup.planError ?? "")")

    // Check Again keeps a step the user is still finishing waiting, rather than "needed" again.
    let unpaid = ExeDevSetup(
      driver: driver(
        StubExeDev([
          "billing plan": Self.ok(#"{"max_vms":0}"#), "integrations setup": Self.ok("  me ✓"),
          "browser": Self.ok(#"{"magic_link":"https://exe.dev/auth/verify?token=T"}"#),
        ])),
      open: { _ in })
    await unpaid.refresh()
    await unpaid.choosePlan()
    XCTAssertEqual(unpaid.plan, .waiting)
    await unpaid.checkAgain()
    XCTAssertEqual(unpaid.plan, .waiting)
    XCTAssertEqual(unpaid.account, .done("me@x.dev"))
    unpaid.cancel()
    setup.cancel()
    await setup.choosePlan()
    XCTAssertEqual(opened, [])
    XCTAssertNotEqual(setup.plan, .waiting)
  }

  /// A key exe.dev doesn't know yet is answered in plain text on stdout, exit 1 (spike): that, like
  /// ssh's own refusal, is a sign-in the user finishes at a terminal, not a failure to report.
  func testAnUnregisteredKeyIsASignInToFinish() async throws {
    let exe = StubExeDev([
      "whoami": CommandResult(
        stdout: "Please complete registration by running: ssh exe.dev\r\n", stderr: "",
        exitCode: 1, timedOut: false)
    ])
    do {
      _ = try await driver(exe).signedIn()
      XCTFail("signed in with a key exe.dev doesn't know")
    } catch let required as ExeDevHostDriver.SignInRequired {
      XCTAssertEqual(required.said, "Please complete registration by running: ssh exe.dev")
    }
  }

  /// GitHub is connected when `--verify` ticks an account, and not otherwise.
  func testGitHubIsConnectedWhenVerifyTicksAnAccount() async throws {
    for (answer, connected) in [
      (Self.ok("  joelmoss ✓"), true),
      (Self.ok("No GitHub accounts connected."), false),
      (CommandResult(stdout: "", stderr: "error", exitCode: 1, timedOut: false), false),
    ] {
      let exe = StubExeDev(["integrations setup": answer])
      let result = try await driver(exe).gitHubConnected()
      XCTAssertEqual(result, connected, answer.stdout)
      XCTAssertEqual(exe.arguments(of: "integrations"), ["setup", "github", "--verify"])
    }
  }

  /// `whoami` tells a signed-in account from each thing a new user's ssh still lacks, as exe.dev
  /// and ssh answer them (spike, 2026-10-12).
  func testWhoamiSaysWhatANewUserStillLacks() {
    func result(_ stdout: String, _ stderr: String = "", exit: Int32) -> CommandResult {
      CommandResult(stdout: stdout, stderr: stderr, exitCode: exit, timedOut: false)
    }
    typealias Account = ExeDevHostDriver.Account
    let cases: [(CommandResult, Account)] = [
      (result(#"{"email":"me@x.dev"}"#, exit: 0), .signedIn("me@x.dev")),
      (result("Please complete registration by running: ssh exe.dev\r\n", exit: 1), .needsSignUp),
      (result("", "Host key verification failed.\n", exit: 255), .unknownHostKey),
      (
        result("", "exedev@exe.dev: Permission denied (publickey).\n", exit: 255),
        .noUsableKey("exedev@exe.dev: Permission denied (publickey).")
      ),
      (result(#"{"error":"down"}"#, exit: 1), .failed("down")),
    ]
    for (answer, expected) in cases {
      XCTAssertEqual(
        ExeDevHostDriver.account(from: answer), expected, answer.stdout + answer.stderr)
    }
  }

  /// exe.dev's gateway key is trusted only when its fingerprint is the published one, and the line
  /// added names `exe.dev`, as the driver's `HostKeyAlias` and a plain `ssh exe.dev` look it up.
  func testOnlyTheGatewayKeyWithThePublishedFingerprintIsTrusted() throws {
    let blob = Data("not exe.dev's key".utf8).base64EncodedString()
    let scan = "# exe.dev:22 SSH-2.0\nexe.dev ssh-rsa \(blob)\n"
    XCTAssertNil(
      ExeDevHostDriver.verifiedGatewayKey(in: scan), "trusted a key that isn't exe.dev's")
    let digest = Data(SHA256.hash(data: try XCTUnwrap(Data(base64Encoded: blob))))
      .base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    XCTAssertEqual(
      ExeDevHostDriver.verifiedGatewayKey(in: scan, fingerprint: "SHA256:\(digest)"),
      "exe.dev ssh-rsa \(blob)")
  }

  /// The key goes in the first known_hosts file the user's ssh reads, `~` expanded.
  func testTheKnownHostsFileIsTheFirstSshReads() {
    XCTAssertEqual(
      ExeDevHostDriver.knownHostsFile(
        in: "user exedev\nuserknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2\n"),
      NSHomeDirectory() + "/.ssh/known_hosts")
    XCTAssertNil(ExeDevHostDriver.knownHostsFile(in: "user exedev\n"))
  }

  /// A sign-in link lands on its page with the fragment intact (spike: `/integrations#github`).
  func testASignInLinkRedirectsToItsPage() {
    XCTAssertEqual(
      ExeDevHostDriver.url(
        "https://exe.dev/auth/verify?token=T", redirectingTo: "/integrations#github")?
        .absoluteString,
      "https://exe.dev/auth/verify?token=T&redirect=%2Fintegrations%23github")
  }

  /// What exe.dev said to an email, without its colours or the prompt it asks again with.
  func testASignUpRefusalIsExeDevsLastWords() {
    XCTAssertEqual(
      ExeDevHostDriver.SignUp.lastWords(
        "x@y\r\n\u{1B}[1mInvalid email address\u{1B}[0m\r\nPlease enter your email address: "),
      "Invalid email address")
  }

  /// A plan allows VMs when its `max_vms` does: a new account's Basic plan is active with none.
  func testAPlanAllowsVMsWhenItsMaxVMsDoes() async throws {
    for (maxVMs, allows) in [(0, false), (5, true)] {
      let exe = StubExeDev([
        "billing plan": Self.ok(
          #"{"plan":"Basic","status":"active","paid":false,"max_vms":\#(maxVMs)}"#)
      ])
      let result = try await driver(exe).planAllowsVMs()
      XCTAssertEqual(result, allows)
    }
  }

  /// A ready account goes straight to its create; a new one is asked for its email, with the
  /// website steps after it; and a website step opens a link signed in to the account, then waits.
  @MainActor
  func testSetupAsksOnlyForWhatTheAccountLacks() async throws {
    defer { ExeDevSetup.confirmedThisLaunch = false }
    let ready = ExeDevSetup(
      driver: driver(
        StubExeDev([
          "billing plan": Self.ok(#"{"max_vms":5}"#),
          "integrations setup": Self.ok("  me ✓"),
        ])))
    await ready.refresh()
    XCTAssertTrue(ready.isReady)

    let new = ExeDevSetup(
      driver: driver(
        StubExeDev([
          "whoami": CommandResult(
            stdout: "Please complete registration by running: ssh exe.dev\r\n", stderr: "",
            exitCode: 1, timedOut: false)
        ])))
    await new.refresh()
    XCTAssertEqual(new.account, .needsEmail(error: nil))
    XCTAssertFalse(new.isReady)

    var opened: [URL] = []
    let unpaid = ExeDevSetup(
      driver: driver(
        StubExeDev([
          "billing plan": Self.ok(#"{"max_vms":0}"#),
          "integrations setup": Self.ok("No GitHub accounts connected."),
          "browser": Self.ok(#"{"magic_link":"https://exe.dev/auth/verify?token=T"}"#),
        ])),
      open: { opened.append($0) })
    await unpaid.refresh()
    XCTAssertEqual(unpaid.account, .done("me@x.dev"))
    XCTAssertEqual([unpaid.plan, unpaid.gitHub], [.needed, .needed])
    await unpaid.connectGitHub()
    XCTAssertEqual(
      opened.map(\.absoluteString),
      ["https://exe.dev/auth/verify?token=T&redirect=%2Fintegrations%23github"])
    XCTAssertEqual(unpaid.gitHub, .waiting)
    unpaid.cancel()
  }

  /// A sign-up finished by hand runs the user's own `ssh exe.dev` in the sheet, with the agent the
  /// driver's ssh uses, and the step waits on the account.
  @MainActor
  func testASignUpByHandRunsTheUsersOwnSSH() async {
    let exe = StubExeDev([
      "whoami": CommandResult(
        stdout: "Please complete registration by running: ssh exe.dev\r\n", stderr: "",
        exitCode: 1, timedOut: false)
    ])
    let setup = ExeDevSetup(driver: driver(exe))
    await setup.refresh()
    setup.useTerminal()
    XCTAssertEqual(setup.account, .inTerminal)
    XCTAssertEqual(
      setup.signInCommand, "'/usr/bin/env' 'SSH_AUTH_SOCK=/agent.sock' '/usr/bin/ssh' 'exe.dev'")
    setup.cancel()
  }

  /// A VM is made with no tag: a tag marked a base, which nothing makes any more.
  func testAHostIsUntaggedAndARefusedOneHasNothingToRemove() async throws {
    let exe = StubExeDev(
      [
        "new": CommandResult(
          stdout: #"{"error":"VM limit reached"}"#, stderr: "", exitCode: 1, timedOut: false)
      ])
    let driver = driver(exe)
    do {
      _ = try await driver.create()
      XCTFail("a refused VM became a host")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "exe.dev new: VM limit reached")
    }
    XCTAssertEqual(PendingMachines.entries(in: driver.directory), [], "a removed VM stayed pending")
    let new = try XCTUnwrap(exe.arguments(of: "new"))
    XCTAssertFalse(new.contains("--tag"), "\(new)")
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
    let log = SSHTransport.attachLog(
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
    func create() async throws -> HostID { .local }
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
