import XCTest

@testable import Workroom

/// The commit sheet's pure rules. None of these is reachable through SwiftUI, which is why they live
/// in `CommitDraft` rather than in the view — the same reason `VCSSyncPresenter` exists.
final class CommitDraftTests: XCTestCase {

  // MARK: - Message composition

  func testSummaryOnlyMessageHasNoTrailingBlankLines() {
    XCTAssertEqual(CommitDraft.message(summary: "Fix the toolbar", body: ""), "Fix the toolbar")
    XCTAssertEqual(CommitDraft.message(summary: "  Fix it  ", body: "   "), "Fix it")
  }

  /// The blank line between subject and body is the convention every downstream tool splits on.
  func testSummaryAndBodyAreSeparatedByABlankLine() {
    XCTAssertEqual(
      CommitDraft.message(summary: "Subject", body: "Body line one.\nBody line two."),
      "Subject\n\nBody line one.\nBody line two.")
  }

  func testWhitespaceIsTrimmedFromBothHalves() {
    XCTAssertEqual(
      CommitDraft.message(summary: "\n Subject \n", body: "\n\n Body \n\n"), "Subject\n\nBody")
  }

  // MARK: - Splitting a stored message back into the fields

  /// The jj prefill round-trip. Reading only the first line — which is all
  /// `JJCommitChanges.description` carries — and then describing again would silently discard the
  /// body, which is why the sheet reads the FULL description and splits it here.
  func testSplitRecoversSummaryAndBody() {
    let parts = CommitDraft.split(message: "Subject line\n\nBody one.\nBody two.")
    XCTAssertEqual(parts.summary, "Subject line")
    XCTAssertEqual(parts.body, "Body one.\nBody two.")
  }

  func testSplitOfASingleLineHasNoBody() {
    let parts = CommitDraft.split(message: "Just a subject\n")
    XCTAssertEqual(parts.summary, "Just a subject")
    XCTAssertEqual(parts.body, "")
  }

  func testSplitOfAnEmptyMessageIsEmpty() {
    let parts = CommitDraft.split(message: "")
    XCTAssertEqual(parts.summary, "")
    XCTAssertEqual(parts.body, "")
  }

  /// Round-trips, so describing an existing change and re-opening the sheet cannot drift.
  func testMessageAndSplitRoundTrip() {
    let composed = CommitDraft.message(summary: "Subject", body: "Body one.\n\nBody two.")
    let parts = CommitDraft.split(message: composed)
    XCTAssertEqual(parts.summary, "Subject")
    XCTAssertEqual(parts.body, "Body one.\n\nBody two.")
  }

  // MARK: - Selection

  private func file(_ path: String) -> ChangedFile {
    ChangedFile(path: path, change: .modified, oldPath: nil)
  }

  func testNothingExcludedSelectsEverything() {
    let files = [file("a"), file("b")]
    XCTAssertEqual(CommitDraft.selected(from: files, excluding: []).map(\.path), ["a", "b"])
  }

  /// **The core of the selection model.** Exclusions are stored, not selections, so a file written
  /// while the dialog is open — by a coding agent in this app's own terminal, continuously — arrives
  /// CHECKED rather than resetting the user's deliberate choices or being committed unseen.
  func testANewlyAppearedFileArrivesIncluded() {
    let before = [file("a"), file("b")]
    let excluded: Set<String> = ["b"]
    XCTAssertEqual(CommitDraft.selected(from: before, excluding: excluded).map(\.path), ["a"])

    let after = [file("a"), file("b"), file("c")]
    XCTAssertEqual(
      CommitDraft.selected(from: after, excluding: excluded).map(\.path), ["a", "c"],
      "the new file is included, and b stays excluded — no reset, no silent inclusion")
  }

  /// A path that leaves the change set drops out on its own, so the excluded set never needs pruning.
  func testAVanishedFileNeedsNoPruning() {
    let files = [file("a")]
    XCTAssertEqual(CommitDraft.selected(from: files, excluding: ["b", "c"]).map(\.path), ["a"])
  }

  // MARK: - Button label

  func testCommitLabelNamesTheCount() {
    XCTAssertEqual(CommitDraft.commitLabel(selectedCount: 1, vcs: "git"), "Commit 1 file")
    XCTAssertEqual(CommitDraft.commitLabel(selectedCount: 12, vcs: "git"), "Commit 12 files")
  }

  /// jj offers no per-file selection, so a count would imply a choice that isn't on offer.
  func testCommitLabelOmitsTheCountForJJ() {
    XCTAssertEqual(CommitDraft.commitLabel(selectedCount: 12, vcs: "jj"), "Commit")
  }

  // MARK: - Blocked reasons

  private func reason(
    vcs: String = "git", summary: String = "Subject", selected: Int = 1, total: Int = 1,
    conflicted: Bool = false, sequencer: String? = nil
  ) -> String? {
    CommitDraft.blockedReason(
      vcs: vcs, summary: summary, selectedCount: selected, totalCount: total,
      conflicted: conflicted, sequencer: sequencer)
  }

  func testNothingBlocksAValidCommit() {
    XCTAssertNil(reason())
  }

  func testAnEmptySummaryBlocks() {
    XCTAssertEqual(reason(summary: "   "), "Write a summary to describe this change.")
  }

  func testZeroSelectedFilesBlocksForGit() {
    XCTAssertEqual(reason(selected: 0, total: 4), "Select at least one file to commit.")
  }

  /// jj commits the whole change, so a zero count is meaningless there — and an empty jj change is
  /// still describable, which is why the box is offered at all.
  func testZeroFilesDoesNotBlockJJ() {
    XCTAssertNil(reason(vcs: "jj", selected: 0, total: 0))
  }

  /// A parked sequencer outranks everything: several of those states make a path-limited commit
  /// outright invalid, and finishing one is the user's call, not ours.
  func testSequencerOutranksEveryOtherReason() {
    XCTAssertEqual(
      reason(summary: "", selected: 0, total: 0, conflicted: true, sequencer: "merge"),
      "A merge is in progress. Finish it in the terminal before committing.")
  }

  /// git refuses unmerged paths outright. jj would accept them, but "Commit" reading as "done" over
  /// unresolved conflicts is a UX decision rather than a capability one, so both say the same thing.
  func testConflictsBlockBothBackends() {
    for vcs in ["git", "jj"] {
      XCTAssertEqual(
        reason(vcs: vcs, conflicted: true),
        "Some files still have unresolved conflicts. Resolve them first.")
    }
  }

  // MARK: - Blocked reasons: the message-only verbs

  /// Amend and Describe rewrite a message and take no pathspec, so the file-count rules are not their
  /// preconditions — gating them on the primary's reason would block a legitimate reword.
  func testTheMessageOnlyVerbIgnoresTheFileCountRules() {
    XCTAssertNil(
      CommitDraft.messageOnlyBlockedReason(
        summary: "Reworded", conflicted: false, sequencer: nil),
      "no file selection is needed to rewrite a message")
  }

  /// But it answers to the repo's state, which it previously did not: the button stayed live over
  /// unresolved conflicts that the primary refused and the engine then rejected anyway.
  func testTheMessageOnlyVerbStillAnswersToRepoState() {
    XCTAssertEqual(
      CommitDraft.messageOnlyBlockedReason(summary: "Reworded", conflicted: true, sequencer: nil),
      "Some files still have unresolved conflicts. Resolve them first.")
    XCTAssertEqual(
      CommitDraft.messageOnlyBlockedReason(
        summary: "Reworded", conflicted: false, sequencer: "rebase"),
      "A rebase is in progress. Finish it in the terminal before committing.")
  }

  /// **One trimming rule for both buttons.** The secondary used to trim `.whitespaces` where this
  /// trims `.whitespacesAndNewlines`, so a summary of a single newline blocked Commit while Amend
  /// would rewrite the last commit's message with it.
  func testBothVerbsAgreeOnWhatAnEmptySummaryIs() {
    for blank in ["", "   ", "\n", " \n\t "] {
      XCTAssertEqual(
        CommitDraft.messageOnlyBlockedReason(summary: blank, conflicted: false, sequencer: nil),
        "Write a summary to describe this change.",
        "the secondary verb must reject \(blank.debugDescription)")
      XCTAssertEqual(
        reason(summary: blank), "Write a summary to describe this change.",
        "and so must the primary, identically")
    }
  }
}
