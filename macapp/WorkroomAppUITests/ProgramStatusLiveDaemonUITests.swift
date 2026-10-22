import XCTest

/// Program status (#358) end to end, through a REAL `workroomd`: the fixture's terminals attach
/// through a scratch agent of their own (`-WorkroomUITestLiveDaemon`, so no agent, session or config
/// of the developer's is touched), and `testdata/program-status/mock-claude-code.sh` plays back
/// what Claude Code sends. So this covers what the seeded `ProgramStatusUITests` cannot: the probe
/// answered by the agent, the service, the app's subscription, the monitor, the indicators, the
/// "needs you" alert, Claude's own alert folded into it, and ⇧⌘M.
///
/// Banners in Notification Center are not assertable here (another process, behind a permission
/// prompt); the in-app alert stands in for them.
///
/// The runner cannot spawn a process, and `terminate()` does not run the app's quit path, so the
/// test ends its own shells before quitting: with no session left, the scratch agent idles out.
final class ProgramStatusLiveDaemonUITests: XCTestCase {
  private var app: XCUIApplication!
  private let scratch = "/tmp/wr-ps-\(UUID().uuidString.prefix(8))"
  private let mock = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("testdata/program-status/mock-claude-code.sh").path

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalTabs", "2"]
    app.launchArguments += ["-WorkroomUITestLiveDaemon", scratch]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
  }

  override func tearDown() {
    // End the scratch agent from a shell it runs (the shell's parent), its sessions with it, a few
    // seconds after the app has quit: exiting the shells is not enough (the app opens a fresh
    // terminal when the last closes), and a live app would start the agent again. The shell also
    // removes the scratch directory, which the runner may not.
    if chips.count > 0 {
      chip(0).click()
      app.typeKey("c", modifierFlags: .control)
      app.typeText(
        "p=$PPID; nohup sh -c \"sleep 3; kill $p; sleep 1; rm -rf '\(scratch)'\" >/dev/null 2>&1 &")
      app.typeText("\r")
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    app?.terminate()
    super.tearDown()
  }

  /// The terminal chips, by position, not title: a live shell renames its chip as it runs. Only
  /// the chip's text: its small close button carries the same identifier.
  private var chips: XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func chip(_ index: Int) -> XCUIElement { chips.element(boundBy: index) }

  private func chipDump() -> String {
    app.debugDescription.split(separator: "\n")
      .filter { $0.contains("terminal.tab") || $0.contains("Terminal") }.joined(separator: "\n")
  }

  private func surface() -> XCUIElement {
    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))
    return surface
  }

  /// Anything on screen whose spoken label contains `text`: an in-app alert's row or toast.
  private func labelled(_ text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }

  /// A "needs you" alert, toast or row: named by the terminal's own name and its workroom, never
  /// the title its program set (the chip now shows the running command).
  private var needsYouAlert: XCUIElement { labelled("Terminal 1 in uitest-room needs you") }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// Focus Terminal 1 and prove its shell runs (through the agent) before typing into it.
  private func readyTerminalOne() {
    app.activate()
    let one = chip(0)
    XCTAssertTrue(one.waitForExistence(timeout: 20), "the fixture has two terminals")
    one.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    // Return in its own call (see `GhosttyOrphanShellUITests.run`).
    app.typeText("echo WRREADY$((1+1))")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
    XCTAssertTrue(
      poll(timeout: 30) { ((surface().value as? String) ?? "").contains("WRREADY2") },
      "Terminal 1's shell never came up through the scratch agent")
  }

  /// Start the mock in the focused terminal: it probes (the agent answers), works for two steps,
  /// then waits on a permission request for `hold` seconds, with Claude's own alert 1 s in.
  private func startMock(hold: Int) {
    app.typeText("MOCK_STEP=2 MOCK_HOLD=\(hold) MOCK_ALERT_DELAY=1 sh '\(mock)' --auto")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
  }

  /// A program waiting in a terminal you are not looking at: its chip and workroom say so, one
  /// in-app alert says "Terminal 1 in uitest-room needs you", Claude's own alert is folded into it rather than
  /// shown again, ⇧⌘M goes there (which reads the alert), and the finished turn shows while you
  /// watch it.
  func testAWaitingProgramElsewhereAlertsOnceAndShiftCommandMGoesThere() {
    readyTerminalOne()
    startMock(hold: 20)
    // Look elsewhere before the request arrives (about 5 s in).
    chip(1).click()
    XCTAssertTrue(poll(timeout: 3) { chip(1).isSelected })

    let one = chip(0)
    XCTAssertTrue(
      poll(timeout: 30) { (one.value as? String) == "Waiting for your permission" },
      "Terminal 1 never reported waiting: got \(one.value ?? "<nil>"); chips: \(chipDump())")
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label == %@", "1 terminal needs you")).firstMatch
        .waitForExistence(timeout: 5),
      "the workroom row does not count the waiting terminal")
    XCTAssertTrue(
      needsYouAlert.waitForExistence(timeout: 10),
      "no in-app alert for the waiting terminal")
    // The mock's own OSC 777 alert lands 1 s after its report: folded in, never a second entry.
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    XCTAssertFalse(
      labelled("Claude Code").exists,
      "the program's own alert was shown as well as Workroom's")

    app.typeKey("m", modifierFlags: [.command, .shift])
    XCTAssertTrue(poll(timeout: 5) { one.isSelected }, "⇧⌘M did not go to the waiting terminal")
    XCTAssertTrue(
      poll(timeout: 5) { !needsYouAlert.exists },
      "looking at the terminal did not read its alert")

    // The request resolves on its own (`--auto`), and the turn finishes while it has focus.
    XCTAssertTrue(
      poll(timeout: 40) { (one.value as? String) == "Turn finished" },
      "the finished turn never showed: got \(one.value ?? "<nil>")")
  }

  /// The same request in the terminal you are looking at shows on its chip but raises no alert,
  /// and the program's own alert is dropped as any focused terminal's is.
  func testAWaitingProgramInTheFocusedTerminalRaisesNoAlert() {
    readyTerminalOne()
    startMock(hold: 15)
    let one = chip(0)
    XCTAssertTrue(
      poll(timeout: 30) { (one.value as? String) == "Waiting for your permission" },
      "Terminal 1 never reported waiting: got \(one.value ?? "<nil>")")
    RunLoop.current.run(until: Date().addingTimeInterval(4))
    XCTAssertFalse(needsYouAlert.exists, "an alert for the focused terminal")
    XCTAssertFalse(labelled("Claude Code").exists, "the program's own alert in a focused terminal")
  }
}
