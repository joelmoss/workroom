import XCTest

/// Regression coverage for the hover-preview feature (plan: ~/.claude/plans/ethereal-inventing-wolf.md)
/// stealing keyboard focus from the real active tab — found via real-mouse QA, not by any automated
/// test: hovering a backgrounded tab's chip silently made it the first responder (a stale
/// `GhosttySurfaceView.wantsFocus` left over from when it was last actually active triggered
/// `viewDidMoveToWindow`'s auto-claim once the hover-preview re-homed it into a real window).
///
/// The surface itself is Metal-rendered and exposes nothing queryable for "who currently holds first
/// responder" (the same CMT-3 gap `GhosttyActionDispatchUITests` documents), so this proves the
/// regression the way a real user would notice it: type into the real active tab, hover a DIFFERENT
/// tab's chip, then type again and confirm the keystrokes still land in the ORIGINALLY-FOCUSED tab's
/// chip POSITION — exercised through the shell's own OSC 0/2 retitling (issue #2), the same detector
/// `GhosttyActionDispatchUITests.testRunningCommandRetitlesTheTabChip` already uses. Checked by strip
/// POSITION, not by re-querying for the expected title prefix — a title-prefix query would still find
/// A match even if the WRONG chip (the hovered one) is the one that actually retitled, which would
/// silently pass right through the regression this test exists to catch.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run).
final class TerminalHoverPreviewUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalTabs", "2"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// `.staticTexts` specifically, not `.descendants(matching: .any)` — the chip's title AND its close
  /// button share the same `terminal.tab.<title>` identifier prefix (`TabStripOverflowUITests`' own
  /// comment: "match only the title StaticText to count chips 1:1"), so an `.any` query returns more
  /// than one element per chip and breaks positional indexing.
  private func chipQuery(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  /// The chip currently at strip position `index` — re-queried fresh each call (not a held
  /// reference), since a retitle changes the element's identifier/label but never its strip position.
  private func chip(_ app: XCUIApplication, at index: Int) -> XCUIElement {
    chipQuery(app).element(boundBy: index)
  }

  private func focusFirstTab(_ app: XCUIApplication) {
    app.activate()
    let query = chipQuery(app)
    XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 20))
    XCTAssertGreaterThanOrEqual(query.count, 2, "the fixture must seed 2 terminal tabs")
    chip(app, at: 0).click()
    // The click lands before the surface is first responder; without a beat the first keystrokes are
    // dropped (same note as GhosttyActionDispatchUITests.focusTerminal).
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  private func run(_ app: XCUIApplication, _ line: String) {
    app.typeText(line + "\r")
  }

  /// Waits until the chip at strip position `index` retitles to contain `substring`.
  private func waitForChipLabel(
    _ app: XCUIApplication, at index: Int, toContain substring: String, timeout: TimeInterval = 20
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if chip(app, at: index).label.contains(substring) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return false
  }

  /// The regression test: hovering tab 2 while tab 1 is focused must not move keyboard focus.
  func testHoveringABackgroundTabDoesNotStealFocusFromTheActiveTab() {
    let app = launchedApp()
    focusFirstTab(app)

    // Confirm keystrokes land in POSITION 0 before hovering, establishing the baseline. `sleep 3`
    // first keeps the whole line as the tab's title long enough to reliably poll — a bare `echo`
    // completes in milliseconds and its title can revert before a poll ever observes it (the same
    // reason `GhosttyActionDispatchUITests.testRunningCommandRetitlesTheTabChip` uses `sleep 6`, not
    // an instant command).
    run(app, "sleep 3; echo before_hover_marker")
    XCTAssertTrue(
      waitForChipLabel(app, at: 0, toContain: "before_hover"),
      "position 0 must retitle from its own running command")

    // Hover tab 2's chip (position 1) long enough to pass the hover-preview's dwell (0.4s) and
    // settle (0.05s).
    chip(app, at: 1).hover()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    // Type again — if hovering had stolen first responder, this would land at position 1 instead.
    run(app, "sleep 3; echo after_hover_marker")
    XCTAssertTrue(
      waitForChipLabel(app, at: 0, toContain: "after_hover"),
      "position 0 must still be the one receiving keystrokes after hovering position 1's chip — if "
        + "this fails, hovering silently stole first responder (the regression this test exists for)"
    )
    XCTAssertFalse(
      chip(app, at: 1).label.contains("after_hover"),
      "position 1 (the hovered chip) must not have received the command instead")
  }

  /// Hovering the already-focused/visible tab is v1's explicit no-preview case — confirms it's also a
  /// safe no-op for focus, not just for the preview UI.
  func testHoveringTheAlreadyVisibleTabIsANoOp() {
    let app = launchedApp()
    focusFirstTab(app)

    chip(app, at: 0).hover()  // tab 1 is already focused/visible — v1 shows no preview for it
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    run(app, "sleep 3; echo still_focused_marker")
    XCTAssertTrue(
      waitForChipLabel(app, at: 0, toContain: "still_focused"),
      "hovering the already-active tab's own chip must not disturb focus")
  }
}
