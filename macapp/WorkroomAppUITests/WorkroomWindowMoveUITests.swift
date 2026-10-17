import XCTest

/// Moving a workroom into a window of its own (issue #444).
///
/// Driven through the Window menu item, not a drag past the window edge, for the reason
/// `DetachedPaneUITests` gives: synthetic drags around the title bar do not behave like a real mouse
/// here. Where a drag lands is pure logic and covered by `WorkroomHandOverTests`; what this proves is
/// the part only the real app can show, that a second window appears holding the workroom with its
/// terminal still mounted, and that the first window no longer has it.
final class WorkroomWindowMoveUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestTwoTabs", "1"]
    app.launch()
    app.activate()
    return app
  }

  private func chips(in element: XCUIElement) -> XCUIElementQuery {
    element.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'workroom.tab.'"))
  }

  private func waitForCount(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", n), object: query)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  func testMovingAWorkroomGivesItAWindowOfItsOwnWithItsTerminal() {
    let app = launchedApp()
    XCTAssertTrue(waitForCount(chips(in: app), 2), "the fixture opens two workrooms")
    let windowsBefore = app.windows.count
    let selected = chips(in: app).matching(NSPredicate(format: "selected == true")).firstMatch
    XCTAssertTrue(selected.waitForExistence(timeout: 5))
    let movedID = selected.identifier

    let item = app.menuBars.menuBarItems["Window"].menuItems["Move workroom into new window"]
    XCTAssertTrue(item.isEnabled, "a window's second workroom can move")
    item.click()

    XCTAssertTrue(
      waitForCount(app.windows, windowsBefore + 1), "moving the workroom opens one window")
    let moved = chips(in: app).matching(NSPredicate(format: "identifier == %@", movedID))
    XCTAssertTrue(waitForCount(moved, 1), "the workroom is in one window, not cloned")
    XCTAssertTrue(waitForCount(chips(in: app), 2), "and nothing else was opened or closed")
    // Per window rather than through the launch window's element: an `XCUIElement` resolves its
    // query when used, and `windows.firstMatch` is the frontmost window by then, the new one.
    for index in 0..<app.windows.count {
      XCTAssertEqual(
        chips(in: app.windows.element(boundBy: index)).count, 1,
        "each window holds one workroom: the moved one left the first window")
    }
    // A surface is in the accessibility tree only while it is mounted in a window, so this is the
    // check that the moved terminal is showing, not a blank pane.
    let surfaces = app.descendants(matching: .any).matching(identifier: "terminal.surface")
    XCTAssertTrue(
      waitForCount(surfaces, 2),
      "both workrooms show a live terminal, one in each window")

    // The new window now holds one workroom; moving it on would just give it the same window.
    let only = app.menuBars.menuBarItems["Window"].menuItems["Move workroom into new window"]
    XCTAssertFalse(only.isEnabled, "a window's only workroom does not move from the menu")
  }
}
