import XCTest

/// The typing marker (#696): when another session types into a pane, the pane shows who and from
/// which tab, and the marker goes 3 s after the last keystroke. Run in the VM, this class only
/// (`make app-uitest-vm`).
///
/// The first test drives the whole path through a REAL `workroomd` of its own
/// (`-WorkroomUITestLiveDaemon`, so no daemon, session or config of the developer's is touched):
/// Terminal 2 runs `workroomd send` into Terminal 1 under a shell function named `claude`, whose
/// title the app recognises as Claude, and the daemon's `session.input` event reaches the app's
/// subscription and Terminal 1's marker. The second captures the marker, seeded with no daemon,
/// in light and dark, with Glass off and on, for a reviewer.
final class PaneTypingMarkerUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  private var marker: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "terminal.typingMarker").firstMatch
  }

  /// The terminal chips, by position: a live shell renames its chip as it runs. Only the chip's
  /// text: its small close button carries the same identifier.
  private func chip(_ index: Int) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .element(boundBy: index)
  }

  private func surface() -> XCUIElement {
    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))
    return surface
  }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }

  /// Types `line` into the focused terminal and presses Return in its own call (see
  /// `GhosttyOrphanShellUITests.run`).
  private func run(_ line: String) {
    app.typeText(line)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
  }

  /// Focuses terminal `index` and proves its shell runs, through the daemon, before typing on.
  private func ready(_ index: Int, then line: String = "") {
    let tab = chip(index)
    XCTAssertTrue(tab.waitForExistence(timeout: 20), "the fixture has two terminals")
    tab.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let probe = "WRREADY\(index)$((1+1))"
    run(line.isEmpty ? "echo \(probe)" : "\(line); echo \(probe)")
    XCTAssertTrue(
      poll(timeout: 30) {
        ((surface().value as? String) ?? "").contains("WRREADY\(index)2")
      }, "Terminal \(index + 1)'s shell never came up through the scratch daemon")
  }

  /// Claude, in Terminal 2, types into Terminal 1: Terminal 1 shows "Claude · tab 2", says so in
  /// its tooltip and to VoiceOver, and the marker is gone 3 s after the keystroke and not before.
  func testAnotherPaneTypingShowsWhoAndFromWhichTabUntilThreeSecondsAfter() {
    app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalTabs", "2"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    let directory = app.useScratchDaemon()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    app.activate()

    // Terminal 1's session id, where Terminal 2 can read it: every pane's shell has its own in
    // `WORKROOM_PANE` (#684).
    ready(0, then: "echo $WORKROOM_PANE > \(directory)/pane-one")
    XCTAssertFalse(marker.exists, "nobody has typed into Terminal 1 yet")

    // Terminal 2: the bundled daemon binary (an ancestor of every pane's shell) is the `workroom`
    // command (`main.rs` gives it every CLI subcommand), and `$WORKROOM_DAEMON` names its socket.
    // `claude` is a shell function, so the app recognises Claude from the title the shell sets
    // for it, as for the real one; it waits long enough for the test to look at Terminal 1.
    ready(
      1,
      then: "p=$PPID; while [ \"$p\" -gt 1 ]; do c=$(ps -o comm= -p $p); "
        + "case $c in */workroomd) W=$c; break;; esac; p=$(ps -o ppid= -p $p | tr -d ' '); done; "
        + "claude() { sleep 4; \"$W\" send \"$(cat \(directory)/pane-one)\" 'echo typed-by-claude'"
        + " || echo SENDFAILED; sleep 5; }")
    // Before `claude` starts, so the 4 s it waits before sending all fall after this.
    let started = Date()
    run("claude")
    chip(0).click()

    XCTAssertTrue(
      marker.waitForExistence(timeout: 20),
      "Terminal 1 never showed who was typing into it: \(app.debugDescription.prefix(2000))")
    XCTAssertEqual(marker.label, "Claude in tab 2 is typing into this pane.")

    XCTAssertTrue(poll(timeout: 20) { !marker.exists }, "the marker never went")
    // The send went at least 4 s after `started`, and the marker lasts 3 s after it.
    XCTAssertGreaterThanOrEqual(
      Date().timeIntervalSince(started), 7,
      "the marker went before 3 s had passed since the send")
    XCTAssertTrue(
      poll(timeout: 10) {
        ((surface().value as? String) ?? "").contains("echo typed-by-claude")
      }, "the send never reached Terminal 1")
  }

  /// The marker over a pane in each appearance, for a reviewer: light and dark, Glass off and at
  /// 85%. Seeded with no daemon (`-WorkroomUITestTypingMarker`), so it shows for as long as the
  /// capture takes.
  func testTheMarkerInEachAppearance() {
    for (appearance, glass) in [("light", "1"), ("light", "0.85"), ("dark", "1"), ("dark", "0.85")]
    {
      app = XCUIApplication()
      app.launchArguments += ["-WorkroomUITestFixture", "1"]
      app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
      app.launchArguments += ["-WorkroomUITestTypingMarker", "1"]
      app.launchArguments += ["-WorkroomUITestGlassOpacity", glass]
      app.launchArguments += ["-themePreference", appearance]
      app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
      app.launch()
      app.activate()
      XCTAssertTrue(marker.waitForExistence(timeout: 20), "no marker (\(appearance), \(glass))")
      // Polled: a keystroke the fixture sends before the window is registered names a terminal
      // no window has open, until the next one, a second later.
      XCTAssertTrue(
        poll(timeout: 5) { marker.label == "Claude in tab 2 is typing into this pane." },
        "the marker reads \(marker.label)")
      // Past the fade-in.
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      let name = "\(appearance), Glass \(glass == "1" ? "off" : "85%")"
      for (shot, suffix) in [
        (XCUIScreen.main.screenshot(), "screen"), (marker.screenshot(), "marker"),
      ] {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "Typing marker, \(name), \(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      app.terminate()
    }
  }
}
