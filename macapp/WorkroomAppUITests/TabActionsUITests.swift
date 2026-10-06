import XCTest

/// UI tests for the pane title bar's toolbar + context menus + File-menu bulk close (issue #72; the
/// toolbar moved from the tab strip into each pane's own bar in issue #150). Driven through the
/// real app in fixture mode (`-WorkroomUITestFixture 1`): the workroom auto-selects so a terminal pane
/// renders on launch, and clicking a Changes-panel row opens a canned diff tab. Panes are counted via
/// the per-leaf `terminal.pane` accessibility element (one per rendered pane, diff or terminal).
///
/// Two launches cover the class. Each test is a chain of what used to be separate tests, ordered so
/// every step starts from the state it needs; a step that ends the panes (Close All) runs last.
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

  /// Open the working-copy diff for `app/models/user.rb` as a preview tab; returns once its diff
  /// tab chip ("user.rb") exists.
  ///
  /// Deliberately patient, because this helper gates most of the class: it waits for the row to be
  /// hittable before clicking, allows the diff tab the same 10s as every other wait here (6s was the
  /// tightest budget in the sequence and the first thing to give under batch load), and clicks a
  /// second time if the first produced nothing — re-clicking the same row just re-opens the same
  /// preview, so the retry is free. That combination is what this flaked on when run in a batch.
  private func openDiffPreview(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, id: "changes.file.app/models/user.rb").waitForExistence(timeout: 10),
      "the Changes panel should render its file rows")
    let row = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.scrollIntoView(in: app)
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

  /// The ON-SCREEN right-click menu item with this exact title, or nil. Hittable only, because
  /// "Split Right" also lives in the menu bar (`WorkroomApp.swift`), whose collapsed items are in the
  /// tree with a zero frame: a plain title match can be satisfied, or clicked, there instead.
  private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
    app.menuItems.matching(NSPredicate(format: "title == %@", title))
      .allElementsBoundByIndex.first { $0.isHittable }
  }

  /// Wait for an on-screen menu item to appear (a menu opens a beat after the right-click).
  private func waitForMenuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
    let shown = NSPredicate { _, _ in self.menuItem(app, title) != nil }
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 3)
    return menuItem(app, title)
  }

  /// Escape the open diff menu and wait until it is really gone, so the next menu's checks can't be
  /// satisfied by this one. "Keep Open" is the witness: only a preview diff's chip/panel menu has it.
  private func dismissDiffMenu(_ app: XCUIApplication) {
    app.typeKey(.escape, modifierFlags: [])
    let closed = NSPredicate { _, _ in self.menuItem(app, "Keep Open") == nil }
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 4),
      .completed, "the menu should close on Escape")
  }

  // MARK: Terminal tab — toolbar, then File ▸ Close All Tabs

  /// A terminal tab's toolbar offers Split-right + Split-down + Close-all, but NOT Open-file-in (that's
  /// diff-only); both split buttons add a pane; then File ▸ Close All Tabs closes every tab, with
  /// Close Other Tabs offered too (enabled with ≥2 tabs).
  func testTerminalToolbarSplitsThenFileMenuClosesAll() {
    let app = launchedApp()
    openWorkroom(app)
    XCTAssertTrue(app.buttons["pane.toolbar.splitRight"].waitForExistence(timeout: 6))
    XCTAssertTrue(app.buttons["pane.toolbar.splitDown"].exists)
    XCTAssertTrue(app.buttons["workroom.pane.closeAll"].exists)
    XCTAssertFalse(
      app.buttons["pane.toolbar.openFile"].exists, "a terminal tab has no Open-file action")
    // …and no optional controls at all, so no overflow menu (the rendered half of
    // `PaneToolbarPresentationTests.testTerminalAndChangesetShowNoOptionalControls`).
    XCTAssertFalse(
      element(app, id: "pane.toolbar.overflow").exists, "a terminal tab has no overflow menu")

    assertCount(panes(app), reaches: 1)
    app.buttons["pane.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)
    // Every pane has its own bar now, so the split buttons are no longer unique: take the first.
    app.buttons.matching(identifier: "pane.toolbar.splitDown").firstMatch.click()
    assertCount(panes(app), reaches: 3)

    let fileMenu = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
    fileMenu.click()
    let closeAll = app.menuItems["Close All Tabs"]
    XCTAssertTrue(closeAll.waitForExistence(timeout: 3))
    XCTAssertTrue(app.menuItems["Close Other Tabs"].isEnabled, "≥2 tabs → Close Other Tabs enabled")
    closeAll.click()
    assertCount(panes(app), reaches: 0)
  }

  // MARK: Diff tab — toolbar, chip menu, panel menu (issue #72), Remove from Split (issue #122)

  /// One preview diff, walked through every surface:
  /// 1. its toolbar adds Open-file-in alongside Split-right/down + Close-all;
  /// 2. its chip menu carries the diff actions (Open File in…, Keep Open for a preview) and the split
  ///    + close group, but no "Remove from Split" while the tab is solo;
  /// 3. right-clicking the diff PANEL body shows the same menu as its chip;
  /// 4. Split Right from the chip menu opens a second pane;
  /// 5. "Remove from Split" on the second pane's body pulls it out, back to one pane (targeted by
  ///    position, since a same-file split makes the two chips share a title);
  /// 6. Split-right from the toolbar opens a second pane again;
  /// 7. the toolbar's Close-all closes every tab in the workroom.
  func testDiffTabToolbarMenusAndSplits() {
    let app = launchedApp()
    openWorkroom(app)
    openDiffPreview(app)
    assertCount(panes(app), reaches: 1)  // the diff is shown solo

    // 1. Toolbar.
    XCTAssertTrue(app.buttons["pane.toolbar.openFile"].waitForExistence(timeout: 6))
    XCTAssertTrue(app.buttons["pane.toolbar.splitRight"].exists)
    XCTAssertTrue(app.buttons["pane.toolbar.splitDown"].exists)
    XCTAssertTrue(app.buttons["workroom.pane.closeAll"].exists)

    // 2. Chip menu. "Keep Open" first: it proves THIS menu opened, so the absence check below can't
    // pass on a menu that never appeared.
    diffTab(app, "user.rb").rightClick()
    XCTAssertNotNil(waitForMenuItem(app, "Keep Open"), "a preview diff tab offers Keep Open")
    XCTAssertNotNil(menuItem(app, "Open File in…"))
    XCTAssertNotNil(menuItem(app, "Split Right"))
    XCTAssertNotNil(menuItem(app, "Close Others"))
    XCTAssertNotNil(menuItem(app, "Close All"))
    XCTAssertNil(
      menuItem(app, "Remove from Split"),
      "a solo tab is in no split, so Remove from Split must not appear")
    dismissDiffMenu(app)

    // 3. Panel menu.
    panes(app).firstMatch.rightClick()
    XCTAssertNotNil(
      waitForMenuItem(app, "Open File in…"),
      "the diff panel offers the same Open File in… as its tab")
    XCTAssertNotNil(menuItem(app, "Keep Open"))
    XCTAssertNotNil(menuItem(app, "Split Right"))
    XCTAssertNotNil(menuItem(app, "Close All"))
    dismissDiffMenu(app)

    // 4. Split from the chip menu.
    diffTab(app, "user.rb").rightClick()
    let split = waitForMenuItem(app, "Split Right")
    XCTAssertNotNil(split)
    split?.click()
    assertCount(panes(app), reaches: 2)

    // 5. Remove the second pane from the split via its body.
    panes(app).element(boundBy: 1).rightClick()
    let remove = waitForMenuItem(app, "Remove from Split")
    XCTAssertNotNil(remove, "a split member's menu offers Remove from Split")
    remove?.click()
    assertCount(panes(app), reaches: 1)  // extracted tab shown solo; split dissolved

    // 6. Split from the toolbar (one pane, so the button is unique again).
    app.buttons["pane.toolbar.splitRight"].click()
    assertCount(panes(app), reaches: 2)

    // 7. Close all from the toolbar.
    app.buttons["workroom.pane.closeAll"].click()
    assertCount(panes(app), reaches: 0)
  }
}
