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
  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestWorkroomSplit", "1",
      "-WorkroomUITestCreatingSplitMember", "1",
      "-WorkroomUITestRunCommand", "sleep 30",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    return app
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
    let overlay = panes(app).element(boundBy: 0).descendants(matching: .any)
      .matching(identifier: "SetupOverlay").firstMatch
    let other = panes(app).element(boundBy: 1).descendants(matching: .any)
      .matching(identifier: "SetupOverlay").firstMatch
    XCTAssertTrue(
      overlay.waitForExistence(timeout: 10) || other.waitForExistence(timeout: 10),
      "the setup dialog must render inside one of the split's panes, not over the whole detail")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "and the other member keeps its terminal — it was never unmounted")
  }

  /// The second half: a creating member's title bar drops Run. `startRunCommand` refuses a workroom
  /// whose setup script is still writing the worktree (issue #167), so the button was live, pressable
  /// and silent — barely visible until the focused create moved into a pane with a full title bar.
  ///
  /// Exactly ONE Run button is the assertion, not zero: both members belong to the same project and so
  /// resolve the same configured command, and the member that ISN'T being created must keep its own.
  /// A gate applied pane-wide rather than per-target would read as zero here.
  func testTheCreatingMemberHasNoRunButtonWhileTheOtherKeepsOne() throws {
    let app = launchedApp()

    assertCount(panes(app), reaches: 2)
    assertCount(app.descendants(matching: .any).matching(identifier: "runCommand.run"), reaches: 1)
  }
}
