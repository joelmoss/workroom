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

  /// Defaulted fields: a commit built without the divergence args is non-divergent with no siblings.
  func testDefaultsAreNonDivergent() {
    let c = VCSCommit(
      commitID: "c1", shortID: "c1", changeID: "xl", summary: "s", body: "",
      authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: false)
    XCTAssertFalse(c.isDivergent)
    XCTAssertTrue(c.divergentSiblings.isEmpty)
    XCTAssertNil(c.divergentLabel)
  }
}
