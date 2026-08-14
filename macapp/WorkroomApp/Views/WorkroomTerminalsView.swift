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
  /// Whether this workroom's terminal may hold keyboard focus — `false` for a co-displayed but
  /// non-focused split member, so it doesn't steal first responder (and the workroom selection) on mount.
  var surfaceActive: Bool = true
  @EnvironmentObject var notifications: NotificationCenterStore
  @EnvironmentObject var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Owned here (one per target) — `TerminalTabStrip` only drives it via `@ObservedObject` (eng review
  /// D4, Codex #7). This is also where `TabChipAnchorKey` is consumed and the overlay rendered, so
  /// ownership and rendering live together.
  @StateObject private var hoverPreview: TerminalHoverPreviewController
  @State private var chipAnchors: [TerminalTab.ID: Anchor<CGRect>] = [:]

  // Drag a tab chip down into a pane to split (issue #3). `chipPaneDrag` is the live drop preview
  // (content-local), shown by `PaneTreeView`; `contentFrame` is the pane area's global rect, used to
  // tell "over the strip" (reorder) from "over a pane" (drop-to-split) and to localise the cursor.
  @State private var chipPaneDrag: PaneDragState?
  @State private var contentFrame: CGRect = .zero

  init(target: TerminalTarget, sessions: TerminalSessions, surfaceActive: Bool = true) {
    self.target = target
    self.sessions = sessions
    self.surfaceActive = surfaceActive
    _hoverPreview = StateObject(wrappedValue: TerminalHoverPreviewController(sessions: sessions))
  }

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
      } else {
        ContentUnavailableView {
          Label("No terminal", systemImage: "terminal")
        } description: {
          Text("Open one with ⌘T.")
        } actions: {
          Button("New Terminal") { sessions.addTab(for: target) }
            .buttonStyle(.borderedProminent)
            // Use the active theme accent rather than the system blue (issue #36).
            .tint(ThemeService.shared.tokens.accent)
            .accessibilityIdentifier("NewTerminal")
        }
      }
    }
    // A thin 2pt frame inside the workroom's card, so the card's lighter fill reads as a border rather
    // than a margin. Top is 0 so the tab strip sits flush on the content (the active tab bridges the
    // panel→bg colour step) — the Chrome-style merge with the strip above. Applied to the whole Group,
    // not just the pane tree, so the "No terminal" empty state is inset by the same gutter.
    .padding(.horizontal, 2)
    .padding(.bottom, 2)
    .padding(.top, 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onPreferenceChange(ContentFrameKey.self) { contentFrame = $0 }
    .safeAreaInset(edge: .top, spacing: 0) {
      // No tab bar when there are no terminals: the empty state's "New Terminal" button (and ⌘T) cover
      // adding one, so the strip and its "+" would be redundant. A split member's remove-from-split ✕
      // now lives in its pane title bar (issue #110), drawn by the leaf above this view and present
      // even with zero tabs — so the strip no longer needs to stay alive just to host the ✕.
      if !tabs.isEmpty {
        TerminalTabStrip(
          tabs: tabs, activeID: active?.id, target: target, sessions: sessions,
          hoverPreview: hoverPreview,
          chipPaneDrag: $chipPaneDrag,
          localize: { chipLocal($0) },
          dropTarget: { chipDropTarget(at: $0) }
        )
        // A backgrounded workroom (`!surfaceActive` — a non-focused workroom *split* member, or a
        // backgrounded solo workroom, issue #82) dims its terminals via the per-pane scrim in
        // `PaneTreeView`. That scrim covers only the Metal surfaces, not this tab strip — it rides on
        // the safe-area inset, outside the pane tree — so without this the strip stayed bright while
        // its panes faded. The strip is plain SwiftUI (no Metal layer), so a plain `.opacity` fade is
        // enough; match the scrim's `surfaceActive` animation so the strip and panes fade together.
        .opacity(surfaceActive ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: surfaceActive)
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
    // Focusing a terminal dismisses its notifications — but ONLY while this view is the focused one
    // (`surfaceActive`). In a workroom split EVERY member renders through this view, including
    // co-displayed NON-focused members (`surfaceActive: false`, issue #23); without the gate, such a
    // member would wipe its OWN notifications on mount/remount via the `initial: true` fire — a pane
    // you're explicitly not looking at (issue #89). With the gate: for the focused member, `active.id`
    // changing *is* a focus change (chip tap, ⌘1–9, sidebar switch, close revealing a neighbour) and
    // `initial` handles its first appearance. The sibling `surfaceActive` hook covers selection
    // MOVING to a member — `selectedTargetID` changes but the member's `active.id` does not, so the
    // hook above wouldn't fire. In the single-workroom path `surfaceActive` is always true, so this
    // behaves exactly as before. Returning to the app with the same tab focused is handled separately
    // by RootView's didBecomeActive → dismissFocusedTerminalNotifications.
    .onChange(of: active?.id, initial: true) { _, id in
      if surfaceActive, let id { notifications.dismiss(tab: id) }
    }
    .onChange(of: surfaceActive) { _, nowFocused in
      if nowFocused, let id = active?.id { notifications.dismiss(tab: id) }
    }
    // All three AND in `!store.hasModalPresentation` for the same reason RootView's booleans do: a
    // menu key equivalent still fires while a dialog or sheet is up, so ⌘W / ⌘F / ⌘↑ / ⌘↓ / ⌘D would
    // otherwise act on the terminal behind it. Disabling the item drops the key equivalent.
    //
    // Drive the "Close Terminal" menu command's enabled state.
    .focusedSceneValue(\.hasTerminal, !tabs.isEmpty && !store.hasModalPresentation)
    // Drive the Go-menu Previous/Next Terminal Tab items (issue #29) — only meaningful with ≥2 tabs.
    .focusedSceneValue(\.multipleTerminalTabs, tabs.count > 1 && !store.hasModalPresentation)
    // Drive View ▸ "Resize Splits Evenly" (issue #83) — only when a terminal split is on screen. Note
    // that in a workroom split EVERY member mounts this view, so all three of these are written by
    // several instances at once and the last writer wins; the menu items they drive are all
    // "is such a thing on screen at all", for which any visible member is an acceptable answer. A
    // blocking setup script withholds this view, so no item can act on a hidden split.
    .focusedSceneValue(
      \.terminalSplitVisible,
      sessions.isSplitVisible(for: target) && !store.hasModalPresentation
    )
    // Positioned from the hovered chip's own anchor (`TabChipAnchorKey`, set by `TerminalTabStrip`),
    // resolved here rather than inside the strip — the strip sits in a `safeAreaInset` and may clip an
    // overlay bleeding below it.
    .overlayPreferenceValue(TabChipAnchorKey.self) { anchors in
      GeometryReader { geo in
        if case .visible(let tabID) = hoverPreview.phase,
          let host = hoverPreview.previewHost,
          let anchor = anchors[tabID]
        {
          let chipFrame = geo[anchor]
          TerminalHoverPreviewOverlay(
            host: host, title: sessions.tab(tabID, for: target)?.title ?? ""
          )
          .position(
            x: chipFrame.midX,
            y: chipFrame.maxY + TerminalHoverPreviewOverlay.estimatedTotalHeight / 2 + 6)
        }
      }
    }
    // "Hover ends" alone isn't a reliable teardown signal (Codex #8) — this view disappearing (target
    // switch, split collapse, window close tearing down the hierarchy) must force it too.
    .onDisappear { hoverPreview.forceTeardown() }
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
