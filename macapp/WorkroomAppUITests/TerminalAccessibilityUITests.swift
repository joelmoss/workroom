import XCTest

/// **CMT-3's safety precondition, checked before the feature ships.** Exposing terminal content to
/// the accessibility tree (`GhosttySurfaceView.accessibilityValue`/`accessibilitySelectedText`) is
/// only safe if it exposes exactly what a sighted user's own copy/select already exposes — never
/// more. The concrete risk: a password prompt with local echo disabled (`read -s`, `ssh`'s passphrase
/// prompt) must render NOTHING for the typed characters, so there is nothing for an accessibility
/// client to read that a shoulder-surfer couldn't already see on screen.
///
/// Verified here against a REAL PTY and a REAL `read -s`, not by reasoning about terminal semantics —
/// the same empirical standard `GhosttyCLIUITests` and `AgentResumeUITests` hold the engine to.
final class TerminalAccessibilityUITests: XCTestCase {
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

  /// Focus the terminal so keystrokes reach the PTY. Clicks the TAB CHIP, not the pane — see
  /// `GhosttyCLIUITests.focusTerminal` for why.
  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  @discardableResult
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

  /// **The check that gates CMT-3.** `read -s` disables local echo at the TTY level, so the terminal
  /// never renders the typed characters at all — there is nothing on screen for `accessibilityValue`
  /// (or copy/select) to expose. If this ever fails, a secret typed into any password-style prompt
  /// would leak through the accessibility tree, and CMT-3's production wiring must not ship as-is.
  func testPasswordPromptWithEchoDisabledRendersNoTypedCharacters() {
    let app = launchedApp()
    focusTerminal(app)

    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))

    // `stty -echo` + plain `read`, not `read -s`/`read -p`: zsh's `-p` means "read from a coprocess,"
    // not "show a prompt" (bash-only flag), so this is written to be shell-agnostic. Deliberately
    // never echoes `$x` back — the point is that the secret must not render ANYWHERE on screen, so
    // nothing here prints it on purpose either. `WRDONE` alone proves the prompt completed, echo was
    // restored, and the shell moved on.
    let secret = "WRSECRET9f3a"
    app.typeText("echo -n 'WRPROMPT: '; stty -echo; read x; stty echo; echo; echo WRDONE\r")
    waitForScreen(surface, containing: "WRPROMPT:")
    app.typeText("\(secret)\r")

    let done = waitForScreen(surface, containing: "WRDONE")
    XCTAssertTrue(done.found, "the prompt never completed — screen was:\n\(done.screen)")
    XCTAssertFalse(
      done.screen.contains(secret),
      """
      a secret typed at a `read -s` prompt appeared in the rendered viewport — echo-disabled input \
      must never reach the screen, so exposing that screen via accessibilityValue would leak it. \
      Screen was:
      \(done.screen)
      """)
  }
}
