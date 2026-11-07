import XCTest

@testable import WorkroomGit

/// Tests for character-level (intra-line) diff: the common-prefix/suffix trim that yields the
/// changed byte range, and the replacement-line pairing across a hunk. Pure — operates on diff text.
final class IntraLineDiffTests: XCTestCase {

  // MARK: - changedRanges (prefix/suffix trim → changed middle)

  func testIdenticalHasNoChange() {
    let (del, add) = IntraLineDiff.changedRanges(old: "same", new: "same")
    XCTAssertNil(del)
    XCTAssertNil(add)
  }

  func testMiddleTokenChangeInRealLine() {
    // A localized edit inside a long line: common prefix "  this." + a long common suffix, so the
    // changed middle is a small fraction of the line and passes the similarity gate.
    let old = "  this.$toggleTarget?.addEventListener('x')"
    let new = "  this.#toggle?.addEventListener('x')"
    let (del, add) = IntraLineDiff.changedRanges(old: old, new: new)
    XCTAssertEqual(del, 7..<20)  // "$toggleTarget"
    XCTAssertEqual(add, 7..<14)  // "#toggle"
  }

  func testDissimilarLinesAreGated() {
    // Index-aligned block replacement: the two lines barely overlap, so no intra-line emphasis —
    // the flat line tint carries the change instead of a solid deep-tint block.
    let (del, add) = IntraLineDiff.changedRanges(
      old: "@import '/lib/theme/index.css';", new: "@layer layout {")
    XCTAssertNil(del)
    XCTAssertNil(add)
  }

  func testHalfRewrittenLineIsGated() {
    // Over the 50% threshold → treated as a block change, not a localized edit.
    let (del, add) = IntraLineDiff.changedRanges(old: "body {", new: "    --body-margin-top: 0;")
    XCTAssertNil(del)
    XCTAssertNil(add)
  }

  func testPureInsertionMarksOnlyAddedSide() {
    // "abc" → "abXc": prefix "ab", suffix "c". Deletion middle empty → nil; addition middle = "X".
    let (del, add) = IntraLineDiff.changedRanges(old: "abc", new: "abXc")
    XCTAssertNil(del)
    XCTAssertEqual(add, 2..<3)
  }

  func testPureRemovalMarksOnlyDeletedSide() {
    let (del, add) = IntraLineDiff.changedRanges(old: "abXc", new: "abc")
    XCTAssertEqual(del, 2..<3)
    XCTAssertNil(add)
  }

  func testMultibytePrefixCountsBytesNotCharacters() {
    // "café x" → "café y": the changed char is at byte 6 (é is 2 UTF-8 bytes), not char index 5.
    let (del, add) = IntraLineDiff.changedRanges(old: "café x", new: "café y")
    XCTAssertEqual(del, 6..<7)
    XCTAssertEqual(add, 6..<7)
  }

  // MARK: - emphasis(for:) (pairing across a hunk)

  private func line(_ k: UnifiedDiff.Line.Kind, _ t: String, old: Int? = nil, new: Int? = nil)
    -> UnifiedDiff.Line
  {
    UnifiedDiff.Line(kind: k, text: t, oldLine: old, newLine: new)
  }

  private func diff(_ lines: [UnifiedDiff.Line]) -> UnifiedDiff {
    UnifiedDiff(hunks: [.init(header: "@@", lines: lines)], truncated: false, renamedFrom: nil)
  }

  func testPairsDeletionWithFollowingAddition() {
    let d = diff([
      line(.context, "ctx", old: 1, new: 1),
      line(.deletion, "foo old", old: 2),
      line(.addition, "foo new", new: 2),
    ])
    let e = IntraLineDiff.emphasis(for: d)
    XCTAssertEqual(e.deletions[2], 4..<7)  // "old"
    XCTAssertEqual(e.additions[2], 4..<7)  // "new"
  }

  func testAddOnlyBlockHasNoEmphasis() {
    let e = IntraLineDiff.emphasis(
      for: diff([line(.addition, "brand new line", new: 1), line(.addition, "another", new: 2)]))
    XCTAssertTrue(e.deletions.isEmpty)
    XCTAssertTrue(e.additions.isEmpty)
  }

  func testDeleteOnlyBlockHasNoEmphasis() {
    let e = IntraLineDiff.emphasis(for: diff([line(.deletion, "gone", old: 1)]))
    XCTAssertTrue(e.deletions.isEmpty)
    XCTAssertTrue(e.additions.isEmpty)
  }

  func testMismatchedCountsPairOnlyTheOverlap() {
    // 1 deletion, 2 additions → only the first addition pairs; the second is a pure insertion.
    let d = diff([
      line(.deletion, "x = 1", old: 1),
      line(.addition, "x = 2", new: 1),
      line(.addition, "y = 3", new: 2),
    ])
    let e = IntraLineDiff.emphasis(for: d)
    XCTAssertEqual(e.deletions[1], 4..<5)  // "1"
    XCTAssertEqual(e.additions[1], 4..<5)  // "2"
    XCTAssertNil(e.additions[2], "the unpaired extra addition is the whole-line change")
  }
}
