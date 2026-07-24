import XCTest

/// ⌘R on a workroom with no run command opens the Project Settings sheet with the "no command
/// yet" warning (issue #127) — not a silent no-op.
final class RunSettingsPromptUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    // -WorkroomUITestNoRunCommand: the fixture otherwise ALWAYS seeds a fallback run command
    // (AppStore.loadFixture), so without this flag the "no command configured" state this whole
    // test file exists to exercise would never actually hold (found by review, issue #127).
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestNoRunCommand", "1",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    // Explicitly select the fixture workroom before sending ⌘R — `runningForeground` proves the
    // window is up, not that a target is selected/ready (outside-voice review flagged this).
    let row = app.otherElements["sidebar.workroom.uitest-room"]
    XCTAssertTrue(row.waitForExistence(timeout: 10), "fixture workroom row should exist")
    row.click()
    return app
  }

  func testCommandRPresentsRunSettingsWithWarningWhenNoCommandConfigured() {
    let app = launchedApp()

    app.typeKey("r", modifierFlags: .command)

    XCTAssertTrue(
      app.staticTexts["projectSettings.runWarning"].waitForExistence(timeout: 10),
      "the warning banner should appear")
    XCTAssertTrue(
      app.textFields["projectSettings.runCommand"].waitForExistence(timeout: 5),
      "the run-command field should be present so the user can define one")
  }

  /// Regression check for unifying to one sheet presenter (issue #127-eng-1): the pre-existing
  /// "Project Settings…" context-menu entry must keep opening with NO warning banner.
  func testProjectSettingsContextMenuShowsNoWarningBanner() {
    let app = launchedApp()

    // "Project Settings…" lives on the PROJECT row's context menu (ProjectSidebar.swift), not the
    // workroom row's — unlike the ⌘R test above, which acts on the selected workroom.
    app.otherElements["sidebar.project.UITestProject"].rightClick()
    app.menuItems["Project Settings…"].click()

    XCTAssertTrue(
      app.textFields["projectSettings.runCommand"].waitForExistence(timeout: 10),
      "the settings sheet should open")
    XCTAssertFalse(
      app.staticTexts["projectSettings.runWarning"].exists,
      "the plain Project Settings entry must not show the Run warning")
  }
}
