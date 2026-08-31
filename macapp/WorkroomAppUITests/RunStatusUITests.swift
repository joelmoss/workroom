import XCTest

/// XCUITests for run success/failure indicators (issue #79). Unlike the store-level
/// `RunCommandTests`, these drive a REAL run command in the fixture workroom (a temp dir), so the
/// integration seams the unit tests bypass get end-to-end coverage:
///   1. a real non-zero exit → the failed run icon (the wrapper records the code; libghostty's own
///      child-exit code is unreliable in the pinned GhosttyKit, so this proves the recorded-code path).
///   2. in-pane ⌃C → `onInterrupt` → NOT a failure (the `keyDown`/NSEvent wiring the unit tests skip).
///
/// The fixture run command is overridden per-test via `-WorkroomUITestRunCommand`. The run tab's
/// chip has its own explicit `.accessibilityLabel` (issue #141's recognized-tool favicon), which
/// makes the whole chip ONE accessibility element — the nested run-state icon is not independently
/// queryable, so run state is read off the CHIP's own `.accessibilityValue` (`running` / `stopped` /
/// `failed`) instead. Colour isn't assertable via XCUITest — the red tint is checked in manual QA;
/// here we assert the failed indicator's PRESENCE / ABSENCE.
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

  private func runTabChip(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "terminal.tab.Run").firstMatch
  }

  /// XCUITest has no built-in "wait for this value"; the run's own state arrives from the
  /// supervisor's callback thread, not from a UI event this test drove, so polling is unavoidable.
  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  private func waitForRunState(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 15)
    -> Bool
  {
    let chip = runTabChip(app)
    return poll(timeout: timeout) { (chip.value as? String) == label }
  }

  /// A run that exits non-zero on its own surfaces the failed run icon (red xmark octagon).
  func testFailedRunShowsFailedIndicator() {
    let app = launchedApp(runCommand: "sleep 1; exit 7")
    startRun(app)
    XCTAssertTrue(
      waitForRunState(app, "failed"),
      "a non-zero exit shows the failed run icon (#79); got \(runTabChip(app).value ?? "<nil>")")
  }

  /// A run that exits 0 is a success, not a failure: no failed icon (the chip settles on stopped).
  func testCleanExitDoesNotShowFailedIndicator() {
    let app = launchedApp(runCommand: "sleep 1; exit 0")
    startRun(app)
    XCTAssertTrue(waitForRunState(app, "stopped"), "the run finished")
    XCTAssertNotEqual(
      runTabChip(app).value as? String, "failed", "a clean exit is not a failure (#79)")
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
    runTabChip(app).click()
    app.typeKey("c", modifierFlags: .control)

    XCTAssertTrue(waitForRunState(app, "stopped"), "the run stopped after ⌃C")
    XCTAssertNotEqual(
      runTabChip(app).value as? String, "failed",
      "in-pane ⌃C reads as a stop, not a failure (#79)")
  }
}
