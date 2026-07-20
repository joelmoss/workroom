import XCTest

/// UI test for the Settings window's source-list sidebar (⌘,). Guards the regression the user hit:
/// clicking a sidebar row must switch the detail to THAT pane. The switch is wired through a `@State`
/// selection (NOT `@Default`, whose SwiftUI wrapper invalidates asynchronously — the click then only
/// repainted after the next event, e.g. a cursor move; cf. the same class of bug in
/// `ChangesPanelUITests.testClickingHeaderTogglesGroup`).
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// this is excluded from `make app-test` (the unit gate) via a separate scheme.
final class SettingsSidebarUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// Open the Settings window via the app menu (index 1: the app-named menu, after the Apple menu).
  private func openSettings(_ app: XCUIApplication) {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "app menu should exist")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings… menu item should exist")
    settings.click()
  }

  /// A sidebar row button by its accessibility id (`settingsPane.<rawValue>`).
  private func pane(_ app: XCUIApplication, _ raw: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "settingsPane.\(raw)").firstMatch
  }

  /// A detail-pane control by its accessibility id (`settings.control.<name>`). Matching by id, not
  /// label, because a Form `Toggle`/`Picker`'s title isn't reliably exposed as an element `label`.
  private func control(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "settings.control.\(id)").firstMatch
  }

  /// An About-pane control by its accessibility id (`about.<name>`).
  private func aboutControl(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "about.\(id)").firstMatch
  }

  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 5) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// Clicking each sidebar row switches the detail to that pane: the pane's own control appears AND
  /// the previous pane's control disappears (proving the detail actually swapped, not just added).
  func testClickingEachSidebarRowSwitchesTheDetailPane() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openSettings(app)

    XCTAssertTrue(pane(app, "general").waitForExistence(timeout: 10), "sidebar should render")

    // General → its "Confirm before quitting" toggle.
    pane(app, "general").click()
    XCTAssertTrue(waitExists(control(app, "confirmQuit"), true), "General shows its controls")

    // Appearance → "Diff view" appears, and General's toggle is gone (detail swapped).
    pane(app, "appearance").click()
    XCTAssertTrue(waitExists(control(app, "diffView"), true), "Appearance shows its controls")
    XCTAssertTrue(
      waitExists(control(app, "confirmQuit"), false),
      "switching away replaces the General detail")

    // Terminal → "Copy on select".
    pane(app, "terminal").click()
    XCTAssertTrue(waitExists(control(app, "copyOnSelect"), true), "Terminal shows its controls")

    // Agent → "Diagnose automatically".
    pane(app, "agent").click()
    XCTAssertTrue(waitExists(control(app, "autoDiagnose"), true), "Agent shows its controls")

    // About → the "Check for Updates…" button; Agent's control is gone (detail swapped).
    pane(app, "about").click()
    XCTAssertTrue(
      aboutControl(app, "checkForUpdates").waitForExistence(timeout: 5), "About shows its controls")
    XCTAssertTrue(
      waitExists(control(app, "autoDiagnose"), false),
      "switching away replaces the Agent detail")
  }

  /// The About pane (issue #91) exposes the version, the repo/release-notes links, the
  /// "Check for Updates…" button, and the release-channel picker — all reachable by a11y id.
  func testAboutPaneHasUpdateControlsAndLinks() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openSettings(app)

    XCTAssertTrue(pane(app, "about").waitForExistence(timeout: 10), "sidebar should render")
    pane(app, "about").click()
    XCTAssertTrue(
      aboutControl(app, "version").waitForExistence(timeout: 5), "About shows the version")
    XCTAssertTrue(aboutControl(app, "repo").exists, "About shows the repository link")
    XCTAssertTrue(aboutControl(app, "releaseNotes").exists, "About shows the release-notes link")
    XCTAssertTrue(aboutControl(app, "checkForUpdates").exists, "About shows Check for Updates…")
    XCTAssertTrue(
      control(app, "releaseChannel").exists, "About shows the release-channel picker")
  }

  /// ⌘W closes the Settings window even though the app-wide "Close Terminal" ⌘W command is disabled
  /// there (it has no focused terminal) — handled by the AppDelegate key monitor for non-workroom
  /// windows.
  func testCommandWClosesSettingsWindow() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openSettings(app)

    let generalRow = pane(app, "general")
    XCTAssertTrue(generalRow.waitForExistence(timeout: 10), "Settings should be open")

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitExists(generalRow, false), "⌘W should close the Settings window")
  }
}
