import AppKit
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
  private let theme = ThemeService.shared

  var body: some View {
    CodeTextView(
      attributed: attributed, version: version, tokens: theme.tokens, find: find, isFocused: false
    )
    .task(id: "\(theme.generation)\u{1F}\(text)") { await render() }
  }

  /// How tall the script's lines are, with the text view's insets, so a short script is drawn no
  /// taller than it is. A long line that wraps adds rows this leaves out; the view scrolls then.
  static func contentHeight(of text: String) -> CGFloat {
    let lineHeight = NSLayoutManager().defaultLineHeight(for: PlainFileViewer.font)
    return CGFloat(PlainFileViewer.splitLines(text).count) * lineHeight + 16
  }

  /// Plain at once, then with syntax colours worked out off-main, as `PlainFileViewer` does; a
  /// script with no grammar stays plain.
  private func render() async {
    let source = text
    attributed = FileHighlightMapper.nsAttributedString(
      content: source, spans: [], tokens: theme.tokens, font: PlainFileViewer.font)
    version &+= 1
    let firstLine = PlainFileViewer.splitLines(source).first
    guard let grammar = SyntaxLanguage.grammar(forPath: name, firstLine: firstLine) else { return }
    let spans = await Task.detached(priority: .utility) {
      SyntaxHighlighter.shared.spans(for: source, grammar: grammar)
    }.value
    guard !Task.isCancelled, !spans.isEmpty else { return }
    attributed = FileHighlightMapper.nsAttributedString(
      content: source, spans: spans, tokens: theme.tokens, font: PlainFileViewer.font)
    version &+= 1
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
    window.contentView = NSHostingView(rootView: ScriptCodeView(text: text, name: name))
    window.center()
    shown.insert(window)
    window.makeKeyAndOrderFront(nil)
  }

  override func close() {
    super.close()
    Self.shown.remove(self)
  }
}
