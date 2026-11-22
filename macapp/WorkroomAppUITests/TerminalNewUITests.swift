import XCTest

/// `workroom new` and `workroom close` (#693) end to end, through a REAL `workroomd` of the test's
/// own (`-WorkroomUITestLiveDaemon`, so no daemon, session or config of the developer's is
/// touched): a pane runs the bundled binary's `new`, the daemon's `session.created` reaches the
/// app's subscription, and the window showing that pane opens the session as a tab, or as a split
/// beside the pane; `close` takes it away again. Run in the VM, this class only
/// (`make app-uitest-vm`).
final class TerminalNewUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  /// The terminal chips' text, in order: their small close buttons carry the same identifier.
  private var chips: XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private var surfaces: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.surface")
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

  /// What the first terminal's screen shows.
  private var screen: String { (surfaces.firstMatch.value as? String) ?? "" }

  /// Launches the fixture with one terminal on a scratch daemon, and has its shell name the
  /// daemon's own `workroom` as `W`.
  private func launch() {
    app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalTabs", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    _ = app.useScratchDaemon()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    app.activate()
    let chip = chips.firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture has a terminal")
    chip.click()
    XCTAssertTrue(surfaces.firstMatch.waitForExistence(timeout: 10))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    // The daemon's bin folder's `workroom`, its own build, as every pane has it (#695).
    run("W=\"$WORKROOM_BIN_DIR/workroom\"; \"$W\" version > /dev/null && echo WRREADY$((1+1))")
    XCTAssertTrue(
      poll(timeout: 30) { screen.contains("WRREADY2") },
      "the terminal's shell never came up through the scratch daemon")
  }

  /// Value: protects=`workroom new` in a pane opens a tab in that pane's window, named by
  /// `--title`, and leaves the pane in front; `workroom close` closes the tab (stories 24, 27);
  /// fails_when=no tab appears, it takes the focus, or the close leaves it behind; why_new=#693;
  /// seam=a scratch daemon's real `new` and `close`; no_claim=the tab's styling
  func testNewOpensATabBesideTheCallerAndCloseClosesIt() {
    launch()
    XCTAssertEqual(chips.count, 1)
    // Its envelope and this Mac's name stay on the screen, for a failure to say what was asked.
    run("\"$W\" new --title api-tab --json; hostname; echo NEW$((2+2))")
    XCTAssertTrue(
      poll(timeout: 20) { chips.count == 2 },
      "no tab opened for the new terminal; the pane shows: \(screen.suffix(1500))")
    XCTAssertTrue(
      poll(timeout: 10) { chips.allElementsBoundByIndex.contains { $0.label == "api-tab" } },
      "the tab isn't named by --title: \(chips.allElementsBoundByIndex.map(\.label))")
    XCTAssertTrue(
      poll(timeout: 10) { screen.contains("NEW4") }, "the caller's pane isn't the one in front")
    XCTAssertEqual(surfaces.count, 1, "a tab, not a split")

    run("\"$W\" close api-tab && echo CLOSED$((3+3))")
    XCTAssertTrue(poll(timeout: 20) { chips.count == 1 }, "the closed terminal's tab stayed")
    XCTAssertTrue(poll(timeout: 10) { screen.contains("CLOSED6") })
  }

  /// Value: protects=`workroom new --split right` opens the new terminal as a split beside the
  /// caller's pane, and `close` takes the split away (story 25); fails_when=it opens as a tab, in
  /// another place, or stays after its close; why_new=#693; seam=a scratch daemon's real `new`;
  /// no_claim=the split's ratio
  func testNewWithSplitOpensASplitBesideTheCaller() {
    launch()
    XCTAssertEqual(surfaces.count, 1)
    run("\"$W\" new --title api-split --split right && echo SPLIT$((4+4))")
    XCTAssertTrue(
      poll(timeout: 20) { surfaces.count == 2 },
      "no split opened beside the caller; the pane shows: \(screen.suffix(1500))")
    let caller = surfaces.element(boundBy: 0).frame
    let split = surfaces.element(boundBy: 1).frame
    XCTAssertGreaterThan(split.minX, caller.minX, "the split is on the caller's right")
    XCTAssertEqual(split.minY, caller.minY, accuracy: 2, "side by side")
    XCTAssertTrue(poll(timeout: 10) { screen.contains("SPLIT8") })

    run("\"$W\" close api-split && echo GONE$((5+5))")
    XCTAssertTrue(poll(timeout: 20) { surfaces.count == 1 }, "the closed split stayed")
  }
}
