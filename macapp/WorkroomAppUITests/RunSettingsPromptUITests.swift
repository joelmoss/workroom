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
    //
    // `.buttons`, NOT `.otherElements`: the sidebar row carries
    // `.accessibilityAddTraits(.isButton)` (`ProjectSidebar.swift`), so XCUITest resolves it as a
    // button and an `otherElements` query matches nothing — which is what silently failed both
    // tests in this file. Same form as `ChangesetDetailUITests`/`HistoryPushStateUITests`, the two
    // other places that select this row.
    let row = app.buttons.matching(
      NSPredicate(
        format: "identifier == %@ AND label == %@", "sidebar.workroom.uitest-room", "uitest-room")
    ).firstMatch
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

  /// The same branch, reached by CLICK. Since issue #139's follow-up the workroom pane header's Run button
  /// is shown even with no command configured — it exists precisely to lead you here, so a button that
  /// silently did nothing (or wasn't there at all) would be the regression. Written as its own test rather
  /// than folded into the ⌘R one because the keyboard and the click take different doors into
  /// `runOrFocusRunCommand`: the shortcut goes through the selection-scoped overload, the button through
  /// the per-target one.
  func testHeaderRunButtonPresentsRunSettingsWhenNoCommandConfigured() {
    let app = launchedApp()

    let pane = app.descendants(matching: .any).matching(identifier: "workroom.pane").firstMatch
    XCTAssertTrue(pane.waitForExistence(timeout: 10))
    let run = pane.buttons["runCommand.run"]
    XCTAssertTrue(
      run.waitForExistence(timeout: 10),
      "Run should be shown even though this project has no run command configured")
    run.click()

    XCTAssertTrue(
      app.staticTexts["projectSettings.runWarning"].waitForExistence(timeout: 10),
      "clicking Run with nothing configured should open Project Settings, warned")
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
