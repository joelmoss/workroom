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

    XCTAssertTrue(element(app, "sidebar.terminals").waitForExistence(timeout: 15))
    for id in seeded {
      XCTAssertTrue(element(app, "sidebar.standalone.\(id)").waitForExistence(timeout: 5), id)
      XCTAssertTrue(element(app, "workroom.tab.\(id)").exists, "\(id)'s title-bar tab")
    }
    // The section is above the projects.
    let firstRow = element(app, "sidebar.standalone.\(seeded[0])")
    let project = elements(app, prefix: "sidebar.project.").firstMatch
    if project.exists { XCTAssertLessThan(firstRow.frame.minY, project.frame.minY) }

    app.typeKey("t", modifierFlags: [.command, .option])

    XCTAssertTrue(
      waitForCount(elements(app, prefix: "sidebar.standalone."), 3), "⌥⌘T adds a third row")
    XCTAssertTrue(
      waitForCount(elements(app, prefix: "workroom.tab.standalone:"), 3), "and its tab")

    // Folding the section hides its rows, not its tabs.
    element(app, "sidebar.terminals").click()
    XCTAssertTrue(waitForCount(elements(app, prefix: "sidebar.standalone."), 0))
    XCTAssertEqual(elements(app, prefix: "workroom.tab.standalone:").count, 3)
  }

  /// #657: with no projects the empty state offers New Terminal; using it opens a terminal that has
  /// a row in the sidebar, which is shown (with its toggle) though there is still no project.
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

    XCTAssertTrue(waitForCount(elements(app, prefix: "sidebar.standalone."), 1), "its row")
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
    XCTAssertTrue(waitForCount(elements(app, prefix: "sidebar.standalone."), 1))

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
