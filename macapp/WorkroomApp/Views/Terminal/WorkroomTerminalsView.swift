import Defaults
import SwiftUI
import WorkroomDomain

/// The detail pane's terminals for one target (a workroom or a project root): a horizontal
/// tab strip below the title bar plus the active terminal. Reads its target's panes through
/// Observation, so adding, closing, and switching tabs all update live, and another workroom's
/// pane changes re-run none of it.
///
/// This view coordinates the tab strip (`TerminalTabStrip`) and the pane content
/// (`PaneTreeView`) for a tab dragged into the panes to split them: the target's `TabContentDrop`
/// holds the live preview the pane tree renders and the pane area's frame, which this view
/// measures. The strip and the sidebar's Open rows (#819) both drive it.
struct WorkroomTerminalsView: View {
  let target: TerminalTarget
  let panes: TerminalPanes
  /// Whether this workroom's terminal may hold keyboard focus — `false` for a co-displayed but
  /// non-focused split member, so it doesn't steal first responder (and the workroom selection) on mount.
  var surfaceActive: Bool = true
  /// Whether this workroom is itself one member of a multi-workroom split — forwarded to
  /// `PaneTreeView` so a solo terminal within it still gets the focused border (see
  /// `PaneTreeView.workroomIsSplit`).
  var workroomIsSplit: Bool = false
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.paneHost) private var host
  @EnvironmentObject var modals: ModalState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens
  /// "Dim unfocused panes" (issue #162) — the strip's fade is in lockstep with the pane scrim, so the
  /// setting gates it too (see `PaneTreeView.shouldRecede`).
  @Default(.dimUnfocusedPanes) private var dimUnfocusedPanes

  var body: some View {
    // Drag a tab chip, or its Open row (#819), down into a pane to split (issue #3): the target's
    // `TabContentDrop` holds the live preview `PaneTreeView` draws and the pane area's frame.
    let drop = panes.contentDrop(for: target.id)
    let tabs = panes.tabs(for: target)
    let active = panes.activeTab(for: target)
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
          layout: panes.split(for: target) ?? .leaf(active.id), target: target, panes: panes,
          externalDrag: drop.preview, surfaceActive: surfaceActive,
          workroomIsSplit: workroomIsSplit
        )
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: ContentFrameKey.self, value: geo.frame(in: .global))
          }
        )
      } else if host.waitingForHostLayout.contains(target.id) {
        // A remote workroom asking its host for its layout (#255, D4): its tabs come from there,
        // within seconds, so nothing is offered meanwhile.
        ContentUnavailableView {
          Label("Waiting for the host", systemImage: "network")
        } description: {
          Text("Restoring this workroom's tabs from its host.")
        } actions: {
          ProgressView().controlSize(.small)
        }
        .accessibilityIdentifier("WaitingForHostLayout")
      } else {
        ContentUnavailableView {
          Label("No terminal", systemImage: "terminal")
        } description: {
          Text(
            Shortcuts.shared.table.label(for: .newTerminal).map { "Open one with \($0)." }
              ?? "Open one with New Terminal.")
        } actions: {
          Button("New Terminal") { host.newTerminal(in: target) }
            .buttonStyle(.borderedProminent)
            // Use the active theme accent rather than the system blue (issue #36).
            .tint(tokens.accent)
            .accessibilityIdentifier("NewTerminal")
        }
      }
    }
    // A thin 1pt frame inside the workroom's card, so the card's lighter fill reads as a border rather
    // than a margin. Top is 0 so the tab strip sits flush on the content (the active tab bridges the
    // panel→bg colour step) — the Chrome-style merge with the strip above. Applied to the whole Group,
    // not just the pane tree, so the "No terminal" empty state is inset by the same gutter.
    .padding(.horizontal, 1)
    .padding(.bottom, 1)
    .padding(.top, 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onPreferenceChange(ContentFrameKey.self) { [drop] frame in
      MainActor.assumeIsolated { drop.frame = frame == .zero ? nil : frame }
    }
    .onDisappear { drop.frame = nil }
    .onChange(of: target.id) { old, _ in panes.contentDrop(for: old).frame = nil }
    .safeAreaInset(edge: .top, spacing: 0) {
      // No tab bar when there are no terminals: the empty state's "New Terminal" button (and ⌘T) cover
      // adding one, so the strip and its "+" would be redundant. A split member's remove-from-split ✕
      // now lives in its pane title bar (issue #110), drawn by the leaf above this view and present
      // even with zero tabs — so the strip no longer needs to stay alive just to host the ✕.
      // A standalone terminal's one terminal shows none (`showsTabStrip`).
      if TerminalPanes.showsTabStrip(tabCount: tabs.count, for: target.id) {
        TerminalTabStrip(
          tabs: tabs, activeID: active?.id, target: target, panes: panes,
          chipPaneDrag: Binding(get: { drop.preview }, set: { drop.preview = $0 }),
          localize: { drop.localize($0) },
          dropTarget: { panes.contentDropTarget(at: $0, for: target) }
        )
        // A backgrounded workroom (`!surfaceActive` — a non-focused workroom *split* member, or a
        // backgrounded solo workroom, issue #82) dims its terminals via the per-pane scrim in
        // `PaneTreeView`. That scrim covers only the Metal surfaces, not this tab strip — it rides on
        // the safe-area inset, outside the pane tree — so without this the strip stayed bright while
        // its panes faded. The strip is plain SwiftUI (no Metal layer), so a plain `.opacity` fade is
        // enough; match the scrim's `surfaceActive` animation so the strip and panes fade together.
        .opacity(
          PaneTreeView.shouldRecede(active: surfaceActive, enabled: dimUnfocusedPanes) ? 0.45 : 1
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: surfaceActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: dimUnfocusedPanes)
      }
    }
    // Create the first terminal once the pane appears (and for each new target), then reconcile
    // occlusion so the right surfaces render after a target switch (issue #3).
    .task(id: target.id) {
      // Through the host so a pending auto-run (issue #7) suppresses the default first tab and the
      // run command becomes tab #1 instead of being orphaned beside a stray "Terminal 1".
      host.ensureInitialTerminal(for: target)
      panes.reconcileOcclusion(for: target)
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
    // All three AND in `!modals.hasModalPresentation` for the same reason RootView's booleans do: a
    // menu key equivalent still fires while a dialog or sheet is up, so ⌘W / ⌘F / ⌘↑ / ⌘↓ / ⌘D would
    // otherwise act on the terminal behind it. Disabling the item drops the key equivalent.
    //
    // Drive the "Close Tab" menu command's enabled state.
    .focusedSceneValue(\.hasTerminal, !tabs.isEmpty && !modals.hasModalPresentation)
    // Drive the Go-menu Previous/Next Terminal Tab items (issue #29) — only meaningful with ≥2 tabs.
    .focusedSceneValue(\.multipleTerminalTabs, tabs.count > 1 && !modals.hasModalPresentation)
    // Go ▸ Terminal Tab's items (#148): ids only, see `TerminalTabIDsKey`.
    .focusedSceneValue(
      \.terminalTabIDs, modals.hasModalPresentation ? [] : tabs.prefix(9).map(\.id))
  }
}

/// The pane area's global frame — lets the strip localise a chip drag and tell "over the strip"
/// (reorder) from "over a pane" (drop-to-split).
private struct ContentFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}
