import XCTest

/// A UI-test launch gives its terminals Ghostty's real zsh integration and none of the developer's
/// rc files (issue #268), asserted against a real terminal.
///
/// `UITestFixtureHermeticShellTests` pins the seam's decisions in a unit test; this is the only
/// place that can see what an actual pane received. It also carries the check that goes red when
/// the seam stops working: with `WorkroomApp.init`'s `applyHermeticShell()` call removed, `$ZDOTDIR`
/// is empty here and the first assertion fails.
///
/// Metal-rendered surfaces are invisible to XCUITest, so assertions read `terminal.surface`'s
/// fixture-only accessibility value (the visible viewport — see
/// `GhosttySurfaceView.accessibilityValue`).
final class TerminalHermeticShellUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// One terminal tab, no run command — a run tab would compete for the surface we read.
  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// Focus the terminal so keystrokes reach the PTY. Clicks the TAB CHIP, not the pane, for the
  /// reason `GhosttyCLIUITests` documents.
  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  /// Wait for `needle` in the visible viewport, returning the last screen read either way. Polled by
  /// hand for the reason `GhosttyCLIUITests.waitForScreen` documents.
  private func waitForScreen(
    _ surface: XCUIElement, containing needle: String, timeout: TimeInterval = 30
  ) -> (found: Bool, screen: String) {
    var screen = ""
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      screen = (surface.value as? String) ?? ""
      if screen.contains(needle) { return (true, screen) }
      usleep(250_000)
    }
    return (false, screen)
  }

  func testTerminalGetsHermeticShellWithGhosttyIntegration() {
    let app = launchedApp()
    focusTerminal(app)

    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))

    // The typed text contains `$ZDOTDIR` and `$(whence …)`; only the OUTPUT has them expanded, so
    // waiting for `WRPRE=[_ghostty` cannot match the echoed command line.
    app.typeText(
      "echo \"WRZ=[$ZDOTDIR] WRS=[$SHELL] WRPRE=[$(whence -w _ghostty_precmd)]\"\r")
    let result = waitForScreen(surface, containing: "WRPRE=[_ghostty")
    XCTAssertTrue(result.found, "the probe produced no output. Screen was:\n\(result.screen)")

    XCTAssertTrue(
      result.screen.contains("workroom-tests-zdotdir-"),
      """
      $ZDOTDIR was not the hermetic folder, so this pane read the developer's real rc files. \
      Screen was:
      \(result.screen)
      """)
    XCTAssertTrue(
      result.screen.contains("WRS=[/bin/zsh]"),
      "the pane's shell was not the hermetic /bin/zsh. Screen was:\n\(result.screen)")
    XCTAssertTrue(
      result.screen.contains("_ghostty_precmd: function"),
      """
      Ghostty's zsh integration did not load under the redirected ZDOTDIR, which is the reason \
      this uses zsh and a ZDOTDIR rather than /bin/sh. Screen was:
      \(result.screen)
      """)
  }
}
