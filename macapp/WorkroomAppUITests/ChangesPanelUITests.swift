import XCTest

/// UI tests for the Changes panel: a conflicted file's status reaching its row and the sidebar, and
/// the row context menu opening a file in the in-app viewer.
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// this is excluded from `make app-test` (the unit gate) via a separate scheme.
final class ChangesPanelUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArguments
    app.launch()
    app.activate()
    return app
  }

  /// An element by its exact accessibility identifier. Not a label match: a row's filename also
  /// appears in its hover "Open file <path>" button's label.
  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Wait until `el` reaches the wanted existence state.
  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 4) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  // MARK: conflicted files (per-file conflict status)

  /// A conflicted file must render as its OWN state in the Changes panel, all the way from the VCS
  /// layer to the row: the status read classifies an unmerged path as `.conflicted`, and the row's
  /// composed accessibility label must say so.
  ///
  /// The badge glyph/colour themselves are NOT assertable here — the row is
  /// `.accessibilityElement(children: .ignore)`, so the `Text(letter)` inside it never reaches the
  /// accessibility tree. `ChangeBadgeTests` pins the `"!"` + `tokens.conflict` mapping (including that
  /// it differs from deletion's and modification's); this test pins that the conflicted KIND survives
  /// the trip into the panel, which a unit test on the mapping can't show.
  func testConflictedFileRendersAsConflicted() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestConflict", "1"])
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.file.app/models/user.rb").waitForExistence(timeout: 10))

    let conflictedRow = element(app, id: "changes.file.app/models/merge_me.rb")
    XCTAssertTrue(conflictedRow.waitForExistence(timeout: 10), "the conflicted row should render")
    XCTAssertTrue(
      conflictedRow.label.contains("conflicted"),
      "the conflicted row reads as conflicted; got \(conflictedRow.label)")

    // Negative control: a neighbouring modified row must NOT read as conflicted — proves the label
    // tracks the file's kind rather than the panel being conflicted wholesale.
    let modifiedRow = element(app, id: "changes.file.Gemfile")
    XCTAssertTrue(modifiedRow.waitForExistence(timeout: 6), "the modified row should render")
    XCTAssertTrue(
      modifiedRow.label.contains("modified"), "Gemfile reads as modified; got \(modifiedRow.label)")
    XCTAssertFalse(
      modifiedRow.label.contains("conflicted"),
      "a modified file must not read as conflicted; got \(modifiedRow.label)")
  }

  /// The conflict must also reach the sidebar's aggregate signal: a conflicted workroom outranks
  /// dirty in `WorkroomStatus.aggregateWeight`, so a **collapsed** project row shows
  /// `VCSAggregateDot` reading "project conflicted" rather than "project changes".
  ///
  /// The dot renders only while collapsed (`ProjectSidebar`: expanded projects show each row's own
  /// dot), and the fixture starts every project expanded — so the test collapses it first by clicking
  /// the project-name disclosure button.
  func testCollapsedProjectRowAggregatesTheConflict() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestConflict", "1"])
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.file.app/models/user.rb").waitForExistence(timeout: 10))

    // Expanded: no aggregate dot yet.
    let dot = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "project conflicted")).firstMatch
    XCTAssertFalse(dot.exists, "the aggregate dot belongs to a collapsed row only")

    let workroomRow = element(app, id: "sidebar.workroom.uitest-room")
    XCTAssertTrue(
      workroomRow.waitForExistence(timeout: 6), "the workroom row renders while expanded")

    // EXACT label: the disclosure button's label is just the project name, while the row's other
    // buttons carry it inside their help text ("New workroom in UITestProject", "Project settings
    // for UITestProject") — a CONTAINS match picks one of those and would click *create*.
    let disclosure = app.buttons
      .matching(NSPredicate(format: "label == %@", "UITestProject")).firstMatch
    XCTAssertTrue(disclosure.waitForExistence(timeout: 6), "the project row should render")
    disclosure.click()

    // Prove the click actually collapsed the project — otherwise a no-op click would make the dot
    // assertion below fail for the wrong reason (or pass for one).
    XCTAssertTrue(
      waitExists(workroomRow, false), "clicking the project name collapses its children")

    XCTAssertTrue(
      dot.waitForExistence(timeout: 6),
      "a collapsed project with a conflicted workroom reads as conflicted")
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
    XCTAssertTrue(element(app, id: "changes.file.app/models/user.rb").waitForExistence(timeout: 10))

    let row = element(app, id: "changes.file.Gemfile")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Gemfile row should render")
    row.rightClick()

    let openFile = app.menuItems["Open File"]  // exact title — not "Open File in <editor>"
    XCTAssertTrue(openFile.waitForExistence(timeout: 6), "the context menu offers Open File")
    openFile.click()

    XCTAssertTrue(
      markerVisible(app, fileMarker), "the in-app viewer renders the file's real content")

    // The pane title bar names the file too (issue #136, moved there by #150) — this is the `.file`
    // half of `TabContent.filePath`;
    // `DiffViewerUITests` covers the `.diff` half (and, with its nested rows, the directory case that
    // a root-level `Gemfile` can't show). The segment's string arrives as the element's `value`, not
    // its `label` — macOS exposes a SwiftUI `Text`'s accessibility string that way (same reason the
    // viewer assertions above read `value`), so match on both rather than guessing.
    let paneTitlePath = app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
          "terminal.pane.titlebar", "Gemfile", "Gemfile")
      )
      .firstMatch
    XCTAssertTrue(
      paneTitlePath.waitForExistence(timeout: 6), "the pane title bar names the open file")
  }
}
