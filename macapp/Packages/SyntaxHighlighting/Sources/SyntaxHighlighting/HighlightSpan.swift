import Foundation

/// One contiguous, non-overlapping run of highlighted source, produced by `SyntaxHighlighter` from
/// one whole-new-file tree-sitter parse. The `byteRange` is in **UTF-8 byte offsets** into the
/// parsed content (we parse via the UTF-8 read block so offsets map cleanly onto the diff's line
/// text, which is also UTF-8 — see the byte↔offset mapping in `DiffViewer`). `capture` is the
/// tree-sitter highlight capture name (e.g. `keyword`, `string`, `function`, `comment`); the theme
/// turns it into a colour via `ThemeTokens.syntaxColor(forCapture:)`.
public struct HighlightSpan: Equatable, Sendable {
  /// UTF-8 byte offsets into the whole parsed file. Half-open, non-overlapping, ascending.
  public let byteRange: Range<Int>
  /// The winning capture name after precedence resolution (dot-joined for nested captures).
  public let capture: String

  public init(byteRange: Range<Int>, capture: String) {
    self.byteRange = byteRange
    self.capture = capture
  }
}
