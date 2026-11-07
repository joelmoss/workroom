import AppKit
import DesignSystem
import SwiftUI
import SyntaxHighlighting

/// Builds the themed `NSAttributedString` the `NSTextView`-backed `PlainFileViewer` / `CodeTextView`
/// render for a whole file. Pure (no I/O, no parse) — the byte↔UTF-16 arithmetic mirrors
/// `DiffHighlightMapper`, but without a diff: every character is the theme foreground with captured
/// spans recoloured. Unit-tested without a parser or UI.
enum FileHighlightMapper {
  /// Highlight a whole file off the main thread: parse, then `nsAttributedString`, which alone took
  /// 26 ms of main-thread time at the viewer's 5000-line cap. `nil` when the grammar captures
  /// nothing, so the caller keeps the plain string it already shows.
  @MainActor static func highlighted(
    content: String, grammar: GrammarID, tokens: ThemeTokens, font: NSFont
  ) async -> NSAttributedString? {
    // An NSFont is immutable, and AppKit documents it as safe to share across threads.
    nonisolated(unsafe) let font = font
    return await Task.detached(priority: .utility) {
      let spans = SyntaxHighlighter.shared.spans(for: content, grammar: grammar)
      guard !spans.isEmpty else { return Built(string: nil) }
      return Built(
        string: nsAttributedString(content: content, spans: spans, tokens: tokens, font: font))
    }.value.string
  }

  /// A string built on the worker and handed over whole: nothing else holds it, so it is safe to
  /// read from the main actor afterwards.
  private struct Built: @unchecked Sendable {
    let string: NSAttributedString?
  }

  /// Build a single themed `NSAttributedString` for the whole file — the text the `NSTextView`-backed
  /// `CodeTextView` renders (SwiftUI `Text` can't select across lines). Every character starts in the
  /// theme foreground + `font`; captured spans are recoloured. `spans == []` yields a plain (but still
  /// monospaced + themed) string. Spans are UTF-8 byte ranges (tree-sitter), converted to the
  /// `NSAttributedString`'s UTF-16 ranges via one forward walk (spans are ascending + non-overlapping,
  /// so the cursor only moves forward).
  static func nsAttributedString(
    content: String, spans: [HighlightSpan], tokens: ThemeTokens, font: NSFont
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(string: content)
    let full = NSRange(location: 0, length: result.length)
    result.addAttribute(.font, value: font, range: full)
    result.addAttribute(.foregroundColor, value: tokens.nsFg, range: full)
    guard !spans.isEmpty else { return result }

    // One forward walk over the scalars turns byte offsets into UTF-16 offsets; spans ascend and
    // never overlap, so the cursor only moves on. (Stepping `Character`s and converting each
    // `String.Index` range cost three times this at the 5000-line cap.)
    var scalars = content.unicodeScalars.makeIterator()
    var byte = 0
    var utf16 = 0
    func advance(to target: Int) {
      while byte < target, let scalar = scalars.next() {
        byte += scalar.utf8.count
        utf16 += scalar.utf16.count
      }
    }
    var colors: [String: NSColor?] = [:]  // a capture's colour, nil when the theme has none
    for span in spans where span.byteRange.lowerBound >= byte {
      advance(to: span.byteRange.lowerBound)
      let start = utf16
      advance(to: span.byteRange.upperBound)
      guard utf16 > start else { continue }
      let color: NSColor?
      if let cached = colors[span.capture] {
        color = cached
      } else {
        color = ThemeTokens.category(for: span.capture).flatMap { tokens.syntaxByCategory[$0] }
        colors[span.capture] = color
      }
      guard let color else { continue }
      result.addAttribute(
        .foregroundColor, value: color, range: NSRange(location: start, length: utf16 - start))
    }
    return result
  }
}
