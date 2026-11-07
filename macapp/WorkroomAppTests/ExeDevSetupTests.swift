import HostDrivers
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import Workroom

/// The app's side of the exe.dev driver (#259), with exe.dev's ssh API stubbed: the setup sheet's
/// model (`ExeDevSetup`) and the create sequence's log of the repository grant. The driver's own
/// tests are HostDrivers' `ExeDevHostDriverTests`.
final class ExeDevSetupTests: XCTestCase {
  // MARK: With exe.dev stubbed

  /// Answers each lobby command from `answers` by its name, as `whoami` for `email`, or, unless
  /// ssh `signsIn`, as ssh refused by the gateway. Records every command and ssh's arguments.
  private final class StubExeDev: StatusCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(command: String, ssh: [String], arguments: [String])] = []
    private var answers: [String: CommandResult]
    let signsIn: Bool
    let email: String

    init(_ answers: [String: CommandResult], signsIn: Bool = true, email: String = "me@x.dev") {
      self.answers = answers
      self.signsIn = signsIn
      self.email = email
    }

    /// Every command but the account checks, in order.
    /// Changes what `command` answers from now on, as when the user finishes a step on the website.
    func answer(_ command: String, _ result: CommandResult) {
      lock.withLock { answers[command] = result }
    }
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
      let answers = lock.withLock { self.answers }
      lock.withLock {
        calls.append((command, Array(args[...lobby]), Array(args[(lobby + 2)...])))
      }
      guard signsIn else {
        return CommandResult(
          stdout: "", stderr: "exe.dev: Permission denied (publickey,keyboard-interactive).\n",
          exitCode: 255, timedOut: false)
      }
      if command == "whoami" {
        return answers[command] ?? ExeDevSetupTests.ok(#"{"email":"\#(email)"}"#)
      }
      // A rollback removes a VM the stub never made: not found, as exe.dev says it.
      if command == "rm", answers[command] == nil {
        let name = args[lobby + 2]
        return ExeDevSetupTests.ok(
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
      configuration: .init(account: account, sshAgent: "/agent.sock", hostSetup: .bundled),
      directory: root, runner: exe)
  }

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [(ProvisioningProgress.Step, String)] = []
    var all: [(ProvisioningProgress.Step, String)] { lock.withLock { heard } }
    func add(_ step: ProvisioningProgress.Step, _ line: String) {
      lock.withLock { heard.append((step, line)) }
    }
  }

  private struct Stop: Error {}

  /// Value: protects=#483's command log, the repository grant a create runs first logs its exe.dev
  /// commands under the `repository` step, without announcing a step of its own; fails_when=the
  /// grant's commands are lost from the log, filed under another step, or restart the repository
  /// row; no_claim=exe.dev's real answers (a stubbed lobby stands in)
  func testACreatesRepositoryGrantIsLoggedUnderItsRepositoryStep() async throws {
    let exe = StubExeDev([
      "integrations list": Self.ok("[]"), "integrations add": Self.ok(""),
    ])
    let driver = driver(exe)
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket,
      grantRepository: { repository in
        try await driver.grantGitHub(
          host: repository.host, owner: repository.owner, name: repository.name)
      },
      connect: { _ in throw Stop() })
    let lines = Lines()
    let steps = Lines()
    let log: @Sendable (ProvisioningProgress.Step, String) -> Void = { lines.add($0, $1) }
    let report: @Sendable (ProvisioningProgress.Step) -> Void = { steps.add($0, "") }
    await ProvisioningProgress.$reportStep.withValue(report) {
      await ProvisioningProgress.$log.withValue(log) {
        _ = try? await RemoteWorkrooms.create(
          repository: repository, cloneURL: "https://github.com/o/r.git",
          key: .exeDev(account: "me@x.dev"), driver: driver, environment: environment,
          recorder: RemoteWorkrooms.Recorder(
            reserve: { _, _ in throw Stop() }, record: { _, _ in }, forget: { _ in }),
          pendingIn: nil)
      }
    }
    XCTAssertTrue(
      lines.all.contains { $0.1.hasPrefix("$ ssh") && $0.1.contains("integrations add") },
      "the grant's commands aren't logged: \(lines.all.map(\.1))")
    XCTAssertTrue(lines.all.allSatisfy { $0.0 == .repository }, "\(lines.all.map(\.0))")
    XCTAssertTrue(steps.all.isEmpty, "the grant announced a step: \(steps.all.map(\.0))")
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
    // A check that couldn't answer doesn't hold the create back: exe.dev's own error decides.
    XCTAssertTrue(setup.isReady)

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

  // Value: protects=Check Again turns a website step the user finished to done, enabling Create
  // Workroom; fails_when=checkAgain keeps any step that was waiting waiting; why_new=only the
  // still-undone case was tested; seam=none; no_claim=the polling that does the same unasked
  /// Check Again after the user picked a plan finishes that step, and the sheet is ready.
  @MainActor
  func testCheckAgainFinishesAStepTheUserDid() async throws {
    ExeDevSetup.confirmedThisLaunch = false
    defer { ExeDevSetup.confirmedThisLaunch = false }
    let exe = StubExeDev([
      "billing plan": Self.ok(#"{"max_vms":0}"#), "integrations setup": Self.ok("  me ✓"),
      "browser": Self.ok(#"{"magic_link":"https://exe.dev/auth/verify?token=T"}"#),
    ])
    let setup = ExeDevSetup(driver: driver(exe), open: { _ in })
    await setup.refresh()
    await setup.choosePlan()
    XCTAssertEqual(setup.plan, .waiting)
    XCTAssertFalse(setup.isReady)
    exe.answer("billing plan", Self.ok(#"{"max_vms":5}"#))
    await setup.checkAgain()
    XCTAssertEqual(setup.plan, .done)
    XCTAssertTrue(setup.isReady)
    setup.cancel()
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
}
