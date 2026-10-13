import HostDrivers
import XCTest

@testable import Workroom

/// The setup sheets' shared parts: the poller that watches their waiting steps.
@MainActor
final class RemoteSetupTests: XCTestCase {
  private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
  }

  // Value: protects=a waiting setup step is checked again with growing gaps and the checks stop once
  // nothing waits or the sheet closes; fails_when=the backoff stops doubling, the loop outlives
  // isWaiting, or cancel leaves it running; why_new=the setup poll had no test (only ShellHost.poll
  // did); seam=the first and cap delays, so the test takes milliseconds; no_claim=the 3 s / 30 s values
  func testThePollerBacksOffWhileAStepWaitsAndStopsWhenDoneOrCancelled() async throws {
    let poller = SetupPoller(first: .milliseconds(10), cap: .milliseconds(40))
    let checks = Box<[ContinuousClock.Instant]>([])
    let waiting = Box(true)
    poller.start(
      while: { waiting.value },
      check: {
        checks.value.append(.now)
        if checks.value.count == 4 { waiting.value = false }
      })
    for _ in 0..<300 where poller.isPolling { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(poller.isPolling, "the poll outlived the last waiting step")
    XCTAssertEqual(checks.value.count, 4)
    // 10, 20, 40, 40 ms: the third gap is a doubled one, the last is held at the cap.
    let gaps = zip(checks.value.dropFirst(), checks.value).map { $0 - $1 }
    XCTAssertGreaterThanOrEqual(gaps[1], .milliseconds(39), "the gaps didn't grow: \(gaps)")
    XCTAssertGreaterThanOrEqual(gaps[2], .milliseconds(39), "\(gaps)")

    let after = Box(0)
    waiting.value = true
    poller.start(while: { waiting.value }, check: { after.value += 1 })
    poller.cancel()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(after.value, 0, "a cancelled poll still checked")
    XCTAssertFalse(poller.isPolling)
  }

  // MARK: boxd

  /// A command a step started, ending when the test says.
  private final class FakeCommand: RunningCommand, @unchecked Sendable {
    let link: URL? = URL(string: "https://app.boxd.sh/?session=s1")
    let lastLine: String?
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?
    private(set) var cancelled = false

    init(lastLine: String? = nil) { self.lastLine = lastLine }

    func finish(_ code: Int32) {
      let waiter = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
        status = code
        defer { self.waiter = nil }
        return self.waiter
      }
      waiter?.resume(returning: code)
    }

    func wait() async -> Int32 {
      await withCheckedContinuation { continuation in
        let done = lock.withLock { () -> Int32? in
          if status == nil { waiter = continuation }
          return status
        }
        if let done { continuation.resume(returning: done) }
      }
    }

    func cancel() {
      lock.withLock { cancelled = true }
      finish(9)
    }
  }

  /// boxd as a test sets it up: installed or not, and what its checks answer.
  private final class FakeBoxd {
    var installed = true
    var account: BoxdHostDriver.AccountState = .signedIn(FakeBoxd.ada)
    var gitHub: BoxdHostDriver.GitHubState = .connected
    var commands: [String: FakeCommand] = [:]
    var opened: [URL] = []

    static let ada = try! JSONDecoder().decode(
      BoxdHostDriver.Account.self,
      from: Data(
        (#"{"active_org":null,"user_id":"usr_1","display_name":"Ada","orgs":[{"active":true,"#
          + #""name":"Ada's default org"}]}"#).utf8))

    func command(_ name: String) -> FakeCommand {
      let command = commands[name] ?? FakeCommand()
      commands[name] = command
      return command
    }

    @MainActor var actions: BoxdSetup.Actions {
      BoxdSetup.Actions(
        isInstalled: { self.installed },
        install: { self.command("install") },
        account: { self.account },
        gitHub: { self.gitHub },
        signIn: { self.command("signIn") },
        connectGitHub: { self.command("connectGitHub") })
    }

    @MainActor func setup() -> BoxdSetup {
      BoxdSetup(actions: actions, open: { self.opened.append($0) })
    }
  }

  // Value: protects=each boxd answer shows the step it should, and Create enables exactly when boxd
  // is ready or couldn't be asked; fails_when=the step mapping or isReady regresses;
  // why_new=BoxdSetup is new; seam=Actions (stands in for boxd); no_claim=the sheet's rendering
  func testBoxdStepsFollowWhatBoxdSays() async {
    BoxdSetup.confirmedThisLaunch = false
    defer { BoxdSetup.confirmedThisLaunch = false }
    let boxd = FakeBoxd()

    boxd.installed = false
    var setup = boxd.setup()
    await setup.refresh()
    XCTAssertEqual(setup.install, .needed)
    XCTAssertEqual(setup.account, .locked)
    XCTAssertEqual(setup.gitHub, .locked)
    XCTAssertFalse(setup.isReady)

    boxd.installed = true
    boxd.account = .signedOut(nil)
    setup = boxd.setup()
    await setup.refresh()
    XCTAssertEqual(setup.account, .signedOut(nil))
    XCTAssertEqual(setup.gitHub, .locked, "GitHub waits on the account")
    XCTAssertFalse(setup.isReady)

    boxd.account = .signedIn(FakeBoxd.ada)
    boxd.gitHub = .notConnected
    setup = boxd.setup()
    await setup.refresh()
    XCTAssertEqual(setup.account, .signedIn(name: "Ada", org: "Ada's default org"))
    XCTAssertEqual(setup.gitHub, .needed)
    XCTAssertFalse(setup.isReady)
    XCTAssertFalse(BoxdSetup.confirmedThisLaunch)

    // Checks that couldn't answer don't hold the create back.
    boxd.account = .unknown("boxd auth: timed out after 60s")
    boxd.gitHub = .unknown("boxd manage integrations: timed out after 60s")
    setup = boxd.setup()
    await setup.refresh()
    XCTAssertTrue(setup.isReady)

    BoxdSetup.confirmedThisLaunch = false
    boxd.account = .signedIn(FakeBoxd.ada)
    boxd.gitHub = .connected
    let none = await BoxdSetup.needed(actions: boxd.actions)
    XCTAssertNil(none, "a ready account saw the sheet")
    XCTAssertTrue(BoxdSetup.confirmedThisLaunch)
  }

  // Value: protects=a step a click starts finishes when its command does, offers its page again,
  // and dies with the sheet; fails_when=the step doesn't re-check after the command, the link isn't
  // surfaced, or cancel leaves the command running; why_new=BoxdSetup is new; seam=Actions;
  // no_claim=boxd's real sign-in (manual, make app-run-boxd-fresh)
  func testSigningInFinishesWithBoxdsSignInAndStopsWithTheSheet() async throws {
    let boxd = FakeBoxd()
    boxd.account = .signedOut(nil)
    boxd.gitHub = .notConnected
    let setup = boxd.setup()
    await setup.refresh()

    let signingIn = Task { await setup.signIn() }
    for _ in 0..<100 where setup.link == nil { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(setup.account, .signingIn)
    setup.openLinkAgain()
    XCTAssertEqual(boxd.opened, [URL(string: "https://app.boxd.sh/?session=s1")!])
    boxd.account = .signedIn(FakeBoxd.ada)
    boxd.command("signIn").finish(0)
    await signingIn.value
    XCTAssertEqual(setup.account, .signedIn(name: "Ada", org: "Ada's default org"))
    XCTAssertEqual(setup.gitHub, .needed)

    // Stop: the user closed boxd's page. The step reads from boxd again and says nothing went wrong.
    let stopped = Task { await setup.connectGitHub() }
    for _ in 0..<100 where setup.gitHub != .connecting {
      try await Task.sleep(for: .milliseconds(20))
    }
    setup.stop()
    await stopped.value
    for _ in 0..<100 where setup.gitHub != .needed { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(setup.gitHub, .needed, "a stopped step didn't read from boxd again")
    XCTAssertTrue(boxd.command("connectGitHub").cancelled)
    boxd.commands["connectGitHub"] = nil

    let connecting = Task { await setup.connectGitHub() }
    for _ in 0..<100 where setup.gitHub != .connecting {
      try await Task.sleep(for: .milliseconds(20))
    }
    setup.cancel()
    await connecting.value
    XCTAssertTrue(boxd.command("connectGitHub").cancelled, "the sheet closed and boxd ran on")
    XCTAssertEqual(setup.gitHub, .connecting, "a step changed after the sheet closed")
  }

  // Value: protects=a failed install says why and can be tried again; fails_when=a failed installer
  // reads as installed or says nothing; why_new=BoxdSetup is new; seam=Actions; no_claim=the real
  // installer (read from boxd.sh/downloads/install.sh)
  func testAFailedInstallSaysTheInstallersLastWords() async throws {
    let boxd = FakeBoxd()
    boxd.installed = false
    boxd.commands["install"] = FakeCommand(lastLine: "x hash mismatch")
    let setup = boxd.setup()
    await setup.refresh()
    let installing = Task { await setup.installBoxd() }
    for _ in 0..<100 where setup.install != .installing {
      try await Task.sleep(for: .milliseconds(20))
    }
    boxd.command("install").finish(1)
    await installing.value
    XCTAssertEqual(setup.install, .failed("x hash mismatch"))
    XCTAssertFalse(setup.isReady)
  }

  // Value: protects=a sign-in or GitHub step that fails says why and stays retryable, and a step that
  // can't start says so; fails_when=a non-zero exit with the step undone reads as a wait or as done,
  // or a start error is swallowed; why_new=the existing boxd tests cover only success and a failed
  // install; seam=Actions; no_claim=boxd's real wording
  func testAStepThatFailsSaysWhyAndAStepThatCannotStartSaysSo() async throws {
    let boxd = FakeBoxd()
    boxd.account = .signedOut(nil)
    boxd.commands["signIn"] = FakeCommand(lastLine: "error: sign-in timed out")
    let setup = boxd.setup()
    await setup.refresh()
    let signingIn = Task { await setup.signIn() }
    for _ in 0..<100 where setup.account != .signingIn {
      try await Task.sleep(for: .milliseconds(20))
    }
    boxd.command("signIn").finish(1)
    await signingIn.value
    XCTAssertEqual(setup.account, .signedOut("error: sign-in timed out"))

    boxd.account = .signedIn(FakeBoxd.ada)
    boxd.gitHub = .notConnected
    boxd.commands["connectGitHub"] = FakeCommand(lastLine: "error: denied")
    await setup.refresh()
    let connecting = Task { await setup.connectGitHub() }
    for _ in 0..<100 where setup.gitHub != .connecting {
      try await Task.sleep(for: .milliseconds(20))
    }
    boxd.command("connectGitHub").finish(1)
    await connecting.value
    XCTAssertEqual(setup.gitHub, .failed("error: denied"))
    XCTAssertFalse(setup.isReady)

    struct CannotStart: LocalizedError { var errorDescription: String? { "no such file" } }
    var actions = boxd.actions
    actions.signIn = { throw CannotStart() }
    let broken = BoxdSetup(actions: actions, open: { _ in })
    await broken.signIn()
    XCTAssertEqual(broken.account, .failed("no such file"))

    // A sign-in that finishes but leaves one Workroom can't read: boxd changed its format.
    boxd.account = .unreadable
    boxd.commands["signIn"] = nil
    let unreadable = boxd.setup()
    await unreadable.refresh()
    XCTAssertEqual(unreadable.account, .signedOut("Workroom couldn't read boxd's sign-in."))
    let finishing = Task { await unreadable.signIn() }
    for _ in 0..<100 where unreadable.account != .signingIn {
      try await Task.sleep(for: .milliseconds(20))
    }
    boxd.command("signIn").finish(0)
    await finishing.value
    XCTAssertEqual(unreadable.account, .needsUpdate)
    XCTAssertFalse(unreadable.isReady)

    // Or leaves none where Workroom looks.
    boxd.account = .signedOut(nil)
    boxd.commands["signIn"] = nil
    let missing = boxd.setup()
    await missing.refresh()
    let signing = Task { await missing.signIn() }
    for _ in 0..<100 where missing.account != .signingIn {
      try await Task.sleep(for: .milliseconds(20))
    }
    boxd.command("signIn").finish(0)
    await signing.value
    XCTAssertEqual(missing.account, .needsUpdate)
  }

  // Value: protects=an installer that exits 0 but leaves no boxd isn't taken for installed, and a
  // launch's checks are skipped once boxd was seen ready; fails_when=install trusts the exit code
  // alone, or needed() asks boxd again after confirmedThisLaunch; why_new=only a failed exit and
  // the first ready check are covered; seam=Actions; no_claim=the real installer
  func testAnInstallerThatLeavesNoBoxdFailsAndAReadyLaunchIsNotCheckedAgain() async throws {
    BoxdSetup.confirmedThisLaunch = false
    defer { BoxdSetup.confirmedThisLaunch = false }
    let boxd = FakeBoxd()
    boxd.installed = false
    let setup = boxd.setup()
    await setup.refresh()
    let installing = Task { await setup.installBoxd() }
    for _ in 0..<100 where setup.install != .installing {
      try await Task.sleep(for: .milliseconds(20))
    }
    boxd.command("install").finish(0)
    await installing.value
    guard case .failed = setup.install else { return XCTFail("\(setup.install)") }

    boxd.installed = true
    boxd.gitHub = .notConnected
    let pending = await BoxdSetup.needed(actions: boxd.actions)
    XCTAssertNotNil(pending, "a user with GitHub undone skipped the setup")
    XCTAssertFalse(BoxdSetup.confirmedThisLaunch)

    BoxdSetup.confirmedThisLaunch = true
    let asked = Box(0)
    var actions = boxd.actions
    actions.isInstalled = {
      asked.value += 1
      return false
    }
    let skipped = await BoxdSetup.needed(actions: actions)
    XCTAssertNil(skipped)
    XCTAssertEqual(asked.value, 0, "boxd was checked again after it was seen ready")
  }

  // Value: protects=starting the poll again replaces the running one, so a sheet whose user acts
  // twice doesn't check twice as often; fails_when=start no longer cancels the poll it replaces;
  // why_new=the poller test covers one poll, its backoff and cancel only; seam=the first and cap
  // delays; no_claim=the 3 s / 30 s values
  func testStartingThePollAgainReplacesTheRunningPoll() async throws {
    let poller = SetupPoller(first: .milliseconds(10), cap: .milliseconds(10))
    let old = Box(0)
    let new = Box(0)
    poller.start(while: { true }, check: { old.value += 1 })
    poller.start(while: { true }, check: { new.value += 1 })
    try await Task.sleep(for: .milliseconds(100))
    poller.cancel()
    let seen = old.value
    XCTAssertEqual(seen, 0, "the replaced poll kept checking")
    XCTAssertGreaterThan(new.value, 0)
  }

  // Value: protects=New Workroom offers boxd and exe.dev whatever is installed, since a create's
  // setup installs boxd; fails_when=unavailability(of:) goes back to "not installed" for boxd;
  // why_new=the runtime entries are tested, the provider ones were not; seam=none;
  // no_claim=the menu rendering
  func testBoxdAndExeDevAreNeverUnavailableBecauseTheirSetupInstallsThem() {
    XCTAssertNil(RemoteWorkrooms.unavailability(of: .boxd))
    XCTAssertNil(RemoteWorkrooms.unavailability(of: .exeDev))
  }
}
