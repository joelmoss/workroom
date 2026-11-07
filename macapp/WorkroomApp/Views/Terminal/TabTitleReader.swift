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
