import XCTest

/// UI test for the right activity bar (the vertical icon rail). Guards the core behaviour: clicking a
/// section icon shows THAT section's pane (and hides the other's), and clicking the already-active
/// icon collapses the content pane while the bar stays. The bar is the swap-pane mechanism, so this
/// is the activity-bar analogue of `SettingsSidebarUITests`.
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// this is excluded from `make app-test` (the unit gate) via a separate scheme.
final class ActivityBarUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// A bar icon by its accessibility id (`activitySection.<rawValue>`).
  private func icon(_ app: XCUIApplication, _ raw: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "activitySection.\(raw)").firstMatch
  }

  /// A section header by its accessibility id (`inspector.header.<title>`) — present only while that
  /// sub-section's pane is on screen, so it's the signal that a section is showing.
  private func header(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "inspector.header.\(title)").firstMatch
  }

  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 5) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// Clicking each icon swaps the pane: the selected section's header(s) appear AND the other
  /// section's header disappears (proving a swap, not an add). The Changes pane stacks both Changes
  /// and Pull Request headers; the Files pane shows only the Files header.
  ///
  /// Each step is a SWITCH to a different section, which always opens that section's pane (never
  /// toggles it closed), so the test is independent of the persisted open/section state it launches
  /// with (tests share the real "Workroom Dev" defaults domain).
  func testClickingIconsSwapsThePane() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    XCTAssertTrue(icon(app, "files").waitForExistence(timeout: 10), "activity bar should render")

    // Files → the Files header; Changes header absent.
    icon(app, "files").click()
    XCTAssertTrue(waitExists(header(app, "Files"), true), "Files pane shows the Files header")

    // Switch to Changes → the Changes + Pull Request stack appears and Files is gone (a swap).
    icon(app, "changes").click()
    XCTAssertTrue(waitExists(header(app, "Changes"), true), "Changes pane shows the Changes header")
    XCTAssertTrue(waitExists(header(app, "Pull Request"), true), "Changes pane stacks Pull Request")
    XCTAssertTrue(waitExists(header(app, "Files"), false), "switching away replaces the Files pane")

    // Switch back to Files → Files returns, the Changes stack is gone.
    icon(app, "files").click()
    XCTAssertTrue(waitExists(header(app, "Files"), true), "Files pane returns")
    XCTAssertTrue(waitExists(header(app, "Changes"), false), "the Changes pane is replaced")
  }

  /// Clicking the ACTIVE icon collapses the content pane (its headers disappear) while the bar icon
  /// itself stays — the VSCode toggle behaviour.
  func testClickingActiveIconCollapsesContent() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let changes = icon(app, "changes")
    XCTAssertTrue(changes.waitForExistence(timeout: 10), "activity bar should render")

    // Put Changes into a known-open state by switching to it from Files (a switch always opens,
    // regardless of the persisted visibility the app launched with).
    icon(app, "files").click()
    XCTAssertTrue(waitExists(header(app, "Files"), true), "Files pane opens")
    changes.click()
    XCTAssertTrue(waitExists(header(app, "Changes"), true), "Changes pane opens")

    // Click the ACTIVE icon → the content collapses, the bar icon stays.
    changes.click()
    XCTAssertTrue(
      waitExists(header(app, "Changes"), false), "clicking the active icon hides content")
    XCTAssertTrue(changes.exists, "the bar icon stays visible after collapsing the pane")
  }

  /// History (issue #59) is its own bar section, not a tab inside Changes: clicking its icon swaps
  /// the History pane in (its header + the `HistoryPanel` body appear) and replaces whatever pane
  /// was showing — the same swap contract as Changes/Files, proving History joined the rail as a
  /// peer section rather than being nested under another.
  func testHistorySectionSwapsIntoView() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    XCTAssertTrue(icon(app, "history").waitForExistence(timeout: 10), "History icon should render")

    // Prime with Files so the next History click is guaranteed a SWITCH (which always opens),
    // independent of whatever section the shared "Workroom Dev" defaults launched active — clicking
    // an already-active icon toggles it closed, so we can't assert on this priming click itself.
    icon(app, "files").click()

    icon(app, "history").click()
    XCTAssertTrue(waitExists(header(app, "History"), true), "History pane shows the History header")
    XCTAssertTrue(waitExists(header(app, "Files"), false), "switching away replaces the Files pane")

    // Switch back to Files (Files ≠ the now-active History → a switch, opens) → History is gone.
    icon(app, "files").click()
    XCTAssertTrue(waitExists(header(app, "Files"), true), "Files pane returns")
    XCTAssertTrue(waitExists(header(app, "History"), false), "the History pane is replaced")
  }
}
