import DesignSystem
import SwiftUI
import SyntaxHighlighting

/// Maps whole-file highlight spans onto a diff's lines, producing one coloured `AttributedString`
/// per **new-file line number** for the added/context lines. Pure (no I/O, no parse) and the single
/// home of the byte↔offset arithmetic, so the tricky cases (CRLF, retained `\r`, no final newline,
/// multibyte/combining characters) are unit-testable without a parser or a UI.
///
/// A line whose diff text no longer matches the file's line is skipped (degrade to plain): the
/// changed-since-diff / symlink-target guard — a mid-edit race can't mis-map colours onto the wrong
/// text.
///
/// `side` selects which lines to map and against which file `content`: `.new` (default) colours the
/// added + context lines from the whole NEW file, keyed by new-line; `.old` colours the DELETED
/// lines from the whole OLD (pre-image) file, keyed by old-line. `DiffViewer` calls it once per side
/// and picks the right map per line, so a diff highlights both its added and its removed lines.
enum DiffHighlightMapper {
  enum Side: Sendable { case new, old }

  /// Build `lineNumber → AttributedString` for the highlightable lines of `diff`, from `spans` over
  /// the whole file `content` for the chosen `side`. Uncaptured text uses the theme foreground;
  /// captured spans use the base syntax colour. Intra-line change emphasis is folded in per side
  /// (`additionEmphasis` on the new side, `deletionEmphasis` on the old). Empty lines are left plain.
  static func attributedLines(
    diff: UnifiedDiff, content: String, spans: [HighlightSpan], tokens: ThemeTokens,
    side: Side = .new,
    additionEmphasis: [Int: Range<Int>] = [:],
    deletionEmphasis: [Int: Range<Int>] = [:]
  ) -> [Int: AttributedString] {
    let bytes = Array(content.utf8)
    guard !bytes.isEmpty else { return [:] }

    // File line byte ranges. `lineEnd` excludes the trailing `\n` (a `\r` before it stays in the
    // line, so CRLF content matches git's line text). Content ending in `\n` yields a final empty
    // line, which is harmless (no non-empty diff line maps to it).
    var lineStart: [Int] = [0]
    var lineEnd: [Int] = []
    for (i, b) in bytes.enumerated() where b == 0x0A {
      lineEnd.append(i)
      lineStart.append(i + 1)
    }
    lineEnd.append(bytes.count)
    let lineCount = lineStart.count

    // The line index containing byte offset `b` (largest i with lineStart[i] <= b).
    func lineIndex(forByte b: Int) -> Int {
      var lo = 0
      var hi = lineCount - 1
      var ans = 0
      while lo <= hi {
        let mid = (lo + hi) / 2
        if lineStart[mid] <= b {
          ans = mid
          lo = mid + 1
        } else {
          hi = mid - 1
        }
      }
      return ans
    }

    // Bucket spans per line (clamped to the line), splitting multiline spans (block comments,
    // multiline strings) across the lines they cover. Input spans are ascending + non-overlapping,
    // so each bucket stays ascending.
    var buckets: [[HighlightSpan]] = Array(repeating: [], count: lineCount)
    for span in spans {
      let lo = span.byteRange.lowerBound
      let hi = min(span.byteRange.upperBound, bytes.count)
      guard lo < hi else { continue }
      let first = lineIndex(forByte: lo)
      let last = lineIndex(forByte: hi - 1)
      for l in first...last {
        let s = max(lo, lineStart[l])
        let e = min(hi, lineEnd[l])
        if s < e { buckets[l].append(HighlightSpan(byteRange: s..<e, capture: span.capture)) }
      }
    }

    let defaultColor = Color(nsColor: tokens.nsFg)
    let emphasisBg = side == .new ? tokens.diffAddEmphasisBg : tokens.diffRemoveEmphasisBg
    // Use the base syntax colour on added lines too (not the contrast-nudged one): the add tint is
    // light, so the same palette as context stays legible — and matching context is what reads as
    // "syntax highlighting is preserved on changed lines" (GitHub-style). Looked up once per
    // capture name; nil when the theme has no colour for it.
    var colors: [String: Color?] = [:]
    func color(for capture: String) -> Color? {
      if let cached = colors[capture] { return cached }
      let color = tokens.syntaxColor(forCapture: capture)
      colors[capture] = color
      return color
    }
    var result: [Int: AttributedString] = [:]

    for hunk in diff.hunks {
      for line in hunk.lines {
        // Pick this side's line number + intra-line emphasis; skip lines not on this side.
        let lineNumber: Int
        let lineEmphasis: Range<Int>?
        switch side {
        case .new:
          guard line.kind != .deletion, let n = line.newLine else { continue }
          lineNumber = n
          lineEmphasis = line.kind == .addition ? additionEmphasis[n] : nil
        case .old:
          guard line.kind == .deletion, let o = line.oldLine else { continue }
          lineNumber = o
          lineEmphasis = deletionEmphasis[o]
        }
        guard !line.text.isEmpty else { continue }
        let idx = lineNumber - 1
        guard idx >= 0, idx < lineCount else { continue }

        // Changed-since-diff guard: the file's line must still be exactly the diff's line text.
        guard line.text.utf8.elementsEqual(bytes[lineStart[idx]..<lineEnd[idx]]) else { continue }

        // One string for the line, the default colour throughout, then the spans recoloured and
        // the emphasis tinted over it. Byte offsets become string positions by one forward walk
        // over the scalars per line (spans ascend); the emphasis gets a walk of its own, as it may
        // start before the last span ended. (Appending a run per colour change cost six times
        // this at the 2000-line cap.)
        var attr = AttributedString(line.text)
        attr.foregroundColor = defaultColor
        let scalars = line.text.unicodeScalars
        var index = scalars.startIndex
        var byte = lineStart[idx]
        func advance(to target: Int) {
          while byte < target, index < scalars.endIndex {
            byte += scalars[index].utf8.count
            index = scalars.index(after: index)
          }
        }
        for span in buckets[idx] {
          advance(to: span.byteRange.lowerBound)
          let start = index
          advance(to: span.byteRange.upperBound)
          guard start < index, let color = color(for: span.capture),
            let range = Range(start..<index, in: attr)
          else { continue }
          attr[range].foregroundColor = color
        }
        if let lineEmphasis {
          index = scalars.startIndex
          byte = lineStart[idx]
          advance(to: lineStart[idx] + lineEmphasis.lowerBound)
          let start = index
          advance(to: lineStart[idx] + lineEmphasis.upperBound)
          if start < index, let range = Range(start..<index, in: attr) {
            attr[range].backgroundColor = emphasisBg
          }
        }

        result[lineNumber] = attr
      }
    }
    return result
  }
}
