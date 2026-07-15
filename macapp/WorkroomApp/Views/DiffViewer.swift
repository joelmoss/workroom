import Defaults
import SwiftUI

/// Renders a single file's diff inside a content tab (issue #66): a unified, inline view (old/new
/// gutter + colored +/- lines), or a side-by-side view (old left, new right). The layout follows the
/// tab toolbar's per-file toggle (`viewModeOverride`) when set, else the global `Defaults[.diffViewMode]`
/// (which additionally falls back to unified in a pane too narrow for two columns). Both are themed
/// with the shared `diffAdd*/diffRemove*/diffHunk*` tokens.
///
/// Fetch is on-appear via `.task(id:)` keyed on the descriptor's file + revision, so switching to a
/// diff tab (or retargeting the preview to a new file) re-runs `DiffResolver` for the current state —
/// the diff is always fresh, and SwiftUI cancels an in-flight fetch when the view goes away. Lines
/// render in an eager `VStack` (see
/// `unifiedBody`), so a large diff lays out gap-free; `UnifiedDiff.parse`'s line cap bounds it.
struct DiffViewer: View {
  let descriptor: DiffDescriptor
  /// The workroom directory the VCS runs in (resolves the repo-relative path / picks the worktree).
  let directory: String
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

  @State private var state: LoadState = .loading
  /// The file identity (`fetchKey`) the current diff was loaded for — so a spurious `.task` re-run
  /// for the SAME file no-ops instead of re-entering `load()` (see the load task's comment).
  @State private var loadedKey: String?
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
  @State private var sbsRows: [[UnifiedDiff.SideBySideRow]] = []
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
    // Re-fetch whenever the file or its source revision changes (preview retarget, tab switch).
    // Load ONCE per file identity: SwiftUI re-runs this `.task` on the same view instance when the
    // body re-renders after `applyHighlight` populates `highlightedLines` (even though `fetchKey`
    // is unchanged). Without this guard each such re-run re-enters `load()`, which resets
    // `state = .loading`, which re-renders, which re-highlights… a ~150ms feedback loop that leaves
    // the diff pane stuck on its loader forever. Latent until commit-diff highlighting (issue #59)
    // made `applyHighlight` actually populate lines for a History file diff. A genuine file switch
    // changes `fetchKey`; a tab reopen recreates the view (so `@State` resets) — both re-run.
    .task(id: fetchKey) {
      guard loadedKey != fetchKey else { return }
      loadedKey = fetchKey
      await load()
    }
    // Build (or rebuild) highlighting once a diff is loaded, and re-colour on theme change. Keyed
    // on source+path+theme-generation+load-token so a superseded run is cancelled and a stale
    // result (wrong file or old theme) is never applied.
    .task(id: highlightKey) { await applyHighlight() }
  }

  /// Identity of the file+revision this diff is for — the load task's key and the re-load guard.
  private var fetchKey: String { "\(descriptor.source)\u{1F}\(descriptor.path)" }

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

  /// Added / removed line counts of the loaded diff (`nil` until loaded, or when there's no line diff).
  private var loadedStats: (additions: Int, removals: Int)? {
    guard case .loaded(let diff) = state else { return nil }
    var additions = 0
    var removals = 0
    for hunk in diff.hunks {
      for line in hunk.lines {
        switch line.kind {
        case .addition: additions += 1
        case .deletion: removals += 1
        case .context: break
        }
      }
    }
    return (additions, removals)
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

  private func load() async {
    state = .loading
    highlightedLines = [:]  // drop any previous file's colours immediately (no stale flash)
    highlightedOldLines = [:]
    // In UI-test fixture mode the workroom path is a fake temp dir with no repo, so serve a canned
    // diff instead of shelling out to git/jj (issue #66 UI tests).
    let result =
      UITestFixture.isActive
      ? UITestFixture.diff(for: descriptor)
      : await DiffResolver().resolve(descriptor, in: directory)
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
      sbsRows = diff.hunks.map(UnifiedDiff.sideBySideRows(for:))
    } else {
      emphasis = ([:], [:])
      sbsRows = []
    }
    loadToken &+= 1  // signal the highlight task to (re)build against this diff
  }

  /// Build syntax highlighting for the loaded diff, off-main and cancellable. Any miss (no grammar,
  /// no/blocked content, parse failure, stale/cancelled) leaves the diff rendering plain — this can
  /// never block or break the diff. Only additions + context are coloured; deletions stay plain.
  private func applyHighlight() async {
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
    guard !Task.isCancelled else { return }
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
    guard !Task.isCancelled else { return }
    let lines = DiffHighlightMapper.attributedLines(
      diff: diff, content: content, spans: spans, tokens: theme.tokens,
      additionEmphasis: emphasis.additions)
    guard !Task.isCancelled else { return }
    highlightedLines = lines

    // Old side: highlight the DELETED lines from the pre-image file (the new-side pass can't — they
    // aren't in the new file). Only when the diff actually has deletions, and not in fixture mode
    // (no pre-image source there → deletions render plain). Reuses the same grammar (same file).
    guard diff.hunks.contains(where: { $0.lines.contains { $0.kind == .deletion } }) else { return }
    let oldContent =
      UITestFixture.isActive
      ? nil : await DiffResolver().oldFileContent(for: descriptor, in: directory)
    guard !Task.isCancelled, let oldContent else { return }
    let oldSpans = await Task.detached(priority: .utility) {
      SyntaxHighlighter.shared.spans(for: oldContent, grammar: grammar)
    }.value
    guard !Task.isCancelled else { return }
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
      if showSideBySide(width: proxy.size.width) {
        sideBySideBody(diff)
      } else {
        unifiedBody(diff)
      }
    }
  }

  private func unifiedBody(_ diff: UnifiedDiff) -> some View {
    // Vertical-only scroll, eager `VStack` (not `LazyVStack`): the rows soft-wrap via
    // `fixedSize(vertical:)`, and a lazy stack caches a bad height estimate for not-yet-materialised
    // wrapping rows — leaving a blank band in the middle of a tall diff until you scroll it into
    // view. `UnifiedDiff.parse`'s 2000-line cap bounds the row count, so laying them all out up
    // front is affordable and gap-free.
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        if let from = diff.renamedFrom {
          headerNote("Renamed from \(from)")
        }
        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
          hunkHeader(hunk.header)
          ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
            lineRow(line)
          }
        }
        if diff.truncated {
          headerNote("Diff truncated — file too large to show in full.")
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
  }

  /// Side-by-side body (issue #66): same scroll/eager-`VStack` shell as `unifiedBody` (the soft-wrap
  /// reasoning there still holds), but each hunk's rows come from the memoized `sbsRows` and render
  /// as a left(old) | divider | right(new) `HStack`.
  private func sideBySideBody(_ diff: UnifiedDiff) -> some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        if let from = diff.renamedFrom {
          headerNote("Renamed from \(from)")
        }
        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { index, hunk in
          hunkHeader(hunk.header)
          ForEach(Array(rows(forHunk: index).enumerated()), id: \.offset) { _, row in
            sideBySideRow(row)
          }
        }
        if diff.truncated {
          headerNote("Diff truncated — file too large to show in full.")
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
  }

  /// The memoized side-by-side rows for a hunk index (empty if out of range — should not happen, as
  /// `sbsRows` is built from the same diff in `load()`).
  private func rows(forHunk index: Int) -> [UnifiedDiff.SideBySideRow] {
    index < sbsRows.count ? sbsRows[index] : []
  }

  private func sideBySideRow(_ row: UnifiedDiff.SideBySideRow) -> some View {
    // `.top` so each side's gutter aligns to the first visual line when the taller side wraps. The
    // add/remove/absent fills are painted as a full-height background *layer* (two equal halves), not
    // per-cell: a bare cell background collapses to the gutter line under `.top` alignment, so a
    // short side opposite a multi-line wrapped side would only tint its first line. The background
    // matches the row's height (the taller side), so both halves always span the full row.
    HStack(alignment: .top, spacing: 0) {
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
        styledText(line)
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

  private func lineRow(_ line: UnifiedDiff.Line) -> some View {
    // `.top` so the gutter + marker align to the first visual line when a long line wraps.
    HStack(alignment: .top, spacing: 0) {
      unifiedGutter(old: line.oldLine, new: line.newLine)
      Text(marker(line.kind))
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(foreground(line.kind))
        .frame(width: 16, alignment: .center)
      styledText(line)
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
  /// side-by-side cell. Additions/context use the new-side highlight run; deletions use the old-side
  /// (pre-image) run — both built in `applyHighlight`. Intra-line change emphasis is folded into the
  /// highlighted run by the mapper, or applied here (`emphasizedLine`) when highlighting is absent.
  @ViewBuilder private func styledText(_ line: UnifiedDiff.Line) -> some View {
    let highlighted: AttributedString? =
      line.kind == .deletion
      ? line.oldLine.flatMap { highlightedOldLines[$0] }
      : line.newLine.flatMap { highlightedLines[$0] }
    let emphasized: AttributedString? = highlighted == nil ? emphasizedLine(line) : nil
    Group {
      if let highlighted {
        Text(highlighted)  // syntax foreground + intra-line emphasis background
      } else if let emphasized {
        Text(emphasized)  // plain foreground + intra-line emphasis background
      } else {
        // Not syntax-highlighted: use the default code foreground (never the add/remove colour), so
        // the row background — not the text colour — carries the change signal. Keeps text legible
        // and matches the highlighted lines' uncaptured runs.
        Text(line.text.isEmpty ? " " : line.text).foregroundStyle(codeTextColor)
      }
    }
    .font(.system(.callout, design: .monospaced))
    .textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)  // wrap long lines, never truncate
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
