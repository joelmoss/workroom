import XCTest

/// End-to-end XCUITest for the inline terminal agent (issue #49). Drives a REAL failing run command
/// in the fixture workroom, so the capture path the unit tests can't reach runs against a live
/// libghostty surface: a non-zero run exit → `applyRunStatus` → `diagnoseRunFailure` →
/// `readFullSurface` (real SURFACE read) → `RunCaptureSupport` (waits for the supervisor's in-band
/// exit trailer) → manager → `AgentPrompt.parse` → the diagnosis surfaces in the detail-panel status
/// bar (and a ✦ badge on the tab).
///
/// Hermetic: `-WorkroomUITestAgentStub` enables the agent with a STUB backend that returns a canned
/// diagnosis, so the test never hits `claude`/`codex` (no network, no cost) — only the *capture* and
/// *UI* are real. The canned summary ("UITEST diagnosis…") is asserted.
final class TerminalAgentUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(runCommand: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestAgentStub", "1"]
    app.launchArguments += ["-WorkroomUITestRunCommand", runCommand]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func startRun(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15), "Run is available")
    app.menuBars.menuBarItems["Run"].menuItems["Run"].click()
  }

  /// Runs start backgrounded (issue #67), so the failing run tab isn't on screen. Focus it so its
  /// pane (and the status bar reflecting it) render.
  private func revealRunTab(_ app: XCUIApplication) {
    let runTab = app.descendants(matching: .any).matching(identifier: "terminal.tab.Run").firstMatch
    XCTAssertTrue(runTab.waitForExistence(timeout: 15), "the run tab exists")
    runTab.click()
  }

  /// A failing run command surfaces the (stubbed) diagnosis in the status bar; clicking it opens the
  /// popover with the fix and actions.
  func testRunFailureShowsDiagnosisInStatusBar() {
    let app = launchedApp(runCommand: "echo 'boom: build failed'; exit 7")
    startRun(app)
    revealRunTab(app)

    let diagnosis = app.buttons["terminal.statusBar.diagnosis"]
    XCTAssertTrue(
      diagnosis.waitForExistence(timeout: 20),
      "a failed run auto-diagnoses and shows the diagnosis in the status bar")

    diagnosis.click()
    XCTAssertTrue(
      app.staticTexts["UITEST diagnosis: port already in use"].waitForExistence(timeout: 5),
      "the diagnosis popover shows the parsed summary")
    // The canned fix is non-destructive, so Insert fix + Investigate are offered.
    XCTAssertTrue(app.buttons["Insert fix"].exists, "a safe fix offers Insert")
    XCTAssertTrue(app.buttons["Investigate"].exists)
  }

  /// The exact issue #146 regression: TerminalTabStrip's Investigate previously hardcoded a bare
  /// `"claude"` invocation with no context, while TerminalStatusBar's already seeded it with the
  /// diagnosis. Both now route through `AppStore.startInvestigate`, so clicking Investigate from
  /// EITHER entry point must open a tab whose command carries the canned diagnosis text — not a
  /// bare `claude` with nothing to go on. Checked via the status-bar popover here (the tab-strip's
  /// popover is covered by `testFailedTabShowsAgentBadge`'s identical entry point, minus the click).
  func testClickingInvestigateSeedsTheRealDiagnosisNotABareCommand() {
    let app = launchedApp(runCommand: "echo 'boom: build failed'; exit 7")
    startRun(app)
    revealRunTab(app)

    let diagnosis = app.buttons["terminal.statusBar.diagnosis"]
    XCTAssertTrue(diagnosis.waitForExistence(timeout: 20))
    diagnosis.click()

    let investigate = app.buttons["Investigate"]
    XCTAssertTrue(investigate.waitForExistence(timeout: 5))
    investigate.click()

    // Investigate opens a new focused tab (titled "Run" until claude reports its own title, same
    // as any run tab) seeded with the diagnosis — read its live surface content via the
    // fixture-only accessibility value (`UITestFixture.isActive` → `readText(VIEWPORT)`).
    let newSurface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .element(boundBy: 0)
    XCTAssertTrue(newSurface.waitForExistence(timeout: 10), "Investigate opens a new terminal pane")

    let containsDiagnosis = NSPredicate { _, _ in
      (newSurface.value as? String)?.contains("UITEST diagnosis: port already in use") == true
    }
    let expectation = XCTNSPredicateExpectation(predicate: containsDiagnosis, object: nil)
    let result = XCTWaiter().wait(for: [expectation], timeout: 10)
    XCTAssertEqual(
      result, .completed,
      "the seeded command must carry the diagnosis text, not a bare `claude` invocation — got: "
        + "\(newSurface.value ?? "<nil>")")
  }

  /// A failed tab carries a ✦ badge (the per-tab signal), which opens the same diagnosis popover.
  func testFailedTabShowsAgentBadge() {
    let app = launchedApp(runCommand: "echo 'boom: build failed'; exit 7")
    startRun(app)
    revealRunTab(app)

    // The chip sets its own `terminal.tab.<title>` identifier, which shadows child identifiers, so
    // query the badge by its a11y LABEL (same pattern as the run-status icon).
    let badge = app.buttons.matching(NSPredicate(format: "label == %@", "Diagnosis available"))
      .firstMatch
    XCTAssertTrue(badge.waitForExistence(timeout: 20), "the failed tab shows the ✦ diagnosis badge")

    badge.click()
    XCTAssertTrue(
      app.staticTexts["UITEST diagnosis: port already in use"].waitForExistence(timeout: 5),
      "the ✦ badge opens the diagnosis popover")
  }

  /// Dismissing from the popover clears the diagnosis everywhere (status bar + badge). The popover
  /// lives in its own window, so its Dismiss button is always clickable (unlike a pane overlay whose
  /// controls lose hit-testing to the terminal's Metal view).
  func testDismissFromPopoverClearsDiagnosis() {
    let app = launchedApp(runCommand: "echo nope; exit 3")
    startRun(app)
    revealRunTab(app)

    let diagnosis = app.buttons["terminal.statusBar.diagnosis"]
    XCTAssertTrue(diagnosis.waitForExistence(timeout: 20))
    diagnosis.click()

    let dismiss = app.buttons["Dismiss"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
    dismiss.click()

    XCTAssertTrue(
      diagnosis.waitForNonExistence(timeout: 5), "dismiss clears the status-bar diagnosis")
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label == %@", "Diagnosis available")).firstMatch
        .exists,
      "dismiss also clears the tab badge")
  }

  /// A diff pane carries a status bar too — the path + branch variant, with no cwd/run/diagnosis
  /// (those are terminal-only). What the path segment says is asserted in `DiffViewerUITests`.
  func testDiffPaneHasStatusBar() {
    let app = launchedApp(runCommand: "true")
    let row = app.descendants(matching: .any)["changes.file.app/models/user.rb"]
    XCTAssertTrue(row.waitForExistence(timeout: 15), "a changed-file row renders")
    row.click()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.tab.user.rb").firstMatch
        .waitForExistence(timeout: 6), "a diff tab opens")
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 6),
      "the diff pane has a status bar")
  }

  /// Every terminal pane carries its own status bar — including each member of a split.
  func testEveryPaneHasAStatusBar() {
    let app = launchedApp(runCommand: "true")
    let bars = app.descendants(matching: .any).matching(identifier: "terminal.statusBar")
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 20),
      "a solo pane has a status bar")
    XCTAssertEqual(bars.count, 1)

    // Split the focused pane → two terminals side by side, each with its own bar.
    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    let twoBars = NSPredicate(format: "count == 2")
    expectation(for: twoBars, evaluatedWith: bars)
    waitForExpectations(timeout: 10)
  }
}
