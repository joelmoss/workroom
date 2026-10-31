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
    origin.withOffset(CGVector(dx: 11, dy: 16)).press(
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
}
