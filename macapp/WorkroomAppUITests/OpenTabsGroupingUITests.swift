import XCTest

/// The Open Tabs view's header controls, through the real window: Group by regroups the rows, and
/// Expand All / Collapse All folds and unfolds them. Wiring only; the layouts and fold rules are
/// `OpenTabsGroupingTests`'. Fixture only, never a real project or config. Run in the VM:
/// `make app-uitest-vm APP_UITEST_FLAGS="-only-testing:WorkroomAppUITests/OpenTabsGroupingUITests"`.
final class OpenTabsGroupingUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The fixture's project, whose two workrooms each have a tab open (`-WorkroomUITestTwoTabs`).
  private let header = "sidebar.open.project.UITestProject"

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestTwoTabs", "1",
      "-WorkroomUITestStandaloneTerminals", "1",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    app.activate()
    addTeardownBlock { app.terminate() }
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func tabRows(_ app: XCUIApplication) -> Int {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.open.tab.")
    ).count
  }

  private func poll(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// Picks `title` from the header's Group by menu.
  private func group(_ app: XCUIApplication, by title: String) {
    let button = element(app, "sidebar.open.groupBy")
    XCTAssertTrue(button.waitForExistence(timeout: 15), "the header's Group by button")
    button.click()
    let item = app.menuItems[title]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "Group by offers \(title)")
    item.click()
  }

  /// Group by lays the rows out by the grouping picked: project headers in the project groupings,
  /// none in Workroom or None, and every tab listed in None.
  func testGroupByRegroupsTheRows() {
    let app = launchedApp()
    XCTAssertTrue(element(app, "sidebar.view.open").waitForExistence(timeout: 15))
    XCTAssertFalse(element(app, header).exists, "Workroom, the default, has no project headers")

    group(app, by: "Project › Workroom")
    XCTAssertTrue(element(app, header).waitForExistence(timeout: 5), "a header for the project")

    group(app, by: "Project")
    XCTAssertTrue(element(app, header).waitForExistence(timeout: 5))
    XCTAssertTrue(poll { self.tabRows(app) >= 2 }, "both workrooms' tabs under it")

    group(app, by: "None")
    XCTAssertTrue(poll { !self.element(app, self.header).exists }, "no headers")
    XCTAssertTrue(poll { self.tabRows(app) >= 2 }, "every tab, flat")
    XCTAssertFalse(element(app, "sidebar.open.foldAll").exists, "nothing folds in None")

    group(app, by: "Workroom")
    XCTAssertTrue(poll { !self.element(app, self.header).exists })
  }

  /// The Projects view's header has the same button: Collapse All, then Expand All.
  func testTheProjectsViewHasExpandAndCollapseAll() {
    let app = launchedApp()
    let projects = element(app, "sidebar.view.projects")
    XCTAssertTrue(projects.waitForExistence(timeout: 15))
    projects.click()
    let button = element(app, "sidebar.projects.foldAll")
    XCTAssertTrue(button.waitForExistence(timeout: 5), "the Projects view's fold button")
    XCTAssertEqual(button.label, "Collapse All", "the fixture's project is expanded")

    button.click()
    XCTAssertTrue(poll { button.label == "Expand All" })
    button.click()
    XCTAssertTrue(poll { button.label == "Collapse All" })
  }

  /// Collapse All folds every header and row, leaving no tab rows, and then offers Expand All,
  /// which shows them again.
  func testCollapseAllThenExpandAll() {
    let app = launchedApp()
    group(app, by: "Project › Workroom")
    XCTAssertTrue(element(app, header).waitForExistence(timeout: 5))
    let button = element(app, "sidebar.open.foldAll")
    XCTAssertTrue(button.waitForExistence(timeout: 5), "the header's fold button")
    XCTAssertTrue(poll { self.tabRows(app) > 0 }, "the selected workroom's tabs show")
    XCTAssertEqual(button.label, "Collapse All")

    button.click()
    XCTAssertTrue(poll { self.tabRows(app) == 0 }, "every row folded")
    XCTAssertTrue(poll { button.label == "Expand All" })

    button.click()
    XCTAssertTrue(poll { self.tabRows(app) >= 2 }, "every row unfolded")
    XCTAssertTrue(poll { button.label == "Collapse All" })
  }
}
