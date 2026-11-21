import XCTest

/// Unnamed terminal groups in the real window (#659, ADR 0077): ⌘D on a standalone terminal turns
/// its row into a group's in the same place, and closing the new half turns it back; a standalone
/// terminal's row, or a workroom terminal's tab, dropped on a standalone terminal's row or
/// title-bar tab groups the two. Seeded by the fixture's `-WorkroomUITestStandaloneTerminals`,
/// never a real project or config.
final class UnnamedTerminalGroupUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The fixture's fixed ids (`UITestFixture.standaloneTerminalIDs`).
  private let seeded = [
    "standalone:00000000-0000-0000-0000-000000000651",
    "standalone:00000000-0000-0000-0000-000000000652",
  ]

  private func launchedApp(standalone: Int = 2) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "\(standalone)"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// The Quick Terminal's group (#661), always listed: never one of the groups made here.
  private let quickTerminal = "51C10A7E-0D4F-4E6A-9B2C-000000000001"

  /// Elements whose identifier starts with `prefix`, leaving out the Quick Terminal's.
  private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND NOT (identifier CONTAINS[c] %@)", prefix,
        quickTerminal))
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Waits for `query` to match `n` distinct identifiers: a List row's element can show up more
  /// than once in the tree, under the same identifier.
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

  func testCommandDTurnsAStandaloneRowIntoAGroupInPlaceAndClosingAHalfTurnsItBack() {
    let app = launchedApp()
    let first = element(app, "sidebar.standalone.\(seeded[0])")
    let second = element(app, "sidebar.standalone.\(seeded[1])")
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    first.click()

    app.typeKey("d", modifierFlags: .command)

    let groups = elements(app, prefix: "sidebar.group.group:")
    XCTAssertTrue(waitForRows(groups, 1), "the row becomes a group's")
    XCTAssertTrue(waitForRows(elements(app, prefix: "sidebar.standalone."), 1), "one is left")
    XCTAssertFalse(first.exists, "the split terminal's own row has gone")
    let group = groups.firstMatch
    XCTAssertLessThan(group.frame.minY, second.frame.minY, "in its place, above the other")
    XCTAssertTrue(
      waitForRows(elements(app, prefix: "workroom.tab.group:"), 1), "one title-bar tab for it")
    XCTAssertTrue(
      waitForRows(elements(app, prefix: "sidebar.terminal."), 2), "its two terminals under it")
    let label = [group.label, group.value as? String ?? ""].joined(separator: " ")
    XCTAssertTrue(label.contains(" + "), "labelled by its terminals' names: \(label)")

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForRows(groups, 0), "one terminal left: the group dissolves")
    XCTAssertTrue(
      waitForRows(elements(app, prefix: "sidebar.standalone."), 2), "back to two standalone rows")
    XCTAssertTrue(waitForRows(elements(app, prefix: "workroom.tab.standalone:"), 2))
  }

  /// Whether the one group's row is labelled by two terminals' names. Their own rows can't be
  /// counted: each is identified by its title, and both here are "Terminal 1".
  private func groupsTwoTerminals(_ app: XCUIApplication) -> Bool {
    let named = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", " + ", " + ")
    let row = elements(app, prefix: "sidebar.group.group:").firstMatch
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: named, object: row)], timeout: 6) == .completed
  }

  /// `click(forDuration:thenDragTo:)`, the mouse drag: on macOS 27 `press` posts no mouse events
  /// from an element, so nothing drags (#269).
  private func drag(_ from: XCUIElement, to: XCUIElement, dy: CGFloat = 0.5) {
    from.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: to.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy)))
  }

  /// A standalone terminal's row let go over the middle of another's makes a group of the two in
  /// the destination's place; let go at another's edge, it only reorders.
  func testDroppingAStandaloneRowOnAnotherGroupsThemAndAtItsEdgeReorders() {
    let app = launchedApp(standalone: 3)
    let rows = seeded + ["standalone:00000000-0000-0000-0000-000000000653"]
    let first = element(app, "sidebar.standalone.\(rows[0])")
    let second = element(app, "sidebar.standalone.\(rows[1])")
    let third = element(app, "sidebar.standalone.\(rows[2])")
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    XCTAssertTrue(third.waitForExistence(timeout: 5))

    // At the top edge of the first: the third goes above it, and nothing groups.
    drag(third, to: first, dy: 0.1)
    let reordered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in third.frame.minY < first.frame.minY }, object: nil)
    XCTAssertEqual(XCTWaiter().wait(for: [reordered], timeout: 6), .completed, "it reorders")
    let groups = elements(app, prefix: "sidebar.group.group:")
    XCTAssertTrue(waitForRows(groups, 0, timeout: 1), "and groups nothing")

    // Over the middle of the first: the second joins it in a group.
    drag(second, to: first)
    XCTAssertTrue(waitForRows(groups, 1), "the two become a group")
    XCTAssertTrue(
      waitForRows(elements(app, prefix: "sidebar.standalone."), 1), "the third is left alone")
    XCTAssertTrue(groupsTwoTerminals(app), "of the two terminals")
    XCTAssertLessThan(third.frame.minY, groups.firstMatch.frame.minY, "in the first's place")
  }

  /// A workroom terminal's tab let go on a standalone terminal's row groups the two.
  func testATabDroppedOnAStandaloneRowGroupsThem() {
    let app = launchedApp(standalone: 1)
    let row = element(app, "sidebar.standalone.\(seeded[0])")
    let chip = element(app, "terminal.tab.Terminal 1")
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the fixture workroom's terminal tab")
    XCTAssertTrue(row.waitForExistence(timeout: 5))

    drag(chip, to: row)

    XCTAssertTrue(waitForRows(elements(app, prefix: "sidebar.group.group:"), 1), "a group")
    XCTAssertTrue(waitForRows(elements(app, prefix: "sidebar.standalone."), 0))
    XCTAssertTrue(groupsTwoTerminals(app), "of the two terminals")
  }

  /// A workroom terminal's tab let go on a standalone terminal's title-bar tab groups the two.
  func testATabDroppedOnAStandaloneTitleBarTabGroupsThem() {
    let app = launchedApp(standalone: 1)
    let tab = element(app, "workroom.tab.\(seeded[0])")
    let chip = element(app, "terminal.tab.Terminal 1")
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the fixture workroom's terminal tab")
    XCTAssertTrue(tab.waitForExistence(timeout: 5))

    drag(chip, to: tab)

    XCTAssertTrue(waitForRows(elements(app, prefix: "workroom.tab.group:"), 1), "a group's tab")
    XCTAssertTrue(waitForRows(elements(app, prefix: "workroom.tab.standalone:"), 0))
    XCTAssertTrue(groupsTwoTerminals(app), "of the two terminals")
  }
}
