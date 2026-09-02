import Defaults
import SwiftUI

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

/// `unifiedBody`'s `ForEach` element — `Identifiable` by `DiffLineID` directly, so that identity is
/// the ONE thing driving both the `List` row's diffing identity and its `ScrollViewReader` scroll-to
/// target (see the doc comment at that `ForEach` for why a second, separate `.id()` modifier broke
/// `List`'s lazy row realization).
private struct IdentifiedDiffLine: Identifiable {
  let id: DiffLineID
  let line: UnifiedDiff.Line
}

/// `sideBySideBody`'s `ForEach` element — same reasoning as `IdentifiedDiffLine`.
private struct IdentifiedSideBySideRow: Identifiable {
  let id: DiffLineID
  let row: UnifiedDiff.SideBySideRow
}

/// Renders a single file's diff inside a content tab (issue #66): a unified, inline view (old/new
/// gutter + colored +/- lines), or a side-by-side view (old left, new right). The layout follows the
/// tab toolbar's per-file toggle (`viewModeOverride`) when set, else the global `Defaults[.diffViewMode]`
/// (which additionally falls back to unified in a pane too narrow for two columns). Both are themed
/// with the shared `diffAdd*/diffRemove*/diffHunk*` tokens.
///
/// Fetch is on-appear via `.task(id:)` keyed on the descriptor's file + revision, so switching to a
/// diff tab (or retargeting the preview to a new file) re-runs `DiffResolver` for the current state —
/// the diff is always fresh, and SwiftUI cancels an in-flight fetch when the view goes away. Lines
/// render in a `List` (see `unifiedBody`/`sideBySideBody`, WORKROOM-2T): a near-cap (2000-line) diff
/// used to render in one eager `VStack`, which put every line's accessibility element in the tree
/// SwiftUI's focus-responder walk traverses on every layout pass — the App Hang. `List` is
/// `NSTableView`-backed, so it virtualizes both rendering AND accessibility for offscreen rows, unlike
/// a hand-rolled `LazyVStack` (which was the fallback plan, made unnecessary once `List` proved out).
struct DiffViewer: View {
  let descriptor: DiffDescriptor
  /// The workroom directory the VCS runs in (resolves the repo-relative path / picks the worktree).
  let directory: String
  /// The owning project's root (`AppStore.projectRoot(forTarget:)`), or `nil` when `descriptor`
  /// can't be a `.jjWorkingCopy` source (e.g. the changeset detail view, always `.commit`). Passed
  /// straight through to `DiffResolver.resolve` to key `JJSnapshotGate` — see that type's doc.
  let projectRoot: String?
  /// This file's per-tab layout override from the tab toolbar's toggle (issue #66); `nil` ⇒ follow
  /// the global `Defaults[.diffViewMode]` (which additionally falls back to unified in a narrow pane).
  /// Owned by the tab (`TerminalTab.diffViewModeOverride`) and passed in, so the toolbar sets it and
  /// this view reacts — an explicit per-file choice that the pane re-renders to without refetching.
  var viewModeOverride: DiffViewMode? = nil
  /// When true, a compact header sits above the diff: the change symbol, the file path, and the
  /// right-aligned additions/removals count (from the loaded diff). Off by default; the changeset
  /// detail turns it on. Other diff surfaces render bare.
  var showsFileHeader: Bool = false
  /// When the header is shown, the unified/side-by-side switch reads and writes this binding (nil in
  /// the binding ⇒ follow the global `Defaults[.diffViewMode]`). `nil` binding ⇒ no switch in the
  /// header (and layout follows `viewModeOverride`/global as before). Lets the changeset detail own
  /// the choice so it persists across file selection, without touching the global default.
  var headerModeBinding: Binding<DiffViewMode?>? = nil
  /// Whether this pane holds focus — only the focused diff/changeset pane feeds the (shared) find
  /// model and shows the find bar / match highlights. Mirrors `PlainFileViewer.isFocused`.
  var isFocused: Bool = true
  /// The shared find state (owned by `AppStore`, `contentFind`) — reused unmodified across file, diff,
  /// and changeset panes.
  @ObservedObject var find: FileFindModel
  /// The diff fetch, injectable so a test can hold one file's load open while the pane is retargeted
  /// to another (the stale-write race `activeFetchKey` guards). Defaults to the real resolver.
  var resolveDiff: (DiffDescriptor, String, String?) async -> DiffResult = {
    await DiffResolver().resolve($0, in: $1, projectRoot: $2)
  }
  #if DEBUG
    /// Test-only observation seam for the stale-load regression test — fires with the `LoadState`
    /// this SPECIFIC instance just committed. Per-instance (a `@MainActor` closure the test owns),
    /// not a shared static, for the same reason `AvatarView.onCommit` is: the macOS XCTest host runs
    /// the real, fully-live app alongside the test's hosted view, so a global seam would also catch
    /// commits from unrelated `DiffViewer`s already on screen.
    var onCommit: (@MainActor (LoadState) -> Void)? = nil
  #endif

  @State private var state: LoadState = .loading
  /// The file identity (`fetchKey`) the current diff was loaded for — so a spurious `.task` re-run
  /// for the SAME file no-ops instead of re-entering `load()` (see the load task's comment).
  @State private var loadedKey: String?
  /// The id of whichever `.task(id:)` invocation most recently started a load at this
  /// view-identity slot — a generation token, held ALONGSIDE `Task.isCancelled` rather than
  /// instead of it. Retargeting this pane swaps the id value at a stable slot (the view instance is
  /// reused, not recreated), and cancellation delivery for that shape does not measure the same
  /// way everywhere: `AvatarView` measured `Task.isCancelled == false` throughout the outgoing
  /// invocation in the live app (see TODOS "`.task(id:)` cancellation is not reliably delivered on
  /// an in-place value swap"), while this view measured it DELIVERED in a hosted-view harness
  /// (`DiffViewerStaleLoadTests`). The harness is not the app's view tree and the flag's delivery is
  /// an unspecified SwiftUI detail, so the flag is the guard the test proves and the token is the
  /// belt. `@State` survives the slot being reused, so whichever invocation started LAST wins.
  @State private var activeFetchKey: String?
  /// The same generation token for the highlight task (`.task(id: highlightKey)`), tracked
  /// separately because the two tasks have independent keys and lifetimes.
  @State private var activeHighlightKey: String?
  /// Syntax-highlighted new-side lines, keyed by 1-based new-file line number. Empty ⇒ render plain
  /// (the always-available fallback). Built asynchronously off the diff render — highlighting can
  /// never block or break the diff.
  @State private var highlightedLines: [Int: AttributedString] = [:]
  /// Syntax-highlighted OLD-side lines, keyed by 1-based old-file line number — for the diff's
  /// DELETED lines (the new-side `highlightedLines` can't cover them). Built from the pre-image file
  /// in `applyHighlight`; empty ⇒ deletions render plain (no pre-image / binary / add-only diff).
  @State private var highlightedOldLines: [Int: AttributedString] = [:]
  /// Bumped when a diff finishes loading, so the highlight task (keyed on it) re-runs against the
  /// freshly loaded diff without re-fetching the diff on every theme change.
  @State private var loadToken = 0
  /// Intra-line change emphasis (line-relative byte ranges) for replaced lines — deletions by
  /// `oldLine`, additions by `newLine`. Computed synchronously from the diff in `load()`.
  @State private var emphasis: (deletions: [Int: Range<Int>], additions: [Int: Range<Int>]) =
    ([:], [:])
  /// Per-hunk side-by-side rows, paired once in `load()` (mirroring `emphasis`) so the layout isn't
  /// re-derived on every render (highlight arrival, theme change). Empty unless a diff is loaded;
  /// index-aligned with the loaded diff's `hunks`. Only consumed by `sideBySideBody`.
  ///
  /// Boxed in a non-`Equatable` reference type rather than stored as a bare array: a plain
  /// `@State` array is a genuine AttributeGraph-tracked value, and every file switch reassigns it
  /// against the PREVIOUS file's unrelated rows, forcing AG to structurally walk two nested
  /// `Equatable` arrays (`_ArrayBuffer.count.getter` twice — outer hunks, inner rows) whose "equal
  /// → skip" result is never useful (a different file's diff should never read as unchanged). A
  /// near-cap (2000-line) diff with long lines made that walk run long enough to trip a Sentry App
  /// Hang (WORKROOM-2S). The box makes AG's compare an O(1) reference check instead.
  @State private var sbsRows: SideBySideRows?
  /// Added/removed line counts of the loaded diff, paired once in `load()` (same pattern as
  /// `emphasis`/`sbsRows`) rather than recomputed by walking every hunk/line on each render
  /// (`fileHeader` reads it on every highlight/theme/mode-flip re-render). `nil` until loaded, or
  /// when there's no line diff.
  @State private var loadedStats: (additions: Int, removals: Int)?
  /// The find source + line-identity index for the loaded diff (both the unified and side-by-side
  /// orderings — see `FindIndex`'s doc). Boxed for the same AttributeGraph reason as `SideBySideRows`.
  /// `nil` until a diff is loaded.
  @State private var findIndex: FindIndex?
  /// Which layout is CURRENTLY on screen, tracked explicitly (not read inline from `showSideBySide`)
  /// so a flip can be observed and re-feed `find` with the newly-active ordering — unified and
  /// side-by-side show the same lines in a different visual order (see `FindIndex`), so `⌘G` must
  /// step through whichever order is on screen right now.
  @State private var isSideBySideActive = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The global default diff layout (issue #66), used when this tab has no `viewModeOverride`. A
  /// narrow pane additionally falls back to unified (see `sideBySideMinWidth`).
  @Default(.diffViewMode) private var diffViewMode
  private let theme = ThemeService.shared

  /// Below this content width a side-by-side diff's two half-width columns wrap code into tall
  /// blocks that ruin line comparison, so we render unified even when side-by-side is selected.
  private static let sideBySideMinWidth: CGFloat = 700

  enum LoadState: Equatable {
    case loading
    case loaded(UnifiedDiff)
    case binary
    case empty
    case tooLarge
    case failed(String)
  }

  /// Reference-type box for `sbsRows` (see its doc) — deliberately not `Equatable`, so storing it
  /// in `@State` makes AttributeGraph's write-time compare an identity check rather than a walk of
  /// the wrapped arrays.
  private final class SideBySideRows {
    let rows: [[UnifiedDiff.SideBySideRow]]
    init(_ rows: [[UnifiedDiff.SideBySideRow]]) { self.rows = rows }
  }

  /// Find source + line-identity index for a loaded diff, boxed for the same AttributeGraph reason as
  /// `SideBySideRows` (rebuilt once per `load()`, not per render). Holds BOTH visual orderings: unified
  /// (document order — one line per row) and side-by-side (row-major, left-then-right — rows pair a
  /// deletion run with the addition run that follows it, so row count ≠ line count and the visual
  /// order differs from document order). `⌘G` must step through whichever ordering is on screen.
  private final class FindIndex {
    let unifiedLines: [String]
    let unifiedIDs: [DiffLineID]
    let unifiedIndexByID: [DiffLineID: Int]
    let sideBySideLines: [String]
    let sideBySideIDs: [DiffLineID]
    let sideBySideIndexByID: [DiffLineID: Int]

    init(_ diff: UnifiedDiff, sbsRows: [[UnifiedDiff.SideBySideRow]]) {
      let unified = DiffViewer.findSource(for: diff)
      unifiedLines = unified.lines
      unifiedIDs = unified.ids
      #if DEBUG
        precondition(
          !DiffViewer.hasDuplicateIDs(unified.ids),
          "DiffLineID collision in unified ordering — (kind,oldLine,newLine) invariant violated")
      #endif
      // `uniquingKeysWith` (not `Dictionary(uniqueKeysWithValues:)`): a collision — which the debug
      // precondition above already asserts can't happen for any current call path — degrades to
      // "first line wins" in RELEASE rather than crashing.
      unifiedIndexByID = Dictionary(
        zip(unifiedIDs, unifiedIDs.indices), uniquingKeysWith: { first, _ in first })

      let sideBySide = DiffViewer.findSourceSideBySide(sbsRows: sbsRows)
      sideBySideLines = sideBySide.lines
      sideBySideIDs = sideBySide.ids
      #if DEBUG
        precondition(
          !DiffViewer.hasDuplicateIDs(sideBySide.ids),
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

  var body: some View {
    Group {
      if showsFileHeader {
        VStack(spacing: 0) {
          fileHeader
          Divider()
          content
        }
      } else {
        content
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.tokens.bg)
    // Find bar (⌘F), top-trailing over the focused pane only — search state is shared across every
    // file/diff/changeset pane (`AppStore.contentFind`), so only the focused one shows/feeds it.
    .overlay(alignment: .topTrailing) { if isFocused { FileFindBar(model: find) } }
    // Feed the find model this diff's lines (in whichever ordering is on screen) when focus arrives,
    // mirroring `PlainFileViewer.swift`'s equivalent `onChange`.
    .onChange(of: isFocused) { _, focused in
      if focused { find.setSource(findIndex?.lines(sideBySide: isSideBySideActive) ?? []) }
    }
    // Re-fetch whenever the file or its source revision changes (preview retarget, tab switch).
    // Load ONCE per file identity: SwiftUI re-runs this `.task` on the same view instance when the
    // body re-renders after `applyHighlight` populates `highlightedLines` (even though `fetchKey`
    // is unchanged). Without this guard each such re-run re-enters `load()`, which resets
    // `state = .loading`, which re-renders, which re-highlights… a ~150ms feedback loop that leaves
    // the diff pane stuck on its loader forever. Latent until commit-diff highlighting (issue #59)
    // made `applyHighlight` actually populate lines for a History file diff. A genuine file switch
    // changes `fetchKey`; a tab reopen recreates the view (so `@State` resets) — both re-run.
    .task(id: fetchKey) {
      guard Self.shouldLoad(loadedKey: loadedKey, fetchKey: fetchKey) else { return }
      let myKey = fetchKey
      loadedKey = myKey
      activeFetchKey = myKey
      await load(key: myKey)
    }
    // Build (or rebuild) highlighting once a diff is loaded, and re-colour on theme change. Keyed
    // on source+path+theme-generation+load-token so a superseded run is cancelled and a stale
    // result (wrong file or old theme) is never applied.
    .task(id: highlightKey) {
      let myKey = highlightKey
      activeHighlightKey = myKey
      await applyHighlight(key: myKey)
    }
  }

  /// Identity of the file+revision this diff is for — the load task's key and the re-load guard.
  private var fetchKey: String { "\(descriptor.source)\u{1F}\(descriptor.path)" }

  /// The load-once-per-file decision behind `.task(id: fetchKey)`: load only when the file identity
  /// actually changed. A re-run with the SAME `fetchKey` (a spurious body re-render re-firing the
  /// task after `applyHighlight` populates lines) must skip, so `load()` can't re-enter and spin the
  /// loader forever (the issue-#59 re-fire loop). `nil` loadedKey ⇒ first load. Pure, unit-tested.
  static func shouldLoad(loadedKey: String?, fetchKey: String) -> Bool { loadedKey != fetchKey }

  /// Identity of the current highlight: file + revision + theme generation + which diff load it's
  /// for. Any change cancels the in-flight highlight and starts a fresh, correctly-keyed one.
  private var highlightKey: String {
    "\(descriptor.source)\u{1F}\(descriptor.path)\u{1F}\(theme.generation)\u{1F}\(loadToken)"
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .loading:
      centered { ProgressView().controlSize(.small) }
    case .loaded(let diff):
      diffBody(diff)
    case .binary:
      message("Binary file", systemImage: "doc.fill", detail: "No text diff to show.")
    case .empty:
      message("No changes", systemImage: "checkmark.circle", detail: nil)
    case .tooLarge:
      message(
        "Diff too large to show", systemImage: "doc.fill",
        detail: "Open the file in your editor (⌘-click in the Files list).")
    case .failed(let reason):
      message("Diff unavailable", systemImage: "exclamationmark.triangle", detail: reason)
    }
  }

  // MARK: File header

  /// Compact header above the diff (opt-in via `showsFileHeader`): change symbol + file path, with
  /// the additions/removals count right-aligned. The counts come from the loaded diff, so they're
  /// blank until it loads (and for binary/too-large files, which have no line diff).
  private var fileHeader: some View {
    HStack(spacing: 8) {
      // Info cluster — combined into one a11y element with the path as its tooltip, kept separate
      // from the interactive switch (so the switch keeps its own per-segment tooltips + VoiceOver).
      HStack(spacing: 8) {
        Text(Self.changeLetter(descriptor.change))
          .font(.system(.caption2, design: .monospaced).weight(.bold))
          .foregroundStyle(Self.changeColor(descriptor.change))
          .frame(width: 14)
        headerPathText
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        if let stats = loadedStats {
          HStack(spacing: 6) {
            if stats.additions > 0 {
              Text("+\(stats.additions)").foregroundStyle(theme.tokens.diffAddFg)
            }
            if stats.removals > 0 {
              Text("−\(stats.removals)").foregroundStyle(theme.tokens.diffRemoveFg)
            }
            if stats.additions == 0 && stats.removals == 0 {
              Text("0").foregroundStyle(.secondary)
            }
          }
          .font(.system(.caption, design: .monospaced))
        }
      }
      .help(descriptor.path)
      .accessibilityElement(children: .combine)
      if let binding = headerModeBinding {
        DiffModeSwitch(mode: binding.wrappedValue ?? diffViewMode) { binding.wrappedValue = $0 }
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.tokens.panel)
  }

  /// The header path with its leading directories dimmed and the file name in the primary colour.
  private var headerPathText: Text {
    let name = (descriptor.path as NSString).lastPathComponent
    let prefix = String(descriptor.path.dropLast(name.count))
    return Text(prefix).foregroundStyle(.tertiary) + Text(name)
  }

  /// Single-letter change symbol, matching the changeset file-list badges.
  private static func changeLetter(_ change: ChangedFile.Change) -> String {
    switch change {
    case .added: return "A"
    case .modified: return "M"
    case .deleted: return "D"
    case .renamed: return "R"
    case .conflicted: return "!"
    case .untracked: return "?"
    case .other: return "\u{2022}"
    }
  }

  private static func changeColor(_ change: ChangedFile.Change) -> Color {
    switch change {
    case .added: return .green
    case .deleted: return .red
    case .modified: return .yellow
    case .renamed: return .blue
    case .conflicted: return .orange
    case .untracked, .other: return .secondary
    }
  }

  private func load(key: String) async {
    state = .loading
    highlightedLines = [:]  // drop any previous file's colours immediately (no stale flash)
    highlightedOldLines = [:]
    // In UI-test fixture mode the workroom path is a fake temp dir with no repo, so serve a canned
    // diff instead of shelling out to git/jj (issue #66 UI tests).
    let result =
      UITestFixture.isActive
      ? UITestFixture.diff(for: descriptor)
      : await resolveDiff(descriptor, directory, projectRoot)
    // Stale-write guard. This path had NO staleness check at all, so a slow diff for the file this
    // pane USED to show could land after a retarget and paint file A's diff, stats and find index
    // into file B's slot — reproduced red/green by `DiffViewerStaleLoadTests`. The token half is the
    // belt; see `activeFetchKey` for why both are here.
    guard !Task.isCancelled, activeFetchKey == key else { return }
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
    if isFocused { find.setSource(findIndex?.lines(sideBySide: isSideBySideActive) ?? []) }
    loadToken &+= 1  // signal the highlight task to (re)build against this diff
    #if DEBUG
      onCommit?(state)
    #endif
  }

  /// Build syntax highlighting for the loaded diff, off-main and cancellable. Any miss (no grammar,
  /// no/blocked content, parse failure, stale/cancelled) leaves the diff rendering plain — this can
  /// never block or break the diff. Only additions + context are coloured; deletions stay plain.
  private func applyHighlight(key: String) async {
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
    // New-side content: canned in fixture mode, else the guarded VCS fetch folded into DiffResolver.
    let content =
      UITestFixture.isActive
      ? UITestFixture.fileContent(for: descriptor)
      : await DiffResolver().fileContent(for: descriptor, in: directory)
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
    // Parse + resolve captures off the main actor — CPU-bound, bounded by the byte cap.
    let spans = await Task.detached(priority: .utility) {
      SyntaxHighlighter.shared.spans(for: content, grammar: grammar)
    }.value
    guard !Task.isCancelled, activeHighlightKey == key else { return }
    let lines = DiffHighlightMapper.attributedLines(
      diff: diff, content: content, spans: spans, tokens: theme.tokens,
      additionEmphasis: emphasis.additions)
    guard !Task.isCancelled, activeHighlightKey == key else { return }
    highlightedLines = lines

    // Old side: highlight the DELETED lines from the pre-image file (the new-side pass can't — they
    // aren't in the new file). Only when the diff actually has deletions, and not in fixture mode
    // (no pre-image source there → deletions render plain). Reuses the same grammar (same file).
    guard diff.hunks.contains(where: { $0.lines.contains { $0.kind == .deletion } }) else { return }
    let oldContent =
      UITestFixture.isActive
      ? nil : await DiffResolver().oldFileContent(for: descriptor, in: directory)
    guard !Task.isCancelled, activeHighlightKey == key, let oldContent else { return }
    let oldSpans = await Task.detached(priority: .utility) {
      SyntaxHighlighter.shared.spans(for: oldContent, grammar: grammar)
    }.value
    guard !Task.isCancelled, activeHighlightKey == key else { return }
    highlightedOldLines = DiffHighlightMapper.attributedLines(
      diff: diff, content: oldContent, spans: oldSpans, tokens: theme.tokens,
      side: .old, deletionEmphasis: emphasis.deletions)
  }

  // MARK: Diff body

  /// Pick the layout for the given content width. An explicit per-tab toggle (`viewModeOverride`)
  /// wins outright; the global default additionally falls back to unified in a pane too narrow for
  /// two columns.
  private func showSideBySide(width: CGFloat) -> Bool {
    if let activeViewModeOverride { return activeViewModeOverride == .sideBySide }
    return diffViewMode == .sideBySide && width >= Self.sideBySideMinWidth
  }

  /// The effective explicit layout override: the header switch's choice (if a header binding is
  /// present) wins, else the tab's `viewModeOverride`. `nil` ⇒ follow the global default.
  private var activeViewModeOverride: DiffViewMode? {
    headerModeBinding?.wrappedValue ?? viewModeOverride
  }

  /// Pick the layout: side-by-side per `showSideBySide`, else unified. `GeometryReader` measures the
  /// available content width for the global default's narrow-pane fallback.
  @ViewBuilder private func diffBody(_ diff: UnifiedDiff) -> some View {
    GeometryReader { proxy in
      let active = showSideBySide(width: proxy.size.width)
      Group {
        if active {
          sideBySideBody(diff)
        } else {
          unifiedBody(diff)
        }
      }
      // Track which layout is on screen (`isSideBySideActive`) so find can be re-searched against
      // whichever ordering matches it — a live resize crossing `sideBySideMinWidth`, or the header's
      // mode switch, changes what's actually visible without a diff reload. `initial: true` also
      // syncs state on first render, so a diff that opens already wide enough for side-by-side isn't
      // stuck reading the (default-false) unified ordering. Guarded so a resize that doesn't cross the
      // threshold (recomputed every frame) doesn't re-`setSource` on every pixel.
      .onChange(of: active, initial: true) { _, newValue in
        guard isSideBySideActive != newValue else { return }
        isSideBySideActive = newValue
        if isFocused { find.setSource(findIndex?.lines(sideBySide: newValue) ?? []) }
      }
    }
  }

  private func unifiedBody(_ diff: UnifiedDiff) -> some View {
    // `List`, not `ScrollView { VStack {...} }` (WORKROOM-2T): a near-cap (2000-line) diff used to lay
    // every line out eagerly, on the reasoning that soft-wrapping rows (`.fixedSize(vertical:)`) can't
    // report their height to a `LazyVStack` before being materialized, and an inaccurate estimate left
    // a visible blank band mid-scroll. That reasoning was correct as far as it went, but it missed the
    // actual cost: 2000 eager rows means 2000 accessibility elements in the tree SwiftUI's
    // accessibility focus-responder walk traverses on every layout pass — the App Hang.
    // `List` sidesteps both problems at once: it's `NSTableView`-backed, so it virtualizes rendering
    // AND accessibility together for offscreen rows (no manual height pre-measurement needed, and no
    // per-row `AppKitPlatformViewHost` node for a row that was never realized). `HistoryPanel`'s
    // `LazyVStack` is fine for its OWN rows (single-line, fixed-height, so a lazy stack's height
    // estimate is exact) but couldn't have carried the same fix here without the pre-measurement work
    // `List` makes unnecessary — see TODOS.md/WORKROOM-2T for the full investigation, including why
    // `List` was avoided elsewhere in this codebase (macOS list chrome fighting custom row styling) and
    // why that concern didn't hold up here once actually tried (`.listStyle(.plain)` +
    // `.listRowInsets`/`.listRowSeparator(.hidden)` + `.environment(\.defaultMinListRowHeight, 0)`).
    ScrollViewReader { proxy in
      List {
        if let from = diff.renamedFrom {
          headerNote("Renamed from \(from)")
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        }
        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
          hunkHeader(hunk.header)
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
          // `Identifiable`-based (not a second `.id()` modifier layered on an `id: \.offset` ForEach):
          // two identity mechanisms on the same rows made `List`/`ScrollViewReader` abandon lazy row
          // realization on macOS (measured — every row built, `DiffViewerLazyRenderingTests` caught it,
          // WORKROOM-2T class regression). One identity, used directly, keeps virtualization intact.
          ForEach(hunk.lines.map { IdentifiedDiffLine(id: DiffLineID.id(for: $0), line: $0) }) {
            item in
            lineRow(item.line)
              .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
          }
        }
        if diff.truncated {
          headerNote("Diff truncated — file too large to show in full.")
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 0)
      .scrollContentBackground(.hidden)
      .onChange(of: find.current) { _, _ in scrollToMatch(proxy, sideBySide: false) }
      .onChange(of: find.matches) { _, _ in scrollToMatch(proxy, sideBySide: false) }
      .onChange(of: find.sourceGeneration) { _, _ in scrollToMatch(proxy, sideBySide: false) }
    }
  }

  /// Side-by-side body (issue #66): same `List` shell as `unifiedBody` (see its comment for why `List`,
  /// WORKROOM-2T), but each hunk's rows come from the memoized `sbsRows` and render as a
  /// left(old) | divider | right(new) `HStack`.
  private func sideBySideBody(_ diff: UnifiedDiff) -> some View {
    ScrollViewReader { proxy in
      List {
        if let from = diff.renamedFrom {
          headerNote("Renamed from \(from)")
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        }
        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { index, hunk in
          hunkHeader(hunk.header)
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
          // See the matching comment in `unifiedBody`: `Identifiable`-based, not a second `.id()`.
          ForEach(
            rows(forHunk: index).map { IdentifiedSideBySideRow(id: Self.rowID(for: $0), row: $0) }
          ) { item in
            sideBySideRow(item.row)
              .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
          }
        }
        if diff.truncated {
          headerNote("Diff truncated — file too large to show in full.")
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 0)
      .scrollContentBackground(.hidden)
      .onChange(of: find.current) { _, _ in scrollToMatch(proxy, sideBySide: true) }
      .onChange(of: find.matches) { _, _ in scrollToMatch(proxy, sideBySide: true) }
      .onChange(of: find.sourceGeneration) { _, _ in scrollToMatch(proxy, sideBySide: true) }
    }
  }

  /// Scroll to the current find match, gated on `isFocused` (the shared-model isolation requirement —
  /// `find` is one instance shared across every visible diff/changeset pane). `sideBySide` picks which
  /// ordering's ids to resolve the match against, and must match whichever body is calling this (each
  /// caller passes its own literal, not `isSideBySideActive`, which can lag one render behind a layout
  /// flip). For side-by-side, a row's `.id()` is its left-else-right line id (`rowID(for:)`), so the
  /// match's line id must be resolved to whichever ROW contains it — rows ≠ lines there (a deletion run
  /// pairs with the addition run that follows it into shared rows).
  private func scrollToMatch(_ proxy: ScrollViewProxy, sideBySide: Bool) {
    guard isFocused, let findIndex else { return }
    guard
      let id = Self.matchedLineID(
        match: find.currentMatch, ids: findIndex.ids(sideBySide: sideBySide))
    else { return }
    let scrollID: DiffLineID?
    if sideBySide {
      // The matched line's id may be the row's RIGHT side while the row's own `.id()` (`rowID(for:)`,
      // left-else-right) is keyed by its LEFT side — so check both sides for containment, then
      // resolve to the row's actual scroll-id, not the matched line's id directly.
      scrollID = sbsRows?.rows.lazy.flatMap { $0 }.first(where: {
        $0.left.map(DiffLineID.id(for:)) == id || $0.right.map(DiffLineID.id(for:)) == id
      }).map(Self.rowID(for:))
    } else {
      scrollID = id
    }
    guard let scrollID else { return }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
      proxy.scrollTo(scrollID, anchor: .center)
    }
  }

  /// The memoized side-by-side rows for a hunk index (empty if out of range — should not happen, as
  /// `sbsRows` is built from the same diff in `load()`).
  private func rows(forHunk index: Int) -> [UnifiedDiff.SideBySideRow] {
    Self.rows(in: sbsRows?.rows, forHunk: index)
  }

  /// Bounds-checked lookup into paired side-by-side rows for a hunk index — pulled out as a pure
  /// static func (mirrors `shouldLoad`) so the boxed-`sbsRows` refactor (WORKROOM-2S: an AppHang
  /// from AttributeGraph deep-comparing the array on every file switch) stays regression-tested
  /// without needing a live view. A `nil` box (no diff loaded) or an out-of-range/negative index
  /// reads empty rather than trapping.
  static func rows(in rows: [[UnifiedDiff.SideBySideRow]]?, forHunk index: Int)
    -> [UnifiedDiff.SideBySideRow]
  {
    guard let rows, index >= 0, index < rows.count else { return [] }
    return rows[index]
  }

  // MARK: Find

  /// The unified find source: every line's text + identity, in document order across all hunks.
  /// Excludes chrome that isn't rendered via `styledText` (hunk headers, the renamed-from note, the
  /// truncated footer) — nothing there has a natural `DiffLineID`. Pure — unit-tested.
  static func findSource(for diff: UnifiedDiff) -> (lines: [String], ids: [DiffLineID]) {
    let flat = diff.hunks.flatMap { $0.lines }
    return (flat.map(\.text), flat.map(DiffLineID.id(for:)))
  }

  /// The side-by-side find source: row-major, left-then-right (reading order), so `⌘G` steps through
  /// matches top-to-bottom the way the eye reads a two-column diff — NOT document order (which would
  /// step through every deletion on the left, then jump back to the top for every addition on the
  /// right, since `sideBySideRows` pairs a deletion run with the addition run that follows it into
  /// shared rows). A context row's `left`/`right` are the SAME line (see `sideBySideRows`'s doc), so
  /// it contributes exactly one entry, not two. Pure — unit-tested.
  static func findSourceSideBySide(sbsRows: [[UnifiedDiff.SideBySideRow]])
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
  static func hasDuplicateIDs(_ ids: [DiffLineID]) -> Bool { Set(ids).count != ids.count }

  /// A side-by-side row's scroll-to identity — its left line's id, or its right's if left is absent.
  /// Non-optional (`.id()` and `ScrollViewProxy.scrollTo` must agree on the SAME concrete `ID` type —
  /// `AnyHashable` does not treat `DiffLineID?` and `DiffLineID` as equal, so mixing them would make
  /// `scrollTo` silently fail to find the row); the fallback sentinel is unreachable in practice
  /// (`sideBySideRows` never emits a row with neither side present) but keeps this total rather than
  /// force-unwrapping in a render path.
  static func rowID(for row: UnifiedDiff.SideBySideRow) -> DiffLineID {
    row.left.map(DiffLineID.id(for:)) ?? row.right.map(DiffLineID.id(for:))
      ?? DiffLineID(kind: .context, oldLine: nil, newLine: nil)
  }

  /// The `DiffLineID` the current find match hit, bounds-checked against `ids` (out of range ⇒ a
  /// stale match from a load that raced a keystroke — no scroll, not a crash). Pure — unit-tested.
  static func matchedLineID(match: FileFindMatch?, ids: [DiffLineID]) -> DiffLineID? {
    guard let match, match.line >= 0, match.line < ids.count else { return nil }
    return ids[match.line]
  }

  #if DEBUG
    /// How many times `sideBySideRow`'s body has been evaluated this process — the measurement behind
    /// the WORKROOM-2T hang-regression test (does `List` actually realize only visible rows for a
    /// near-2000-line diff, mirroring `HistoryRow.bodyPasses`/`ChangedFileRow.bodyPasses`).
    static var sideBySideRowBodyPasses = 0
  #endif

  private func sideBySideRow(_ row: UnifiedDiff.SideBySideRow) -> some View {
    #if DEBUG
      Self.sideBySideRowBodyPasses += 1
    #endif
    // `.top` so each side's gutter aligns to the first visual line when the taller side wraps. The
    // add/remove/absent fills are painted as a full-height background *layer* (two equal halves), not
    // per-cell: a bare cell background collapses to the gutter line under `.top` alignment, so a
    // short side opposite a multi-line wrapped side would only tint its first line. The background
    // matches the row's height (the taller side), so both halves always span the full row.
    return HStack(alignment: .top, spacing: 0) {
      sideCell(row.left, side: .left)
      Divider()
      sideCell(row.right, side: .right)
    }
    .padding(.vertical, 2)  // a little line breathing room (matches the unified rows)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HStack(spacing: 0) {
        sideHalfFill(row.left).frame(maxWidth: .infinity)
        sideHalfFill(row.right).frame(maxWidth: .infinity)
      }
    )
  }

  private enum DiffSide { case left, right }

  /// One column of a side-by-side row: the old side (`.left`, deletions + context) or the new side
  /// (`.right`, additions + context). A `nil` line is an absent cell — no number, just the
  /// row-background layer's faint fill, so a length mismatch between the two sides reads as a gap. No
  /// `+`/`-` marker: the side and colour already convey add/remove.
  @ViewBuilder private func sideCell(_ line: UnifiedDiff.Line?, side: DiffSide) -> some View {
    HStack(alignment: .top, spacing: 0) {
      sideGutter(side == .left ? line?.oldLine : line?.newLine)
      if let line {
        styledText(line, sideBySide: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 4)
          .padding(.trailing, 8)
      } else {
        Color.clear.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(side == .left ? "diff.side.left" : "diff.side.right")
    .accessibilityLabel(line.map(accessibilityLabel) ?? "absent")
    // Test-observable highlight marker (XCUITest can't see colours); "absent" for a blank side.
    .accessibilityValue(line.map { isHighlighted($0) ? "highlighted" : "plain" } ?? "absent")
  }

  /// The fill for one side, painted in the row's full-height background layer (so it spans the row
  /// even when this side is shorter than a wrapping neighbour). `nil` (absent side) → a faint fill
  /// derived from the muted token (no new theme/palette entry); context → clear.
  private func cellFill(_ line: UnifiedDiff.Line?) -> Color {
    line.map { rowBackground($0.kind) } ?? theme.tokens.fgMuted.opacity(0.05)
  }

  private func hunkHeader(_ header: String) -> some View {
    Text(header)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(theme.tokens.diffHunkFg)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.tokens.diffHunkBg)
      .accessibilityLabel("Hunk \(header)")
  }

  /// Width of the two-column gutter strip: two `unifiedGutterNumber` cells (32 + 6 + 6 each).
  private static let gutterWidth: CGFloat = 88

  #if DEBUG
    /// How many times `lineRow`'s body has been evaluated this process — the measurement behind the
    /// WORKROOM-2T hang-regression test, mirroring `HistoryRow.bodyPasses`/`ChangedFileRow.bodyPasses`.
    /// A near-2000-line diff must move this by far less than the line count once `List` realizes only
    /// visible rows — the property that WOULD have caught the eager-`VStack` App Hang.
    static var lineRowBodyPasses = 0
  #endif

  private func lineRow(_ line: UnifiedDiff.Line) -> some View {
    #if DEBUG
      Self.lineRowBodyPasses += 1
    #endif
    // `.top` so the gutter + marker align to the first visual line when a long line wraps.
    return HStack(alignment: .top, spacing: 0) {
      unifiedGutter(old: line.oldLine, new: line.newLine)
      Text(marker(line.kind))
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(foreground(line.kind))
        .frame(width: 16, alignment: .center)
      styledText(line, sideBySide: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.trailing, 8)
    }
    .padding(.vertical, 2)  // a little line breathing room
    .frame(maxWidth: .infinity, alignment: .leading)
    // Gutter tint as a full-height leading strip (spans the row's vertical padding, unlike a fill on
    // the top-aligned gutter block), painted over the row tint so the gutter reads deeper — GH-style.
    .background(alignment: .leading) { gutterFill(line.kind).frame(width: Self.gutterWidth) }
    .background(rowBackground(line.kind))
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("diff.line")
    .accessibilityLabel(accessibilityLabel(line))
    // A test-observable marker that highlighting was applied (XCUITest can't see colours).
    .accessibilityValue(isHighlighted(line) ? "highlighted" : "plain")
  }

  /// The GitHub-style two-column line-number gutter for the unified view: old | new, each right-
  /// aligned in its own padded cell, in a fixed-width strip divided from the code by a hairline. The
  /// tint is painted by `lineRow` as a full-height strip (see there); this just lays out the numbers.
  private func unifiedGutter(old: Int?, new: Int?) -> some View {
    HStack(spacing: 0) {
      unifiedGutterNumber(old)
      unifiedGutterNumber(new)
    }
    .frame(width: Self.gutterWidth)
    .overlay(alignment: .trailing) { Rectangle().fill(theme.tokens.border).frame(width: 1) }
  }

  private func unifiedGutterNumber(_ number: Int?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(theme.tokens.fgMuted)
      .frame(width: 32, alignment: .trailing)
      .padding(.leading, 6).padding(.trailing, 6)
  }

  /// The gutter strip's fill: neutral on context, a deeper add/remove tint on changed lines (layered
  /// over the row background so the gutter reads deeper than the code, GitHub-style).
  private func gutterFill(_ kind: UnifiedDiff.Line.Kind) -> Color {
    switch kind {
    case .context: return theme.tokens.fgMuted.opacity(0.06)
    case .addition: return theme.tokens.diffAddFg.opacity(0.13)
    case .deletion: return theme.tokens.diffRemoveFg.opacity(0.13)
    }
  }

  /// The styled, soft-wrapping text for one diff line, shared by the unified row and each
  /// side-by-side cell. `sideBySide` says which body is asking, so highlighting is looked up against
  /// the ordering ACTUALLY on screen (passed explicitly from the caller rather than read off
  /// `isSideBySideActive`, which can lag one render behind the body GeometryReader just picked).
  private func styledText(_ line: UnifiedDiff.Line, sideBySide: Bool) -> some View {
    Text(styledAttributed(line, sideBySide: sideBySide))
      .font(.system(.callout, design: .monospaced))
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)  // wrap long lines, never truncate
  }

  /// Additions/context use the new-side highlight run; deletions use the old-side (pre-image) run —
  /// both built in `applyHighlight`. Intra-line change emphasis is folded into the highlighted run by
  /// the mapper, or applied here (`emphasizedLine`) when highlighting is absent. Composites the find
  /// match background on top of whichever of the three built the base string (`applyFindHighlight`).
  private func styledAttributed(_ line: UnifiedDiff.Line, sideBySide: Bool) -> AttributedString {
    let highlighted: AttributedString? =
      line.kind == .deletion
      ? line.oldLine.flatMap { highlightedOldLines[$0] }
      : line.newLine.flatMap { highlightedLines[$0] }
    var base: AttributedString
    if let highlighted {
      base = highlighted  // syntax foreground + intra-line emphasis background
    } else if let emphasized = emphasizedLine(line) {
      base = emphasized  // plain foreground + intra-line emphasis background
    } else {
      // Not syntax-highlighted: use the default code foreground (never the add/remove colour), so
      // the row background — not the text colour — carries the change signal. Keeps text legible
      // and matches the highlighted lines' uncaptured runs.
      base = AttributedString(line.text.isEmpty ? " " : line.text)
      base.foregroundColor = codeTextColor
    }
    let hits = findHits(for: line, sideBySide: sideBySide)
    guard !hits.isEmpty else { return base }
    return Self.applyFindHighlight(
      base, hits: hits,
      currentBg: theme.tokens.accent.opacity(0.55), otherBg: theme.tokens.accent.opacity(0.28))
  }

  /// This line's find-match ranges (character offsets), or empty when there's nothing to highlight.
  /// Gated on `isFocused` — `find` is shared across every visible diff/changeset pane, and an
  /// unfocused pane's `findIndex` describes UNRELATED content. `sideBySide` picks which ordering to
  /// look the line up in.
  private func findHits(for line: UnifiedDiff.Line, sideBySide: Bool) -> [(
    range: Range<Int>, isCurrent: Bool
  )] {
    guard isFocused, let findIndex,
      let idx = findIndex.indexByID(sideBySide: sideBySide)[DiffLineID.id(for: line)]
    else { return [] }
    return find.highlights(onLine: idx)
  }

  /// Composite find-match backgrounds onto an already-built `AttributedString` — generic over what
  /// colored it (syntax mapper, `emphasizedPlain`, or the freshly-wrapped plain branch above). `hits`
  /// are CHARACTER-offset ranges (`FileFindModel.highlights`, via `String.distance`). `AttributedString`
  /// itself does not expose a bounds-checked `index(_:offsetBy:limitedBy:)` (its own `index(_:offsetBy:)`
  /// traps out of range), but `.characters` — the `BidirectionalCollection<Character>` view — shares
  /// `AttributedString`'s own `Index` type, so walking offsets through `.characters` and subscripting
  /// `out[...]` directly with the result is correct, and safely bounds-checked. Correct regardless of
  /// the base string having been assembled from UTF-8 byte-sliced runs (`emphasizedPlain`,
  /// `DiffHighlightMapper`) — byte-slicing only matters at construction time; grapheme-cluster
  /// boundaries are recomputed over the final joined string. Pure — unit-tested.
  static func applyFindHighlight(
    _ base: AttributedString, hits: [(range: Range<Int>, isCurrent: Bool)],
    currentBg: Color, otherBg: Color
  ) -> AttributedString {
    guard !hits.isEmpty else { return base }
    var out = base
    let characters = out.characters
    for hit in hits {
      guard
        let lo = characters.index(
          characters.startIndex, offsetBy: hit.range.lowerBound, limitedBy: characters.endIndex),
        let hi = characters.index(
          characters.startIndex, offsetBy: hit.range.upperBound, limitedBy: characters.endIndex),
        lo <= hi
      else { continue }
      out[lo..<hi].backgroundColor = hit.isCurrent ? currentBg : otherBg
    }
    return out
  }

  /// Whether `line` renders with a syntax-highlighted run — its new-side line (add/context) or its
  /// old-side line (deletion) was coloured. Drives the test-observable `accessibilityValue`.
  private func isHighlighted(_ line: UnifiedDiff.Line) -> Bool {
    if line.kind == .deletion { return line.oldLine.flatMap { highlightedOldLines[$0] } != nil }
    return line.newLine.flatMap { highlightedLines[$0] } != nil
  }

  /// The intra-line-emphasised text for a replaced line (deeper tint behind the changed bytes), or
  /// `nil` for context lines / lines with no intra-line change. Used for deletions and additions not
  /// yet syntax-highlighted; highlighted additions get the emphasis from the mapper instead.
  private func emphasizedLine(_ line: UnifiedDiff.Line) -> AttributedString? {
    let range: Range<Int>?
    let bg: Color
    switch line.kind {
    case .deletion:
      range = line.oldLine.flatMap { emphasis.deletions[$0] }
      bg = theme.tokens.diffRemoveEmphasisBg
    case .addition:
      range = line.newLine.flatMap { emphasis.additions[$0] }
      bg = theme.tokens.diffAddEmphasisBg
    case .context:
      return nil
    }
    guard let range, !line.text.isEmpty else { return nil }
    return Self.emphasizedPlain(line.text, fg: codeTextColor, range: range, bg: bg)
  }

  /// The default code foreground for diff text (matches the syntax mapper's uncaptured runs). Changed
  /// lines use this, not the add/remove colour, so syntax highlighting stays visible — the row
  /// background and the `+`/`−` marker carry the add/remove signal (GitHub-style).
  private var codeTextColor: Color { Color(nsColor: theme.tokens.nsFg) }

  /// Build a single-colour line with `bg` drawn behind the `range` (line-relative UTF-8 bytes).
  static func emphasizedPlain(_ text: String, fg: Color, range: Range<Int>, bg: Color)
    -> AttributedString
  {
    let bytes = Array(text.utf8)
    let lo = max(0, min(range.lowerBound, bytes.count))
    let hi = max(lo, min(range.upperBound, bytes.count))
    func seg(_ r: Range<Int>, _ background: Color?) -> AttributedString {
      var a = AttributedString(String(decoding: bytes[r], as: UTF8.self))
      a.foregroundColor = fg
      if let background { a.backgroundColor = background }
      return a
    }
    var out = AttributedString()
    if lo > 0 { out.append(seg(0..<lo, nil)) }
    if hi > lo { out.append(seg(lo..<hi, bg)) }
    if hi < bytes.count { out.append(seg(hi..<bytes.count, nil)) }
    return out
  }

  /// Width of one side's line-number gutter (a single `unifiedGutterNumber` cell: 32 + 6 + 6).
  private static let sideGutterWidth: CGFloat = 44

  /// One side's line-number gutter for the side-by-side view — the same number cell + hairline
  /// divider as the unified gutter, so both views read identically. The deeper tint is painted by
  /// `sideHalfFill` as a full-height strip (mirroring the unified row's strip).
  private func sideGutter(_ number: Int?) -> some View {
    unifiedGutterNumber(number)
      .overlay(alignment: .trailing) { Rectangle().fill(theme.tokens.border).frame(width: 1) }
  }

  /// The full-height background for one side of a side-by-side row: the cell tint, plus a deeper
  /// gutter strip over its leading number column (nil/absent side → just the faint cell fill).
  @ViewBuilder private func sideHalfFill(_ line: UnifiedDiff.Line?) -> some View {
    ZStack(alignment: .leading) {
      cellFill(line)
      if let line { gutterFill(line.kind).frame(width: Self.sideGutterWidth) }
    }
  }

  private func headerNote(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Empty / error states

  private func message(_ title: String, systemImage: String, detail: String?) -> some View {
    centered {
      VStack(spacing: 6) {
        Image(systemName: systemImage).font(.title2).foregroundStyle(.tertiary)
        Text(title).font(.callout).foregroundStyle(.secondary)
        if let detail, !detail.isEmpty {
          Text(detail).font(.footnote).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center).lineLimit(3)
        }
      }
      .padding(24)
    }
  }

  private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
    inner().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  // MARK: Styling

  private func marker(_ kind: UnifiedDiff.Line.Kind) -> String {
    switch kind {
    case .addition: return "+"
    case .deletion: return "-"
    case .context: return " "
    }
  }

  private func foreground(_ kind: UnifiedDiff.Line.Kind) -> Color {
    switch kind {
    case .addition: return theme.tokens.diffAddFg
    case .deletion: return theme.tokens.diffRemoveFg
    case .context: return .primary
    }
  }

  private func rowBackground(_ kind: UnifiedDiff.Line.Kind) -> Color {
    switch kind {
    case .addition: return theme.tokens.diffAddBg
    case .deletion: return theme.tokens.diffRemoveBg
    case .context: return .clear
    }
  }

  private func accessibilityLabel(_ line: UnifiedDiff.Line) -> String {
    let prefix: String
    switch line.kind {
    case .addition: prefix = "added"
    case .deletion: prefix = "removed"
    case .context: prefix = "unchanged"
    }
    return "\(prefix): \(line.text)"
  }
}
