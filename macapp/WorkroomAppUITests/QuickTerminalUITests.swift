import XCTest

/// The Quick Terminal's window (issue #39), hosted by `QuickTerminalHost`: summoned from File ▸
/// Quick Terminal, its tabs and splits driven by the keys `AppDelegate`'s monitor routes to it
/// (`QuickTerminalKey`) and by a pane's right-click menu, hidden with its last tab, summoned
/// fresh, a pane moved out into a workroom, and its sidebar row sliding it in (#661).
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
  /// A non-activating panel, AppKit gives it the system-dialog subrole, so XCUITest lists it under
  /// `dialogs`, not `windows`.
  private func quickTerminal(_ app: XCUIApplication) -> XCUIElement {
    app.dialogs.matching(NSPredicate(format: "title == %@", "Quick Terminal")).firstMatch
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
  /// tab, which hides its window:
  ///
  /// 1. Summoned, it opens with one terminal tab.
  /// 2. ⌘T adds a tab, ⌘D splits it, ⌘W closes the split's pane and then a tab: its own keys, not
  ///    the workroom window's (both windows count separately, and the workroom's stays as it was).
  /// 3. ⌘W on its last tab hides the window (`onTargetEmptied`); the group stays.
  /// 4. Summoned again, it comes back with one fresh tab.
  /// 5. Its pane's "Move to workroom" button moves the tab into the fixture workroom: the
  ///    workroom's strip gains it, and the Quick Terminal, left with no tab, hides.
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
      waitForCount(app.dialogs, 1), "summoning adds exactly one window, the panel")
    XCTAssertEqual(app.windows.count, windowsBefore, "and opens no other")
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

    // 3. Its last tab hides the window.
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      quickTerminal(app).waitForNonExistence(timeout: 10),
      "closing its last tab hides the Quick Terminal")
    XCTAssertTrue(waitForCount(app.dialogs, 0), "and only its window went")
    XCTAssertEqual(app.windows.count, windowsBefore, "the workroom's stay")

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
      "the Quick Terminal's only tab left it, so it hides")
  }

  /// #661: the Quick Terminal is the built-in group, listed first in the Terminals section, above
  /// the projects. Clicking its row slides its panel in, with a terminal, and the window stays on
  /// the workroom it showed, opening no terminal of its own.
  func testItsSidebarRowSlidesThePanelInAndKeepsTheWindowsSelection() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let workroom = workroomWindow(app)
    XCTAssertTrue(
      panes(in: workroom).firstMatch.waitForExistence(timeout: 15),
      "the fixture workroom should render a terminal pane on launch")
    let workroomTabsBefore = tabs(in: workroom).count
    let row = workroom.descendants(matching: .any)
      .matching(identifier: "sidebar.group.group:51C10A7E-0D4F-4E6A-9B2C-000000000001").firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Quick Terminal has a sidebar row")
    let project = workroom.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.project.")).firstMatch
    if project.exists {
      XCTAssertLessThan(row.frame.minY, project.frame.minY, "above the projects")
    }
    XCTAssertFalse(quickTerminal(app).exists, "no Quick Terminal yet")
    let fold = workroom.descendants(matching: .any)
      .matching(identifier: "sidebar.group.fold.group:51C10A7E-0D4F-4E6A-9B2C-000000000001")
      .firstMatch
    row.hover()
    XCTAssertFalse(
      fold.waitForExistence(timeout: 2), "with no terminals to list, hovering shows no chevron")

    row.click()

    let qt = quickTerminal(app)
    XCTAssertTrue(qt.waitForExistence(timeout: 15), "its row slides the panel in")
    assertCounts(in: qt, tabs: 1, panes: 1, "slid in from its row")
    XCTAssertTrue(
      waitForCount(tabs(in: workroom), workroomTabsBefore), "the window opened no terminal")
    XCTAssertTrue(panes(in: workroom).firstMatch.exists, "and still shows its workroom")
    // Listing its terminal under it, its row folds as the other groups' do: hovered, the chevron
    // sits after its name and clear of the trailing "+".
    row.hover()
    XCTAssertTrue(fold.waitForExistence(timeout: 6), "a chevron once it lists a terminal")
    let name = row.staticTexts["Quick Terminals"].firstMatch
    XCTAssertTrue(name.exists, "the group's name on its row")
    XCTAssertGreaterThanOrEqual(fold.frame.minX, name.frame.maxX, "after the name")
    let plus = workroom.descendants(matching: .any)
      .matching(identifier: "sidebar.group.new.group:51C10A7E-0D4F-4E6A-9B2C-000000000001")
      .firstMatch
    XCTAssertTrue(plus.exists, "New Terminal in Group on its row")
    XCTAssertLessThan(fold.frame.maxX, plus.frame.minX, "clear of the trailing column")
  }

  /// The Quick Terminal's sidebar row, the built-in group's.
  private func quickTerminalRow(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)
      .matching(identifier: "sidebar.group.group:51C10A7E-0D4F-4E6A-9B2C-000000000001").firstMatch
  }

  /// #652 stories 29, 37: a workroom terminal's tab dragged onto the Quick Terminal's sidebar row
  /// moves into its panel, which slides in holding it; the workroom's strip loses the tab.
  func testATabDroppedOnItsSidebarRowMovesIntoThePanel() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let workroom = workroomWindow(app)
    let chip = workroom.descendants(matching: .any).matching(identifier: "terminal.tab.Terminal 1")
      .firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the fixture workroom's terminal tab")
    let workroomTabsBefore = tabs(in: workroom).count
    let row = quickTerminalRow(in: workroom)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Quick Terminal has a sidebar row")
    XCTAssertFalse(quickTerminal(app).exists, "no Quick Terminal yet")

    // `click(forDuration:thenDragTo:)`, the mouse drag: on macOS 27 `press` posts no mouse
    // events from an element, so nothing drags (#269).
    chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

    let qt = quickTerminal(app)
    XCTAssertTrue(qt.waitForExistence(timeout: 15), "the drop slides the panel in")
    assertCounts(in: qt, tabs: 1, panes: 1, "holding the moved terminal")
    XCTAssertTrue(
      waitForCount(tabs(in: workroom), workroomTabsBefore - 1), "the workroom's strip lost it")
  }

  /// #652: a standalone terminal's sidebar row dragged from the window onto the showing panel's
  /// tab joins the Quick Terminal there. The press in the window takes focus from the panel, which
  /// would slide it away (it hides on losing focus, by default); it stays up through the drop.
  func testAStandaloneRowDraggedOntoThePanelsTabJoinsIt() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestStandaloneTerminals", "1",
    ]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let row = app.descendants(matching: .any)
      .matching(identifier: "sidebar.standalone.standalone:00000000-0000-0000-0000-000000000651")
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15), "the fixture's standalone terminal's row")
    let qt = summon(app)
    assertCounts(in: qt, tabs: 1, panes: 1, "summoned with one terminal")
    let panelTab = tabs(in: qt).firstMatch
    XCTAssertFalse(
      qt.frame.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)), "the row is not under it")

    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: panelTab.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))

    assertCounts(in: qt, tabs: 2, panes: 1, "the panel took the dropped terminal")
    XCTAssertTrue(
      waitForCount(
        app.descendants(matching: .any).matching(
          identifier: "sidebar.standalone.standalone:00000000-0000-0000-0000-000000000651"), 0),
      "its standalone row went")
    XCTAssertTrue(qt.isHittable, "the panel stayed up")
  }

  /// #652 story 39: the Quick Terminal's only pane popped out by its right-click Move to New Window
  /// hides the panel; the Window menu's "Move back to main window", with the pane's window key,
  /// docks it back into the panel, which slides in holding it.
  func testAPanePoppedOutOfThePanelDocksBackFromTheWindowMenu() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(in: workroomWindow(app)).firstMatch.waitForExistence(timeout: 15),
      "the fixture workroom should render a terminal pane on launch")
    let qt = summon(app)
    assertCounts(in: qt, tabs: 1, panes: 1, "summoned")

    choose("Move to New Window", onAPaneIn: qt, app)
    let detached = app.windows["detachedPane.window"]
    XCTAssertTrue(detached.waitForExistence(timeout: 10), "the pane pops out into its own window")
    XCTAssertTrue(
      quickTerminal(app).waitForNonExistence(timeout: 10),
      "its only docked pane left, so the panel hides")

    let dock = app.menuBars.menuBarItems["Window"].menuItems["Move back to main window"]
    XCTAssertTrue(dock.waitForExistence(timeout: 5), "the Window menu offers the dock")
    dock.click()

    XCTAssertTrue(detached.waitForNonExistence(timeout: 10), "the pane's window goes")
    let back = quickTerminal(app)
    XCTAssertTrue(back.waitForExistence(timeout: 15), "the panel slides in")
    assertCounts(in: back, tabs: 1, panes: 1, "holding the docked pane")
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

  /// Launch restore (#661, story 44): the Quick Terminal's saved layout in `session.json` comes
  /// back at launch, hidden, and its first summon shows exactly the saved terminals, with their
  /// names and no stray fresh one. Seeded by writing the panel's entry into the file a first launch
  /// wrote, as `SessionRestoreUITests` seeds a sibling window; the second quit then checks the
  /// panel's entry is written back whole.
  ///
  /// Not covered: reattaching to live sessions. The fixture runs no session daemon, so the seeded
  /// session ids find nothing to attach to and the panes start fresh shells in their place, which
  /// is the path `restore` documents for a session it can't reach. Reattach itself, and the
  /// notifications a reattached pane raises before the first summon, are covered by
  /// `QuickTerminalRestoreTests` and `PersistentSessionRecoveryTests` with a stubbed recover step.
  func testTheQuickTerminalsSavedTerminalsComeBackAtLaunch() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-uitest-qt-\(UUID().uuidString)", isDirectory: true)
    let sessionFile = directory.appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    func launch() -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments += ["-WorkroomUITestFixture", "1"]
      app.launchArguments += ["-WorkroomUITestSessionFile", sessionFile.path]
      app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
      app.launch()
      app.activate()
      return app
    }
    func quitAndWaitForSave(_ app: XCUIApplication) {
      app.terminate()
      let written = NSPredicate { _, _ in
        ((try? FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size]) as? Int ?? 0)
          > 0
      }
      XCTAssertEqual(
        XCTWaiter().wait(
          for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 10),
        .completed, "quitting should write the session")
    }

    // First launch: just to have the app write a valid session file.
    let first = launch()
    XCTAssertTrue(first.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(in: workroomWindow(first)).firstMatch.waitForExistence(timeout: 15),
      "the fixture workroom should render a terminal pane on launch")
    quitAndWaitForSave(first)

    func terminal(_ key: String, _ title: String) -> [String: Any] {
      [
        "key": key, "kind": "terminal",
        "terminal": [
          "defaultTitle": title, "userTitle": "Restored \(key)",
          "sessionID": UUID().uuidString,
        ],
      ]
    }
    let data = try Data(contentsOf: sessionFile)
    var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    document["quickTerminal"] = [
      "targetID": "group:51C10A7E-0D4F-4E6A-9B2C-000000000001",
      "tabs": [terminal("a", "Terminal 1"), terminal("b", "Terminal 2")],
      "focusedKey": "a", "terminalCounter": 2,
    ]
    try JSONSerialization.data(withJSONObject: document).write(to: sessionFile)

    // Relaunch: the panel is restored hidden, then summoned.
    let app = launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(in: workroomWindow(app)).firstMatch.waitForExistence(timeout: 15),
      "the fixture workroom should render a terminal pane on launch")
    XCTAssertFalse(quickTerminal(app).exists, "restored hidden: no panel until it is summoned")
    let qt = summon(app)
    XCTAssertTrue(
      waitForCount(tabs(in: qt), 2),
      "the panel should hold its 2 saved terminals, has \(tabs(in: qt).count)")
    // A chip is identified by its app-given name ("Terminal 1"); its label is the title it shows.
    for (key, name) in [("a", "Terminal 1"), ("b", "Terminal 2")] {
      let chip = qt.staticTexts["terminal.tab.\(name)"]
      let named = NSPredicate(format: "label CONTAINS %@", "Restored \(key)")
      XCTAssertEqual(
        XCTWaiter().wait(
          for: [XCTNSPredicateExpectation(predicate: named, object: chip)], timeout: 5),
        .completed, "the saved terminal keeps the name it was given")
    }

    // The second quit writes the panel's entry back whole.
    quitAndWaitForSave(app)
    let after = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile)) as? [String: Any])
    let saved = try XCTUnwrap(after["quickTerminal"] as? [String: Any], "the panel is saved again")
    XCTAssertEqual((saved["tabs"] as? [Any])?.count, 2)
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
    app.menuItems.matching(NSPredicate(format: "title ENDSWITH %@", " / uitest-room"))
      .allElementsBoundByIndex.first { $0.isHittable }
  }
}
