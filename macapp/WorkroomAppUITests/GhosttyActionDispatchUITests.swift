import XCTest

/// Baseline coverage for `GhosttyRuntimeAdapter.handleAction` — the one switch every libghostty
/// apprt action funnels through.
///
/// **Why this exists.** Fourteen tags reach that switch and, before this file, not one had a test
/// asserting the app reacts. What coverage existed sat *beside* it (`TerminalActivityMapperTests`
/// maps a notification payload; `TerminalSearchTests` folds search state) or observed a side
/// channel: `RunStatusUITests` asserts the run supervisor's status FILE, which
/// `AppStore.markRunExited` deliberately prefers over libghostty's payload — so it passes even if
/// `COMMAND_FINISHED` never arrives. The dispatch layer's only real detector was a human walking
/// `QA-libghostty.md`.
///
/// That is a bad trade for a dependency we upgrade: an action that stops arriving fails SILENTLY —
/// no crash, no red test, just a title that stops updating or a spinner that never stops. These
/// tests were written deliberately against the CURRENT engine, BEFORE the pin bump (see "Bump the
/// libghostty pin" in TODOS.md), so they record known-good behaviour. Written after the bump they
/// would encode whatever the new engine does as correct and could never detect a regression.
///
/// **What these do NOT test, and why:**
///   - `GHOSTTY_ACTION_RING_BELL` calls `NSSound.beep()`, which produces audio and no UI. XCUITest
///     cannot observe it, and adding a fixture-only counter to prove it would test the counter.
///     It stays manual QA (`QA-libghostty.md` §G) — where it belongs, and where it was caught the
///     one time it shipped silent.
///   - `SEARCH_TOTAL` / `SEARCH_SELECTED`. Attempted and PARKED, not forgotten — see
///     "Finish the action-dispatch UI coverage" in TODOS.md for what was learned (the find bar
///     does open from `Edit ▸ Find…`; the needle never reaches the field under XCUITest, so the
///     counter stays at its empty-needle state).
///   - A test asserting a tag's RAW VALUE would be tautological: the test target and the app import
///     the same `ghostty.h`, so the mid-enum insert that renumbers tags can never fail it. Only
///     observable side effects catch that class of change. Do not add one.
///
/// Each test drives a REAL terminal in the fixture workroom (a temp dir) and emits the escape
/// sequence from the shell, so the whole path is exercised: PTY → libghostty parse → `action_cb` →
/// `handleAction` → `GhosttySurfaceView` → `TerminalSessions` → SwiftUI.
final class GhosttyActionDispatchUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// One terminal tab, no run command — the run tab's own chip would otherwise compete with the
  /// tab-title and busy assertions below.
  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// Focus the terminal so keystrokes reach the PTY.
  ///
  /// Clicks the TAB CHIP, not `terminal.pane` — the same handle `RunStatusUITests` uses. The pane
  /// group is an accessibility CONTAINER (`PaneTreeView` sets `.accessibilityElement(children:
  /// .contain)`) and clicking it does not hand first responder to the surface; the surface itself is
  /// an `NSViewRepresentable`, Metal-rendered, and exposes nothing queryable (that gap IS CMT-3).
  /// Verified by probe: after this click, a typed `touch` really does create its file on disk.
  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    let chip = anyTabChip(app)
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    // The click lands before the surface is first responder; without a beat the first keystrokes
    // are dropped and the failure looks like "the engine didn't report", which is a lie.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  /// The first terminal tab chip, whatever it is currently titled.
  ///
  /// Queried by PREFIX rather than by name, because the title is not stable by design: ghostty's
  /// shell integration retitles the tab per command (issue #2), so any test that pins an exact
  /// title is testing the shell's prompt, not the app.
  private func anyTabChip(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .firstMatch
  }

  /// Type a shell line and run it. Typed as text (not `typeKey`) so the shell's own `printf`
  /// produces the escape bytes — XCUITest cannot type an ESC into a PTY directly.
  private func run(_ app: XCUIApplication, _ line: String) {
    app.typeText(line + "\r")
  }

  // MARK: GHOSTTY_ACTION_SET_TITLE

  /// A running command retitles the tab (issue #2). Proves `SET_TITLE` → `handleTitleChange` →
  /// `TerminalSessions.updateTitle` → `tab.liveTitle` → the chip identifier.
  ///
  /// Driven through shell integration (which emits OSC 0/2 per command) rather than a hand-written
  /// `printf '\033]0;…'`: a hand-set title IS delivered, but the shell's own prompt sequence
  /// overwrites it a few milliseconds later, so asserting on it tests the race, not the dispatch.
  /// Measured, not assumed — an earlier version of this test failed for exactly that reason.
  func testRunningCommandRetitlesTheTabChip() {
    let app = launchedApp()
    focusTerminal(app)
    run(app, "sleep 6")

    let titled = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.sleep"))
      .firstMatch
    XCTAssertTrue(
      titled.waitForExistence(timeout: 20),
      "the running command reached GHOSTTY_ACTION_SET_TITLE and renamed the tab")
  }

  // MARK: GHOSTTY_ACTION_PROGRESS_REPORT

  /// OSC 9;4 drives the tab's busy state (issue #28). The chip's accessibility VALUE is the only
  /// non-visual carrier of it — the underline is drawn, not announced.
  ///
  /// Asserts both edges: state 1 (set) marks it busy, state 0 (remove) clears it. The clear half
  /// matters more — a spinner that never stops is the symptom users actually report. The chip is
  /// queried by identifier PREFIX because the title moves under us as commands run.
  func testOSCProgressReportMarksTheTabBusyThenIdle() {
    let app = launchedApp()
    focusTerminal(app)
    let chip = anyTabChip(app)
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the tab is addressable")

    // Both edges inside ONE command line, deliberately. `TerminalSessions.handleCommandFinished`
    // clears `progressActive` the moment a command exits ("so the indicator stops the moment the
    // command exits") — so a one-shot `printf` would set the state and have it cleared by its own
    // completion, and the test would pass or fail on a race rather than on the action. Holding the
    // shell inside `sleep` keeps the command open across both assertions, so what is observed is
    // OSC 9;4 itself. (Measured: the one-shot form failed exactly this way.)
    run(app, #"printf '\033]9;4;1;50\007'; sleep 5; printf '\033]9;4;0;0\007'; sleep 5"#)
    XCTAssertTrue(
      waitForValue(chip, "Busy"),
      "OSC 9;4 state 1 reached GHOSTTY_ACTION_PROGRESS_REPORT and marked the tab busy")
    XCTAssertTrue(
      waitForValue(chip, "Idle"),
      "OSC 9;4 state 0 (remove) cleared the busy state — a stuck spinner is the reported symptom")
  }

  // MARK: Waiters

  /// XCUITest has no built-in "wait for this value", and polling a value is unavoidable here: the
  /// state changes arrive from the engine's own thread via `ghostty_app_tick`, not from a UI event
  /// we drove, so there is nothing to `waitForExistence` on.
  private func waitForValue(
    _ element: XCUIElement, _ expected: String, timeout: TimeInterval = 15
  ) -> Bool {
    poll(timeout: timeout) { (element.value as? String) == expected }
  }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }
}
