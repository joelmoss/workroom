import XCTest

/// Popping a detail panel out into its own window and docking it back (issue #172).
///
/// Driven through the **Window menu item**, never a synthetic drag past the window edge: `WindowDragUITests` already documents that synthetic drags around the title-bar region do not
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
    app.menuBars.menuBarItems["Window"].menuItems["Move pane into new window"]
  }

  private func dockMenuItem(_ app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["Window"].menuItems["Move back to main window"]
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

  /// Poll the app-wide pane count, for the same reason `waitForWindowCount` polls windows: the origin
  /// re-lays out asynchronously after a pane leaves or returns. A fixed `Thread.sleep` is a bet on how
  /// long that takes — too short under load (false red), and on a fast machine it can read the count
  /// before the relayout lands (false green).
  private func waitForPaneCount(_ app: XCUIApplication, _ target: Int, timeout: TimeInterval = 6)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", target), object: terminalPanes(app))
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// The pane leaves the main window for one of its own. Asserted on the pane, not just the window —
  /// a second window containing nothing would pass a count check and fail the user.
  ///
  /// Docking back is deliberately NOT covered here: the detached window uses normal macOS chrome, so
  /// the gesture is dragging it by its native title bar, which XCUITest can drive no more reliably
  /// than the tear-off drag. The model half (`dockPane`, and which window ends up owning the surface)
  /// is covered by `DetachedPaneTests` and `PaneRenderingTests`; the gesture itself is manual QA.
  func testPaneDetachesToItsOwnWindow() throws {
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

    XCTAssertFalse(
      detached.descendants(matching: .any).matching(identifier: "terminal.pane.titlebar")
        .firstMatch.exists,
      "the pane drops its own title bar in there — the window's title bar names it instead")
  }

  /// The Window-menu item is ONE item that flips with key focus: pop out while the main window is
  /// key, move back while the detached one is. Worth an explicit test because the mechanism is not
  /// the usual one — a detached window is not a SwiftUI scene, so no `@FocusedValue` changes when it
  /// becomes key, and a `Commands` body would never re-evaluate without something else observed.
  func testTheMenuItemFlipsWithKeyFocus() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    XCTAssertTrue(popOutMenuItem(app).exists, "the main window offers the pop-out direction")

    popOutMenuItem(app).click()
    XCTAssertTrue(detachedWindow(app).waitForExistence(timeout: 5))
    detachedWindow(app).click()  // make the detached window key

    XCTAssertTrue(
      dockMenuItem(app).waitForExistence(timeout: 5),
      "with the detached window key, the same item becomes its inverse")
    XCTAssertFalse(
      popOutMenuItem(app).exists, "and only one direction is offered at a time")

    dockMenuItem(app).click()
    XCTAssertTrue(
      popOutMenuItem(app).waitForExistence(timeout: 5),
      "docking returns the menu to the pop-out direction")
  }

  /// The pane count is conserved: popping out MOVES the pane rather than cloning it, so the app-wide
  /// total is unchanged — it is simply in a different window.
  func testDetachingMovesThePaneRatherThanDuplicatingIt() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let panesBefore = terminalPanes(app).count

    popOutMenuItem(app).click()
    XCTAssertTrue(detachedWindow(app).waitForExistence(timeout: 5))

    XCTAssertTrue(
      waitForPaneCount(app, panesBefore),
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

    // The window's own close button, not a pane button: the pane has no chrome of its own in there.
    detached.buttons[XCUIIdentifierCloseWindow].click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore), "the window goes when its pane does")
    XCTAssertTrue(
      waitForPaneCount(app, panesBefore - 1),
      "and the pane is gone from the app entirely, not docked back")
  }
}
