import XCTest

/// A focused create renders INSIDE its own workroom pane (issue #171, closing #163 §2c).
///
/// ⌥⌘N creates a workroom beside the current one, and the split is in the model from the moment the
/// new workroom exists — but `RootView.detailContent` used to hand the whole detail to a chrome-less
/// full-frame create whenever the selected target had one. The anchor pane the user had just chosen to
/// create beside was therefore unmounted for the length of the create: a blink with no setup script,
/// the entire script run with one.
///
/// These tests assert the two things that are only true of the render, not of the model — which is why
/// they live here and not in `AppStoreCreateWorkroomTests`, where the split's *state* is already
/// covered. The fixture seeds a mid-script create on the selected split member
/// (`-WorkroomUITestCreatingSplitMember 1`) rather than producing one: fixture mode never shells out
/// to the CLI, so a real create can't be driven from a UI test (see `NewWorkroomDialogUITests`).
final class CreateInSplitUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// A root + workroom split whose workroom member is mid-setup-script. `runCommand` seeds a
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

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 10) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// **The issue.** Both panes stay mounted while the selected member is being created, and the setup
  /// dialog is a DESCENDANT of a workroom pane rather than of the window.
  ///
  /// The descendant check is the load-bearing half. A full-frame create also puts a `SetupOverlay` on
  /// screen — `app.descendants` would find it either way — so only scoping the query to
  /// `workroom.pane` tells the two routings apart. The pane count is the user-visible consequence: one
  /// pane means the anchor was unmounted, which is the bug.
  func testTheCreateRendersInsideItsPaneAndKeepsTheAnchorOnScreen() throws {
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
    XCTAssertFalse(
      creatingPane(app).descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .exists,
      "while the creating member withholds its own, because its create owns that pane")
  }

  /// The second half: a creating member's title bar drops Run. `startRunCommand` refuses a workroom
  /// whose setup script is still writing the worktree (issue #167), so the button was live, pressable
  /// and silent — barely visible until the focused create moved into a pane with a full title bar.
  ///
  /// Asserted PER PANE, not as a global count. Both members belong to the same project and so resolve
  /// the same configured command, so the healthy one must keep its Run — a count of 1 alone would also
  /// be satisfied by an INVERTED gate that hid the wrong pane's button, which is the regression most
  /// worth catching. Panes are identified by their accessibility label (`WorkroomPaneLeaf` labels each
  /// "Workroom <name>" or "Project <title>") rather than by index, which layout order could swap.
  func testTheCreatingMemberHasNoRunButtonWhileTheOtherKeepsOne() throws {
    let app = launchedApp()

    assertCount(panes(app), reaches: 2)
    let creating = panes(app)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Workroom ")).firstMatch
    let healthy = panes(app)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Project ")).firstMatch
    XCTAssertTrue(creating.waitForExistence(timeout: 10), "the creating workroom member's pane")
    XCTAssertTrue(healthy.waitForExistence(timeout: 10), "the project-root member's pane")

    XCTAssertTrue(
      healthy.buttons["runCommand.run"].waitForExistence(timeout: 8),
      "the member that is NOT being created must keep its own Run button")
    XCTAssertFalse(
      creating.buttons["runCommand.run"].exists,
      "the creating member's Run would be live, pressable and silent — it must not render")
  }

  /// A project with NO setup script gets the loader, inside its own pane, with the anchor still up.
  /// This branch is new in issue #171 — the pane used to draw nothing for a no-setup create, because
  /// the focused create owned the whole window and the co-displayed case mounted its terminal
  /// straight away. Now it withholds, so something has to be there.
  func testANoSetupCreateShowsItsLoaderInsideItsOwnPane() throws {
    let app = launchedApp("-WorkroomUITestCreatingSplitMemberNoSetup")

    assertCount(panes(app), reaches: 2)
    let loader = creatingPane(app).descendants(matching: .any)
      .matching(identifier: "CreationLoader").firstMatch
    XCTAssertTrue(
      loader.waitForExistence(timeout: 10),
      "a no-setup create must show its loader, not an empty pane under a title bar")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "and the anchor pane keeps its terminal throughout")
  }
}
