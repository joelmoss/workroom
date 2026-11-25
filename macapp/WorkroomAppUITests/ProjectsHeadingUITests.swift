import XCTest

/// The sidebar's Projects heading (#652): "Projects" under the Open section, a fold chevron
/// that hides every project's rows, and Add Project in the trailing "+" column, shown with no
/// projects too. Fixture only, never a real project or config.
final class ProjectsHeadingUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(noProjects: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if noProjects {
      app.launchArguments += [
        "-WorkroomUITestNoProjects", "1", "-WorkroomUITestOnboarding", "hide",
      ]
    }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    addTeardownBlock { app.terminate() }
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
  }

  /// Its "+" opens the New Project sheet, which Cancel closes.
  private func assertAddProjectOpensTheSheet(_ app: XCUIApplication) {
    let add = element(app, "AddProject")
    XCTAssertTrue(add.waitForExistence(timeout: 6), "Add Project on the heading")
    add.click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 6), "the New Project sheet opens")
    element(app, "addProject.cancelButton").click()
    XCTAssertTrue(waitGone(sheet), "Cancel closes it")
  }

  /// The heading sits below the Open heading; its chevron hides the project rows and shows
  /// them again.
  func testTheHeadingFoldsTheProjects() {
    let app = launchedApp()
    let heading = element(app, "sidebar.projects")
    XCTAssertTrue(heading.waitForExistence(timeout: 15), "the Projects heading")
    let terminals = element(app, "sidebar.open")
    XCTAssertTrue(terminals.exists)
    let project = element(app, "sidebar.project.UITestProject")
    XCTAssertTrue(project.waitForExistence(timeout: 6), "a project's row")
    XCTAssertLessThan(terminals.frame.minY, heading.frame.minY, "under the Open section")
    XCTAssertLessThan(heading.frame.maxY, project.frame.minY + 1, "above the projects")
    XCTAssertEqual(
      heading.frame.height, terminals.frame.height, accuracy: 0.5, "as tall as Open's")
    XCTAssertEqual(heading.frame.minX, terminals.frame.minX, accuracy: 0.5, "and as inset")

    heading.click()
    XCTAssertTrue(waitGone(project), "folded, the projects' rows go")
    XCTAssertTrue(heading.exists, "the heading stays")
    heading.click()
    XCTAssertTrue(project.waitForExistence(timeout: 6), "unfolded, they come back")
  }

  /// The Open and Projects headings are the inspector's section headers: as tall as Changes',
  /// and reaching the sidebar's leading edge, past the rows' inset, as the band does.
  func testTheHeadingsLookLikeTheInspectorsSectionHeaders() {
    let app = launchedApp()
    let heading = element(app, "sidebar.projects")
    XCTAssertTrue(heading.waitForExistence(timeout: 15), "the Projects heading")
    let terminals = element(app, "sidebar.open")
    let changes = element(app, "inspector.header.Changes")
    XCTAssertTrue(changes.waitForExistence(timeout: 10), "the inspector's Changes header")
    let project = element(app, "sidebar.project.UITestProject")
    XCTAssertTrue(project.waitForExistence(timeout: 6), "a project's row")
    for h in [heading, terminals] {
      XCTAssertEqual(
        h.frame.height, changes.frame.height, accuracy: 0.5, "\(h.identifier) as tall as Changes")
      XCTAssertLessThan(
        h.frame.minX, project.frame.minX, "\(h.identifier) spans past the rows' inset")
    }
  }

  func testTheHeadingsPlusOpensAddProject() {
    let app = launchedApp()
    XCTAssertTrue(element(app, "sidebar.projects").waitForExistence(timeout: 15))
    assertAddProjectOpensTheSheet(app)
  }

  /// With no projects, once a terminal shows the sidebar, the heading is there and its "+" is how
  /// to add one. (With nothing at all the sidebar stays hidden and the empty state offers Add
  /// Project itself.)
  func testWithNoProjectsTheHeadingShowsAndAddsAProject() {
    let app = launchedApp(noProjects: true)
    let newTerminal = element(app, "EmptyStateNewTerminal")
    XCTAssertTrue(newTerminal.waitForExistence(timeout: 15), "the empty state")
    newTerminal.click()
    let heading = element(app, "sidebar.projects")
    XCTAssertTrue(heading.waitForExistence(timeout: 10), "the Projects heading, with no projects")
    assertAddProjectOpensTheSheet(app)
  }
}
