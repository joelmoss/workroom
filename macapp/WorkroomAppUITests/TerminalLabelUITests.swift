import XCTest

/// A terminal's tab name and its session's label are one name (#694), end to end, through a REAL
/// `workroomd` of the test's own (`-WorkroomUITestLiveDaemon`, so no daemon, session or config of
/// the developer's is touched): renaming the tab labels the session, which a pane's `workroom`
/// then names it by, and a label set through the terminal API renames the tab. Run in the VM,
/// this class only (`make app-uitest-vm`).
final class TerminalLabelUITests: XCTestCase {
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

  /// What the terminal's screen shows.
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

  /// Names the first tab `name` through its menu's Rename…, as the user does.
  private func rename(to name: String) {
    let chip = chips.firstMatch
    chip.rightClick()
    let item = app.waitForHittableMenuItem(titled: "Rename…")
    XCTAssertNotNil(item, "a terminal tab's menu offers Rename…")
    item?.click()
    let field = app.sheets.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 6), "the rename sheet has a name field")
    field.typeKey("a", modifierFlags: .command)
    if name.isEmpty {
      field.typeKey(.delete, modifierFlags: [])
    } else {
      field.typeText(name)
    }
    app.sheets.buttons["Rename"].click()
    // The sheet is gone and the pane has the keyboard again.
    XCTAssertTrue(poll(timeout: 6) { app.sheets.count == 0 })
    surfaces.firstMatch.click()
  }

  /// Value: protects=renaming a tab labels its session, so a pane's `workroom` names the session
  /// as the user does, and clearing the name clears the label (story 29); fails_when=the rename
  /// stays the app's, or the old name still names it; why_new=#694; seam=a scratch daemon's real
  /// `session.label` and target resolution; no_claim=the tab's styling
  func testRenamingATabLabelsItsSession() {
    launch()
    rename(to: "ui-named")
    XCTAssertTrue(
      poll(timeout: 10) { chips.firstMatch.label.contains("ui-named") },
      "the tab shows its new name: \(chips.firstMatch.label)")
    // Its target resolves by its label only once the daemon has it: asked until then.
    run(
      "for i in $(seq 50); do \"$W\" sessions ui-named > /dev/null 2>&1 && break; sleep 0.2;"
        + " done; \"$W\" sessions ui-named > /dev/null && echo LABELLED$((3+4))")
    XCTAssertTrue(
      poll(timeout: 20) { screen.contains("LABELLED7") },
      "the session isn't named by its tab's name; the pane shows: \(screen.suffix(1500))")

    rename(to: "")
    run(
      "for i in $(seq 50); do \"$W\" sessions ui-named > /dev/null 2>&1 || break; sleep 0.2;"
        + " done; \"$W\" sessions ui-named > /dev/null 2>&1 || echo CLEARED$((4+5))")
    XCTAssertTrue(
      poll(timeout: 20) { screen.contains("CLEARED9") },
      "a cleared name still names the session; the pane shows: \(screen.suffix(1500))")
  }

  /// Value: protects=a label set through the terminal API renames the tab, and clearing it gives
  /// the tab its default back (story 29); fails_when=the tab keeps its old name, or the app labels
  /// it back; why_new=#694; seam=a scratch daemon's real `session.label` and `session.labelled`;
  /// no_claim=other Macs (SessionLabelsTests)
  func testALabelSetThroughTheAPIRenamesTheTab() {
    launch()
    let chip = chips.firstMatch
    let unnamed = chip.label
    run(
      "\"$W\" api call session.label \"{\\\"target\\\":\\\"$WORKROOM_PANE\\\","
        + "\\\"label\\\":\\\"api-named\\\"}\" > /dev/null && echo SET$((5+6))")
    XCTAssertTrue(
      poll(timeout: 10) { screen.contains("SET11") },
      "the label wasn't set; the pane shows: \(screen.suffix(1500))")
    XCTAssertTrue(
      poll(timeout: 20) { chip.label.contains("api-named") },
      "the tab isn't renamed by the label: \(chip.label)")

    run(
      "\"$W\" api call session.label \"{\\\"target\\\":\\\"api-named\\\",\\\"label\\\":null}\""
        + " > /dev/null && echo UNSET$((6+7))")
    XCTAssertTrue(poll(timeout: 10) { screen.contains("UNSET13") })
    XCTAssertTrue(
      poll(timeout: 20) { !chip.label.contains("api-named") },
      "a cleared label leaves the tab named: \(chip.label)")
    XCTAssertFalse(chip.label.contains("Terminal 1"), "no number is shown: \(chip.label)")
    XCTAssertFalse(unnamed.isEmpty)
  }
}
