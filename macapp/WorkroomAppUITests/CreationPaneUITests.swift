import AppKit
import XCTest

/// A create opens its pane on the click and shows its checklist until the workroom's own UI takes
/// over (#483), even with the sidebar hidden, which used to be the only place a create showed.
///
/// The create is a scripted one (`-WorkroomUITestScriptedCreate 1`, `ScriptedCreateCLI`): fixture
/// paths aren't repositories, so the real CLI would fail at its worktree. The script plays the
/// steps over a few seconds, so the checklist is on screen long enough to see.
// Value: protects=AC 1 and AC 7 end to end, a local create started from File ▸ New Workroom… with
// the sidebar hidden shows its checklist in the detail, then Done, then its terminal;
// fails_when=nothing shows until the create ends, no Done is offered, the checklist never goes, or
// the terminal never mounts; no_claim=a real `workroom create` (ScriptedCreateCLI stands in), the crossfade's look
final class CreationPaneUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// A scripted create run to its end with its setup script's two-line log open.
  private func finishedCreateWithLogOpen() -> (XCUIApplication, XCUIElement) {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestScriptedCreate", "1",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let file = app.menuBars.menuBarItems["File"]
    file.click()
    file.menuItems["New Workroom…"].click()
    let project = element(app, "newWorkroom.project.UITestProject")
    XCTAssertTrue(project.waitForExistence(timeout: 5), "the picker didn't list the project")
    project.click()
    let thisMac = app.buttons["newWorkroom.place.thisMac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5), "the picker didn't ask where")
    thisMac.click()
    XCTAssertTrue(
      element(app, "CreationPane.Done").waitForExistence(timeout: 20), "the create never finished")
    let row = element(app, "CreationPane.step.script")
    if row.value as? String == "Collapsed" { row.click() }
    let log = element(app, "CreationPane.log")
    XCTAssertTrue(log.waitForExistence(timeout: 5), "the log didn't open")
    return (app, log)
  }

  private func copiedText(_ app: XCUIApplication) -> String? {
    NSPasteboard.general.clearContents()
    app.typeKey("c", modifierFlags: .command)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let text = NSPasteboard.general.string(forType: .string) { return text }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return nil
  }

  private func keepClipboard() {
    let saved = NSPasteboard.general.string(forType: .string)
    addTeardownBlock {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }
  }

  // Value: protects=the reported bug, ⌘A then ⌘C takes a whole log after a click in it;
  // fails_when=selection stops at one line, or the keys never reach the log;
  // no_claim=a log still receiving lines (LogTextControllerTests)
  func testSelectAllCopiesAWholeLog() {
    keepClipboard()
    let (app, log) = finishedCreateWithLogOpen()
    log.click()
    app.typeKey("a", modifierFlags: .command)
    XCTAssertEqual(copiedText(app), "Installing dependencies…\nDone.")
  }

  // Value: protects=the reported bug, a mouse drag selects across lines; fails_when=a drag stops at
  // the line it started on; no_claim=a drag past the log's edge
  func testDraggingSelectsAcrossLines() {
    keepClipboard()
    let (app, log) = finishedCreateWithLogOpen()
    let width = log.frame.width
    let origin = log.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 11, dy: 16)).click(
      forDuration: 0.3, thenDragTo: origin.withOffset(CGVector(dx: width - 4, dy: 30)))
    let copied = copiedText(app)
    XCTAssertTrue(copied?.contains("\nDone.") == true, "copied \(copied ?? "nothing")")
  }

  // Value: protects=D16, Return answers the pane's footer even with focus in its log;
  // fails_when=the text view swallows Return after a click in it; no_claim=Escape, the arrow keys
  func testReturnAnswersDoneAfterAClickInTheLog() {
    let (app, log) = finishedCreateWithLogOpen()
    log.click()
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(
      element(app, "CreationPane").waitForNonExistence(timeout: 5), "Return didn't answer Done")
  }

  func testALocalCreateWithTheSidebarHiddenShowsItsChecklistThenItsTerminal() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestScriptedCreate", "1",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

    // Hide the sidebar (View ▸ Projects, ⌃⌘S). Its state persists across launches, so only if shown.
    let projectRow = element(app, "sidebar.project.UITestProject")
    if projectRow.waitForExistence(timeout: 10) {
      app.typeKey("s", modifierFlags: [.control, .command])
      XCTAssertTrue(projectRow.waitForNonExistence(timeout: 5), "the sidebar didn't hide")
    }

    let file = app.menuBars.menuBarItems["File"]
    file.click()
    file.menuItems["New Workroom…"].click()
    let project = element(app, "newWorkroom.project.UITestProject")
    XCTAssertTrue(project.waitForExistence(timeout: 5), "the picker didn't list the project")
    project.click()
    let thisMac = app.buttons["newWorkroom.place.thisMac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5), "the picker didn't ask where")
    thisMac.click()

    let pane = element(app, "CreationPane")
    XCTAssertTrue(pane.waitForExistence(timeout: 5), "the create's pane didn't open on the click")
    for step in ["fetch", "worktree"] {
      XCTAssertTrue(element(app, "CreationPane.step.\(step)").exists, "\(step) isn't listed")
    }
    // Without a setup script of the project's own, its row shows once the scripted one runs.
    XCTAssertTrue(
      element(app, "CreationPane.step.script").waitForExistence(timeout: 10),
      "the setup script's row never showed")
    XCTAssertEqual(
      element(app, "CreationPane.step.fetch").label, "Fetch base branch, skipped")
    // Value: protects=the footer's "Close automatically when done" can be changed while the create
    // runs, and Done is offered only once it succeeds; fails_when=the footer waits for success
    // again, or Done shows (and answers) mid-run; no_claim=focus, the checkbox not moving
    XCTAssertTrue(
      element(app, "CreationPane.closeWhenDone").exists, "the checkbox isn't offered mid-run")
    XCTAssertFalse(element(app, "CreationPane.Done").exists, "Done is offered mid-run")
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = "creation-pane-running"
    shot.lifetime = .keepAlways
    add(shot)

    let done = element(app, "CreationPane.Done")
    XCTAssertTrue(done.waitForExistence(timeout: 20), "the finished checklist offers no Done")
    done.click()
    XCTAssertTrue(pane.waitForNonExistence(timeout: 5), "the checklist never gave way")
    let workroomPane = app.descendants(matching: .any).matching(identifier: "workroom.pane")
      .matching(NSPredicate(format: "label == %@", "Workroom uitest-created")).firstMatch
    XCTAssertTrue(workroomPane.waitForExistence(timeout: 5), "the new workroom's pane isn't shown")
    XCTAssertTrue(
      workroomPane.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "its terminal didn't mount")
  }

  // Value: protects=the reported bug, a split create (⌥⌘N) from a terminal whose checklist closes
  // by itself hands the keyboard to the new workroom's terminal; fails_when=the dialog closes in a
  // render of its own, whose late focus claim pulls the selection back to the workroom beside it,
  // so keys keep going to that terminal; no_claim=a real `workroom create`, a create that waits for
  // Done (its click selects the pane anyway)
  func testASplitCreatesTerminalTakesTheKeyboardWhenItsChecklistClosesItself() {
    let app = startSplitCreateFromATerminal(closesWhenDone: true)
    XCTAssertTrue(
      element(app, "CreationPane").waitForNonExistence(timeout: 30),
      "the checklist didn't close by itself")
    assertTypingReachesTheNewTerminal(app)
  }

  // Value: protects=the reported bug as the app runs it, panes attached through `workroomd`;
  // fails_when=the daemon-backed terminal that replaces a self-closing checklist never takes the
  // keyboard; no_claim=a real `workroom create`
  func testASplitCreatesDaemonTerminalTakesTheKeyboardWhenItsChecklistClosesItself() {
    let app = startSplitCreateFromATerminal(closesWhenDone: true, throughTheDaemon: true)
    XCTAssertTrue(
      element(app, "CreationPane").waitForNonExistence(timeout: 30),
      "the checklist didn't close by itself")
    assertTypingReachesTheNewTerminal(app)
  }

  // Value: protects=the reported bug, a split create (⌥⌘N) from a pane running Claude Code, which
  // asks for focus reports and retitles its terminal several times a second, hands the keyboard to
  // the new terminal; fails_when=the caller's pane takes the keyboard back; no_claim=Claude itself
  // (a shell loop stands in)
  func testASplitCreatesTerminalTakesTheKeyboardFromABusyAgentPane() {
    // Recognised as Claude by its exact title, as the app reads it, then retitled with a spinner
    // the way Claude Code does while it works.
    let app = startSplitCreateFromATerminal(
      closesWhenDone: true, throughTheDaemon: true,
      callerRuns: "printf '\\e[?1004h\\e]0;Claude Code\\a'; sleep 0.5;"
        + " while :; do printf '\\e]0;%s Fixing the build\\a' $RANDOM; sleep 0.1; done")
    XCTAssertTrue(
      element(app, "CreationPane").waitForNonExistence(timeout: 30),
      "the checklist didn't close by itself")
    assertTypingReachesTheNewTerminal(app)
  }

  // Value: protects=the reported bug, a split create (⌥⌘N) whose checklist waits for Done (the
  // default) hands the keyboard to the new workroom's terminal when Return answers Done;
  // fails_when=the terminal that replaces the checklist mounts without first responder, so keys go
  // nowhere or to the workroom beside it; no_claim=a real `workroom create`
  func testASplitCreatesTerminalTakesTheKeyboardWhenReturnAnswersDone() {
    let app = startSplitCreateFromATerminal(closesWhenDone: false)
    XCTAssertTrue(
      element(app, "CreationPane.Done").waitForExistence(timeout: 30), "the create never finished")
    app.typeKey(.return, modifierFlags: [])
    assertTypingReachesTheNewTerminal(app)
  }

  // Value: protects=the reported bug, as above when Done is clicked; fails_when=the click leaves
  // first responder with the checklist's hosting view as it fades, so the new terminal never takes
  // the keyboard; no_claim=a real `workroom create`
  func testASplitCreatesTerminalTakesTheKeyboardWhenDoneIsClicked() {
    let app = startSplitCreateFromATerminal(closesWhenDone: false)
    let done = element(app, "CreationPane.Done")
    XCTAssertTrue(done.waitForExistence(timeout: 30), "the create never finished")
    done.click()
    assertTypingReachesTheNewTerminal(app)
  }

  /// Launches the fixture, clicks into its workroom's terminal and starts a scripted split create
  /// (⌥⌘N) beside it, with "Close automatically when done" set to `closesWhenDone` from launch.
  private func startSplitCreateFromATerminal(
    closesWhenDone: Bool, throughTheDaemon: Bool = false, callerRuns command: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if throughTheDaemon { _ = app.useScratchDaemon() }
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestScriptedCreate", "1",
      "-ApplePersistenceIgnoreState", "YES",
      // A plist value, so the argument domain holds a Bool that `Defaults` reads (a bare YES is a
      // string, which it doesn't); the checkbox assertion below goes red if that ever stops.
      "-closeCreationPaneWhenDone", closesWhenDone ? "<true/>" : "<false/>",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    // Start where the user does: typing in a terminal, which is where focus stayed (the bug).
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.")).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    if let command {
      app.typeText(command + "\r")
      RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    // New Workroom (split right), ⌥⌘N: the workroom typed in stays on screen beside the create.
    app.typeKey("n", modifierFlags: [.command, .option])
    let project = element(app, "newWorkroom.project.UITestProject")
    XCTAssertTrue(project.waitForExistence(timeout: 5), "the picker didn't list the project")
    project.click()
    let thisMac = app.buttons["newWorkroom.place.thisMac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5), "the picker didn't ask where")
    thisMac.click()
    // Set from launch, as Settings leaves it: nothing in the pane is clicked.
    let closeWhenDone = element(app, "CreationPane.closeWhenDone")
    XCTAssertTrue(closeWhenDone.waitForExistence(timeout: 5), "the checkbox isn't offered mid-run")
    XCTAssertEqual(
      closeWhenDone.value as? Int, closesWhenDone ? 1 : 0, "the setting wasn't set from launch")
    return app
  }

  private func assertTypingReachesTheNewTerminal(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, "CreationPane").waitForNonExistence(timeout: 5), "the checklist never gave way")
    // The NEW workroom's surface, not whichever one comes first: keys still landing in the terminal
    // focused before the create would otherwise read as a pass.
    let workroomPane = app.descendants(matching: .any).matching(identifier: "workroom.pane")
      .matching(NSPredicate(format: "label == %@", "Workroom uitest-created")).firstMatch
    XCTAssertTrue(workroomPane.waitForExistence(timeout: 5), "the new workroom's pane isn't shown")
    let surface = workroomPane.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10), "its terminal didn't mount")
    let surfaces = app.descendants(matching: .any).matching(identifier: "terminal.surface")
    // Let the crossfade finish and the shell print its prompt before typing.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    app.typeText("echo WRFOCUS$((40+2))")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
    let deadline = Date().addingTimeInterval(15)
    var text = ""
    while Date() < deadline {
      text = (surface.value as? String) ?? ""
      if text.contains("WRFOCUS42") { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    let elsewhere = surfaces.allElementsBoundByIndex.map { ($0.value as? String) ?? "" }
      .filter { $0.contains("WRFOCUS42") && $0 != text }
    XCTAssertTrue(
      text.contains("WRFOCUS42"),
      "typing never reached the new terminal: \(text)\nother surfaces: \(elsewhere)")
  }
}
