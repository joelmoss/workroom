import AppKit
import XCTest

@testable import Workroom

/// Direct coverage for the shared `settle(_:seconds:until:)` helper itself (see `Settle.swift`) —
/// this is new shared infrastructure whose blast radius is 4 call sites at once, so its own
/// early-exit and ceiling-enforcement contracts get a dedicated test rather than being inferred
/// only from the 4 rewritten call sites.
final class SettleTests: XCTestCase {

  @MainActor
  func testReturnsEarlyOnceConditionIsTrue() {
    let view = NSView()
    let start = Date()
    var checks = 0
    settle(
      view, seconds: 2,
      until: {
        checks += 1
        return checks >= 3
      })
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(
      elapsed, 1.0, "should return well before the 2s ceiling once the condition flips true")
  }

  @MainActor
  func testRespectsTheCeilingWhenConditionNeverBecomesTrue() {
    let view = NSView()
    let start = Date()
    settle(view, seconds: 0.3, until: { false })
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertGreaterThanOrEqual(elapsed, 0.3, "must not return before the ceiling")
    XCTAssertLessThan(elapsed, 1.5, "must not hang well past the ceiling either")
  }

  @MainActor
  func testDefaultConditionBehavesLikeTheOldUnconditionalBusyWait() {
    let view = NSView()
    let start = Date()
    settle(view, seconds: 0.3)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertGreaterThanOrEqual(
      elapsed, 0.3,
      "omitting `until` must burn the full ceiling, matching every pre-existing "
        + "call site that has no observable convergence signal")
  }
}
