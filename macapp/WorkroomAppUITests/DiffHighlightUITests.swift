import XCTest

/// Fixture UI tests for syntax-highlighted diffs (tree-sitter, phase 1). XCUITest can't see colours,
/// so each diff line exposes an accessibility *value* — `highlighted` once a coloured
/// `AttributedString` was applied, else `plain`. In fixture mode `UITestFixture` serves a canned Ruby
/// file (parsed by the real bundled grammar) for `.rb` paths and no content for others, so we can
/// assert: highlight applies for a known language, deletions stay plain, and an unknown language
/// still renders (plain) rather than breaking.
///
/// Run with `make app-uitest` on a real GUI login session (excluded from the headless unit gate).
final class DiffHighlightUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    // Every assertion below is on `diff.line`, which only the UNIFIED renderer emits — so pin the
    // layout instead of inheriting `Defaults[.diffViewMode]` from the developer's Dev domain (a
    // machine left on side-by-side turned these red; see `UITestFixture.applyFixtureDefaults`).
    app.launchArguments += ["-WorkroomUITestDiffViewMode", "unified"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func fileRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
    element(app, id: "changes.file.\(path)")
  }

  /// A diff line matching a predicate, e.g. highlighted lines or a specific labelled line.
  private func diffLine(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement
  {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: format, arguments: getVaList(args))).firstMatch
  }

  /// Open a working-copy file's diff and wait for its tab.
  private func openDiff(_ app: XCUIApplication, _ path: String, tab basename: String) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(element(app, id: "changes.workingCopy").waitForExistence(timeout: 10))
    let row = fileRow(app, path)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "row \(path) should render")
    row.click()
    XCTAssertTrue(element(app, id: "terminal.tab.\(basename)").waitForExistence(timeout: 6))
  }

  /// A known-language (Ruby) file's diff gets syntax highlighting applied to added/context lines.
  ///
  /// SKIPPED: highlighting is applied asynchronously (parse + query off-main, then `highlightedLines`
  /// updates the line's `.accessibilityValue` to "highlighted"). SwiftUI doesn't post an a11y
  /// value-changed notification for that async @State update, so XCUITest's a11y snapshot keeps seeing
  /// the initial "plain" value and never observes the change — a deterministic false-negative, not an
  /// app bug. The full pipeline (fixture diff + content → detect → real parse/query → map) is covered
  /// deterministically and headlessly by
  /// `DiffHighlightMapperTests.testFixtureRubyDiffPipelineProducesHighlightedLines` (in the CI unit
  /// gate); the sibling render tests below still prove the diff itself renders.
  func testRubyDiffIsHighlighted() throws {
    throw XCTSkip(
      "XCUITest can't observe the async-applied highlight a11y value; covered headlessly by "
        + "DiffHighlightMapperTests.testFixtureRubyDiffPipelineProducesHighlightedLines.")
  }

  /// Deletions are never highlighted — the removed line renders plain even in a highlighted diff.
  func testDeletionLineRendersPlain() throws {
    let app = launchedApp()
    openDiff(app, "app/models/user.rb", tab: "user.rb")
    // Let highlighting settle (a highlighted line appears first).
    _ = diffLine(app, "identifier == %@ AND value == %@", "diff.line", "highlighted")
      .waitForExistence(timeout: 8)
    let highlightedDeletion = diffLine(
      app, "identifier == %@ AND label CONTAINS %@ AND value == %@", "diff.line", "removed",
      "highlighted")
    XCTAssertFalse(highlightedDeletion.exists, "a deletion line must never be highlighted")
  }

  /// An unknown-language file still renders its diff (plain) — highlighting failure never breaks it.
  func testUnknownLanguageRendersPlain() throws {
    let app = launchedApp()
    openDiff(app, ".env.example", tab: ".env.example")
    // The diff renders…
    XCTAssertTrue(
      element(app, id: "diff.line").waitForExistence(timeout: 8), "the diff still renders")
    // …and no line is highlighted (no grammar for this path).
    let highlighted = diffLine(app, "identifier == %@ AND value == %@", "diff.line", "highlighted")
    XCTAssertFalse(
      highlighted.waitForExistence(timeout: 3),
      "an unknown language renders plain, not highlighted")
  }
}
