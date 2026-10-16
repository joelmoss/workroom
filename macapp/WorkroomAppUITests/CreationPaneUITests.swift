import XCTest

/// A create opens its pane on the click and shows its checklist until the workroom's own UI takes
/// over (#483), even with the sidebar hidden, which used to be the only place a create showed.
///
/// The create is a scripted one (`-WorkroomUITestScriptedCreate 1`, `ScriptedCreateCLI`): fixture
/// paths aren't repositories, so the real CLI would fail at its worktree. The script plays the
/// steps over a few seconds, so the checklist is on screen long enough to see.
// Value: protects=AC 1 and AC 7 end to end, a local create started from File ▸ New Workroom… with
// the sidebar hidden shows its checklist in the detail, then its terminal with no click;
// fails_when=nothing shows until the create ends, the checklist never goes, or the terminal never
// mounts; no_claim=a real `workroom create` (ScriptedCreateCLI stands in), the crossfade's look
final class CreationPaneUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
    for step in ["fetch", "worktree", "script"] {
      XCTAssertTrue(element(app, "CreationPane.step.\(step)").exists, "\(step) isn't listed")
    }
    XCTAssertEqual(
      element(app, "CreationPane.step.fetch").label, "Fetch base branch, skipped")
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = "creation-pane-running"
    shot.lifetime = .keepAlways
    add(shot)

    XCTAssertTrue(pane.waitForNonExistence(timeout: 20), "the checklist never gave way")
    let workroomPane = app.descendants(matching: .any).matching(identifier: "workroom.pane")
      .matching(NSPredicate(format: "label == %@", "Workroom uitest-created")).firstMatch
    XCTAssertTrue(workroomPane.waitForExistence(timeout: 5), "the new workroom's pane isn't shown")
    XCTAssertTrue(
      workroomPane.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "its terminal didn't mount")
  }
}
