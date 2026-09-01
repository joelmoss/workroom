import XCTest

@testable import Workroom

/// Unit tests for `ChangesetDetailView.diffPaneHasContent(state:selectedPath:)` — the pure form of
/// `hasSearchableDiff`, which drives closing the shared find model whenever `diffPane` has nothing to
/// render (loading, failed, empty changeset, or a stale selection). Regression guard for the
/// empty-changeset stale-matches bug (eng review, outside-voice finding, 2026-09-01): a changeset tab
/// retargeted to a different commit with zero changed files, without a focus change, used to leave
/// `contentFind` holding the previous commit's matches with no bar visible to show them.
final class ChangesetDetailViewFindTests: XCTestCase {
  private func commit(_ id: String = "abc123") -> VCSCommit {
    VCSCommit(
      commitID: id, shortID: String(id.prefix(8)), changeID: nil, summary: "c \(id)",
      body: "", authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: false)
  }

  private func changeset(files: [String]) -> VCSChangeset {
    VCSChangeset(
      commit: commit(), fullMessage: "",
      files: files.map { VCSChangedFile(path: $0, oldPath: nil, kind: .modified) },
      isMerge: false)
  }

  func testLoadingHasNoSearchableDiff() {
    XCTAssertFalse(
      ChangesetDetailView.diffPaneHasContent(state: .loading, selectedPath: "a.swift"))
  }

  func testFailedHasNoSearchableDiff() {
    XCTAssertFalse(
      ChangesetDetailView.diffPaneHasContent(
        state: .failed("boom"), selectedPath: "a.swift"))
  }

  func testEmptyChangesetHasNoSearchableDiff() {
    let state = ChangesetDetailView.LoadState.loaded(changeset(files: []))
    XCTAssertFalse(ChangesetDetailView.diffPaneHasContent(state: state, selectedPath: nil))
  }

  func testStaleSelectionHasNoSearchableDiff() {
    // A selectedPath left over from a PREVIOUS commit that doesn't exist in the new one.
    let state = ChangesetDetailView.LoadState.loaded(changeset(files: ["b.swift"]))
    XCTAssertFalse(
      ChangesetDetailView.diffPaneHasContent(state: state, selectedPath: "a.swift"))
  }

  func testLoadedWithMatchingSelectionHasSearchableDiff() {
    let state = ChangesetDetailView.LoadState.loaded(changeset(files: ["a.swift", "b.swift"]))
    XCTAssertTrue(
      ChangesetDetailView.diffPaneHasContent(state: state, selectedPath: "a.swift"))
  }

  func testNilSelectedPathHasNoSearchableDiff() {
    let state = ChangesetDetailView.LoadState.loaded(changeset(files: ["a.swift"]))
    XCTAssertFalse(ChangesetDetailView.diffPaneHasContent(state: state, selectedPath: nil))
  }
}
