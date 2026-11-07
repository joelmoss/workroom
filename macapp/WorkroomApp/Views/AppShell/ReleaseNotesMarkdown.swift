import SwiftUI

/// A minimal block renderer for GitHub release-note markdown.
///
/// `AttributedString(markdown:)` flattens block structure (headings and lists render inline), so we
/// split the body into line-blocks and render each as its own view, applying inline markup
/// (bold/italic/`code`/links) per line. Tables, images, and other rich GFM degrade to plain text —
/// acceptable for release notes. Any inline-parse failure falls back to the raw line.
struct ReleaseNotesMarkdown: View {
  let markdown: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(Self.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
        block.view
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// One rendered line-block.
  enum Block: Equatable {
    case heading(String, level: Int)
    case bullet(String)
    case paragraph(String)
    case spacer

    @ViewBuilder var view: some View {
      switch self {
      case .heading(let text, let level):
        Self.inline(text)
          .font(level <= 1 ? .title3.bold() : (level == 2 ? .headline : .subheadline.bold()))
          .padding(.top, 2)
      case .bullet(let text):
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("•").foregroundStyle(.secondary)
          Self.inline(text)
        }
      case .paragraph(let text):
        Self.inline(text)
      case .spacer:
        Spacer().frame(height: 2)
      }
    }

    /// Render one line's inline markdown; fall back to plain text on parse failure.
    static func inline(_ s: String) -> Text {
      if let attributed = try? AttributedString(
        markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
      {
        return Text(attributed)
      }
      return Text(s)
    }
  }

  /// Split `markdown` into blocks. Pure + `Equatable` so the classification is unit-testable.
  static func blocks(from markdown: String) -> [Block] {
    var out: [Block] = []
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    for rawLine in normalized.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        out.append(.spacer)
      } else if let hashes = headingHashes(line) {
        // Strip the actual hash run; cap only the *styling* level (h4+ render as h3).
        out.append(.heading(strip(prefixCount: hashes, from: line), level: min(hashes, 3)))
      } else if let item = bulletText(line) {
        out.append(.bullet(item))
      } else {
        out.append(.paragraph(line))
      }
    }
    return tidy(out)
  }

  /// The number of leading `#` in a heading line, else nil. Requires a space after the hashes so a
  /// bare "#tag" stays a paragraph. The caller caps the styling level; this returns the raw count so
  /// the marker is stripped correctly even for h4+.
  private static func headingHashes(_ line: String) -> Int? {
    var count = 0
    for ch in line {
      if ch == "#" { count += 1 } else { break }
    }
    guard count > 0, count < line.count else { return nil }
    let after = line[line.index(line.startIndex, offsetBy: count)]
    guard after == " " else { return nil }
    return count
  }

  private static func strip(prefixCount: Int, from line: String) -> String {
    String(line.dropFirst(prefixCount)).trimmingCharacters(in: .whitespaces)
  }

  /// "- ", "* ", or "+ " bullet → its text, else nil.
  private static func bulletText(_ line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// Collapse runs of blank lines to a single spacer and trim leading/trailing spacers.
  private static func tidy(_ blocks: [Block]) -> [Block] {
    var out: [Block] = []
    for block in blocks {
      if block == .spacer, out.last == .spacer { continue }
      out.append(block)
    }
    while out.first == .spacer { out.removeFirst() }
    while out.last == .spacer { out.removeLast() }
    return out
  }
}
