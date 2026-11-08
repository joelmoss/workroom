import XCTest

/// The Quick Terminal's window (issue #39), hosted by `QuickTerminalHost`: summoned from File ▸
/// Quick Terminal, its tabs and splits driven by the keys `AppDelegate`'s monitor routes to it
/// (`QuickTerminalKey`) and by a pane's right-click menu, closed with its last tab, summoned
/// fresh, and a pane moved out into a workroom.
///
/// Summoned from the menu item, never its key equivalent: that is ⌥§ by default, which no test
/// should rely on. Every count is scoped to the Quick Terminal's window, because the fixture's
/// workroom window carries the same `terminal.pane` and `terminal.tab.` ids.
///
/// The fixture turns the close confirm off (`TabCloseFlow` asks nothing when
/// `AppEnvironment.current.isFixture`), so ⌘W closes at once.
///
/// Not covered: the hotkey's hide and re-show of the same window (a global Carbon hotkey, which a
/// Debug build does not register), hiding when it loses focus, and dragging it along the screen
/// edges (`QuickTerminalDragHandle`: a synthetic drag around a window's title region does not behave
/// like a real mouse, see `WindowDragUITests`). Its docking geometry is covered by
/// `QuickTerminalControllerTests`.
final class QuickTerminalUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// The Quick Terminal's window, by its title: it is the app's only window titled so, and its
  /// title is fixed (`QuickTerminalController.createWindow`), hidden from view but not from AX.
  private func quickTerminal(_ app: XCUIApplication) -> XCUIElement {
    app.windows.matching(NSPredicate(format: "title == %@", "Quick Terminal")).firstMatch
  }

  /// The fixture's workroom window: every window but the Quick Terminal's.
  private func workroomWindow(_ app: XCUIApplication) -> XCUIElement {
    app.windows.matching(NSPredicate(format: "title != %@", "Quick Terminal")).firstMatch
  }

  /// One `terminal.pane` per rendered leaf in `window`.
  private func panes(in window: XCUIElement) -> XCUIElementQuery {
    window.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  /// One strip chip per terminal in `window`. A chip's title and close button share its
  /// `terminal.tab.<title>` id, so only the title's StaticText is counted (as `SplitPaneUITests`).
  private func tabs(in window: XCUIElement) -> XCUIElementQuery {
    window.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func waitForCount(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", n), object: query)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  private func assertCounts(
    in window: XCUIElement, tabs tabCount: Int, panes paneCount: Int, _ step: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      waitForCount(tabs(in: window), tabCount),
      "\(step): the Quick Terminal should have \(tabCount) tab(s), has \(tabs(in: window).count)",
      file: file, line: line)
    XCTAssertTrue(
      waitForCount(panes(in: window), paneCount),
      "\(step): the Quick Terminal should show \(paneCount) pane(s), "
        + "shows \(panes(in: window).count)",
      file: file, line: line)
  }

  /// File ▸ Quick Terminal, then wait for its window. A first summon can wait on the session
  /// backend's first health check before it makes the window (`QuickTerminalController.show`).
  private func summon(_ app: XCUIApplication) -> XCUIElement {
    let item = app.menuBars.menuBarItems["File"].menuItems["Quick Terminal"]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "File offers Quick Terminal")
    item.click()
    let window = quickTerminal(app)
    XCTAssertTrue(window.waitForExistence(timeout: 15), "the Quick Terminal's window should appear")
    return window
  }

  /// One launch, one ordered chain; the move runs last because it takes the Quick Terminal's only
  /// tab, which closes its window:
  ///
  /// 1. Summoned, it opens with one terminal tab.
  /// 2. ⌘T adds a tab, ⌘D splits it, ⌘W closes the split's pane and then a tab: its own keys, not
  ///    the workroom window's (both windows count separately, and the workroom's stays as it was).
  /// 3. ⌘W on its last tab closes the window (`onTargetEmptied`).
  /// 4. Summoned again, it comes back with one fresh tab.
  /// 5. Its pane's "Move to workroom" button moves the tab into the fixture workroom: the
  ///    workroom's strip gains it, and the Quick Terminal, left with no tab, closes.
  func testSummonTabsSplitsClosesResummonsAndMovesAPaneIntoAWorkroom() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let workroom = workroomWindow(app)
    XCTAssertTrue(
      panes(in: workroom).firstMatch.waitForExistence(timeout: 15),
      "the fixture workroom should render a terminal pane on launch")
    let windowsBefore = app.windows.count
    let workroomTabsBefore = tabs(in: workroom).count
    XCTAssertFalse(quickTerminal(app).exists, "no Quick Terminal at launch")

    // 1. Summon.
    var qt = summon(app)
    XCTAssertTrue(
      waitForCount(app.windows, windowsBefore + 1), "summoning adds exactly one window")
    assertCounts(in: qt, tabs: 1, panes: 1, "summoned")

    // 2. Its keys.
    app.typeKey("t", modifierFlags: .command)
    assertCounts(in: qt, tabs: 2, panes: 1, "after ⌘T")
    // A split's new terminal has its own strip tab.
    app.typeKey("d", modifierFlags: .command)
    assertCounts(in: qt, tabs: 3, panes: 2, "after ⌘D")
    app.typeKey("w", modifierFlags: .command)
    assertCounts(in: qt, tabs: 2, panes: 1, "after ⌘W on the split's pane")
    app.typeKey("w", modifierFlags: .command)
    assertCounts(in: qt, tabs: 1, panes: 1, "after ⌘W on a tab")
    XCTAssertTrue(
      waitForCount(tabs(in: workroom), workroomTabsBefore),
      "the keys acted on the Quick Terminal, not the workroom window")

    // 3. Its last tab closes the window.
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      quickTerminal(app).waitForNonExistence(timeout: 10),
      "closing its last tab closes the Quick Terminal")
    XCTAssertTrue(waitForCount(app.windows, windowsBefore), "and only its window went")

    // 4. Summon again: a fresh window with one tab.
    qt = summon(app)
    assertCounts(in: qt, tabs: 1, panes: 1, "summoned again")

    // 5. Move its pane into the fixture workroom. The button is the pane title bar's menu
    // (`QuickTerminalMoveToWorkroomMenu`); its items are "<project> — <workroom>", and the
    // project's root may be listed beside the workroom, so the item is picked by the workroom.
    let move = qt.descendants(matching: .any).matching(identifier: "pane.toolbar.moveToWorkroom")
      .firstMatch
    XCTAssertTrue(
      move.waitForExistence(timeout: 5), "a Quick Terminal pane offers Move to workroom")
    move.click()
    let shown = NSPredicate { _, _ in self.workroomItem(app) != nil }
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 5)
    guard let item = workroomItem(app) else {
      return XCTFail("Move to workroom should list the fixture workroom")
    }
    item.click()
    XCTAssertTrue(
      waitForCount(tabs(in: workroomWindow(app)), workroomTabsBefore + 1),
      "the moved tab joins the workroom's strip")
    XCTAssertTrue(
      quickTerminal(app).waitForNonExistence(timeout: 10),
      "the Quick Terminal's only tab left it, so it closes")
  }

  /// A Quick Terminal pane's right-click Split Right, New Terminal and Close Terminal act on the
  /// Quick Terminal, not on the workroom window behind it (#583), which keeps its tabs and panes.
  func testAPanesRightClickMenuActsOnTheQuickTerminal() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let workroom = workroomWindow(app)
    XCTAssertTrue(
      panes(in: workroom).firstMatch.waitForExistence(timeout: 15),
      "the fixture workroom should render a terminal pane on launch")
    let workroomTabsBefore = tabs(in: workroom).count
    let workroomPanesBefore = panes(in: workroom).count
    let qt = summon(app)
    assertCounts(in: qt, tabs: 1, panes: 1, "summoned")

    choose("Split Right", onAPaneIn: qt, app)
    assertCounts(in: qt, tabs: 2, panes: 2, "after Split Right")
    choose("New Terminal", onAPaneIn: qt, app)
    assertCounts(in: qt, tabs: 3, panes: 1, "after New Terminal")
    choose("Close Terminal", onAPaneIn: qt, app)
    XCTAssertTrue(
      waitForCount(tabs(in: qt), 2),
      "after Close Terminal: the Quick Terminal should have 2 tabs, has \(tabs(in: qt).count)")

    XCTAssertTrue(
      waitForCount(tabs(in: workroom), workroomTabsBefore), "the workroom kept its tabs")
    XCTAssertTrue(waitForCount(panes(in: workroom), workroomPanesBefore), "and its panes")
  }

  /// Right-click a pane in `window` and choose `title` from its menu.
  private func choose(
    _ title: String, onAPaneIn window: XCUIElement, _ app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    panes(in: window).firstMatch.rightClick()
    guard let item = app.waitForHittableMenuItem(titled: title) else {
      return XCTFail("the pane's menu should offer \(title)", file: file, line: line)
    }
    item.click()
  }

  /// The on-screen "Move to workroom" item for the fixture workroom (`uitest-room`), not the
  /// project's root.
  private func workroomItem(_ app: XCUIApplication) -> XCUIElement? {
    app.menuItems.matching(NSPredicate(format: "title ENDSWITH %@", "— uitest-room"))
      .allElementsBoundByIndex.first { $0.isHittable }
  }
}
