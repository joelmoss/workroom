import AppKit
import DesignSystem
import SwiftUI
import SyntaxHighlighting

/// A script to read before approving it (#363), drawn as the Files inspector draws a file
/// (`PlainFileViewer`): monospaced and selectable, with line numbers and the same syntax colours.
struct ScriptCodeView: View {
  /// The script as a person must read it (`ScriptTrust.visibleText`).
  let text: String
  /// Its file name, which with its shebang picks the grammar.
  let name: String
  /// `CodeTextView` needs one; nothing searches a script.
  @StateObject private var find = FileFindModel()
  @State private var attributed = NSAttributedString()
  @State private var version = 0
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    CodeTextView(
      attributed: attributed, version: version, tokens: tokens, find: find, isFocused: false
    )
    .task(id: "\(ThemeService.shared.generation)\u{1F}\(text)") { await render() }
  }

  /// How tall the script is drawn `width` points wide, with the text view's insets: each line
  /// counts the rows it wraps to, so a script of a few long lines is not cut to a few rows. An
  /// estimate (a monospaced font, the line-number gutter guessed), so the view still scrolls if short.
  static func contentHeight(of text: String, width: CGFloat) -> CGFloat {
    let font = PlainFileViewer.font
    let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    let columns = max(1, Int((width - gutterAllowance) / charWidth))
    let rows = FileContentLoader.splitLines(text).reduce(0) { total, line in
      total + max(1, (line.count + columns - 1) / columns)
    }
    return CGFloat(rows) * lineHeight + 16
  }

  /// What the line numbers and the text's insets take from a row's width.
  private static let gutterAllowance: CGFloat = 64

  /// Plain at once, then with syntax colours worked out off-main, as `PlainFileViewer` does; a
  /// script with no grammar stays plain.
  private func render() async {
    let source = text
    attributed = FileHighlightMapper.nsAttributedString(
      content: source, spans: [], tokens: tokens, font: PlainFileViewer.font)
    version &+= 1
    let firstLine = FileContentLoader.splitLines(source).first
    guard let grammar = SyntaxLanguage.grammar(forPath: name, firstLine: firstLine) else { return }
    let highlighted = await FileHighlightMapper.highlighted(
      content: source, grammar: grammar, tokens: tokens, font: PlainFileViewer.font)
    guard !Task.isCancelled, let highlighted else { return }
    attributed = highlighted
    version &+= 1
  }
}

/// A script to read before approving it, boxed: the creation pane's setup script and the error
/// sheet's teardown script (#363). A longer script than fits scrolls. A button inside its top right
/// corner, on a backing of its own so it stands out over the script, opens it in a window of its own.
struct ScriptBox: View {
  let text: String
  let name: String
  /// The box's accessibility identifier; its button's adds ".openInWindow".
  let id: String
  /// The width it is first laid out at, to work out how many rows the script wraps to.
  var idealWidth: CGFloat = 640
  @Environment(\.themeTokens) private var tokens

  /// It never shrinks below this (or the script, if shorter), and opens no taller than `maxIdeal`;
  /// past that it takes whatever height its container gives it, so a resized sheet grows it.
  private static let minHeight: CGFloat = 120
  private static let maxIdeal: CGFloat = 420

  private var contentHeight: CGFloat {
    ScriptCodeView.contentHeight(of: text, width: idealWidth)
  }

  var body: some View {
    ScriptCodeView(text: text, name: name)
      .frame(
        minHeight: min(contentHeight, Self.minHeight),
        idealHeight: min(contentHeight, Self.maxIdeal),
        maxHeight: .infinity
      )
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(tokens.border, lineWidth: 1)
      )
      .accessibilityIdentifier(id)
      .overlay(alignment: .topTrailing) {
        PaneToolbarButton(
          systemImage: "arrow.up.forward.square", help: "Open in new window",
          accessibilityLabel: "Open script in new window", identifier: "\(id).openInWindow"
        ) { ScriptWindow.show(text: text, name: name) }
        .buttonStyle(
          ToolbarIconButtonStyle(
            wellSize: PaneTitleBarMetrics.wellSize,
            horizontalPadding: PaneTitleBarMetrics.wellPadding)
        )
        .font(.system(size: PaneTitleBarMetrics.glyph))
        .background(tokens.panel, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .strokeBorder(tokens.border, lineWidth: 1)
        )
        .padding(6)
      }
  }
}

/// A script in a window of its own, to read at length. It holds a copy of the text, so it stays
/// open whatever happens to the create that showed it. ⌘W closes it, as any auxiliary window.
final class ScriptWindow: NSWindow {
  /// Every open one: AppKit doesn't keep a window alive.
  private static var shown: Set<ScriptWindow> = []

  static func show(text: String, name: String) {
    let window = ScriptWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = "scripts/\(name)"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ScriptCodeView(text: text, name: name).themeTokensRoot())
    window.center()
    shown.insert(window)
    window.makeKeyAndOrderFront(nil)
  }

  override func close() {
    super.close()
    Self.shown.remove(self)
  }
}
