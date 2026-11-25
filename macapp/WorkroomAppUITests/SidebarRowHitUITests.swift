import XCTest

/// A Terminals-section row is one hit target from its top edge to its bottom edge (#652 critique):
/// its spacing is padding inside the row, not a List inset outside it, so a click near either edge
/// selects the row as a click on its middle does. Seeded by the fixture's standalone terminals and
/// its "Ops" group, never a real project or config.
final class SidebarRowHitUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = true }

  /// The fixture's fixed ids (`UITestFixture.standaloneTerminalIDs`, `terminalGroupID`).
  private let standalone = [
    "standalone:00000000-0000-0000-0000-000000000651",
    "standalone:00000000-0000-0000-0000-000000000652",
  ]
  private let group = "group:00000000-0000-0000-0000-000000000658"

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "2"]
    app.launchArguments += ["-WorkroomUITestTerminalGroup", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// The group's terminals' rows, top to bottom, one element per row (a List row's element can
  /// show up more than once in the tree).
  private func groupTerminalRows(_ app: XCUIApplication) -> [XCUIElement] {
    let deadline = Date().addingTimeInterval(10)
    repeat {
      var seen = Set<String>()
      let rows = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.open.tab."))
        .allElementsBoundByIndex.filter { seen.insert($0.identifier).inserted }
      if rows.count == 2 { return rows.sorted { $0.frame.minY < $1.frame.minY } }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return []
  }

  /// Waits for `tab`, a title-bar tab, to be the selected one: what selecting its row shows. (A
  /// standalone terminal has no pane header to read, #652.)
  private func waitForSelected(_ tab: XCUIElement, _ message: String) {
    let selected = NSPredicate(format: "selected == true")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: selected, object: tab)], timeout: 6),
      .completed, "\(message): \(tab.identifier) is not selected")
  }

  /// Clicks `row` at `y` (0 its top edge, 1 its bottom edge), from another target's selection, and
  /// checks the click selected `row`'s target (`want`, its title-bar tab).
  private func click(
    _ row: XCUIElement, at y: CGFloat, from other: XCUIElement, want: XCUIElement,
    _ message: String
  ) {
    other.click()
    waitForSelected(other, "\(message): starts elsewhere")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).click()
    waitForSelected(want, message)
  }

  func testATerminalRowSelectsFromItsTopEdgeToItsBottomEdge() {
    let app = launchedApp()
    let first = element(app, "sidebar.open.workroom.\(standalone[0])")
    let second = element(app, "sidebar.open.workroom.\(standalone[1])")
    XCTAssertTrue(first.waitForExistence(timeout: 15), "the first standalone terminal's row")
    XCTAssertTrue(second.waitForExistence(timeout: 5), "the second's")
    let children = groupTerminalRows(app)
    XCTAssertEqual(children.count, 2, "the group's two terminals' rows")
    guard children.count == 2 else { return }

    // Each row's frame is its whole pitch: it ends where the row below begins, with no band
    // between them that belongs to neither.
    XCTAssertEqual(
      first.frame.maxY, second.frame.minY, accuracy: 0.5,
      "standalone rows: \(first.frame) then \(second.frame)")
    XCTAssertEqual(
      children[0].frame.maxY, children[1].frame.minY, accuracy: 0.5,
      "a group's terminals' rows: \(children[0].frame) then \(children[1].frame)")
    // And it spans the sidebar's width, as its highlight does.
    XCTAssertEqual(
      first.frame.width, children[0].frame.width, accuracy: 0.5,
      "standalone \(first.frame), group terminal \(children[0].frame)")

    // Each click starts from another target's selection, so it is the click that selects.
    let groupTab = element(app, "workroom.tab.\(group)")
    for y in [0.05, 0.95] {
      for (index, row) in [first, second].enumerated() {
        let tab = element(app, "workroom.tab.\(standalone[index])")
        click(row, at: y, from: groupTab, want: tab, "standalone row at \(y)")
      }
      let standaloneTab = element(app, "workroom.tab.\(standalone[0])")
      for child in children {
        click(child, at: y, from: standaloneTab, want: groupTab, "group terminal row at \(y)")
      }
    }
  }
}
