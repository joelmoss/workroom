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

  // MARK: TerminalSearchState.reduce (engine → app)

  func testStartOpensSearchWithZeroedCounts() {
    let state = TerminalSearchState.reduce(nil, .start(needle: ""))
    XCTAssertEqual(state, TerminalSearchState(needle: "", total: 0, selected: 0))
  }

  func testStartCarriesPrefilledNeedle() {
    // `search_selection` opens the bar pre-filled with the selection.
    let state = TerminalSearchState.reduce(nil, .start(needle: "needle"))
    XCTAssertEqual(state?.needle, "needle")
  }

  func testTotalAndSelectedUpdateCounts() {
    var state = TerminalSearchState.reduce(nil, .start(needle: "x"))
    state = TerminalSearchState.reduce(state, .total(12))
    state = TerminalSearchState.reduce(state, .selected(3))
    XCTAssertEqual(state, TerminalSearchState(needle: "x", total: 12, selected: 3))
  }

  func testNegativeSelectedClampsToZero() {
    // libghostty reports a negative index for "no current match"; the bar shows 0.
    var state = TerminalSearchState.reduce(nil, .start(needle: "x"))
    state = TerminalSearchState.reduce(state, .selected(-1))
    XCTAssertEqual(state?.selected, 0)
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
}
