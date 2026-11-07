import AppKit
import Defaults
import SwiftUI
import WorkroomDomain

/// Renders a target's pane layout (issue #3): a solo terminal is a single-leaf layout, a split is a
/// tree. Every visible pane is laid out in ONE flat `ZStack`, positioned by an absolutely-computed
/// frame and keyed by tab id — a surviving pane keeps the exact same host across layout changes (only
/// its frame moves), so its surface is never re-parented (the close-a-split-pane blank bug). Frame and
/// drop-target math are pure and unit-tested in `WorkroomDomain`'s `PaneTreeLayout` (plan D5).
///
/// Drag-and-drop (Phase 2): a split pane is dragged by its own title bar (`PaneTitleBar`, issue #150 —
/// it replaced a hover-only grip chip); dragging shows 4 edge drop zones on the pane under the cursor
/// and, on drop, moves/rearranges via `moveTabIntoSplit` (or pops the pane out to solo via
/// `extractFromSplit` if dragged up to the strip).
struct PaneTreeView: View {
  let layout: TerminalPaneLayout
  let target: TerminalTarget
  let sessions: TerminalPanes
  /// A drag originating outside the tree (a strip tab chip dragged into the content), in content-local
  /// coords — rendered with the same edge preview + ghost as an in-tree pane-handle drag.
  var externalDrag: PaneDragState?
  /// Whether this whole terminal tree may hold keyboard focus. `true` normally; the workroom split
  /// (issue #23 follow-up) passes `false` for a co-displayed but non-focused workroom, so its terminal
  /// renders without grabbing first responder on mount — otherwise each co-displayed workroom's surface
  /// would steal focus (and retarget the workroom selection) as the split mounts.
  var surfaceActive: Bool = true
  /// Whether this tree's *workroom* is one member of a multi-workroom split (`WorkroomPaneLeaf.multi`
  /// in `WorkroomSplitView`) — distinct from `multiPane` below, which is this tree's OWN split (≥2
  /// terminal panes within the one workroom). A solo terminal in a workroom that is itself split still
  /// wants the focused ring, since it's the thing being picked out among the OTHER workrooms on screen.
  var workroomIsSplit: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// "Dim unfocused panes" (issue #162) — read here, at the tree, and passed to every leaf.
  @Default(.dimUnfocusedPanes) private var dimUnfocusedPanes
  @State private var drag: PaneDragState?
  /// The divider ratio being dragged right now, held here rather than written to the sessions on
  /// every mouse-moved tick: a write changes the target's panes, which re-runs every view of the
  /// workroom (its strip, each pane's title and status bar) and marks the saved layout dirty, at
  /// cursor rate. The release commits it once. The workroom divider's pattern
  /// (`WorkroomSplitView.liveRatio`, issue #139), including `stored`: the split's ratio in the
  /// sessions when the drag began, so a re-even that lands mid-drag (issue #126) drops the override.
  /// Once committed it clears, and the sessions' own value takes over.
  @State private var liveRatio: DividerDrag?
  private static let space = "paneContent"

  /// Whichever drag is active: an in-tree pane-handle drag, or an incoming chip drag.
  private var activeDrag: PaneDragState? { drag ?? externalDrag }

  /// Whether a pane should show the dim scrim. `multiPane || !surfaceActive`: dim split-mates AND
  /// every pane of a *backgrounded* workroom — `surfaceActive` is `false` only for a co-displayed,
  /// non-focused workroom split member (`WorkroomSplitView`), so "no first responder == backgrounded
  /// == dim" is a *deliberate* coupling here; split this into its own flag if a future caller ever
  /// disables focus for some other reason. `!focused` never dims the active pane. Gating on
  /// `surfaceActive` (not merely `!focused`) keeps a solo *focused* workroom undimmed even if its
  /// `focusedID` is momentarily nil. `!flashing`: an activity pulse briefly lifts the dim so a
  /// backgrounded pane's pulse is visible. `enabled` is the user's `dimUnfocusedPanes` setting
  /// (issue #162) — off ⇒ no pane ever dims; non-defaulted so the call site must thread it and the
  /// setting can't silently no-op. Pure + unit-tested (issue #82) like the layout math.
  static func shouldDim(
    multiPane: Bool, surfaceActive: Bool, focused: Bool, flashing: Bool, enabled: Bool
  ) -> Bool {
    enabled && (multiPane || !surfaceActive) && !focused && !flashing
  }

  /// Whether a pane's *chrome* — its terminal tab strip (`WorkroomTerminalsView`) and its header
  /// toolbar (`WorkroomPaneTitleBar`) — recedes to 0.45. Those two fades are deliberately in lockstep
  /// with the scrim above ("the header, the strip, and the per-pane scrim all fade as one"), so the
  /// `dimUnfocusedPanes` setting has to reach all three: gating only the scrim left half-faded chrome
  /// floating over a full-brightness terminal, which is the very defect those fades were added to fix
  /// (issue #162 review). `active` is whichever focus signal that site already used — `surfaceActive`
  /// for the strip (the whole workroom is backgrounded), `focused` for the header. Pure + unit-tested.
  static func shouldRecede(active: Bool, enabled: Bool) -> Bool { enabled && !active }

  /// Whether a focus change should CROSS-FADE (the ring's tint, the dim scrim) or land instantly.
  ///
  /// The fades exist for a focus MOVE — click another pane and the accent slides across rather than
  /// popping (issue #162). Closing a pane also hands focus to a survivor, but there the tree has
  /// changed SHAPE: the survivor is re-laid-out in the same update, so fading its chrome through
  /// that reads as the border chasing a terminal that has already snapped to its new size. The
  /// libghostty surface is an `NSView` and never animates, so any chrome that does is on its own.
  ///
  /// `lastPaneCount` is the count this pane last rendered with, so a mismatch means *this* update is
  /// the structural one — `onChange` records the new value only after the body has run. nil is the
  /// first render, which has no transition to make either way.
  static func fadesFocusChange(paneCount: Int, lastPaneCount: Int?, reduceMotion: Bool) -> Bool {
    guard !reduceMotion else { return false }
    guard let lastPaneCount else { return true }
    return lastPaneCount == paneCount
  }

  var body: some View {
    let focusedID = sessions.focusedTab(for: target)?.id
    let multiPane = layout.tabIDs.count >= 2
    // The given layout, with the in-flight divider ratio overlaid while a drag is live.
    let shown = layout.showing(liveRatio)
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(shown, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(Array(layout.tabIDs.enumerated()), id: \.element) { index, tabID in
          if let tab = sessions.tab(tabID, for: target), let rect = plan.panes[tabID] {
            PaneLeafView(
              tabID: tabID, content: tab.content, surface: sessions.surface(of: tabID),
              target: target, sessions: sessions,
              focused: surfaceActive && tabID == focusedID, multiPane: multiPane,
              surfaceActive: surfaceActive, dimUnfocusedPanes: dimUnfocusedPanes,
              workroomIsSplit: workroomIsSplit,
              paneIndex: index + 1, paneCount: layout.tabIDs.count, coordinateSpace: Self.space,
              onDragChanged: {
                beginOrUpdateDrag(
                  tabID: tabID, at: $0, plan: plan, contentFrame: geo.frame(in: .global))
              },
              onDragEnded: { commitDrag(plan: plan, contentFrame: geo.frame(in: .global)) },
              onActivate: { sessions.select(tabID, for: target) }
            )
            // Take the new rect as ONE unit. Every `.animation(_:value: focused)` inside the pane
            // — the scrim, the focus ring — animates *all* animatable changes in its subtree when
            // that value flips, geometry included. Closing one of two panes flips the survivor to
            // focused and resizes it in the same update, so the ring interpolated its way across the
            // window while the libghostty surface (an `NSView`, no SwiftUI animation) snapped: a
            // border sliding over a terminal that had already moved. `geometryGroup` resolves this
            // subtree's geometry before its children animate, which leaves the colour fades intact
            // and makes the frame change instant — the same thing `commitDrag` is careful about,
            // since animating pane frames also floods the surface with resize calls.
            .geometryGroup()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .id(tabID)
          }
        }
        ForEach(plan.dividers) { d in
          // The in-flight ratio is parked in `liveRatio`; only the release reaches the sessions.
          SplitDivider(
            orientation: d.orientation, ratio: d.ratio, total: d.total, noun: "pane",
            identifier: "pane.divider",
            onLive: {
              liveRatio = DividerDrag(split: d.id, ratio: $0, over: layout, fallback: d.ratio)
            },
            onCommit: {
              liveRatio = nil
              sessions.setRatio($0, forSplit: d.id, for: target)
            }
          )
          .frame(width: d.hitRect.width, height: d.hitRect.height)
          .position(x: d.rect.midX, y: d.rect.midY)
        }
        dropHighlight(plan: plan)
        dragGhost()
      }
      .coordinateSpace(.named(Self.space))
      // Hand the measured pane rects to the store so `fits` can apply the pane floor to a CONTENT
      // pane, which owns no surface to measure. A preference (rather than a write from inside this
      // GeometryReader) keeps the write out of body evaluation.
      .preference(key: PaneRectsKey.self, value: plan.panes)
      // …and the container those rects tile, which is the group-level measurement auto-even needs
      // (issue #126): whether the whole group can hold another pane, and whether evening would
      // actually render evenly here. Same feed, same after-layout write.
      .preference(key: PaneSpaceKey.self, value: CGRect(origin: .zero, size: geo.size))
    }
    .onPreferenceChange(PaneRectsKey.self) { [target, sessions] rects in
      // `paneRects` is a plain (non-`@Published`) cache, so this cannot publish into a view update.
      MainActor.assumeIsolated { sessions.paneRects[target.id] = rects }
    }
    .onPreferenceChange(PaneSpaceKey.self) { [target, sessions] space in
      MainActor.assumeIsolated { sessions.paneSpace[target.id] = space }
    }
  }

  /// The accent band previewing where a dragged pane will land.
  @ViewBuilder
  private func dropHighlight(plan: PaneTreeLayout.Plan<TerminalTab.ID>) -> some View {
    if let drag = activeDrag,
      let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.tabID
        || (externalDrag != nil
          && sessions.tabStripSplitDestination(
            moving: drag.tabID, over: hit.tab, for: target) != nil),
      let rect = plan.panes[hit.tab]
    {
      DropAccent(cornerRadius: 8).placed(in: PaneTreeLayout.edgeBand(hit.edge, in: rect))
    }
  }

  /// A floating preview of the pane being dragged (its title + grip), tracking the cursor with a
  /// shadow — so it's clear what's being moved and to where.
  @ViewBuilder
  private func dragGhost() -> some View {
    if let drag = activeDrag, let tab = sessions.tab(drag.tabID, for: target) {
      DragTitleGhost(title: tab.title, at: drag.location)
    }
  }

  /// Track a pane-handle drag. The first point (drag begin) fades the drop preview in; subsequent
  /// points update instantly so the highlight tracks the cursor with no lag. The end is left
  /// un-animated so the result snaps into place — and crucially never animates pane *frames* (which
  /// would flood the surface with resize calls).
  private func beginOrUpdateDrag(
    tabID: TerminalTab.ID, at location: CGPoint,
    plan: PaneTreeLayout.Plan<TerminalTab.ID>, contentFrame: CGRect
  ) {
    if drag == nil {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
        drag = PaneDragState(tabID: tabID, location: location)
      }
    } else {
      drag = PaneDragState(tabID: tabID, location: location)
    }
    updateDetachPreview(tabID: tabID, at: location, plan: plan, contentFrame: contentFrame)
  }

  /// Show the tear-off ghost once the drag would detach, and take it away again if the cursor comes
  /// back inside. Without it the drag has NO feedback at all past the window edge: the in-tree
  /// `dragGhost` is a SwiftUI overlay, so it stops existing exactly where the new gesture begins.
  private func updateDetachPreview(
    tabID: TerminalTab.ID, at location: CGPoint,
    plan: PaneTreeLayout.Plan<TerminalTab.ID>, contentFrame: CGRect
  ) {
    let outcome = PaneTreeLayout.dragOutcome(
      cursor: location, windowBounds: Self.windowBounds(contentFrame: contentFrame),
      panes: plan.panes, dragging: tabID)
    guard outcome == .detach, let tab = sessions.tab(tabID, for: target) else {
      return sessions.hideDragOutside()
    }
    sessions.showDragOutside(tab)
  }

  private func commitDrag(
    plan: PaneTreeLayout.Plan<TerminalTab.ID>, contentFrame: CGRect
  ) {
    defer {
      drag = nil
      // Unconditional: the ghost may never have been shown, and hiding is idempotent.
      sessions.hideDragOutside()
    }
    guard let drag else { return }
    switch PaneTreeLayout.dragOutcome(
      cursor: drag.location, windowBounds: Self.windowBounds(contentFrame: contentFrame),
      panes: plan.panes, dragging: drag.tabID)
    {
    case .move(let tab, let edge):
      sessions.moveTabIntoSplit(drag.tabID, ontoEdge: edge, of: tab, for: target)
    case .extract:
      // Dragged up out of the panes (toward the strip) but still inside the window → pop this pane
      // out of the split to solo.
      sessions.extractFromSplit(drag.tabID, for: target)
    case .detach:
      // Dragged clear of the window → its own window, at the cursor (issue #172), or for a Quick
      // Terminal pane, the workroom it was let go over.
      sessions.dropOutside(drag.tabID, for: target)
    case .none:
      break
    }
  }

  /// The host window's bounds expressed in the pane tree's own content space, which is what
  /// `dragOutcome`'s extract fence is measured against.
  ///
  /// `contentFrame` is `.global`, i.e. the window's coordinate space with its origin at the top-left
  /// of the window INCLUDING the title bar — the same reading `RootView.workroomChipLocal` already
  /// relies on when it compares a global `y` against `WorkroomTitlebar.height`. Subtracting that
  /// origin therefore puts the whole window into content coordinates, with negative `y` covering the
  /// strip and title bar above the panes. The window is resolved through `NSApp.keyWindow` because a
  /// mouse drag belongs to the window it started in, which AppKit keeps key for the gesture's
  /// lifetime; with no key window the fence opens (no window, nothing to be outside of).
  private static func windowBounds(contentFrame: CGRect) -> CGRect {
    guard let size = NSApp.keyWindow?.frame.size else { return .infinite }
    return CGRect(origin: .zero, size: size)
      .offsetBy(dx: -contentFrame.minX, dy: -contentFrame.minY)
  }
}

/// The pane rects the renderer laid out, carried to `TerminalPanes.paneRects`. Reduce keeps the
/// last non-empty value: sibling subtrees contribute nothing, so an empty map must not clobber a
/// real measurement (same shape as `ContentFrameKey`'s non-zero rule).
private struct PaneRectsKey: PreferenceKey {
  static let defaultValue: [TerminalTab.ID: CGRect] = [:]
  static func reduce(
    value: inout [TerminalTab.ID: CGRect], nextValue: () -> [TerminalTab.ID: CGRect]
  ) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

/// The rect the split was laid out in, carried to `TerminalPanes.paneSpace`. Keeps the last
/// non-empty value for the same reason `PaneRectsKey` does — an empty sibling contribution must not
/// erase a real measurement.
private struct PaneSpaceKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

/// A pane drag in progress: which tab, and the cursor in the content coordinate space.
struct PaneDragState {
  let tabID: TerminalTab.ID
  var location: CGPoint
}

// MARK: - Leaf

/// One terminal pane: hosts its title bar (issue #150), the surface, the focus ring and the activity
/// flash (D3). In a split the title bar is also the pane's drag handle — it replaced a hover-only grip
/// chip, so the affordance is always visible. (Closing is via the strip ✕ / ⌘W, or that same bar.)
/// Internal rather than file-private since issue #172: `DetachedPaneView` hosts this exact view in a
/// popped-out window, so a detached pane is the same pane — same chrome, same title bar, same status
/// bar — rather than a second rendering of one.
struct PaneLeafView: View {
  let tabID: TerminalTab.ID
  /// The pane's content — a terminal surface or non-terminal content (issue #66). All the pane chrome
  /// (focus ring, dim scrim, drag handle, a11y) wraps *both* kinds; only the centre swaps.
  let content: TabContent
  /// A terminal pane's surface, read from the sessions by whoever builds this leaf, beside
  /// `content`; nil for a content pane. Passed in rather than looked up here, so a last update
  /// pass after the tab has moved to another window (#444) still holds the surface it rendered,
  /// and `mayHostSurface` is what keeps that pass from taking it back.
  let surface: GhosttySurfaceView?
  /// The target this pane belongs to — its `path` is the workroom directory handed to a diff pane (so
  /// its `DiffResolver` runs against the right repo), and it routes the diff pane's context-menu actions.
  let target: TerminalTarget
  let sessions: TerminalPanes
  /// Routes the diff pane's reused tab context menu (issue #72: "Open File in…", split, close group).
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var modals: ModalState
  /// The inline terminal agent (issue #49); its per-tab state drives the auto-diagnose opt-in dialog.
  @EnvironmentObject var codingAgentManager: TerminalCodingAgentManager
  let focused: Bool
  let multiPane: Bool
  /// Whether this pane's workroom may hold keyboard focus — `false` for a co-displayed, non-focused
  /// workroom split member (the only `surfaceActive: false` caller). Drives the dim scrim alongside
  /// `multiPane` (see `PaneTreeView.shouldDim`). Non-defaulted on purpose: the compiler then forces
  /// the call site to thread it through, so the dim can't silently no-op (issue #82).
  let surfaceActive: Bool
  /// The user's "Dim unfocused panes" setting (issue #162), read once per tree and threaded down the
  /// way `multiPane` / `surfaceActive` are — one `Defaults` observer per tree rather than per pane.
  let dimUnfocusedPanes: Bool
  /// Whether this pane's workroom is itself one member of a multi-workroom split — see
  /// `PaneTreeView.workroomIsSplit`. Drives `borderColor` alongside `multiPane`.
  let workroomIsSplit: Bool
  let paneIndex: Int
  let paneCount: Int
  let coordinateSpace: String
  let onDragChanged: (CGPoint) -> Void
  let onDragEnded: () -> Void
  /// Focus this pane (mirrors a click into a terminal pane's body). Wired only for non-terminal
  /// content — a terminal surface focuses itself via first responder; a diff pane is pure SwiftUI
  /// with no responder hook, so without this a click in its body never focuses it (only the strip
  /// chip would).
  let onActivate: () -> Void
  /// Whether this leaf is being rendered in its own window (issue #172) — only `DetachedPaneView`
  /// passes true; the pane tree never renders a detached tab.
  var isDetached: Bool = false
  /// Drop the pane's own chrome: its title bar, its rounded card and its focus ring.
  ///
  /// A detached pane is alone in a real window, so all three are redundant or wrong — the window's
  /// own title bar names it, there is no sibling to be focused relative to, and a rounded card inset
  /// from the window edge just wastes the space the pane was popped out to get. The CONTENT is
  /// untouched: this only removes chrome around it, so the single-structural-slot rule that protects
  /// the libghostty view is not in play.
  var chromeless: Bool = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives `borderColor` — see `WorkroomPaneCardBorder.tint`, which this pane's ring shares.
  @Environment(\.controlActiveState) private var activeState
  /// The global diff view mode, for a pane whose tab has set no override of its own — resolved here
  /// and handed to the title bar, which stays store- and defaults-free (issue #150).
  @Default(.diffViewMode) private var defaultDiffViewMode
  @State private var flashing = false
  /// The pane count this view last rendered with, so `fadesFocusChange` can tell a focus MOVE from
  /// the tree changing shape. Recorded after the body runs, which is what makes the comparison
  /// during a structural update see the previous value.
  @State private var lastPaneCount: Int?
  // A view-rendering test that hosts this without `themeTokensRoot()` gets the key's default, the
  // live tokens, so it needs no injection of its own.
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    // Looked up once per pass, for the title bar, the content's context menu and whether this
    // window still holds the surface: nil once the tab has gone, or moved to another window (#444).
    let tab = sessions.tab(tabID, for: target)
    // The pane's own title bar (issue #150), a SIBLING above the content — never a wrapper around it.
    // `paneContent` therefore keeps the single structural position that `PaneLeafView` has always
    // guaranteed it: an `if` around the content would swap SwiftUI's `_ConditionalContent` branch and
    // re-parent the libghostty surface (the blank/stranded-pane bug, issue #3). The bar is
    // unconditional, so there is no branch on this axis at all.
    //
    // The clip lives HERE rather than inside each `paneContent` branch, so the bar and the content
    // round as one panel — and every chrome overlay below (scrim, focus ring, padding, a11y) wraps
    // both, which is why the bar needs no unfocused fade of its own.
    VStack(spacing: 0) {
      if !chromeless { titleBar(tab) }
      // Non-terminal panes (a diff) have no first responder to claim focus on click, so a click
      // anywhere in the body focuses the pane. Gated on `!isTerminal` ONLY — the content type is
      // stable for a pane's lifetime, so the gesture is never attached/detached mid-interaction
      // (gating on `focused` would flip the modifier's structural branch on every focus, tearing
      // down and rebuilding the DiffViewer — a reload flash + lag). A terminal pane skips this
      // entirely; its surface eats SwiftUI gestures and focuses via first responder.
      // `isBlocked` is checked when a click FIRES rather than folded into `enabled` above, precisely
      // to preserve the invariant that comment describes.
      //
      // Scoped to the CONTENT, never the title bar. The catcher is a `.background` sized to whatever
      // it modifies and its monitor fires on mouse-DOWN without consuming the event, so covering the
      // whole stack made every click on a bar button focus the pane before the button's own action
      // ran. That silently broke `splitTab`'s guarantee that a REFUSED split (pane too small to
      // halve) leaves the selection untouched: the fit guard refused, but the workroom had already
      // been promoted to selected, so later selection-based commands (Run, Close All) retargeted to
      // a pane where nothing visibly happened. The bar does its own activation via `.onTapGesture`,
      // which a button consumes before it fires, so scoping this here loses nothing.
      paneContent(tab)
        .modifier(
          ActivateOnPress(
            enabled: !isTerminal, onActivate: onActivate,
            isBlocked: { modals.activePicker != nil })
        )
    }
    .clipShape(
      RoundedRectangle(
        cornerRadius: chromeless ? 0 : TerminalPanelMetrics.cornerRadius, style: .continuous)
    )
    // Dim every pane that isn't the focused one so the active terminal reads instantly. This fires
    // for split-mates AND for every pane of a co-displayed *backgrounded* workroom — which passes
    // `surfaceActive: false`, so all its panes arrive here `focused == false` (`shouldDim` gates on
    // `multiPane || !surfaceActive`, so a backgrounded *solo* workroom dims too — issue #82). A
    // focused solo terminal never dims. A scrim (not `.opacity`) because the libghostty Metal
    // surface composites its own layer. The scrim is the terminal's own background colour
    // (`.terminalDim`) so it washes the text toward the background — the BG itself barely changes.
    // The scrim is ALWAYS mounted and only its opacity animates (0↔0.3): conditionally inserting it
    // would make a solo workroom's focus transition snap instead of fade. An activity flash lifts
    // the dim so the pulse is visible on a backgrounded pane.
    .overlay {
      RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius)
        .fill(
          tokens.terminalDim.opacity(
            PaneTreeView.shouldDim(
              multiPane: multiPane, surfaceActive: surfaceActive, focused: focused,
              flashing: flashing, enabled: dimUnfocusedPanes) ? 0.3 : 0)
        )
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: flashing)
        .animation(focusFade(0.07), value: focused)
        .animation(focusFade(0.07), value: surfaceActive)
        .animation(focusFade(0.07), value: dimUnfocusedPanes)
    }
    // A rounded border frames every terminal at 1.5pt. `borderColor` only highlights a pane with a
    // peer to be picked out from (same gate as `WorkroomPaneCardBorder.isHighlighted`): either this
    // workroom's own terminal tree is split (`multiPane`), or the workroom itself is one member of a
    // multi-workroom split (`workroomIsSplit`). A truly solo terminal — one pane, unsplit workroom —
    // keeps the plain hairline even though it's always the model-focused pane.
    .overlay {
      RoundedRectangle(cornerRadius: chromeless ? 0 : TerminalPanelMetrics.cornerRadius)
        .strokeBorder(chromeless ? .clear : borderColor, lineWidth: 1.5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: flashing)
        .animation(focusFade(0.08), value: focused)
    }
    // Records the count this render used, so the NEXT update can tell a focus move from a
    // structural one. Deliberately after the body: during the structural update itself the state
    // still holds the previous count, which is exactly the signal `focusFade` reads.
    .onChange(of: paneCount, initial: true) { _, new in lastPaneCount = new }
    // The one-time auto-diagnose opt-in — attached to the pane so it fires wherever the failure
    // surfaces (the diagnosis itself lives in the detail-panel status bar / tab badge, issue #49).
    .confirmationDialog(
      "Auto-diagnose failures from now on?",
      isPresented: Binding(
        get: { codingAgentManager.autoOptInPromptTab == tabID },
        set: { if !$0 { codingAgentManager.respondToAutoOptIn(enable: false) } }),
      titleVisibility: .visible
    ) {
      Button("Auto-diagnose") { codingAgentManager.respondToAutoOptIn(enable: true) }
      Button("Not now", role: .cancel) { codingAgentManager.respondToAutoOptIn(enable: false) }
    } message: {
      Text("Workroom can diagnose failed commands automatically, instead of waiting for a click.")
    }
    // A uniform 1pt pad on EVERY pane (solo or split) — split panes need it as the inter-pane gutter
    // (plus the surrounding panel gutter from WorkroomTerminalsView) so the rounded panes read as
    // separate cards, and a solo pane keeps the same pad so the panel doesn't shift when you switch
    // between a solo tab and a grouped/split one. Surface identity is held by `.id(tabID)` on the
    // host (not this padding), so no surface is re-parented across the change (issue #3).
    .padding(chromeless ? 0 : 1)
    .onChange(of: sessions.activityPulses[tabID]) { _, _ in
      // Flash a backgrounded pane on activity — a split-mate, or any pane of a co-displayed
      // backgrounded workroom (`!surfaceActive`), mirroring the dim gate so the pulse lifts the
      // scrim (issue #82). Never the focused pane — you're looking at it.
      guard multiPane || !surfaceActive, !focused else { return }
      flashing = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { flashing = false }
    }
    // The Metal surface contributes nothing to the a11y tree, so expose the pane itself as one
    // accessibility element: a stable per-pane signal UI tests count to verify how many panes
    // render (issue #3), and a clear VoiceOver target. The focused pane carries the selected trait.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.pane")
    // The title is read in a leaf (`TabTitleReader`): a terminal's changes many times a second,
    // and this body must not re-run for each one.
    .withTabTitle(content) { pane, title in pane.accessibilityLabel(Text(accessibilityLabel(title)))
    }
    // `multiPane || AppEnvironment.current.isFixture`: with one pane there's normally no need to mark it
    // selected, but that left single-pane keyboard focus with NO queryable signal, so a UI test
    // asserting "the terminal has focus" could only ever be vacuous — and focus races here are a
    // recurring bug class (the ⌘F find-bar hatch in TerminalContainerView, DiffPaneFocusUITests, and
    // the dialog-vs-terminal race this trait now covers). Fixture-gated rather than unconditional:
    // a lone pane announcing itself "selected" to VoiceOver would be wrong for real users.
    .accessibilityAddTraits(focused && (multiPane || Self.marksLonePane) ? .isSelected : [])
  }

  /// Whether a lone focused pane is marked selected too: only for a UI-test fixture launch.
  private static var marksLonePane: Bool {
    #if DEBUG
      AppEnvironment.current.isFixture
    #else
      false
    #endif
  }

  /// The pane's centre: a hosted terminal surface, or a diff viewer for a content tab. Clipped to the
  /// same rounded shape the focus border draws (the terminal host already clips itself).
  @ViewBuilder private func paneContent(_ tab: TerminalTab?) -> some View {
    switch content {
    // A terminal leaf's builder always reads its surface with `content`, so the `if` is one slot.
    case .terminal(let s):
      if let surface {
        terminalPanel(s, surface: surface, held: tab != nil)
      }
    case .diff(let descriptor):
      // The diff pane body carries the SAME context menu as its tab chip (issue #72) — the live
      // tab, so "Keep Open" / split-guard reflect its current preview / split state. A diff leaf is
      // always a live tab while it renders, so the `else` is just a safety fallback.
      let diff = DiffViewer(
        descriptor: descriptor, directory: target.path, repositoryLocation: target.remoteLocation,
        viewModeOverride: tab?.diffViewModeOverride,
        isFocused: focused, find: store.contentFind, cannedDiffs: store.services.cannedDiffs
      )
      if let tab {
        contentPanel(
          diff.tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions))
      } else {
        contentPanel(diff)
      }
    case .file(let descriptor):
      // Read-only file viewer (Files inspector section). Same rounded clip + chip context menu as the
      // diff leaf, so "Keep Open"/Close behave identically on a previewed file.
      let file = PlainFileViewer(
        descriptor: descriptor, directory: target.path, repositoryLocation: target.remoteLocation,
        isFocused: focused,
        previewOverride: tab?.markdownPreviewOverride,
        find: store.contentFind
      )
      if let tab {
        contentPanel(
          file.tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions))
      } else {
        contentPanel(file)
      }
    case .changeset(let descriptor):
      // A whole commit's detail (issue #59): metadata + file list + the selected file's diff (which
      // reuses DiffViewer via a `.commit` source). Same rounded clip + chip context menu as the other
      // content leaves, so "Keep Open"/Close/split behave identically.
      let detail = ChangesetDetailView(
        descriptor: descriptor, directory: target.path,
        repositoryLocation: target.remoteLocation, tabID: tabID, target: target,
        isFocused: focused, find: store.contentFind)
      if let tab {
        contentPanel(
          detail.tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions))
      } else {
        contentPanel(detail)
      }
    }
  }

  /// A terminal pane's centre: its surface and its status bar. `held`: whether this window's
  /// sessions still hold the tab.
  private func terminalPanel(_ s: TerminalState, surface: GhosttySurfaceView, held: Bool)
    -> some View
  {
    // The terminal and its status bar (issue #49) stack as one rounded panel: the surface rounds
    // only its top corners, the enclosing clip rounds the bar's bottom, so every pane — including
    // each split member — carries its own bar as part of the pane.
    VStack(spacing: 0) {
      // `activePicker != nil` reports the pane as UNfocused while a New/Open Workroom dialog is up,
      // which makes `applyFocus` resign the surface's first responder so the dialog's search field
      // can hold it (issue: the dialog was not blocking). Deliberately folded into `isFocusedPane`
      // rather than added as a second parameter: the container's existing not-focused branch already
      // does exactly the right resign, guard included, so a `suspendsFocus` flag would have been a
      // byte-for-byte duplicate of it. PaneTreeView's own `focused` still drives the focus ring, the
      // find bar and the a11y trait, so only the AppKit responder follows the dialog.
      TerminalContainerView(
        view: surface, isFocusedPane: focused && modals.activePicker == nil,
        // Only the host whose kind matches the model may hold the surface (issue #172): the pane
        // tree while the tab is docked, the detached window while it is not. And only in the
        // window whose sessions own the tab: one moved to another window (#444) leaves this
        // window's tree a last pass that would otherwise take the surface back. Its own target is
        // the only one that can hold it here: no tab moves between targets inside one window.
        mayHostSurface: sessions.detachedTabIDs.contains(tabID) == isDetached && held
      )
      // Scrollback find bar (⌘F), pinned top-trailing over the focused pane only — search state
      // is per-surface, and only the focused pane can be searched. Nothing until active.
      .overlay(alignment: .topTrailing) {
        if focused {
          TerminalSearchBar(model: surface.searchModel)
        }
      }
      TerminalStatusBar(target: target, tabID: tabID, state: s, surface: surface)
    }
  }

  /// Wrap a non-terminal content pane (diff / file / changeset) with its status bar (issue #49), so
  /// every pane — terminal or not — carries the same bottom chrome. The rounding is applied once by
  /// `body`, around the title bar and this pair together.
  private func contentPanel(_ view: some View) -> some View {
    VStack(spacing: 0) {
      view
      TerminalStatusBar(target: target, tabID: tabID, state: nil)
    }
  }

  private var isTerminal: Bool {
    if case .terminal = content { return true }
    return false
  }

  /// "Terminal <title>" (or just the content tab's title), plus "pane N of M" in a split — so
  /// VoiceOver announces both what the pane is and where it sits in the group.
  private func accessibilityLabel(_ title: String) -> String {
    let base = isTerminal ? "Terminal \(title)" : title
    return multiPane ? "\(base), pane \(paneIndex) of \(paneCount)" : base
  }

  /// This pane's own title bar (issue #150) — its identity and its actions, acting on THIS tab rather
  /// than on whichever tab happens to be active. It also replaced the hover-only grip chip as the
  /// pane's drag handle: a permanently visible affordance instead of one that appeared on hover, and
  /// one XCUITest can actually drive.
  ///
  /// The bar is store-free, so everything it shows is resolved here — this view already observes
  /// `sessions` and holds the store, and doing it once per pane keeps that churn out of the bar.
  private func titleBar(_ tab: TerminalTab?) -> some View {
    // The bar reads the changing title only in its text and accessibility leaves, keeping its
    // adaptive toolbar and action closures out of every spinner frame.
    return PaneTitleBar(
      content: content,
      glyph: content.glyph,
      controls: PaneToolbarPresentation.controls(for: content),
      diffMode: tab?.diffViewModeOverride ?? defaultDiffViewMode,
      markdownPreview: tab?.markdownPreviewOverride ?? true,
      openFileEnabled: !isDeletedDiff,
      focused: focused,
      multiPane: multiPane,
      help: helpText,
      coordinateSpace: coordinateSpace,
      onSetDiffMode: { sessions.setDiffViewMode($0, forTab: tabID, in: target) },
      onSetMarkdownPreview: { sessions.setMarkdownPreview($0, forTab: tabID, in: target) },
      // The pane's OWN target, not `selectedTarget` — see `AppStore.openFilePreview(path:for:)`.
      onOpenFile: {
        if let path = content.filePath { store.openFilePreview(path: path, for: target) }
      },
      onSplitRight: { sessions.splitTab(tabID, on: .right, for: target) },
      onSplitDown: { sessions.splitTab(tabID, on: .bottom, for: target) },
      onClose: { store.requestCloseTerminalTab(tabID, for: target) },
      onActivate: onActivate,
      // Same screen placement a drag-out would produce, minus the drag: put the window under the
      // pointer rather than somewhere arbitrary.
      onPopOut: sessions.allowsDetach
        ? { sessions.detachPane(tabID, for: target, at: NSEvent.mouseLocation) } : nil,
      moveToWorkroom: target.id == QuickTerminalController.targetID
        ? QuickTerminalMoveToWorkroomMenu(
          store: store, tabID: tabID, target: target, style: .toolbar) : nil,
      onDragChanged: onDragChanged,
      onDragEnded: onDragEnded
    )
  }

  /// A diff whose source file was deleted has no working copy to open (review D4).
  private var isDeletedDiff: Bool {
    if case .diff(let descriptor) = content { return descriptor.change == .deleted }
    return false
  }

  /// The bar's tooltip: the full title, plus the file's absolute path where there is one — so a name
  /// the pane was too narrow to show is still readable on hover.
  private func helpText(_ title: String) -> String {
    guard let path = content.filePath else { return title }
    return "\(title)\n\((target.path as NSString).appendingPathComponent(path))"
  }

  /// The animation for a focus-driven fade — nil while the tree is changing shape, so a pane
  /// opening or closing lands instantly instead of animating its chrome into a new rect.
  private func focusFade(_ duration: Double) -> Animation? {
    guard
      PaneTreeView.fadesFocusChange(
        paneCount: paneCount, lastPaneCount: lastPaneCount, reduceMotion: reduceMotion)
    else { return nil }
    return .easeInOut(duration: duration)
  }

  private var borderColor: Color {
    // Shares `WorkroomPaneCardBorder.tint`, so a focused terminal reads the same whether it's a split
    // terminal pane or a split workroom pane: accent on a key window, the neutral `focused` tint when
    // the window isn't key. Highlights only with a peer to be picked out from — this tree split
    // (`multiPane`) or the workroom itself split (`workroomIsSplit`); a truly solo terminal never
    // highlights.
    WorkroomPaneCardBorder.tint(
      highlighted: (multiPane || workroomIsSplit) && (focused || flashing),
      active: activeState != .inactive, tokens: tokens)
  }
}

/// Focus a non-terminal pane on click. `enabled` is gated on content type only (stable for the
/// pane's lifetime) so the conditional never flips and churns the wrapped view's identity.
///
/// A diff/file pane's body is selectable `Text` (`.textSelection(.enabled)` in `DiffViewer`), whose
/// AppKit text interaction swallows the `mouseDown` before SwiftUI's gesture graph sees it — so a
/// SwiftUI tap (even `simultaneousGesture`) never fires on a click that lands on a diff *line*, only
/// on the empty space between/after lines where no text intercepts. That made clicking a diff line in
/// a co-displayed workroom fail to focus its pane (and the owning workroom split member). A
/// window-local `NSEvent` monitor (the same lever the ⌘-key `AppDelegate` monitor uses) sees every
/// left `mouseDown` first and fires `onActivate` when it falls within this pane — returning the event
/// untouched, so the text underneath still selects.
private struct ActivateOnPress: ViewModifier {
  let enabled: Bool
  let onActivate: () -> Void
  /// Consulted when a click fires, NOT folded into `enabled`. A modal dialog's dimmed backdrop owns
  /// clicks that land on it (it dismisses), so this pane must not also focus itself — but `enabled`
  /// drives the structural branch below, and flipping it mid-life would tear down and rebuild the
  /// DiffViewer (see the call site's comment). Checking at fire time costs one bool per click and
  /// keeps the view's identity stable.
  let isBlocked: () -> Bool

  func body(content: Content) -> some View {
    if enabled {
      content.background(
        PaneClickFocusCatcher(onActivate: onActivate, isBlocked: isBlocked))
    } else {
      content
    }
  }
}

/// Hosts a window-local left-`mouseDown` monitor that fires `onActivate` for any click landing within
/// this view's bounds, WITHOUT consuming it (see `ActivateOnPress`). Placed as a `.background`, sized
/// to the pane; `hitTest` returns nil so the view never becomes the event target itself — detection is
/// purely via the monitor, leaving the diff's own text selection and scrolling untouched.
private struct PaneClickFocusCatcher: NSViewRepresentable {
  let onActivate: () -> Void
  let isBlocked: () -> Bool

  func makeNSView(context: Context) -> ClickFocusCatchView {
    ClickFocusCatchView(onActivate: onActivate, isBlocked: isBlocked)
  }

  func updateNSView(_ view: ClickFocusCatchView, context: Context) {
    view.onActivate = onActivate  // keep the closure fresh so a stale target is never focused
    view.isBlocked = isBlocked  // ditto — a stale capture would read yesterday's dialog state
  }

  static func dismantleNSView(_ view: ClickFocusCatchView, coordinator: ()) {
    view.teardownMonitor()
  }

  final class ClickFocusCatchView: NSView {
    var onActivate: () -> Void
    var isBlocked: () -> Bool
    // Main-thread only; `nonisolated(unsafe)` so `deinit` can remove it.
    nonisolated(unsafe) private var monitor: Any?

    init(onActivate: @escaping () -> Void, isBlocked: @escaping () -> Bool) {
      self.onActivate = onActivate
      self.isBlocked = isBlocked
      super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // Never become the event target — the monitor does the detecting, so text selection / scrolling
    // in the pane content layered in front stay untouched.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      teardownMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        // A modal dialog is up: its backdrop owns this click and will dismiss. Bail BEFORE the bounds
        // test — this monitor sees every click regardless of hit-testing, which is the whole point of
        // the catcher (the diff's selectable text swallows mouseDown before SwiftUI sees it) and also
        // why the backdrop covering the pane isn't enough on its own.
        if self.isBlocked() { return event }
        if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
          self.onActivate()
        }
        return event  // pass through so the underlying text still selects
      }
    }

    nonisolated func teardownMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    deinit { teardownMonitor() }
  }
}

// MARK: - Divider

/// A draggable divider that writes a new ratio for one split node, for both splits: the terminal
/// panes' (`PaneTreeView`) and the workroom cards' (`WorkroomSplitView`). Draws **no** separator
/// rule — each pane already has its own rounded border, so a line in the gutter would only double
/// up; it's just an invisible, hit-testable track surfaced by the resize cursor on hover.
struct SplitDivider: View {
  let orientation: SplitOrientation
  let ratio: CGFloat
  let total: CGFloat
  /// What VoiceOver calls the divided things ("pane", "workroom"), and the divider's accessibility
  /// identifier.
  let noun: String
  let identifier: String
  /// The in-flight ratio, per mouse-moved tick, for the caller to park in local state rather than
  /// the store (`DividerDrag`).
  let onLive: (CGFloat) -> Void
  /// The final ratio, once, on mouse-up. A VoiceOver step is already final, so it goes here too.
  let onCommit: (CGFloat) -> Void
  @State private var startRatio: CGFloat?
  /// The translation this drag is measured FROM. Normally zero (the gesture's own origin), but it
  /// re-bases whenever the divider is re-anchored mid-drag — `value.translation` is cumulative for
  /// the whole gesture, so a new anchor needs a new origin or the pointer jumps.
  @State private var baseTranslation: CGSize = .zero
  /// The last ratio this drag emitted, so an incoming `ratio` that differs from it can only have
  /// come from somewhere else (issue #126: an auto-even landing while the mouse is down).
  @State private var lastEmitted: CGFloat?

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            reanchorIfMovedElsewhere(value.translation)
            let next = dragged(from: startRatio ?? ratio, by: rebased(value.translation))
            lastEmitted = next  // what `reanchorIfMovedElsewhere` compares the incoming ratio to
            onLive(next)
          }
          .onEnded { value in
            // Re-anchor here too, not just in `onChanged`. An auto-even can land AFTER the last
            // mouse-moved tick — hold the divider still while a workroom delete lands and
            // `pruneWorkroomSplitToLiveLeaves` evens the group — and a committing divider PERSISTS
            // here. Without it the release replays `stale start + whole-gesture translation` and
            // silently overwrites the even, which is the exact defect the re-anchor exists to
            // prevent. The final translation comes from this closure's own value; there's no need
            // to mirror each tick into a second `@State`.
            reanchorIfMovedElsewhere(value.translation)
            if let start = startRatio {
              onCommit(dragged(from: start, by: rebased(value.translation)))
            }
            startRatio = nil
            lastEmitted = nil
            baseTranslation = .zero
          }
      )
      // SwiftUI's pointer style, not an NSCursor push: the terminal panes beside the divider set
      // their pointer with cursor rects, which override a pushed cursor (#466).
      .pointerStyle(orientation == .horizontal ? .columnResize : .rowResize)
      // Adjustable so VoiceOver users can resize without a drag: ⌃⌥→/← nudge the split by 5%.
      .accessibilityElement()
      .accessibilityIdentifier(identifier)
      .accessibilityLabel(
        orientation == .horizontal ? "Vertical \(noun) divider" : "Horizontal \(noun) divider"
      )
      .accessibilityValue("\(Int((ratio * 100).rounded()))%")
      .accessibilityAdjustableAction { direction in
        let step: CGFloat = 0.05
        switch direction {
        case .increment:
          onCommit(PaneTreeLayout.clampRatio(ratio + step, total: total, along: orientation))
        case .decrement:
          onCommit(PaneTreeLayout.clampRatio(ratio - step, total: total, along: orientation))
        @unknown default: break
        }
      }
  }

  /// The ratio a drag of `translation` from `start` lands on — one formula for both gesture phases, so
  /// the committed value can't drift from the live one it followed.
  private func dragged(from start: CGFloat, by translation: CGSize) -> CGFloat {
    let usable = max(1, total - PaneTreeLayout.dividerThickness)
    let delta = orientation == .horizontal ? translation.width : translation.height
    return PaneTreeLayout.clampRatio(start + delta / usable, total: total, along: orientation)
  }

  /// This gesture's translation measured from its current anchor. `value.translation` is cumulative
  /// for the whole gesture, so a re-anchor mid-drag needs its origin subtracted.
  private func rebased(_ translation: CGSize) -> CGSize {
    CGSize(
      width: translation.width - baseTranslation.width,
      height: translation.height - baseTranslation.height)
  }

  /// Latch the drag's origin, and re-latch it when the divider moved for a reason other than this
  /// drag (issue #126). `equalized()` keeps every split node's `id`, so an auto-even landing while
  /// the mouse is down leaves this view — and its latched start — alive over a tree that has since
  /// changed underneath it. Without re-anchoring, the next tick (and a mouse-up commit) replays
  /// `stale start + whole-gesture translation` and silently undoes the even.
  private func reanchorIfMovedElsewhere(_ translation: CGSize) {
    guard
      PaneTreeLayout.shouldReanchorDrag(
        currentRatio: ratio, lastEmitted: lastEmitted, hasStarted: startRatio != nil)
    else { return }
    startRatio = ratio
    baseTranslation = translation
  }
}

/// What a drag carries across the window: the dragged thing's title and a grip, with a shadow,
/// tracking the cursor. A pane's (`PaneTreeView`) and a workroom's (`WorkroomSplitView`, #444).
struct DragTitleGhost: View {
  let title: String
  /// The cursor, in the space the ghost is drawn in: it floats just above it.
  let at: CGPoint

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold))
      Text(title).font(.caption).lineLimit(1)
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    .fixedSize()
    .position(x: at.x, y: at.y - 14)
    .allowsHitTesting(false)
  }
}
