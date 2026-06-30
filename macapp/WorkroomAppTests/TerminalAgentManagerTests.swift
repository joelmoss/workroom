import XCTest

@testable import Workroom

/// A claude `--output-format json` envelope whose result is the compact diagnosis JSON. File-scope
/// (not a static on the test class) so it's usable from default-argument expressions.
private let successEnvelope: String = {
  let inner = #"{\"summary\":\"port in use\",\"fix\":\"kill $(lsof -ti:3000)\"}"#
  return #"{"type":"result","is_error":false,"result":"\#(inner)"}"#
}()

/// The inline-agent state machine (issue #49, T6): disposition → banner, manual vs auto, cooldown,
/// cancel-supersede, lifecycle, and outcome mapping — all driven through a fake `AgentRunning`, no
/// real CLI. The manager is `@MainActor`, so is the test.
@MainActor
final class TerminalAgentManagerTests: XCTestCase {
  private let target: TerminalTarget.ID = "wr|/p|x"

  private func makeManager(
    outcome: AgentRunOutcome = .success(stdout: successEnvelope),
    auto: Bool = false,
    now: @escaping () -> Date = { Date(timeIntervalSince1970: 1000) },
    cooldown: TimeInterval = 20
  ) -> (TerminalAgentManager, FakeAgentRunner) {
    let runner = FakeAgentRunner(outcome: outcome)
    let manager = TerminalAgentManager(
      runner: runner, featureEnabled: { true }, autoDiagnoseEnabled: { auto },
      redactSecrets: { true }, now: now, cooldown: cooldown, inlineCwd: "/var/neutral", timeout: 5)
    return (manager, runner)
  }

  private func failure(
    _ exit: Int32, command: String? = "rails server", run: Bool = false, remote: Bool = false,
    output: String = "Address already in use"
  ) -> FailedCommand {
    FailedCommand(
      command: command, cwd: "/app", exitCode: exit, shell: "zsh", output: output, isRunTab: run,
      isRemote: remote)
  }

  // MARK: gating + disposition

  func testDisabledFeatureDoesNothing() {
    let runner = FakeAgentRunner(outcome: .success(stdout: successEnvelope))
    let manager = TerminalAgentManager(runner: runner, featureEnabled: { false })
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    XCTAssertNil(manager.banners[tab])
  }

  func testSkipLeavesNoBanner() {
    let (manager, _) = makeManager()
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(0))  // exit 0 → skip
    XCTAssertNil(manager.banners[tab])
  }

  func testEligibleManualShowsAwaiting() {
    let (manager, runner) = makeManager(auto: false)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    XCTAssertEqual(manager.banners[tab], .awaitingDiagnose(failure(1)))
    XCTAssertEqual(runner.calls, 0, "manual must not auto-run")
  }

  func testBenignProgramSoftSuppressedButManualWorks() async {
    let (manager, runner) = makeManager(auto: true)  // even with auto on, benign is suppressed
    let tab = UUID()
    let fail = failure(1, command: "grep needle log")
    manager.commandFinished(tab: tab, target: target, failure: fail)
    XCTAssertNil(manager.banners[tab], "benign non-zero shows no banner")
    XCTAssertEqual(runner.calls, 0)

    manager.diagnose(tab: tab, target: target)  // manual override still works
    await manager.inFlight[tab]?.value
    XCTAssertEqual(runner.calls, 1)
    if case .ready = manager.banners[tab] {
    } else {
      XCTFail("expected ready, got \(String(describing: manager.banners[tab]))")
    }
  }

  func testRemoteShowsCaveatAndNeverRuns() {
    let (manager, runner) = makeManager(auto: true)
    let tab = UUID()
    let fail = failure(1, remote: true)
    manager.commandFinished(tab: tab, target: target, failure: fail)
    XCTAssertEqual(manager.banners[tab], .remoteCaveat(fail))
    XCTAssertEqual(runner.calls, 0)
    manager.diagnose(tab: tab, target: target)  // even explicit Diagnose is a no-op for remote
    XCTAssertEqual(runner.calls, 0)
  }

  // MARK: auto + cooldown

  func testAutoFiresAndResolvesToReady() async {
    let (manager, runner) = makeManager(auto: true)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    await manager.inFlight[tab]?.value
    XCTAssertEqual(runner.calls, 1)
    XCTAssertEqual(runner.lastCwd, "/var/neutral", "inline runs in the neutral cwd (token opt)")
    guard case .ready(_, let diag) = manager.banners[tab] else {
      return XCTFail("expected ready, got \(String(describing: manager.banners[tab]))")
    }
    XCTAssertEqual(diag.summary, "port in use")
    XCTAssertEqual(diag.fixCommand, "kill $(lsof -ti:3000)")
  }

  func testCooldownBlocksSecondAutoFire() async {
    var clock = Date(timeIntervalSince1970: 1000)
    let (manager, runner) = makeManager(auto: true, now: { clock }, cooldown: 20)
    let tabA = UUID()
    manager.commandFinished(tab: tabA, target: target, failure: failure(1))
    await manager.inFlight[tabA]?.value
    XCTAssertEqual(runner.calls, 1)

    // 5s later (< cooldown): a new eligible failure on the same target must NOT auto-fire.
    clock = Date(timeIntervalSince1970: 1005)
    let tabB = UUID()
    manager.commandFinished(tab: tabB, target: target, failure: failure(1, command: "npm run dev"))
    XCTAssertEqual(manager.banners[tabB], .awaitingDiagnose(failure(1, command: "npm run dev")))
    XCTAssertEqual(runner.calls, 1, "still just the first run")

    // 25s after the first (> cooldown): auto-fire resumes.
    clock = Date(timeIntervalSince1970: 1025)
    let tabC = UUID()
    manager.commandFinished(tab: tabC, target: target, failure: failure(1, command: "yarn dev"))
    await manager.inFlight[tabC]?.value
    XCTAssertEqual(runner.calls, 2)
  }

  // MARK: lifecycle (cancel-supersede / dismiss / close)

  func testDismissBeforeResultSkipsApply() async {
    let (manager, _) = makeManager(auto: false)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    manager.diagnose(tab: tab, target: target)  // spawns the task (loading)
    let task = manager.inFlight[tab]
    manager.dismiss(tab: tab)  // cancels before the task runs
    await task?.value
    XCTAssertNil(manager.banners[tab], "a dismissed/cancelled run must not paint a banner")
  }

  func testTabClosedClearsEverything() async {
    let (manager, _) = makeManager(auto: false)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    manager.diagnose(tab: tab, target: target)
    let task = manager.inFlight[tab]
    manager.tabClosed(tab)
    await task?.value
    XCTAssertNil(manager.banners[tab])
    XCTAssertNil(manager.inFlight[tab])
  }

  // MARK: outcome mapping

  func testCliNotFoundMapsToFailure() async {
    let (manager, _) = makeManager(outcome: .cliNotFound, auto: true)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    await manager.inFlight[tab]?.value
    XCTAssertEqual(manager.banners[tab], .failure(failure(1), .cliNotFound))
  }

  func testMalformedSuccessMapsToFailure() async {
    let (manager, _) = makeManager(outcome: .success(stdout: "not json"), auto: true)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    await manager.inFlight[tab]?.value
    XCTAssertEqual(manager.banners[tab], .failure(failure(1), .malformed))
  }

  // MARK: auto-diagnose opt-in (first manual Diagnose)

  private func optInManager(prompted: Bool, spy: OptInSpy) -> TerminalAgentManager {
    TerminalAgentManager(
      runner: FakeAgentRunner(outcome: .success(stdout: successEnvelope)),
      featureEnabled: { true }, autoDiagnoseEnabled: { false }, redactSecrets: { false },
      hasPromptedAutoOptIn: { prompted }, persistAutoOptIn: { spy.calls.append($0) },
      inlineCwd: "/var/neutral", timeout: 5)
  }

  func testFirstManualDiagnoseOffersOptIn() {
    let manager = optInManager(prompted: false, spy: OptInSpy())
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    manager.diagnose(tab: tab, target: target)
    XCTAssertEqual(manager.autoOptInPromptTab, tab, "first manual Diagnose offers the opt-in")
  }

  func testOptInNotOfferedWhenAlreadyPrompted() {
    let manager = optInManager(prompted: true, spy: OptInSpy())
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    manager.diagnose(tab: tab, target: target)
    XCTAssertNil(manager.autoOptInPromptTab)
  }

  func testAcceptOptInPersistsEnable() {
    let spy = OptInSpy()
    let manager = optInManager(prompted: false, spy: spy)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    manager.diagnose(tab: tab, target: target)
    manager.respondToAutoOptIn(enable: true)
    XCTAssertEqual(spy.calls, [true])
    XCTAssertNil(manager.autoOptInPromptTab)
  }

  func testDeclineOptInPersistsDisableAndStopsAsking() {
    let spy = OptInSpy()
    let manager = optInManager(prompted: false, spy: spy)
    let tab = UUID()
    manager.commandFinished(tab: tab, target: target, failure: failure(1))
    manager.diagnose(tab: tab, target: target)
    manager.respondToAutoOptIn(enable: false)
    XCTAssertEqual(spy.calls, [false])
    XCTAssertNil(manager.autoOptInPromptTab)
  }
}

/// Records the opt-in persistence calls so the tests can assert what was saved.
private final class OptInSpy {
  var calls: [Bool] = []
}

/// Records calls and returns a canned outcome, so the manager runs without a real `claude`/`codex`.
private final class FakeAgentRunner: AgentRunning, @unchecked Sendable {
  let outcome: AgentRunOutcome
  private(set) var calls = 0
  private(set) var lastCwd: String?

  init(outcome: AgentRunOutcome) { self.outcome = outcome }

  func diagnoseInline(systemPrompt: String?, prompt: String, cwd: String, timeout: TimeInterval)
    async -> AgentRunOutcome
  {
    calls += 1
    lastCwd = cwd
    return outcome
  }
}
