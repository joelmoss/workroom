import AppKit
import XCTest

@testable import Workroom

/// `RunningUnderline`'s sweep is a Core Animation gradient so the main thread does no per-frame work
/// (the SwiftUI `repeatForever` it replaced cost ~a third of a core while any pane was running).
/// These pin the gate that starts and stops it and the travel it is built with.
@MainActor
final class SweepViewTests: XCTestCase {
  func testSweepsOnlyInAKeyVisibleWindowWithWidth() {
    XCTAssertTrue(SweepView.shouldSweep(isKey: true, isVisible: true, width: 80))
    XCTAssertFalse(SweepView.shouldSweep(isKey: false, isVisible: true, width: 80), "not key")
    XCTAssertFalse(SweepView.shouldSweep(isKey: true, isVisible: false, width: 80), "occluded")
    XCTAssertFalse(SweepView.shouldSweep(isKey: true, isVisible: true, width: 0), "unlaid-out")
  }

  func testSweepTravelsTheTrackAndStopsOnDemand() {
    let view = SweepView(color: .systemBlue)
    view.frame = NSRect(x: 0, y: 0, width: 100, height: 2)
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.isSweeping, "no window → no animation")

    view.setSweeping(true)
    XCTAssertTrue(view.isSweeping)
    let sweep = view.layer?.sublayers?.first?.animation(forKey: SweepView.animationKey)
    let basic = sweep as? CABasicAnimation
    XCTAssertEqual(basic?.keyPath, "transform.translation.x")
    // The highlight is 40% of a 100pt track and starts just off the leading edge, so it travels the
    // track width plus its own width to leave at the trailing edge.
    XCTAssertEqual(basic?.toValue as? CGFloat, 140)
    XCTAssertEqual(basic?.duration, SweepView.duration)
    XCTAssertEqual(basic?.repeatCount, .infinity)

    view.setSweeping(true)
    XCTAssertTrue(
      view.layer?.sublayers?.first?.animation(forKey: SweepView.animationKey) === sweep,
      "re-asking to sweep must not restart the highlight mid-travel")

    view.setSweeping(false)
    XCTAssertFalse(view.isSweeping)
  }

  // Value: protects=clicks and drag-reorders on a busy chip's bottom edge still reach the chip;
  // fails_when=SweepView becomes hit-testable (the hitTest override is dropped); why_new=no other
  // test touches event routing; seam=none; no_claim=SwiftUI gesture delivery itself.
  func testTheSweepNeverTakesTheClick() {
    let view = SweepView(color: .systemBlue)
    view.frame = NSRect(x: 0, y: 0, width: 100, height: 2)
    XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 1)), "the chip's gestures own this strip")
  }

  // Value: protects=a theme change recolours the running sweep; fails_when=the color didSet stops
  // updating the gradient stops (the highlight keeps the old theme colour); why_new=the other tests
  // never change colour; seam=none; no_claim=window-dependent gating or width-change rebuild.
  func testColorChangeRecoloursTheHighlight() throws {
    let view = SweepView(color: .systemBlue)
    let gradient = try XCTUnwrap(view.layer?.sublayers?.first as? CAGradientLayer)
    let before = try XCTUnwrap(gradient.colors as? [CGColor])
    view.color = .systemRed
    let after = try XCTUnwrap(gradient.colors as? [CGColor])
    XCTAssertEqual(after[1], NSColor.systemRed.cgColor, "midpoint is the opaque colour")
    XCTAssertEqual(after[0].alpha, 0)
    XCTAssertNotEqual(before[1], after[1])
  }
}
