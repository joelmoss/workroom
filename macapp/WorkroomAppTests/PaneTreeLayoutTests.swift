import XCTest

@testable import Workroom

/// Pure split-geometry math used by the pane renderer (plan D5). Extracting it keeps the trickiest
/// arithmetic in the feature unit-testable even though the SwiftUI views themselves aren't.
final class PaneTreeLayoutTests: XCTestCase {
  private let divider = TerminalSessions.dividerThickness  // 4
  private let minW = TerminalSessions.minPaneWidth  // 300 — the tab strip's furniture sets this
  private let minH = TerminalSessions.minPaneHeight  // 120

  func testLengthsSumToUsableAndSplitEvenly() {
    let (a, b) = PaneTreeLayout.lengths(total: 1000, ratio: 0.5, along: .horizontal)
    XCTAssertEqual(a + b, 1000 - divider, accuracy: 0.5)
    XCTAssertEqual(a, b, accuracy: 1.5)  // even ±rounding
  }

  func testLengthsClampSecondToMinPane() {
    let (a, b) = PaneTreeLayout.lengths(total: 1000, ratio: 0.95, along: .horizontal)
    XCTAssertEqual(b, minW, accuracy: 0.5)  // second can't go below the width floor
    XCTAssertEqual(a + b, 1000 - divider, accuracy: 0.5)
  }

  func testLengthsClampFirstToMinPane() {
    let (a, _) = PaneTreeLayout.lengths(total: 1000, ratio: 0.01, along: .horizontal)
    XCTAssertEqual(a, minW, accuracy: 0.5)
  }

  func testLengthsTooSmallFallsBackToEven() {
    let (a, b) = PaneTreeLayout.lengths(total: 500, ratio: 0.9, along: .horizontal)
    XCTAssertEqual(a + b, 500 - divider, accuracy: 0.5)
    XCTAssertEqual(a, b, accuracy: 1.5)  // ignores ratio when it can't honor the floor
  }

  /// The point of splitting the floor per axis: the SAME container and ratio resolve differently
  /// depending on which axis is being divided. 496pt of usable space can't seat two 300pt-wide panes
  /// (so a side-by-side split gives up and centres) but seats two 120pt-tall ones comfortably.
  func testTheFloorFollowsTheAxisBeingDivided() {
    let stacked = PaneTreeLayout.lengths(total: 500, ratio: 0.9, along: .vertical)
    XCTAssertEqual(stacked.second, minH, accuracy: 0.5)  // honours the ratio, clamped to 120
    let sideBySide = PaneTreeLayout.lengths(total: 500, ratio: 0.9, along: .horizontal)
    XCTAssertEqual(sideBySide.first, sideBySide.second, accuracy: 1.5)  // too narrow → even
  }

  func testClampRatioKeepsBothPanesUsable() {
    let usable = 1000 - divider
    let minR = minW / usable
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(0.99, total: 1000, along: .horizontal), 1 - minR, accuracy: 0.001)
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(0.0, total: 1000, along: .horizontal), minR, accuracy: 0.001)
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(0.5, total: 1000, along: .horizontal), 0.5, accuracy: 0.001)
  }

  /// Too small to honour the floor → the ratio passes through untouched. It must NOT centre: the
  /// caller persists whatever comes back, so centring would erase the user's split the moment the
  /// window got narrow. `lengths` is what makes it *render* centred (asserted above).
  func testClampRatioTooSmallPassesTheRatioThrough() {
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(0.9, total: 500, along: .horizontal), 0.9, accuracy: 0.001)
  }

  /// The regression behind the pass-through: narrowing a container below the floor and nudging the
  /// divider used to write `0.5` over a stored 70/30, unrecoverably. Round-trip the stored ratio
  /// through a narrow container and back out to a wide one — it has to survive.
  ///
  /// 1400pt for the wide leg, not 1000: at 1000 the second pane of a 70/30 is 996×0.3 = 298.8pt, so
  /// the floor legitimately trims 0.7 and the round-trip would be measuring the ordinary clamp
  /// instead of the pass-through.
  func testANarrowContainerDoesNotErodeTheStoredRatio() {
    let stored: CGFloat = 0.7
    let whileNarrow = PaneTreeLayout.clampRatio(stored, total: 500, along: .horizontal)
    XCTAssertEqual(whileNarrow, stored, accuracy: 0.001)
    // …and once there's room again the divider is right back where the user left it.
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(whileNarrow, total: 1400, along: .horizontal), stored,
      accuracy: 0.001)
    // Meanwhile the narrow container still DRAWS evenly — the floor is honoured by `lengths`.
    let (a, b) = PaneTreeLayout.lengths(total: 500, ratio: stored, along: .horizontal)
    XCTAssertEqual(a, b, accuracy: 1.5)
  }

  /// The clamp's half of `testTheFloorFollowsTheAxisBeingDivided`: at 500pt a dragged divider is
  /// clamped on the height axis but unconstrained on the width axis (which can't seat two panes at
  /// all, so it defers to `lengths` rather than clamping).
  func testClampRatioFloorFollowsTheAxis() {
    let usable = 500 - divider
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(0.9, total: 500, along: .vertical), 1 - minH / usable,
      accuracy: 0.001)
    XCTAssertEqual(
      PaneTreeLayout.clampRatio(0.9, total: 500, along: .horizontal), 0.9, accuracy: 0.001)
  }

  // MARK: Drop targeting (Phase 2)

  func testNearestEdgePicksTheNearerSide() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 100)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 10, y: 50), in: r), .left)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 90, y: 50), in: r), .right)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 50, y: 10), in: r), .top)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 50, y: 90), in: r), .bottom)
  }

  func testNearestEdgeAccountsForAspect() {
    let wide = CGRect(x: 0, y: 0, width: 400, height: 100)
    // Near the top-center of a wide pane → top, not left, because edges tile by normalised distance.
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 200, y: 10), in: wide), .top)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 20, y: 50), in: wide), .left)
  }

  func testDropTargetFindsPaneOrNil() {
    let a = UUID()
    let b = UUID()
    let panes = [
      a: CGRect(x: 0, y: 0, width: 100, height: 100),
      b: CGRect(x: 107, y: 0, width: 100, height: 100),
    ]
    let hitA = PaneTreeLayout.dropTarget(at: CGPoint(x: 90, y: 50), panes: panes)
    XCTAssertEqual(hitA?.tab, a)
    XCTAssertEqual(hitA?.edge, .right)
    XCTAssertEqual(PaneTreeLayout.dropTarget(at: CGPoint(x: 150, y: 50), panes: panes)?.tab, b)
    // gap/outside
    XCTAssertNil(PaneTreeLayout.dropTarget(at: CGPoint(x: 500, y: 50), panes: panes))
  }

  func testEdgeBandIsHalfThePane() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 80)
    XCTAssertEqual(
      PaneTreeLayout.edgeBand(.right, in: r), CGRect(x: 50, y: 0, width: 50, height: 80))
    XCTAssertEqual(PaneTreeLayout.edgeBand(.top, in: r), CGRect(x: 0, y: 0, width: 100, height: 40))
    XCTAssertEqual(
      PaneTreeLayout.edgeBand(.bottom, in: r), CGRect(x: 0, y: 40, width: 100, height: 40))
  }

  // MARK: Directional pane focus (Phase 3)

  func testAdjacentPaneAcrossHorizontalSplit() {
    let a = UUID()
    let b = UUID()
    let layout = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    XCTAssertEqual(PaneTreeLayout.adjacentPane(to: a, direction: .right, in: layout), b)
    XCTAssertEqual(PaneTreeLayout.adjacentPane(to: b, direction: .left, in: layout), a)
    XCTAssertNil(PaneTreeLayout.adjacentPane(to: a, direction: .left, in: layout))
    XCTAssertNil(PaneTreeLayout.adjacentPane(to: a, direction: .up, in: layout))
  }

  func testAdjacentPaneInNestedSplit() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    // A | (B / C)
    let layout = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
    )
    XCTAssertEqual(PaneTreeLayout.adjacentPane(to: b, direction: .down, in: layout), c)
    XCTAssertEqual(PaneTreeLayout.adjacentPane(to: c, direction: .up, in: layout), b)
    XCTAssertEqual(PaneTreeLayout.adjacentPane(to: b, direction: .left, in: layout), a)
    XCTAssertEqual(PaneTreeLayout.adjacentPane(to: c, direction: .left, in: layout), a)
    XCTAssertNil(PaneTreeLayout.adjacentPane(to: b, direction: .right, in: layout))
    let fromA = PaneTreeLayout.adjacentPane(to: a, direction: .right, in: layout)
    XCTAssertTrue(fromA == b || fromA == c)  // a right-column pane
  }
}
