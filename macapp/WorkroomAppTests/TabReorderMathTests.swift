import CoreGraphics
import XCTest

@testable import Workroom

/// Unit tests for the pure drag-to-reorder math extracted from `TerminalTabStrip` (issue #23 prep).
/// These pin the behavior that both the terminal tab strip and the Workrooms tab bar depend on.
final class TabReorderMathTests: XCTestCase {
  // Three equal 100pt chips with 4pt spacing → each neighbour's span is 104, half-span 52.
  private let widths: [CGFloat] = [100, 100, 100]
  private let spacing: CGFloat = 4

  // MARK: dropTargetIndex

  func testNoTranslationStaysPut() {
    XCTAssertEqual(
      TabReorder.dropTargetIndex(widths: widths, draggedIndex: 1, translation: 0, spacing: spacing),
      1)
  }

  func testSmallTranslationDoesNotCross() {
    // 40 < half-span (52) → no crossing.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 40, spacing: spacing),
      0)
  }

  func testDragRightCrossesOneNeighbour() {
    // 60 > 52 (one half-span) but < 156 → land on index 1.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 60, spacing: spacing),
      1)
  }

  func testDragRightCrossesTwoNeighboursToLastSlot() {
    // 160 > 52 and > 104+52=156 → land on the last index.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 160, spacing: spacing),
      2)
  }

  func testDragLeftCrossesOneNeighbour() {
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 2, translation: -60, spacing: spacing),
      1)
  }

  func testDragLeftReachesFirstSlot() {
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 2, translation: -160, spacing: spacing),
      0)
  }

  func testDragRightClampsAtLastSlot() {
    // Huge translation can't exceed the last index.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 99_999, spacing: spacing),
      2)
  }

  // MARK: gapShift

  func testGapShiftNilTargetIsZero() {
    XCTAssertEqual(
      TabReorder.gapShift(index: 1, draggedIndex: 0, target: nil, amount: 104), 0)
    XCTAssertEqual(
      TabReorder.gapShift(index: 1, draggedIndex: nil, target: 2, amount: 104), 0)
  }

  func testGapShiftDraggingRightSlidesInterveningChipsLeft() {
    // Dragging 0 → 2: chips at 1 and 2 slide left by `amount`; chip 0 (the dragged slot) doesn't.
    XCTAssertEqual(TabReorder.gapShift(index: 1, draggedIndex: 0, target: 2, amount: 104), -104)
    XCTAssertEqual(TabReorder.gapShift(index: 2, draggedIndex: 0, target: 2, amount: 104), -104)
    XCTAssertEqual(TabReorder.gapShift(index: 0, draggedIndex: 0, target: 2, amount: 104), 0)
  }

  func testGapShiftDraggingLeftSlidesInterveningChipsRight() {
    // Dragging 2 → 0: chips at 0 and 1 slide right by `amount`; chip 2 doesn't.
    XCTAssertEqual(TabReorder.gapShift(index: 0, draggedIndex: 2, target: 0, amount: 104), 104)
    XCTAssertEqual(TabReorder.gapShift(index: 1, draggedIndex: 2, target: 0, amount: 104), 104)
    XCTAssertEqual(TabReorder.gapShift(index: 2, draggedIndex: 2, target: 0, amount: 104), 0)
  }
}

/// Unit tests for the overflow/pinning math both tab strips share (issue #129): when the chip run plus
/// the trailing controls no longer fit, the controls pin at the trailing edge so the "+" is never
/// scrolled out of reach.
final class TabStripOverflowTests: XCTestCase {
  private let spacing: CGFloat = 4

  // MARK: runWidth

  func testRunWidthOfNoChipsIsZero() {
    XCTAssertEqual(TabStripOverflow.runWidth([], spacing: spacing), 0)
  }

  func testRunWidthOfOneChipHasNoSpacing() {
    XCTAssertEqual(TabStripOverflow.runWidth([100], spacing: spacing), 100)
  }

  func testRunWidthCountsOneFewerGapThanChips() {
    // 3 chips → 2 gaps: 300 + 8.
    XCTAssertEqual(TabStripOverflow.runWidth([100, 100, 100], spacing: spacing), 308)
  }

  // MARK: pinsControls — the boundary

  /// The inline layout is exactly `leadingInset + run + inlineAddLead + add + gutter` wide. With
  /// `epsilon: 0` an exact fit must NOT pin (the comparison is strictly greater-than).
  func testExactFitDoesNotPin() {
    // 8 + 300 + 6 + 20 + 8 = 342.
    XCTAssertFalse(
      TabStripOverflow.pinsControls(
        runWidth: 300, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 8,
        epsilon: 0))
  }

  func testOnePointOverPins() {
    XCTAssertTrue(
      TabStripOverflow.pinsControls(
        runWidth: 301, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 8,
        epsilon: 0))
  }

  // MARK: pinsControls — epsilon absorbs resize jitter

  func testEpsilonAbsorbsSubPixelOvershoot() {
    // 0.4pt over the boundary is rounding noise during a live resize, not a real overflow.
    XCTAssertFalse(
      TabStripOverflow.pinsControls(
        runWidth: 300.4, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 8))
  }

  func testEpsilonDoesNotSwallowARealPoint() {
    XCTAssertTrue(
      TabStripOverflow.pinsControls(
        runWidth: 301, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 8))
  }

  // MARK: pinsControls — the gutter is load-bearing

  /// The gutter is what stops a clipped chip abutting the trailing controls — symptom 1 of issue #129.
  /// The same run must fit without it and overflow with it, or the strip would only pin once a chip is
  /// already touching.
  func testGutterIsLoadBearing() {
    let fits = TabStripOverflow.pinsControls(
      runWidth: 308, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 0,
      epsilon: 0)
    let overflows = TabStripOverflow.pinsControls(
      runWidth: 308, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 8,
      epsilon: 0)
    XCTAssertFalse(fits)
    XCTAssertTrue(overflows)
  }

  // MARK: pinsControls — the leading inset shifts the threshold

  /// The leading inset is a term in the fit, so a wider one must be able to flip the decision on its
  /// own. With `available: 342` a 4pt inset fits runs up to 304pt and an 8pt one up to 300pt, so 302
  /// sits in the window where only the inset decides.
  ///
  /// (This used to be the solo-8pt vs split-member-4pt comparison. Issue #139 gave every workroom the
  /// same card geometry, so the strip has ONE inset — 4pt — and the old test was asserting a
  /// distinction the app no longer draws. The arithmetic is still worth pinning; the product claim it
  /// carried is gone.)
  func testAWiderLeadingInsetCanFlipTheOverflowDecision() {
    XCTAssertTrue(
      TabStripOverflow.pinsControls(
        runWidth: 302, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6, gutter: 8,
        epsilon: 0))
    XCTAssertFalse(
      TabStripOverflow.pinsControls(
        runWidth: 302, add: 20, available: 342, leadingInset: 4, inlineAddLead: 6, gutter: 8,
        epsilon: 0))
  }

  // MARK: pinsControls — never pin before anything is measured

  /// On the first layout pass the `@State` widths are still 0. Pinning then would flash the controls
  /// across the bar; the guard renders inline instead and the single correction follows.
  func testUnmeasuredInputsNeverPin() {
    XCTAssertFalse(
      TabStripOverflow.pinsControls(
        runWidth: 300, add: 20, available: 0, leadingInset: 8, inlineAddLead: 6))
    XCTAssertFalse(
      TabStripOverflow.pinsControls(
        runWidth: 0, add: 20, available: 342, leadingInset: 8, inlineAddLead: 6))
    XCTAssertFalse(
      TabStripOverflow.pinsControls(
        runWidth: 300, add: 0, available: 342, leadingInset: 8, inlineAddLead: 6))
  }

  // MARK: pinsControls — monotonic, and stable once pinned

  func testShrinkingAvailableWidthNeverUnpins() {
    var pinned = false
    for available in stride(from: CGFloat(400), through: 100, by: -10) {
      let now = TabStripOverflow.pinsControls(
        runWidth: 308, add: 20, available: available, leadingInset: 8, inlineAddLead: 6)
      if pinned { XCTAssertTrue(now, "un-pinned at available=\(available) after pinning") }
      pinned = pinned || now
    }
    XCTAssertTrue(pinned, "a 308pt run should pin somewhere between 400pt and 100pt")
  }

  /// The anti-oscillation property, as a test rather than a comment. Once the controls pin they stop
  /// occupying the scroller's viewport, so a predicate written against the *viewport* would see the
  /// smaller number and might un-pin, then re-pin. This predicate reads the width the strip was
  /// granted, which the pinning does not change — so re-evaluating with the same inputs is stable, and
  /// feeding it the (smaller) post-pin viewport is not something the API permits: there is no such
  /// parameter. This test pins the intent so a later "simplification" to content-vs-viewport fails here.
  func testDecisionIsStableAcrossReevaluation() {
    let inputs = (runWidth: CGFloat(308), add: CGFloat(20), available: CGFloat(320))
    let first = TabStripOverflow.pinsControls(
      runWidth: inputs.runWidth, add: inputs.add, available: inputs.available, leadingInset: 8,
      inlineAddLead: 6)
    XCTAssertTrue(first)
    for _ in 0..<5 {
      XCTAssertEqual(
        TabStripOverflow.pinsControls(
          runWidth: inputs.runWidth, add: inputs.add, available: inputs.available, leadingInset: 8,
          inlineAddLead: 6),
        first, "the decision must not depend on how many times it is evaluated")
    }
  }
}

/// Unit tests for the split-group bracket's geometry, lifted out of `TerminalTabStrip.splitRunRect`
/// (issue #129 review). REGRESSION COVERAGE: this arithmetic had none, and the #129 restructure moves
/// the bracket's `background` from the scroll-content row onto the chip run — a mis-alignment there is
/// silent and no other test would catch it.
final class TabStripSplitRunTests: XCTestCase {
  private let widths: [CGFloat] = [100, 100, 100, 100]
  private let spacing: CGFloat = 4

  func testNoMembersDrawsNoBracket() {
    XCTAssertNil(TabStripSplitRun.rect(widths: widths, memberIndices: [], spacing: spacing))
  }

  /// One member is not a split — the bracket would frame a lone chip and read as selection.
  func testSingleMemberDrawsNoBracket() {
    XCTAssertNil(TabStripSplitRun.rect(widths: widths, memberIndices: [1], spacing: spacing))
  }

  func testGroupAtRunStartHasZeroOffset() {
    let rect = TabStripSplitRun.rect(widths: widths, memberIndices: [0, 1], spacing: spacing)
    XCTAssertEqual(rect?.x, 0)
    // Two chips, one gap between them.
    XCTAssertEqual(rect?.width, 204)
  }

  func testGroupInRunMiddleOffsetsByPrecedingChipsAndGaps() {
    let rect = TabStripSplitRun.rect(widths: widths, memberIndices: [1, 2], spacing: spacing)
    // One preceding chip plus the gap that follows it.
    XCTAssertEqual(rect?.x, 104)
    XCTAssertEqual(rect?.width, 204)
  }

  func testGroupAtRunEnd() {
    let rect = TabStripSplitRun.rect(widths: widths, memberIndices: [2, 3], spacing: spacing)
    XCTAssertEqual(rect?.x, 208)
    XCTAssertEqual(rect?.width, 204)
  }

  func testThreeMemberGroupSpansTwoGaps() {
    let rect = TabStripSplitRun.rect(widths: widths, memberIndices: [1, 2, 3], spacing: spacing)
    XCTAssertEqual(rect?.x, 104)
    XCTAssertEqual(rect?.width, 308)
  }

  /// Members are contiguous by construction (the display order guarantees it), but a stale index set
  /// mid-update must span rather than crash or return a negative width.
  func testNonContiguousMembersSpanTheWholeRun() {
    let rect = TabStripSplitRun.rect(widths: widths, memberIndices: [0, 3], spacing: spacing)
    XCTAssertEqual(rect?.x, 0)
    XCTAssertEqual(rect?.width, 412)
  }

  /// A member index past the end means the caller's widths haven't caught up with its model yet — draw
  /// nothing rather than reading out of bounds.
  func testOutOfRangeMemberDrawsNoBracket() {
    XCTAssertNil(TabStripSplitRun.rect(widths: widths, memberIndices: [2, 9], spacing: spacing))
    XCTAssertNil(TabStripSplitRun.rect(widths: [], memberIndices: [0, 1], spacing: spacing))
  }
}

/// Unit tests for `TabReorderDrag<ID>` — the stateful choreography `TerminalTabStrip` and
/// `WorkroomTabBar` used to each hand-roll (3 `@State` vars + near-duplicate gesture code) and had
/// already independently discovered and fixed the same bug in. These pin that fix at the shared
/// type, so a future edit can't reintroduce it in either strip.
final class TabReorderDragTests: XCTestCase {
  private let ids = ["a", "b", "c"]
  // Three equal 100pt chips with 4pt spacing, matching TabReorderMathTests's fixture.
  private let widths: [String: CGFloat] = ["a": 100, "b": 100, "c": 100]
  private let spacing: CGFloat = 4

  private func makeDrag() -> TabReorderDrag<String> {
    var drag = TabReorderDrag<String>()
    drag.setWidths(widths)
    return drag
  }

  func testFreshDragIsNotDragging() {
    let drag = makeDrag()
    XCTAssertFalse(drag.isDragging)
    XCTAssertNil(drag.id)
    XCTAssertEqual(drag.draggedWidth, 0)
  }

  func testUpdateLatchesTheFirstChipAndTracksTranslation() {
    var drag = makeDrag()
    drag.update("b", translation: 30)
    XCTAssertEqual(drag.id, "b")
    XCTAssertEqual(drag.translation, 30)
    XCTAssertEqual(drag.draggedWidth, 100)
  }

  /// Mirrors both strips' `if draggingID == nil { draggingID = tab.id }` / `guard draggingID ==
  /// tab.id else { return }`: once a chip has latched the drag, a different chip's gesture
  /// callback (a SwiftUI quirk this codebase has hit before) must not steal or perturb it.
  func testUpdateIgnoresADifferentChipOnceLatched() {
    var drag = makeDrag()
    drag.update("b", translation: 30)
    drag.update("a", translation: 999)
    XCTAssertEqual(drag.id, "b")
    XCTAssertEqual(drag.translation, 30)
  }

  func testDropIndexNilWhenNotDragging() {
    let drag = makeDrag()
    XCTAssertNil(drag.dropIndex(ids: ids, spacing: spacing, suspendedByPaneDrag: false))
  }

  /// A chip dragged down into a pane stops opening a reorder gap.
  func testDropIndexNilWhenSuspendedByPaneDrag() {
    var drag = makeDrag()
    drag.update("a", translation: 60)
    XCTAssertNil(drag.dropIndex(ids: ids, spacing: spacing, suspendedByPaneDrag: true))
  }

  func testDropIndexMatchesTheSharedMath() {
    var drag = makeDrag()
    drag.update("a", translation: 60)  // crosses one neighbour, per TabReorderMathTests.
    XCTAssertEqual(drag.dropIndex(ids: ids, spacing: spacing, suspendedByPaneDrag: false), 1)
  }

  /// THE bug both strips independently fixed: a fast/coarse drag's last `onChanged` sample
  /// (`translation`) can land short of `onEnded`'s true final displacement. `commit` must resolve
  /// off the caller-supplied `finalTranslation`, never the live `translation` field.
  func testCommitUsesFinalTranslationNotLiveTranslation() {
    var drag = makeDrag()
    drag.update("a", translation: 5)  // stale/under-shot sample: would not cross any neighbour.
    let move = drag.commit(ids: ids, spacing: spacing, finalTranslation: 60)  // true release point.
    XCTAssertEqual(move?.from, 0)
    XCTAssertEqual(move?.to, 1)
  }

  func testCommitReturnsNilWhenDropIndexDidNotChange() {
    var drag = makeDrag()
    drag.update("a", translation: 5)
    XCTAssertNil(drag.commit(ids: ids, spacing: spacing, finalTranslation: 5))
  }

  func testCommitReturnsNilWhenNothingWasDragging() {
    var drag = makeDrag()
    XCTAssertNil(drag.commit(ids: ids, spacing: spacing, finalTranslation: 60))
  }

  /// `commit` must reset drag state even when it returns nil — otherwise a no-op drop (or one with
  /// an unchanged index) would leave a stale `id`/`translation` haunting the next render.
  func testCommitAlwaysResetsStateRegardlessOfOutcome() {
    var drag = makeDrag()
    drag.update("a", translation: 5)
    _ = drag.commit(ids: ids, spacing: spacing, finalTranslation: 5)  // nil: unchanged index.
    XCTAssertFalse(drag.isDragging)
    XCTAssertNil(drag.id)
    XCTAssertEqual(drag.translation, 0)

    drag.update("b", translation: 60)
    _ = drag.commit(ids: ids, spacing: spacing, finalTranslation: 60)  // non-nil: real move.
    XCTAssertFalse(drag.isDragging)
    XCTAssertEqual(drag.translation, 0)
  }

  func testCancelResetsWithoutReturningAMove() {
    var drag = makeDrag()
    drag.update("a", translation: 60)
    drag.cancel()
    XCTAssertFalse(drag.isDragging)
    XCTAssertNil(drag.id)
    XCTAssertEqual(drag.translation, 0)
  }
}
