import XCTest

/// Split-pane UI tests (issue #3). These drive the real app through XCUITest — which owns app launch
/// and routes key commands to the app itself — and assert on the **on-screen pane count**. Each leaf
/// of the pane renderer exposes one `terminal.pane` accessibility element (the libghostty Metal
/// surface itself contributes nothing to the a11y tree), so counting `terminal.pane` elements is a
/// direct "how many panes are rendering?" check. That's the signal that catches the close-a-split-pane
/// blank regression: the survivor must remain a rendered pane, not a detached/blank one.
///
/// Deterministic, not opportunistic: the app is launched in **UI-test fixture mode**
/// (`-WorkroomUITestFixture 1`, see `UITestFixture`), so it loads fake projects/workrooms rooted at a
/// temp directory instead of the developer's real `~/.config/workroom` — the fixture workroom is
/// auto-selected, so a terminal renders on launch with no sidebar navigation. Run with `make
/// app-uitest` on a GUI session (XCUITest can't drive a headless run).
final class SplitPaneUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(workroomSplit: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    // Fixture mode: deterministic fake projects/workrooms (not the developer's real config), with the
    // close/quit confirmations suppressed in-app — so ⌘W closes synchronously and teardown never
    // blocks on an alert.
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Workroom-split scenario (issue #112): start already in a root + workroom split so the group
    // title bar renders on launch without a flaky XCUITest drag.
    if workroomSplit { app.launchArguments += ["-WorkroomUITestWorkroomSplit", "1"] }
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  /// On-screen panes: one `terminal.pane` accessibility element per rendered leaf.
  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  /// One strip chip per terminal. The chip's title and close button both inherit the
  /// `terminal.tab.<title>` identifier, so match only the title StaticText to count chips 1:1.
  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 6) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Wait until the fixture workroom's terminal renders. The fixture auto-selects the workroom on
  /// launch, so this just confirms the first pane mounted — no sidebar clicking (and no XCTSkip:
  /// the fixture is always present).
  private func openWorkroom(_ app: XCUIApplication) throws {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(app).firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
  }

  func testSplitRightCreatesTwoPanes() throws {
    let app = launchedApp()
    try openWorkroom(app)
    assertCount(panes(app), reaches: 1)
    app.typeKey("d", modifierFlags: .command)  // ⌘D → Split Right
    assertCount(panes(app), reaches: 2)
  }

  /// Regression for the close-collapse blank bug: closing one pane of a split must leave exactly one
  /// rendered pane (the survivor), not a detached/blank surface.
  func testCloseSplitPaneLeavesOneRenderedPane() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    app.typeKey("w", modifierFlags: .command)  // close the focused (new) pane → collapse to solo
    assertCount(panes(app), reaches: 1)  // survivor still renders
  }

  func testNestedSplitCreatesThreePanes() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    app.typeKey("d", modifierFlags: [.command, .shift])  // ⇧⌘D → Split Down (nested)
    assertCount(panes(app), reaches: 3)
  }

  /// The issue's "terminal tabs should remain for each terminal, even if it is in a pane."
  func testSplitKeepsATabPerTerminal() throws {
    let app = launchedApp()
    try openWorkroom(app)
    let initial = tabs(app).count
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    assertCount(tabs(app), reaches: initial + 1)  // the split's new terminal has its own strip tab
  }

  /// Regression: closing a pane from its own right-click menu must not crash the app. The
  /// `rightMouseDown` handler balances its press with a RELEASE *after* the menu closes; closing the
  /// pane used to free the surface mid-modal, so that RELEASE hit a freed surface (use-after-free).
  func testRightClickCloseTerminalDoesNotCrash() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)  // split → two panes
    assertCount(panes(app), reaches: 2)

    panes(app).firstMatch.rightClick()
    // "Close Terminal" titles two items — the right-click menu's AND the File-menu ⌘W command (which
    // lives in the collapsed menu bar with a zero frame). Click the on-screen, hittable one.
    let closeItems = app.menuItems.matching(NSPredicate(format: "title == %@", "Close Terminal"))
    XCTAssertTrue(
      closeItems.firstMatch.waitForExistence(timeout: 3),
      "right-click menu should offer Close Terminal")
    let close = closeItems.allElementsBoundByIndex.first { $0.isHittable } ?? closeItems.firstMatch
    close.click()

    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 3), "app must stay alive after Close Terminal")
    assertCount(panes(app), reaches: 1)  // collapsed to the survivor, no crash
  }

  // MARK: Split group title-bar context menu (issue #112)

  /// The split group title bars — one `workroom.pane.titlebar` per split member.
  private func titlebars(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "workroom.pane.titlebar")
  }

  /// A title bar identifies its member by accessibility label: a workroom member's label is
  /// `"<project>, workroom <name>"` (always contains the word "workroom", even once relabelled),
  /// while a project-root member's label is just the project name.
  private func workroomTitleBar(_ app: XCUIApplication) -> XCUIElement {
    titlebars(app).matching(NSPredicate(format: "label CONTAINS[c] %@", "workroom")).firstMatch
  }
  private func rootTitleBar(_ app: XCUIApplication) -> XCUIElement {
    titlebars(app)
      .matching(NSPredicate(format: "NOT (label CONTAINS[c] %@)", "workroom")).firstMatch
  }

  /// A hittable context-menu item with this exact title. Filters out the collapsed menu-bar
  /// duplicates (zero frame, not hittable) so an assertion reflects the on-screen context menu — the
  /// same reasoning `testRightClickCloseTerminalDoesNotCrash` uses. Titles use the real ellipsis "…".
  private func hittableMenuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
    app.menuItems.matching(NSPredicate(format: "title == %@", title))
      .allElementsBoundByIndex.first { $0.isHittable }
  }

  /// Right-clicking a **workroom** split member's title bar shows the full workroom menu: Close,
  /// Remove from Split, Set Label…, and Delete Workroom….
  func testSplitTitleBarMenuOnWorkroomMember() throws {
    let app = launchedApp(workroomSplit: true)
    try openWorkroom(app)
    assertCount(titlebars(app), reaches: 2)  // root + workroom members

    let bar = workroomTitleBar(app)
    XCTAssertTrue(bar.waitForExistence(timeout: 6), "the workroom member's title bar should render")
    bar.rightClick()

    XCTAssertNotNil(hittableMenuItem(app, "Close"), "workroom member menu should offer Close")
    XCTAssertNotNil(
      hittableMenuItem(app, "Remove from Split"), "…and Remove from Split")
    XCTAssertNotNil(
      hittableMenuItem(app, "Set Label…"), "…and Set Label…")
    XCTAssertNotNil(
      hittableMenuItem(app, "Delete Workroom…"), "…and Delete Workroom…")
  }

  /// A **project-root** split member is never labelled or deletable, but it can still be closed or
  /// popped out of the split — so its menu offers Close + Remove from Split only.
  func testSplitTitleBarMenuOnRootMember() throws {
    let app = launchedApp(workroomSplit: true)
    try openWorkroom(app)
    assertCount(titlebars(app), reaches: 2)

    let bar = rootTitleBar(app)
    XCTAssertTrue(bar.waitForExistence(timeout: 6), "the root member's title bar should render")
    bar.rightClick()

    XCTAssertNotNil(hittableMenuItem(app, "Close"), "root members can be closed")
    XCTAssertNotNil(hittableMenuItem(app, "Remove from Split"), "…and removed from the split")
    XCTAssertNil(hittableMenuItem(app, "Delete Workroom…"), "but root members aren't deletable")
    XCTAssertNil(hittableMenuItem(app, "Set Label…"), "and aren't labelled")
  }

  /// "Remove from Split" pops the member out of the split — the split collapses to a solo view, so
  /// its group title bars disappear (a solo pane has none). The workroom keeps running.
  func testSplitTitleBarRemoveFromSplitCollapses() throws {
    let app = launchedApp(workroomSplit: true)
    try openWorkroom(app)
    assertCount(titlebars(app), reaches: 2)

    workroomTitleBar(app).rightClick()
    let remove = hittableMenuItem(app, "Remove from Split")
    XCTAssertNotNil(remove, "Remove from Split should be offered")
    remove?.click()

    assertCount(titlebars(app), reaches: 0)  // collapsed to solo → no group title bars
    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 6), "the survivor still renders")
  }

  /// The store-flag → RootView confirmation bridge fires from the split title bar, and the menu acts
  /// on the member it was opened on even when that member is NOT focused. Focus the root first, then
  /// delete the (non-focused) workroom member → its confirmation dialog appears.
  func testSplitTitleBarDeleteTargetsMemberEvenWhenNotFocused() throws {
    let app = launchedApp(workroomSplit: true)
    try openWorkroom(app)
    assertCount(titlebars(app), reaches: 2)

    rootTitleBar(app).click()  // focus the ROOT member → the workroom member is now non-focused
    workroomTitleBar(app).rightClick()
    let delete = hittableMenuItem(app, "Delete Workroom…")
    XCTAssertNotNil(delete, "Delete Workroom… should be offered on the workroom member")
    delete?.click()

    XCTAssertTrue(
      app.buttons["Delete"].waitForExistence(timeout: 4),
      "deleting from the split title bar should raise the confirmation dialog")
    app.typeKey(.escape, modifierFlags: [])  // dismiss (cancel role) without deleting
  }

  /// Full label round-trip through the NEW split title-bar menu: Set Label… opens the label sheet
  /// (the sheet bridge works from the split bar too), and once a label is set the menu flips to
  /// Edit Label… + Remove Label. Guards the `label != nil` branch from silent regression.
  func testSplitTitleBarLabelRoundTrip() throws {
    let app = launchedApp(workroomSplit: true)
    try openWorkroom(app)
    XCTAssertTrue(workroomTitleBar(app).waitForExistence(timeout: 6))

    // Unlabelled: the menu offers Set Label… (not Edit Label…).
    workroomTitleBar(app).rightClick()
    XCTAssertNil(hittableMenuItem(app, "Edit Label…"))
    let setLabel = hittableMenuItem(app, "Set Label…")
    XCTAssertNotNil(setLabel, "an unlabelled workroom member should offer Set Label…")
    setLabel?.click()

    // The label sheet opens from the split bar; enter a label and save.
    let field = app.textFields["workroomLabel.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 4), "Set Label… should open the label sheet")
    field.click()
    field.typeText("My Label")
    app.buttons["workroomLabel.saveButton"].click()
    XCTAssertTrue(field.waitForNonExistence(timeout: 4), "the sheet should dismiss after Save")

    // Labelled: the menu now offers Edit Label… + Remove Label, not Set Label….
    workroomTitleBar(app).rightClick()
    XCTAssertNotNil(
      hittableMenuItem(app, "Edit Label…"), "a labelled member should offer Edit Label…")
    XCTAssertNotNil(hittableMenuItem(app, "Remove Label"), "…and Remove Label")
    XCTAssertNil(hittableMenuItem(app, "Set Label…"))
  }
}
