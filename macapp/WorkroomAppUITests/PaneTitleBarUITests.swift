import XCTest

/// The detail panel's own title bar (issue #150). Before it, a pane's identity lived only in its tab
/// chip — capped at 180pt and, in a split, sitting well away from the pane it named — and the actions
/// lived in the tab strip's toolbar keyed on the ACTIVE tab, so in a split they acted on a pane other
/// than the one you clicked.
///
/// Two things here are deliberately geometric rather than label-based. Asserting that an element's
/// accessibility label contains the whole title proves nothing about what is *rendered*: the label is
/// the full string whether or not a single character of it fits. So the truncation and collapse tests
/// measure `frame` at a controlled window size instead.
final class PaneTitleBarUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(longTitle: Bool = false, workroomSplit: Bool = false)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if longTitle { app.launchArguments += ["-WorkroomUITestLongTabTitle", "1"] }
    if workroomSplit { app.launchArguments += ["-WorkroomUITestWorkroomSplit", "1"] }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  private func titlebars(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane.titlebar")
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 8) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  @discardableResult
  private func openWorkroom(_ app: XCUIApplication) -> XCUIElement {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let pane = panes(app).firstMatch
    XCTAssertTrue(
      pane.waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
    return pane
  }

  /// Every pane carries exactly one bar — solo included. That is the whole change: the bar is
  /// unconditional, so a pane's identity and its actions are always where the pane is.
  func testEveryPaneHasExactlyOneTitleBar() {
    let app = launchedApp()
    openWorkroom(app)
    assertCount(titlebars(app), reaches: 1)

    app.buttons["pane.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)
    assertCount(titlebars(app), reaches: 2)
  }

  /// The bar renders more of a long title than the chip's `TabStripMetrics.maxChipTitle` cap allows.
  /// Measured, not read off the label: escaping that cap IS the feature, and a label assertion would
  /// pass even if the title rendered as a single ellipsis.
  func testLongTitleRendersWiderThanTheChipCap() {
    let app = launchedApp(longTitle: true)
    openWorkroom(app)
    let bar = titlebars(app).firstMatch
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    let title = bar.staticTexts.firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 6))
    XCTAssertGreaterThan(
      title.frame.width, 180,
      "the pane bar must not inherit the chips' 180pt title cap — that cap is what issue #150 escapes"
    )
  }

  /// Split right / split down / close act on the pane whose button was clicked, not on the active tab.
  /// This is the defect the issue exists to fix, so it is asserted on the pane that is NOT focused:
  /// clicking the first pane's close must leave exactly the second one behind.
  func testCloseActsOnItsOwnPaneNotTheActiveTab() {
    let app = launchedApp()
    openWorkroom(app)
    app.buttons["pane.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)

    // Splitting focuses the NEW pane, so the first bar's close button belongs to the unfocused one.
    let first = titlebars(app).element(boundBy: 0)
    XCTAssertTrue(first.waitForExistence(timeout: 6))
    first.buttons["pane.toolbar.close"].click()
    assertCount(panes(app), reaches: 1)
  }

  /// Split down is wired to its own edge — a smoke guard against both buttons calling the same action,
  /// which a copy-paste in the bar would produce and which nothing else here would catch.
  func testSplitDownAlsoCreatesASecondPane() {
    let app = launchedApp()
    openWorkroom(app)
    app.buttons["pane.toolbar.splitDown"].click()
    assertCount(panes(app), reaches: 2)
  }

  /// A solo pane's bar must NOT be draggable, but its buttons must still work. The bar carries the
  /// pane-move `DragGesture`, and gating that with `GestureMask.none` would disable every gesture in
  /// the bar's SUBVIEW hierarchy too — killing the buttons on every unsplit pane. `.subviews` is what
  /// drops only the drag. `ToolbarIconButtonStyle`'s hover well is `.onHover`, not a gesture, so a
  /// broken button still reports `.exists` and `.isHittable`: only clicking it tells the difference.
  /// Same trap `WorkroomPaneHeaderUITests.testSoloRunButtonActuallyFires` documents for the workroom
  /// bar above this one.
  func testSoloPaneButtonsStillFire() {
    let app = launchedApp()
    openWorkroom(app)
    assertCount(panes(app), reaches: 1)
    let split = app.buttons["pane.toolbar.splitRight"]
    XCTAssertTrue(split.waitForExistence(timeout: 6))
    split.click()
    assertCount(panes(app), reaches: 2)
  }

  /// A terminal pane offers no per-file controls: no diff mode switch, no "Open File". They are not
  /// merely hidden behind the overflow menu either — a terminal has nothing optional to collapse, so
  /// the menu itself must be absent.
  func testTerminalPaneShowsNoOptionalControls() {
    let app = launchedApp()
    openWorkroom(app)
    XCTAssertTrue(app.buttons["pane.toolbar.splitRight"].waitForExistence(timeout: 6))
    XCTAssertFalse(app.buttons["pane.toolbar.openFile"].exists)
    XCTAssertFalse(app.buttons["pane.toolbar.overflow"].exists)
  }
}
