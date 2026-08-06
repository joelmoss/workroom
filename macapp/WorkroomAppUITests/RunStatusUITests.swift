import XCTest

/// XCUITests for run success/failure indicators (issue #79). Unlike the store-level
/// `RunCommandTests`, these drive a REAL run command in the fixture workroom (a temp dir), so the
/// integration seams the unit tests bypass get end-to-end coverage:
///   1. a real non-zero exit → the failed run icon (the wrapper records the code; libghostty's own
///      child-exit code is unreliable in the pinned GhosttyKit, so this proves the recorded-code path).
///   2. in-pane ⌃C → `onInterrupt` → NOT a failure (the `keyDown`/NSEvent wiring the unit tests skip).
///
/// The fixture run command is overridden per-test via `-WorkroomUITestRunCommand`. The run-status
/// chip icon inherits the tab's `terminal.tab.<title>` identifier, so it's queried by its a11y LABEL
/// (`running` / `stopped` / `failed`), not an identifier. Colour isn't assertable via XCUITest — the
/// red tint is checked in manual QA; here we assert the failed indicator's PRESENCE / ABSENCE.
final class RunStatusUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(runCommand: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestRunCommand", runCommand]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// Start the run via the menu — clicking the toolbar Run button is flaky under XCUITest (it can
  /// collapse into the toolbar overflow); the menu item is always hittable.
  private func startRun(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15), "Run is available")
    app.menuBars.menuBarItems["Run"].menuItems["Run"].click()
  }

  /// A run-status chip icon by its a11y label (`running` / `stopped` / `failed`).
  private func runIcon(_ app: XCUIApplication, label: String) -> XCUIElement {
    app.images.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  /// A run that exits non-zero on its own surfaces the failed run icon (red xmark octagon).
  func testFailedRunShowsFailedIndicator() {
    let app = launchedApp(runCommand: "sleep 1; exit 7")
    startRun(app)
    XCTAssertTrue(
      runIcon(app, label: "failed").waitForExistence(timeout: 15),
      "a non-zero exit shows the failed run icon (#79)")
  }

  /// A run that exits 0 is a success, not a failure: no failed icon (the chip settles on stopped).
  func testCleanExitDoesNotShowFailedIndicator() {
    let app = launchedApp(runCommand: "sleep 1; exit 0")
    startRun(app)
    XCTAssertTrue(
      runIcon(app, label: "stopped").waitForExistence(timeout: 15), "the run finished")
    XCTAssertFalse(runIcon(app, label: "failed").exists, "a clean exit is not a failure (#79)")
  }

  /// Typing ⌃C into the run terminal is a user interrupt, not a crash: the run stops but the failed
  /// icon must NOT appear, whatever code the signalled process reports (#79). Exercises the
  /// `keyDown` ⌃C → `onInterrupt` wiring the store-level tests can't reach.
  func testInPaneCtrlCDoesNotShowFailedIndicator() {
    let app = launchedApp(runCommand: "sleep 30")
    startRun(app)
    XCTAssertTrue(
      app.buttons["runCommand.stop"].waitForExistence(timeout: 15), "the run started")

    // Focus the (backgrounded) run terminal, then ⌃C it: forwards SIGINT to the PTY and fires
    // onInterrupt, so the exit is recorded as a user stop.
    app.descendants(matching: .any).matching(identifier: "terminal.tab.Run").firstMatch.click()
    app.typeKey("c", modifierFlags: .control)

    XCTAssertTrue(
      runIcon(app, label: "stopped").waitForExistence(timeout: 15), "the run stopped after ⌃C")
    XCTAssertFalse(
      runIcon(app, label: "failed").exists, "in-pane ⌃C reads as a stop, not a failure (#79)")
  }
}
