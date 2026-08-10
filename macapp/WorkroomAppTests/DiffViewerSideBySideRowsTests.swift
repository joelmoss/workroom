import XCTest

@testable import Workroom

/// Regression tests for `DiffViewer.rows(in:forHunk:)` — the bounds-checked lookup behind
/// `sbsRows`'s reference-type box (WORKROOM-2S, a ≥2000 ms App Hang sampled inside
/// AttributeGraph's array-equality walk). `sbsRows` moved from a bare `@State [[SideBySideRow]]`
/// to a boxed, non-`Equatable` reference specifically so AG's write-time compare on every file
/// switch is an O(1) identity check instead of a deep structural walk of the previous file's
/// unrelated rows. This pins the surviving lookup logic so a future edit can't regress it back
/// toward an unguarded/trapping array index.
final class DiffViewerSideBySideRowsTests: XCTestCase {
  private func line(_ text: String) -> UnifiedDiff.Line {
    UnifiedDiff.Line(kind: .context, text: text, oldLine: 1, newLine: 1)
  }

  private func row(_ text: String) -> UnifiedDiff.SideBySideRow {
    UnifiedDiff.SideBySideRow(left: line(text), right: line(text))
  }

  func testNilRowsReturnsEmpty() {
    // No diff loaded yet (or a binary/empty/too-large result) → sbsRows is nil.
    XCTAssertEqual(DiffViewer.rows(in: nil, forHunk: 0), [])
  }

  func testOutOfRangeIndexReturnsEmpty() {
    let rows = [[row("a")]]
    XCTAssertEqual(DiffViewer.rows(in: rows, forHunk: 1), [])
  }

  func testNegativeIndexReturnsEmpty() {
    let rows = [[row("a")]]
    XCTAssertEqual(DiffViewer.rows(in: rows, forHunk: -1), [])
  }

  func testValidIndexReturnsThatHunksRows() {
    let hunk0 = [row("a"), row("b")]
    let hunk1 = [row("c")]
    let rows = [hunk0, hunk1]
    XCTAssertEqual(DiffViewer.rows(in: rows, forHunk: 0), hunk0)
    XCTAssertEqual(DiffViewer.rows(in: rows, forHunk: 1), hunk1)
  }
}
