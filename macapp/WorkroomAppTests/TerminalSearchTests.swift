import XCTest

@testable import Workroom

/// Unit tests for the two pure, engine-free seams of terminal scrollback find (`TerminalSearch.swift`).
/// Everything past these needs a live libghostty surface + PTY and is covered by manual QA
/// (`QA-libghostty.md`); these pin the parts that cross the C boundary as plain data.
final class TerminalSearchTests: XCTestCase {

  // MARK: TerminalSearchAction.bindingString (app → engine)

  func testStartAndEndBindingStrings() {
    XCTAssertEqual(TerminalSearchAction.start.bindingString, "start_search")
    XCTAssertEqual(TerminalSearchAction.end.bindingString, "end_search")
  }

  func testNeedleBindingString() {
    XCTAssertEqual(TerminalSearchAction.setNeedle("foo").bindingString, "search:foo")
  }

  func testEmptyNeedleIsTheCancelForm() {
    // An empty needle is libghostty's documented "cancel the search" form — what we send when the
    // field is cleared. Must stay `search:` (not, say, `end_search`).
    XCTAssertEqual(TerminalSearchAction.setNeedle("").bindingString, "search:")
  }

  func testNeedleBindingStringPreservesUTF8AndColons() {
    // The needle is forwarded verbatim across the C boundary — Unicode and a literal colon must
    // survive (the colon is only the first separator, so `a:b` stays `a:b`).
    XCTAssertEqual(TerminalSearchAction.setNeedle("café→naïve").bindingString, "search:café→naïve")
    XCTAssertEqual(TerminalSearchAction.setNeedle("a:b").bindingString, "search:a:b")
  }

  func testNavigateBindingStrings() {
    XCTAssertEqual(TerminalSearchAction.navigate(.next).bindingString, "navigate_search:next")
    XCTAssertEqual(
      TerminalSearchAction.navigate(.previous).bindingString, "navigate_search:previous")
  }

  // MARK: TerminalSearchAction.navigationPlan (direction mapping + host-side wrap)
  //
  // `selected` is libghostty's RAW 0-based index in its OWN newest→oldest order: `0` is the
  // bottom-most match, `total - 1` the top-most; `< 0` = none. Find Next/Previous are INVERTED from
  // the engine's `navigate_search` (which walks newest→oldest), so Find Next emits engine `previous`
  // (toward index 0 / the bottom) and Find Previous emits engine `next`. The user-facing top-down
  // position is `total - selected`. (Verified against Ghostty's `search_selected = sel.idx`.)
  // The direction, both wraps and the no-selection step are pinned through `TerminalSearchModel`
  // (its only caller) in the model tests below; these are the cases that have no model twin.

  func testNavigationPlanFindPreviousStepsEngineNext() {
    XCTAssertEqual(
      TerminalSearchAction.navigationPlan(findNext: false, selected: 5, total: 12), [.next])
  }

  func testNavigationPlanSingleMatchDoesNotWrap() {
    // One match (index 0, total 1): nowhere to wrap to. A single (engine no-op) step.
    XCTAssertEqual(
      TerminalSearchAction.navigationPlan(findNext: true, selected: 0, total: 1), [.previous])
    XCTAssertEqual(
      TerminalSearchAction.navigationPlan(findNext: false, selected: 0, total: 1), [.next])
  }

  func testNavigationPlanNoMatchesIsEmpty() {
    XCTAssertEqual(TerminalSearchAction.navigationPlan(findNext: true, selected: -1, total: 0), [])
    XCTAssertEqual(TerminalSearchAction.navigationPlan(findNext: false, selected: -1, total: 0), [])
  }

  // MARK: TerminalSearchState.reduce (engine → app)

  func testStartOpensSearchWithNoSelection() {
    // Fresh search: no match selected yet → `selected == -1` (NOT 0, which is a real match index).
    let state = TerminalSearchState.reduce(nil, .start(needle: ""))
    XCTAssertEqual(state, TerminalSearchState(needle: "", total: 0, selected: -1))
  }

  func testStartCarriesPrefilledNeedle() {
    // `search_selection` opens the bar pre-filled with the selection.
    let state = TerminalSearchState.reduce(nil, .start(needle: "needle"))
    XCTAssertEqual(state?.needle, "needle")
  }

  func testTotalAndSelectedKeepRawZeroBasedIndex() {
    // The engine reports a 0-based index; we keep it verbatim (index 3 = the 4th of 12 matches).
    var state = TerminalSearchState.reduce(nil, .start(needle: "x"))
    state = TerminalSearchState.reduce(state, .total(12))
    state = TerminalSearchState.reduce(state, .selected(3))
    XCTAssertEqual(state, TerminalSearchState(needle: "x", total: 12, selected: 3))
  }

  func testIndexZeroIsAMatchNotNoSelection() {
    // Index 0 (the bottom match) must stay 0 — distinct from "no match" (-1) — so end-of-list wrap
    // detection fires on a real end match, never on "nothing selected yet".
    var state = TerminalSearchState.reduce(nil, .start(needle: "x"))
    state = TerminalSearchState.reduce(state, .selected(0))
    XCTAssertEqual(state?.selected, 0)
  }

  func testNegativeSelectedNormalisesToMinusOne() {
    // libghostty reports a negative index for "no current match"; we normalise it to -1 (not 0).
    var state = TerminalSearchState.reduce(nil, .start(needle: "x"))
    state = TerminalSearchState.reduce(state, .selected(-1))
    XCTAssertEqual(state?.selected, -1)
  }

  func testEndClosesSearch() {
    let open = TerminalSearchState.reduce(nil, .start(needle: "x"))
    XCTAssertNil(TerminalSearchState.reduce(open, .end))
  }

  func testStrayCountBeforeStartIsIgnored() {
    // A `SEARCH_TOTAL` arriving before `START_SEARCH` must not conjure a bar (stays closed) — and
    // must not crash on the nil current state.
    XCTAssertNil(TerminalSearchState.reduce(nil, .total(5)))
    XCTAssertNil(TerminalSearchState.reduce(nil, .selected(2)))
  }

  // MARK: TerminalSearchModel — the live ⌘G path (engine events → navigate → emitted actions)
  //
  // These drive the model with the SAME 0-based events libghostty emits, then capture what
  // `navigate(_:)` pushes back to the engine. This is the seam the unit-level `navigationPlan`
  // tests can't reach: it pins the index base the model actually receives, so a 1-based vs 0-based
  // mix-up (which leaves wrap silently dead) fails here.

  /// A model wired to a recording `perform`, opened on `total` matches with the engine sitting on
  /// 0-based index `selected`. Returns the model and the captured-actions box (cleared of setup).
  private func openModel(total: Int, selected: Int) -> (
    TerminalSearchModel, () -> [TerminalSearchAction]
  ) {
    let model = TerminalSearchModel()
    var sent: [TerminalSearchAction] = []
    model.perform = { sent.append($0) }
    model.start()
    model.apply(.start(needle: "x"))
    model.apply(.total(total))
    if selected >= 0 { model.apply(.selected(selected)) }
    sent.removeAll()
    return (model, { sent })
  }

  func testModelFindNextInMiddleStepsEnginePrevious() {
    // Find Next (⌘G) maps to engine `previous` (one match down the screen).
    let (model, sent) = openModel(total: 12, selected: 5)
    model.navigate(.next)
    XCTAssertEqual(sent(), [.navigate(.previous)])
  }

  func testModelFindNextWrapsAtBottom() {
    // On the bottom match (index 0), Find Next (⌘G) wraps to the top via 11 engine `next` steps.
    let (model, sent) = openModel(total: 12, selected: 0)
    model.navigate(.next)
    XCTAssertEqual(sent(), Array(repeating: TerminalSearchAction.navigate(.next), count: 11))
  }

  func testModelFindPreviousWrapsAtTop() {
    // On the top match (index 11), Find Previous (⇧⌘G) wraps to the bottom via 11 `previous` steps.
    let (model, sent) = openModel(total: 12, selected: 11)
    model.navigate(.previous)
    XCTAssertEqual(sent(), Array(repeating: TerminalSearchAction.navigate(.previous), count: 11))
  }

  func testModelNavigateWithNoSelectionDoesNotWrap() {
    // Just typed, nothing selected yet (-1): a single (inverted) step, never a wrap burst.
    let (model, sent) = openModel(total: 12, selected: -1)
    model.navigate(.next)
    XCTAssertEqual(sent(), [.navigate(.previous)])
    let (model2, sent2) = openModel(total: 12, selected: -1)
    model2.navigate(.previous)
    XCTAssertEqual(sent2(), [.navigate(.next)])
  }

  func testModelNavigateWhileClosedDoesNothing() {
    let model = TerminalSearchModel()
    var sent: [TerminalSearchAction] = []
    model.perform = { sent.append($0) }
    model.navigate(.next)  // never opened
    XCTAssertEqual(sent, [])
  }

  // MARK: TerminalSearchModel.start (⌘F open vs. refocus)

  func testStartWhileClosedOpensAndSendsStart() {
    let model = TerminalSearchModel()
    var sent: [TerminalSearchAction] = []
    model.perform = { sent.append($0) }
    model.start()
    XCTAssertTrue(model.isActive)
    XCTAssertEqual(sent, [.start])
    XCTAssertEqual(model.focusRequest, 1)
  }

  func testStartWhileOpenRefocusesWithoutRestartingEngine() {
    // ⌘F again while the bar is open must NOT re-send `start_search` (which would restart the live
    // search) — it only bumps `focusRequest` so the bar pulls focus back to the field.
    let model = TerminalSearchModel()
    var sent: [TerminalSearchAction] = []
    model.perform = { sent.append($0) }
    model.start()
    sent.removeAll()
    let before = model.focusRequest
    model.start()
    XCTAssertTrue(model.isActive)
    XCTAssertEqual(sent, [])
    XCTAssertEqual(model.focusRequest, before + 1)
  }

  // MARK: TerminalSearchModel.matchSummary (top-down 1-based position from the engine's 0-based index)

  func testMatchSummaryEmptyNeedle() {
    XCTAssertEqual(TerminalSearchModel().matchSummary, "")
  }

  func testMatchSummaryTopMatchIsPositionOne() {
    // The top-most match is engine index `total - 1`; the bar shows it as position 1.
    let (model, _) = openModel(total: 12, selected: 11)
    XCTAssertEqual(model.matchSummary, "1/12")
  }

  func testMatchSummaryBottomMatchIsLastPosition() {
    // The bottom-most match is engine index 0; the bar shows it as the last position.
    let (model, _) = openModel(total: 12, selected: 0)
    XCTAssertEqual(model.matchSummary, "12/12")
  }

  func testMatchSummaryNoSelectionShowsZero() {
    let (model, _) = openModel(total: 12, selected: -1)
    XCTAssertEqual(model.matchSummary, "0/12")
  }

  func testMatchSummaryNoResults() {
    let (model, _) = openModel(total: 0, selected: -1)
    XCTAssertEqual(model.matchSummary, "No results")
  }
}
