import AppKit
import SwiftUI

/// Renders a target's pane layout (issue #3): a solo terminal is a single-leaf layout, a split is a
/// tree. Every visible pane is laid out in ONE flat `ZStack`, positioned by an absolutely-computed
/// frame and keyed by tab id — a surviving pane keeps the exact same host across layout changes (only
/// its frame moves), so its surface is never re-parented (the close-a-split-pane blank bug). Frame and
/// drop-target math are pure and unit-tested (plan D5).
///
/// Drag-and-drop (Phase 2): each split pane shows a small grip chip at its top-center; dragging it
/// shows 4 edge drop zones on the pane under the cursor and, on drop, moves/rearranges via
/// `moveTabIntoSplit` (or pops the pane out to solo via `extractFromSplit` if dragged up to the strip).
struct PaneTreeView: View {
  let layout: TerminalPaneLayout
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  /// A drag originating outside the tree (a strip tab chip dragged into the content), in content-local
  /// coords — rendered with the same edge preview + ghost as an in-tree pane-handle drag.
  var externalDrag: PaneDragState?
  /// Whether this whole terminal tree may hold keyboard focus. `true` normally; the workroom split
  /// (issue #23 follow-up) passes `false` for a co-displayed but non-focused workroom, so its terminal
  /// renders without grabbing first responder on mount — otherwise each co-displayed workroom's surface
  /// would steal focus (and retarget the workroom selection) as the split mounts.
  var surfaceActive: Bool = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: PaneDragState?
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
  /// backgrounded pane's pulse is visible. Pure + unit-tested (issue #82) like the layout math.
  static func shouldDim(multiPane: Bool, surfaceActive: Bool, focused: Bool, flashing: Bool) -> Bool
  {
    (multiPane || !surfaceActive) && !focused && !flashing
  }

  var body: some View {
    let focusedID = sessions.focusedTab(for: target)?.id
    let multiPane = layout.tabIDs.count >= 2
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(Array(layout.tabIDs.enumerated()), id: \.element) { index, tabID in
          if let tab = sessions.tab(tabID, for: target), let rect = plan.panes[tabID] {
            PaneLeafView(
              tabID: tabID, content: tab.content, target: target, sessions: sessions,
              title: tab.title,
              focused: surfaceActive && tabID == focusedID, multiPane: multiPane,
              surfaceActive: surfaceActive,
              paneIndex: index + 1, paneCount: layout.tabIDs.count, coordinateSpace: Self.space,
              onDragChanged: { beginOrUpdateDrag(tabID: tabID, at: $0) },
              onDragEnded: { commitDrag(plan: plan) },
              onActivate: { sessions.select(tabID, for: target) }
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .id(tabID)
          }
        }
        ForEach(plan.dividers) { d in
          SplitDivider(orientation: d.orientation, ratio: d.ratio, total: d.total) {
            sessions.setRatio($0, forSplit: d.id, for: target)
          }
          .frame(width: d.hitRect.width, height: d.hitRect.height)
          .position(x: d.rect.midX, y: d.rect.midY)
        }
        dropHighlight(plan: plan)
        dragGhost()
      }
      .coordinateSpace(.named(Self.space))
    }
  }

  /// The accent band previewing where a dragged pane will land.
  @ViewBuilder
  private func dropHighlight(plan: PaneTreeLayout.Plan<TerminalTab.ID>) -> some View {
    if let drag = activeDrag,
      let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.tabID, let rect = plan.panes[hit.tab]
    {
      let band = PaneTreeLayout.edgeBand(hit.edge, in: rect)
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.accentColor.opacity(0.25))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
        .frame(width: band.width, height: band.height)
        .position(x: band.midX, y: band.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  /// A floating preview of the pane being dragged (its title + grip), tracking the cursor with a
  /// shadow — so it's clear what's being moved and to where.
  @ViewBuilder
  private func dragGhost() -> some View {
    if let drag = activeDrag, let tab = sessions.tab(drag.tabID, for: target) {
      HStack(spacing: 5) {
        Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold))
        Text(tab.title).font(.caption).lineLimit(1)
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
      .fixedSize()
      .position(x: drag.location.x, y: drag.location.y - 14)  // float just above the cursor
      .allowsHitTesting(false)
    }
  }

  /// Track a pane-handle drag. The first point (drag begin) fades the drop preview in; subsequent
  /// points update instantly so the highlight tracks the cursor with no lag. The end is left
  /// un-animated so the result snaps into place — and crucially never animates pane *frames* (which
  /// would flood the surface with resize calls).
  private func beginOrUpdateDrag(tabID: TerminalTab.ID, at location: CGPoint) {
    if drag == nil {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
        drag = PaneDragState(tabID: tabID, location: location)
      }
    } else {
      drag = PaneDragState(tabID: tabID, location: location)
    }
  }

  private func commitDrag(plan: PaneTreeLayout.Plan<TerminalTab.ID>) {
    defer { drag = nil }
    guard let drag else { return }
    if let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.tabID
    {
      sessions.moveTabIntoSplit(drag.tabID, ontoEdge: hit.edge, of: hit.tab, for: target)
    } else if drag.location.y < 0 {
      // Dragged up out of the panes (toward the strip) → pop this pane out of the split to solo.
      sessions.extractFromSplit(drag.tabID, for: target)
    }
  }
}

/// A pane drag in progress: which tab, and the cursor in the content coordinate space.
struct PaneDragState {
  let tabID: TerminalTab.ID
  var location: CGPoint
}

// MARK: - Pure layout & drop math (extracted for unit tests — plan D5)

struct PaneDividerFrame: Identifiable {
  let id: UUID
  let orientation: SplitOrientation
  /// The 4pt visual gutter rect — where the divider sits and the value `.position` centers on.
  let rect: CGRect
  /// The draggable hit-zone rect (issue #83): `rect` widened along the split axis to
  /// `dividerHitThickness`, centered on `rect`. Wider than the visual gutter so the divider is
  /// easier to grab, but still entirely within the transparent gutter + pane padding so it never
  /// overhangs a live terminal surface (which would steal the terminal's own mouse input).
  let hitRect: CGRect
  let ratio: CGFloat
  let total: CGFloat
}

enum PaneTreeLayout {
  typealias Plan<Leaf: Hashable> = (panes: [Leaf: CGRect], dividers: [PaneDividerFrame])

  static var dividerThickness: CGFloat { TerminalSessions.dividerThickness }
  static var minPane: CGFloat { TerminalSessions.minPaneSize }
  /// Draggable hit-zone thickness for the resize divider (issue #83). The visible gutter stays
  /// `dividerThickness` (4pt); the hit zone is widened to this so the divider is easier to grab. It is
  /// capped at `dividerThickness + 2pt pane padding on each side` (= 8pt) — the widest band that stays
  /// over only the transparent gutter + the panes' 2pt padding (see `PaneLeafView`'s `.padding(2)`), so
  /// it never overhangs a live terminal surface and can't intercept the terminal's own mouse input
  /// (text selection, OSC8 link clicks, right-click menu, TUI mouse reporting).
  static var dividerHitThickness: CGFloat { dividerThickness + 4 }

  /// Lengths of the first/second child along the split axis for a container of `total` points. Rounds
  /// the first child to whole points (avoids sub-pixel seams) and clamps so neither child falls below
  /// `minPane`; when the container is too small to honor that, falls back to an even split.
  static func lengths(total: CGFloat, ratio: CGFloat) -> (first: CGFloat, second: CGFloat) {
    let usable = max(0, total - dividerThickness)
    guard usable > 2 * minPane else {
      let half = (usable / 2).rounded()
      return (half, usable - half)
    }
    let raw = (usable * ratio).rounded()
    let first = min(usable - minPane, max(minPane, raw))
    return (first, usable - first)
  }

  /// Clamp a proposed divider ratio to keep both panes ≥ `minPane` (the single, view-owned clamp).
  static func clampRatio(_ ratio: CGFloat, total: CGFloat) -> CGFloat {
    let usable = max(1, total - dividerThickness)
    guard usable > 2 * minPane else { return 0.5 }
    let minR = minPane / usable
    return min(1 - minR, max(minR, ratio))
  }

  /// Absolute frames for every leaf (by tab id) and every divider, laying `node` out in `rect`.
  static func plan<Leaf: Hashable>(_ node: PaneLayout<Leaf>, in rect: CGRect) -> Plan<Leaf> {
    switch node {
    case .leaf(let id):
      return ([id: rect], [])
    case .split(let sid, let orientation, let ratio, let first, let second):
      let axis = orientation == .horizontal ? rect.width : rect.height
      let (firstLen, secondLen) = lengths(total: axis, ratio: ratio)
      let div = dividerThickness
      let firstRect: CGRect
      let dividerRect: CGRect
      let secondRect: CGRect
      if orientation == .horizontal {
        firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLen, height: rect.height)
        dividerRect = CGRect(x: rect.minX + firstLen, y: rect.minY, width: div, height: rect.height)
        secondRect = CGRect(
          x: rect.minX + firstLen + div, y: rect.minY, width: secondLen, height: rect.height)
      } else {
        firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLen)
        dividerRect = CGRect(x: rect.minX, y: rect.minY + firstLen, width: rect.width, height: div)
        secondRect = CGRect(
          x: rect.minX, y: rect.minY + firstLen + div, width: rect.width, height: secondLen)
      }
      let f = plan(first, in: firstRect)
      let s = plan(second, in: secondRect)
      var panes = f.panes
      panes.merge(s.panes) { a, _ in a }
      // Widen the hit zone along the split axis, centered on the gutter rect (issue #83). The
      // perpendicular dimension is unchanged, so the band runs the full length of the divider.
      let hit = dividerHitThickness
      let hitRect =
        orientation == .horizontal
        ? CGRect(
          x: dividerRect.midX - hit / 2, y: dividerRect.minY, width: hit, height: dividerRect.height
        )
        : CGRect(
          x: dividerRect.minX, y: dividerRect.midY - hit / 2, width: dividerRect.width, height: hit)
      let divider = PaneDividerFrame(
        id: sid, orientation: orientation, rect: dividerRect, hitRect: hitRect, ratio: ratio,
        total: axis)
      return (panes, f.dividers + [divider] + s.dividers)
    }
  }

  /// Which pane + edge a content-local `point` targets. Each pane is tiled into 4 triangles meeting at
  /// its center, so the nearest edge always wins — no dead zone (plan: "edges tile the whole pane").
  static func dropTarget<Leaf: Hashable>(at point: CGPoint, panes: [Leaf: CGRect])
    -> (tab: Leaf, edge: PaneEdge)?
  {
    guard let hit = panes.first(where: { $0.value.contains(point) }) else { return nil }
    return (hit.key, nearestEdge(of: point, in: hit.value))
  }

  /// The edge of `rect` nearest `point`, normalised by the rect's aspect (so a wide pane still splits
  /// top/bottom near its short edges).
  static func nearestEdge(of point: CGPoint, in rect: CGRect) -> PaneEdge {
    let dx = rect.width == 0 ? 0 : (point.x - rect.midX) / rect.width
    let dy = rect.height == 0 ? 0 : (point.y - rect.midY) / rect.height
    if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
    return dy < 0 ? .top : .bottom
  }

  /// The pane nearest `tabID` in `direction` within `layout`: the closest pane that lies that way and
  /// overlaps on the perpendicular axis (so ⌃⌘→ from a tall left pane lands on whichever right pane
  /// shares the most rows). Pure geometry over a reference rect — `nil` if there's nothing that way.
  static func adjacentPane<Leaf: Hashable>(
    to tabID: Leaf, direction: PaneDirection, in layout: PaneLayout<Leaf>
  ) -> Leaf? {
    let panes = plan(layout, in: CGRect(x: 0, y: 0, width: 1000, height: 1000)).panes
    guard let from = panes[tabID] else { return nil }
    let horizontal = direction == .left || direction == .right
    var best: (id: Leaf, primary: CGFloat, secondary: CGFloat)?
    for (id, r) in panes where id != tabID {
      let inDirection: Bool
      switch direction {
      case .right: inDirection = r.midX > from.midX
      case .left: inDirection = r.midX < from.midX
      case .down: inDirection = r.midY > from.midY
      case .up: inDirection = r.midY < from.midY
      }
      let overlaps =
        horizontal
        ? (from.minY < r.maxY && r.minY < from.maxY) : (from.minX < r.maxX && r.minX < from.maxX)
      guard inDirection, overlaps else { continue }
      let primary = horizontal ? abs(r.midX - from.midX) : abs(r.midY - from.midY)
      let secondary = horizontal ? abs(r.midY - from.midY) : abs(r.midX - from.midX)
      if best == nil || primary < best!.primary
        || (primary == best!.primary && secondary < best!.secondary)
      {
        best = (id, primary, secondary)
      }
    }
    return best?.id
  }

  /// The half-pane band to highlight for a drop on `edge`.
  static func edgeBand(_ edge: PaneEdge, in rect: CGRect) -> CGRect {
    switch edge {
    case .left:
      return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .right:
      return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
    case .bottom:
      return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }
  }
}

// MARK: - Leaf

/// One terminal pane: hosts the surface, the focus ring, the activity flash (D3), and — in a split — a
/// small semi-transparent grip chip at the top-center that you drag to move the pane. (Closing is via
/// the strip ✕ / ⌘W, so the pane needs no close affordance of its own.)
private struct PaneLeafView: View {
  let tabID: TerminalTab.ID
  /// The pane's content — a terminal surface or non-terminal content (issue #66). All the pane chrome
  /// (focus ring, dim scrim, drag handle, a11y) wraps *both* kinds; only the centre swaps.
  let content: TabContent
  /// The target this pane belongs to — its `path` is the workroom directory handed to a diff pane (so
  /// its `DiffResolver` runs against the right repo), and it routes the diff pane's context-menu actions.
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  /// Routes the diff pane's reused tab context menu (issue #72: "Open File in…", split, close group).
  @EnvironmentObject var store: AppStore
  let title: String
  let focused: Bool
  let multiPane: Bool
  /// Whether this pane's workroom may hold keyboard focus — `false` for a co-displayed, non-focused
  /// workroom split member (the only `surfaceActive: false` caller). Drives the dim scrim alongside
  /// `multiPane` (see `PaneTreeView.shouldDim`). Non-defaulted on purpose: the compiler then forces
  /// the call site to thread it through, so the dim can't silently no-op (issue #82).
  let surfaceActive: Bool
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var flashing = false
  @State private var hovering = false
  // The shared @Observable service; reading `theme.tokens` in a body still tracks changes via the
  // Observation framework (no environment injection required, so view-rendering tests don't need it).
  private let theme = ThemeService.shared

  var body: some View {
    paneContent
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
            theme.tokens.terminalDim.opacity(
              PaneTreeView.shouldDim(
                multiPane: multiPane, surfaceActive: surfaceActive, focused: focused,
                flashing: flashing) ? 0.3 : 0)
          )
          .allowsHitTesting(false)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: flashing)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: focused)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: surfaceActive)
      }
      // A rounded border frames every terminal, the same in a split or solo: `borderColor` is the
      // focus tint on the focused pane (a solo terminal is always focused, so it always gets it) and a
      // neutral hairline on unfocused split panes — all at 1.5pt.
      .overlay {
        RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius)
          .strokeBorder(borderColor, lineWidth: 1.5)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: flashing)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.08), value: focused)
      }
      .overlay(alignment: .top) { handle }
      // A uniform 2pt pad on EVERY pane (solo or split) — split panes need it as the inter-pane gutter
      // (plus the surrounding panel gutter from WorkroomTerminalsView) so the rounded panes read as
      // separate cards, and a solo pane keeps the same pad so the panel doesn't shift when you switch
      // between a solo tab and a grouped/split one. Surface identity is held by `.id(tabID)` on the
      // host (not this padding), so no surface is re-parented across the change (issue #3).
      .padding(2)
      // Non-terminal panes (a diff) have no first responder to claim focus on click, so a click
      // anywhere in the body focuses the pane. Gated on `!isTerminal` ONLY — the content type is
      // stable for a pane's lifetime, so the gesture is never attached/detached mid-interaction
      // (gating on `focused` would flip the modifier's structural branch on every focus, tearing
      // down and rebuilding the DiffViewer — a reload flash + lag). A terminal pane skips this
      // entirely; its surface eats SwiftUI gestures and focuses via first responder.
      .modifier(ActivateOnPress(enabled: !isTerminal, onActivate: onActivate))
      .onHover { hovering = $0 }
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
      .accessibilityLabel(Text(accessibilityLabel))
      .accessibilityAddTraits(focused && multiPane ? .isSelected : [])
  }

  /// The pane's centre: a hosted terminal surface, or a diff viewer for a content tab. Clipped to the
  /// same rounded shape the focus border draws (the terminal host already clips itself).
  @ViewBuilder private var paneContent: some View {
    switch content {
    case .terminal(let s):
      TerminalContainerView(view: s.view, isFocusedPane: focused)
        // Scrollback find bar (⌘F), pinned top-trailing over the focused pane only — search state is
        // per-surface, and only the focused pane can be searched. Renders nothing until active.
        .overlay(alignment: .topTrailing) {
          if focused {
            TerminalSearchBar(model: s.view.searchModel)
          }
        }
    case .diff(let descriptor):
      // The diff pane body carries the SAME context menu as its tab chip (issue #72) — fetch the live
      // tab so "Keep Open" / split-guard reflect its current preview / split state. A diff leaf is
      // always a live tab while it renders, so the `else` is just a safety fallback.
      let diff = DiffViewer(
        descriptor: descriptor, directory: target.path,
        viewModeOverride: sessions.tab(tabID, for: target)?.diffViewModeOverride
      )
      .clipShape(
        RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius, style: .continuous))
      if let tab = sessions.tab(tabID, for: target) {
        diff.tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions)
      } else {
        diff
      }
    }
  }

  private var isTerminal: Bool {
    if case .terminal = content { return true }
    return false
  }

  /// "Terminal <title>" (or just the content tab's title), plus "pane N of M" in a split — so
  /// VoiceOver announces both what the pane is and where it sits in the group.
  private var accessibilityLabel: String {
    let base = isTerminal ? "Terminal \(title)" : title
    return multiPane ? "\(base), pane \(paneIndex) of \(paneCount)" : base
  }

  /// A small semi-transparent grip chip at the pane's top-center — drag it to move the pane (onto
  /// another pane's edge, or up to the strip to pop it out). Only in a split; hidden until the pane
  /// is hovered, so it isn't a permanent mark over the terminal's top line.
  @ViewBuilder private var handle: some View {
    if multiPane {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .opacity(hovering ? 0.95 : 0)
        .padding(.top, 5)
        .contentShape(Capsule())
        .gesture(
          DragGesture(coordinateSpace: .named(coordinateSpace))
            .onChanged { onDragChanged($0.location) }
            .onEnded { _ in onDragEnded() }
        )
        .help("Drag to move this pane")
        .accessibilityIdentifier("pane.grip")
        .accessibilityLabel("Move pane")
        .accessibilityHint("Drag onto a pane edge to rearrange, or to the tab strip to pop out")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    }
  }

  private var borderColor: Color {
    // The focused terminal gets the solid, theme-following `focused` tint — solo or split alike (and
    // an unfocused pane briefly flashes it on activity). Non-focused panes keep a faint neutral
    // hairline that still frames the surface.
    if focused || flashing { return theme.tokens.focused }
    return theme.tokens.border
  }
}

/// Focus a non-terminal pane on click. `enabled` is gated on content type only (stable for the
/// pane's lifetime) so the conditional never flips and churns the wrapped view's identity. A
/// `simultaneousGesture` tap (not a drag) so it fires promptly on click-up without fighting the
/// diff's own scroll / text-selection gestures — a `minimumDistance: 0` drag would stall while the
/// system disambiguates it from a scroll.
private struct ActivateOnPress: ViewModifier {
  let enabled: Bool
  let onActivate: () -> Void

  func body(content: Content) -> some View {
    if enabled {
      content.simultaneousGesture(TapGesture().onEnded { onActivate() })
    } else {
      content
    }
  }
}

// MARK: - Divider

/// A draggable divider that writes a new ratio for one split node. Draws **no** separator rule — each
/// terminal pane already has its own rounded border, so a line in the gutter would only double up;
/// it's just an invisible, hit-testable track surfaced by the resize cursor on hover.
private struct SplitDivider: View {
  let orientation: SplitOrientation
  let ratio: CGFloat
  let total: CGFloat
  let onRatio: (CGFloat) -> Void
  @State private var startRatio: CGFloat?

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            let start = startRatio ?? ratio
            if startRatio == nil { startRatio = start }
            let usable = max(1, total - PaneTreeLayout.dividerThickness)
            let delta =
              orientation == .horizontal ? value.translation.width : value.translation.height
            onRatio(PaneTreeLayout.clampRatio(start + delta / usable, total: total))
          }
          .onEnded { _ in startRatio = nil }
      )
      .onHover { inside in
        if inside {
          (orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
          NSCursor.pop()
        }
      }
      // Adjustable so VoiceOver users can resize without a drag: ⌃⌥→/← nudge the split by 5%.
      .accessibilityElement()
      .accessibilityIdentifier("pane.divider")
      .accessibilityLabel(
        orientation == .horizontal ? "Vertical pane divider" : "Horizontal pane divider"
      )
      .accessibilityValue("\(Int((ratio * 100).rounded()))%")
      .accessibilityAdjustableAction { direction in
        let step: CGFloat = 0.05
        switch direction {
        case .increment: onRatio(PaneTreeLayout.clampRatio(ratio + step, total: total))
        case .decrement: onRatio(PaneTreeLayout.clampRatio(ratio - step, total: total))
        @unknown default: break
        }
      }
  }
}
