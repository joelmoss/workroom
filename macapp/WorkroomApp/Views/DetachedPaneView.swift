import AppKit
import SwiftUI

/// The content of a popped-out pane's window (issue #172): the same `PaneLeafView` the pane tree
/// renders, hosted alone.
///
/// It is always focused, never multi-pane, and always surface-active — in its own window there is
/// nothing to be unfocused relative to.
///
/// **Environment is re-injected by hand** because it does not cross the `NSHostingView` the window
/// hosts this in, exactly as `RightInspector` re-injects per inspector section and
/// `RootView.accessoryBarContent` does for the title-bar accessory.
///
/// **One structural slot, load-bearing.** `PaneLeafView` must not be wrapped in an `if` here: SwiftUI
/// would swap a `_ConditionalContent` branch and re-parent the libghostty view, blanking the pane —
/// the invariant spelled out in `PaneTreeView`, `WorkroomSplitView` and `TargetTerminalDetail`.
///
/// `WindowBackgroundThemer` does the window chrome: it is a window-agnostic probe that resolves its
/// host window and applies `.fullSizeContentView`, a transparent title bar, a hidden title and the
/// panel background, re-applying on `.themeDidChange`. Reusing it (rather than hand-rolling the same
/// six AppKit lines a third time, after `QuickTerminalController`) is also what makes the pane's own
/// title bar sit in the window's title-bar row.
struct DetachedPaneView: View {
  let tabID: TerminalTab.ID
  let content: TabContent
  let target: TerminalTarget
  let title: String
  @ObservedObject var sessions: TerminalSessions
  let store: AppStore
  /// Reports the drag on the pane's title bar, in this window's coordinate space, so the window can
  /// follow the cursor and the drop can be hit-tested against the origin window.
  let onDragChanged: (CGPoint) -> Void
  let onDragEnded: () -> Void

  private static let space = "detachedPaneContent"

  var body: some View {
    PaneLeafView(
      tabID: tabID, content: content, target: target, sessions: sessions, title: title,
      focused: true, multiPane: false, surfaceActive: true,
      dimUnfocusedPanes: false, workroomIsSplit: false,
      paneIndex: 1, paneCount: 1, coordinateSpace: Self.space,
      onDragChanged: onDragChanged, onDragEnded: onDragEnded,
      onActivate: {},
      isDetached: true,
      onPopOut: { sessions.dockPane(tabID, for: target) }
    )
    .coordinateSpace(.named(Self.space))
    // Traffic lights sit in the pane title bar's row (the window is full-size-content), so inset the
    // bar's leading edge to clear them — the same reserve `RootView`'s title-bar accessory makes.
    .padding(.leading, WorkroomTitlebar.trafficLightInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ThemeService.shared.tokens.panel)
    .background(WindowBackgroundThemer())
    .environmentObject(store)
    .environmentObject(store.notifications)
    .environmentObject(sessions)
    .environmentObject(sessions.agentManager)
  }
}
