import AppKit
import SwiftUI

/// The content of a popped-out pane's window (issue #172): the pane itself, edge to edge, with no
/// chrome of its own. The app footer belongs only to the main workroom windows.
///
/// A detached pane is alone in a real window, so the window IS its chrome — the native title bar
/// names it and closes it, and the pane's own title bar, rounded card and focus ring would only
/// repeat that at the cost of the space the pane was popped out to get. `chromeless` drops all three;
/// the pane's status bar stays, because nothing in the window chrome says what directory or branch
/// you are looking at.
///
/// **Environment is re-injected by hand** because it does not cross the `NSHostingView` the window
/// hosts this in, exactly as `RightInspector` re-injects per inspector section and
/// `RootView.accessoryBarContent` does for the title-bar accessory.
///
/// **One structural slot, load-bearing.** `PaneLeafView` must not be wrapped in an `if` here: SwiftUI
/// would swap a `_ConditionalContent` branch and re-parent the libghostty view, blanking the pane —
/// the invariant spelled out in `PaneTreeView`, `WorkroomSplitView` and `TargetTerminalDetail`.
struct DetachedPaneView: View {
  let tabID: TerminalTab.ID
  let content: TabContent
  let target: TerminalTarget
  let title: String
  @ObservedObject var sessions: TerminalSessions
  let store: AppStore
  /// Push the pane's live title onto the window, so a terminal that renames itself renames its window
  /// (the pane's own title bar used to carry this).
  let onTitleChange: (String) -> Void

  private static let space = "detachedPaneContent"

  /// The pane's current title, which for a terminal changes as commands run.
  private var liveTitle: String { sessions.tab(tabID, for: target)?.title ?? title }

  var body: some View {
    PaneLeafView(
      tabID: tabID, content: content, target: target, sessions: sessions, title: liveTitle,
      focused: true, multiPane: false, surfaceActive: true,
      dimUnfocusedPanes: false, workroomIsSplit: false,
      paneIndex: 1, paneCount: 1, coordinateSpace: Self.space,
      onDragChanged: { _ in }, onDragEnded: {},
      onActivate: {},
      isDetached: true,
      chromeless: true
    )
    .coordinateSpace(.named(Self.space))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ThemeService.shared.tokens.panel)
    // `takesOverTitlebar: false` — unlike the main window, this one keeps a normal title bar so the
    // pane has a name and a place to drag from; the themer only paints its background.
    .background(WindowBackgroundThemer(takesOverTitlebar: false))
    .onChange(of: liveTitle, initial: true) { _, new in onTitleChange(new) }
    .detachedPaneEnvironment(store: store, sessions: sessions)
  }
}

extension View {
  /// Every environment object a pane's subtree can reach, injected by hand for a hosting tree that
  /// cannot inherit them (issue #172).
  ///
  /// This exists as ONE modifier because the failure mode is a hard crash, not a blank view:
  /// `@EnvironmentObject` traps when it is missing, and the miss is invisible until the exact view
  /// that wants it renders. It cost a crash when the pane's status bar reached for
  /// `claudeUsageBridge` and `agentUsage`, which are scene-level in `WorkroomApp` and so were absent
  /// here. If a pane ever grows a dependency on `updater` or `whatsNew` (today purely `RootView`
  /// chrome, and the only two of the app's eight environment objects left out), add it here.
  func detachedPaneEnvironment(store: AppStore, sessions: TerminalSessions) -> some View {
    self
      .environmentObject(store)
      .environmentObject(store.notifications)
      .environmentObject(sessions)
      .environmentObject(sessions.agentManager)
      .environmentObject(AgentUsageMonitor.shared)
      .environmentObject(ClaudeUsageBridge.shared)
  }
}
