import XCTest

/// Standalone terminals in the real window (#655, ADR 0077): their rows in the Terminals section
/// above the projects, their own title-bar tabs, and ⌥⌘T opening another. Seeded by the fixture's
/// `-WorkroomUITestStandaloneTerminals`, never a real project or config.
final class StandaloneTerminalUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The fixture's fixed ids (`UITestFixture.standaloneTerminalIDs`).
  private let seeded = [
    "standalone:00000000-0000-0000-0000-000000000651",
    "standalone:00000000-0000-0000-0000-000000000652",
  ]

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "2"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", prefix))
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func waitForCount(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", n), object: query)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  func testStandaloneTerminalsHaveRowsAndTitleBarTabsAndOptionCommandTOpensAnother() {
    let app = launchedApp()

    XCTAssertTrue(element(app, "sidebar.open").waitForExistence(timeout: 15))
    for id in seeded {
      XCTAssertTrue(element(app, "sidebar.open.workroom.\(id)").waitForExistence(timeout: 5), id)
      XCTAssertTrue(element(app, "workroom.tab.\(id)").exists, "\(id)'s title-bar tab")
    }
    // The section is above the projects.
    let firstRow = element(app, "sidebar.open.workroom.\(seeded[0])")
    let project = elements(app, prefix: "sidebar.project.").firstMatch
    if project.exists { XCTAssertLessThan(firstRow.frame.minY, project.frame.minY) }

    app.typeKey("t", modifierFlags: [.command, .option])

    XCTAssertTrue(
      waitForCount(elements(app, prefix: "sidebar.open.workroom.standalone:"), 3),
      "⌥⌘T adds a third row")
    XCTAssertTrue(
      waitForCount(elements(app, prefix: "workroom.tab.standalone:"), 3), "and its tab")

    // Folding the section hides its rows, not its tabs.
    element(app, "sidebar.open").click()
    XCTAssertTrue(waitForCount(elements(app, prefix: "sidebar.open.workroom.standalone:"), 0))
    XCTAssertEqual(elements(app, prefix: "workroom.tab.standalone:").count, 3)
  }

  /// Closing the selected standalone terminal with ⌘W lands on the one selected before it (#652
  /// critique): its row and title-bar tab selected, its terminal taking the keys.
  func testClosingAStandaloneTerminalSelectsAndFocusesThePreviousOne() {
    let app = launchedApp()
    let first = element(app, "sidebar.open.workroom.\(seeded[0])")
    let second = element(app, "sidebar.open.workroom.\(seeded[1])")
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    first.click()
    XCTAssertTrue(poll { self.element(app, "workroom.tab.\(self.seeded[0])").isSelected })
    second.click()
    XCTAssertTrue(poll { self.element(app, "workroom.tab.\(self.seeded[1])").isSelected })

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(
      waitForCount(elements(app, prefix: "sidebar.open.workroom.standalone:"), 1), "its row goes")
    XCTAssertTrue(
      poll { self.element(app, "workroom.tab.\(self.seeded[0])").isSelected },
      "the first terminal is selected (its row's selection isn't exposed; its tab's is)")
    // The keys reach its terminal without a click: it has the focus.
    app.typeText("echo WRCLOSE$((40+2))\r")
    let surfaces = app.descendants(matching: .any).matching(identifier: "terminal.surface")
    XCTAssertTrue(
      poll(timeout: 20) {
        surfaces.allElementsBoundByIndex.contains {
          (($0.value as? String) ?? "").contains("WRCLOSE42")
        }
      }, "the typed command ran in a terminal")
  }

  /// A standalone terminal's row has a close button, shown on hover in the trailing column every
  /// sidebar "+" is in, which closes that terminal, as its menu's Close does: its row and title-bar
  /// tab go, and the other terminal's stay.
  func testAStandaloneRowsCloseButtonClosesItsTerminal() {
    let app = launchedApp()
    let row = element(app, "sidebar.open.workroom.\(seeded[0])")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    row.hover()
    let close = element(app, "sidebar.open.close.\(seeded[0])")
    XCTAssertTrue(close.waitForExistence(timeout: 5), "the row's close button")
    XCTAssertEqual(
      close.frame.midX, element(app, "sidebar.open.add").frame.midX, accuracy: 0.5,
      "in the heading's \"+\" column")

    close.click()

    XCTAssertTrue(
      waitForCount(elements(app, prefix: "sidebar.open.workroom.standalone:"), 1), "its row goes")
    XCTAssertFalse(row.exists)
    XCTAssertTrue(waitForCount(elements(app, prefix: "workroom.tab.standalone:"), 1), "its tab")
    XCTAssertTrue(element(app, "sidebar.open.workroom.\(seeded[1])").exists, "the other's stays")
  }

  private func poll(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// #657: with no projects the empty state offers New Terminal; using it opens a terminal that has
  /// a row in the sidebar, which is shown (with its toggle) though there is still no project.
  /// Rename… on a standalone terminal's row edits its name in place, as a group's row does (#652
  /// critique); its title-bar tab's menu offers Rename… too, with no Run, Restart or Stop, and
  /// that also edits the row.
  func testRenameEditsAStandaloneTerminalsNameInItsRow() {
    let app = launchedApp()
    let id = seeded[0]
    let row = element(app, "sidebar.open.workroom.\(id)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    let field = element(app, "sidebar.open.rename.\(id)")

    row.rightClick()
    app.waitForHittableMenuItem(titled: "Rename…")?.click()
    XCTAssertTrue(field.waitForExistence(timeout: 6), "an inline name field, not a sheet")
    XCTAssertFalse(app.sheets.firstMatch.exists, "no sheet")
    field.typeText("Build box\r")
    let named = { (name: String) in
      XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name),
        object: self.element(app, "workroom.tab.\(id)"))
    }
    XCTAssertEqual(XCTWaiter().wait(for: [named("Build box")], timeout: 6), .completed)
    XCTAssertFalse(field.exists, "the field closes")

    // From its title-bar tab: no run items, and Rename… edits the row.
    element(app, "workroom.tab.\(id)").rightClick()
    let rename = app.waitForHittableMenuItem(titled: "Rename…")
    XCTAssertNotNil(rename, "its tab offers Rename…")
    // The menu bar's Room menu has its own Run, Restart and Stop, closed and so not hittable.
    for title in ["Run", "Restart", "Stop"] {
      XCTAssertFalse(
        app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex
          .contains { $0.isHittable }, "no \(title) on a standalone terminal's tab")
    }
    rename?.click()
    XCTAssertTrue(field.waitForExistence(timeout: 6), "the row's inline name field")
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Logs\r")
    XCTAssertEqual(XCTWaiter().wait(for: [named("Logs")], timeout: 6), .completed)
  }

  func testWithNoProjectsNewTerminalOpensATerminalWithARow() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-WorkroomUITestNoProjects", "1"]
    app.launchArguments += ["-WorkroomUITestOnboarding", "hide"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()

    let newTerminal = element(app, "EmptyStateNewTerminal")
    XCTAssertTrue(newTerminal.waitForExistence(timeout: 15), "the empty state offers New Terminal")
    XCTAssertFalse(element(app, "toolbar.toggleSidebar").exists, "nothing to list yet")
    newTerminal.click()

    XCTAssertTrue(
      waitForCount(elements(app, prefix: "sidebar.open.workroom.standalone:"), 1), "its row")
    XCTAssertTrue(element(app, "toolbar.toggleSidebar").exists, "the sidebar toggle shows")
    XCTAssertFalse(newTerminal.exists, "the empty state gives way to the terminal")
  }

  /// #662: a window with only a standalone terminal still opens the picker (⌘O), and it lists that
  /// terminal under Terminals.
  func testTheOpenPickerListsAStandaloneTerminalWithNoProjects() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-WorkroomUITestNoProjects", "1"]
    app.launchArguments += ["-WorkroomUITestOnboarding", "hide"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    let newTerminal = element(app, "EmptyStateNewTerminal")
    XCTAssertTrue(newTerminal.waitForExistence(timeout: 15))
    newTerminal.click()
    XCTAssertTrue(waitForCount(elements(app, prefix: "sidebar.open.workroom.standalone:"), 1))

    app.typeKey("o", modifierFlags: .command)

    XCTAssertTrue(element(app, "openWorkroom.filter").waitForExistence(timeout: 6), "the picker")
    let heading = app.staticTexts.matching(
      NSPredicate(format: "label ==[c] 'Terminals' OR value ==[c] 'Terminals'")
    ).firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 6), "its heading")
    XCTAssertTrue(
      elements(app, prefix: "openWorkroom.target.").firstMatch.waitForExistence(timeout: 6),
      "lists the terminal")
  }
}
