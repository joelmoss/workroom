import XCTest

/// A named terminal group in the real window (#658, ADR 0077): its row in the Terminals section,
/// its terminals' rows under it, which fold away, and its one title-bar tab. Seeded by the fixture's
/// `-WorkroomUITestTerminalGroup`, never a real project or config.
final class TerminalGroupUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The fixture's fixed group (`UITestFixture.terminalGroupID`).
  private let group = "group:00000000-0000-0000-0000-000000000658"

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalGroup", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", prefix))
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Waits for `query` to match `n` distinct rows: a List row's element shows up more than once in
  /// the tree, under the same identifier, and a terminal's row is identified by its title.
  private func waitForRows(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Set(query.allElementsBoundByIndex.map(\.identifier)).count == n { return true }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return false
  }

  func testAGroupHasARowThatFoldsItsTerminalsAndOneTitleBarTab() {
    let app = launchedApp()

    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "the group's row")
    let tab = element(app, "workroom.tab.\(group)")
    XCTAssertTrue(tab.waitForExistence(timeout: 5), "its one title-bar tab")
    XCTAssertEqual(elements(app, prefix: "workroom.tab.\(group)").count, 1)
    let spoken = [tab.label, tab.title, tab.value as? String ?? ""]
    XCTAssertTrue(spoken.contains { $0.contains("Ops") }, "named for the group: \(spoken)")
    XCTAssertTrue(
      element(app, "sidebar.group.new.\(group)").exists, "New Terminal in Group on its row")

    // Unfolded, the row lists the group's two terminals; folded, none.
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForRows(terminals, 2), "its terminals under it")
    element(app, "sidebar.group.fold.\(group)").click()
    XCTAssertTrue(waitForRows(terminals, 0), "folding hides them")
    XCTAssertTrue(row.exists, "and keeps the row")
    element(app, "sidebar.group.fold.\(group)").click()
    XCTAssertTrue(waitForRows(terminals, 2), "unfolding shows them again")

    // Clicking its title-bar tab shows the group: ⌘T then opens a third terminal in it.
    tab.click()
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(waitForRows(terminals, 3), "⌘T opens a terminal in the group")
  }

  /// Rename… on the group's row edits its name in place; Return keeps it, on the row and the
  /// title-bar tab.
  func testRenameEditsTheGroupsNameInPlace() {
    let app = launchedApp()
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))

    row.rightClick()
    let rename = app.waitForHittableMenuItem(titled: "Rename…")
    XCTAssertNotNil(rename, "the group's menu offers Rename…")
    rename?.click()
    let field = element(app, "sidebar.group.rename.\(group)")
    XCTAssertTrue(field.waitForExistence(timeout: 6), "an inline name field")
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Servers\r")

    // The tab is a StaticText, whose name arrives as its `value`, not its `label`; the row is a
    // button, named by its label. Accept either on both rather than depend on which.
    let named = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Servers", "Servers")
    let tab = element(app, "workroom.tab.\(group)")
    let renamed = [
      XCTNSPredicateExpectation(predicate: named, object: tab),
      XCTNSPredicateExpectation(predicate: named, object: row),
    ]
    XCTAssertEqual(
      XCTWaiter().wait(for: renamed, timeout: 6), .completed,
      "tab: \(tab.label) / \(tab.value ?? "-"); row: \(row.label) / \(row.value ?? "-")")
    XCTAssertFalse(field.exists, "the field closes")
  }

  /// Dragging a row within the Terminals section reorders it.
  func testDraggingARowReordersTheSection() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalGroup", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    let standalone = element(
      app, "sidebar.standalone.standalone:00000000-0000-0000-0000-000000000651")
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(standalone.waitForExistence(timeout: 5))
    XCTAssertLessThan(standalone.frame.minY, row.frame.minY, "seeded above the group")

    // `click(forDuration:thenDragTo:)`, the mouse drag: on macOS 27 `press` posts no mouse
    // events from an element, so nothing drags (#269).
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: standalone.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)))

    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in row.frame.minY < standalone.frame.minY }, object: nil)
    XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 6), .completed, "the group is first")
  }
}
