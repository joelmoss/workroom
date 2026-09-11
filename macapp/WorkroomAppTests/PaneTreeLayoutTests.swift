import XCTest

@testable import Workroom

/// Pure split-geometry math used by the pane renderer (plan D5). Extracting it keeps the trickiest
/// arithmetic in the feature unit-testable even though the SwiftUI views themselves aren't.
final class PaneTreeLayoutTests: XCTestCase {
  private let divider = TerminalSessions.dividerThickness  // 4
  private let minW = TerminalSessions.minPaneWidth  // 300 — the tab strip's furniture sets this
  private let minH = TerminalSessions.minPaneHeight  // 150 since issue #150's title bar

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

/// The measured-rect pane floor (`PaneTreeLayout.canSplit`) behind
/// `AppStore.insertWorkroomSplit`'s drop guard. `TerminalSessions.fits` answers the same question
/// from a live `GhosttySurfaceView`'s bounds; the workroom pane tree has no surface to measure, so
/// this takes the rect the renderer's own plan produced.
final class PaneCanSplitTests: XCTestCase {

  private let divider = TerminalSessions.dividerThickness
  private let minW = TerminalSessions.minPaneWidth
  private let minH = TerminalSessions.minPaneHeight

  private func rect(w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: 0, y: 0, width: w, height: h)
  }

  func testExactlyAtTheFloorIsPermitted() {
    // Two floor-width halves plus the divider is the smallest pane that may still be split.
    let exact = minW * 2 + divider
    XCTAssertTrue(PaneTreeLayout.canSplit(rect(w: exact, h: 1000), along: .horizontal))
    let exactV = minH * 2 + divider
    XCTAssertTrue(PaneTreeLayout.canSplit(rect(w: 1000, h: exactV), along: .vertical))
  }

  func testOnePointUnderTheFloorIsRefused() {
    XCTAssertFalse(
      PaneTreeLayout.canSplit(rect(w: minW * 2 + divider - 1, h: 1000), along: .horizontal))
    XCTAssertFalse(
      PaneTreeLayout.canSplit(rect(w: 1000, h: minH * 2 + divider - 1), along: .vertical))
  }

  func testTheReportedRegressionWidthIsRefused() {
    // The measurement from the bug report: a third workroom chip dropped into a 348pt pane yielded
    // two 172pt panes.
    XCTAssertFalse(PaneTreeLayout.canSplit(rect(w: 348, h: 800), along: .horizontal))
  }

  func testEachAxisOnlyConsultsItsOwnDimension() {
    // A pane far too narrow to split side-by-side can still split top/bottom, and vice versa.
    XCTAssertTrue(PaneTreeLayout.canSplit(rect(w: 200, h: 1000), along: .vertical))
    XCTAssertFalse(PaneTreeLayout.canSplit(rect(w: 200, h: 1000), along: .horizontal))
  }

  func testUnmeasuredRectPermitsTheSplit() {
    // Matches `TerminalSessions.fits`' `available > 0` escape: nothing is laid out yet, so the
    // renderer's points-based clamp is the authority, not a floor applied to a zero rect.
    XCTAssertTrue(PaneTreeLayout.canSplit(.zero, along: .horizontal))
    XCTAssertTrue(PaneTreeLayout.canSplit(.zero, along: .vertical))
  }
}

/// The group-level measurements auto-even needs (issue #126). `canSplit` above asks whether ONE
/// rect can be halved; these ask what the whole tree does in a measured container — whether evening
/// would actually render evenly there, and whether every pane still clears the floors.
final class PaneGroupFitTests: XCTestCase {

  private let a = UUID()
  private let b = UUID()
  private let c = UUID()
  private let divider = TerminalSessions.dividerThickness
  private let minW = TerminalSessions.minPaneWidth
  private let minH = TerminalSessions.minPaneHeight

  /// `A | (B / C)` — one full-height pane beside two stacked ones, the mixed-orientation shape whose
  /// panes can only be equal by AREA.
  private func mixedTree(ratio: CGFloat = 0.5, inner: CGFloat = 0.5) -> PaneLayout<UUID> {
    .split(
      id: UUID(), orientation: .horizontal, ratio: ratio, first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: inner, first: .leaf(b),
        second: .leaf(c)))
  }

  private func rect(w: CGFloat, h: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: w, height: h) }

  // MARK: plansEvenly

  func testEvenedTreePlansEvenlyInARoomyContainer() {
    XCTAssertTrue(
      PaneTreeLayout.plansEvenly(mixedTree().equalized(), in: rect(w: 1200, h: 900)),
      "1200pt leaves A at 400 — above the 300pt floor, so the evened ratios survive")
  }

  func testTheClampDefeatsEveningInANarrowContainer() {
    // The measured case: 800pt of usable width. Evening wants A at 1/3 (≈266pt), the renderer clamps
    // it to the 300pt width floor, and A ends visibly smaller than B and C — even with the setting
    // on. Auto-even must see this coming and keep the user's dividers instead.
    XCTAssertFalse(
      PaneTreeLayout.plansEvenly(mixedTree().equalized(), in: rect(w: 800, h: 900)),
      "the per-axis floor clamp overrides the evened ratios here")
  }

  func testUnmeasuredContainerPlansEvenly() {
    // Nothing laid out yet ⇒ nothing to judge, same posture as `canSplit`'s zero rect.
    XCTAssertTrue(PaneTreeLayout.plansEvenly(mixedTree().equalized(), in: .zero))
  }

  func testASkewedTreeDoesNotPlanEvenly() {
    // Guards the tolerance from the other side: a deliberately lopsided tree must not read as even,
    // or auto-even would decline to fix exactly the layouts it exists for.
    XCTAssertFalse(
      PaneTreeLayout.plansEvenly(mixedTree(ratio: 0.8), in: rect(w: 1200, h: 900)))
  }

  // MARK: fitsEveryPane

  func testEveryPaneFitsWhenTheGroupHasRoom() {
    XCTAssertTrue(PaneTreeLayout.fitsEveryPane(mixedTree().equalized(), in: rect(w: 1200, h: 900)))
  }

  func testAPaneUnderTheWidthFloorFails() {
    // Three side-by-side panes need 3 × minW plus two dividers; one point under and the container
    // cannot hold them, whatever the ratios say.
    let tree = PaneLayout<UUID>.split(
      id: UUID(), orientation: .horizontal, ratio: 1.0 / 3.0, first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(b),
        second: .leaf(c)))
    let tight = minW * 3 + divider * 2 - 1
    XCTAssertFalse(PaneTreeLayout.fitsEveryPane(tree, in: rect(w: tight, h: 900)))
    XCTAssertTrue(PaneTreeLayout.fitsEveryPane(tree, in: rect(w: tight + 2, h: 900)))
  }

  func testBothAxesAreChecked() {
    // Wide enough, far too short: the stacked pair can't clear the height floor.
    XCTAssertFalse(
      PaneTreeLayout.fitsEveryPane(mixedTree().equalized(), in: rect(w: 1200, h: minH * 2 - 1)))
  }

  func testUnmeasuredContainerFitsEveryPane() {
    XCTAssertTrue(PaneTreeLayout.fitsEveryPane(mixedTree(), in: .zero))
  }

  // MARK: evenedIfHonourable

  func testDisabledLeavesTheTreeAlone() {
    let skewed = mixedTree(ratio: 0.8)
    XCTAssertEqual(
      PaneTreeLayout.evenedIfHonourable(skewed, in: rect(w: 1200, h: 900), enabled: false), skewed)
  }

  func testEnabledEvensWhenTheContainerCanHonourIt() {
    // One tree, built once: split nodes carry a `UUID` id, so two separately-built trees of the same
    // shape are never `==`.
    let skewed = mixedTree(ratio: 0.8)
    let evened = PaneTreeLayout.evenedIfHonourable(
      skewed, in: rect(w: 1200, h: 900), enabled: true)
    XCTAssertEqual(evened, skewed.equalized())
  }

  func testEnabledKeepsTheDividersWhenTheContainerCannot() {
    // The 800pt case again, now through the step the mutation actually calls: rather than ship a
    // third outcome that is neither even nor what the user dragged, leave the tree untouched.
    let skewed = mixedTree(ratio: 0.8)
    XCTAssertEqual(
      PaneTreeLayout.evenedIfHonourable(skewed, in: rect(w: 800, h: 900), enabled: true), skewed)
  }

  func testANilContainerEvensOptimistically() {
    let skewed = mixedTree(ratio: 0.8)
    XCTAssertEqual(
      PaneTreeLayout.evenedIfHonourable(skewed, in: nil, enabled: true), skewed.equalized())
  }
}

/// The "already under a floor" half of the group-aware guard (issue #126, caught in manual QA). A
/// pane can sit below a floor with no split to blame: drag an ancestor divider far enough and
/// `lengths` cannot honour the floor at all, so it splits what is left evenly. Judging a later
/// split against the floor itself then refuses work that takes nothing off the offending axis.
final class PaneFitNotWorseTests: XCTestCase {

  private let a = UUID()
  private let b = UUID()
  private let c = UUID()

  private func rect(w: CGFloat, h: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: w, height: h) }

  /// `a | (b | c)` — the shape the QA pass produced. The root clamp keeps the right COLUMN at or
  /// above the floor, so the squeeze has to come from the nested split inside it: 368pt of usable
  /// width cannot give two panes 300pt each, so `lengths` abandons the floor and halves it, leaving
  /// two 184pt panes that no single divider drag is responsible for.
  private func squeezed() -> PaneLayout<UUID> {
    .split(
      id: UUID(), orientation: .horizontal, ratio: 0.715, first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(b),
        second: .leaf(c)))
  }

  func testASplitThatTakesNothingOffTheSqueezedAxisIsAdmitted() {
    let current = squeezed()
    // Split `c` along its HEIGHT: the right column stays exactly as narrow as it already was.
    let prospective = current.inserting(
      UUID(), beside: c, orientation: .vertical, newLeafFirst: false, ratio: 0.5)
    let container = rect(w: 1300, h: 985)
    XCTAssertFalse(
      PaneTreeLayout.fitsEveryPane(prospective, in: container),
      "precondition: the absolute-floor rule refuses it, because the column is already too narrow")
    XCTAssertTrue(
      PaneTreeLayout.fitsEveryPane(prospective, in: container, notWorseThan: current),
      "but it makes nothing worse, so it must be admitted")
  }

  func testASplitThatNarrowsTheSqueezedAxisFurtherIsRefused() {
    let current = squeezed()
    let prospective = current.inserting(
      UUID(), beside: c, orientation: .horizontal, newLeafFirst: false, ratio: 0.5)
    XCTAssertFalse(
      PaneTreeLayout.fitsEveryPane(prospective, in: rect(w: 1300, h: 985), notWorseThan: current),
      "halving an already-too-narrow column is exactly what the floor is for")
  }

  func testAHealthyTreeIsStillJudgedAgainstTheFloor() {
    // Nothing is under a floor to begin with, so `notWorseThan` must not become a licence to drop
    // below one: a third pane in 700pt cannot clear 300pt, whatever the current tree looks like.
    let current = PaneLayout<UUID>.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    let prospective = current.inserting(
      c, beside: b, orientation: .horizontal, newLeafFirst: false, ratio: 0.5)
    XCTAssertFalse(
      PaneTreeLayout.fitsEveryPane(prospective, in: rect(w: 700, h: 900), notWorseThan: current))
  }
}
