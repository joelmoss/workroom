import XCTest

/// End-to-end coverage for back/forward across *content* panes — the one thing the store-level tests
/// cannot show, because the reported bug was about what the DETAIL PANE displays.
///
/// Asserts `terminal.statusBar.path` (the pane's own file footer, issue #136), not the tab chip. The
/// chip moved correctly even while the bug was live, so a chip-only assertion would have passed
/// against broken code.
///
/// Driven with `⌘[` / `⌘]` rather than the titlebar chevrons: that is the idiom ten other UI tests in
/// this suite use, `Go ▸ Back` already owns the shortcut, and it is reserved from the terminal via
/// `isAppShortcut`. The chevrons live in an AppKit titlebar accessory that no UI test has ever driven,
/// where a tap on a `.disabled` button fails *silently* — a green test proving nothing.
///
/// Run with `make app-uitest` on a real GUI login session, or scoped:
/// `xcodebuild … -only-testing:WorkroomAppUITests/NavigationHistoryContentUITests/<method> test`
final class NavigationHistoryContentUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// A changed-file row, by identifier. Deliberately NOT by label: a row reads
  /// "user.rb, modified, in app/models, open diff", so the full repo-relative path never appears in it.
  private func fileRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    element(app, id: "changes.file.\(path)")
  }

  /// The pane footer naming the file this pane shows (issue #136). Matched on the path as well as the
  /// id, because a split shows one bar per pane. The segment's string arrives as the element's `value`
  /// rather than its `label` on macOS, so match either.
  private func paneShowingFile(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
        "terminal.statusBar.path", path, path)
    ).firstMatch
  }

  private func waitGone(_ el: XCUIElement, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "exists == false")
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  private func tabChipCount(_ app: XCUIApplication) -> Int {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.")
    ).count
  }

  /// Browse two changed files, then go Back: the PANE must return to the first file's diff.
  ///
  /// Before the fix this failed at the final assertion in a specific way worth remembering — Back
  /// landed on the *terminal*, because browsing recorded only one entry (the first click, which
  /// created the tab) and every later click retargeted that tab silently.
  func testBackReturnsThePaneToThePreviousDiff() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "the Changes panel should render its working copy")

    // Single-click two different rows. Different rows, so the 350ms double-click promotion that would
    // create a second tab (and record on its own) cannot trigger.
    fileRow(app, "Gemfile").click()
    XCTAssertTrue(
      paneShowingFile(app, "Gemfile").waitForExistence(timeout: 10),
      "the first click should open Gemfile's diff in the pane")
    let chipsAfterFirst = tabChipCount(app)

    fileRow(app, "app/models/user.rb").click()
    XCTAssertTrue(
      paneShowingFile(app, "user.rb").waitForExistence(timeout: 10),
      "the second click should retarget the pane to user.rb")
    XCTAssertFalse(
      element(app, id: "terminal.tab.Gemfile").exists,
      "the shared preview tab is retargeted in place, so Gemfile's chip is gone")
    XCTAssertEqual(chipsAfterFirst, tabChipCount(app), "retargeting must not add a tab")

    app.typeKey("[", modifierFlags: .command)

    XCTAssertTrue(
      paneShowingFile(app, "Gemfile").waitForExistence(timeout: 10),
      "⌘[ must put Gemfile's diff back in the PANE — not merely move the sidebar highlight")
    XCTAssertTrue(
      waitGone(paneShowingFile(app, "user.rb")),
      "and user.rb must be gone from the pane — the pane switched, it did not gain a second one")
    XCTAssertEqual(
      chipsAfterFirst, tabChipCount(app),
      "replay reuses the preview slot: back never creates a tab")

    app.typeKey("]", modifierFlags: .command)

    XCTAssertTrue(
      paneShowingFile(app, "user.rb").waitForExistence(timeout: 10),
      "⌘] must return to user.rb")
  }
}
