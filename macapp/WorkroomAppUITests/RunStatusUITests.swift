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
    app.useScratchDaemon()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// Start the run via the menu — clicking the toolbar Run button is flaky under XCUITest (it can
  /// collapse into the toolbar overflow); the menu item is always hittable.
  private func startRun(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15), "Run is available")
    app.menuBars.menuBarItems["Room"].menuItems["Run"].click()
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

  /// Only the open context menu's items have a frame; the menu bar keeps zero-frame copies.
  private func assertRunMenu(_ app: XCUIApplication, running: Bool) throws {
    XCTAssertNotNil(app.waitForHittableMenuItem(titled: "Run"))
    for title in ["Restart", "Stop"] {
      let item = try XCTUnwrap(
        app.menuItems.matching(NSPredicate(format: "title == %@", title))
          .allElementsBoundByIndex.first { !$0.frame.isEmpty }, title)
      XCTAssertEqual(item.isEnabled, running, title)
    }
  }

  func testRunContextMenusControlTheirOwnTargets() throws {
    let app = launchedApp(runCommand: "trap : INT; while true; do sleep 1; done")
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15))
    let project = app.otherElements["sidebar.project.UITestProject"]
    if !project.exists { app.buttons["toolbar.toggleSidebar"].click() }
    XCTAssertTrue(project.waitForExistence(timeout: 10))

    // The project menu starts the root's run, even though the workroom was selected.
    project.rightClick()
    try assertRunMenu(app, running: false)
    try XCTUnwrap(app.hittableMenuItem(titled: "Run")).click()
    XCTAssertTrue(waitForRunState(app, "running"))

    let workroom = app.descendants(matching: .any)
      .matching(identifier: "sidebar.workroom.uitest-room").firstMatch
    workroom.rightClick()
    try assertRunMenu(app, running: false)
    try XCTUnwrap(app.hittableMenuItem(titled: "Run")).click()
    XCTAssertTrue(waitForRunState(app, "running"))

    // The workroom's shared context menu can restart its run in place.
    let titlebar = app.descendants(matching: .any)
      .matching(identifier: "workroom.pane.titlebar").firstMatch
    titlebar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).rightClick()
    try assertRunMenu(app, running: true)
    try XCTUnwrap(app.hittableMenuItem(titled: "Restart")).click()
    let restarting = app.staticTexts.matching(
      NSPredicate(format: "value == %@", "Run command Restarting…")
    ).firstMatch
    // Run starts in the background, so reveal it before reading its footer.
    runTabChip(app).click()
    XCTAssertTrue(restarting.exists, app.debugDescription)
    XCTAssertTrue(restarting.waitForNonExistence(timeout: 15))
    XCTAssertTrue(waitForRunState(app, "running"))

    runTabChip(app).rightClick()
    try assertRunMenu(app, running: true)
    try XCTUnwrap(app.hittableMenuItem(titled: "Stop")).click()
    XCTAssertTrue(waitForRunState(app, "stopped"))
    runTabChip(app).rightClick()
    try assertRunMenu(app, running: false)
    app.typeKey(.escape, modifierFlags: [])

    // Stopping the workroom did not stop the root's independently running command.
    project.rightClick()
    try assertRunMenu(app, running: true)
    app.typeKey(.escape, modifierFlags: [])
  }

  /// The sidebar hides idle controls and removes Stop when the command ends, with its tab kept.
  func testSidebarOnlyShowsRunControlWhileRunning() {
    // Keep running after INT so the supervisor's grace period leaves feedback observable.
    let app = launchedApp(runCommand: "trap : INT; while true; do sleep 1; done")
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15))
    let row = app.buttons.matching(identifier: "sidebar.workroom.uitest-room").firstMatch
    if !row.exists { app.buttons["toolbar.toggleSidebar"].click() }
    XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
    // The row's identifier propagates to its children, overriding the nested button's own id.
    let control = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier == %@ AND (label == %@ OR label == %@ OR label == %@)",
        "sidebar.workroom.uitest-room", "Start run command", "Stop run command",
        "Stopping run command")
    ).firstMatch
    XCTAssertFalse(control.exists, "an idle workroom has no sidebar run button")
    startRun(app)
    XCTAssertTrue(waitForRunState(app, "running"))
    XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(control.label, "Stop run command")
    runTabChip(app).click()
    control.click()
    XCTAssertTrue(control.exists, app.debugDescription)
    XCTAssertEqual(control.label, "Stopping run command", "sidebar acknowledges Stop immediately")
    XCTAssertEqual(
      runTabChip(app).value as? String, "stopping", "the run tab also updates immediately")
    let stopping = app.staticTexts.matching(
      NSPredicate(
        format: "value == %@ OR label == %@", "Run command Stopping…", "Run command Stopping…")
    ).firstMatch
    XCTAssertTrue(stopping.exists, app.debugDescription)
    XCTAssertTrue(waitForRunState(app, "stopped"), "the stopped run reports its state")
    XCTAssertTrue(control.waitForNonExistence(timeout: 5))
    XCTAssertTrue(runTabChip(app).exists, "the run terminal stays open after stopping")
  }

  /// A run that exits non-zero on its own surfaces the failed run icon (red xmark octagon).
  func testFailedRunShowsFailedIndicator() {
    let app = launchedApp(runCommand: "sleep 3; exit 7")
    startRun(app)
    // A run that never starts shows the same failed icon, so see this one running first.
    XCTAssertTrue(
      waitForRunState(app, "running"),
      "the run started; got \(runTabChip(app).value ?? "<nil>")")
    XCTAssertTrue(
      waitForRunState(app, "failed"),
      "a non-zero exit shows the failed run icon (#79); got \(runTabChip(app).value ?? "<nil>")")
  }

  /// A running run session keeps its daemon from idling out, and the runner cannot end either, so
  /// the app's own watcher must: once the app is gone, so are the run's command and the scratch
  /// directory (#533). The command outlives this test's wait unless something ends it.
  func testTheScratchDaemonIsGoneOnceTheAppQuits() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestRunCommand", "sleep 60"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    let scratch = app.useScratchDaemon()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    startRun(app)
    XCTAssertTrue(app.buttons["runCommand.stop"].waitForExistence(timeout: 15), "the run started")
    // The run supervisor writes "running <pid>" into its status file in the scratch directory.
    var command: pid_t = 0
    XCTAssertTrue(
      poll(timeout: 10) {
        command = Self.runningPid(in: scratch + "/workroomd.runs") ?? 0
        return command > 0
      }, "the run's daemon lives in \(scratch)")

    app.terminate()
    XCTAssertTrue(
      poll(timeout: 15) { kill(command, 0) != 0 }, "the app's exit left its run \(command) running")
    XCTAssertTrue(
      poll(timeout: 5) { !FileManager.default.fileExists(atPath: scratch) },
      "the app's exit left its scratch directory behind: \(scratch)")
  }

  private static func runningPid(in runs: String) -> pid_t? {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: runs)) ?? []
    for file in files where file.hasSuffix(".status") {
      let line = (try? String(contentsOfFile: runs + "/" + file, encoding: .utf8)) ?? ""
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.first == "running", fields.count > 1, let pid = pid_t(fields[1]) { return pid }
    }
    return nil
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
