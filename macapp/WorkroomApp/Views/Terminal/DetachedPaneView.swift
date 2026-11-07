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
/// `RootView.accessoryBarContent` does for the title-bar accessory. Whoever builds this view applies
/// `detachedPaneEnvironment` to it (`AppStore.openDetachedPane`), so this view names no store; the
/// pane inside it still reads that environment. The window's host injects the theme
/// (`themeTokensRoot()`), since this view's own body reads it.
///
/// **One structural slot, load-bearing.** `PaneLeafView` must not be wrapped in an `if` here: SwiftUI
/// would swap a `_ConditionalContent` branch and re-parent the libghostty view, blanking the pane —
/// the invariant spelled out in `PaneTreeView`, `WorkroomSplitView` and `TargetTerminalDetail`.
struct DetachedPaneView: View {
  let tabID: TerminalTab.ID
  let content: TabContent
  /// The pane's terminal surface, nil for a content pane (`PaneLeafView.surface`).
  let surface: GhosttySurfaceView?
  let target: TerminalTarget
  let panes: TerminalPanes
  /// Push the pane's live title onto the window, so a terminal that renames itself renames its window
  /// (the pane's own title bar used to carry this).
  let onTitleChange: (String) -> Void
  /// Injected by `DetachedPaneWindows.open`, which hosts this view.
  @Environment(\.themeTokens) private var tokens

  private static let space = "detachedPaneContent"

  var body: some View {
    PaneLeafView(
      tabID: tabID, content: content, surface: surface, target: target, panes: panes,
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
    .background(tokens.panel)
    // `takesOverTitlebar: false` — unlike the main window, this one keeps a normal title bar so the
    // pane has a name and a place to drag from; the themer only paints its background.
    .background(WindowBackgroundThemer(takesOverTitlebar: false))
    // The title is read in a leaf (`TabTitleReader`) so a terminal renaming itself many times a
    // second re-runs this `onChange` alone, not the pane.
    .background(
      TabTitleReader(content: content) { title in
        Color.clear.onChange(of: title, initial: true) { _, new in onTitleChange(new) }
      }
    )
  }
}

extension View {
  /// Every environment object a pane's subtree can reach, injected by hand for a hosting tree that
  /// cannot inherit them (issue #172).
  ///
  /// This exists as ONE modifier because the failure mode is a hard crash, not a blank view:
  /// `@EnvironmentObject` traps when it is missing, and the miss is invisible until the exact view
  /// that wants it renders. It cost a crash when the pane's status bar reached for
  /// `claudeUsageBridge` and `codingAgentUsage`, which are scene-level in `WorkroomApp` and so were absent
  /// here. If a pane ever grows a dependency on `updater`, `whatsNew`, `remoteState`,
  /// `projectStore`, `vcsStatus`, `runCommands` or `lifecycle` (today purely main-window chrome,
  /// and the only seven of the app's fourteen environment objects left out, besides the store),
  /// add it here. The window's `TerminalPanes` are not one: views reach them as `host.terminals`
  /// or a parameter, and observe them per target.
  ///
  /// The store itself is not injected: pane views ask the window through its pane host
  /// (`PaneHost`), and only the main window's chrome takes the store from the environment.
  func detachedPaneEnvironment(store: AppStore, panes: TerminalPanes) -> some View {
    self
      .paneHost(store)
      .environmentObject(store.modals)
      .environmentObject(store.runCommand)
      .environmentObject(store.notifications)
      .environmentObject(panes.codingAgentManager)
      .environmentObject(CodingAgentUsageMonitor.shared)
      .environmentObject(ClaudeUsageBridge.shared)
  }
}
