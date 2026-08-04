import XCTest

@testable import Workroom

/// `QuickSwitcherReducer` (issue #132, T9): every transition of the hold-to-reveal session, with the
/// four load-bearing rules pinned by name. Pure — no timers, no panel, no AppKit — so the whole state
/// machine is covered headlessly and the controller stays a thin shell over it.
final class QuickSwitcherReducerTests: XCTestCase {

  /// Open a live session on `count` items and return it mid-`pending`.
  private func opened(count: Int = 5, reverse: Bool = false, kind: QuickSwitcherKind = .workrooms)
    -> QuickSwitcherReducer
  {
    var r = QuickSwitcherReducer()
    XCTAssertEqual(r.handle(.open(kind: kind, count: count, reverse: reverse)), .armReveal)
    return r
  }

  /// Open then reveal — the state a rail is actually on screen in.
  private func revealed(count: Int = 5, reverse: Bool = false) -> QuickSwitcherReducer {
    var r = opened(count: count, reverse: reverse)
    XCTAssertEqual(r.handle(.revealTimerFired), .reveal)
    return r
  }

  // MARK: Open

  func testOpenArmsTheRevealAndMovesTheCursorOffTheCurrentItem() {
    let r = opened(count: 5)
    XCTAssertEqual(r.phase, .pending)
    XCTAssertEqual(
      r.cursor, 1,
      "index 0 is where you already are — one press must land on the previous item, so a tap-release "
        + "flips")
    XCTAssertEqual(r.count, 5)
    XCTAssertFalse(r.hoverArmed, "hover starts disarmed (D17)")
  }

  func testOpenReverseWrapsBackwards() {
    let r = opened(count: 5, reverse: true)
    XCTAssertEqual(r.cursor, 4, "⇧ walks the other way and wraps to the end")
  }

  func testOpenWithFewerThanTwoItemsIsANoOp() {
    var r = QuickSwitcherReducer()
    XCTAssertEqual(r.handle(.open(kind: .panes, count: 1, reverse: false)), .none)
    XCTAssertEqual(
      r.phase, .idle, "nothing to switch to — the monitor passes ⌃Tab to the TUI instead")
    XCTAssertEqual(r.handle(.open(kind: .panes, count: 0, reverse: false)), .none)
    XCTAssertEqual(r.phase, .idle)
  }

  func testOpenMidSessionIsTreatedAsAStep() {
    var r = opened(count: 5)
    // Holding ⌥ and tapping Tab again re-enters the same monitor branch — it must advance, not restart.
    XCTAssertEqual(r.handle(.open(kind: .workrooms, count: 5, reverse: false)), .reveal)
    XCTAssertEqual(r.cursor, 2)
    XCTAssertEqual(r.phase, .revealed)
  }

  func testOpenRemembersItsKind() {
    let r = opened(count: 3, kind: .panes)
    XCTAssertEqual(r.kind, .panes, "the commit needs to know which list it was walking")
  }

  // MARK: Step

  func testStepWhilePendingRevealsImmediately() {
    var r = opened(count: 5)
    // RULE: ⌥Tab⌥Tab means "show me the choices now" — don't make the user wait out the delay.
    XCTAssertEqual(r.handle(.step(reverse: false)), .reveal)
    XCTAssertEqual(r.phase, .revealed)
    XCTAssertEqual(r.cursor, 2)
  }

  func testStepWhileRevealedMovesTheCursor() {
    var r = revealed(count: 5)
    XCTAssertEqual(r.handle(.step(reverse: false)), .moveCursor(2))
    XCTAssertEqual(r.handle(.step(reverse: false)), .moveCursor(3))
    XCTAssertEqual(r.phase, .revealed, "still revealed — a step never re-reveals")
  }

  func testStepWrapsInBothDirections() {
    var r = revealed(count: 3)  // cursor 1
    XCTAssertEqual(r.handle(.step(reverse: false)), .moveCursor(2))
    XCTAssertEqual(r.handle(.step(reverse: false)), .moveCursor(0), "forward wraps past the end")
    XCTAssertEqual(r.handle(.step(reverse: true)), .moveCursor(2), "backward wraps past the start")
  }

  func testStepWhileIdleIsANoOp() {
    var r = QuickSwitcherReducer()
    XCTAssertEqual(r.handle(.step(reverse: false)), .none)
    XCTAssertEqual(r.phase, .idle)
  }

  // MARK: Hover (D17)

  func testHoverIsIgnoredUntilArmed() {
    var r = revealed(count: 5)
    // RULE (D17): the panel is centred, so it can appear UNDER a stationary pointer. An unarmed hover
    // would move the selection to whatever card landed there and the release would commit it.
    XCTAssertEqual(r.handle(.point(index: 3)), .none)
    XCTAssertEqual(r.cursor, 1, "cursor unmoved by an unarmed hover")
    XCTAssertEqual(r.handle(.armHover), .none)
    XCTAssertEqual(r.handle(.point(index: 3)), .moveCursor(3), "real pointer movement arms it")
    XCTAssertEqual(r.cursor, 3)
  }

  func testArmedHoverOnTheCurrentCardIsANoOp() {
    var r = revealed(count: 5)
    _ = r.handle(.armHover)
    XCTAssertEqual(r.handle(.point(index: 1)), .none, "already on it — no redundant scroll")
  }

  func testHoverOutOfRangeIsIgnored() {
    var r = revealed(count: 3)
    _ = r.handle(.armHover)
    XCTAssertEqual(r.handle(.point(index: 9)), .none)
    XCTAssertEqual(r.handle(.point(index: -1)), .none)
    XCTAssertEqual(r.cursor, 1)
  }

  func testHoverWhilePendingIsIgnored() {
    var r = opened(count: 5)
    _ = r.handle(.armHover)
    XCTAssertEqual(r.handle(.point(index: 3)), .none, "no panel on screen yet — nothing to hover")
  }

  // MARK: Reveal timer

  func testRevealTimerFiredOutsidePendingIsANoOp() {
    // RULE: a timer that fires after a fast release must not resurrect a finished session.
    var afterRelease = opened(count: 5)
    XCTAssertEqual(afterRelease.handle(.modifierReleased), .end(commit: 1))
    XCTAssertEqual(afterRelease.handle(.revealTimerFired), .none)
    XCTAssertEqual(afterRelease.phase, .idle, "the stale timer left it idle")

    var alreadyRevealed = revealed(count: 5)
    XCTAssertEqual(
      alreadyRevealed.handle(.revealTimerFired), .none,
      "already revealed by a step — no double reveal")
  }

  // MARK: Commit + release

  func testReleaseWhilePendingCommitsTheTapFlip() {
    var r = opened(count: 5)
    XCTAssertEqual(r.handle(.modifierReleased), .end(commit: 1))
    XCTAssertEqual(r.phase, .idle)
  }

  func testReleaseWhileRevealedCommitsTheCursor() {
    var r = revealed(count: 5)
    _ = r.handle(.step(reverse: false))
    XCTAssertEqual(r.handle(.modifierReleased), .end(commit: 2))
  }

  func testClickCommitsThenTheFollowingReleaseDoesNothing() {
    // RULE: `.idle` swallows everything. A click commits and ends the session; the modifier release
    // that inevitably follows must NOT commit a second time.
    var r = revealed(count: 5)
    XCTAssertEqual(r.handle(.commit(index: 4)), .end(commit: 4))
    XCTAssertEqual(r.phase, .idle)
    XCTAssertEqual(r.handle(.modifierReleased), .none, "no second commit")
  }

  func testCommitWithNilUsesTheCursor() {
    var r = revealed(count: 5)
    _ = r.handle(.step(reverse: false))
    XCTAssertEqual(r.handle(.commit(index: nil)), .end(commit: 2))
  }

  func testCommitOutOfRangeEndsWithoutCommitting() {
    var r = revealed(count: 3)
    XCTAssertEqual(r.handle(.commit(index: 7)), .end(commit: nil), "a dead index must not switch")
    XCTAssertEqual(r.phase, .idle)
  }

  func testCommitWhileIdleIsANoOp() {
    var r = QuickSwitcherReducer()
    XCTAssertEqual(r.handle(.commit(index: 0)), .none)
  }

  // MARK: Cancel

  func testEveryCancelReasonEndsWithoutCommitting() {
    for reason in [
      QuickSwitcherReducer.Cancel.escape, .deactivated, .empty, .timeout, .voiceOver,
    ] {
      var r = revealed(count: 5)
      XCTAssertEqual(r.handle(.cancel(reason)), .end(commit: nil), "\(reason) must not commit")
      XCTAssertEqual(r.phase, .idle)
      XCTAssertEqual(
        r.handle(.modifierReleased), .none, "and the release after it stays swallowed (\(reason))")
    }
  }

  func testCancelWhilePendingAlsoEndsWithoutCommitting() {
    var r = opened(count: 5)
    XCTAssertEqual(r.handle(.cancel(.escape)), .end(commit: nil))
  }

  func testCancelWhileIdleIsANoOp() {
    var r = QuickSwitcherReducer()
    XCTAssertEqual(r.handle(.cancel(.escape)), .none)
  }

  // MARK: itemsChanged

  func testItemsChangedToZeroEndsWithoutCommitting() {
    // RULE: every item went away (the last window closed) — end, don't commit into nothing.
    var r = revealed(count: 5)
    XCTAssertEqual(r.handle(.itemsChanged(count: 0, cursor: 0)), .end(commit: nil))
    XCTAssertEqual(r.phase, .idle)
  }

  func testItemsChangedTakesTheCallersRemappedCursor() {
    // The caller recomputes the cursor from the ITEM it was tracking, because `filter` shifts every
    // later index down one. Clamping alone silently moved the selection to a neighbour, and the release
    // then committed that neighbour — the rail highlighting one card and landing on the next.
    var r = revealed(count: 4)
    _ = r.handle(.step(reverse: false))
    _ = r.handle(.step(reverse: false))
    XCTAssertEqual(r.cursor, 3)
    XCTAssertEqual(
      r.handle(.itemsChanged(count: 3, cursor: 2)), .moveCursor(2),
      "the item that was at 3 is now at 2 — follow it, don't just clamp")
    XCTAssertEqual(r.count, 3)
    XCTAssertEqual(r.phase, .revealed, "the session survives — only the cursor moved")
  }

  func testItemsChangedClampsAnOutOfRangeCursor() {
    var r = revealed(count: 5)
    _ = r.handle(.step(reverse: false))
    _ = r.handle(.step(reverse: false))
    XCTAssertEqual(r.cursor, 3)
    XCTAssertEqual(
      r.handle(.itemsChanged(count: 2, cursor: 9)), .moveCursor(1),
      "a cursor past the new end lands on the last item, never dangling")
    XCTAssertEqual(
      r.handle(.itemsChanged(count: 2, cursor: -3)), .moveCursor(0), "and never negative")
  }

  func testItemsChangedWithNoMoveNeededEmitsNothing() {
    var r = revealed(count: 5)
    XCTAssertEqual(
      r.handle(.itemsChanged(count: 4, cursor: 1)), .none, "cursor 1 still valid — no scroll")
    XCTAssertEqual(r.count, 4)
  }

  func testItemsChangedWhilePendingClampsSilently() {
    var r = opened(count: 5)  // cursor 1, no panel on screen yet
    XCTAssertEqual(
      r.handle(.itemsChanged(count: 1, cursor: 0)), .none,
      "clamped with no panel on screen, so there is nothing to scroll")
    XCTAssertEqual(r.cursor, 0)
    XCTAssertEqual(r.phase, .pending, "the session survives a shrink to one item")
  }

  func testItemsChangedWhileIdleIsANoOp() {
    var r = QuickSwitcherReducer()
    XCTAssertEqual(r.handle(.itemsChanged(count: 3, cursor: 0)), .none)
  }

  // MARK: Reuse + constants

  func testStepMathIsTheSameFunctionTheTapOnlyPathUses() {
    // Stage 1 commits through `QuickSwitcher.destination`; a held-modifier step must not disagree.
    for reverse in [false, true] {
      var r = revealed(count: 4)
      let before = r.cursor
      _ = r.handle(.step(reverse: reverse))
      XCTAssertEqual(
        r.cursor, QuickSwitcher.destination(from: before, count: 4, reverse: reverse),
        "reverse=\(reverse)")
    }
  }

  func testRevealDelayIs250ms() {
    // Pinned: 180ms flashes the panel on a chorded tap, and the 180ms in EdgeRevealSidebar is a HIDE
    // debounce, not a reveal delay.
    XCTAssertEqual(QuickSwitcherReducer.revealDelay, .milliseconds(250))
    XCTAssertEqual(QuickSwitcherReducer.sessionCeiling, .seconds(10))
  }
}
