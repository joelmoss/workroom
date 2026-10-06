import XCTest

/// The always-on workroom pane header (issue #139). Before it, a workroom only got a title bar when it
/// was part of a split group, and its run / "Open in…" controls lived in the window title bar keyed on
/// the *selected* target — so a co-displayed split member's were unreachable. These tests pin down the
/// three things that changed: a solo pane has a header, that header (not the title bar) hosts the
/// actions, and every member of a split gets its own set.
///
/// The load-bearing step here is the closing Run click of
/// `testSoloPaneHeaderHostsItsControlsAndTheRunButtonFires`. The header carries the group-drag
/// `DragGesture`, and gating it with `GestureMask.none` when solo would disable every gesture in the
/// bar's SUBVIEW hierarchy too — killing these buttons in exactly the single-workroom case the feature
/// exists for. `ToolbarIconButtonStyle`'s hover well is `.onHover`, not a gesture, so a broken button
/// still lights up on hover and still reports `.exists` and `.isHittable`. Only actually clicking it and
/// watching the run state change tells the difference, which is why existence assertions alone are not
/// enough on this bar.
final class WorkroomPaneHeaderUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Fixture launch. `workroomSplit` starts in a root + workroom split so both members render without a
  /// flaky drag; `runCommand` seeds a deterministic command (a long `sleep` stays running long enough
  /// to assert the Run → Stop flip).
  private func launchedApp(workroomSplit: Bool = false, runCommand: String? = nil)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if workroomSplit { app.launchArguments += ["-WorkroomUITestWorkroomSplit", "1"] }
    if let runCommand { app.launchArguments += ["-WorkroomUITestRunCommand", runCommand] }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  private func titlebars(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "workroom.pane.titlebar")
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "workroom.pane")
  }

  private func runButtons(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "runCommand.run")
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 8) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Wait for the fixture workroom's pane to mount. Terminal panes carry `terminal.pane`; the workroom
  /// pane wrapping them carries `workroom.pane`.
  private func openWorkroom(_ app: XCUIApplication) throws {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "terminal.pane").firstMatch
        .waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
  }

  /// One launch for everything a SOLO workroom pane header must do, seeded with `sleep 30` so the
  /// closing Run click has a command that stays running. The Run button does not depend on a configured
  /// command (`WorkroomPaneToolbarPresentationTests`), so the seed is irrelevant to the earlier steps.
  /// Steps run in this order, each from the solo state the previous one leaves:
  ///
  /// 1. A solo workroom now has a title bar (the whole point of issue #139) naming itself, and no
  ///    remove-from-split ✕, because there is no split to leave.
  /// 2. The Run button lives INSIDE the workroom pane, not in the window title bar. Scoping the query to
  ///    the `workroom.pane` element is the assertion: a button still sitting in the title-bar accessory
  ///    would satisfy a bare `app.buttons[…]` lookup and fail this one.
  /// 3. The "Open in…" chevron is a SwiftUI `Menu` in the same bar, so it would be dead under a
  ///    `GestureMask.none` (see the type doc). Opening it, rather than clicking the primary button,
  ///    proves the menu works without launching an external editor. Two query notes, both learned the
  ///    hard way. The step keys on `openIn.primary` — a plain `Button`, so `.buttons` resolves it —
  ///    because that is the honest test of "did `OpenInControl` render at all"; keying it on the menu
  ///    instead made this test skip on a machine that *does* have an editor, silently retiring the
  ///    assertion. And the menu itself needs a **type-agnostic** lookup: a SwiftUI `Menu` with
  ///    `.menuStyle(.button)` does not surface as `.buttons` in the accessibility tree. With no editor
  ///    installed only this step is skipped; the skip is thrown LAST so it cannot retire later steps.
  /// 4. Right-click still raises the workroom menu with the bar's new buttons in place. The buttons are
  ///    their own hit targets, so aim at the leading label region — that is where the menu lives.
  /// 5. Solo, the group-drag is masked off — there is no group to move within. Dragging the header must
  ///    not conjure a split.
  /// 6. **The gesture-mask guard.** Click the solo pane's Run button and require the run to actually
  ///    start — Stop replaces Run. It is last because it starts a process and flips the bar to Stop. If
  ///    the header's drag gesture were masked with `.none` instead of `.subviews`, this button would be
  ///    inert while still existing, being hittable, and lighting its hover well, so nothing short of a
  ///    real click would catch it.
  func testSoloPaneHeaderHostsItsControlsAndTheRunButtonFires() throws {
    let app = launchedApp(runCommand: "sleep 30")
    try openWorkroom(app)

    // 1. Title bar, naming the workroom, no remove-from-split.
    assertCount(titlebars(app), reaches: 1)
    let bar = titlebars(app).firstMatch
    XCTAssertTrue(
      bar.label.localizedCaseInsensitiveContains("workroom"),
      "the header should name the workroom it belongs to, got \(bar.label)")
    XCTAssertFalse(
      app.buttons["workroom.pane.close"].exists,
      "a solo pane is not in a split, so it offers no way out of one")

    // 2. Run button is a descendant of the pane.
    let pane = panes(app).firstMatch
    XCTAssertTrue(pane.waitForExistence(timeout: 8))
    XCTAssertTrue(
      pane.buttons["runCommand.run"].waitForExistence(timeout: 8),
      "the workroom's Run button should be a descendant of its own pane")

    // 3. "Open in…" menu opens, then is dismissed before the next step.
    var openInMissing = false
    if pane.buttons["openIn.primary"].waitForExistence(timeout: 4) {
      let menu = pane.descendants(matching: .any).matching(identifier: "openIn.menu").firstMatch
      XCTAssertTrue(
        menu.waitForExistence(timeout: 4), "the editor chooser should render beside the icon")
      menu.click()

      // Existence, not `isHittable`: on macOS 27 an open `Menu`'s items are in the tree but report
      // not hittable, which read as "no editors installed" and was never about the machine (#269).
      XCTAssertTrue(
        menu.menuItems.firstMatch.waitForExistence(timeout: 4),
        "the editor menu should list at least the installed editor")
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(
        menu.menuItems.firstMatch.waitForNonExistence(timeout: 4),
        "the editor menu should be closed before the next step")
    } else {
      openInMissing = true
    }

    // 4. Right-click context menu (matched by title among hittable items only: "Close" also exists
    // in the menu bar as a collapsed zero-frame item).
    XCTAssertTrue(bar.waitForExistence(timeout: 8))
    // 15% across the bar: past the leading glyph, well clear of the trailing controls.
    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).rightClick()
    XCTAssertNotNil(
      app.hittableMenuItem(titled: "Close"),
      "the workroom context menu should still open from the header")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      app.waitForNoHittableMenuItem(titled: "Close"),
      "the context menu should be closed before the next step")

    // 5. Dragging a solo header must not form a split.
    let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
    from.click(forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 120)))
    assertCount(titlebars(app), reaches: 1)
    XCTAssertFalse(
      app.buttons["workroom.pane.close"].exists, "dragging a solo header must not form a split")

    // 6. A real click on Run starts the command: Stop replaces Run.
    let run = pane.buttons["runCommand.run"]
    XCTAssertTrue(run.waitForExistence(timeout: 8), "Run should render in the solo pane header")
    run.click()
    XCTAssertTrue(
      pane.buttons["runCommand.stop"].waitForExistence(timeout: 15),
      "clicking Run must start the command — Stop replaces it once it's running")

    // Last, so a skip cannot hide any step above.
    if openInMissing {
      throw XCTSkip(
        "no supported editor installed, so OpenInControl renders nothing (step 3 not run)")
    }
  }

  /// The per-member point of the change: in a split, EVERY visible member carries its own run control,
  /// acting on its own target — one window title bar could only ever reach the selected one.
  func testEachSplitMemberHasItsOwnRunButton() throws {
    let app = launchedApp(workroomSplit: true)
    try openWorkroom(app)

    assertCount(titlebars(app), reaches: 2)
    // The fixture splits the project root against a workroom of the SAME project, so both members
    // resolve the same configured run command and both render a Run button.
    assertCount(runButtons(app), reaches: 2)
    assertCount(
      app.descendants(matching: .any).matching(identifier: "workroom.pane.close"), reaches: 2)
  }
}
