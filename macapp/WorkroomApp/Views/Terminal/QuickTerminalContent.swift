import Defaults
import DesignSystem
import SwiftUI

/// Everything in the Quick Terminal's window: a workroom's own terminals view (tab strip, pane
/// tree, title bars, footers) over its one target, with the strip where the titlebar would be.
struct QuickTerminalContent: View {
  let sessions: TerminalPanes
  /// Read here so a changed "Opens in" applies to the next tab, not only the next window.
  @Default(.quickTerminalDirectory) private var directory
  /// Injected by `QuickTerminalController`, which hosts this view.
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let _ = directory
    WorkroomTerminalsView(target: QuickTerminalController.target(), sessions: sessions)
      // Clear of the window's rounded corners: the first tab and the panes' bottoms touched them.
      .padding(8)
      // Toasts while it is the front window (#573 D2). `.pointerStyle`: the arrow over a toast,
      // not a terminal's cursor rect beneath it (#466).
      .overlay(alignment: .bottomTrailing) {
        ToastStackAdapter().pointerStyle(.default).padding(Spacing.m)
      }
      .background(tokens.panel)
      // The tab strip takes the titlebar's place; without this the hosting view insets everything
      // below the (hidden) titlebar and leaves an empty strip above the tabs.
      .ignoresSafeArea()
  }
}
