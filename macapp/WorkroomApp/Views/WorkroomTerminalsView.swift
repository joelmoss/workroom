import SwiftUI

/// The detail pane's terminals for one target (a workroom or a project root): a horizontal
/// tab strip below the title bar plus the active terminal. Observes `TerminalSessions` so
/// adding, closing, and switching tabs all update live.
///
/// This view coordinates the tab strip (`TerminalTabStrip`) and the pane content
/// (`PaneTreeView`), owning the cross-component drag-into-pane wiring: `chipPaneDrag` (the live
/// drop preview the pane tree renders) and `contentFrame` (the pane area's global rect, used to
/// tell "over the strip" reorder from "over a pane" drop-to-split and to localise the cursor).
/// The strip is handed those via a binding plus the `chipLocal`/`chipDropTarget` closures.
struct WorkroomTerminalsView: View {
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  /// When this target is a workroom co-displayed in a split (issue #23 follow-up), the action that
  /// removes it from the split — surfaced as a control on the right edge of the tab strip. nil
  /// (default) for the normal single-target case.
  var onCloseWorkroomPane: (() -> Void)? = nil
  /// Whether this workroom's terminal may hold keyboard focus — `false` for a co-displayed but
  /// non-focused split member, so it doesn't steal first responder (and the workroom selection) on mount.
  var surfaceActive: Bool = true
  @EnvironmentObject var notifications: NotificationCenterStore
  @EnvironmentObject var store: AppStore

  // Drag a tab chip down into a pane to split (issue #3). `chipPaneDrag` is the live drop preview
  // (content-local), shown by `PaneTreeView`; `contentFrame` is the pane area's global rect, used to
  // tell "over the strip" (reorder) from "over a pane" (drop-to-split) and to localise the cursor.
  @State private var chipPaneDrag: PaneDragState?
  @State private var contentFrame: CGRect = .zero

  var body: some View {
    let tabs = sessions.tabs(for: target)
    let active = sessions.activeTab(for: target)
    // The terminal (or empty state) fills the pane; the tab bar rides on safeAreaInset so it only
    // ever takes its natural height — otherwise the tab bar's horizontal ScrollView grabs the
    // vertical slack when there's no terminal below it and balloons.
    Group {
      if let active {
        // Always render through the one pane tree — a solo terminal is just a single-leaf layout.
        // Routing solo and split through the SAME host means a surface has exactly one owner; an
        // earlier split→solo bug came from two `TerminalContainerView`s (the solo branch and the dying
        // split leaf) fighting over the same surface and stranding it in a detached container (#3).
        PaneTreeView(
          layout: contentLayout(active: active), target: target, sessions: sessions,
          externalDrag: chipPaneDrag, surfaceActive: surfaceActive
        )
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: ContentFrameKey.self, value: geo.frame(in: .global))
          }
        )
        .padding(6)
      } else {
        ContentUnavailableView {
          Label("No terminal", systemImage: "terminal")
        } description: {
          Text("Open one with ⌘T.")
        } actions: {
          Button("New Terminal") { sessions.addTab(for: target) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("NewTerminal")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onPreferenceChange(ContentFrameKey.self) { contentFrame = $0 }
    .safeAreaInset(edge: .top, spacing: 0) {
      // Normally no tab bar when there are no terminals: the empty state's "New Terminal" button (and
      // ⌘T) cover adding one, so the strip and its "+" would be redundant. But a *split member* still
      // needs its remove-from-split ✕ — which rides on the strip's right edge — reachable after its
      // last terminal is closed (issue #23 follow-up); otherwise an empty split pane has no way out
      // of the split. So when this is a split member (`onCloseWorkroomPane != nil`) keep the strip
      // even with zero tabs (it collapses to just the "+" and the close ✕).
      if !tabs.isEmpty || onCloseWorkroomPane != nil {
        VStack(spacing: 0) {
          TerminalTabStrip(
            tabs: tabs, activeID: active?.id, target: target, sessions: sessions,
            chipPaneDrag: $chipPaneDrag,
            localize: { chipLocal($0) },
            dropTarget: { chipDropTarget(at: $0) },
            onCloseWorkroomPane: onCloseWorkroomPane
          )
          Divider()
        }
      }
    }
    // Create the first terminal once the pane appears (and for each new target), then reconcile
    // occlusion so the right surfaces render after a target switch (issue #3).
    .task(id: target.id) {
      // Through the store so a pending auto-run (issue #7) suppresses the default first tab and the
      // run command becomes tab #1 instead of being orphaned beside a stray "Terminal 1".
      store.ensureInitialTerminal(for: target)
      sessions.reconcileOcclusion(for: target)
    }
    // Focusing a terminal dismisses its notifications. This view only ever renders the selected
    // target's active terminal, so `active.id` changing *is* a focus change — whether from a chip
    // tap, ⌘1–9, the sidebar switching targets, or a close revealing a neighbour. One hook covers
    // them all; `initial` handles the target's first appearance (e.g. arriving from the empty state
    // with notifications already waiting). Returning to the app with the same tab still focused is
    // handled separately by RootView's didBecomeActive → dismissFocusedTerminalNotifications.
    .onChange(of: active?.id, initial: true) { _, id in
      if let id { notifications.dismiss(tab: id) }
    }
    // Drive the "Close Terminal" menu command's enabled state.
    .focusedSceneValue(\.hasTerminal, !tabs.isEmpty)
    // Drive the Go-menu Previous/Next Terminal Tab items (issue #29) — only meaningful with ≥2 tabs.
    .focusedSceneValue(\.multipleTerminalTabs, tabs.count > 1)
  }

  /// The layout the content area renders: the split when it's visible, else the focused solo tab.
  private func contentLayout(active: TerminalTab) -> TerminalPaneLayout {
    sessions.isSplitVisible(for: target)
      ? (sessions.split(for: target) ?? .leaf(active.id)) : .leaf(active.id)
  }

  /// The content-local point for a chip drag at `global`, or nil when the cursor is outside the pane
  /// area (i.e. still over the strip → a reorder, not a drop-into-pane).
  private func chipLocal(_ global: CGPoint) -> CGPoint? {
    guard contentFrame.contains(global) else { return nil }
    return CGPoint(x: global.x - contentFrame.minX, y: global.y - contentFrame.minY)
  }

  /// Where a chip dropped at `global` lands (pane + edge), using the same pane plan the renderer uses,
  /// or nil if it isn't over a pane.
  private func chipDropTarget(at global: CGPoint) -> (tab: TerminalTab.ID, edge: PaneEdge)? {
    guard let local = chipLocal(global), let active = sessions.activeTab(for: target) else {
      return nil
    }
    let plan = PaneTreeLayout.plan(
      contentLayout(active: active), in: CGRect(origin: .zero, size: contentFrame.size))
    return PaneTreeLayout.dropTarget(at: local, panes: plan.panes)
  }
}

/// The pane area's global frame — lets the strip localise a chip drag and tell "over the strip"
/// (reorder) from "over a pane" (drop-to-split).
private struct ContentFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}
