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
