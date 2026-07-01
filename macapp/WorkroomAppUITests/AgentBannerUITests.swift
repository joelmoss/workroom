import XCTest

/// End-to-end XCUITest for the inline terminal agent (issue #49, T10). Drives a REAL failing run
/// command in the fixture workroom, so the capture path that the unit tests can't reach runs against
/// a live libghostty surface: a non-zero run exit → `applyRunStatus` → `diagnoseRunFailure` →
/// `readFullSurface` (real SURFACE read) → `RunCaptureSupport` (waits for the supervisor's in-band
/// exit trailer, X3) → manager → `AgentPrompt.parse` → the banner renders.
///
/// Hermetic: `-WorkroomUITestAgentStub` enables the agent with a STUB backend that returns a canned
/// diagnosis, so the test never hits `claude`/`codex` (no network, no cost) — only the *capture* and
/// *UI* are real. The canned summary ("UITEST diagnosis…") is asserted as the banner headline.
final class AgentBannerUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(runCommand: String, presentation: String = "banner") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestAgentStub", "1"]
    app.launchArguments += ["-WorkroomUITestRunCommand", runCommand]
    app.launchArguments += ["-terminalAgentPresentation", presentation]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func startRun(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15), "Run is available")
    app.menuBars.menuBarItems["Run"].menuItems["Run"].click()
  }

  /// Runs start backgrounded (issue #67), so the failing run tab's pane — where the banner lives —
  /// isn't on screen. Focus the run tab to render its pane.
  private func revealRunTab(_ app: XCUIApplication) {
    let runTab = app.descendants(matching: .any).matching(identifier: "terminal.tab.Run").firstMatch
    XCTAssertTrue(runTab.waitForExistence(timeout: 15), "the run tab exists")
    runTab.click()
  }

  /// A failing run command surfaces the inline-agent banner with the (stubbed) diagnosis.
  func testRunFailureShowsAgentBanner() {
    let app = launchedApp(runCommand: "echo 'boom: build failed'; exit 7")
    startRun(app)
    revealRunTab(app)

    let banner = app.descendants(matching: .any)["terminal.agentBanner"]
    XCTAssertTrue(
      banner.waitForExistence(timeout: 20),
      "a failed run auto-diagnoses and shows the inline-agent banner")
    XCTAssertTrue(
      app.staticTexts["UITEST diagnosis: port already in use"].waitForExistence(timeout: 5),
      "the banner shows the parsed diagnosis summary")
    // The canned fix is non-destructive, so Insert fix + Investigate are offered.
    XCTAssertTrue(app.buttons["Insert fix"].exists, "a safe fix offers Insert")
    XCTAssertTrue(app.buttons["Investigate"].exists)
  }

  /// Inline presentation (issue #49): no pane overlay — a ✦ badge on the failed tab opens a popover
  /// with the diagnosis, so the terminal is never covered.
  func testInlinePresentationUsesBadgeAndPopover() {
    let app = launchedApp(runCommand: "echo 'boom: build failed'; exit 7", presentation: "inline")
    startRun(app)
    revealRunTab(app)

    // The chip sets its own `terminal.tab.<title>` identifier, which shadows child identifiers, so
    // query the badge by its a11y LABEL (same pattern as the run-status icon).
    let badge = app.buttons.matching(NSPredicate(format: "label == %@", "Diagnosis available"))
      .firstMatch
    XCTAssertTrue(
      badge.waitForExistence(timeout: 20), "inline mode shows the ✦ badge on the failed tab")
    XCTAssertFalse(
      app.descendants(matching: .any)["terminal.agentBanner"].exists,
      "no pane overlay in inline mode (before the popover opens)")

    badge.click()
    XCTAssertTrue(
      app.staticTexts["UITEST diagnosis: port already in use"].waitForExistence(timeout: 5),
      "the ✦ popover shows the diagnosis")
  }

  /// Dismissing the banner removes it.
  func testDismissClearsBanner() {
    let app = launchedApp(runCommand: "echo nope; exit 3")
    startRun(app)
    revealRunTab(app)

    let banner = app.descendants(matching: .any)["terminal.agentBanner"]
    XCTAssertTrue(banner.waitForExistence(timeout: 20))
    app.buttons["Dismiss"].click()
    XCTAssertTrue(
      banner.waitForNonExistence(timeout: 5), "dismiss removes the banner")
  }
}
