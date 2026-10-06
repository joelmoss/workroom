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

  /// A failing run command surfaces the (stubbed) diagnosis in the status bar and a ✦ badge on the
  /// tab; clicking the diagnosis opens the popover with the fix and actions, and dismissing from it
  /// clears the diagnosis everywhere. One ordered chain on one launch: badge, then popover, then
  /// Dismiss (Dismiss removes the badge, so the badge check has to come first).
  ///
  /// The badge is asserted on the CHIP's own accessibility label, not on the badge button. The badge
  /// is a nested `Button`, and the chip's explicit `.accessibilityLabel` (issue #141) collapses the
  /// chip into one accessibility element, so no descendant of it is queryable — the same wall that
  /// forced run state onto the chip's `.accessibilityValue`. This test previously queried
  /// `app.buttons["Diagnosis available"]` and had been failing ever since, waiting 20s for an element
  /// accessibility does not expose.
  ///
  /// **Not covered here:** clicking the badge to open the popover. XCUITest cannot invoke a named
  /// accessibility action, and the badge has no reachable element to click, so the chip→popover path
  /// is manual-verify only. The popover's own contents and actions are covered from the status-bar
  /// entry point here and by `testClickingInvestigateSeedsTheRealDiagnosisNotABareCommand`.
  ///
  /// The popover lives in its own window, so its Dismiss button is always clickable (unlike a pane
  /// overlay whose controls lose hit-testing to the terminal's Metal view).
  func testRunFailureShowsDiagnosisBadgePopoverAndDismissClearsIt() {
    let app = launchedApp(runCommand: "echo 'boom: build failed'; exit 7")
    startRun(app)
    revealRunTab(app)

    let diagnosis = app.buttons["terminal.statusBar.diagnosis"]
    XCTAssertTrue(
      diagnosis.waitForExistence(timeout: 20),
      "a failed run auto-diagnoses and shows the diagnosis in the status bar")

    // The ✦ badge: the per-tab signal that complements the status-bar diagnosis.
    let chip = app.descendants(matching: .any).matching(identifier: "terminal.tab.Run").firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the run tab chip exists")
    XCTAssertTrue(
      poll(timeout: 20, until: { chip.label.contains("Diagnosis available") }),
      "the failed tab announces the ✦ diagnosis badge; got label \(chip.label)")

    diagnosis.click()
    XCTAssertTrue(
      app.staticTexts["UITEST diagnosis: port already in use"].waitForExistence(timeout: 5),
      "the diagnosis popover shows the parsed summary")
    // The canned fix is non-destructive, so Insert fix + Investigate are offered.
    XCTAssertTrue(app.buttons["Insert fix"].exists, "a safe fix offers Insert")
    XCTAssertTrue(app.buttons["Investigate"].exists)

    // The badge is still present immediately before Dismiss, so the "badge cleared" assertion
    // below can fail. It previously asserted `app.buttons["Diagnosis available"].exists == false`,
    // which was VACUOUSLY true: accessibility never exposes that button, so it passed whether or not
    // dismiss actually cleared the badge. Read the chip's own label instead, which is where the
    // badge is announced — and which can therefore fail.
    XCTAssertTrue(
      chip.label.contains("Diagnosis available"),
      "the badge is still present before Dismiss; got label \(chip.label)")
    let dismiss = app.buttons["Dismiss"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
    dismiss.click()

    XCTAssertTrue(
      diagnosis.waitForNonExistence(timeout: 5), "dismiss clears the status-bar diagnosis")
    XCTAssertTrue(chip.exists, "the run tab chip is still on screen")
    XCTAssertTrue(
      poll(timeout: 5, until: { !chip.label.contains("Diagnosis available") }),
      "dismiss also clears the tab badge; got label \(chip.label)")
  }

  /// The exact issue #146 regression: TerminalTabStrip's Investigate previously hardcoded a bare
  /// `"claude"` invocation with no context, while TerminalStatusBar's already seeded it with the
  /// diagnosis. Both now route through `AppStore.startInvestigate`, so clicking Investigate from
  /// EITHER entry point must open a tab whose command carries the canned diagnosis text — not a
  /// bare `claude` with nothing to go on. Checked via the status-bar popover here (the tab-strip's
  /// popover is covered by the badge step of
  /// `testRunFailureShowsDiagnosisBadgePopoverAndDismissClearsIt`'s identical entry point, minus the
  /// click).
  ///
  /// Asserts on the seeded ARGV (`accessibilityPlaceholderValue`), not the spawned process's
  /// rendered output: Investigate always shells out to the REAL `claude` binary (the agent stub only
  /// fakes the earlier diagnosis step), and a fresh fixture workroom is untrusted to `claude` on
  /// every run — its first-run trust prompt would block forever before anything the seed contains
  /// ever reaches the screen. `RunCommandTests.testStartInvestigateBuildsCommandAndTracksTab` already
  /// pins `AppStore.startInvestigate`'s own command construction exactly; this test's job is only to
  /// confirm THIS click path (the status-bar popover) actually reaches it.
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
    // as any run tab) seeded with the diagnosis.
    let newSurface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .element(boundBy: 0)
    XCTAssertTrue(newSurface.waitForExistence(timeout: 10), "Investigate opens a new terminal pane")

    let seededCommand = newSurface.placeholderValue ?? "<nil>"
    XCTAssertTrue(
      seededCommand.contains("UITEST diagnosis: port already in use"),
      "the seeded command must carry the diagnosis text, not a bare `claude` invocation — got: "
        + seededCommand)
  }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      usleep(200_000)
    }
    return condition()
  }

  /// Every pane carries its own status bar: the solo terminal, a diff pane (the path + branch
  /// variant, with no cwd/run/diagnosis — those are terminal-only; what the path segment says is
  /// asserted in `DiffViewerUITests`), and each member of a split. One launch: the diff tab goes
  /// first (a pane renders only its selected tab's content, so the bar count stays 1 there), then the
  /// terminal tab is re-selected so the split splits a terminal pane.
  func testEveryPaneHasAStatusBar() {
    let app = launchedApp(runCommand: "true")
    let bars = app.descendants(matching: .any).matching(identifier: "terminal.statusBar")
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 20),
      "a solo pane has a status bar")
    XCTAssertEqual(bars.count, 1)

    // Remember the terminal tab's chip before the diff tab adds a second `terminal.tab.*` chip.
    let terminalChip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.")).firstMatch
    XCTAssertTrue(terminalChip.waitForExistence(timeout: 10), "the terminal tab chip exists")
    let terminalChipID = terminalChip.identifier

    let row = app.descendants(matching: .any)["changes.file.app/models/user.rb"]
    XCTAssertTrue(row.waitForExistence(timeout: 15), "a changed-file row renders")
    row.scrollIntoView(in: app)
    row.click()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.tab.user.rb").firstMatch
        .waitForExistence(timeout: 6), "a diff tab opens")
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 6),
      "the diff pane has a status bar")
    XCTAssertEqual(bars.count, 1, "the diff pane shows exactly one status bar")

    // Back to the terminal tab, so the split below splits a terminal pane.
    app.descendants(matching: .any).matching(identifier: terminalChipID).firstMatch.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 6),
      "the re-selected terminal pane has a status bar")
    XCTAssertEqual(bars.count, 1)

    // Split the focused pane → two terminals side by side, each with its own bar.
    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    let twoBars = NSPredicate(format: "count == 2")
    expectation(for: twoBars, evaluatedWith: bars)
    waitForExpectations(timeout: 10)
  }
}
