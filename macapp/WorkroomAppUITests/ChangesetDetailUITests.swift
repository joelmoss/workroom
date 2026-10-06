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

  /// Open the History section and wait for its fixture-canned rows. History is a section of the
  /// **Changes** pane, so this switches to that pane (priming with Files guarantees the click is a
  /// SWITCH, which always opens, independent of the section the shared defaults launched active). The
  /// section is expanded on arrival because `UITestFixture.applyFixtureDefaults` pins
  /// `inspectorLayout` to all-expanded at launch — nothing to click here. The workroom is selected
  /// AFTER History is showing, so the selection change re-triggers the pane's load (avoids the race
  /// where the pane's first load ran with no selection).
  private func openHistory(_ app: XCUIApplication) {
    XCTAssertTrue(el(app, "activitySection.files").waitForExistence(timeout: 10))
    el(app, "activitySection.files").click()
    XCTAssertTrue(waitExists(el(app, "activitySection.changes")))
    el(app, "activitySection.changes").click()
    XCTAssertTrue(
      el(app, "inspector.header.History").waitForExistence(timeout: 8),
      "the History section renders")

    selectWorkroom(app)

    // Rows load asynchronously once a workroom is selected; the header's Refresh button forces a
    // reload if the first render lagged — belt-and-braces so the click-through isn't gated on timing.
    // Matched by its a11y label, not the glyph: the Changes section header in the same pane carries an
    // identical `arrow.clockwise` refresh button.
    if !els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 6) {
      let refresh = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "Refresh history")).firstMatch
      if refresh.exists { refresh.click() }
    }
    XCTAssertTrue(
      els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 8),
      "fixture history rows render")
  }

  /// One launch, one ordered chain (each commit returns the SAME fixture changeset — three files,
  /// the renamed `src/moved.rb → lib/moved.rb`, 24 insertions / 8 deletions — so any History row can
  /// serve any assertion):
  ///
  /// 1. A double-click on the newest row PERSISTS its changeset tab (the chip appears) and opens the
  ///    commit's changeset detail: the detail view, its +/- summary, changed-file list (≥1 row), a
  ///    rendered diff (unified `diff.line` or side-by-side `diff.side.left`), and the moved file's
  ///    row reading `old → new`. Done first, so the persisted chip can't be a leftover preview (a
  ///    single click would give the preview chip the same title) and `ChangesetDetail` can't already
  ///    be on screen. (Double-clicking a row already open as a preview has its own regression test,
  ///    `testDoubleClickingARowAlreadyOpenAsAPreviewPersistsIt`.)
  /// 2. Single-clicking the next row previews "Fixture commit 2". If the first were a preview it
  ///    would be retargeted; because it was persisted, both chips coexist.
  /// 3. Regression, LAST because it destroys every tab: closing ALL tabs of the selected workroom
  ///    empties the History inspector. History keys on the *active* target, which is nil once no
  ///    tabs remain. (Changes + PR use the same `inspectorTargetID` gate.)
  func testChangesetDetailOpensPersistsAndHistoryEmptiesWhenAllTabsClosed() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)  // History active + fixture rows rendered (asserts a HistoryRow exists)

    // 1. Double-click the newest row → persist "Fixture commit 1" and open its detail.
    els(app, "HistoryRow").element(boundBy: 0).doubleClick()
    XCTAssertTrue(
      waitExists(el(app, "terminal.tab.Fixture commit 1")), "the persisted chip appears")
    XCTAssertTrue(waitExists(el(app, "ChangesetDetail")), "the changeset detail opens as a tab")

    // The header shows the changeset's +/- line-count summary (fixture: 24 insertions, 8 deletions).
    // It renders as a combined StaticText whose content is its `value` (the header's `ChangesetDetail`
    // id propagates onto the leaf, so match on the spoken count text, not the id). Scoped to
    // `staticTexts` rather than every element — see `HistoryPushStateUITests.headerSaysNotPushed` for
    // why an unscoped predicate query times out now that the inspector stacks three sections.
    let summary = app.staticTexts.matching(
      NSPredicate(format: "value CONTAINS %@", "24 insertions, 8 deletions")
    ).firstMatch
    XCTAssertTrue(waitExists(summary), "the header shows the +/- line-count summary")

    XCTAssertTrue(
      els(app, "ChangesetFileRow").element(boundBy: 0).waitForExistence(timeout: 8),
      "the changed-file list renders")
    let diffLine = els(app, "diff.line").element(boundBy: 0)
    let sideLine = els(app, "diff.side.left").element(boundBy: 0)
    XCTAssertTrue(
      waitExists(diffLine) || sideLine.exists,
      "the selected file's diff renders (unified or side-by-side)")

    // A moved file's row reads `old → new`. The rename is ONE row (the delete is paired with the
    // add), so this dimmed path line is the only place the old path appears — if it regressed to
    // the bare path, the row would look like a plain add at a path the user never created.
    // Matched on the row's spoken content rather than its `Text`: `ChangesetFileRow` combines its
    // children, so the name + path line surface as the row element's own label/value. The fixture's
    // renamed entry is src/moved.rb → lib/moved.rb; scoped to the file rows (an unscoped predicate
    // query over every element times out now).
    let moved = els(app, "ChangesetFileRow").matching(
      NSPredicate(
        format: "label CONTAINS %@ OR value CONTAINS %@", "src/moved.rb \u{2192} lib/moved.rb",
        "src/moved.rb \u{2192} lib/moved.rb")
    ).firstMatch
    XCTAssertTrue(waitExists(moved), "the renamed row shows `old → new`, not just the new path")

    // 2. Single-click the next row → preview "Fixture commit 2"; both chips coexist.
    els(app, "HistoryRow").element(boundBy: 1).click()
    XCTAssertTrue(waitExists(el(app, "terminal.tab.Fixture commit 2")), "the preview chip appears")
    XCTAssertTrue(
      el(app, "terminal.tab.Fixture commit 1").exists,
      "the persisted changeset tab survives opening another commit's preview")

    // 3. Close every tab (the fixture opens one terminal on launch, plus the two changeset tabs
    // above; idle shells close w/o a confirm). Last: it destroys all tabs.
    XCTAssertTrue(
      els(app, "HistoryRow").element(boundBy: 0).exists, "history has rows while a tab is open")
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

  /// Regression: open a commit with a single click, let the pointer rest, then double-click the same
  /// row to keep it. That double-click must persist the tab — proved by previewing the next commit,
  /// which would retarget a preview but leaves a persisted tab alone. It used to stay a preview: the
  /// resting pointer raised the row's hover card, and the double-click's first click only closed it.
  func testDoubleClickingARowAlreadyOpenAsAPreviewPersistsIt() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)
    let row = els(app, "HistoryRow").element(boundBy: 0)

    row.click()
    XCTAssertTrue(
      waitExists(el(app, "terminal.tab.Fixture commit 1")), "the single click opens a preview")
    Thread.sleep(forTimeInterval: 1.5)  // past the hover card's 0.5s dwell, pointer still resting

    row.doubleClick()
    els(app, "HistoryRow").element(boundBy: 1).click()
    XCTAssertTrue(waitExists(el(app, "terminal.tab.Fixture commit 2")), "the next commit previews")
    XCTAssertTrue(
      el(app, "terminal.tab.Fixture commit 1").exists,
      "the double-click persisted commit 1, so previewing commit 2 left its tab open")
  }
}
