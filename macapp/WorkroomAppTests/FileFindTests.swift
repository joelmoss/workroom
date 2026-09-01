import XCTest

@testable import Workroom

/// Unit tests for the pure in-file find matcher (`FileFind.matches`) and the observable model's
/// navigation/highlight logic. The rendering + scroll-to-match live in `PlainFileViewer` and are
/// covered by manual QA.
final class FileFindTests: XCTestCase {

  // MARK: FileFind.matches

  func testEmptyNeedleHasNoMatches() {
    XCTAssertTrue(FileFind.matches(in: ["abc"], needle: "").isEmpty)
  }

  func testCaseInsensitiveAcrossLinesInDocumentOrder() {
    let lines = ["Foo bar", "no hit", "food FOO"]
    let matches = FileFind.matches(in: lines, needle: "foo")
    XCTAssertEqual(
      matches,
      [
        FileFindMatch(line: 0, range: 0..<3),  // "Foo"
        FileFindMatch(line: 2, range: 0..<3),  // "food" → "foo"
        FileFindMatch(line: 2, range: 5..<8),  // "FOO"
      ])
  }

  func testMultipleHitsOnOneLineDoNotOverlapOrLoop() {
    // Overlapping pattern: "aa" in "aaaa" → non-overlapping hits at 0 and 2.
    let matches = FileFind.matches(in: ["aaaa"], needle: "aa")
    XCTAssertEqual(
      matches, [FileFindMatch(line: 0, range: 0..<2), FileFindMatch(line: 0, range: 2..<4)])
  }

  func testRangesAreCharacterOffsetsNotBytes() {
    // A multibyte prefix must not shift the offsets off — "é" is one Character.
    let matches = FileFind.matches(in: ["é foo"], needle: "foo")
    XCTAssertEqual(matches, [FileFindMatch(line: 0, range: 2..<5)])
  }

  func testMatchesStopAtCap() {
    // A one-char needle repeated past the cap yields exactly `matchCap` matches, never more — so a
    // one-character search in a huge file can't produce an unbounded list.
    let line = String(repeating: "a", count: FileFind.matchCap + 100)
    XCTAssertEqual(FileFind.matches(in: [line], needle: "a").count, FileFind.matchCap)
  }

  // MARK: FileFindModel

  @MainActor func testModelComputesSummaryAndNavigatesWithWrap() {
    let model = FileFindModel()
    model.setSource(["foo", "foo foo"])
    model.open()
    model.setNeedle("foo")
    XCTAssertEqual(model.matches.count, 3)
    XCTAssertEqual(model.current, 0)
    XCTAssertEqual(model.summary, "1/3")

    model.next()
    XCTAssertEqual(model.current, 1)
    XCTAssertEqual(model.summary, "2/3")

    model.previous()
    model.previous()  // wrap from 0 → last
    XCTAssertEqual(model.current, 2)
    XCTAssertEqual(model.summary, "3/3")
  }

  @MainActor func testNoMatchesSummaryAndHighlights() {
    let model = FileFindModel()
    model.setSource(["hello"])
    model.open()
    model.setNeedle("zzz")
    XCTAssertFalse(model.hasMatches)
    XCTAssertEqual(model.summary, "No results")
    XCTAssertTrue(model.highlights(onLine: 0).isEmpty)
  }

  @MainActor func testHighlightsMarkCurrentMatch() {
    let model = FileFindModel()
    model.setSource(["foo foo"])
    model.open()
    model.setNeedle("foo")
    let line0 = model.highlights(onLine: 0)
    XCTAssertEqual(line0.count, 2)
    XCTAssertTrue(line0[0].isCurrent)  // current == 0
    XCTAssertFalse(line0[1].isCurrent)
    model.next()
    XCTAssertFalse(model.highlights(onLine: 0)[0].isCurrent)
    XCTAssertTrue(model.highlights(onLine: 0)[1].isCurrent)
  }

  @MainActor func testCloseClearsState() {
    let model = FileFindModel()
    model.setSource(["foo"])
    model.open()
    model.setNeedle("foo")
    model.close()
    XCTAssertFalse(model.isOpen)
    XCTAssertEqual(model.needle, "")
    XCTAssertTrue(model.matches.isEmpty)
    XCTAssertTrue(model.highlights(onLine: 0).isEmpty)
  }

  @MainActor func testHighlightsEmptyWhenClosed() {
    let model = FileFindModel()
    model.setSource(["foo"])
    model.setNeedle("foo")  // matches exist but bar not open
    XCTAssertFalse(model.isOpen)
    XCTAssertTrue(model.highlights(onLine: 0).isEmpty)
  }

  /// `sourceGeneration` must bump on EVERY `setSource` call, even when the new content happens to
  /// produce array-equal `matches`/`current` to what was there before — that's exactly the case a
  /// consumer needing an unambiguous "content changed" signal (`DiffViewer`'s scroll-to-match) can't
  /// get from `onChange(of: matches)`/`onChange(of: current)` alone, since SwiftUI's `onChange` only
  /// fires on an actual VALUE difference.
  @MainActor func testSourceGenerationBumpsOnEverySetSourceEvenWhenMatchesAreEqual() {
    let model = FileFindModel()
    model.setSource(["foo"])
    model.open()
    model.setNeedle("foo")
    let generationAfterFirstSource = model.sourceGeneration
    let matchesAfterFirstSource = model.matches

    // A different "file" whose content happens to produce an identical match set.
    model.setSource(["foo"])
    XCTAssertEqual(model.matches, matchesAfterFirstSource)
    XCTAssertGreaterThan(model.sourceGeneration, generationAfterFirstSource)
  }
}
