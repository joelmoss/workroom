import XCTest

@testable import Workroom

/// The quota segment's spoken label (`CodingAgentUsageSegment.quotaAccessibilityLabel`). Every
/// `CodingAgentUsageUITests` assertion reads this string; these pin the zero-usage branch, which used to
/// need an app launch of its own.
final class CodingAgentUsageSegmentLabelTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(fiveHourUsed: Double, weeklyUsed: Double) -> CodingAgentQuotaSnapshot {
    CodingAgentQuotaSnapshot(
      backend: .codex,
      windows: [
        CodingAgentQuotaWindow(
          kind: .fiveHour, usedPercentage: fiveHourUsed, duration: 5 * 60 * 60,
          resetsAt: now.addingTimeInterval(3.5 * 60 * 60)),
        CodingAgentQuotaWindow(
          kind: .weekly, usedPercentage: weeklyUsed, duration: 7 * 24 * 60 * 60,
          resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
      ], capturedAt: now)
  }

  /// Nothing used yet, so there is no pace to report: "0% used" with no pace phrase at all.
  func testZeroUsageOmitsPace() {
    let label = CodingAgentUsageSegment.quotaAccessibilityLabel(
      snapshot(fiveHourUsed: 0, weeklyUsed: 0), now: now)
    XCTAssertTrue(label.contains("5h quota 0% used"), label)
    XCTAssertTrue(label.contains("wk quota 0% used"), label)
    XCTAssertFalse(label.contains("in deficit"), label)
    XCTAssertFalse(label.contains("in reserve"), label)
    XCTAssertFalse(label.contains("pace"), label)
  }

  // MARK: Several Claude accounts (#480)

  private func account(_ slot: Int, _ alias: String?) -> ClaudeAccount {
    ClaudeAccount(slot: slot, alias: alias, email: "\(slot)@example.com", organizationName: nil)
  }

  /// Aliases are capped at 8 characters, a shared alias gets its slot so the two stay apart, and an
  /// account without one is its slot.
  func testAccountLabelsAreBoundedAndNeverAmbiguous() {
    let labels = CodingAgentUsageSegment.accountLabels([
      account(1, "ht"), account(2, nil), account(3, "averylongalias"), account(4, "ht"),
      account(5, "exactly8"),
    ])
    XCTAssertEqual(labels[1], "ht #1")
    XCTAssertEqual(labels[2], "#2")
    XCTAssertEqual(labels[3], "averylo…")
    XCTAssertEqual(labels[4], "ht #4")
    XCTAssertEqual(labels[5], "exactly8")
  }

  func testAnAccountsLabelIsSpokenWithItsQuota() {
    let label = CodingAgentUsageSegment.quotaAccessibilityLabel(
      snapshot(fiveHourUsed: 9, weeklyUsed: 63), accountLabel: "ht", now: now)
    XCTAssertTrue(label.hasPrefix("Codex ht quota. "), label)
  }

  func testAStaleReadingSaysHowOldItIs() {
    let old = CodingAgentQuotaSnapshot(
      backend: .claude, windows: snapshot(fiveHourUsed: 9, weeklyUsed: 63).windows,
      capturedAt: now.addingTimeInterval(-600))
    let label = CodingAgentUsageSegment.quotaAccessibilityLabel(old, now: now)
    XCTAssertTrue(label.hasSuffix("Updated 10 minutes ago."), label)
    let fresh = CodingAgentUsageSegment.quotaAccessibilityLabel(
      snapshot(fiveHourUsed: 9, weeklyUsed: 63), now: now)
    XCTAssertFalse(fresh.contains("Updated"), fresh)
  }

  /// A window past its reset draws empty with no pace pin, and says so.
  func testAWindowPastItsResetShowsEmptyWithoutAPin() {
    let expired = CodingAgentQuotaWindow(
      kind: .fiveHour, usedPercentage: 70, duration: 5 * 60 * 60,
      resetsAt: now.addingTimeInterval(-60))
    let shown = CodingAgentUsageSegment.displayed(expired, now: now)
    XCTAssertEqual(shown.usedPercentage, 0)
    XCTAssertNil(shown.marker)
    let label = CodingAgentUsageSegment.quotaAccessibilityLabel(
      CodingAgentQuotaSnapshot(backend: .claude, windows: [expired], capturedAt: now), now: now)
    XCTAssertTrue(label.contains("5h quota reset, nothing read since"), label)

    let live = snapshot(fiveHourUsed: 42, weeklyUsed: 0).windows[0]
    let liveShown = CodingAgentUsageSegment.displayed(live, now: now)
    XCTAssertEqual(liveShown.usedPercentage, 42)
    XCTAssertEqual(liveShown.marker, live.sustainablePacePercentage(at: now))
  }

  func testAnUnavailableAccountSpeaksItsReason() {
    XCTAssertEqual(
      CodingAgentUsageSegment.unavailableAccessibilityLabel(
        accountLabel: "ht", reason: "Sign in to this account again with cswap."),
      "Claude ht usage unavailable. Sign in to this account again with cswap.")
  }

  /// The control: with usage, each window speaks its own pace, so the test above isn't passing
  /// because the label never carries a pace.
  func testUsageSpeaksEachWindowsPace() {
    let snap = snapshot(fiveHourUsed: 42, weeklyUsed: 61)
    let label = CodingAgentUsageSegment.quotaAccessibilityLabel(snap, now: now)
    for window in snap.windows {
      XCTAssertTrue(
        label.contains(window.pace(at: now).accessibilityDescription),
        "\(window.kind) pace missing from: \(label)")
    }
  }
}
