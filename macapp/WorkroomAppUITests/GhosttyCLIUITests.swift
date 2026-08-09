import XCTest

/// The one assumption the `ghostty` symlink design rests on, asserted against a real terminal.
///
/// `Contents/MacOS/ghostty` is a relative symlink to the app binary, and Ghostty's bundled shell
/// integration finds it through `GHOSTTY_BIN_DIR` — which **the engine sets itself**, from the
/// running executable's directory (`src/termio/Exec.zig`). Nothing in the app writes that variable.
/// So the whole mechanism hangs on an engine behaviour we do not control and cannot see from a unit
/// test: `GhosttyCLITests` runs the binary directly, which proves dispatch works but says nothing
/// about whether a *shell* can find it.
///
/// If a pin bump changes how that path is derived, `ssh-terminfo` users silently go back to
/// re-pushing terminfo on every connect. No error, no log — `Resources/ghostty/SOURCE.md` calls
/// silent degradation this directory's whole failure mode, and the pin bump is the next thing on the
/// roadmap. This test is the tripwire for exactly that.
///
/// Metal-rendered surfaces are invisible to XCUITest, so assertions read `terminal.surface`'s
/// fixture-only accessibility value (the visible viewport — see
/// `GhosttySurfaceView.accessibilityValue`).
final class GhosttyCLIUITests: XCTestCase {
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

  /// Focus the terminal so keystrokes reach the PTY. Clicks the TAB CHIP, not the pane: the pane is
  /// an accessibility container and clicking it does not hand first responder to the surface. Same
  /// handle `GhosttyActionDispatchUITests` uses, for the same reason.
  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    // The click lands before the surface is first responder; without a beat the first keystrokes are
    // dropped and the failure reads as "the engine didn't report", which is a lie.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  /// Wait for `needle` to appear in the visible viewport, returning the last screen read either way.
  ///
  /// Polled by hand rather than with `XCTNSPredicateExpectation`, which re-evaluates against a
  /// cached element snapshot and does not observe this value changing — the same trap
  /// `AgentResumeUITests` documents.
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

  /// Three questions, one app launch — a fixture launch costs ~15s and they share all of its setup.
  /// Each assertion carries its own message so a failure still says which link in the chain broke:
  ///
  ///   1. does the engine point `GHOSTTY_BIN_DIR` at our bundle?
  ///   2. is the symlink reachable as a bare `ghostty` on the pane's PATH? (the engine appends
  ///      `GHOSTTY_BIN_DIR` to PATH; if that ever stops, the shadowing note in SOURCE.md is wrong
  ///      but nothing else breaks — the shell integration uses the absolute path)
  ///   3. can a shell actually dispatch an action through it?
  func testBinDirResolvesToBundle() {
    let app = launchedApp()
    focusTerminal(app)

    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))

    // Markers are deliberately distinguishable from the command line that echoes them: the typed
    // text contains `$GHOSTTY_BIN_DIR`, only the OUTPUT contains an expanded path.
    app.typeText("echo \"WRBINDIR=[$GHOSTTY_BIN_DIR]\"\r")
    let bindir = waitForScreen(surface, containing: "WRBINDIR=[/")
    XCTAssertTrue(
      bindir.found,
      """
      GHOSTTY_BIN_DIR was empty in a real pane. The engine derives it from the running \
      executable's path, so this is the assumption the ghostty symlink design rests on. If it is \
      genuinely gone, inject it via GhosttySurfaceView's config.env_vars instead. Screen was:
      \(bindir.screen)
      """)
    XCTAssertTrue(
      bindir.screen.contains("Contents/MacOS"),
      """
      GHOSTTY_BIN_DIR should point at the app bundle's Contents/MacOS, where the ghostty symlink \
      lives. Screen was:
      \(bindir.screen)
      """)

    app.typeText("command -v ghostty && echo WRWHICH=yes || echo WRWHICH=no\r")
    let which = waitForScreen(surface, containing: "WRWHICH=")
    XCTAssertTrue(which.found, "the `command -v ghostty` probe produced no output")
    XCTAssertTrue(
      which.screen.contains("WRWHICH=yes"),
      """
      `ghostty` did not resolve on the pane's PATH. Not fatal — shell integration calls it by \
      absolute path — but it means the PATH-shadowing note in Resources/ghostty/SOURCE.md and \
      macapp/CLAUDE.md is wrong and should be removed. Screen was:
      \(which.screen)
      """)

    // Isolated state: a test must never read or write the developer's own ssh terminfo cache.
    app.typeText(
      "XDG_STATE_HOME=$(mktemp -d) \"$GHOSTTY_BIN_DIR/ghostty\" +ssh-cache >/dev/null 2>&1; "
        + "echo WRRC=$?\r")
    let dispatch = waitForScreen(surface, containing: "WRRC=")
    XCTAssertTrue(dispatch.found, "the +ssh-cache probe produced no output")
    XCTAssertTrue(
      dispatch.screen.contains("WRRC=0"),
      """
      A shell could not dispatch `+ssh-cache` through $GHOSTTY_BIN_DIR/ghostty. This is exactly \
      what Ghostty's shell integration does on every ssh, so ssh-terminfo is broken. Screen was:
      \(dispatch.screen)
      """)
  }
}
