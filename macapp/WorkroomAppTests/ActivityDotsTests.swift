import XCTest

@testable import Workroom

/// The sidebar's busy mark: each dot peaks in its own turn, left to right, and rests dim between.
final class ActivityDotsTests: XCTestCase {
  func testEachDotPeaksInTurnAndRestsDim() {
    let stagger = ActivityDots.stagger
    for index in 0..<3 {
      let peak = 0.3 + Double(index) * stagger
      XCTAssertEqual(ActivityDots.opacity(phase: peak, index: index), 1, accuracy: 0.0001)
      XCTAssertEqual(
        ActivityDots.opacity(phase: peak + 0.5, index: index), ActivityDots.dim, accuracy: 0.0001)
    }
    // At the first dot's peak the later ones are still rising behind it.
    XCTAssertGreaterThan(
      ActivityDots.opacity(phase: 0.3, index: 1), ActivityDots.opacity(phase: 0.3, index: 2))
  }

  func testTheWaveLoopsWithoutAJump() {
    for index in 0..<3 {
      XCTAssertEqual(
        ActivityDots.opacity(phase: 0, index: index), ActivityDots.opacity(phase: 1, index: index),
        accuracy: 0.0001)
    }
  }
}
