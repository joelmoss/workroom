import XCTest

@testable import Workroom

/// The activity bar's navigation logic is a pure reducer (`ActivityBarReducer`) so every branch is
/// verified here in the fast unit gate rather than only through a GUI-only XCUITest. The three input
/// sources behave differently on purpose — icon-click toggles the active pane, a keyboard shortcut
/// always opens, and the title-bar toggle flips visibility without changing the selection.
final class ActivityBarReducerTests: XCTestCase {
  private typealias State = ActivityBarReducer.State

  // MARK: iconClick

  /// Clicking a DIFFERENT section's icon opens + selects it.
  func testIconClickOnInactiveSectionOpensAndSelects() {
    let next = ActivityBarReducer.reduce(
      State(active: .changes, visible: true), .iconClick(.files))
    XCTAssertEqual(next, State(active: .files, visible: true))
  }

  /// Clicking the ACTIVE section's icon while its pane is open collapses the pane (bar stays).
  func testIconClickOnActiveVisibleSectionTogglesClosed() {
    let next = ActivityBarReducer.reduce(
      State(active: .changes, visible: true), .iconClick(.changes))
    XCTAssertEqual(next, State(active: .changes, visible: false))
  }

  /// Clicking the active section's icon while the pane is HIDDEN re-opens it (doesn't toggle off).
  func testIconClickOnActiveHiddenSectionOpens() {
    let next = ActivityBarReducer.reduce(
      State(active: .changes, visible: false), .iconClick(.changes))
    XCTAssertEqual(next, State(active: .changes, visible: true))
  }

  // MARK: shortcut

  /// A keyboard shortcut ALWAYS opens + selects — even when that section's pane is already open, so
  /// ⌥⌘C on an open Changes pane keeps it open rather than surprising the user by toggling it closed.
  func testShortcutAlwaysOpens() {
    XCTAssertEqual(
      ActivityBarReducer.reduce(State(active: .changes, visible: true), .shortcut(.changes)),
      State(active: .changes, visible: true))
    XCTAssertEqual(
      ActivityBarReducer.reduce(State(active: .files, visible: false), .shortcut(.changes)),
      State(active: .changes, visible: true))
  }

  // MARK: toggleVisibility

  /// The title-bar toggle flips pane visibility WITHOUT changing which section is selected.
  func testToggleVisibilityKeepsSelection() {
    XCTAssertEqual(
      ActivityBarReducer.reduce(State(active: .files, visible: true), .toggleVisibility),
      State(active: .files, visible: false))
    XCTAssertEqual(
      ActivityBarReducer.reduce(State(active: .files, visible: false), .toggleVisibility),
      State(active: .files, visible: true))
  }

  /// Regression guard for the FilesPanel activation gate (`activeInspectorSection == .files`):
  /// selecting Files makes it active (the tree activates); selecting Changes makes it inactive (the
  /// Files pane unmounts and stops listing). The tree's actual (de)activation is exercised end-to-end
  /// in `ActivityBarUITests`; this pins the state transition the gate reads.
  func testSelectingFilesThenChangesFlipsActiveSection() {
    let toFiles = ActivityBarReducer.reduce(
      State(active: .changes, visible: true), .iconClick(.files))
    XCTAssertEqual(toFiles.active, .files)
    let backToChanges = ActivityBarReducer.reduce(toFiles, .iconClick(.changes))
    XCTAssertEqual(backToChanges.active, .changes)
  }
}
