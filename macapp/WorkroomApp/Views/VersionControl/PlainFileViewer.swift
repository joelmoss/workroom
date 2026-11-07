import DesignSystem
import SwiftUI
import SyntaxHighlighting
import WorkroomVCS

/// Read-only viewer for a working-tree file, shown in a content tab when a file is picked in the
/// inspector's Files section. Reads the file off-main, renders it with line numbers, and applies the
/// same tree-sitter syntax highlighting the diff viewer uses (degrading to plain on any miss). It is
/// deliberately read-only — editing stays in the terminal or the external editor (⌘-click a file in
/// the Files panel). Binary / too-large / unreadable files show a placeholder instead.
struct PlainFileViewer: View {
  let descriptor: FileDescriptor
  /// The workroom directory the repo-relative `descriptor.path` resolves against.
  let directory: String
  /// Where the file is read when it isn't a path on this Mac: a remote workroom's location on its
  /// host (#253). nil resolves `directory` locally.
  var repositoryLocation: RepositoryLocation? = nil
  /// Whether this pane holds focus — only the focused file viewer feeds the find model and shows the
  /// find bar / match highlights (the model is shared, since only one pane searches at a time).
  var isFocused: Bool = true
  /// This tab's Markdown source/preview override, driven by the tab toolbar's Source/Preview switch
  /// (`TerminalTab.markdownPreviewOverride`). `nil` ⇒ the default (Markdown opens rendered). Ignored
  /// for non-Markdown files, which are always source. Mirrors `DiffViewer.viewModeOverride`.
  var previewOverride: Bool?
  /// The shared in-file find state (owned by `AppStore`). The focused viewer feeds it its lines.
  @ObservedObject var find: FileFindModel

  /// The read, its stale-load guard and its classification. `@State`, so it lives as long as this
  /// view's identity: a retarget to another file reuses it, a reopened tab starts a fresh one.
  @State private var loader = FileContentLoader()
  /// Whether the Markdown preview has painted its first render. Until `__render` has run and WebKit
  /// has painted, the `WKWebView` is an empty rectangle, so the preview covers it with a themed panel.
  @State private var previewRendered = false
  @Environment(\.themeTokens) private var tokens
  /// The theme's apply count, which keys the highlight and the Markdown render: a re-apply of the
  /// same theme still recolours them.
  private var themeGeneration: Int { ThemeService.shared.generation }

  /// Whether this file is Markdown (preview mode is offered only then).
  private var isMarkdown: Bool { PlainFileViewer.isMarkdown(descriptor.path) }
  /// Rendered preview vs. source. Markdown defaults to preview; the tab toolbar's switch overrides it
  /// via `previewOverride`. Non-Markdown files are always source.
  private var showingPreview: Bool { isMarkdown && (previewOverride ?? true) }

  /// Whether the file at `path` is Markdown — the one file kind that offers a rendered preview. Shared
  /// with the tab strip so its Source/Preview switch appears for exactly these tabs.
  nonisolated static func isMarkdown(_ path: String) -> Bool {
    SyntaxLanguage.grammar(forPath: path) == .markdown
  }

  /// The code font, shared by the text view and the line-number ruler's alignment.
  static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  var body: some View {
    content(for: loader.state)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // Find bar (source mode only — preview has no in-text find), top-trailing over a focused pane.
      .overlay(alignment: .topTrailing) {
        if isFocused && !showingPreview { FileFindBar(model: find) }
      }
      .background(tokens.bg)
      .task(id: descriptor.path) {
        previewRendered = false  // a new file means a new render to wait for
        let loaded = await loader.load(
          path: descriptor.path, directory: directory, location: repositoryLocation,
          tokens: tokens, font: Self.font)
        if let loaded, isFocused { find.setSource(loaded) }  // search this file once it's on screen
      }
      .task(id: highlightKey) {
        await loader.applyHighlight(path: descriptor.path, tokens: tokens, font: Self.font)
      }
      // Feed the find model this file's lines when focus arrives (or the file/content changes), so a
      // search runs against what's actually on screen.
      .onChange(of: isFocused) { _, focused in if focused { find.setSource(lines) } }
      // Toggling Source/Preview swaps which branch of `fileBody` exists, so returning to Preview
      // builds a new preview, which has a render to wait for — the loader has to come back with it.
      .onChange(of: showingPreview) { _, preview in if preview { previewRendered = false } }
  }

  /// Identity of the current highlight: file + theme generation + which load it's for. Any change
  /// cancels the in-flight highlight and starts a fresh, correctly-keyed one.
  private var highlightKey: String {
    "\(descriptor.path)\u{1F}\(themeGeneration)\u{1F}\(loader.loadToken)"
  }

  /// The displayed lines (capped — see `FileContentLoader.lineCap`), empty until a text file loads.
  private var lines: [String] {
    if case .loaded(let text) = loader.state { return text.lines }
    return []
  }

  // MARK: Body

  @ViewBuilder private func content(for state: LoadState<FileContentLoader.Text>) -> some View {
    switch state {
    case .loading:
      centered { ProgressView().controlSize(.small) }
    case .loaded(let text):
      fileBody(text)
    case .empty:
      MessageState("Empty file", systemImage: "doc")
    case .binary:
      MessageState("Binary file", systemImage: "doc.fill", detail: "No preview available.")
    case .tooLarge:
      MessageState(
        "File too large to preview", systemImage: "doc.fill",
        detail: "Open it in your editor (⌘-click in the Files list).")
    case .failed(let reason):
      MessageState("Can't open file", systemImage: "exclamationmark.triangle", detail: reason)
    }
  }

  @ViewBuilder private func fileBody(_ text: FileContentLoader.Text) -> some View {
    Group {
      if showingPreview {
        // Rendered Markdown in a themed WKWebView — GFM tables, task lists, and mermaid diagrams,
        // all bundled/offline. Read-only, selectable, with externally-opening links.
        MarkdownWebView(
          markdown: text.content, tokens: tokens, generation: themeGeneration,
          onFirstRender: {
            // The UI-test seam pins the loading state on screen; the real loader is far too
            // short-lived for XCUITest to catch reliably (see UITestFixture.holdPreviewLoader).
            #if DEBUG
              if UITestFixture.holdPreviewLoader { return }
            #endif
            previewRendered = true
          }
        )
        // Cover the web view's boot window with a themed panel from the first frame, so opening a
        // Markdown file never shows an empty white rectangle. Most previews paint in under 100 ms,
        // so the spinner only joins the cover once the render has taken `DelayedSpinner.delay`.
        .overlay {
          if !previewRendered {
            centered { DelayedSpinner() }
              .background(tokens.bg)
              .transition(.opacity)
          }
        }
        .animation(.easeOut(duration: 0.12), value: previewRendered)
      } else {
        // Source: an NSTextView (CodeTextView) — read-only, fully selectable across lines, with a
        // line-number gutter and find-match highlighting.
        CodeTextView(
          attributed: loader.attributed, version: loader.version, tokens: tokens, find: find,
          isFocused: isFocused
        )
      }
    }
    // The line cap applies to `content`, which feeds BOTH modes — so the notice belongs to both.
    // Preview used to cut off at `lineCap` silently, with no cue that anything was missing.
    .overlay(alignment: .bottomLeading) {
      if text.truncated {
        Text("File truncated — showing the first \(FileContentLoader.lineCap) lines.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.regularMaterial, in: Capsule())
          .padding(8)
          // Decorative: never absorb clicks/scroll from the web view or text view underneath.
          .allowsHitTesting(false)
      }
    }
  }

  private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
    inner().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

/// The preview loader's spinner, held back for `delay` so a fast render never flashes it. Each time
/// the cover appears it is a new view, so the wait starts again.
private struct DelayedSpinner: View {
  static let delay: Duration = .milliseconds(250)
  @State private var due = false

  var body: some View {
    ZStack {
      if due {
        ProgressView()
          .controlSize(.small)
          .accessibilityIdentifier("file.preview.loading")
          .transition(.opacity)
      }
    }
    .task {
      guard (try? await Task.sleep(for: Self.delay)) != nil else { return }
      withAnimation(.easeIn(duration: 0.12)) { due = true }
    }
  }
}
