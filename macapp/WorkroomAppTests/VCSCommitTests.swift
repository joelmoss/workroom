import XCTest

@testable import Workroom

/// `VCSCommit` divergence surface: `isDivergent` derives from the presence of `divergentSiblings`
/// (the off-`::@` copies of a divergent change), and `divergentLabel` composes jj's `id/N` marker
/// (used to label each sibling copy in the History pane's divergence expander).
final class VCSCommitTests: XCTestCase {
  private func commit(
    commitID: String = "c1", changeID: String?, changeOffset: Int?,
    siblings: [VCSCommit] = []
  ) -> VCSCommit {
    VCSCommit(
      commitID: commitID, shortID: String(commitID.prefix(8)), changeID: changeID, summary: "s",
      body: "", authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: false, changeOffset: changeOffset, divergentSiblings: siblings)
  }

  func testDivergentWhenSiblingsPresent() {
    let sibling = commit(commitID: "c2", changeID: "xl", changeOffset: 2)
    let c = commit(commitID: "c1", changeID: "xl", changeOffset: nil, siblings: [sibling])
    XCTAssertTrue(c.isDivergent)
    XCTAssertEqual(c.divergentSiblings.count, 1)
  }

  func testNotDivergentWithoutSiblings() {
    let c = commit(changeID: "xl", changeOffset: nil)
    XCTAssertFalse(c.isDivergent)
  }

  func testSiblingLabelComposesIDAndOffset() {
    let sibling = commit(commitID: "c2", changeID: "xl", changeOffset: 2)
    XCTAssertEqual(sibling.divergentLabel, "xl/2")
  }

  func testLabelNilWithoutOffset() {
    let c = commit(changeID: "xl", changeOffset: nil)
    XCTAssertNil(c.divergentLabel)
  }

  func testLabelNilWithoutChangeID() {
    // git has no change-id, so no label can form even with an offset.
    let c = commit(changeID: nil, changeOffset: 1)
    XCTAssertNil(c.divergentLabel)
  }

  /// Defaulted fields: a commit built without the divergence args is non-divergent with no siblings,
  /// and its push state is `.unknown` — the guard that adding `pushState` didn't quietly start badging
  /// every commit built by an older call site.
  func testDefaultsAreNonDivergent() {
    let c = VCSCommit(
      commitID: "c1", shortID: "c1", changeID: "xl", summary: "s", body: "",
      authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: false)
    XCTAssertFalse(c.isDivergent)
    XCTAssertTrue(c.divergentSiblings.isEmpty)
    XCTAssertNil(c.divergentLabel)
    XCTAssertEqual(c.pushState, .unknown)
    XCTAssertFalse(c.showsUnpushedBadge)
  }

  // MARK: - push state

  private func commit(pushState: VCSPushState, isWorkingCopy: Bool) -> VCSCommit {
    VCSCommit(
      commitID: "c1", shortID: "c1", changeID: nil, summary: "s", body: "", authors: [],
      timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: isWorkingCopy, pushState: pushState)
  }

  /// The badge renders for exactly one of the six (state × working-copy) combinations. `.unknown` must
  /// behave like `.pushed` here, NOT like `.unpushed`: it means "couldn't tell", and guessing would put
  /// a wrong badge on every row of a repo with no `origin`.
  func testShowsUnpushedBadgeTruthTable() {
    XCTAssertTrue(commit(pushState: .unpushed, isWorkingCopy: false).showsUnpushedBadge)
    // jj's `@` is a real commit and really is unpushed, but it's a pending change, not something you'd
    // push — the row would carry a permanent badge.
    XCTAssertFalse(commit(pushState: .unpushed, isWorkingCopy: true).showsUnpushedBadge)
    XCTAssertFalse(commit(pushState: .pushed, isWorkingCopy: false).showsUnpushedBadge)
    XCTAssertFalse(commit(pushState: .pushed, isWorkingCopy: true).showsUnpushedBadge)
    XCTAssertFalse(commit(pushState: .unknown, isWorkingCopy: false).showsUnpushedBadge)
    XCTAssertFalse(commit(pushState: .unknown, isWorkingCopy: true).showsUnpushedBadge)
  }
}
