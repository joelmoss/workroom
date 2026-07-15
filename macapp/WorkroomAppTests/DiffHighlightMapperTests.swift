import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The real coverage for the byte↔offset mapping (XCUITest can't see colours, so we assert the
/// produced `AttributedString` *attributes* here): CRLF / retained `\r`, no-final-newline,
/// multibyte + combining characters, multiline spans, deletions-plain, and the changed-since-diff
/// guard. Pure — no parser, no UI, no filesystem.
@MainActor
final class DiffHighlightMapperTests: XCTestCase {
  private func ns(_ hex: String) -> NSColor { ThemeService.parseHex(hex)! }

  /// Tokens with a distinct palette so each capture colour is identifiable.
  private func tokens() -> ThemeTokens {
    var pal = Array(repeating: "#808080", count: 16)
    pal[1] = "#ff0000"  // red
    pal[2] = "#00cc00"  // green  → string
    pal[3] = "#cccc00"  // yellow
    pal[4] = "#0000ff"  // blue
    pal[5] = "#cc00cc"  // magenta → keyword
    pal[6] = "#00cccc"  // cyan
    return ThemeTokens(
      preview: ThemePreview(
        name: "T", background: ns("#1c1c1e"), foreground: ns("#e0e0e0"), palette: pal.map(ns)))
  }

  /// (substring, foreground colour) for each run, in order.
  private func runs(_ a: AttributedString) -> [(text: String, color: NSColor?)] {
    a.runs.map { run in
      (
        String(a[run.range].characters),
        run.foregroundColor.map { NSColor($0).usingColorSpace(.sRGB)! }
      )
    }
  }

  /// (substring, background colour) for each run, in order.
  private func backgrounds(_ a: AttributedString) -> [(text: String, bg: NSColor?)] {
    a.runs.map { run in
      (
        String(a[run.range].characters),
        run.backgroundColor.map { NSColor($0).usingColorSpace(.sRGB)! }
      )
    }
  }

  private func assertColor(
    _ got: NSColor?, _ want: NSColor, _ message: String = "", line: UInt = #line
  ) {
    guard let got else { return XCTFail("nil colour. \(message)", line: line) }
    let w = want.usingColorSpace(.sRGB)!
    XCTAssertEqual(got.redComponent, w.redComponent, accuracy: 0.02, line: line)
    XCTAssertEqual(got.greenComponent, w.greenComponent, accuracy: 0.02, line: line)
    XCTAssertEqual(got.blueComponent, w.blueComponent, accuracy: 0.02, line: line)
  }

  private func line(_ kind: UnifiedDiff.Line.Kind, _ text: String, old: Int? = nil, new: Int? = nil)
    -> UnifiedDiff.Line
  {
    UnifiedDiff.Line(kind: kind, text: text, oldLine: old, newLine: new)
  }

  private func diff(_ lines: [UnifiedDiff.Line]) -> UnifiedDiff {
    UnifiedDiff(
      hunks: [.init(header: "@@ -1 +1 @@", lines: lines)], truncated: false, renamedFrom: nil)
  }

  // MARK: - Core mapping

  func testKeywordSpanColoursTheRightBytes() {
    let t = tokens()
    let content = "let x = 1\n"
    let spans = [HighlightSpan(byteRange: 0..<3, capture: "keyword")]  // "let"
    let d = diff([line(.addition, "let x = 1", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)

    let r = runs(lines[1]!)
    XCTAssertEqual(r.map(\.text).joined(), "let x = 1")
    XCTAssertEqual(r.first?.text, "let")
    assertColor(
      r.first?.color, NSColor(t.syntaxColor(forCapture: "keyword")!))
    // The remainder is the default foreground.
    assertColor(r.last?.color, t.nsFg, "uncaptured text uses theme fg")
  }

  /// End-to-end over the *exact* UI-test fixture Ruby path (the canned diff + new-side content the
  /// `testRubyDiffIsHighlighted` XCUITest drives): detect → real parse/query → map. Proves the whole
  /// data pipeline produces highlighted lines headlessly, isolating the UI test from async/render
  /// timing. Mirrors `DiffViewer.applyHighlight` in fixture mode.
  func testFixtureRubyDiffPipelineProducesHighlightedLines() {
    let desc = DiffDescriptor(
      path: "app/models/user.rb", change: .modified, source: .jjWorkingCopy, isPreview: false)
    guard case .diff(let diff) = UITestFixture.diff(for: desc) else {
      return XCTFail("fixture should serve a Ruby diff")
    }
    let content = try! XCTUnwrap(
      UITestFixture.fileContent(for: desc), "fixture serves Ruby content")
    let grammar = try! XCTUnwrap(
      SyntaxLanguage.grammar(forPath: desc.path), "user.rb resolves to a grammar")
    XCTAssertEqual(grammar, .ruby)

    let spans = SyntaxHighlighter.shared.spans(for: content, grammar: grammar)
    XCTAssertFalse(spans.isEmpty, "the bundled Ruby grammar should produce highlight spans")

    let lines = DiffHighlightMapper.attributedLines(
      diff: diff, content: content, spans: spans, tokens: tokens())
    XCTAssertFalse(
      lines.isEmpty, "the fixture Ruby diff should map at least one highlighted new-side line")
  }

  func testContextLineUsesBaseColourNotAddVariant() {
    let t = tokens()
    let content = "let x = 1\n"
    let spans = [HighlightSpan(byteRange: 0..<3, capture: "keyword")]
    let d = diff([line(.context, "let x = 1", old: 1, new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    assertColor(
      runs(lines[1]!).first?.color, NSColor(t.syntaxColor(forCapture: "keyword")!),
      "context lines use the base (non-add) colour")
  }

  func testCRLFLineRetainsCarriageReturnAndMaps() {
    let t = tokens()
    let content = "foo\r\nbar\n"  // line 1 = "foo\r"
    let spans = [HighlightSpan(byteRange: 0..<3, capture: "keyword")]  // "foo"
    let d = diff([line(.addition, "foo\r", new: 1)])  // git keeps the \r in the line text
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    let r = runs(lines[1]!)
    XCTAssertEqual(r.map(\.text).joined(), "foo\r", "the \\r is retained")
    assertColor(
      r.first?.color, NSColor(t.syntaxColor(forCapture: "keyword")!))
  }

  func testNoFinalNewlineMapsLastLine() {
    let t = tokens()
    let content = "x = 1"  // no trailing newline
    let spans = [HighlightSpan(byteRange: 4..<5, capture: "number")]  // "1"
    let d = diff([line(.addition, "x = 1", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    let r = runs(lines[1]!)
    XCTAssertEqual(r.map(\.text).joined(), "x = 1")
    XCTAssertEqual(r.last?.text, "1")
    assertColor(
      r.last?.color, NSColor(t.syntaxColor(forCapture: "number")!))
  }

  func testMultibyteCharacterSliceIsIntact() {
    let t = tokens()
    // "π" is 2 UTF-8 bytes; "let " is 4 bytes, so π occupies bytes 4..6. A distinct capture colour
    // (keyword ≠ fg) keeps it as its own run so we can assert the slice landed on a clean boundary.
    let content = "let π = 3\n"
    let spans = [HighlightSpan(byteRange: 4..<6, capture: "keyword")]
    let d = diff([line(.addition, "let π = 3", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    let r = runs(lines[1]!)
    XCTAssertEqual(r.map(\.text).joined(), "let π = 3", "multibyte content reassembles exactly")
    let pi = r.first { $0.text == "π" }
    XCTAssertNotNil(pi, "the multibyte span slices on a clean UTF-8 boundary")
    assertColor(pi?.color, NSColor(t.syntaxColor(forCapture: "keyword")!))
  }

  func testCombiningCharacterSliceIsIntact() {
    let t = tokens()
    // "e" + combining acute (U+0301) = 3 UTF-8 bytes total ("e"=1, U+0301=2).
    let content = "e\u{0301}x\n"
    let spans = [HighlightSpan(byteRange: 0..<3, capture: "string")]  // the full "é" grapheme
    let d = diff([line(.addition, "e\u{0301}x", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    XCTAssertEqual(runs(lines[1]!).map(\.text).joined(), "e\u{0301}x")
  }

  func testMultilineSpanColoursEachCoveredLine() {
    let t = tokens()
    let content = "/*\ncomment\n*/\n"  // lines: "/*"(0..2) "comment"(3..10) "*/"(11..13)
    let spans = [HighlightSpan(byteRange: 0..<13, capture: "comment")]  // whole block comment
    let d = diff([
      line(.context, "/*", old: 1, new: 1),
      line(.context, "comment", old: 2, new: 2),
      line(.context, "*/", old: 3, new: 3),
    ])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    for n in 1...3 {
      let r = runs(lines[n]!)
      assertColor(r.first?.color, NSColor(t.syntaxColor(forCapture: "comment")!), "line \(n)")
    }
  }

  // MARK: - Intra-line emphasis background

  func testAdditionEmphasisAppliesBackgroundToChangedBytes() {
    let t = tokens()
    let content = "x = 2\n"
    // Emphasise the changed byte ("2" at byte 4) on the new line.
    let d = diff([line(.addition, "x = 2", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: [], tokens: t, additionEmphasis: [1: 4..<5])
    let bgs = backgrounds(lines[1]!)
    XCTAssertEqual(bgs.map(\.text).joined(), "x = 2")
    // Only the "2" run carries the deeper add-emphasis background.
    let emphasised = bgs.first { $0.bg != nil }
    XCTAssertEqual(emphasised?.text, "2")
    assertColor(emphasised?.bg, NSColor(t.diffAddEmphasisBg))
    XCTAssertTrue(bgs.filter { $0.bg != nil }.count == 1, "exactly one emphasised run")
  }

  func testEmphasisComposesWithSyntaxForeground() {
    let t = tokens()
    let content = "let x = 2\n"
    // "let" is a keyword span; emphasise "2" (byte 8).
    let d = diff([line(.addition, "let x = 2", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content,
      spans: [HighlightSpan(byteRange: 0..<3, capture: "keyword")], tokens: t,
      additionEmphasis: [1: 8..<9])
    // Foreground still colours "let"; background still marks "2" — the two compose.
    let r = runs(lines[1]!)
    assertColor(
      r.first?.color, NSColor(t.syntaxColor(forCapture: "keyword")!))
    let emphasised = backgrounds(lines[1]!).first { $0.bg != nil }
    XCTAssertEqual(emphasised?.text, "2")
  }

  // MARK: - Guards

  func testNewSideMapperSkipsDeletions() {
    let t = tokens()
    let content = "kept\n"
    let spans = [HighlightSpan(byteRange: 0..<4, capture: "keyword")]
    let d = diff([
      line(.deletion, "gone", old: 1),
      line(.addition, "kept", new: 1),
    ])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)  // side .new
    XCTAssertNotNil(lines[1], "the addition is highlighted")
    XCTAssertEqual(lines.count, 1, "the new side maps only the addition; deletions come from .old")
  }

  func testOldSideMapperHighlightsDeletionsByOldLine() {
    let t = tokens()
    let oldContent = "let removed = 1\n"  // the pre-image line
    let spans = [HighlightSpan(byteRange: 0..<3, capture: "keyword")]  // "let"
    let d = diff([
      line(.deletion, "let removed = 1", old: 1),
      line(.addition, "let added = 2", new: 1),
    ])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: oldContent, spans: spans, tokens: t, side: .old)
    // Keyed by OLD line; only the deletion maps on the old side.
    XCTAssertEqual(lines.count, 1)
    let r = runs(lines[1]!)
    XCTAssertEqual(r.map(\.text).joined(), "let removed = 1")
    assertColor(r.first?.color, NSColor(t.syntaxColor(forCapture: "keyword")!))
  }

  func testChangedSinceDiffGuardSkipsMismatchedLine() {
    let t = tokens()
    // File line 1 no longer matches the diff's recorded text → that line must render plain.
    let content = "let y = 2\n"
    let spans = [HighlightSpan(byteRange: 0..<3, capture: "keyword")]
    let d = diff([line(.addition, "let x = 1", new: 1)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    XCTAssertNil(lines[1], "a file-vs-diff mismatch degrades to plain (no mis-mapping)")
  }

  func testEmptyLineStaysPlain() {
    let t = tokens()
    let content = "\nx\n"  // line 1 empty, line 2 = "x"
    let spans = [HighlightSpan(byteRange: 1..<2, capture: "variable")]
    let d = diff([line(.context, "", old: 1, new: 1), line(.addition, "x", new: 2)])
    let lines = DiffHighlightMapper.attributedLines(
      diff: d, content: content, spans: spans, tokens: t)
    XCTAssertNil(lines[1], "empty lines render plain")
    XCTAssertNotNil(lines[2])
  }

  func testNoSpansProducesNoEntries() {
    let t = tokens()
    let lines = DiffHighlightMapper.attributedLines(
      diff: diff([line(.addition, "plain", new: 1)]), content: "plain\n", spans: [], tokens: t)
    // With no spans the whole line is still emitted as a single default-coloured run.
    XCTAssertEqual(runs(lines[1]!).map(\.text).joined(), "plain")
    assertColor(runs(lines[1]!).first?.color, t.nsFg)
  }

  func testEmptyContentProducesEmptyMap() {
    XCTAssertTrue(
      DiffHighlightMapper.attributedLines(
        diff: diff([line(.addition, "x", new: 1)]), content: "", spans: [], tokens: tokens()
      ).isEmpty)
  }
}
