import XCTest

/// The ⌘O Open Workroom picker (issue #94), which had no UI coverage until issue #163 added a
/// modifier to its pick. Both tests here exist because the behaviour lives in AppKit's key
/// routing, not in the store: whether ⌥⏎ survives the focused search field's field editor, and
/// whether a plain ⏎ still does what it always did.
///
/// Run scoped — `xcodebuild … -only-testing:WorkroomAppUITests/OpenWorkroomDialogUITests`.
final class OpenWorkroomDialogUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // A SECOND workroom (`uitest-room-2`) for the picker to open — the default fixture seeds one.
    app.launchArguments += ["-WorkroomUITestWorkroomCount", "2"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  private func titlebars(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "workroom.pane.titlebar")
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 6) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Waits for the fixture workroom's pane, then raises the Open picker and returns the row for
  /// the OTHER workroom (the one a pick would open).
  private func openPickerRow(_ app: XCUIApplication) throws -> XCUIElement {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 10))
    assertCount(titlebars(app), reaches: 1)
    app.typeKey("o", modifierFlags: .command)
    let row = app.descendants(matching: .any)
      .matching(identifier: "openWorkroom.target.uitest-room-2").firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 6), "the picker should list the other workroom")
    return row
  }

  /// REGRESSION GUARD: issue #163 rewrote this dialog's return handler (to the `keys:` overload,
  /// which carries modifiers) and added a modifier read to its tap gesture. A plain ⏎ must still
  /// REPLACE the current workroom — one pane, not two.
  func testPlainReturnStillReplaces() throws {
    let app = launchedApp()
    _ = try openPickerRow(app)
    app.typeKey(.return, modifierFlags: [])
    assertCount(titlebars(app), reaches: 1)
  }

  /// ⌥⏎ opens the highlighted row as a split instead. This is also the empirical answer to whether
  /// AppKit's `insertNewlineIgnoringFieldEditor:` binding swallows ⌥⏎ before SwiftUI sees it — if
  /// this fails while `testPlainReturnStillReplaces` passes, change `PickerSplitIntent.modifier`.
  func testOptionReturnSplitsFromThePicker() throws {
    let app = launchedApp()
    _ = try openPickerRow(app)
    app.typeKey(.return, modifierFlags: .option)
    assertCount(titlebars(app), reaches: 2)
  }
}
