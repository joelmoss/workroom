import XCTest

/// A create renders INSIDE its own workroom pane (issue #171, closing #163 §2c), as a bare creation
/// pane since #483.
///
/// ⌥⌘N creates a workroom beside the current one, and the split is in the model from the click — but
/// `RootView.detailContent` used to hand the whole detail to a chrome-less full-frame create whenever
/// the selected target had one. The anchor pane the user had just chosen to create beside was
/// therefore unmounted for the length of the create.
///
/// These tests assert the things that are only true of the render, not of the model — which is why
/// they live here and not in `CreationFlowTests`, where the split's *state* is already covered. The
/// fixture seeds a running create on the selected split member (`-WorkroomUITestCreatingSplitMember
/// 1`) rather than producing one: fixture mode never shells out to the CLI.
final class CreateInSplitUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// A root + workroom split whose workroom member is being created. `runCommand` seeds a
  /// configured command so the Run buttons are in play at all — without one neither member shows one
  /// and the gating assertion would pass vacuously.
  private func launchedApp(_ variant: String = "-WorkroomUITestCreatingSplitMember")
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestWorkroomSplit", "1",
      variant, "1",
      "-WorkroomUITestRunCommand", "sleep 30",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    return app
  }

  /// The creating member's pane, found by its accessibility label rather than by index — layout
  /// order could swap, the label cannot (`WorkroomPaneLeaf` labels each "Workroom <name>").
  private func creatingPane(_ app: XCUIApplication) -> XCUIElement {
    panes(app).matching(NSPredicate(format: "label BEGINSWITH %@", "Workroom ")).firstMatch
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "workroom.pane")
  }

  private func inside(_ element: XCUIElement, _ identifier: String) -> XCUIElement {
    element.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 10) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// **The issue.** Both panes stay mounted while the selected member is being created, and the
  /// creation pane is a DESCENDANT of that workroom pane rather than of the window — only scoping the
  /// query to `workroom.pane` tells the two routings apart. The pane count is the user-visible
  /// consequence: one pane means the anchor was unmounted, which is the bug.
  ///
  /// **The bare pane (#483, AC 2):** the creating member has no title bar, so no Run, no ✕ and no
  /// menu, while the healthy member keeps its own. Asserted PER PANE, not as a global count: both
  /// members resolve the same configured command, so a count of 1 alone would also be satisfied by an
  /// INVERTED gate that hid the wrong pane's controls.
  func testTheCreateRendersBareInsideItsPaneAndKeepsTheAnchor() throws {
    let app = launchedApp()

    assertCount(panes(app), reaches: 2)
    XCTAssertEqual(
      Set(panes(app).allElementsBoundByIndex.map { $0.label }),
      ["Project UITestProject", "Workroom uitest-room"],
      "both members stay mounted and identified while the create runs")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "the anchor member keeps its terminal — it was never unmounted")

    let creating = creatingPane(app)
    let healthy = panes(app)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Project ")).firstMatch
    XCTAssertTrue(creating.waitForExistence(timeout: 10), "the creating workroom member's pane")
    XCTAssertTrue(healthy.waitForExistence(timeout: 10), "the project-root member's pane")
    XCTAssertTrue(
      inside(creating, "CreationPane").waitForExistence(timeout: 10),
      "the create's checklist draws inside its own pane")
    XCTAssertTrue(
      inside(creating, "CreationPane.step.script").exists, "with the step it is on")
    XCTAssertFalse(
      inside(creating, "terminal.pane").exists, "its terminal is withheld while the create runs")

    XCTAssertTrue(
      inside(healthy, "workroom.pane.titlebar").exists, "the healthy member keeps its title bar")
    XCTAssertTrue(
      healthy.buttons["runCommand.run"].waitForExistence(timeout: 8),
      "the member that is NOT being created must keep its own Run button")
    XCTAssertFalse(
      inside(creating, "workroom.pane.titlebar").exists, "the creating member's pane is bare")
    XCTAssertFalse(creating.buttons["runCommand.run"].exists)
  }

  /// A create still on its worktree, with no setup script running yet, shows the same checklist in
  /// its own pane — the plan up front, the worktree row running — with the anchor still up.
  func testACreateOnItsWorktreeShowsItsChecklistInsideItsOwnPane() throws {
    let app = launchedApp("-WorkroomUITestCreatingSplitMemberNoSetup")

    assertCount(panes(app), reaches: 2)
    let creating = creatingPane(app)
    XCTAssertTrue(
      inside(creating, "CreationPane").waitForExistence(timeout: 10),
      "the create must show its checklist, not an empty pane")
    for step in ["fetch", "worktree", "script"] {
      XCTAssertTrue(inside(creating, "CreationPane.step.\(step)").exists, "\(step) isn't listed")
    }
    XCTAssertEqual(
      inside(creating, "CreationPane.step.worktree").label, "Create worktree, running")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "and the anchor pane keeps its terminal throughout")
  }
}
