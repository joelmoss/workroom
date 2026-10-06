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

  /// One launch, one ordered chain (each step leaves the state the next needs):
  ///
  /// 1. Clicking each icon swaps the pane: the selected section's header(s) appear AND the other
  ///    section's header disappears (proving a swap, not an add). The Changes pane stacks Changes,
  ///    History and Pull Request headers; the Files pane shows only the Files header. Each step is
  ///    a SWITCH to a different section, which always opens that section's pane (never toggles it
  ///    closed), so the step is independent of the persisted open/section state the app launches
  ///    with (tests share the real "Workroom Dev" defaults domain). Ends with Files active, open.
  /// 2. History (issue #59) is a **section of the Changes stack**, sitting between Changes and Pull
  ///    Request — not a bar section of its own. So there is no `activitySection.history` icon, and
  ///    its header collapses in place (a chevron, an "expanded"/"collapsed" a11y label) exactly
  ///    like its two siblings, rather than closing the whole pane the way solo Files does.
  ///    Switching from Files to Changes (always an open) is the setup; History is restored before
  ///    the next step.
  /// 3. Clicking the ACTIVE icon collapses the content pane (its headers disappear) while the bar
  ///    icon itself stays — the VSCode toggle behaviour. It runs last, and must NOT click `files`
  ///    first: Files is already active here, so that click would collapse it. It leaves Changes
  ///    active but collapsed, so the next run's first click (on `files`) is still a switch.
  func testActivityBarIconsSwapCollapseAndHistorySection() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    XCTAssertTrue(icon(app, "files").waitForExistence(timeout: 10), "activity bar should render")
    // The bar has rendered (the Files icon exists), so this absence is meaningful.
    XCTAssertFalse(icon(app, "history").exists, "History is no longer a bar section")

    // Files → the Files header; Changes header absent.
    icon(app, "files").click()
    XCTAssertTrue(waitExists(header(app, "Files"), true), "Files pane shows the Files header")

    // Switch to Changes → the Changes + History + Pull Request stack appears and Files is gone (a
    // swap).
    icon(app, "changes").click()
    XCTAssertTrue(waitExists(header(app, "Changes"), true), "Changes pane shows the Changes header")
    XCTAssertTrue(waitExists(header(app, "History"), true), "Changes pane stacks History")
    XCTAssertTrue(waitExists(header(app, "Pull Request"), true), "Changes pane stacks Pull Request")
    XCTAssertTrue(waitExists(header(app, "Files"), false), "switching away replaces the Files pane")

    // Switch back to Files → Files returns, the Changes stack is gone.
    icon(app, "files").click()
    XCTAssertTrue(waitExists(header(app, "Files"), true), "Files pane returns")
    XCTAssertTrue(waitExists(header(app, "Changes"), false), "the Changes pane is replaced")
    XCTAssertTrue(waitExists(header(app, "History"), false), "…History with it")

    // Files is active and open, so Changes is a SWITCH (which always opens).
    icon(app, "changes").click()
    let history = header(app, "History")
    XCTAssertTrue(waitExists(history, true), "the Changes pane stacks the History section")

    // Collapsing History leaves the pane (and its siblings) in place — only its own label flips.
    let before = history.label
    history.click()
    let flipped = XCTWaiter().wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "label != %@", before), object: history)
      ], timeout: 5)
    XCTAssertEqual(
      flipped, .completed, "History's collapsed/expanded label should flip (was \(before))")
    XCTAssertTrue(header(app, "Changes").exists, "collapsing History keeps the Changes section")
    XCTAssertTrue(header(app, "Pull Request").exists, "…and Pull Request")

    history.click()  // leave it as it was found
    let restored = XCTWaiter().wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "label == %@", before), object: history)
      ], timeout: 5)
    XCTAssertEqual(restored, .completed, "History should be back as it was found (\(before))")

    // Changes is active and open (just established) → clicking the ACTIVE icon collapses the
    // content, the bar icon stays.
    let changes = icon(app, "changes")
    XCTAssertTrue(waitExists(header(app, "Changes"), true), "Changes pane is open")
    changes.click()
    XCTAssertTrue(
      waitExists(header(app, "Changes"), false), "clicking the active icon hides content")
    XCTAssertTrue(changes.exists, "the bar icon stays visible after collapsing the pane")
  }
}
