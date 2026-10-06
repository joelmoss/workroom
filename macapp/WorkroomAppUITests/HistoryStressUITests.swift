import XCTest

/// History at scale — the UI-tier half of the WORKROOM-2B App Hang fix.
///
/// Launched with `-WorkroomUITestManyCommits 800`, so the fixture serves 800 commits across seven
/// authors. Two properties matter here, and neither is visible to a unit test:
///
/// 1. **The pane realizes only what it draws.** The eager `VStack` this replaced built every loaded row
///    — 800 rows of MD5 + Gravatar-URL + avatar work per body pass. If the count of realized rows is in
///    the hundreds, the list went back to being eager.
/// 2. **The app stays interactive at that size.** A 2-second budget, not the 8 seconds an earlier draft
///    used: 8 seconds would pass straight through the very hang being fixed.
///
/// Plus the lazy-stack failure modes that only exist once a list is lazy: scrolling away and back
/// (recycled row state), expanding a row mid-list, and selecting a row that started off-screen.
///
/// Run per-method: `xcodebuild … -only-testing:WorkroomAppUITests/HistoryStressUITests/<method>`.
final class HistoryStressUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(commits: Int = 800) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestManyCommits", String(commits)]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func els(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: id)
  }

  private func selectWorkroom(_ app: XCUIApplication) {
    let row = app.buttons.matching(
      NSPredicate(
        format: "identifier == %@ AND label == %@", "sidebar.workroom.uitest-room", "uitest-room")
    ).firstMatch
    if row.waitForExistence(timeout: 10) { row.click() }
  }

  /// Same recipe as `HistoryPushStateUITests.openHistory`: prime with Files so the Changes click is
  /// always a switch, then select the workroom so the selection re-triggers the load.
  private func openHistory(_ app: XCUIApplication) {
    XCTAssertTrue(el(app, "activitySection.files").waitForExistence(timeout: 10))
    el(app, "activitySection.files").click()
    XCTAssertTrue(el(app, "activitySection.changes").waitForExistence(timeout: 8))
    el(app, "activitySection.changes").click()
    XCTAssertTrue(el(app, "inspector.header.History").waitForExistence(timeout: 8))

    selectWorkroom(app)

    if !els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 8) {
      let refresh = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "Refresh history")).firstMatch
      if refresh.exists { refresh.click() }
    }
    XCTAssertTrue(
      els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 10),
      "the stress fixture's history rows render")
  }

  /// One launch, three ordered steps (they share the 800-commit launch, so they run as a chain).
  ///
  /// 1. Realized-row count, BEFORE any scroll or click: the pane realizes only what it draws.
  /// 2. Scroll away and back: recycled rows must come back live and open their changeset.
  /// 3. A row that started off-screen opens ITS OWN changeset.
  ///
  /// `testLargeHistoryStaysInteractive` is deliberately NOT part of this chain: the Makefile skips it
  /// by name in routine runs, so merging it would get the whole chain skipped.
  func testLargeHistoryIsLazyAndItsRowsStayUsableAfterScrolling() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    // Step 1: only the visible rows are realized.
    //
    // Anti-vacuity guard: with only the default five-commit fixture, "fewer than 100 realized rows"
    // would pass while proving nothing. Stress commits carry `s…` short ids (the default fixture's are
    // `fixc000…`), and each row's accessibility label leads with its short id — so this asserts the
    // stress page is genuinely in play.
    //
    // Note what is NOT used here: "Load more". That button sits BELOW 800 rows, so a lazy list
    // legitimately hasn't realized it — its absence is evidence FOR laziness, not against the fixture.
    XCTAssertTrue(
      els(app, "HistoryRow").matching(NSPredicate(format: "label BEGINSWITH %@", "s000")).firstMatch
        .waitForExistence(timeout: 8),
      "the stress fixture's synthetic commits must be what the pane is showing")

    let realized = els(app, "HistoryRow").count
    XCTAssertGreaterThan(realized, 0, "some rows must be on screen")
    // No exact number: how far past the viewport SwiftUI realizes is its business and moves between OS
    // releases. "Nowhere near all 800" is the property that distinguishes lazy from eager.
    XCTAssertLessThan(
      realized, 100,
      "\(realized) of 800 rows are in the accessibility tree — that many realized rows means the list "
        + "is building the whole window again (the WORKROOM-2B amplifier)")

    // Step 2: scroll away and back. No changeset is open yet (nothing above clicked a row), so the
    // `ChangesetDetail` wait below really does prove this click opened one.
    let firstRow = els(app, "HistoryRow").element(boundBy: 0)
    let scroller = app.scrollViews.firstMatch
    XCTAssertTrue(scroller.waitForExistence(timeout: 8))
    XCTAssertFalse(
      el(app, "ChangesetDetail").exists, "no changeset is open before the first row is clicked")

    // Recycled row state is the lazy-stack hazard: rows destroyed on scroll-out must come back live,
    // not blank or stale.
    scroller.scroll(byDeltaX: 0, deltaY: -1200)
    XCTAssertTrue(els(app, "HistoryRow").element(boundBy: 0).waitForExistence(timeout: 8))
    scroller.scroll(byDeltaX: 0, deltaY: 1200)

    XCTAssertTrue(
      firstRow.waitForExistence(timeout: 8), "the top rows come back after scrolling back")
    let firstLabel = firstRow.label
    firstRow.click()
    XCTAssertTrue(
      el(app, "ChangesetDetail").waitForExistence(timeout: 4),
      "a recycled row still opens its changeset")

    // Step 3: back at the top (asserted, not assumed), scroll down to a row that started off-screen.
    // Row 0's changeset is still open, so the `ChangesetDetail` wait below cannot prove anything on
    // its own; the short-id check, which must differ from row 0's, is what pins the clicked commit.
    XCTAssertTrue(
      els(app, "HistoryRow").matching(NSPredicate(format: "label BEGINSWITH %@", "s000")).firstMatch
        .waitForExistence(timeout: 8),
      "history is scrolled back to the top before the next step")

    // A row that started off-screen: scrolling realizes it, and clicking it must select THAT commit —
    // the case index-based selection can't express once rows come and go.
    scroller.scroll(byDeltaX: 0, deltaY: -600)
    let row = els(app, "HistoryRow").element(boundBy: 1)
    XCTAssertTrue(row.waitForExistence(timeout: 8))
    let label = row.label
    XCTAssertNotEqual(label, firstLabel, "the second step clicks a different commit than the first")
    row.click()

    XCTAssertTrue(el(app, "ChangesetDetail").waitForExistence(timeout: 4))
    // The row's label leads with the commit's short id; the detail must be showing that commit.
    let shortID = String(label.prefix(while: { $0 != "," }))
    let firstShortID = String(firstLabel.prefix(while: { $0 != "," }))
    XCTAssertNotEqual(shortID, firstShortID)
    // Scoped to the detail header's leaves (they all carry its `ChangesetDetail` id): the row's own
    // hover card also shows the short id, and an app-wide match used to pass on the card alone.
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "ChangesetDetail")
        .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", shortID, shortID))
        .firstMatch.waitForExistence(timeout: 4),
      "the changeset that opened belongs to the row that was clicked (\(shortID))")
  }

  func testLargeHistoryStaysInteractive() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    openHistory(app)

    let started = Date()
    els(app, "HistoryRow").element(boundBy: 0).click()
    XCTAssertTrue(
      el(app, "ChangesetDetail").waitForExistence(timeout: 2),
      "clicking a row on an 800-commit page must open its changeset within 2s — a budget under the "
        + "2000 ms app-hang threshold, so a stalled main thread fails instead of passing slowly")
    XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
  }
}
