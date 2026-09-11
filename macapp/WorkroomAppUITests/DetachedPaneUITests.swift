import XCTest

/// Popping a detail panel out into its own window and docking it back (issue #172).
///
/// Driven through the **menu item and the title-bar buttons**, never a synthetic drag past the window
/// edge: `WindowDragUITests` already documents that synthetic drags around the title-bar region do not
/// behave like a real mouse here, and this app has a history of real-mouse-only bugs. The tear-off
/// drag's *decision* is covered instead by `PaneDragOutcomeTests` (pure geometry, all four edges); what
/// these tests prove is the part geometry cannot — that a second window really appears, really contains
/// the pane, and really goes away again.
///
/// Window counts settle asynchronously, so every assertion is a DELTA against the launch window,
/// never an absolute count.
final class DetachedPaneUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  private func terminalPanes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func detachedWindow(_ app: XCUIApplication) -> XCUIElement {
    app.windows["detachedPane.window"]
  }

  private func popOutMenuItem(_ app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["Window"].menuItems["Open Pane in New Window"]
  }

  private func waitForLaunchWindow(_ app: XCUIApplication) {
    XCTAssertTrue(
      terminalPanes(app).firstMatch.waitForExistence(timeout: 15),
      "fixture launch window (with its terminal) should appear")
  }

  private func waitForWindowCount(_ app: XCUIApplication, _ target: Int, timeout: TimeInterval = 6)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", target), object: app.windows)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// The whole feature in one pass: the pane leaves the main window for one of its own, and the Dock
  /// button brings it back. Asserted on the pane, not just the window — a second window containing
  /// nothing would pass a count check and fail the user.
  func testPaneDetachesToItsOwnWindowAndDocksBack() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let windowsBefore = app.windows.count

    popOutMenuItem(app).click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore + 1),
      "popping a pane out should add exactly one window (had \(windowsBefore))")
    let detached = detachedWindow(app)
    XCTAssertTrue(
      detached.waitForExistence(timeout: 5), "the detached window should be identifiable")
    XCTAssertTrue(
      detached.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 5),
      "and it should actually contain the pane, not just be an empty window")

    detached.descendants(matching: .any).matching(identifier: "pane.toolbar.dock").firstMatch
      .click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore),
      "docking should close the detached window again")
  }

  /// The pane count is conserved: popping out MOVES the pane rather than cloning it, so the app-wide
  /// total is unchanged — it is simply in a different window.
  func testDetachingMovesThePaneRatherThanDuplicatingIt() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let panesBefore = terminalPanes(app).count

    popOutMenuItem(app).click()
    XCTAssertTrue(detachedWindow(app).waitForExistence(timeout: 5))
    // Let the origin settle after losing the pane.
    Thread.sleep(forTimeInterval: 1.0)

    XCTAssertEqual(
      terminalPanes(app).count, panesBefore,
      "the pane moved windows; nothing was created or destroyed")
  }

  /// Closing the detached window closes the PANE, Chrome/VS Code style — the asymmetry most likely to
  /// be "fixed" into a bug later, so it is pinned here.
  func testClosingTheDetachedWindowClosesThePane() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let windowsBefore = app.windows.count
    let panesBefore = terminalPanes(app).count

    popOutMenuItem(app).click()
    let detached = detachedWindow(app)
    XCTAssertTrue(detached.waitForExistence(timeout: 5))

    detached.descendants(matching: .any).matching(identifier: "pane.toolbar.close").firstMatch
      .click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore), "the window goes when its pane does")
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      terminalPanes(app).count, panesBefore - 1,
      "and the pane is gone from the app entirely, not docked back")
  }
}
