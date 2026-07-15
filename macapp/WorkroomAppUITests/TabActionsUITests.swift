import XCTest

/// UI tests for the tab toolbar + context menus + File-menu bulk close (issue #72). Driven through the
/// real app in fixture mode (`-WorkroomUITestFixture 1`): the workroom auto-selects so a terminal pane
/// renders on launch, and clicking a Changes-panel row opens a canned diff tab. Panes are counted via
/// the per-leaf `terminal.pane` accessibility element (one per rendered pane, diff or terminal).
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run).
final class TabActionsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// One `terminal.pane` accessibility element per rendered leaf (terminal or diff).
  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func fileRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    element(app, id: "changes.file.\(path)")
  }

  private func diffTab(_ app: XCUIApplication, _ basename: String) -> XCUIElement {
    element(app, id: "terminal.tab.\(basename)")
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 6) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Confirm the fixture workroom's terminal pane rendered on launch.
  private func openWorkroom(_ app: XCUIApplication) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(app).firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
  }

  /// Open the jj working-copy diff for `app/models/user.rb` as a preview tab; returns once its diff
  /// tab chip ("user.rb") exists.
  private func openDiffPreview(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "jj Working Copy header should render")
    let row = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6), "diff tab should open")
  }

  /// A right-click menu item, by exact title.
  private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
  }

  // MARK: Toolbar — terminal tab

  /// A terminal tab's toolbar offers Split-right + Split-down + Close-all, but NOT Open-file-in
  /// (that's diff-only).
  func testTerminalToolbarHasSplitAndCloseAllNotOpenFile() {
    let app = launchedApp()
    openWorkroom(app)
    XCTAssertTrue(app.buttons["tab.toolbar.splitRight"].waitForExistence(timeout: 6))
    XCTAssertTrue(app.buttons["tab.toolbar.splitDown"].exists)
    XCTAssertTrue(app.buttons["tab.toolbar.closeAll"].exists)
    XCTAssertFalse(
      app.buttons["tab.toolbar.openFile"].exists, "a terminal tab has no Open-file action")
  }

  func testTerminalToolbarSplitRightCreatesTwoPanes() {
    let app = launchedApp()
    openWorkroom(app)
    assertCount(panes(app), reaches: 1)
    app.buttons["tab.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)
  }

  func testTerminalToolbarSplitDownCreatesTwoPanes() {
    let app = launchedApp()
    openWorkroom(app)
    assertCount(panes(app), reaches: 1)
    app.buttons["tab.toolbar.splitDown"].click()
    assertCount(panes(app), reaches: 2)
  }

  // MARK: Toolbar — diff tab

  /// A diff tab's toolbar adds Open-file-in alongside Split-right + Close-all.
  func testDiffTabToolbarHasOpenFileSplitCloseAll() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    XCTAssertTrue(app.buttons["tab.toolbar.openFile"].waitForExistence(timeout: 6))
    XCTAssertTrue(app.buttons["tab.toolbar.splitRight"].exists)
    XCTAssertTrue(app.buttons["tab.toolbar.splitDown"].exists)
    XCTAssertTrue(app.buttons["tab.toolbar.closeAll"].exists)
  }

  /// Splitting a diff from the toolbar opens a second pane (a diff pane of the same file, #72).
  func testDiffToolbarSplitRightCreatesTwoPanes() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    assertCount(panes(app), reaches: 1)  // the diff is shown solo
    app.buttons["tab.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)
  }

  /// "Close all" from the toolbar closes every tab in the workroom (here: a split of two panes → none).
  func testToolbarCloseAllClosesEveryPane() {
    let app = launchedApp()
    openWorkroom(app)
    app.buttons["tab.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)
    app.buttons["tab.toolbar.closeAll"].click()
    assertCount(panes(app), reaches: 0)
  }

  // MARK: Context menu — tab chip

  /// A diff tab's right-click menu carries the diff actions (Open File in…, Keep Open for a preview)
  /// plus the split + close group.
  func testDiffTabContextMenuHasExpectedItems() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    diffTab(app, "user.rb").rightClick()
    XCTAssertTrue(menuItem(app, "Open File in…").waitForExistence(timeout: 3))
    XCTAssertTrue(menuItem(app, "Keep Open").exists, "a preview diff tab offers Keep Open")
    XCTAssertTrue(menuItem(app, "Split Right").exists)
    XCTAssertTrue(menuItem(app, "Close Others").exists)
    XCTAssertTrue(menuItem(app, "Close All").exists)
    app.typeKey(.escape, modifierFlags: [])  // dismiss the menu
  }

  /// Splitting from the tab chip's context menu opens a second pane.
  func testContextMenuSplitRightCreatesTwoPanes() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    assertCount(panes(app), reaches: 1)
    diffTab(app, "user.rb").rightClick()
    let split = menuItem(app, "Split Right")
    XCTAssertTrue(split.waitForExistence(timeout: 3))
    split.click()
    assertCount(panes(app), reaches: 2)
  }

  // MARK: Context menu — diff PANEL (issue #72: same menu as the tab)

  /// Right-clicking the diff PANEL body shows the same context menu as its tab chip.
  func testDiffPanelHasSameContextMenuAsTab() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    panes(app).firstMatch.rightClick()
    XCTAssertTrue(
      menuItem(app, "Open File in…").waitForExistence(timeout: 3),
      "the diff panel offers the same Open File in… as its tab")
    XCTAssertTrue(menuItem(app, "Split Right").exists)
    XCTAssertTrue(menuItem(app, "Close All").exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  // MARK: File menu — bulk close

  /// File ▸ Close All Tabs closes every tab; Close Other Tabs is offered too (enabled with ≥2 tabs).
  func testFileMenuCloseAllTabsClosesEverything() {
    let app = launchedApp()
    openWorkroom(app)
    app.buttons["tab.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)

    let fileMenu = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
    fileMenu.click()
    let closeAll = app.menuItems["Close All Tabs"]
    XCTAssertTrue(closeAll.waitForExistence(timeout: 3))
    XCTAssertTrue(app.menuItems["Close Other Tabs"].isEnabled, "≥2 tabs → Close Other Tabs enabled")
    closeAll.click()
    assertCount(panes(app), reaches: 0)
  }
}
