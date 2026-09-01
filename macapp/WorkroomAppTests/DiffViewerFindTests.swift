import SwiftUI
import XCTest

@testable import Workroom

/// Unit tests for the pure helpers behind ⌘F on diff/changeset panes: the two find-source orderings
/// (`findSource`/`findSourceSideBySide`), the `DiffLineID` identity + its debug collision guard, the
/// `AttributedString` highlight compositor (`applyFindHighlight`), and the row/match lookup helpers
/// (`rowID`, `matchedLineID`). Rendering + scroll-to-match integration is manual QA, matching this
/// feature's established convention (`FileFindTests.swift`'s doc comment on `PlainFileViewer`).
final class DiffViewerFindTests: XCTestCase {

  // MARK: Fixtures

  private func line(
    _ kind: UnifiedDiff.Line.Kind, _ text: String, old: Int? = nil, new: Int? = nil
  ) -> UnifiedDiff.Line {
    UnifiedDiff.Line(kind: kind, text: text, oldLine: old, newLine: new)
  }

  // MARK: findSource (unified ordering)

  func testFindSourceEmptyDiffIsEmpty() {
    let diff = UnifiedDiff(hunks: [], truncated: false, renamedFrom: nil)
    let (lines, ids) = DiffViewer.findSource(for: diff)
    XCTAssertTrue(lines.isEmpty)
    XCTAssertTrue(ids.isEmpty)
  }

  func testFindSourceExcludesChromeNotInHunkLines() {
    // Hunk header text and the renamed-from/truncated markers are separate fields, never part of
    // `hunk.lines` — so they can never appear in the find source no matter their content.
    let hunk = UnifiedDiff.Hunk(
      header: "@@ -1,1 +1,1 @@ findMeIfBuggy",
      lines: [line(.context, "unchanged", old: 1, new: 1)])
    let diff = UnifiedDiff(hunks: [hunk], truncated: true, renamedFrom: "old/path.swift")
    let (lines, _) = DiffViewer.findSource(for: diff)
    XCTAssertEqual(lines, ["unchanged"])
  }

  func testFindSourceConcatenatesHunksInDocumentOrder() {
    let hunk1 = UnifiedDiff.Hunk(
      header: "@@ -1,1 +1,1 @@", lines: [line(.deletion, "old1", old: 1)])
    let hunk2 = UnifiedDiff.Hunk(
      header: "@@ -5,1 +5,2 @@", lines: [line(.addition, "new5", new: 5)])
    let diff = UnifiedDiff(hunks: [hunk1, hunk2], truncated: false, renamedFrom: nil)
    let (lines, ids) = DiffViewer.findSource(for: diff)
    XCTAssertEqual(lines, ["old1", "new5"])
    XCTAssertEqual(
      ids,
      [
        DiffLineID(kind: .deletion, oldLine: 1, newLine: nil),
        DiffLineID(kind: .addition, oldLine: nil, newLine: 5),
      ])
  }

  // MARK: findSourceSideBySide

  func testFindSourceSideBySideContextRowContributesOneEntry() {
    let ctx = line(.context, "same", old: 1, new: 1)
    let row = UnifiedDiff.SideBySideRow(left: ctx, right: ctx)
    let (lines, ids) = DiffViewer.findSourceSideBySide(sbsRows: [[row]])
    XCTAssertEqual(lines, ["same"])
    XCTAssertEqual(ids, [DiffLineID(kind: .context, oldLine: 1, newLine: 1)])
  }

  func testFindSourceSideBySideRowMajorLeftThenRight() {
    // A replacement row: left=deletion, right=addition — the shape that motivated row-major order
    // (document/patch order would put ALL deletions before ALL additions; this must interleave).
    let del = line(.deletion, "old text", old: 3)
    let add = line(.addition, "new text", new: 3)
    let row = UnifiedDiff.SideBySideRow(left: del, right: add)
    let (lines, ids) = DiffViewer.findSourceSideBySide(sbsRows: [[row]])
    XCTAssertEqual(lines, ["old text", "new text"])
    XCTAssertEqual(
      ids,
      [
        DiffLineID(kind: .deletion, oldLine: 3, newLine: nil),
        DiffLineID(kind: .addition, oldLine: nil, newLine: 3),
      ])
  }

  func testFindSourceSideBySideAbsentCellsSkipped() {
    let add = line(.addition, "added only", new: 9)
    let row = UnifiedDiff.SideBySideRow(left: nil, right: add)
    let (lines, ids) = DiffViewer.findSourceSideBySide(sbsRows: [[row]])
    XCTAssertEqual(lines, ["added only"])
    XCTAssertEqual(ids, [DiffLineID(kind: .addition, oldLine: nil, newLine: 9)])
  }

  // MARK: DiffLineID / hasDuplicateIDs

  func testDiffLineIDEqualityAndHashing() {
    let a = DiffLineID(kind: .context, oldLine: 1, newLine: 1)
    let b = DiffLineID(kind: .context, oldLine: 1, newLine: 1)
    let c = DiffLineID(kind: .addition, oldLine: nil, newLine: 1)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
    XCTAssertEqual(Set([a, b, c]).count, 2)
  }

  func testHasDuplicateIDsFalseForUniqueSet() {
    let ids = [
      DiffLineID(kind: .context, oldLine: 1, newLine: 1),
      DiffLineID(kind: .addition, oldLine: nil, newLine: 2),
    ]
    XCTAssertFalse(DiffViewer.hasDuplicateIDs(ids))
  }

  func testHasDuplicateIDsTrueForDeliberateDuplicate() {
    let dup = DiffLineID(kind: .context, oldLine: 1, newLine: 1)
    XCTAssertTrue(DiffViewer.hasDuplicateIDs([dup, dup]))
  }

  // MARK: rowID

  func testRowIDPrefersLeftWhenBothPresent() {
    let left = line(.deletion, "l", old: 1)
    let right = line(.addition, "r", new: 1)
    let row = UnifiedDiff.SideBySideRow(left: left, right: right)
    XCTAssertEqual(
      DiffViewer.rowID(for: row), DiffLineID(kind: .deletion, oldLine: 1, newLine: nil))
  }

  func testRowIDFallsBackToRightWhenLeftAbsent() {
    let right = line(.addition, "r", new: 5)
    let row = UnifiedDiff.SideBySideRow(left: nil, right: right)
    XCTAssertEqual(
      DiffViewer.rowID(for: row), DiffLineID(kind: .addition, oldLine: nil, newLine: 5))
  }

  // MARK: matchedLineID

  func testMatchedLineIDInRange() {
    let ids = [
      DiffLineID(kind: .context, oldLine: 1, newLine: 1),
      DiffLineID(kind: .addition, oldLine: nil, newLine: 2),
    ]
    let match = FileFindMatch(line: 1, range: 0..<2)
    XCTAssertEqual(DiffViewer.matchedLineID(match: match, ids: ids), ids[1])
  }

  func testMatchedLineIDOutOfRangeReturnsNil() {
    let ids = [DiffLineID(kind: .context, oldLine: 1, newLine: 1)]
    let match = FileFindMatch(line: 5, range: 0..<2)
    XCTAssertNil(DiffViewer.matchedLineID(match: match, ids: ids))
  }

  func testMatchedLineIDNilMatchReturnsNil() {
    XCTAssertNil(
      DiffViewer.matchedLineID(
        match: nil, ids: [DiffLineID(kind: .context, oldLine: 1, newLine: 1)]))
  }

  // MARK: applyFindHighlight

  func testApplyFindHighlightNoHitsReturnsBaseUnchanged() {
    let base = AttributedString("hello")
    let result = DiffViewer.applyFindHighlight(base, hits: [], currentBg: .red, otherBg: .blue)
    XCTAssertEqual(result, base)
  }

  func testApplyFindHighlightCurrentVsOtherAlpha() {
    let base = AttributedString("foo bar")
    let hits: [(range: Range<Int>, isCurrent: Bool)] = [(0..<3, true), (4..<7, false)]
    let result = DiffViewer.applyFindHighlight(base, hits: hits, currentBg: .red, otherBg: .blue)
    let runs = Array(result.runs)
    let redRun = runs.first { $0.backgroundColor == .red }
    let blueRun = runs.first { $0.backgroundColor == .blue }
    XCTAssertNotNil(redRun)
    XCTAssertNotNil(blueRun)
    if let redRun { XCTAssertEqual(String(result[redRun.range].characters), "foo") }
    if let blueRun { XCTAssertEqual(String(result[blueRun.range].characters), "bar") }
  }

  /// The previously-flagged risk: `FileFindModel.highlights` computes ranges in CHARACTER offsets
  /// (`String.distance`), not UTF-8 bytes. "é" is one Character but two UTF-8 bytes, so a byte-offset
  /// bug would land the highlight on the wrong characters for the second "café".
  func testApplyFindHighlightMultiByteCharacterOffsets() {
    let base = AttributedString("café x café")
    let hit: [(range: Range<Int>, isCurrent: Bool)] = [(7..<11, true)]
    let result = DiffViewer.applyFindHighlight(base, hits: hit, currentBg: .red, otherBg: .blue)
    let redRun = result.runs.first { $0.backgroundColor == .red }
    XCTAssertNotNil(redRun)
    if let redRun { XCTAssertEqual(String(result[redRun.range].characters), "café") }
  }

  /// Compositing over an ALREADY-colored base (built the same way `emphasizedPlain` builds one, via
  /// byte-sliced runs) — proves the two highlight layers combine correctly rather than one clobbering
  /// the other's unrelated region.
  func testApplyFindHighlightComposesOverEmphasizedBase() {
    let base = DiffViewer.emphasizedPlain("foobar", fg: .primary, range: 0..<3, bg: .yellow)
    let hit: [(range: Range<Int>, isCurrent: Bool)] = [(3..<6, false)]
    let result = DiffViewer.applyFindHighlight(base, hits: hit, currentBg: .red, otherBg: .green)
    let yellowRun = result.runs.first { $0.backgroundColor == .yellow }
    let greenRun = result.runs.first { $0.backgroundColor == .green }
    XCTAssertNotNil(yellowRun, "the emphasis background must survive untouched")
    XCTAssertNotNil(greenRun, "the find background must be added alongside it")
    if let yellowRun { XCTAssertEqual(String(result[yellowRun.range].characters), "foo") }
    if let greenRun { XCTAssertEqual(String(result[greenRun.range].characters), "bar") }
  }

  func testApplyFindHighlightOutOfRangeHitIsSkippedNotCrashing() {
    let base = AttributedString("short")
    let hit: [(range: Range<Int>, isCurrent: Bool)] = [(100..<105, true)]
    let result = DiffViewer.applyFindHighlight(base, hits: hit, currentBg: .red, otherBg: .blue)
    XCTAssertEqual(result, base)
  }
}
