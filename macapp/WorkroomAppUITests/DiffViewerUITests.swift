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
  private func launchedApp(gitWorkroom: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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
  func testSingleClickPreviewIsReplacedInPlace() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

    fileRow(app, "app/models/user.rb").click()
    XCTAssertTrue(diffTab(app, "user.rb").waitForExistence(timeout: 6))

    fileRow(app, "config/routes.rb").click()
    XCTAssertTrue(diffTab(app, "routes.rb").waitForExistence(timeout: 6))
    XCTAssertTrue(
      waitExists(diffTab(app, "user.rb"), false),
      "the preview tab retargets in place — the first file's tab is replaced, not kept")
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
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    // NSArgumentDomain override drives `Defaults[.diffViewMode]` (bare raw string via
    // `DiffViewMode: PreferRawRepresentable`), so the viewer opens in side-by-side.
    app.launchArguments += ["-diffViewMode", "sideBySide"]
    app.launch()
    app.activate()

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
    let app = launchedApp()  // global default mode (unified)
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
