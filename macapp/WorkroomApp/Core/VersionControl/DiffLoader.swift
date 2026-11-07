import DesignSystem
import Foundation
import SyntaxHighlighting
import WorkroomGit
import WorkroomVCS

/// Stable identity for a `UnifiedDiff.Line` within ONE loaded diff (`DiffResolver` always resolves a
/// single file's diff, so `UnifiedDiff.parse`'s own multi-file generality never actually applies here)
/// — line numbers only increase across a file's hunks, so `(kind, oldLine, newLine)` is unique without
/// needing a hunk/offset index. Used to map a `FileFindModel` match (an index into a flat line array)
/// back to the specific rendered row, in both the unified and side-by-side layouts.
struct DiffLineID: Hashable {
  let kind: UnifiedDiff.Line.Kind
  let oldLine: Int?
  let newLine: Int?

  static func id(for line: UnifiedDiff.Line) -> DiffLineID {
    DiffLineID(kind: line.kind, oldLine: line.oldLine, newLine: line.newLine)
  }
}

/// Loads one file's diff for `DiffViewer`: keyed on the file and revision, a stale result
/// discarded, classified into a `LoadState`, and everything derived from the diff built once per
/// load (intra-line emphasis, side-by-side rows, line stats, the find index) before syntax
/// highlighting arrives off-main.
///
/// The viewer holds it as `@State`, so it lives exactly as long as the view's identity does: a pane
/// retargeted to another file keeps the same loader (and so `loadedKey` and the generation tokens
/// below), and a reopened tab gets a fresh one, which loads again.
@MainActor
@Observable
final class DiffLoader {
  /// Identity of the file+revision a diff is for — the load task's key and the re-load guard.
  struct FetchKey: Hashable {
    let location: RepositoryLocation?
    let localDirectory: String
    let source: DiffSource
    let path: String
  }

  struct HighlightKey: Hashable {
    let fetch: FetchKey
    let theme: Int
    let load: Int
  }

  /// What to load and where from: the viewer's inputs, handed over on each call so the loader holds
  /// no copy that could fall behind them.
  struct Request {
    let descriptor: DiffDescriptor
    /// The workroom directory the VCS runs in (resolves the repo-relative path / picks the worktree).
    let directory: String
    let repositoryLocation: RepositoryLocation?
    /// The services' canned diffs (`AppServices.cannedDiffs`), served instead of reading the
    /// repository: the UI-test fixture's, whose paths are not repositories. Nil reads it.
    let cannedDiffs: AppServices.CannedDiffs?
    /// The diff fetch, injectable so a test can hold one file's load open while the pane is
    /// retargeted to another (the stale-write race `activeFetchKey` guards).
    let resolveDiff: (DiffDescriptor, String) async -> DiffResult

    var key: FetchKey {
      FetchKey(
        location: repositoryLocation, localDirectory: directory, source: descriptor.source,
        path: descriptor.path)
    }
  }

  /// Reference-type box for `sbsRows` — deliberately not `Equatable`, so replacing it on a file
  /// switch never compares the wrapped arrays. When this lived in a view's `@State`, every file
  /// switch made AttributeGraph structurally walk the PREVIOUS file's unrelated rows (two nested
  /// `Equatable` arrays — `_ArrayBuffer.count.getter` twice, outer hunks then inner rows), whose
  /// "equal → skip" answer is never useful: a different file's diff should never read as unchanged.
  /// A near-cap (2000-line) diff with long lines made that walk run long enough to trip a Sentry
  /// App Hang (WORKROOM-2S). The box keeps any compare an O(1) reference check.
  final class SideBySideRows {
    let rows: [[UnifiedDiff.SideBySideRow]]
    init(_ rows: [[UnifiedDiff.SideBySideRow]]) { self.rows = rows }
  }

  /// Find source + line-identity index for a loaded diff, boxed for the same reason as
  /// `SideBySideRows` (rebuilt once per load, not per render). Holds BOTH visual orderings: unified
  /// (document order — one line per row) and side-by-side (row-major, left-then-right — rows pair a
  /// deletion run with the addition run that follows it, so row count ≠ line count and the visual
  /// order differs from document order). `⌘G` must step through whichever ordering is on screen.
  final class FindIndex {
    let unifiedLines: [String]
    let unifiedIDs: [DiffLineID]
    let unifiedIndexByID: [DiffLineID: Int]
    let sideBySideLines: [String]
    let sideBySideIDs: [DiffLineID]
    let sideBySideIndexByID: [DiffLineID: Int]

    init(_ diff: UnifiedDiff, sbsRows: [[UnifiedDiff.SideBySideRow]]) {
      let unified = DiffLoader.findSource(for: diff)
      unifiedLines = unified.lines
      unifiedIDs = unified.ids
      #if DEBUG
        precondition(
          !DiffLoader.hasDuplicateIDs(unified.ids),
          "DiffLineID collision in unified ordering — (kind,oldLine,newLine) invariant violated")
      #endif
      // `uniquingKeysWith` (not `Dictionary(uniqueKeysWithValues:)`): a collision — which the debug
      // precondition above already asserts can't happen for any current call path — degrades to
      // "first line wins" in RELEASE rather than crashing.
      unifiedIndexByID = Dictionary(
        zip(unifiedIDs, unifiedIDs.indices), uniquingKeysWith: { first, _ in first })

      let sideBySide = DiffLoader.findSourceSideBySide(sbsRows: sbsRows)
      sideBySideLines = sideBySide.lines
      sideBySideIDs = sideBySide.ids
      #if DEBUG
        precondition(
          !DiffLoader.hasDuplicateIDs(sideBySide.ids),
          "DiffLineID collision in side-by-side ordering — (kind,oldLine,newLine) invariant violated"
        )
      #endif
      sideBySideIndexByID = Dictionary(
        zip(sideBySideIDs, sideBySideIDs.indices), uniquingKeysWith: { first, _ in first })
    }

    func lines(sideBySide: Bool) -> [String] { sideBySide ? sideBySideLines : unifiedLines }
    func ids(sideBySide: Bool) -> [DiffLineID] { sideBySide ? sideBySideIDs : unifiedIDs }
    func indexByID(sideBySide: Bool) -> [DiffLineID: Int] {
      sideBySide ? sideBySideIndexByID : unifiedIndexByID
    }
  }

  private(set) var state: LoadState<UnifiedDiff> = .loading
  /// Syntax-highlighted new-side lines, keyed by 1-based new-file line number. Empty ⇒ render plain
  /// (the always-available fallback). Built asynchronously off the diff render — highlighting can
  /// never block or break the diff.
  private(set) var highlightedLines: [Int: AttributedString] = [:]
  /// Syntax-highlighted OLD-side lines, keyed by 1-based old-file line number — for the diff's
  /// DELETED lines (the new-side `highlightedLines` can't cover them). Built from the pre-image file
  /// in `applyHighlight`; empty ⇒ deletions render plain (no pre-image / binary / add-only diff).
  private(set) var highlightedOldLines: [Int: AttributedString] = [:]
  /// Bumped when a diff finishes loading, so the highlight task (keyed on it) re-runs against the
  /// freshly loaded diff without re-fetching the diff on every theme change.
  private(set) var loadToken = 0
  /// Intra-line change emphasis (line-relative byte ranges) for replaced lines — deletions by
  /// `oldLine`, additions by `newLine`. Computed synchronously from the diff in `load`.
  private(set) var emphasis: (deletions: [Int: Range<Int>], additions: [Int: Range<Int>]) =
    ([:], [:])
  /// Per-hunk side-by-side rows, paired once in `load` (mirroring `emphasis`) so the layout isn't
  /// re-derived on every render (highlight arrival, theme change). Nil unless a diff is loaded;
  /// index-aligned with the loaded diff's `hunks`. Only consumed by the side-by-side body.
  private(set) var sbsRows: SideBySideRows?
  /// Added/removed line counts of the loaded diff, paired once in `load` (same pattern as
  /// `emphasis`/`sbsRows`) rather than recomputed by walking every hunk/line on each render (the
  /// file header reads it on every highlight/theme/mode-flip re-render). `nil` until loaded, or
  /// when there's no line diff.
  private(set) var loadedStats: (additions: Int, removals: Int)?
  /// The find source + line-identity index for the loaded diff (both the unified and side-by-side
  /// orderings — see `FindIndex`). `nil` until a diff is loaded.
  private(set) var findIndex: FindIndex?

  /// The file identity (`FetchKey`) the current diff was loaded for — so a spurious `.task` re-run
  /// for the SAME file no-ops instead of re-entering `load` (see `DiffViewer`'s load task).
  @ObservationIgnored private var loadedKey: FetchKey?
  /// The key of whichever `.task(id:)` invocation most recently started a load at this
  /// view-identity slot — a generation token, held ALONGSIDE `Task.isCancelled` rather than
  /// instead of it. Retargeting the pane swaps the id value at a stable slot (the view instance is
  /// reused, not recreated), and cancellation delivery for that shape does not measure the same
  /// way everywhere: `AvatarView` measured `Task.isCancelled == false` throughout the outgoing
  /// invocation in the live app (2026-08-13), while `DiffViewer` measured it DELIVERED in a
  /// hosted-view harness (`DiffViewerStaleLoadTests`). The harness is not the app's view tree and
  /// the flag's delivery is an unspecified SwiftUI detail, so the flag is the guard the test proves
  /// and the token is the belt. The loader survives the slot being reused (it is the view's
  /// `@State`), so whichever invocation started LAST wins.
  @ObservationIgnored private var activeFetchKey: FetchKey?
  /// The same generation token for the highlight task (`.task(id: highlightKey)`), tracked
  /// separately because the two tasks have independent keys and lifetimes.
  @ObservationIgnored private var activeHighlightKey: HighlightKey?

  /// The highlight task's key for `fetch` under theme generation `theme`, against the latest load.
  func highlightKey(for fetch: FetchKey, theme: Int) -> HighlightKey {
    HighlightKey(fetch: fetch, theme: theme, load: loadToken)
  }

  /// Load `request`'s diff unless it is already the one loaded. Returns whether this call committed
  /// a new state — false for a same-key re-fire, and for a result that went stale while it was read.
  func loadIfNeeded(_ request: Request) async -> Bool {
    let key = request.key
    guard Self.shouldLoad(loadedKey: loadedKey, fetchKey: key) else { return false }
    loadedKey = key
    activeFetchKey = key
    return await load(request, key: key)
  }

  nonisolated static func shouldLoad<Key: Equatable>(loadedKey: Key?, fetchKey: Key) -> Bool {
    loadedKey != fetchKey
  }

  private func resolveRepositoryDiff(_ request: Request) async -> DiffResult {
    if let location = request.repositoryLocation {
      return await DiffResolver().resolve(request.descriptor, in: location)
    }
    return await request.resolveDiff(request.descriptor, request.directory)
  }

  private func repositoryFileContent(_ request: Request, old: Bool) async -> String? {
    let location: RepositoryLocation
    if let repositoryLocation = request.repositoryLocation {
      location = repositoryLocation
    } else {
      guard let local = try? await RepositoryLocation.local(request.directory) else { return nil }
      location = local
    }
    return old
      ? await DiffResolver().oldFileContent(for: request.descriptor, in: location)
      : await DiffResolver().fileContent(for: request.descriptor, in: location)
  }

  private func load(_ request: Request, key: FetchKey) async -> Bool {
    state = .loading
    highlightedLines = [:]  // drop any previous file's colours immediately (no stale flash)
    highlightedOldLines = [:]
    // Canned diffs (the UI-test fixture's workroom path is a fake temp dir with no repo) are served
    // instead of shelling out to git (issue #66 UI tests).
    let result: DiffResult
    if let cannedDiffs = request.cannedDiffs {
      result = cannedDiffs.diff(request.descriptor)
    } else {
      result = await resolveRepositoryDiff(request)
    }
    // Stale-write guard. This path had NO staleness check at all, so a slow diff for the file this
    // pane USED to show could land after a retarget and paint file A's diff, stats and find index
    // into file B's slot — reproduced red/green by `DiffViewerStaleLoadTests`. The token half is the
    // belt; see `activeFetchKey` for why both are here.
    guard !Task.isCancelled, activeFetchKey == key else { return false }
    switch result {
    case .diff(let diff): state = diff.hunks.isEmpty ? .empty : .loaded(diff)
    case .binary: state = .binary
    case .empty: state = .empty
    case .tooLarge: state = .tooLarge
    case .failed(let reason): state = .failed(reason)
    }
    // Intra-line (character-level) change emphasis is computed straight from the diff (no fetch),
    // so it's available for the immediate render — additions/context get it folded into their
    // syntax-highlighted run later, deletions and pre-parse lines use it directly in `lineRow`.
    if case .loaded(let diff) = state {
      emphasis = IntraLineDiff.emphasis(for: diff)
      // Pair the side-by-side rows once here (same place/pattern as `emphasis`) — bounded by the
      // line cap, so the layout never re-pairs on a render-only update (highlight, theme).
      let pairedRows = diff.hunks.map(UnifiedDiff.sideBySideRows(for:))
      sbsRows = SideBySideRows(pairedRows)
      loadedStats = UnifiedDiff.lineStats(for: diff)
      findIndex = FindIndex(diff, sbsRows: pairedRows)
    } else {
      emphasis = ([:], [:])
      sbsRows = nil
      loadedStats = nil
      findIndex = nil
    }
    loadToken &+= 1  // signal the highlight task to (re)build against this diff
    return true
  }

  /// Build syntax highlighting for the loaded diff, off-main and cancellable. Any miss (no grammar,
  /// no/blocked content, parse failure, stale/cancelled) leaves the diff rendering plain — this can
  /// never block or break the diff. Additions and context are coloured from the new file, deletions
  /// from the pre-image.
  func applyHighlight(_ request: Request, key: HighlightKey, tokens: ThemeTokens) async {
    activeHighlightKey = key
    let descriptor = request.descriptor
    guard case .loaded(let diff) = state else {
      highlightedLines = [:]
      return
    }
    // Resolve a grammar from the new path, falling back to the old (rename/delete) path.
    let pathGrammar =
      SyntaxLanguage.grammar(forPath: descriptor.path)
      ?? diff.renamedFrom.flatMap { SyntaxLanguage.grammar(forPath: $0) }
    // An extension-less file may still be detectable via its shebang, which needs the content — so
    // don't bail before fetching in that case. A file with a known-but-unsupported extension still
    // short-circuits to plain (no wasted content fetch).
    let extensionless =
      (descriptor.path as NSString).pathExtension.isEmpty
      && (diff.renamedFrom.map { ($0 as NSString).pathExtension.isEmpty } ?? true)
    guard pathGrammar != nil || extensionless else {
      highlightedLines = [:]
      return
    }
    // New-side content: canned with canned diffs, else the guarded VCS fetch folded into
    // DiffResolver.
    let content: String?
    if let cannedDiffs = request.cannedDiffs {
      content = cannedDiffs.fileContent(descriptor)
    } else {
      content = await repositoryFileContent(request, old: false)
    }
    guard !Task.isCancelled, activeHighlightKey == key else { return }
    guard let content else {
      highlightedLines = [:]
      return
    }
    // Path detection first, then the shebang on the first line (extension-less scripts).
    let firstLine = String(content.prefix { $0 != "\n" && $0 != "\r" })
    guard let grammar = pathGrammar ?? SyntaxLanguage.grammar(forShebang: firstLine) else {
      highlightedLines = [:]
      return
    }
    // Parse, resolve captures and build the per-line strings off the main actor — CPU-bound,
    // bounded by the byte cap and the diff's line cap.
    let additionEmphasis = emphasis.additions
    let lines = await Task.detached(priority: .utility) {
      let spans = SyntaxHighlighter.shared.spans(for: content, grammar: grammar)
      return DiffHighlightMapper.attributedLines(
        diff: diff, content: content, spans: spans, tokens: tokens,
        additionEmphasis: additionEmphasis)
    }.value
    guard !Task.isCancelled, activeHighlightKey == key else { return }
    highlightedLines = lines

    // Old side: highlight the DELETED lines from the pre-image file (the new-side pass can't — they
    // aren't in the new file). Only when the diff actually has deletions, and not with canned diffs
    // (no pre-image source there → deletions render plain). Reuses the same grammar (same file).
    guard diff.hunks.contains(where: { $0.lines.contains { $0.kind == .deletion } }) else { return }
    let oldContent =
      request.cannedDiffs == nil ? await repositoryFileContent(request, old: true) : nil
    guard !Task.isCancelled, activeHighlightKey == key, let oldContent else { return }
    let deletionEmphasis = emphasis.deletions
    let oldLines = await Task.detached(priority: .utility) {
      let oldSpans = SyntaxHighlighter.shared.spans(for: oldContent, grammar: grammar)
      return DiffHighlightMapper.attributedLines(
        diff: diff, content: oldContent, spans: oldSpans, tokens: tokens,
        side: .old, deletionEmphasis: deletionEmphasis)
    }.value
    guard !Task.isCancelled, activeHighlightKey == key else { return }
    highlightedOldLines = oldLines
  }

  /// The memoized side-by-side rows for a hunk index (empty if out of range — should not happen, as
  /// `sbsRows` is built from the same diff in `load`).
  func rows(forHunk index: Int) -> [UnifiedDiff.SideBySideRow] {
    Self.rows(in: sbsRows?.rows, forHunk: index)
  }

  /// Bounds-checked lookup into paired side-by-side rows for a hunk index — pulled out as a pure
  /// static func (mirrors `shouldLoad`) so the boxed-`sbsRows` refactor (WORKROOM-2S: an AppHang
  /// from AttributeGraph deep-comparing the array on every file switch) stays regression-tested
  /// without needing a live view. A `nil` box (no diff loaded) or an out-of-range/negative index
  /// reads empty rather than trapping.
  nonisolated static func rows(in rows: [[UnifiedDiff.SideBySideRow]]?, forHunk index: Int)
    -> [UnifiedDiff.SideBySideRow]
  {
    guard let rows, index >= 0, index < rows.count else { return [] }
    return rows[index]
  }

  // MARK: Find

  /// The unified find source: every line's text + identity, in document order across all hunks.
  /// Excludes chrome that isn't rendered via `styledText` (hunk headers, the renamed-from note, the
  /// truncated footer) — nothing there has a natural `DiffLineID`. Pure — unit-tested.
  nonisolated static func findSource(for diff: UnifiedDiff) -> (lines: [String], ids: [DiffLineID])
  {
    let flat = diff.hunks.flatMap { $0.lines }
    return (flat.map(\.text), flat.map(DiffLineID.id(for:)))
  }

  /// The side-by-side find source: row-major, left-then-right (reading order), so `⌘G` steps through
  /// matches top-to-bottom the way the eye reads a two-column diff — NOT document order (which would
  /// step through every deletion on the left, then jump back to the top for every addition on the
  /// right, since `sideBySideRows` pairs a deletion run with the addition run that follows it into
  /// shared rows). A context row's `left`/`right` are the SAME line (see `sideBySideRows`'s doc), so
  /// it contributes exactly one entry, not two. Pure — unit-tested.
  nonisolated static func findSourceSideBySide(sbsRows: [[UnifiedDiff.SideBySideRow]])
    -> (lines: [String], ids: [DiffLineID])
  {
    var lines: [String] = []
    var ids: [DiffLineID] = []
    for hunkRows in sbsRows {
      for row in hunkRows {
        let leftID = row.left.map(DiffLineID.id(for:))
        if let left = row.left, let leftID {
          lines.append(left.text)
          ids.append(leftID)
        }
        if let right = row.right {
          let rightID = DiffLineID.id(for: right)
          guard rightID != leftID else { continue }  // context row: left/right are the same line
          lines.append(right.text)
          ids.append(rightID)
        }
      }
    }
    return (lines, ids)
  }

  /// Whether `ids` contains a duplicate — the debug-only guard on the `(kind, oldLine, newLine)`
  /// identity invariant (verified true for every current call path: a single file's diff). Kept as a
  /// plain function rather than an inline `precondition` so it's unit-testable directly.
  nonisolated static func hasDuplicateIDs(_ ids: [DiffLineID]) -> Bool {
    Set(ids).count != ids.count
  }
}
