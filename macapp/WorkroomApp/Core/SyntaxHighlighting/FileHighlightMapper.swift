import AppKit
import SwiftUI
import SyntaxHighlighting

/// Builds the themed `NSAttributedString` the `NSTextView`-backed `PlainFileViewer` / `CodeTextView`
/// render for a whole file. Pure (no I/O, no parse) — the byte↔UTF-16 arithmetic mirrors
/// `DiffHighlightMapper`, but without a diff: every character is the theme foreground with captured
/// spans recoloured. Unit-tested without a parser or UI.
enum FileHighlightMapper {
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

    let byteCount = content.utf8.count
    var index = content.startIndex
    var byte = 0
    for span in spans {
      let lo = span.byteRange.lowerBound
      let hi = min(span.byteRange.upperBound, byteCount)
      guard lo < hi, lo >= byte else { continue }
      while byte < lo, index < content.endIndex {
        byte += content[index].utf8.count
        index = content.index(after: index)
      }
      let start = index
      while byte < hi, index < content.endIndex {
        byte += content[index].utf8.count
        index = content.index(after: index)
      }
      guard start < index else { continue }
      let color = tokens.syntaxColor(forCapture: span.capture).map { NSColor($0) } ?? tokens.nsFg
      result.addAttribute(
        .foregroundColor, value: color, range: NSRange(start..<index, in: content))
    }
    return result
  }
}
