import XCTest

/// The sidebar's Terminals and Projects sections are the inspector's panes (#652): each a sticky
/// heading over its own scrolling list, so scrolling one list keeps both headings where they are,
/// and collapsing one pane leaves the other's rows showing. Fixture only, never a real project or
/// config.
final class SidebarPanesUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The Quick Terminal's group row, always first in the Terminals section.
  private let quickTerminal = "sidebar.group.group:51C10A7E-0D4F-4E6A-9B2C-000000000001"

  /// Sixteen workrooms in a short window, so the Projects list is longer than its pane.
  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestWorkroomCount", "16",
      "-WorkroomUITestWindowFrame", "{{80, 80}, {1200, 620}}",
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

  private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
  }

  /// Polls until `condition` holds, for a frame that settles after a layout pass.
  private func eventually(_ timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return condition()
  }

  /// Scrolling the Projects list moves its rows and leaves both headings hittable, in place.
  func testScrollingTheProjectsListKeepsBothHeadingsInPlace() {
    let app = launchedApp()
    let terminals = element(app, "sidebar.terminals")
    let projects = element(app, "sidebar.projects")
    XCTAssertTrue(projects.waitForExistence(timeout: 15), "the Projects heading")
    XCTAssertTrue(terminals.exists, "the Terminals heading")
    let project = element(app, "sidebar.project.UITestProject")
    XCTAssertTrue(project.waitForExistence(timeout: 6), "the project's row")
    let terminalsFrame = terminals.frame
    let projectsFrame = projects.frame
    let projectY = project.frame.minY

    project.scroll(byDeltaX: 0, deltaY: -600)

    XCTAssertTrue(
      eventually { project.frame.minY < projectY - 50 }, "the Projects list scrolled its rows up")
    XCTAssertEqual(terminals.frame, terminalsFrame, "the Terminals heading stays put")
    XCTAssertEqual(projects.frame, projectsFrame, "the Projects heading stays put")
    XCTAssertTrue(terminals.isHittable, "the Terminals heading stays clickable")
    XCTAssertTrue(projects.isHittable, "the Projects heading stays clickable")
  }

  /// Collapsing the Terminals pane leaves the projects' rows showing, and collapsing the Projects
  /// pane leaves the Terminals rows showing.
  func testCollapsingOnePaneLeavesTheOthersRowsShowing() {
    let app = launchedApp()
    let terminals = element(app, "sidebar.terminals")
    let projects = element(app, "sidebar.projects")
    XCTAssertTrue(projects.waitForExistence(timeout: 15), "the Projects heading")
    let project = element(app, "sidebar.project.UITestProject")
    let quick = element(app, quickTerminal)
    XCTAssertTrue(project.waitForExistence(timeout: 6), "the project's row")
    XCTAssertTrue(quick.waitForExistence(timeout: 6), "the Quick Terminal's row")
    let projectsTop = projects.frame.minY

    terminals.click()
    XCTAssertTrue(waitGone(quick), "collapsed, the Terminals rows go")
    XCTAssertTrue(
      eventually { abs(projects.frame.minY - terminals.frame.maxY) < 2 },
      "the Projects pane moves up under the Terminals heading")
    XCTAssertLessThan(projects.frame.minY, projectsTop)
    XCTAssertTrue(project.isHittable, "the projects' rows still show")

    terminals.click()
    XCTAssertTrue(quick.waitForExistence(timeout: 6), "expanded, they come back")
    XCTAssertTrue(
      eventually { abs(projects.frame.minY - projectsTop) < 2 }, "where the pane was before")

    projects.click()
    XCTAssertTrue(waitGone(project), "collapsed, the projects' rows go")
    XCTAssertTrue(quick.isHittable, "the Terminals rows still show")
    projects.click()
    XCTAssertTrue(project.waitForExistence(timeout: 6), "expanded, they come back")
  }
}
