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

  /// Wait for `element` to become hittable, returning whether it got there. Existing in the
  /// accessibility tree is NOT the same as accepting a hit: a SwiftUI row can be present a frame or
  /// two before its layout settles, and a click that lands early is swallowed silently — no error,
  /// no effect. The result is advisory (a row that never reports hittable is still worth clicking),
  /// which is why callers pair this with a retry rather than asserting on it.
  private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: element)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// Open the jj working-copy diff for `app/models/user.rb` as a preview tab; returns once its diff
  /// tab chip ("user.rb") exists.
  ///
  /// Deliberately patient, because this helper gates most of the class: it waits for the row to be
  /// hittable before clicking, allows the diff tab the same 10s as every other wait here (6s was the
  /// tightest budget in the sequence and the first thing to give under batch load), and clicks a
  /// second time if the first produced nothing — re-clicking the same row just re-opens the same
  /// preview, so the retry is free. That combination is what this flaked on when run in a batch.
  private func openDiffPreview(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "jj Working Copy header should render")
    let row = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    _ = waitForHittable(row)
    row.click()
    let tab = diffTab(app, "user.rb")
    guard !tab.waitForExistence(timeout: 10) else { return }
    // The first click produced nothing. Record it before retrying: a one-frame layout race and a
    // permanent first-click regression look identical from here, and this app has shipped the
    // permanent kind — `.textSelection(.enabled)` text swallowing real mouseDown, which no synthetic
    // click reproduces. Without the attachment the retry turns that regression into a green run.
    XCTContext.runActivity(named: "first click on the Changes row was swallowed") { activity in
      activity.add(XCTAttachment(string: "row: app/models/user.rb, expected diff tab: user.rb"))
    }
    row.click()
    XCTAssertTrue(tab.waitForExistence(timeout: 10), "diff tab should open")
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

  /// "Remove from Split" is hidden on a solo (unsplit) tab — it only renders for a real split
  /// member (issue #122). The split-creating items stay visible either way.
  func testRemoveFromSplitAbsentOnSoloTab() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)  // one solo diff tab, no split
    diffTab(app, "user.rb").rightClick()
    XCTAssertTrue(menuItem(app, "Split Right").waitForExistence(timeout: 3), "menu should be open")
    XCTAssertFalse(
      menuItem(app, "Remove from Split").exists,
      "a solo tab is in no split, so Remove from Split must not appear")
    app.typeKey(.escape, modifierFlags: [])  // dismiss the menu
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

  /// Removing a pane from the split via its PANEL body (issue #122): the shared menu offers "Remove
  /// from Split" for a real split member, and invoking it pulls that pane out. Split of two diff
  /// panes → remove one → collapses to the extracted tab shown solo (one pane). The pane body is
  /// targeted by position (`boundBy`) since a same-file split makes the two chips share a title.
  func testRemoveFromSplitViaPaneBodyCollapses() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    app.buttons["tab.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)
    panes(app).element(boundBy: 1).rightClick()  // the second pane's body
    let remove = menuItem(app, "Remove from Split")
    XCTAssertTrue(
      remove.waitForExistence(timeout: 3), "a split member's menu offers Remove from Split")
    remove.click()
    assertCount(panes(app), reaches: 1)  // extracted tab shown solo; split dissolved
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
