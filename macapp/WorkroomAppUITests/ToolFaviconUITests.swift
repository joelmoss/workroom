import XCTest

/// End-to-end coverage for the tab-chip tool favicon (issue #141). Drives a REAL command through a
/// real shell (shell integration, OSC 0/2, the real `foregroundExecutableName` PID resolution) rather than a
/// hand-set/synthetic fixture, for the same reason `GhosttyActionDispatchUITests` does: a synthetic
/// signal doesn't prove the real detection pipeline fires end-to-end.
final class ToolFaviconUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    let chip = anyTabChip(app)
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  private func anyTabChip(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .firstMatch
  }

  private func run(_ app: XCUIApplication, _ line: String) {
    app.typeText(line + "\r")
  }

  /// XCUITest has no built-in "wait for this label"; polling is unavoidable since the title/tool
  /// arrive from the engine's own callback thread, not from a UI event this test drove.
  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// `git status; sleep 8` (not a bare `git status`) is deliberate — `git status` alone usually exits
  /// before XCUITest can observe the recognized-tool state, the exact failure mode
  /// `testOSCProgressReportMarksTheTabBusyThenIdle` already measured and worked around by holding the
  /// shell open. One shell-integration command line, so the tab latches "git" for the whole duration.
  ///
  /// Asserted via the chip's accessibility LABEL, not a separate identifier on the favicon `Image`
  /// itself: the chip already carries its own `.accessibilityIdentifier`/`.accessibilityValue`, and a
  /// container with an explicit accessibility modifier auto-combines its children into ONE element —
  /// a leaf `.accessibilityIdentifier` on a plain (non-interactive) `Image` is unreachable (measured:
  /// the model-layer detection and the bundled image asset both resolve correctly, but XCUITest never
  /// found the element). `TerminalTabStrip.swift` folds the recognized tool into the chip's own
  /// `.accessibilityLabel` for exactly this reason.
  func testRecognizedToolShowsInChipLabelThenClearsOnCommandFinish() {
    let app = launchedApp()
    focusTerminal(app)
    let chip = anyTabChip(app)
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the tab is addressable")

    run(app, "git status; sleep 8")

    XCTAssertTrue(
      poll(timeout: 20, until: { chip.label.contains("Git") }),
      "the recognized tool appeared in the chip's label; got \(chip.label)")

    XCTAssertTrue(
      poll(timeout: 20, until: { !chip.label.contains("Git") }),
      "the recognized tool clears once command_finished fires; got \(chip.label)")
  }
}
