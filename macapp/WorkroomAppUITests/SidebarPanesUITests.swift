import XCTest

/// The sidebar's Open and Projects sections are the inspector's panes (#652): each a sticky
/// heading over its own scrolling list, so scrolling one list keeps both headings where they are,
/// and collapsing one pane leaves the other's rows showing. Fixture only, never a real project or
/// config.
final class SidebarPanesUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The Open section's first workroom row (the fixture's workroom tab).
  private func openRow(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.open.workroom.")
    ).firstMatch
  }

  /// Sixteen workrooms (the fixture's most) in a short window, so the Projects list runs several
  /// rows past its pane. The window fits a 1024×768 screen, so its size, not the screen's, sets that.
  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestWorkroomCount", "16",
      "-WorkroomUITestWindowFrame", "{{40, 40}, {1000, 520}}",
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
  ///
  /// Measured by which rows show, not by how far one moved: a row scrolled out of the list leaves
  /// the accessibility tree, so its frame says nothing once it has gone.
  func testScrollingTheProjectsListKeepsBothHeadingsInPlace() {
    let app = launchedApp()
    let terminals = element(app, "sidebar.open")
    let projects = element(app, "sidebar.projects")
    XCTAssertTrue(projects.waitForExistence(timeout: 15), "the Projects heading")
    XCTAssertTrue(terminals.exists, "the Open heading")
    let project = element(app, "sidebar.project.UITestProject")
    let lastRow = element(app, "sidebar.workroom.uitest-room-16")
    XCTAssertTrue(project.waitForExistence(timeout: 6), "the project's row")
    XCTAssertTrue(project.isHittable, "the list starts at the top, with the project's row showing")
    XCTAssertFalse(
      lastRow.exists && lastRow.isHittable, "the list runs past its pane, hiding the last row")
    let terminalsFrame = terminals.frame
    let projectsFrame = projects.frame

    project.scroll(byDeltaX: 0, deltaY: -600)

    XCTAssertTrue(
      eventually {
        lastRow.exists && lastRow.isHittable && !(project.exists && project.isHittable)
      },
      "the Projects list scrolled its rows up: the last row in, the project's row out")
    XCTAssertEqual(terminals.frame, terminalsFrame, "the Open heading stays put")
    XCTAssertEqual(projects.frame, projectsFrame, "the Projects heading stays put")
    XCTAssertTrue(terminals.isHittable, "the Open heading stays clickable")
    XCTAssertTrue(projects.isHittable, "the Projects heading stays clickable")
  }

  /// Collapsing the Open pane leaves the projects' rows showing, and collapsing the Projects
  /// pane leaves the Open rows showing.
  func testCollapsingOnePaneLeavesTheOthersRowsShowing() {
    let app = launchedApp()
    let terminals = element(app, "sidebar.open")
    let projects = element(app, "sidebar.projects")
    XCTAssertTrue(projects.waitForExistence(timeout: 15), "the Projects heading")
    let project = element(app, "sidebar.project.UITestProject")
    let quick = openRow(app)
    XCTAssertTrue(project.waitForExistence(timeout: 6), "the project's row")
    XCTAssertTrue(quick.waitForExistence(timeout: 6), "the Open section's workroom row")
    let projectsTop = projects.frame.minY

    terminals.click()
    XCTAssertTrue(waitGone(quick), "collapsed, the Open rows go")
    XCTAssertTrue(
      eventually { abs(projects.frame.minY - terminals.frame.maxY) < 2 },
      "the Projects pane moves up under the Open heading")
    XCTAssertLessThan(projects.frame.minY, projectsTop)
    XCTAssertTrue(project.isHittable, "the projects' rows still show")

    terminals.click()
    XCTAssertTrue(quick.waitForExistence(timeout: 6), "expanded, they come back")
    XCTAssertTrue(
      eventually { abs(projects.frame.minY - projectsTop) < 2 }, "where the pane was before")

    projects.click()
    XCTAssertTrue(waitGone(project), "collapsed, the projects' rows go")
    XCTAssertTrue(quick.isHittable, "the Open rows still show")
    projects.click()
    XCTAssertTrue(project.waitForExistence(timeout: 6), "expanded, they come back")
  }
}
