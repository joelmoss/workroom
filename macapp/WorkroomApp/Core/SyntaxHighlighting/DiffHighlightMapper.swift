import SwiftUI

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
        let fileLineText = String(decoding: bytes[lineStart[idx]..<lineEnd[idx]], as: UTF8.self)
        guard fileLineText == line.text else { continue }

        var attr = AttributedString()
        var cursor = lineStart[idx]

        // The intra-line change emphasis for this line, as a file-global byte range.
        let emphasis: Range<Int>? = lineEmphasis.map {
          (lineStart[idx] + $0.lowerBound)..<(lineStart[idx] + $0.upperBound)
        }

        func emit(_ range: Range<Int>, _ fg: Color, _ bg: Color?) {
          guard range.lowerBound < range.upperBound else { return }
          var run = AttributedString(String(decoding: bytes[range], as: UTF8.self))
          run.foregroundColor = fg
          if let bg { run.backgroundColor = bg }
          attr.append(run)
        }

        // Append a foreground run, splitting it at the emphasis boundaries so the changed bytes get
        // the deeper background tint. Called with ascending ranges, so the sub-runs stay ordered.
        // Each sub-range is bounds-checked *before* constructing it — `a..<b` traps when `a > b`,
        // which happens whenever the run lies entirely before or after the emphasis range.
        func appendRun(_ range: Range<Int>, _ color: Color) {
          let lo = range.lowerBound
          let hi = range.upperBound
          guard lo < hi else { return }
          guard let emphasis else { return emit(lo..<hi, color, nil) }
          let beforeHi = min(hi, emphasis.lowerBound)
          if lo < beforeHi { emit(lo..<beforeHi, color, nil) }
          let inLo = max(lo, emphasis.lowerBound)
          let inHi = min(hi, emphasis.upperBound)
          if inLo < inHi { emit(inLo..<inHi, color, emphasisBg) }
          let afterLo = max(lo, emphasis.upperBound)
          if afterLo < hi { emit(afterLo..<hi, color, nil) }
        }

        for span in buckets[idx] {
          if span.byteRange.lowerBound > cursor {
            appendRun(cursor..<span.byteRange.lowerBound, defaultColor)
          }
          // Use the base syntax colour on added lines too (not the contrast-nudged one): the add
          // tint is light, so the same palette as context stays legible — and matching context is
          // what reads as "syntax highlighting is preserved on changed lines" (GitHub-style).
          let color = tokens.syntaxColor(forCapture: span.capture) ?? defaultColor
          appendRun(max(span.byteRange.lowerBound, cursor)..<span.byteRange.upperBound, color)
          cursor = max(cursor, span.byteRange.upperBound)
        }
        if cursor < lineEnd[idx] { appendRun(cursor..<lineEnd[idx], defaultColor) }

        result[lineNumber] = attr
      }
    }
    return result
  }
}
