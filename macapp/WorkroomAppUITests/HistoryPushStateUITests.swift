import XCTest

/// UI tests for the unpushed badge on History rows and in the changeset detail header.
///
/// The fixture (`FixtureVCSProvider`) seeds all three push states plus both suppression rules, so the
/// pane must show **exactly one** badge: commit 1 is unpushed but is the working copy `@` (suppressed),
/// commit 2 is the only badged row, commit 3 is pushed, commit 4 is unknown, and the two divergent
/// siblings are unpushed but never badge. The exact count is the assertion that matters — a plain
/// `.exists` check would pass a badge-on-every-row bug just as happily.
///
/// The hover card is NOT covered here: XCUITest can't drive `.onHover`. It's covered at the view level
/// by `HistoryCommitCardTests`.
///
/// Run with `make app-uitest` on a real GUI login session.
final class HistoryPushStateUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

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

  /// Mirrors `ChangesetDetailUITests.openHistory`: History is a section of the **Changes** pane, so
  /// prime with Files (making the Changes click always a switch), then select the workroom so the
  /// selection re-triggers the load. The section arrives expanded — the fixture pins `inspectorLayout`.
  private func openHistory(_ app: XCUIApplication) {
    XCTAssertTrue(el(app, "activitySection.files").waitForExistence(timeout: 10))
    el(app, "activitySection.files").click()
    XCTAssertTrue(waitExists(el(app, "activitySection.changes")))
    el(app, "activitySection.changes").click()
    XCTAssertTrue(
      el(app, "inspector.header.History").waitForExistence(timeout: 8),
      "the History section renders")

    selectWorkroom(app)

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

  /// The row for a specific fixture commit, matched by its short id rather than by position.
  ///
  /// Position stopped being a reliable way to name a commit when the History list became a
  /// `LazyVStack` (WORKROOM-2B): unrealized rows are absent from the accessibility tree, so
  /// `element(boundBy: 2)` can silently mean a different commit than the test intends — and still pass.
  /// The short id leads each row's accessibility label for exactly this reason. Scoped to `staticTexts`
  /// (the combined row leaf) to keep the predicate query off the whole snapshot.
  private func historyRow(_ app: XCUIApplication, shortID: String) -> XCUIElement {
    // `descendants(matching: .any)`, not `staticTexts`: SwiftUI's combined row leaf is not reliably a
    // static text, and an identifier-scoped query stays indexed (fast) even though a label predicate
    // rides along.
    els(app, "HistoryRow")
      .matching(NSPredicate(format: "label BEGINSWITH %@", shortID))
      .firstMatch
  }

  /// Exactly one row badges, and it isn't every row: this is the suppression proof. `@` (unpushed),
  /// pushed and unknown rows must all stay clean.
  func testExactlyOneRowShowsTheUnpushedBadge() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    XCTAssertTrue(
      els(app, "HistoryRowUnpushed").element(boundBy: 0).waitForExistence(timeout: 8),
      "the unpushed row badges")
    let badges = els(app, "HistoryRowUnpushed").count
    let rows = els(app, "HistoryRow").count
    XCTAssertEqual(badges, 1, "only the one genuinely-unpushed non-@ commit badges")
    XCTAssertLessThan(badges, rows, "the badge is per-commit, not decoration on the whole list")
  }

  /// Expanding the divergence disclosure must not add badges: the sibling copies are unpushed in the
  /// fixture, but they sit off the `::@` line and their rows deliberately don't carry the marker.
  func testDivergentSiblingsDoNotBadge() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)
    XCTAssertTrue(
      els(app, "HistoryRowUnpushed").element(boundBy: 0).waitForExistence(timeout: 8))
    XCTAssertEqual(els(app, "HistoryRowUnpushed").count, 1)

    let toggle = el(app, "HistoryRowDiverges")
    XCTAssertTrue(toggle.waitForExistence(timeout: 8))
    toggle.click()
    XCTAssertTrue(
      els(app, "HistoryDivergentSibling").element(boundBy: 1).waitForExistence(timeout: 6),
      "the sibling copies appear")

    XCTAssertEqual(
      els(app, "HistoryRowUnpushed").count, 1,
      "expanding the divergence expander adds rows but no badges")
  }

  /// Matched app-wide on `value`, not by identifier and not scoped to the detail element.
  ///
  /// Two facts about how SwiftUI exposes this header, both verified by dumping the tree: the element
  /// carrying `identifier: 'ChangesetDetail'` is a LEAF `StaticText` whose value is just the commit
  /// summary — the metadata line is a sibling, not a descendant — and that metadata line is one combined
  /// `StaticText` whose VALUE concatenates its children ("…, Not pushed, …"). So a scoped or
  /// identifier-based query finds nothing (the same reason `ChangesetDetailUITests` matches the `+N −M`
  /// summary on `value CONTAINS`).
  ///
  /// Matching on `value` and not `label` is what keeps this honest: the History row's badge carries
  /// "Not pushed" as its accessibility LABEL, so a label match would find the row and pass regardless of
  /// what the header shows.
  ///
  /// Scoped to `staticTexts`, not `descendants(matching: .any)`: a predicate query over EVERY element
  /// has to evaluate the whole snapshot, and since History joined the Changes stack the inspector holds
  /// three sections' worth of rows at once — the unscoped version started failing with "Timed out while
  /// evaluating UI query" (identifier queries are indexed and stayed fast, which is why only the
  /// predicate ones broke).
  private func headerSaysNotPushed(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Not pushed")).firstMatch
  }

  /// Opening the badged commit states the same fact in the detail header — a badge that vanishes when
  /// you click the row would read as a bug.
  func testChangesetHeaderShowsTheUnpushedMarker() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    // Fixture commit 2 is the badged one — named by its short id, not by row position.
    let badged = historyRow(app, shortID: "fixc0002")
    XCTAssertTrue(
      badged.waitForExistence(timeout: 8), "the badged fixture commit's row is on screen")
    badged.click()
    XCTAssertTrue(waitExists(el(app, "ChangesetDetail")), "the changeset detail opens")
    XCTAssertTrue(
      waitExists(headerSaysNotPushed(app)), "the detail header states the commit isn't pushed")
  }

  /// And the pushed commit's detail says nothing: the marker is a claim about this commit, not a
  /// permanent header fixture.
  func testChangesetHeaderOmitsTheMarkerForAPushedCommit() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    // Fixture commit 3 is `.pushed`.
    let pushed = historyRow(app, shortID: "fixc0003")
    XCTAssertTrue(
      pushed.waitForExistence(timeout: 8), "the pushed fixture commit's row is on screen")
    pushed.click()
    XCTAssertTrue(waitExists(el(app, "ChangesetDetail")), "the changeset detail opens")
    XCTAssertFalse(
      headerSaysNotPushed(app).exists, "a pushed commit's header carries no unpushed marker")
  }
}
