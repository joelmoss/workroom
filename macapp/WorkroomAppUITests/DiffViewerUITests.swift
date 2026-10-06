import XCTest

/// UI tests for the Changes → diff viewer flow (issue #66). Fixture mode serves canned diffs
/// (`UITestFixture.diff(for:)`) so a real `DiffViewer` renders without shelling out to git against
/// the fake temp workroom — and the canned content encodes the `DiffSource`, so each test asserts it
/// opened the *right* revision (git worktree or a commit).
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run), so
/// these are excluded from `make app-test` (the unit gate) via the UI-test scheme.
final class DiffViewerUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Launch in fixture mode: the fixture workroom is a git working tree (flat changed-file list).
  ///
  /// `diffViewMode` is passed on EVERY launch, never left implicit. `Defaults[.diffViewMode]` lives in
  /// the app's real (Dev) UserDefaults domain and is a Settings picker, so a test that says nothing
  /// inherits the developer's last choice — and the unified assertions here (`diff.line`) then fail on
  /// a machine sitting on side-by-side, which is exactly how three of them sat red. The fixture mirrors
  /// this into `Defaults` at launch (`UITestFixture.applyFixtureDefaults`).
  private func launchedApp(diffViewMode: String = "unified")
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestDiffViewMode", diffViewMode]
    // These tests click changed-file rows down to the seventh, and with the default equal thirds the
    // Changes section only shows the first five: the rest are scrolled out of view but still found,
    // and a click on one lands on the History pane drawn over its accessibility frame. Give Changes
    // the room.
    app.launchArguments += ["-WorkroomUITestInspectorWeights", "6,1,1,1"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// A changed-file row, by its stable per-path accessibility id.
  private func fileRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    element(app, id: "changes.file.\(path)")
  }

  /// The diff tab chip for an open file (the chip id is `terminal.tab.<basename>`).
  private func diffTab(_ app: XCUIApplication, _ basename: String) -> XCUIElement {
    element(app, id: "terminal.tab.\(basename)")
  }

  /// The pane title bar naming `path` (issue #136; it moved out of the footer into the pane's own
  /// title bar in issue #150). Matched on the text as well as the
  /// id, because a split shows one bar per pane and the id alone can't say WHICH file. The segment's
  /// string arrives as the element's `value`, not its `label` — macOS exposes a SwiftUI `Text`'s
  /// accessibility string that way — so match either and don't depend on which.
  private func paneTitlePath(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
          "terminal.pane.titlebar", path, path)
      )
      .firstMatch
  }

  private func paneTitleShowsPath(_ app: XCUIApplication, _ path: String, _ timeout: Double = 6)
    -> Bool
  {
    paneTitlePath(app, path).waitForExistence(timeout: timeout)
  }

  /// True once a rendered diff line carries `marker` in its label — proves the diff body rendered
  /// the expected source's content (the canned diff tags each line with its `DiffSource`).
  private func diffLineExists(
    _ app: XCUIApplication, contains marker: String, _ timeout: Double = 6
  )
    -> Bool
  {
    let line = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "diff.line", marker))
      .firstMatch
    return line.waitForExistence(timeout: timeout)
  }

  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  // MARK: git, preview semantics, selection, double-click, per-tab toggle

  /// One launch walks the Changes → diff flow in order. Steps share the preview slot
  /// (`TerminalSessions.openContentPreview`), so the order is load-bearing:
  ///
  /// 1. The Changes panel is a flat list; clicking a file opens the git worktree diff.
  /// 2. A single click opens a PREVIEW tab; clicking a second file replaces it in place (≤1
  ///    preview): the first file's tab is gone, the second's is present. Doubles as the coverage
  ///    for the pane title bar's path (issue #136), because retarget is the hard case:
  ///    `openContentPreview` mutates `tab.content` and keeps the tab id, so the pane view is NOT
  ///    rebuilt — the same stale-content-on-a-stable-view shape as the DiffViewer `.task` re-fire
  ///    loop. Both files are nested, so these also prove a DIRECTORY reaches the title bar, which
  ///    the basename-only chip id can't show.
  /// 3. The changed-file row whose diff is focused reads as selected, and selection follows focus.
  /// 4. A double click PERSISTS the tab: it survives the next single-click preview (the two
  ///    coexist), proving double-click skipped preview mode.
  /// 5. LAST: the tab toolbar's diff view-mode toggle starts on the global default (unified) and
  ///    flips THIS tab to side-by-side — without changing the global setting. It goes last because
  ///    the per-tab `diffViewModeOverride` persists across a preview retarget
  ///    (`TerminalSessions`), so any `diff.line` assertion after it would go dark.
  func testChangedFileClicksOpenPreviewPersistAndToggleDiffMode() throws {
    let app = launchedApp(diffViewMode: "unified")  // the global default the toggle overrides
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Step 1: a git file opens the `git diff HEAD` diff.
    let routesRow = fileRow(app, "config/routes.rb")
    XCTAssertTrue(routesRow.waitForExistence(timeout: 10), "git changed-file row should render")
    routesRow.click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      diffLineExists(app, contains: "git-worktree"), "a git file opens the `git diff HEAD` diff")

    // Steps 2 and 3: retarget the preview (routes.rb → user.rb → routes.rb) and follow selection.
    let userRow = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(userRow.waitForExistence(timeout: 10))
    userRow.click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      waitExists(diffTab(app, "routes.rb"), false),
      "the preview tab retargets in place — the first file's tab is replaced, not kept")
    XCTAssertTrue(
      paneTitleShowsPath(app, "app/models/user.rb"),
      "the pane title bar names the whole path, not just the chip's `user.rb`")
    XCTAssertTrue(waitSelected(userRow, true), "the row whose diff is focused should be selected")

    routesRow.click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      waitExists(diffTab(app, "user.rb"), false),
      "the preview tab retargets in place — the first file's tab is replaced, not kept")
    XCTAssertTrue(
      paneTitleShowsPath(app, "config/routes.rb"), "the pane title follows the retarget")
    XCTAssertTrue(
      waitExists(paneTitlePath(app, "app/models/user.rb"), false),
      "and stops naming the file the pane no longer shows")
    XCTAssertTrue(waitSelected(routesRow, true), "the newly focused file's row becomes selected")
    XCTAssertTrue(
      waitSelected(userRow, false), "selection follows focus — the previous row deselects")

    // Step 4: the double click's first click retargets the routes.rb preview to user.rb, so
    // routes.rb is absent before the next single click re-opens it (not a leftover tab).
    userRow.doubleClick()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      waitExists(diffTab(app, "routes.rb"), false),
      "the double click retargets the routes.rb preview, so it is gone before the next click")

    routesRow.click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      diffTab(app, "user.rb").exists,
      "the persisted (double-clicked) tab survives the next preview — both coexist")

    // Step 5: re-focus the persisted user.rb tab (its override is still unset, so unified), and
    // wait for something specific to ITS diff — routes.rb's diff also has a `removed` line.
    userRow.click()
    XCTAssertTrue(paneTitleShowsPath(app, "app/models/user.rb"), "focus is back on user.rb")
    XCTAssertTrue(
      diffLineExists(app, contains: "marker app/models/user.rb"),
      "the focused tab shows user.rb's diff")
    XCTAssertTrue(diffLineExists(app, contains: "removed"), "opens unified (the global default)")
    XCTAssertFalse(
      element(app, id: "diff.side.right").exists, "no side-by-side column before the toggle")

    let sideBySideButton = element(app, id: "tab.toolbar.diffSideBySide")
    XCTAssertTrue(
      sideBySideButton.waitForExistence(timeout: 6), "the tab toolbar shows the diff-mode toggle")
    sideBySideButton.click()

    XCTAssertTrue(
      sideCellExists(app, id: "diff.side.left", contains: "removed"),
      "toggling renders the old (left) column's deletion cell for this tab")
    XCTAssertTrue(
      sideCellExists(app, id: "diff.side.right", contains: "added"),
      "toggling renders side-by-side for this tab")
  }

  /// Wait for an element's `isSelected` to reach `want`.
  @discardableResult
  private func waitSelected(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "isSelected == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  // MARK: side-by-side (issue #66)

  /// In side-by-side mode a modified file renders two columns: deletions in the left (old) column,
  /// additions in the right (new) column, each with its own accessibility id. We assert the
  /// two-column STRUCTURE — not the async-applied highlight a11y value, which XCUITest can't observe
  /// reliably (a documented false-negative; see `DiffHighlightUITests`).
  func testSideBySideRendersTwoColumns() throws {
    let app = launchedApp(diffViewMode: "sideBySide")
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.file.app/models/user.rb").waitForExistence(timeout: 10))

    let row = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "working-copy file row should render")
    row.click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))

    XCTAssertTrue(
      sideCellExists(app, id: "diff.side.left", contains: "removed"),
      "the old (left) column renders a deletion cell")
    XCTAssertTrue(
      sideCellExists(app, id: "diff.side.right", contains: "added"),
      "the new (right) column renders an addition cell")
  }

  /// True once a side-by-side cell with the given id carries `marker` in its accessibility label.
  private func sideCellExists(
    _ app: XCUIApplication, id: String, contains marker: String, _ timeout: Double = 6
  ) -> Bool {
    let cell = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", id, marker))
      .firstMatch
    return cell.waitForExistence(timeout: timeout)
  }
}
