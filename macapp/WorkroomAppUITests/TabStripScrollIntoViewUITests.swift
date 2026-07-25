import XCTest

/// UI tests for scrolling a selected chip into view in both horizontal tab strips (issue #129
/// follow-up — `OverflowingTabScroller`'s `ScrollViewReader`). Before this, selecting a chip that was
/// scrolled out of sight swapped the pane content with no visible feedback — it read as "the shortcut
/// did nothing". Each test below establishes the "not visible yet" precondition FIRST — a lesson from
/// the last tab-strip change: a test that only asserts the good end-state passes even when the
/// fixture never set up the interesting state — then drives a real selection, then asserts the chip
/// is now on screen and hittable.
///
/// ⌘1-9 / ⌥⌘1-9 only address the first nine tabs (`AppDelegate`'s local key monitor), so neither can
/// reach the LAST chip in a strip overflowing by more than nine on its own. The cycle shortcuts
/// (⌥⌘←/→ terminal, ⇧⌥⌘←/→ workroom, issue #29 — `AppStore.cycleTerminalTab`/`cycleWorkroomTab`) have
/// no such ceiling and wrap at the ends, so cycling BACKWARD from the first tab wraps straight to the
/// last one in a single keypress — landing on the same offscreen chip a digit shortcut can't reach,
/// through the exact same write (`TerminalSessions.setFocused` / `AppStore.selectedTargetID`) ⌘1-9
/// uses, just via a different entry point.
///
/// Shares its geometry/fixture idioms with `TabStripOverflowUITests` (`launchedApp`, `terminalChips`,
/// `workroomChips`, the `overflowTabs`/`overflowWorkrooms` counts) and its `typeKey` idiom with
/// `ViewMenuShortcutsUITests`; each file duplicates its own copies of the small helpers rather than
/// sharing them, matching this suite's existing convention.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run).
final class TabStripScrollIntoViewUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Enough terminal tabs that the strip overflows at any sane window width (mirrors
  /// `TabStripOverflowUITests.overflowTabs` — chip titles cap at 180pt, so 12 chips is ≥ 1000pt of
  /// run).
  private let overflowTabs = 12
  /// Enough workroom chips to overflow the title bar's tab area (mirrors
  /// `TabStripOverflowUITests.overflowWorkrooms`).
  private let overflowWorkrooms = 10

  private func launchedApp(terminalTabs: Int? = nil, workrooms: Int? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let terminalTabs {
      app.launchArguments += ["-WorkroomUITestTerminalTabs", "\(terminalTabs)"]
    }
    if let workrooms { app.launchArguments += ["-WorkroomUITestWorkroomCount", "\(workrooms)"] }
    app.launch()
    app.activate()
    return app
  }

  /// One strip chip per terminal. The chip's title and close button share the `terminal.tab.<title>`
  /// identifier (it cascades), so match only the title `StaticText` to address chips 1:1 (mirrors
  /// `TabStripOverflowUITests.terminalChips`).
  private func terminalChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  /// Every workroom tab chip carries a `workroom.tab.<target.id>` identifier and is ONE combined
  /// accessibility element, unlike the terminal chips above (mirrors
  /// `TabStripOverflowUITests.workroomChips`).
  private func workroomChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workroom.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 10) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Waits for `element`'s frame to land fully inside `window` — the scroll-into-view animation
  /// (`.easeInOut(duration: 0.18)`) is still in flight for a moment after the keystroke that triggers
  /// it, so a bare synchronous check here would be racy.
  private func waitUntilContained(
    _ window: CGRect, _ element: XCUIElement, timeout: TimeInterval = 10
  ) -> Bool {
    let predicate = NSPredicate { _, _ in window.contains(element.frame) }
    let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// Waits for `element` to sit entirely before `boundary`'s leading edge — the containment test for a
  /// strip whose visible trailing edge is NOT the window's (see the terminal test below). Same reason
  /// for waiting rather than checking once: the scroll is animated.
  private func waitUntilTrailingEdgeClears(
    _ boundary: XCUIElement, _ element: XCUIElement, timeout: TimeInterval = 10
  ) -> Bool {
    let predicate = NSPredicate { _, _ in element.frame.maxX <= boundary.frame.minX }
    let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  // MARK: Terminal tab strip

  /// Deliberately does NOT test containment in the WINDOW, the way the workroom case below can: the
  /// terminal strip's visible trailing edge is far inside the window — the per-tab toolbar sits beyond
  /// it, and the inspector column beyond that — so a chip scrolled out of the *strip* is still
  /// geometrically inside the *window* rect. (Asserting window containment here is a mistake this test
  /// made once, and it failed for exactly that reason.) The pinned "+" marks the strip's visible
  /// trailing edge, so "offscreen" here means `chip.maxX > plus.minX`.
  ///
  /// The precondition is established by SELECTING tab 1, not by the launch state. The fixture happens
  /// to leave tab N focused-but-never-scrolled-to (`TerminalSessions.addTab` focuses every tab it
  /// creates, and `.onChange` doesn't fire for a view's initial value), so the last chip starts
  /// offscreen anyway — but asserting that would tie this test to that gap, and the gap is a thing we
  /// may well close (a restored selection should arguably be scrolled to on first layout).
  func testCyclingToTheLastOffscreenTerminalTabScrollsItIntoView() {
    // The fixture's ceiling (`UITestFixture.terminalTabs` clamps 1...16). Deliberately more than
    // `overflowTabs`: 12 chips only *just* overflow this strip, so the last chip would sit a few
    // points past the edge and "scrolled into view" would be a few points of travel. At 16 it is
    // several hundred, which is a demonstration rather than a rounding difference.
    let manyTabs = 16
    let app = launchedApp(terminalTabs: manyTabs)
    assertCount(terminalChips(app), reaches: manyTabs)
    let lastChip = terminalChips(app).element(boundBy: manyTabs - 1)
    XCTAssertTrue(lastChip.waitForExistence(timeout: 10))
    let plus = app.descendants(matching: .any).matching(identifier: "NewTerminal").firstMatch
    XCTAssertTrue(plus.waitForExistence(timeout: 10))

    // ⌘1: select the first tab, which leaves the run scrolled to the start — so the cycle below is a
    // genuine transition, and the last chip is definitively out of the strip when we assert it.
    app.typeKey("1", modifierFlags: [.command])
    XCTAssertTrue(
      waitUntilTrailingEdgeClears(plus, terminalChips(app).element(boundBy: 0)),
      "selecting tab 1 should leave the run scrolled to the start")
    let hiddenFrame = lastChip.frame
    XCTAssertGreaterThan(
      hiddenFrame.maxX, plus.frame.minX,
      "with the run at the start, the last of \(manyTabs) tabs must be past the strip's trailing "
        + "edge — otherwise this test asserts nothing")

    // ⌥⌘←: cycle the terminal tab backward (issue #29's `cycleTerminalTab`) — from tab 1 this WRAPS
    // to the last tab, reaching the same offscreen chip ⌘1-9 alone can't address.
    app.typeKey(.leftArrow, modifierFlags: [.command, .option])

    XCTAssertTrue(
      waitUntilTrailingEdgeClears(plus, lastChip),
      "selecting the offscreen last tab should scroll it into view (issue #129 follow-up)")
    XCTAssertLessThan(
      lastChip.frame.minX, hiddenFrame.minX,
      "the chip should have travelled leftward, i.e. the run actually scrolled")
    XCTAssertTrue(lastChip.isHittable, "the scrolled-to tab should be hittable")
  }

  // MARK: Workroom tab bar (title bar)

  /// Drives ⌥⌘1 then ⌥⌘9 — two directly addressable targets — rather than the wrapping cycle
  /// shortcut. An earlier version of this test cycled BACKWARD from the first workroom to wrap onto the
  /// last chip; it passed once and then failed, so the wrap is not something to build an assertion on
  /// here. The ninth of ten workroom chips is comfortably out of the bar anyway: chips measure ~186pt,
  /// so the ninth starts ~1500pt into a run the title bar cannot show.
  ///
  /// Boundary is the pinned "+" (`NewWorkroom`), not the window, for the same reason as the terminal
  /// test: it marks the bar's visible trailing edge, and the window's rect extends past it.
  func testSelectingAnOffscreenWorkroomScrollsItIntoView() {
    let app = launchedApp(workrooms: overflowWorkrooms)
    assertCount(workroomChips(app), reaches: overflowWorkrooms)
    let target = workroomChips(app).element(boundBy: 8)  // the ⌥⌘9 target
    XCTAssertTrue(target.waitForExistence(timeout: 10))
    let plus = app.descendants(matching: .any).matching(identifier: "NewWorkroom").firstMatch
    XCTAssertTrue(plus.waitForExistence(timeout: 10))

    // ⌥⌘1: select the first workroom, leaving the run scrolled to the start.
    app.typeKey("1", modifierFlags: [.command, .option])
    XCTAssertTrue(
      waitUntilTrailingEdgeClears(plus, workroomChips(app).element(boundBy: 0)),
      "selecting the first workroom should leave the run scrolled to the start")
    let hiddenFrame = target.frame
    XCTAssertGreaterThan(
      hiddenFrame.maxX, plus.frame.minX,
      "with the run at the start, the ninth of \(overflowWorkrooms) workroom chips must be past the "
        + "bar's trailing edge — otherwise this test asserts nothing")

    // ⌥⌘9: select it directly (`AppStore.focusWorkroomTab(at:)`).
    app.typeKey("9", modifierFlags: [.command, .option])

    XCTAssertTrue(
      waitUntilTrailingEdgeClears(plus, target),
      "selecting the offscreen workroom should scroll it into view (issue #129 follow-up)")
    XCTAssertLessThan(
      target.frame.minX, hiddenFrame.minX,
      "the chip should have travelled leftward, i.e. the run actually scrolled")
    XCTAssertTrue(target.isHittable, "the scrolled-to workroom chip should be hittable")
  }
}
