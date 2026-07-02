import SwiftUI

/// Read-only viewer for a working-tree file, shown in a content tab when a file is picked in the
/// inspector's Files section. Reads the file off-main, renders it with line numbers, and applies the
/// same tree-sitter syntax highlighting the diff viewer uses (degrading to plain on any miss). It is
/// deliberately read-only — editing stays in the terminal or the external editor (⌘-click a file in
/// the Files panel). Binary / too-large / unreadable files show a placeholder instead.
struct PlainFileViewer: View {
  let descriptor: FileDescriptor
  /// The workroom directory the repo-relative `descriptor.path` resolves against.
  let directory: String
  /// Whether this pane holds focus — only the focused file viewer feeds the find model and shows the
  /// find bar / match highlights (the model is shared, since only one pane searches at a time).
  var isFocused: Bool = true
  /// The shared in-file find state (owned by `AppStore`). The focused viewer feeds it its lines.
  @ObservedObject var find: FileFindModel

  @State private var state: LoadState = .loading
  /// The displayed lines (capped — see `lineCap`), the always-available plain fallback.
  @State private var lines: [String] = []
  /// The (possibly line-capped) content the highlight task parses; kept so a theme change recolours
  /// without re-reading the file.
  @State private var content = ""
  /// True when the file was longer than `lineCap` and only the head is shown.
  @State private var truncated = false
  /// The themed, (optionally) syntax-highlighted content the `NSTextView` renders. Plain immediately
  /// on load, upgraded when highlighting arrives / the theme changes.
  @State private var attributed = NSAttributedString()
  /// Bumped whenever `attributed` is replaced, so `CodeTextView` resets its text storage only then.
  @State private var version = 0
  /// Bumped when a file finishes loading, so the highlight task (keyed on it) re-runs against the
  /// freshly loaded content without re-reading on every theme change.
  @State private var loadToken = 0
  /// Source vs. rendered for a Markdown file; ignored for other files (always source). Reset to the
  /// per-file default on load; a manual toggle persists until the next file opens.
  @State private var mode: RenderMode = .source
  private let theme = ThemeService.shared

  enum RenderMode: String, CaseIterable { case source, preview }

  /// Whether this file is Markdown (preview mode is offered only then).
  private var isMarkdown: Bool { SyntaxLanguage.grammar(forPath: descriptor.path) == .markdown }
  private var showingPreview: Bool { isMarkdown && mode == .preview }

  /// Files at or over this size aren't loaded (open them in an editor instead). Comfortably above
  /// the 2 MB syntax-highlight cap, so a big-but-readable file still shows (plain).
  static let maxBytes = 8 * 1024 * 1024
  /// Most lines rendered. Bounds the highlight work; the head is shown with a note past it.
  static let lineCap = 5000
  /// The code font, shared by the text view and the line-number ruler's alignment.
  static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  enum LoadState: Equatable {
    case loading
    case text
    case empty
    case binary
    case tooLarge
    case failed(String)
  }

  /// The read outcome, classified purely from the file's bytes (no I/O) so the gating is
  /// unit-testable. `.text` carries the decoded UTF-8 string.
  enum Outcome: Equatable {
    case empty
    case binary
    case tooLarge
    case text(String)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Markdown gets a header bar with the Source/Preview switch, so it never overlays the content.
      if isMarkdown && state == .text { modeToggleBar }
      content(for: state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Find bar (source mode only — preview has no in-text find), top-trailing over a focused pane.
        .overlay(alignment: .topTrailing) {
          if isFocused && !showingPreview { FileFindBar(model: find) }
        }
    }
    .background(theme.tokens.bg)
    .task(id: descriptor.path) { await load() }
    .task(id: highlightKey) { await applyHighlight() }
    // Feed the find model this file's lines when focus arrives (or the file/content changes), so a
    // search runs against what's actually on screen.
    .onChange(of: isFocused) { _, focused in if focused { find.setSource(lines) } }
  }

  /// The header bar with the Source ⇄ Preview switch (Markdown files only).
  private var modeToggleBar: some View {
    HStack(spacing: 0) {
      Picker("", selection: $mode) {
        Text("Preview").tag(RenderMode.preview)
        Text("Source").tag(RenderMode.source)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      // macOS doesn't show a pointer over controls by default; the switch reads better as a button.
      .onHover { inside in
        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(theme.tokens.bg)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// Identity of the current highlight: file + theme generation + which load it's for. Any change
  /// cancels the in-flight highlight and starts a fresh, correctly-keyed one.
  private var highlightKey: String {
    "\(descriptor.path)\u{1F}\(theme.generation)\u{1F}\(loadToken)"
  }

  // MARK: Loading

  private func load() async {
    state = .loading
    lines = []
    attributed = NSAttributedString()
    content = ""
    truncated = false
    let absolute = (directory as NSString).appendingPathComponent(descriptor.path)
    let root = directory
    let outcome = await Task.detached(priority: .utility) { () -> Outcome? in
      // Refuse to read through a symlink that escapes the workroom root. The Files tree lists repo
      // files (git ls-files / jj file list), so a committed symlink like `notes -> ~/.ssh/id_rsa`
      // would otherwise display the target's contents from outside the workroom (review).
      guard PlainFileViewer.isContained(path: absolute, within: root) else { return nil }
      guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: absolute), options: .mappedIfSafe)
      else { return nil }
      return PlainFileViewer.classify(data: data)
    }.value
    guard !Task.isCancelled else { return }
    switch outcome {
    case .none: state = .failed("File unavailable")
    case .empty: state = .empty
    case .binary: state = .binary
    case .tooLarge: state = .tooLarge
    case .text(let full):
      var split = PlainFileViewer.splitLines(full)
      if split.count > Self.lineCap {
        split = Array(split.prefix(Self.lineCap))
        truncated = true
      }
      lines = split
      content = split.joined(separator: "\n")
      // Show the content plain immediately; `applyHighlight` upgrades it with syntax colours.
      attributed = FileHighlightMapper.nsAttributedString(
        content: content, spans: [], tokens: theme.tokens, font: Self.font)
      version &+= 1
      state = .text
      loadToken &+= 1
      mode = isMarkdown ? .preview : .source  // Markdown opens rendered; others always source
      if isFocused { find.setSource(split) }  // search this file once it's on screen
    }
  }

  /// Build syntax highlighting for the loaded file, off-main and cancellable. Any miss (no grammar,
  /// parse failure, stale/cancelled) leaves the file rendering plain — highlighting can never block
  /// or break the viewer.
  private func applyHighlight() async {
    guard state == .text, !content.isEmpty else { return }
    // Detect by path, then by the shebang on the first line — so an extension-less script
    // (`#!/usr/bin/env bash`) still highlights. No grammar ⇒ keep the plain (already-shown) string.
    guard let grammar = SyntaxLanguage.grammar(forPath: descriptor.path, firstLine: lines.first)
    else { return }
    let source = content
    let spans = await Task.detached(priority: .utility) {
      SyntaxHighlighter.shared.spans(for: source, grammar: grammar)
    }.value
    guard !Task.isCancelled, source == content, !spans.isEmpty else { return }
    let highlighted = FileHighlightMapper.nsAttributedString(
      content: source, spans: spans, tokens: theme.tokens, font: Self.font)
    guard !Task.isCancelled else { return }
    attributed = highlighted
    version &+= 1
  }

  // MARK: Pure helpers (unit-tested)

  /// Whether `path`, after resolving symlinks, is the workroom `root` itself or a descendant of it.
  /// Guards the file read against a repo-committed symlink that points outside the workroom. Compares
  /// resolved path *components* so `/a/bc` isn't treated as inside `/a/b`. Pure — unit-tested.
  static func isContained(path: String, within root: String) -> Bool {
    let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let rootComponents = resolvedRoot.pathComponents
    let components = resolved.pathComponents
    guard components.count >= rootComponents.count else { return false }
    return Array(components.prefix(rootComponents.count)) == rootComponents
  }

  /// Classify a file's bytes into a render outcome. Empty → `.empty`; over `byteCap` → `.tooLarge`;
  /// a NUL byte in the first 8 KB or non-UTF-8 → `.binary`; else the decoded text.
  static func classify(data: Data, byteCap: Int = maxBytes) -> Outcome {
    if data.isEmpty { return .empty }
    if data.count > byteCap { return .tooLarge }
    if data.prefix(8192).contains(0) { return .binary }
    guard let string = String(data: data, encoding: .utf8) else { return .binary }
    return .text(string)
  }

  /// Split into display lines, dropping the phantom empty line a trailing newline would add (so the
  /// line count matches an editor's and `FileHighlightMapper`'s).
  static func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    return lines
  }

  // MARK: Body

  @ViewBuilder private func content(for state: LoadState) -> some View {
    switch state {
    case .loading:
      centered { ProgressView().controlSize(.small) }
    case .text:
      fileBody
    case .empty:
      message("Empty file", systemImage: "doc", detail: nil)
    case .binary:
      message("Binary file", systemImage: "doc.fill", detail: "No preview available.")
    case .tooLarge:
      message(
        "File too large to preview", systemImage: "doc.fill",
        detail: "Open it in your editor (⌘-click in the Files list).")
    case .failed(let reason):
      message("Can't open file", systemImage: "exclamationmark.triangle", detail: reason)
    }
  }

  @ViewBuilder private var fileBody: some View {
    if showingPreview {
      // Rendered Markdown in a themed WKWebView — GFM tables, task lists, and mermaid diagrams,
      // all bundled/offline. Read-only, selectable, with externally-opening links.
      MarkdownWebView(markdown: content, tokens: theme.tokens, generation: theme.generation)
    } else {
      // Source: an NSTextView (CodeTextView) — read-only, fully selectable across lines, with a
      // line-number gutter and find-match highlighting.
      CodeTextView(
        attributed: attributed, version: version, tokens: theme.tokens, find: find,
        isFocused: isFocused
      )
      .overlay(alignment: .bottomLeading) {
        if truncated {
          Text("File truncated — showing the first \(Self.lineCap) lines.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
      }
    }
  }

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
}
