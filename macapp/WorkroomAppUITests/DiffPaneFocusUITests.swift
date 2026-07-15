import XCTest

/// Click-to-focus across a mixed split (a diff pane + a terminal pane). Regression guard for: with a
/// diff pane focused, clicking the sibling terminal pane wouldn't focus it.
///
/// Why this can only be a UI test: the defect lives at the AppKit first-responder layer. Focusing a
/// diff pane is pure SwiftUI and claims no responder, so the terminal surface stayed the window's
/// first responder while the diff was logically focused. A later `makeFirstResponder(self)` on the
/// terminal then short-circuited (already first responder) — `becomeFirstResponder`/`onFocused` never
/// fired, so the click couldn't refocus the terminal. The model's focus state was never wrong; only
/// the responder chain was, which a real window exercises. The fix resigns the terminal's first
/// responder when it stops being the focused pane.
///
/// Driven through the real app in UI-test fixture mode (canned jj diffs, suppressed close/quit
/// confirmations). Run with `make app-uitest` on a GUI login session.
final class DiffPaneFocusUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// All rendered panes (one `terminal.pane` a11y element per leaf — diff panes included).
  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  /// The diff pane (its a11y label is the file basename — terminal panes are prefixed "Terminal ").
  private func diffPane(_ app: XCUIApplication, _ basename: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "terminal.pane", basename)
      )
      .firstMatch
  }

  /// The terminal pane (a11y label begins "Terminal ").
  private func terminalPane(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ AND label BEGINSWITH %@", "terminal.pane", "Terminal ")
      )
      .firstMatch
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 6) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "pane count did not reach \(n) within \(timeout)s")
  }

  @discardableResult
  private func waitSelected(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "isSelected == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// Open a diff (working-copy file), form a mixed split by dragging the launch terminal's tab chip
  /// into the diff pane, focus the diff pane by clicking it, then click the terminal pane — it must
  /// become the focused (selected) pane. (Splitting a diff now opens another diff pane, #72, so a
  /// mixed diff+terminal split is built by drag-into-pane rather than ⌘D.)
  func testClickingTerminalPaneFocusesItWhenDiffPaneIsFocused() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "the Changes panel should render so a diff can be opened")

    // Open a persisted diff tab (double-click skips preview so it survives).
    let row = element(app, id: "changes.file.app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "a working-copy file row should render")
    row.doubleClick()
    XCTAssertTrue(
      element(app, id: "terminal.tab.user.rb").waitForExistence(timeout: 6),
      "a diff tab should open for the clicked file")
    assertCount(panes(app), reaches: 1)  // the diff is shown solo

    // Build a mixed split: drag the launch terminal's chip down into the diff pane (drop-into-pane,
    // issue #3) so the terminal and the diff become side-by-side panes.
    let termChip = element(app, id: "terminal.tab.Terminal 1")
    XCTAssertTrue(termChip.waitForExistence(timeout: 6), "the launch terminal's tab chip")
    let diff = diffPane(app, "user.rb")
    XCTAssertTrue(diff.waitForExistence(timeout: 6), "the diff pane should render solo first")
    termChip.press(forDuration: 0.4, thenDragTo: diff)
    assertCount(panes(app), reaches: 2)

    let terminal = terminalPane(app)
    XCTAssertTrue(diff.waitForExistence(timeout: 6), "the diff pane should render in the split")
    XCTAssertTrue(
      terminal.waitForExistence(timeout: 6), "the terminal pane should render in the split")

    // Focus the diff pane by clicking its body (exercises diff click-to-focus too).
    diff.click()
    XCTAssertTrue(waitSelected(diff, true), "clicking the diff pane body should focus it")

    // The regression: with the diff focused, clicking the terminal pane must focus the terminal.
    terminal.click()
    XCTAssertTrue(
      waitSelected(terminal, true),
      "clicking the terminal pane should focus it even when a diff pane was focused")
    XCTAssertTrue(waitSelected(diff, false), "focus should move off the diff pane")
  }
}
