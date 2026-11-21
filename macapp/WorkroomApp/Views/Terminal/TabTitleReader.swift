import SwiftUI

/// Reads a tab's title where it is shown, and nowhere above. A terminal's title changes ten times
/// a second under a spinner (`LiveTitle`), and a body that reads it re-renders for each one: with
/// the tab strip, the pane and the sidebar reading it in their own bodies, one pane's spinner cost
/// 15% of a core on the main thread (Dev build, 2026-10-23). Those bodies hand the read to this
/// leaf, so only its subtree re-renders.
struct TabTitleReader<Content: View>: View {
  let content: TabContent
  @ViewBuilder let text: (String) -> Content

  var body: some View {
    text(content.title)
  }
}

extension View {
  /// Applies modifiers that need the tab's title (a tooltip, an accessibility label) without the
  /// body that built this view reading it: the view is built first, and `apply` re-runs alone when
  /// the title changes.
  func withTabTitle<Modified: View>(
    _ content: TabContent, @ViewBuilder apply: @escaping (Self, String) -> Modified
  ) -> some View {
    TabTitleReader(content: content) { title in apply(self, title) }
  }
}

/// A terminal's title drawn in its parts (`TerminalTitle`): a default title's program in the
/// foreground style around it, which carries the selected and focused emphasis, and its folder
/// faded, in that style's second level. A caller sets both levels with `.foregroundStyle(_:_:)`.
/// The program truncates only when it is alone too wide; the folder gives way first and is cut in
/// the middle, so the end of its path stays. Any other title is one `Text`, as the caller styles it.
///
/// A tab passes `folderFont` to draw the folder a size smaller than the program, on the program's
/// baseline. Without it (the sidebar, the pane title bar) both parts take the caller's one font.
struct TerminalTitleLabel: View {
  let title: TerminalTitle
  var folderFont: Font? = nil

  var body: some View {
    if let folder = title.folder {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(title.name).layoutPriority(1)
        folderText(" " + folder).foregroundStyle(.secondary).truncationMode(.middle)
      }
      // One element for VoiceOver, read as the title in plain text ("zsh ~/dev/workroom").
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title.text)
      .accessibilityAddTraits(.isStaticText)
    } else {
      Text(title.name)
    }
  }

  /// The folder in `folderFont`, else in the inherited font: `.font(nil)` would not inherit it, it
  /// would reset the text to the system default.
  private func folderText(_ text: String) -> Text {
    if let folderFont { return Text(text).font(folderFont) }
    return Text(text)
  }
}
