import Foundation

/// One index-aligned slot of a deletion-run ↔ addition-run replacement. A `nil` side is padding for
/// an uneven run (a pure insertion or removal tail).
struct DiffRunPair: Equatable, Sendable {
  var deletion: UnifiedDiff.Line?
  var addition: UnifiedDiff.Line?
}

/// The single home of the replacement-line pairing rule — deletion *k* lines up with addition *k*.
/// Used by both `IntraLineDiff.emphasis` (character-level change tinting) and
/// `UnifiedDiff.sideBySideRows` (the side-by-side diff layout), so they share one index-pairing rule.
/// (They group runs slightly differently — emphasis pairs each deletion-run with the addition-run
/// that immediately follows it, side-by-side buffers a run between context lines — but git's
/// output always emits a block's deletions before its additions, so for real diffs they pair the same
/// lines; only impossible `+x -a` interleavings could diverge.)
enum DiffRunPairing {
  /// Pair a run of deletions with a run of additions: deletion *k* with addition *k*, padding the
  /// shorter side with `nil` so the result has `max(deletions.count, additions.count)` slots. Empty
  /// inputs yield an empty result.
  ///
  ///     deletions: [a, b, c]   additions: [x, y]
  ///     → [(a, x), (b, y), (c, nil)]
  static func align(deletions: [UnifiedDiff.Line], additions: [UnifiedDiff.Line]) -> [DiffRunPair] {
    let count = max(deletions.count, additions.count)
    guard count > 0 else { return [] }
    return (0..<count).map { k in
      DiffRunPair(
        deletion: k < deletions.count ? deletions[k] : nil,
        addition: k < additions.count ? additions[k] : nil)
    }
  }
}
