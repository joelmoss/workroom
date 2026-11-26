import XCTest

/// The sidebar's view switcher (ADR 0083): one bar at the top of the sidebar whose tabs show the
/// Open view or the Projects view, one at a time, and whose "+" acts on the view shown. Fixture
/// only, never a real project or config.
final class SidebarViewSwitcherUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extra
    app.launch()
    app.activate()
    addTeardownBlock { app.terminate() }
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// The Open view's first workroom row (the fixture's workroom tab).
  private func openRow(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.open.workroom.")
    ).firstMatch
  }

  private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
  }

  /// A window opens on the Open view; the Projects tab shows the project tree in its place and
  /// the Open tab brings the Open rows back, the switcher above both.
  func testTheTabsSwitchBetweenOpenAndProjects() {
    let app = launchedApp()
    let open = element(app, "sidebar.view.open")
    let projects = element(app, "sidebar.view.projects")
    XCTAssertTrue(open.waitForExistence(timeout: 15), "the Open tab")
    XCTAssertTrue(projects.exists, "the Projects tab")
    XCTAssertLessThan(open.frame.minX, projects.frame.minX, "Open first")
    let row = openRow(app)
    let project = element(app, "sidebar.project.UITestProject")
    XCTAssertTrue(row.waitForExistence(timeout: 6), "a new window shows the Open view")
    XCTAssertFalse(project.exists, "and not the project tree")
    XCTAssertGreaterThan(row.frame.minY, open.frame.maxY - 1, "under the switcher")

    projects.click()
    XCTAssertTrue(project.waitForExistence(timeout: 6), "the Projects tab shows the tree")
    XCTAssertTrue(waitGone(row), "in the Open view's place")
    XCTAssertGreaterThan(project.frame.minY, projects.frame.maxY - 1, "under the switcher")
    XCTAssertTrue(open.isHittable, "the switcher stays")

    open.click()
    XCTAssertTrue(row.waitForExistence(timeout: 6), "the Open tab brings the Open rows back")
    XCTAssertTrue(waitGone(project))
  }

  /// The "+" is the shown view's: in Open its menu makes a terminal or group, in Projects it adds a
  /// project.
  func testThePlusActsOnTheShownView() {
    let app = launchedApp()
    let add = element(app, "sidebar.add")
    XCTAssertTrue(add.waitForExistence(timeout: 15), "the switcher's +")
    add.click()
    let newTerminal = element(app, "sidebar.open.add.newTerminal")
    XCTAssertTrue(newTerminal.waitForExistence(timeout: 5), "in Open, the new-terminal menu")
    XCTAssertFalse(
      element(app, "sidebar.open.add.openWorkroom").exists, "opening a workroom is ⌘O's")
    XCTAssertTrue(element(app, "sidebar.open.add.newGroup").exists)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitGone(newTerminal), "Escape closes the menu")

    app.showProjectsView()
    XCTAssertTrue(element(app, "sidebar.project.UITestProject").waitForExistence(timeout: 6))
    add.click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 6), "in Projects, the New Project sheet")
    element(app, "addProject.cancelButton").click()
    XCTAssertTrue(waitGone(sheet), "Cancel closes it")
  }

  /// With no projects, once a terminal shows the sidebar, the Projects view says so and its "+"
  /// adds one. (With nothing at all the sidebar stays hidden and the empty state offers Add
  /// Project itself.)
  func testWithNoProjectsTheProjectsViewOffersAddProject() {
    let app = launchedApp([
      "-WorkroomUITestNoProjects", "1", "-WorkroomUITestOnboarding", "hide",
    ])
    let newTerminal = element(app, "EmptyStateNewTerminal")
    XCTAssertTrue(newTerminal.waitForExistence(timeout: 15), "the empty state")
    newTerminal.click()
    app.showProjectsView()
    XCTAssertTrue(
      app.staticTexts["No projects yet"].waitForExistence(timeout: 6), "the Projects view says so")
    XCTAssertTrue(element(app, "sidebar.view.open").isHittable, "under the switcher")
    element(app, "sidebar.add").click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 6), "its + opens the New Project sheet")
    element(app, "addProject.cancelButton").click()
    XCTAssertTrue(waitGone(sheet))
  }
}
