import XCTest

/// UI test for the changeset detail content tab (issue #59): clicking a History row opens the
/// commit's detail as a content tab in the main pane — a metadata header, its changed-file list, and
/// the selected file's diff (which reuses `DiffViewer`). Single-click previews; a quick double-click
/// persists (so a later preview of another commit doesn't retarget it away).
///
/// Runs against the deterministic fixture VCS backend (`FixtureVCSProvider`), so the History rows and
/// changeset are canned — no live repo. Run with `make app-uitest` on a real GUI login session.
final class ChangesetDetailUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// Click the fixture workroom's sidebar name row (several elements share its identifier — the
  /// chevron, run button, badges — so match the selectable name row by label). Selecting it sets the
  /// target History reads; done *after* History is showing so the selection change re-triggers the
  /// pane's load.
  private func selectWorkroom(_ app: XCUIApplication) {
    let row = app.buttons.matching(
      NSPredicate(
        format: "identifier == %@ AND label == %@", "sidebar.workroom.uitest-room", "uitest-room")
    ).firstMatch
    if row.waitForExistence(timeout: 10) { row.click() }
  }

  private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func els(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: id)
  }

  @discardableResult
  private func waitExists(_ e: XCUIElement, _ want: Bool = true, _ timeout: TimeInterval = 8)
    -> Bool
  {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
  }

  /// Open the History section and wait for its fixture-canned rows. Priming with Files guarantees the
  /// History click is a SWITCH (which always opens), independent of the section the shared defaults
  /// launched active. The workroom is selected AFTER History is showing, so the selection change
  /// re-triggers the pane's load (avoids the race where the pane's first load ran with no selection).
  private func openHistory(_ app: XCUIApplication) {
    XCTAssertTrue(el(app, "activitySection.files").waitForExistence(timeout: 10))
    el(app, "activitySection.files").click()
    XCTAssertTrue(waitExists(el(app, "activitySection.history")))
    el(app, "activitySection.history").click()
    XCTAssertTrue(
      el(app, "inspector.header.History").waitForExistence(timeout: 8), "History pane renders")

    selectWorkroom(app)

    // Rows load asynchronously once a workroom is selected; the header's Refresh button forces a
    // reload if the first render lagged — belt-and-braces so the click-through isn't gated on timing.
    if !els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 6) {
      let refresh = el(app, "arrow.clockwise")
      if refresh.exists { refresh.click() }
    }
    XCTAssertTrue(
      els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 8),
      "fixture history rows render")
  }

  /// Single-clicking a History row opens the commit's changeset detail: the detail view, its
  /// changed-file list (≥1 row), and a rendered diff (unified `diff.line` or side-by-side
  /// `diff.side.left`).
  func testHistoryRowOpensChangesetDetail() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    els(app, "HistoryRow").element(boundBy: 0).click()

    XCTAssertTrue(waitExists(el(app, "ChangesetDetail")), "the changeset detail opens as a tab")
    XCTAssertTrue(
      els(app, "ChangesetFileRow").element(boundBy: 0).waitForExistence(timeout: 8),
      "the changed-file list renders")
    let diffLine = els(app, "diff.line").element(boundBy: 0)
    let sideLine = els(app, "diff.side.left").element(boundBy: 0)
    XCTAssertTrue(
      waitExists(diffLine) || sideLine.exists,
      "the selected file's diff renders (unified or side-by-side)")
  }

  /// A double-click on a History row PERSISTS its changeset tab: opening a different commit's preview
  /// afterward adds a second tab rather than retargeting the first (which a preview would). Asserted
  /// via the two tab chips (`terminal.tab.<title>`) coexisting.
  func testDoubleClickPersistsChangesetTab() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    // Double-click the newest row → persist "Fixture commit 1".
    els(app, "HistoryRow").element(boundBy: 0).doubleClick()
    XCTAssertTrue(
      waitExists(el(app, "terminal.tab.Fixture commit 1")), "the persisted chip appears")

    // Single-click the next row → preview "Fixture commit 2". If the first were a preview it would be
    // retargeted; because it was persisted, both chips coexist.
    els(app, "HistoryRow").element(boundBy: 1).click()
    XCTAssertTrue(waitExists(el(app, "terminal.tab.Fixture commit 2")), "the preview chip appears")
    XCTAssertTrue(
      el(app, "terminal.tab.Fixture commit 1").exists,
      "the persisted changeset tab survives opening another commit's preview")
  }

  /// Regression: closing ALL tabs of the selected workroom empties the History inspector. The sidebar
  /// row stays selected (the detail drops to its "No terminal" placeholder), so the inspector must
  /// follow — History keys on the *active* target, which is nil once no tabs remain. (Changes + PR
  /// use the same `inspectorTargetID` gate.)
  func testHistoryEmptiesWhenAllTabsClosed() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)  // History active + fixture rows rendered (asserts a HistoryRow exists)

    XCTAssertTrue(
      els(app, "HistoryRow").element(boundBy: 0).exists, "history has rows while a tab is open")

    // Close every terminal tab (the fixture opens one on launch; idle shells close w/o a confirm).
    let chips = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
    let initial = chips.count
    for _ in 0..<max(1, initial) { app.typeKey("w", modifierFlags: .command) }
    XCTAssertTrue(waitExists(chips.firstMatch, false), "all terminal tabs closed")

    // History empties — its rows are gone, replaced by the no-active-workspace placeholder.
    XCTAssertTrue(
      waitExists(els(app, "HistoryRow").element(boundBy: 0), false),
      "History empties once the selected workroom has no open tabs")
  }
}
