import Foundation

/// Character-level (intra-line) diff: within a *replaced* line, the byte range that actually changed,
/// so the diff viewer can tint just those characters a deeper colour (the rest of the line keeps the
/// flat add/remove tint). Computed purely from the unified diff's paired `-`/`+` lines — no file
/// fetch, no parse.
///
/// Pairing: inside a hunk, a run of deletions immediately followed by a run of additions is a
/// replacement; deletion *k* pairs with addition *k* (the common case — an edited line) via the
/// shared `DiffRunPairing.align`. Unpaired extras and pure add-only / delete-only blocks get no
/// intra-line emphasis (the whole line is the change, already shown by its line tint). The changed
/// range is the middle left after trimming the common prefix + suffix (grapheme-aware, so
/// multibyte/combining characters are never split).
enum IntraLineDiff {
  /// Line-relative UTF-8 byte ranges that changed, keyed by line number: deletions by `oldLine`,
  /// additions by `newLine` (a number can repeat across the two sides).
  static func emphasis(for diff: UnifiedDiff)
    -> (deletions: [Int: Range<Int>], additions: [Int: Range<Int>])
  {
    var deletions: [Int: Range<Int>] = [:]
    var additions: [Int: Range<Int>] = [:]

    for hunk in diff.hunks {
      let lines = hunk.lines
      var i = 0
      while i < lines.count {
        guard lines[i].kind == .deletion else {
          i += 1
          continue
        }
        // A deletion run, then the addition run that immediately follows it.
        let delStart = i
        while i < lines.count, lines[i].kind == .deletion { i += 1 }
        let delEnd = i
        let addStart = i
        while i < lines.count, lines[i].kind == .addition { i += 1 }
        let addEnd = i

        // Pair deletion k with addition k via the shared rule; only fully-paired slots (both sides
        // present) are a replacement edit — padded `nil` slots are pure insert/remove, no emphasis.
        for pair in DiffRunPairing.align(
          deletions: Array(lines[delStart..<delEnd]), additions: Array(lines[addStart..<addEnd]))
        {
          guard let del = pair.deletion, let add = pair.addition else { continue }
          let (delRange, addRange) = changedRanges(old: del.text, new: add.text)
          if let delRange, let line = del.oldLine { deletions[line] = delRange }
          if let addRange, let line = add.newLine { additions[line] = addRange }
        }
      }
    }
    return (deletions, additions)
  }

  /// The largest fraction of the longer line that may differ and still be treated as a localized
  /// edit. Above this, the two lines barely overlap — they're an index-aligned block replacement,
  /// not an edit — so we skip intra-line emphasis and let the flat line tint carry the change
  /// (otherwise nearly every byte gets the deeper tint, which is just noise).
  static let maxChangedFraction = 0.5

  /// Trim the common prefix + suffix of two line texts and return the differing middle as a
  /// line-relative UTF-8 byte range on each side (`nil` for a side whose middle is empty — a pure
  /// insertion/removal at that spot, or when the lines are too dissimilar to be a real edit pair).
  /// Operates on grapheme clusters, then converts to byte offsets.
  static func changedRanges(old: String, new: String) -> (Range<Int>?, Range<Int>?) {
    guard old != new else { return (nil, nil) }
    let o = Array(old)
    let n = Array(new)

    var prefix = 0
    while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }

    var suffix = 0
    while suffix < o.count - prefix, suffix < n.count - prefix,
      o[o.count - 1 - suffix] == n[n.count - 1 - suffix]
    {
      suffix += 1
    }

    // Similarity gate: if the changed middle dominates the longer line, the pair isn't a localized
    // edit — emit no emphasis so a block replacement shows as clean flat tints, not solid blocks.
    let changed = max(o.count - suffix - prefix, n.count - suffix - prefix)
    let longest = max(o.count, n.count)
    guard longest > 0, Double(changed) <= Double(longest) * maxChangedFraction else {
      return (nil, nil)
    }

    let oStart = byteOffset(of: o, upTo: prefix)
    let oEnd = byteOffset(of: o, upTo: o.count - suffix)
    let nStart = byteOffset(of: n, upTo: prefix)
    let nEnd = byteOffset(of: n, upTo: n.count - suffix)

    return (oStart < oEnd ? oStart..<oEnd : nil, nStart < nEnd ? nStart..<nEnd : nil)
  }

  /// UTF-8 byte count of the first `count` grapheme clusters.
  private static func byteOffset(of chars: [Character], upTo count: Int) -> Int {
    chars.prefix(count).reduce(0) { $0 + String($1).utf8.count }
  }
}
