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

  /// One launch, one ordered chain (each original test used to cost its own app launch):
  ///
  /// 1. The pane leaves the main window for one of its own. Asserted on the pane, not just the window —
  ///    a second window containing nothing would pass a count check and fail the user.
  /// 2. The pane count is conserved: popping out MOVES the pane rather than cloning it, so the
  ///    app-wide total is unchanged — it is simply in a different window.
  /// 3. The Window-menu item is ONE item that flips with key focus: pop out while the main window is
  ///    key, move back while the detached one is. Worth an explicit check because the mechanism is
  ///    not the usual one — a detached window is not a SwiftUI scene, so no `@FocusedValue` changes
  ///    when it becomes key, and a `Commands` body would never re-evaluate without something else
  ///    observed. Docking via the item returns the app to its launch state.
  /// 4. Pop out AGAIN (from the docked state) and close the detached window: closing it closes the
  ///    PANE, Chrome/VS Code style — the asymmetry most likely to be "fixed" into a bug later, so it
  ///    is pinned here. Last, because it destroys the pane.
  ///
  /// Docking back by gesture is deliberately NOT covered here: the detached window uses normal macOS
  /// chrome, so the gesture is dragging it by its native title bar, which XCUITest can drive no more
  /// reliably than the tear-off drag. The model half (`dockPane`, and which window ends up owning the
  /// surface) is covered by `DetachedPaneTests` and `PaneRenderingTests`; the gesture itself is
  /// manual QA.
  func testPaneDetachesMovesFlipsTheMenuDocksAndClosesWithItsWindow() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let windowsBefore = app.windows.count
    let panesBefore = terminalPanes(app).count
    XCTAssertFalse(
      detachedWindow(app).exists, "nothing is detached at launch, so the later checks start clean")
    XCTAssertTrue(popOutMenuItem(app).exists, "the main window offers the pop-out direction")

    // 1. Pop out.
    popOutMenuItem(app).click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore + 1),
      "popping a pane out should add exactly one window (had \(windowsBefore))")
    let detached = detachedWindow(app)
    XCTAssertTrue(
      detached.waitForExistence(timeout: 5), "the detached window should be identifiable")
    XCTAssertFalse(detached.descendants(matching: .any)["window.footer"].exists)
    XCTAssertTrue(
      detached.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 5),
      "and it should actually contain the pane, not just be an empty window")

    XCTAssertFalse(
      detached.descendants(matching: .any).matching(identifier: "terminal.pane.titlebar")
        .firstMatch.exists,
      "the pane drops its own title bar in there — the window's title bar names it instead")

    // 2. The pane moved, nothing was cloned.
    XCTAssertTrue(
      waitForPaneCount(app, panesBefore),
      "the pane moved windows; nothing was created or destroyed")

    // 3. The menu item flips with key focus, then docking restores the launch state.
    detached.click()  // make the detached window key
    XCTAssertTrue(
      dockMenuItem(app).waitForExistence(timeout: 5),
      "with the detached window key, the same item becomes its inverse")
    XCTAssertFalse(
      popOutMenuItem(app).exists, "and only one direction is offered at a time")

    dockMenuItem(app).click()
    XCTAssertTrue(
      popOutMenuItem(app).waitForExistence(timeout: 5),
      "docking returns the menu to the pop-out direction")
    // The first detached window must be fully gone before popping out again: otherwise
    // `detachedWindow(app)` would match the old, closing window and the close assertions below would
    // pass against it.
    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore), "docking removes the detached window")
    XCTAssertTrue(
      detachedWindow(app).waitForNonExistence(timeout: 5),
      "the first detached window is gone before the pane is popped out again")
    XCTAssertTrue(
      waitForPaneCount(app, panesBefore), "the docked pane is back in the main window")

    // 4. Pop out again and close the detached window: the pane goes with it.
    popOutMenuItem(app).click()
    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore + 1),
      "popping the pane out a second time adds one window again")
    let redetached = detachedWindow(app)
    XCTAssertTrue(
      redetached.waitForExistence(timeout: 5), "the second detached window should be identifiable")

    // The window's own close button, not a pane button: the pane has no chrome of its own in there.
    redetached.buttons[XCUIIdentifierCloseWindow].click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore), "the window goes when its pane does")
    XCTAssertTrue(
      waitForPaneCount(app, panesBefore - 1),
      "and the pane is gone from the app entirely, not docked back")
  }
}
