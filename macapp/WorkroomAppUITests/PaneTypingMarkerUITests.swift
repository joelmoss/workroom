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

  /// What VoiceOver reads of the marker, the tooltip's sentence: its description, which XCUITest
  /// may hand over as the element's value instead.
  private var said: String {
    let label = marker.label
    return label.isEmpty ? (marker.value as? String ?? "") : label
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

    // Terminal 2: the daemon's bin folder's `workroom`, its own build, which every pane has
    // (#695), and `$WORKROOM_DAEMON` names its socket. The daemon runs as a copy of the bundled
    // binary, so no ancestor's name says which it is. `claude` is a shell function, so the app
    // recognises Claude from the title the shell sets for it, as for the real one; it waits long
    // enough for the test to look at Terminal 1.
    ready(
      1,
      then: "W=\"$WORKROOM_BIN_DIR/workroom\"; "
        + "claude() { sleep 4; \"$W\" send \"$(cat \(directory)/pane-one)\" 'echo typed-by-claude'"
        + " || echo SENDFAILED; sleep 5; }")
    // Before `claude` starts, so the 4 s it waits before sending all fall after this.
    let started = Date()
    run("claude")
    chip(0).click()

    XCTAssertTrue(
      marker.waitForExistence(timeout: 20),
      "Terminal 1 never showed who was typing into it: \(app.debugDescription.prefix(2000))")
    // No later than the keystroke, which came before it showed.
    let seen = Date()
    XCTAssertTrue(
      poll(timeout: 2) { said == "Claude in tab 2 is typing into this pane." },
      "the marker says \(said): \(marker.debugDescription)")

    XCTAssertTrue(poll(timeout: 20) { !marker.exists }, "the marker never went")
    let gone = Date()
    // From below: the send went at least 4 s after `started`, and the marker lasts 3 s after it.
    XCTAssertGreaterThanOrEqual(
      gone.timeIntervalSince(started), 7, "the marker went before 3 s had passed since the send")
    // From above: 3 s after the one keystroke, its 0.35 s fade, and a margin for a busy guest's
    // accessibility queries; the keystroke was before `seen`.
    XCTAssertLessThanOrEqual(
      gone.timeIntervalSince(seen), 3 + 0.35 + 3, "the marker outstayed the keystroke's 3 s")
    XCTAssertTrue(
      poll(timeout: 10) {
        ((surface().value as? String) ?? "").contains("echo typed-by-claude")
      }, "the send never reached Terminal 1")
  }

  /// The marker over a pane in each appearance, for a reviewer: light and dark, Glass off and at
  /// 85%. Seeded with no daemon (`-WorkroomUITestTypingMarker`), so it shows for as long as the
  /// capture takes.
  func testTheMarkerInEachAppearance() {
    defer { resetSettings() }
    for (appearance, glass) in [("light", "1"), ("light", "0.85"), ("dark", "1"), ("dark", "0.85")]
    {
      capture(
        "\(appearance), Glass \(glass == "1" ? "off" : "85%")",
        saying: "Claude in tab 2 is typing into this pane.",
        ["-WorkroomUITestGlassOpacity", glass, "-WorkroomUITestAppearance", appearance])
    }
  }

  /// A sender in another workroom with a very long name, in a wide pane and in a very narrow
  /// one: the name and the tab stay whole, the workroom gives way from its middle, and the pill
  /// never runs past the pane's edges.
  func testALongWorkroomNameTruncatesFirstInANarrowPane() {
    defer { resetSettings() }
    let long = String(repeating: "abcdefghij", count: 13)
    let anotherWorkroom = [
      "-WorkroomUITestTwoTabs", "1", "-WorkroomUITestTypingMarkerElsewhere", "1",
      "-WorkroomUITestAppearance", "dark", "-WorkroomUITestGlassOpacity", "1",
    ]
    // A short name first, which the pill holds tight round.
    capture(
      "another workroom", saying: "Claude in tab 1 in uitest-room is typing into this pane.",
      anotherWorkroom)
    let elsewhere = anotherWorkroom + ["-WorkroomUITestLongWorkroomName", "1"]
    let saying = "Claude in tab 1 in \(long) is typing into this pane."
    capture("long workroom name", saying: saying, elsewhere)
    capture(
      "long workroom name, narrow pane", saying: saying,
      elsewhere + ["-WorkroomUITestWindowFrame", "{{80, 80}, {760, 560}}"])
  }

  /// Launches the seeded marker with `arguments`, checks what it says and that it sits inside its
  /// pane, and attaches the screen and the pill.
  private func capture(_ name: String, saying: String, _ arguments: [String]) {
    app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-WorkroomUITestTypingMarker", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += arguments
    app.launch()
    app.activate()
    XCTAssertTrue(marker.waitForExistence(timeout: 20), "no marker (\(name))")
    // Polled: a keystroke the fixture sends before the window is registered names a terminal no
    // window has open, until the next one, a second later.
    XCTAssertTrue(
      poll(timeout: 5) { said == saying }, "the marker says \(said): \(marker.debugDescription)")
    // Past the fade-in.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let pane = surface().frame
    XCTAssertTrue(
      pane.insetBy(dx: -1, dy: -1).contains(marker.frame),
      "the pill \(marker.frame) runs past its pane \(pane) (\(name))")
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

  /// Puts back what the captures set, which persists in the app's defaults: Glass off and the
  /// system's appearance, the settings' own defaults.
  private func resetSettings() {
    app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-WorkroomUITestGlassOpacity", "1"]
    app.launchArguments += ["-WorkroomUITestAppearance", "system"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    app.terminate()
  }
}
