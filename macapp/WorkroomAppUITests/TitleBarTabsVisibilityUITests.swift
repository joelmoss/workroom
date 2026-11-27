import XCTest

/// "Show Tabs" (Settings ▸ Appearance ▸ "Show tabs in the title bar"), from the
/// title bar's right-click menus: off from a tab's own menu hides every title-bar tab and leaves the
/// open-workroom and new-workroom buttons; on from the empty bar's menu brings the tabs back, and a
/// control-click opens that menu as a right-click does. The
/// fixture launch turns the tabs on whatever an earlier run left, so this test starts from on.
final class TitleBarTabsVisibilityUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The title-bar tabs: `workroom.tab.<id>`, not their split brackets.
  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "workroom.tab.",
        "workroom.tab.splitBracket"))
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Chooses "Show Tabs" from the right-click menu that `rightClick` opens.
  private func chooseToggle(_ app: XCUIApplication, after rightClick: () -> Void) {
    rightClick()
    let item = app.menuItems["Show Tabs"]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "the right-click menu has the toggle")
    item.click()
  }

  private func waitForCount(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10) -> Bool
  {
    let p = NSPredicate(format: "count == %d", n)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: query)], timeout: timeout) == .completed
  }

  func testTitleBarRightClickHidesAndShowsTheTabs() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    addTeardownBlock { app.terminate() }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

    let tab = tabs(app).firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 15), "the fixture shows a tab")
    let shown = tabs(app).count

    chooseToggle(app) { tab.rightClick() }
    XCTAssertTrue(waitForCount(tabs(app), 0), "unchecking it on a tab hides every tab")
    let newWorkroom = element(app, "NewWorkroom")
    XCTAssertTrue(element(app, "OpenWorkroom").isHittable, "the open-workroom button stays")
    XCTAssertTrue(newWorkroom.isHittable, "the new-workroom button stays")

    // The empty bar past the buttons, where the tabs were.
    let emptyBar = newWorkroom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: 200, dy: 0))
    chooseToggle(app) { emptyBar.rightClick() }
    XCTAssertTrue(waitForCount(tabs(app), shown), "checking it on the bar brings every tab back")

    // A control-click is a right-click, on the bar as on a tab.
    chooseToggle(app) { XCUIElement.perform(withKeyModifiers: .control) { emptyBar.click() } }
    XCTAssertTrue(waitForCount(tabs(app), 0), "unchecking it by control-click hides them again")
  }
}
