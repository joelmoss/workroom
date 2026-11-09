import WorkroomDomain
import XCTest

@testable import Workroom

/// The New Workroom picker's filter + highlight core (issue #81). Pure value logic (no AppKit /
/// SwiftUI), so every branch runs headless — the sheet presentation, focus, and scroll-to-highlight
/// are verified in the UI test. Mirrors `EdgeRevealReducerTests` / `TabReorderMathTests`.
final class ProjectPickerModelTests: XCTestCase {
  private func project(_ path: String) -> Project {
    Project(path: path, vcs: "git", workrooms: [])
  }

  private lazy var projects = [
    project("/code/alpha"),
    project("/code/Bravo"),
    project("/work/charlie"),
  ]

  // MARK: filtered

  func testEmptyQueryReturnsAllInOrder() {
    let result = ProjectPickerModel.filtered(projects, query: "")
    XCTAssertEqual(result.map(\.displayName), ["alpha", "Bravo", "charlie"])
  }

  func testWhitespaceOnlyQueryReturnsAll() {
    XCTAssertEqual(ProjectPickerModel.filtered(projects, query: "   ").count, 3)
  }

  func testPartialMatch() {
    let result = ProjectPickerModel.filtered(projects, query: " char")
    XCTAssertEqual(result.map(\.displayName), ["charlie"])
  }

  func testCaseInsensitiveMatch() {
    // "bravo" lower-cases the project's "Bravo" displayName.
    XCTAssertEqual(
      ProjectPickerModel.filtered(projects, query: "bravo").map(\.displayName), ["Bravo"])
  }

  func testQueryIsTrimmed() {
    XCTAssertEqual(
      ProjectPickerModel.filtered(projects, query: "  alpha  ").map(\.displayName), ["alpha"])
  }

  func testMatchesDisplayNameNotFullPath() {
    // "code" is a parent-dir segment, not part of any displayName ("alpha"/"Bravo") — so no match.
    XCTAssertTrue(ProjectPickerModel.filtered(projects, query: "code").isEmpty)
  }

  func testNoMatchReturnsEmpty() {
    XCTAssertTrue(ProjectPickerModel.filtered(projects, query: "zzz").isEmpty)
  }

  // MARK: fuzzy + multi-token (issue #94 follow-up)

  func testFuzzySubsequenceMatch() {
    // "aph" is a subsequence of "alpha" (a·l·p·h·a) but of neither "Bravo" nor "charlie".
    XCTAssertEqual(
      ProjectPickerModel.filtered(projects, query: "aph").map(\.displayName), ["alpha"])
  }

  func testFuzzyMultiTokenAllMustMatch() {
    XCTAssertTrue(ProjectPickerModel.filtered(projects, query: "alpha zzz").isEmpty)
  }

  // MARK: clamped

  func testClampedWithinRange() {
    XCTAssertEqual(ProjectPickerModel.clamped(1, count: 3), 1)
  }

  func testClampedBelowZero() {
    XCTAssertEqual(ProjectPickerModel.clamped(-5, count: 3), 0)
  }

  func testClampedAboveMax() {
    XCTAssertEqual(ProjectPickerModel.clamped(99, count: 3), 2)
  }

  func testClampedEmptyListIsZero() {
    XCTAssertEqual(ProjectPickerModel.clamped(0, count: 0), 0)
    XCTAssertEqual(ProjectPickerModel.clamped(5, count: 0), 0)
  }

  // MARK: move

  func testMoveUpAtTopStaysZero() {
    XCTAssertEqual(ProjectPickerModel.move(highlight: 0, by: -1, count: 3), 0)
  }

  func testMoveDownAtBottomStaysLast() {
    XCTAssertEqual(ProjectPickerModel.move(highlight: 2, by: 1, count: 3), 2)
  }

  func testMoveWithinRange() {
    XCTAssertEqual(ProjectPickerModel.move(highlight: 0, by: 1, count: 3), 1)
    XCTAssertEqual(ProjectPickerModel.move(highlight: 2, by: -1, count: 3), 1)
  }

  func testMoveInEmptyListStaysZero() {
    XCTAssertEqual(ProjectPickerModel.move(highlight: 0, by: 1, count: 0), 0)
  }

  // MARK: selection (the Return-on-empty no-op guard)

  func testSelectionReturnsHighlightedProject() {
    let filtered = ProjectPickerModel.filtered(projects, query: "")
    XCTAssertEqual(
      ProjectPickerModel.selection(filtered: filtered, highlight: 1)?.displayName, "Bravo")
  }

  func testSelectionNilOnEmptyList() {
    XCTAssertNil(ProjectPickerModel.selection(filtered: [], highlight: 0))
  }

  func testSelectionNilOnOutOfRangeIndex() {
    let filtered = [project("/x/one")]
    XCTAssertNil(ProjectPickerModel.selection(filtered: filtered, highlight: 5))
  }
}

/// The New Workroom dialog's steps: projects, places, then a boxd or exe.dev place's host options.
final class NewWorkroomDialogStepTests: XCTestCase {
  /// Value: protects=Back goes one step at a time (host options → that project's places →
  /// projects), and the list keys pass to host options' fields; fails_when=Back skips a step,
  /// changes project, shows on the projects, or ↑/↓/←/⏎ drive the list from host options;
  /// why_new=the Step enum replaced seven scattered checks (review finding); seam=none;
  /// no_claim=focus and highlight on Back (NewWorkroomPlacesUITests)
  func testBackGoesOneStepAndHostOptionsKeepTheKeys() {
    let project = Project(path: "/step", vcs: "git", workrooms: [])
    typealias Step = NewWorkroomDialog.Step

    XCTAssertEqual(Step.configure(project, .boxd).back, .places(project))
    XCTAssertEqual(Step.places(project).back, .projects)
    XCTAssertNil(Step.projects.back, "the projects have a Back")

    XCTAssertTrue(Step.projects.takesListKeys)
    XCTAssertTrue(Step.places(project).takesListKeys)
    XCTAssertFalse(Step.configure(project, .exeDev).takesListKeys)
  }
}
