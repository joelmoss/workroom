import XCTest

/// UI test for the jj Changes panel: the working copy (`@`) renders as a header — its
/// change-id/commit/refs + description — over a flat change list, the same shape git uses. There are
/// no disclosure groups and no separate Parent Commit group (the History panel surfaces the parent).
///
/// The git flat-list path is covered by `DiffViewerUITests.testGitWorktreeFileOpensDiff`;
/// `ChangesPanel` reaches `gitContent` only when `status.jjWorkingCopy == nil`, which the resolver
/// never sets for git (see `WorkroomStatusIntegrationTests`).
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// this is excluded from `make app-test` (the unit gate) via a separate scheme.
final class ChangesPanelUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// An element by its exact accessibility identifier — unlike the label-based `fileRow` below, which
  /// would also match the hover "Open file <path>" button (its label contains the filename too).
  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// A changed-file row, matched by its filename appearing in the row's composed a11y label.
  private func fileRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
  }

  /// Wait until `el` reaches the wanted existence state.
  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 4) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// The jj Changes panel renders the working copy as a single flat header + change list: the header
  /// (`changes.workingCopy`, carrying the change-id/commit/refs + description) exists, its changed
  /// files render as rows, and no separate Parent Commit group is shown (removed — History shows it).
  func testWorkingCopyRendersFlatWithoutParentGroup() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    XCTAssertTrue(
      element(app, id: "inspector.header.Changes").waitForExistence(timeout: 10),
      "Changes section should exist")

    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "the jj Working Copy header should render")

    // The flat change list renders its file rows directly (no disclosure to expand first).
    XCTAssertTrue(
      waitExists(fileRow(app, "Gemfile"), true),
      "the working-copy change list renders its file rows")

    // The Parent Commit group is gone — its old accessibility id must not exist.
    XCTAssertFalse(
      element(app, id: "changes.group.parentCommit").exists,
      "the Parent Commit group is no longer shown")
  }

  // MARK: in-app "Open File" (issue #117)

  /// True once the file viewer's text carries `marker`. The in-app viewer is an `NSTextView`, whose
  /// rendered string surfaces as a `textView` element's accessibility `value` — asserting the seeded
  /// marker (`UITestFixture.seededFileMarker`) proves REAL content rendered, not the "File
  /// unavailable" placeholder, so the test can't pass on routing alone (issue #117 review, Codex #1).
  /// Scoped to `.textViews` (not `.any`) so the query is fast — a `.any` value-CONTAINS scan of the
  /// whole tree times out.
  private func markerVisible(_ app: XCUIApplication, _ marker: String, _ timeout: Double = 6)
    -> Bool
  {
    let text = app.textViews
      .matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
    return text.waitForExistence(timeout: timeout)
  }

  /// The fixture seeds a real `Gemfile` (`UITestFixture.seededFileContent`) carrying this marker.
  private let fileMarker = "UITEST_FILE_MARKER"

  /// The row context menu's "Open File" opens the changed file in the in-app viewer — the
  /// keyboard-reachable path, distinct from the sibling "Open File in <editor>" (external) item. The
  /// hover-toolbar button routes through the SAME `openChangedFileInApp`, but SwiftUI `.onHover`
  /// doesn't fire under XCUITest's synthetic hover, so the button is covered by manual QA (issue #117
  /// review). We assert the viewer rendered the file's REAL content — the seeded marker appears only
  /// in the working-tree file, never in the canned diff, so it proves a FILE (not a diff) opened,
  /// which the shared `terminal.tab.<basename>` chip id can't (Codex #1/#2).
  func testContextMenuOpensFileInApp() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))

    let row = element(app, id: "changes.file.Gemfile")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Gemfile row should render")
    row.rightClick()

    let openFile = app.menuItems["Open File"]  // exact title — not "Open File in <editor>"
    XCTAssertTrue(openFile.waitForExistence(timeout: 6), "the context menu offers Open File")
    openFile.click()

    XCTAssertTrue(
      markerVisible(app, fileMarker), "the in-app viewer renders the file's real content")
  }
}
