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

  private func launchedApp(
    longTitle: Bool = false, workroomSplit: Bool = false, windowFrame: CGRect? = nil
  )
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if longTitle { app.launchArguments += ["-WorkroomUITestLongTabTitle", "1"] }
    if workroomSplit { app.launchArguments += ["-WorkroomUITestWorkroomSplit", "1"] }
    if let windowFrame {
      app.launchArguments += ["-WorkroomUITestWindowFrame", NSStringFromRect(windowFrame)]
    }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    // Some tests here open the LAST changed-file row (`legacy_user.rb`, the ninth). With the default
    // equal-height inspector sections only the first five rows are visible; a click on a scrolled-out
    // row lands on the pane drawn over its accessibility frame. Give Changes the room.
    app.launchArguments += ["-WorkroomUITestInspectorWeights", "6,1,1,1"]
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

  /// Open a diff pane by clicking its row in the Changes panel, and wait for the pane's bar to name
  /// it — the pane title bar carries the file's path since issue #150.
  private func openDiffPane(_ app: XCUIApplication, path: String = "app/models/user.rb") {
    let row = app.descendants(matching: .any).matching(identifier: "changes.file.\(path)")
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Changes panel should list \(path)")
    row.click()
    let named = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
        "terminal.pane.titlebar", path, path)
    ).firstMatch
    XCTAssertTrue(named.waitForExistence(timeout: 10), "the diff pane's bar should name \(path)")
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

  /// The narrow-pane collapse actually engages: below `PaneTitleBarMetrics.minTitle` the full row
  /// stops fitting and `ViewThatFits` falls to the collapsed candidate, folding the mode switch and
  /// Open File into `pane.toolbar.overflow`.
  ///
  /// This codebase has already shipped a DEAD `ViewThatFits` ladder with the whole suite green —
  /// `AgentUsageUITests.testNarrowSplitKeepsBothWindowsAndShrinksTheBars` documents it (issue #168:
  /// a `.fixedSize` made the first variant always "fit", so every later rung was unreachable). The
  /// same trap applies here, so assert the collapse by OBSERVING it, not by trusting the ladder.
  func testNarrowPaneCollapsesTheOptionalControlsIntoTheOverflowMenu() {
    let app = launchedApp(windowFrame: CGRect(x: 80, y: 80, width: 1650, height: 780))
    openWorkroom(app)
    XCTAssertEqual(app.windows.firstMatch.frame.width, 1650, accuracy: 1)
    openDiffPane(app)

    // Wide: the mode switch is in the row and there is nothing to overflow.
    XCTAssertTrue(app.buttons["tab.toolbar.diffSideBySide"].waitForExistence(timeout: 8))
    // SwiftUI Menu exposes a menu control, which a buttons-only query misses.
    let overflow = app.descendants(matching: .any).matching(identifier: "pane.toolbar.overflow")
      .firstMatch
    XCTAssertFalse(overflow.exists)

    // Three even panes need at least 904pt. The wider fixture leaves ~1000pt for the
    // container, so both splits fit and each pane lands near 330pt, in the collapse band.
    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    assertCount(panes(app), reaches: 2)
    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    assertCount(panes(app), reaches: 3)

    for pane in panes(app).allElementsBoundByIndex {
      XCTAssertGreaterThanOrEqual(pane.frame.width, 300)
      XCTAssertLessThan(pane.frame.width, 399)
    }
    XCTAssertTrue(
      overflow.waitForExistence(timeout: 8),
      "the ladder never collapsed — a dead ViewThatFits keeps its widest candidate (issue #168)")
    XCTAssertFalse(
      app.buttons["tab.toolbar.diffSideBySide"].exists,
      "the mode switch must leave the row when it folds into the overflow menu")
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(overflow.frame),
      "the collapsed toolbar overflowed its pane instead of fitting")
  }

  /// "Open File" opens the working copy of the file being diffed, so a DELETED source has nothing to
  /// open. The button stays visible and goes disabled rather than vanishing (review D4) — a control
  /// that disappears reads as a missing feature.
  func testOpenFileIsDisabledForADeletedSource() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPane(app, path: "app/models/legacy_user.rb")

    let openFile = app.buttons["pane.toolbar.openFile"]
    XCTAssertTrue(openFile.waitForExistence(timeout: 8))
    XCTAssertFalse(openFile.isEnabled, "a deleted source has no working copy to open")
  }

  /// A solo pane's bar must not drag. The gesture is masked `.subviews` when there is no split, so
  /// this asserts the inert half of that mask; `testSoloPaneButtonsStillFire` asserts the half that
  /// would break every button if the mask were `.none` instead. Mirrors
  /// `WorkroomPaneHeaderUITests.testSoloTitleBarDragDoesNotCreateASplit` for the workroom bar above.
  func testSoloPaneBarDragDoesNotCreateASplit() {
    let app = launchedApp()
    openWorkroom(app)
    assertCount(panes(app), reaches: 1)

    let bar = titlebars(app).firstMatch
    XCTAssertTrue(bar.waitForExistence(timeout: 8))
    bar.press(forDuration: 0.4, thenDragTo: app.windows.firstMatch)

    assertCount(panes(app), reaches: 1)
    XCTAssertEqual(titlebars(app).count, 1, "dragging a solo pane's bar must not split anything")
  }

  /// A terminal pane offers no per-file controls: no diff mode switch, no "Open File". They are not
  /// merely hidden behind the overflow menu either — a terminal has nothing optional to collapse, so
  /// the menu itself must be absent.
  func testTerminalPaneShowsNoOptionalControls() {
    let app = launchedApp()
    openWorkroom(app)
    XCTAssertTrue(app.buttons["pane.toolbar.splitRight"].waitForExistence(timeout: 6))
    XCTAssertFalse(app.buttons["pane.toolbar.openFile"].exists)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "pane.toolbar.overflow").firstMatch
        .exists)
  }
}
