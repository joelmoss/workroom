import XCTest

/// The OSC 52 / paste confirmation prompt (`GhosttyRuntimeAdapter.confirmReadClipboard`), driven
/// against a REAL PTY.
///
/// Worth a UI test rather than a unit test because the bug this replaced was invisible from the
/// inside: `confirmReadClipboard` was an empty stub, and libghostty routes BOTH an unsafe paste and
/// an `ask`-gated OSC 52 read through it, so both were silently dropped — no error, no log, nothing
/// on screen. Only driving a real terminal shows the difference between "denied" and "the app
/// forgot to answer". The unit tests next door (`ClipboardConfirmationCopyTests`) cover the wording;
/// these cover that the prompt appears at all, that Return doesn't approve it, and that allowing a
/// paste actually delivers it.
final class ClipboardConfirmationUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// One terminal tab, no run command — a run tab would compete for the surface we drive.
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

  private func surface(_ app: XCUIApplication) -> XCUIElement {
    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))
    return surface
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

  /// **The regression this suite exists for.** An application asking to read the clipboard over
  /// OSC 52 must produce a prompt. `clipboard-read` defaults to `ask`, so before the fix the engine
  /// asked us to confirm, the stub said nothing, and the request was dropped in silence.
  ///
  /// Also pins the security property that makes the prompt worth having: it drops in front of
  /// someone who is TYPING, so Return must not approve it.
  func testOSC52ReadPromptsAndReturnDoesNotApproveIt() {
    let app = launchedApp()
    focusTerminal(app)
    _ = surface(app)

    // OSC 52, clipboard "c", payload "?" — the read request.
    app.typeText("printf '\\033]52;c;?\\007'\r")

    let sheet = app.sheets.firstMatch
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 15),
      "an OSC 52 read produced no confirmation — it is being dropped in silence again")

    let allow = sheet.buttons["Allow"]
    let deny = sheet.buttons["Deny"]
    XCTAssertTrue(allow.exists, "the prompt must offer a way to allow")
    XCTAssertTrue(deny.exists, "the prompt must offer a way to refuse")

    // Return must NOT authorize. If the allow button keeps AppKit's default key equivalent, the next
    // Return of an ongoing typing burst silently hands the clipboard over.
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertTrue(
      sheet.exists,
      "Return dismissed the clipboard prompt — it must not be the default action, or a user typing "
        + "into the terminal will approve clipboard access without reading it")

    // Escape must refuse. AppKit only wires Escape up on its own for a button titled "Cancel", so
    // "Deny" needs an explicit key equivalent — without it the prompt has a mouse-only way out, and
    // the reflex that dismisses every other macOS sheet does nothing here.
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(
      waitForSheetToGoAway(sheet),
      "Escape did not dismiss the clipboard prompt — refusing must not require the mouse")
  }

  /// The other half of the same stub bug, and the one a user would actually hit: paste protection
  /// (`clipboard-paste-protection`, on by default) flags a multi-line paste into a program with no
  /// bracketed-paste mode. Before the fix the paste was silently swallowed — nothing arrived and
  /// nothing said why. Allowing it must actually deliver the text.
  func testUnsafePastePromptsAndAllowingItDeliversTheText() {
    let app = launchedApp()
    focusTerminal(app)
    let surface = surface(app)

    // `cat` echoes what it receives and — unlike the shell's line editor — never turns bracketed
    // paste on, which is what makes a multi-line paste "unsafe" to the engine.
    app.typeText("cat\r")
    RunLoop.current.run(until: Date().addingTimeInterval(1))

    let marker = "WRPASTE7c1e"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("\(marker)\nsecond line\n", forType: .string)

    app.typeKey("v", modifierFlags: .command)

    let sheet = app.sheets.firstMatch
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 15),
      "a multi-line paste into `cat` produced no confirmation — paste protection is dropping it")

    sheet.buttons["Paste"].click()
    XCTAssertTrue(waitForSheetToGoAway(sheet), "the prompt stayed up after Paste")

    let landed = waitForScreen(surface, containing: marker)
    XCTAssertTrue(
      landed.found,
      """
      the paste was confirmed but never reached the terminal — allowing the prompt must complete \
      the engine's request, not just dismiss the sheet. Screen was:
      \(landed.screen)
      """)

    // Leave `cat` so the fixture terminal isn't left holding the PTY.
    app.typeKey("d", modifierFlags: .control)
  }

  private func waitForSheetToGoAway(_ sheet: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !sheet.exists { return true }
      usleep(250_000)
    }
    return false
  }
}
