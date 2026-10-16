import Foundation
import XCTest

@testable import Workroom

/// When the usage monitor starts cswap and the Codex app server, and what it does with what they
/// return (#480). The file-based sources (bridge file, Codex rollouts) refresh on their own
/// schedule and must never start either process.
@MainActor
final class CodingAgentUsagePollingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_180_000)
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-polling-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func window(_ used: Double, resetsIn seconds: TimeInterval = 3600)
    -> CodingAgentQuotaWindow
  {
    CodingAgentQuotaWindow(
      kind: .fiveHour, usedPercentage: used, duration: 5 * 3600,
      resetsAt: now.addingTimeInterval(seconds))
  }

  private func account(_ slot: Int, used: Double) -> ClaudeAccountUsage {
    ClaudeAccountUsage(
      account: ClaudeAccount(
        slot: slot, alias: nil, email: "\(slot)@example.com", organizationName: nil),
      snapshot: CodingAgentQuotaSnapshot(
        backend: .claude, windows: [window(used)], capturedAt: now),
      unavailableReason: nil)
  }

  private func monitor(
    _ pollers: CodingAgentUsagePollers, enabled: Bool = true, interval: TimeInterval = 180,
    start: Bool = false
  ) -> CodingAgentUsageMonitor {
    CodingAgentUsageMonitor(
      codexSessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
      claudeCacheURL: root.appendingPathComponent("claude-rate-limits.json"),
      now: { self.now }, startAutomatically: start, pollers: pollers, pollInterval: interval,
      pollingEnabled: { enabled })
  }

  private func waitForPoll(_ monitor: CodingAgentUsageMonitor, count: Int = 1) async {
    for _ in 0..<200 where monitor.completedPollCount < count {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  func testFileRefreshesNeverStartCswapOrTheCodexServer() async {
    let calls = PollCounter()
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in
          await calls.bump()
          return .notInstalled
        },
        codexServer: { _ in
          await calls.bump()
          return .notInstalled
        }))
    for _ in 0..<3 { monitor.refresh() }
    for _ in 0..<200 where monitor.completedReadCount == 0 {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThan(monitor.completedReadCount, 0)
    let count = await calls.value
    XCTAssertEqual(count, 0)
  }

  func testAPollAlreadyRunningIsJoinedNotRepeated() async {
    let calls = PollCounter()
    let gate = PollGate()
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in
          await calls.bump()
          await gate.wait()
          return .notInstalled
        },
        codexServer: { _ in
          await calls.bump()
          await gate.wait()
          return .notInstalled
        }))
    monitor.poll()
    monitor.poll()
    try? await Task.sleep(nanoseconds: 50_000_000)
    await gate.open()
    await waitForPoll(monitor)
    let count = await calls.value
    XCTAssertEqual(count, 2, "one cswap and one Codex read, not two of each")
  }

  func testNothingPollsWhileNoFooterShowsUsage() async {
    let calls = PollCounter()
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in
          await calls.bump()
          return .notInstalled
        },
        codexServer: { _ in
          await calls.bump()
          return .notInstalled
        }),
      enabled: false, interval: 0.05, start: true)
    monitor.poll()
    try? await Task.sleep(nanoseconds: 300_000_000)
    let count = await calls.value
    XCTAssertEqual(count, 0)
  }

  func testTheTimerPolls() async {
    let monitor = monitor(
      CodingAgentUsagePollers(cswap: { _ in .notInstalled }, codexServer: { _ in .notInstalled }),
      interval: 0.05, start: true)
    await waitForPoll(monitor, count: 2)
    XCTAssertGreaterThanOrEqual(monitor.completedPollCount, 2)
  }

  func testCswapAccountsStandInForTheBridgeAndAFailureKeepsThem() async {
    let replies = PollReplies<CswapUsage.Read>([
      .accounts([account(1, used: 9), account(2, used: 92)], activeSlot: 2),
      .failed("cswap took longer than 30 seconds."),
      .notInstalled,
    ])
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in await replies.next() }, codexServer: { _ in .notInstalled }))

    monitor.poll()
    await waitForPoll(monitor, count: 1)
    XCTAssertEqual(monitor.claudeAccounts?.map(\.account.slot), [1, 2])
    XCTAssertEqual(monitor.claudeActiveSlot, 2)

    monitor.poll()
    await waitForPoll(monitor, count: 2)
    XCTAssertEqual(
      monitor.claudeAccounts?.map(\.account.slot), [1, 2], "a failed poll keeps the last accounts")

    monitor.poll()
    await waitForPoll(monitor, count: 3)
    XCTAssertNil(monitor.claudeAccounts, "without cswap, Claude usage comes from the bridge")
    XCTAssertTrue(monitor.claudeUsesBridge)
  }

  /// Until cswap has answered once, Claude shows nothing: neither the bridge's reading nor its
  /// "Enable usage…" may flash up for a cswap user at launch. A first poll that fails falls back.
  func testClaudeWaitsForCswapThenFallsBackIfItNeverAnswered() async {
    let replies = PollReplies<CswapUsage.Read>([
      .accounts([account(1, used: 9)], activeSlot: 1), .failed("cswap exited with status 1."),
    ])
    let withCswap = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in await replies.next() }, codexServer: { _ in .notInstalled }))
    XCTAssertFalse(withCswap.claudeUsesBridge, "nothing is known before the first poll")
    withCswap.poll()
    await waitForPoll(withCswap)
    XCTAssertFalse(withCswap.claudeUsesBridge)
    withCswap.poll()
    await waitForPoll(withCswap, count: 2)
    XCTAssertFalse(withCswap.claudeUsesBridge, "a later failure keeps the accounts")

    let failing = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in .failed("cswap exited with status 1.") }, codexServer: { _ in .notInstalled })
    )
    failing.poll()
    await waitForPoll(failing)
    XCTAssertNil(failing.claudeAccounts)
    XCTAssertTrue(failing.claudeUsesBridge, "a cswap that never answered falls back to the bridge")
  }

  func testCodexShowsTheNewerOfTheServerAndTheRollouts() async throws {
    let older = CodingAgentQuotaSnapshot(
      backend: .codex, windows: [window(20)], capturedAt: now.addingTimeInterval(-600))
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in .notInstalled }, codexServer: { _ in .snapshot(older) }))
    monitor.poll()
    await waitForPoll(monitor)
    XCTAssertEqual(monitor.snapshot(for: .codex)?.windows.map(\.usedPercentage), [20])
  }

  func testAWindowPastItsResetIsKeptNotDropped() async {
    let expired = CodingAgentQuotaSnapshot(
      backend: .codex, windows: [window(70, resetsIn: -60)],
      capturedAt: now.addingTimeInterval(-7200))
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in .notInstalled }, codexServer: { _ in .snapshot(expired) }))
    monitor.poll()
    await waitForPoll(monitor)
    XCTAssertEqual(monitor.snapshot(for: .codex)?.windows.count, 1)
    XCTAssertTrue(monitor.snapshot(for: .codex)?.isStale(at: now) ?? false)
  }

  /// Without cswap and with the bridge off, the footer offers "Enable usage…" once Claude has run,
  /// until the user enables it or chooses "Don't Ask Again" (#480).
  func testTheEnableOfferStopsAfterDontAskAgain() async {
    let monitor = monitor(
      CodingAgentUsagePollers(cswap: { _ in .notInstalled }, codexServer: { _ in .notInstalled }))
    monitor.poll()
    await waitForPoll(monitor)
    XCTAssertEqual(
      CodingAgentUsageSegment.items(
        monitor: monitor, bridgeState: .disabled, claudeSeen: true, enableDeclined: false),
      [.enableClaude])
    XCTAssertEqual(
      CodingAgentUsageSegment.items(
        monitor: monitor, bridgeState: .disabled, claudeSeen: true, enableDeclined: true),
      [])
    XCTAssertEqual(
      CodingAgentUsageSegment.items(
        monitor: monitor, bridgeState: .disabled, claudeSeen: false, enableDeclined: false),
      [], "nothing is offered before Claude has run")
  }

  /// Value: protects=a pane footer showing the right account (or nothing) for the running Claude and
  /// the poll failure reason reaching the popover; fails_when=a pane without a read profile shows
  /// some account, the default login stops mapping to cswap's active slot, an unmatched profile
  /// guesses, a failed Codex poll leaves no reason or keeps it after recovery;
  /// why_new=ClaudeProfileResolution is tested alone, nothing exercises PaneUsageSlot.item or
  /// applyPoll's failure bookkeeping; seam=none; no_claim=drawing or fitting.
  func testAPaneShowsItsProfilesAccountAndAFailedPollSaysWhy() async {
    let replies = PollReplies<CodexAppServerUsage.Read>([
      .failed("The Codex app server didn't answer in time."),
      .notInstalled,
    ])
    let accounts = [account(1, used: 9), account(2, used: 92)]
    let monitor = monitor(
      CodingAgentUsagePollers(
        cswap: { _ in .accounts(accounts, activeSlot: 2) },
        codexServer: { _ in await replies.next() }))
    monitor.poll()
    await waitForPoll(monitor)

    func used(_ profile: PaneClaudeProfile?) -> [Double]? {
      guard
        case .reading(let snapshot, _, _, _)? = PaneUsageSlot.item(
          backend: .claude, claudeProfile: profile, monitor: monitor)
      else { return nil }
      return snapshot.windows.map(\.usedPercentage)
    }
    XCTAssertNil(used(nil), "a profile not read yet shows nothing")
    XCTAssertEqual(used(.reported("")), [92], "unset is the active account")
    XCTAssertEqual(used(.reported("/b/sessions/1-a_example.com")), [9])
    XCTAssertNil(used(.reported("/elsewhere/.claude-work")), "an unknown profile is not guessed")
    XCTAssertNil(used(.notReported))

    XCTAssertEqual(monitor.pollFailures[.codex], "The Codex app server didn't answer in time.")
    monitor.poll()
    await waitForPoll(monitor, count: 2)
    XCTAssertNil(monitor.pollFailures[.codex], "a later poll that does not fail clears the reason")
  }
}

private actor PollCounter {
  private(set) var value = 0
  func bump() { value += 1 }
}

/// Holds every waiter until `open`.
private actor PollGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

/// Hands out a fixed sequence of replies, repeating the last.
private actor PollReplies<Value: Sendable> {
  private var values: [Value]
  init(_ values: [Value]) { self.values = values }
  func next() -> Value { values.count > 1 ? values.removeFirst() : values[0] }
}
