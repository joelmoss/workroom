import XCTest

/// UI tests for the Changes → diff viewer flow (issue #66). Fixture mode serves canned diffs
/// (`UITestFixture.diff(for:)`) so a real `DiffViewer` renders without shelling out to git/jj against
/// the fake temp workroom — and the canned content encodes the `DiffSource`, so each test asserts it
/// opened the *right* revision (jj `@`, jj `@-`, or git worktree).
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run), so
/// these are excluded from `make app-test` (the unit gate) via the UI-test scheme.
final class DiffViewerUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Launch in fixture mode. `gitWorkroom: true` flips the fixture workroom from the default jj
  /// change to a git working tree (flat changed-file list) so the `.gitWorktree` diff is reachable.
  ///
  /// `diffViewMode` is passed on EVERY launch, never left implicit. `Defaults[.diffViewMode]` lives in
  /// the app's real (Dev) UserDefaults domain and is a Settings picker, so a test that says nothing
  /// inherits the developer's last choice — and the unified assertions here (`diff.line`) then fail on
  /// a machine sitting on side-by-side, which is exactly how three of them sat red. The fixture mirrors
  /// this into `Defaults` at launch (`UITestFixture.applyFixtureDefaults`).
  private func launchedApp(gitWorkroom: Bool = false, diffViewMode: String = "unified")
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestDiffViewMode", diffViewMode]
    if gitWorkroom { app.launchArguments += ["-WorkroomUITestGitWorkroom", "1"] }
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

  /// The pane footer's path segment naming `path` (issue #136). Matched on the text as well as the
  /// id, because a split shows one bar per pane and the id alone can't say WHICH file. The segment's
  /// string arrives as the element's `value`, not its `label` — macOS exposes a SwiftUI `Text`'s
  /// accessibility string that way — so match either and don't depend on which.
  private func footerPath(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
          "terminal.statusBar.path", path, path)
      )
      .firstMatch
  }

  private func footerPathExists(_ app: XCUIApplication, _ path: String, _ timeout: Double = 6)
    -> Bool
  {
    footerPath(app, path).waitForExistence(timeout: timeout)
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

  // MARK: jj

  /// Clicking a working-copy (`@`) file opens a diff tab whose body is the jj working-copy diff.
  func testJJWorkingCopyFileOpensDiffTab() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "jj Working Copy header should render")

    let row = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "working-copy file row should render")
    row.click()

    XCTAssertTrue(
      diffTab(app, "user.rb").waitForExistence(timeout: 6), "a diff tab opens for the clicked file")
    XCTAssertTrue(
      diffLineExists(app, contains: "jj-working-copy"),
      "the working-copy file opens the jj `@` diff")
  }

  // MARK: git

  /// In git-workroom mode the Changes panel is a flat list; clicking a file opens the git worktree diff.
  func testGitWorktreeFileOpensDiff() throws {
    let app = launchedApp(gitWorkroom: true)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let row = fileRow(app, "config/routes.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "git changed-file row should render")
    row.click()

    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      diffLineExists(app, contains: "git-worktree"), "a git file opens the `git diff HEAD` diff")
  }

  // MARK: preview semantics

  /// A single click opens a PREVIEW tab; clicking a second file replaces it in place (≤1 preview):
  /// the first file's tab is gone, the second's is present.
  ///
  /// Doubles as the coverage for the footer's path segment (issue #136), because retarget is the
  /// hard case: `openContentPreview` mutates `tab.content` and keeps the tab id, so the pane view is
  /// NOT rebuilt — the same stale-content-on-a-stable-view shape as the DiffViewer `.task` re-fire
  /// loop. Both files are nested, so these also prove a DIRECTORY reaches the footer, which the
  /// basename-only chip id can't show.
  func testSingleClickPreviewIsReplacedInPlace() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

    fileRow(app, "app/models/user.rb").click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      footerPathExists(app, "app/models/user.rb"),
      "the pane footer names the whole path, not just the chip's `user.rb`")

    fileRow(app, "config/routes.rb").click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      waitExists(diffTab(app, "user.rb"), false),
      "the preview tab retargets in place — the first file's tab is replaced, not kept")
    XCTAssertTrue(
      footerPathExists(app, "config/routes.rb"), "the footer follows the retarget")
    XCTAssertTrue(
      waitExists(footerPath(app, "app/models/user.rb"), false),
      "and stops naming the file the pane no longer shows")
  }

  /// The changed-file row whose diff is focused reads as selected, and selection follows focus:
  /// opening a second file's diff deselects the first.
  func testFocusedFileRowIsSelectedAndFollowsFocus() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

    let userRow = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(userRow.waitForExistence(timeout: 10))
    userRow.click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      waitSelected(userRow, true), "the row whose diff is focused should be selected")

    let routesRow = fileRow(app, "config/routes.rb")
    routesRow.click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(waitSelected(routesRow, true), "the newly focused file's row becomes selected")
    XCTAssertTrue(
      waitSelected(userRow, false), "selection follows focus — the previous row deselects")
  }

  /// Wait for an element's `isSelected` to reach `want`.
  @discardableResult
  private func waitSelected(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "isSelected == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// A double click PERSISTS the tab: it survives the next single-click preview (the two coexist),
  /// proving double-click skipped preview mode.
  func testDoubleClickPersistsAndCoexistsWithNextPreview() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

    fileRow(app, "app/models/user.rb").doubleClick()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))

    fileRow(app, "config/routes.rb").click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      diffTab(app, "user.rb").exists,
      "the persisted (double-clicked) tab survives the next preview — both coexist")
  }

  // MARK: side-by-side (issue #66)

  /// In side-by-side mode a modified file renders two columns: deletions in the left (old) column,
  /// additions in the right (new) column, each with its own accessibility id. We assert the
  /// two-column STRUCTURE — not the async-applied highlight a11y value, which XCUITest can't observe
  /// reliably (a documented false-negative; see `DiffHighlightUITests`).
  func testSideBySideRendersTwoColumns() throws {
    let app = launchedApp(diffViewMode: "sideBySide")
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

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

  /// The tab toolbar's diff view-mode toggle starts on the global default (unified) and flips THIS
  /// tab to side-by-side when its side-by-side button is clicked — without changing the global setting.
  func testTabToolbarToggleSwitchesThisFileToSideBySide() throws {
    let app = launchedApp(diffViewMode: "unified")  // the global default this toggle overrides
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

    let row = fileRow(app, "app/models/user.rb")
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(diffLineExists(app, contains: "removed"), "opens unified (the global default)")

    let sideBySideButton = element(app, id: "tab.toolbar.diffSideBySide")
    XCTAssertTrue(
      sideBySideButton.waitForExistence(timeout: 6), "the tab toolbar shows the diff-mode toggle")
    sideBySideButton.click()

    XCTAssertTrue(
      sideCellExists(app, id: "diff.side.right", contains: "added"),
      "toggling renders side-by-side for this tab")
  }
}
