import AppKit
import Defaults
import SwiftUI

/// Renders a target's pane layout (issue #3): a solo terminal is a single-leaf layout, a split is a
/// tree. Every visible pane is laid out in ONE flat `ZStack`, positioned by an absolutely-computed
/// frame and keyed by tab id — a surviving pane keeps the exact same host across layout changes (only
/// its frame moves), so its surface is never re-parented (the close-a-split-pane blank bug). Frame and
/// drop-target math are pure and unit-tested (plan D5).
///
/// Drag-and-drop (Phase 2): a split pane is dragged by its own title bar (`PaneTitleBar`, issue #150 —
/// it replaced a hover-only grip chip); dragging shows 4 edge drop zones on the pane under the cursor
/// and, on drop, moves/rearranges via `moveTabIntoSplit` (or pops the pane out to solo via
/// `extractFromSplit` if dragged up to the strip).
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
  /// Whether this tree's *workroom* is one member of a multi-workroom split (`WorkroomPaneLeaf.multi`
  /// in `WorkroomSplitView`) — distinct from `multiPane` below, which is this tree's OWN split (≥2
  /// terminal panes within the one workroom). A solo terminal in a workroom that is itself split still
  /// wants the focused ring, since it's the thing being picked out among the OTHER workrooms on screen.
  var workroomIsSplit: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// "Dim unfocused panes" (issue #162) — read here, at the tree, and passed to every leaf.
  @Default(.dimUnfocusedPanes) private var dimUnfocusedPanes
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
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(Array(layout.tabIDs.enumerated()), id: \.element) { index, tabID in
          if let tab = sessions.tab(tabID, for: target), let rect = plan.panes[tabID] {
            PaneLeafView(
              tabID: tabID, content: tab.content, target: target, sessions: sessions,
              title: tab.title,
              focused: surfaceActive && tabID == focusedID, multiPane: multiPane,
              surfaceActive: surfaceActive, dimUnfocusedPanes: dimUnfocusedPanes,
              workroomIsSplit: workroomIsSplit,
              paneIndex: index + 1, paneCount: layout.tabIDs.count, coordinateSpace: Self.space,
              onDragChanged: { beginOrUpdateDrag(tabID: tabID, at: $0) },
              onDragEnded: { commitDrag(plan: plan) },
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

/// The pane rects the renderer laid out, carried to `TerminalSessions.paneRects`. Reduce keeps the
/// last non-empty value: sibling subtrees contribute nothing, so an empty map must not clobber a
/// real measurement (same shape as `ContentFrameKey`'s non-zero rule).
private struct PaneRectsKey: PreferenceKey {
  static var defaultValue: [TerminalTab.ID: CGRect] = [:]
  static func reduce(
    value: inout [TerminalTab.ID: CGRect], nextValue: () -> [TerminalTab.ID: CGRect]
  ) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

/// The rect the split was laid out in, carried to `TerminalSessions.paneSpace`. Keeps the last
/// non-empty value for the same reason `PaneRectsKey` does — an empty sibling contribution must not
/// erase a real measurement.
private struct PaneSpaceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
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
  static var minPaneWidth: CGFloat { TerminalSessions.minPaneWidth }
  static var minPaneHeight: CGFloat { TerminalSessions.minPaneHeight }

  /// The pane floor along the axis a split divides: width for side-by-side, height for stacked. The two
  /// differ because the tab strip's furniture only constrains width — see `TerminalSessions.minPaneWidth`.
  /// Every clamp and fit guard reads the floor through here, so the axis can never be picked twice.
  /// Whether `rect` can be split along `orientation` without either half landing under the axis
  /// floor. The same arithmetic as `TerminalSessions.fits`, but over a MEASURED pane rect rather than
  /// a live `GhosttySurfaceView`'s bounds — so it also works for the workroom pane tree, whose leaves
  /// are `SidebarID`s with no surface to measure (`AppStore.insertWorkroomSplit` had no fit guard at
  /// all, and a third workroom dropped into ~700pt produced two 172pt panes).
  ///
  /// A zero/degenerate rect permits the split, matching `fits`' `available > 0` escape: nothing has
  /// been laid out yet, so the renderer's own points-based clamp is the authority.
  static func canSplit(_ rect: CGRect, along orientation: SplitOrientation) -> Bool {
    let available = orientation == .horizontal ? rect.width : rect.height
    guard available > 0 else { return true }
    return (available - dividerThickness) / 2 >= minPane(along: orientation)
  }

  static func minPane(along orientation: SplitOrientation) -> CGFloat {
    orientation == .horizontal ? minPaneWidth : minPaneHeight
  }

  /// How far a divider's incoming ratio may sit from the last value THIS drag emitted before the
  /// drag treats it as having been moved by something else.
  static let reanchorTolerance: CGFloat = 0.0005

  /// Whether a divider drag must re-anchor: it has not started yet, or the ratio it is being handed
  /// no longer matches the last one it emitted, which means something other than this drag moved it.
  ///
  /// That second case is an auto-even landing while the mouse is down (issue #126): `equalized()`
  /// preserves every split node's `id`, so the divider view — and its latched start ratio — survive
  /// a tree that has changed underneath them. Replaying `stale start + whole-gesture translation`
  /// then undoes the even, on the next tick for a live-writing divider and at mouse-up for a
  /// committing one. Shared by both dividers so the two cannot drift on the rule.
  static func shouldReanchorDrag(currentRatio: CGFloat, lastEmitted: CGFloat?, hasStarted: Bool)
    -> Bool
  {
    guard hasStarted else { return true }
    guard let lastEmitted else { return false }
    return abs(currentRatio - lastEmitted) > reanchorTolerance
  }

  /// Whether `tree`, laid out in `container`, actually RENDERS the ratios it stores. `lengths`
  /// clamps every node to its own axis floor and, below twice that floor, abandons the ratio
  /// altogether for a bare half-and-half — so a tree can be evened in the model and visibly uneven
  /// on screen. Measured: three columns evened to thirds of 800pt want 266pt each and get the 300pt
  /// floor on the first one, leaving the other two to share what's left.
  ///
  /// Auto-even asks this before committing and keeps the user's dividers when the answer is no,
  /// rather than producing a third outcome that is neither even nor what they dragged (issue #126).
  ///
  /// Asks it per NODE rather than by comparing pane sizes, because "even" is not one shape: after
  /// #126's slot weighting a mixed tree is deliberately not equal-area (a full-width pane above two
  /// side-by-side ones is twice their area), so only the node's own axis can say whether its
  /// division survived. An unmeasured container permits, matching `canSplit`.
  static func plansEvenly<Leaf: Hashable>(_ tree: PaneLayout<Leaf>, in container: CGRect) -> Bool {
    guard container.width > 0, container.height > 0 else { return true }
    guard case .split(_, let orientation, let ratio, let first, let second) = tree else {
      return true
    }
    let axis = orientation == .horizontal ? container.width : container.height
    let usable = max(0, axis - dividerThickness)
    let (firstLen, secondLen) = lengths(total: axis, ratio: ratio, along: orientation)
    // What the ratio asked for, before any clamp. More than a point of drift means the renderer
    // overrode it.
    guard abs(firstLen - (usable * ratio).rounded()) <= 1 else { return false }
    let (firstRect, secondRect) =
      orientation == .horizontal
      ? (
        CGRect(x: 0, y: 0, width: firstLen, height: container.height),
        CGRect(x: 0, y: 0, width: secondLen, height: container.height)
      )
      : (
        CGRect(x: 0, y: 0, width: container.width, height: firstLen),
        CGRect(x: 0, y: 0, width: container.width, height: secondLen)
      )
    return plansEvenly(first, in: firstRect) && plansEvenly(second, in: secondRect)
  }

  /// Whether every pane of `tree` lands at or above BOTH axis floors in `container` — the
  /// GROUP-level question the split guard should ask once auto-even is on (issue #126). `canSplit`
  /// asks whether one anchor rect can be halved, which stops being the right question when adding a
  /// pane redistributes the whole group instead of halving one pane: a pane dragged narrow refuses
  /// ⌘D even though the group has room for another. Callers with no measured container keep using
  /// `canSplit`.
  ///
  /// `lengths` clamps, so a planned pane only lands under a floor when the container genuinely
  /// cannot hold this many panes — which is exactly the refusal this guard exists to make.
  ///
  /// `notWorseThan` is the tree as it stands today, and it exists because panes can ALREADY be under
  /// a floor through no fault of the split being judged: drag an ancestor divider far enough and
  /// `lengths` runs out of room to honour the floor at all, falling back to an even split of
  /// whatever is left (a 370pt column becomes two 184pt panes). Refusing every later split in that
  /// subtree would block a ⇧⌘D that only divides HEIGHT and takes nothing off the offending width —
  /// the "⌘D silently does nothing" papercut, reintroduced from the other side. So a pane already
  /// under a floor is judged on whether this split makes that axis worse, not on the floor itself.
  /// Omit the argument to demand the floor outright.
  static func fitsEveryPane<Leaf: Hashable>(
    _ tree: PaneLayout<Leaf>, in container: CGRect, notWorseThan current: PaneLayout<Leaf>? = nil
  ) -> Bool {
    guard container.width > 0, container.height > 0 else { return true }
    let after = smallestPane(tree, in: container)
    if after.width >= minPaneWidth, after.height >= minPaneHeight { return true }
    guard let current else { return false }
    let before = smallestPane(current, in: container)
    return after.width >= min(before.width, minPaneWidth)
      && after.height >= min(before.height, minPaneHeight)
  }

  /// The smallest width and the smallest height across every pane of `tree` (not necessarily the
  /// same pane) — the two numbers the floors are judged against.
  private static func smallestPane<Leaf: Hashable>(_ tree: PaneLayout<Leaf>, in container: CGRect)
    -> CGSize
  {
    let rects = plan(tree, in: container).panes.values
    return CGSize(
      width: rects.map(\.width).min() ?? container.width,
      height: rects.map(\.height).min() ?? container.height)
  }

  /// The tree a mutation will ACTUALLY store (issue #126): evened when the auto-even pref is on and
  /// the container can honour equality, otherwise untouched. A nil container — nothing measured yet
  /// — evens optimistically, the same posture `canSplit` takes when it has no rect.
  ///
  /// Shared by the fit guard and the commit that follows it, so the guard can never admit a split
  /// whose real result it didn't measure. That divergence is the class
  /// `WorkroomSplitTests.testAdmissibilityMatchesWhatInsertActuallyDoes` exists to catch.
  static func evenedIfHonourable<Leaf: Hashable>(
    _ tree: PaneLayout<Leaf>, in container: CGRect?, enabled: Bool
  ) -> PaneLayout<Leaf> {
    guard enabled else { return tree }
    let evened = tree.equalized()
    guard let container else { return evened }
    return plansEvenly(evened, in: container) ? evened : tree
  }

  /// Draggable hit-zone thickness for the resize divider (issue #83). The visible gutter stays
  /// `dividerThickness` (2pt); the hit zone is widened to this so the divider is easier to grab. It is
  /// capped at `dividerThickness + 1pt pane padding on each side` (= 4pt) — the widest band that stays
  /// over only the transparent gutter + the panes' 1pt padding (see `PaneLeafView`'s `.padding(1)`), so
  /// it never overhangs a live terminal surface and can't intercept the terminal's own mouse input
  /// (text selection, OSC8 link clicks, right-click menu, TUI mouse reporting).
  static var dividerHitThickness: CGFloat { dividerThickness + 2 }

  /// Lengths of the first/second child along the split axis for a container of `total` points. Rounds
  /// the first child to whole points (avoids sub-pixel seams) and clamps so neither child falls below
  /// the axis's floor (`minPane(along:)`); when the container is too small to honor that, falls back to
  /// an even split.
  static func lengths(total: CGFloat, ratio: CGFloat, along orientation: SplitOrientation) -> (
    first: CGFloat, second: CGFloat
  ) {
    let floor = minPane(along: orientation)
    let usable = max(0, total - dividerThickness)
    guard usable > 2 * floor else {
      let half = (usable / 2).rounded()
      return (half, usable - half)
    }
    let raw = (usable * ratio).rounded()
    let first = min(usable - floor, max(floor, raw))
    return (first, usable - first)
  }

  /// Clamp a proposed divider ratio to keep both panes ≥ the axis's floor (the single, view-owned clamp).
  ///
  /// Below the floor the proposed ratio is returned UNCHANGED, not centred. Every caller feeds the
  /// result straight to a persisting setter (`TerminalSessions.setRatio`,
  /// `AppStore.setWorkroomSplitRatio`), so returning `0.5` here doesn't just freeze the divider — it
  /// overwrites the user's stored ratio, and widening the window back out can't bring it back. The
  /// container being too small is a transient of the CURRENT geometry; the stored ratio outlives it.
  /// Rendering is unaffected either way: `lengths` independently ignores the ratio and splits evenly
  /// under the same condition, so a too-small container still draws centred — it just no longer
  /// forgets what to go back to.
  static func clampRatio(_ ratio: CGFloat, total: CGFloat, along orientation: SplitOrientation)
    -> CGFloat
  {
    let floor = minPane(along: orientation)
    let usable = max(1, total - dividerThickness)
    guard usable > 2 * floor else { return ratio }
    let minR = floor / usable
    return min(1 - minR, max(minR, ratio))
  }

  /// Absolute frames for every leaf (by tab id) and every divider, laying `node` out in `rect`.
  static func plan<Leaf: Hashable>(_ node: PaneLayout<Leaf>, in rect: CGRect) -> Plan<Leaf> {
    switch node {
    case .leaf(let id):
      return ([id: rect], [])
    case .split(let sid, let orientation, let ratio, let first, let second):
      let axis = orientation == .horizontal ? rect.width : rect.height
      let (firstLen, secondLen) = lengths(total: axis, ratio: ratio, along: orientation)
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

/// One terminal pane: hosts its title bar (issue #150), the surface, the focus ring and the activity
/// flash (D3). In a split the title bar is also the pane's drag handle — it replaced a hover-only grip
/// chip, so the affordance is always visible. (Closing is via the strip ✕ / ⌘W, or that same bar.)
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
  /// The inline terminal agent (issue #49); its per-tab state drives the auto-diagnose opt-in dialog.
  @EnvironmentObject var agentManager: TerminalAgentManager
  let title: String
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
  // The shared @Observable service; reading `theme.tokens` in a body still tracks changes via the
  // Observation framework (no environment injection required, so view-rendering tests don't need it).
  private let theme = ThemeService.shared

  var body: some View {
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
      titleBar
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
      paneContent
        .modifier(
          ActivateOnPress(
            enabled: !isTerminal, onActivate: onActivate,
            isBlocked: { store.activePicker != nil })
        )
    }
    .clipShape(
      RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius, style: .continuous)
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
          theme.tokens.terminalDim.opacity(
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
      RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius)
        .strokeBorder(borderColor, lineWidth: 1.5)
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
        get: { agentManager.autoOptInPromptTab == tabID },
        set: { if !$0 { agentManager.respondToAutoOptIn(enable: false) } }),
      titleVisibility: .visible
    ) {
      Button("Auto-diagnose") { agentManager.respondToAutoOptIn(enable: true) }
      Button("Not now", role: .cancel) { agentManager.respondToAutoOptIn(enable: false) }
    } message: {
      Text("Workroom can diagnose failed commands automatically, instead of waiting for a click.")
    }
    // A uniform 1pt pad on EVERY pane (solo or split) — split panes need it as the inter-pane gutter
    // (plus the surrounding panel gutter from WorkroomTerminalsView) so the rounded panes read as
    // separate cards, and a solo pane keeps the same pad so the panel doesn't shift when you switch
    // between a solo tab and a grouped/split one. Surface identity is held by `.id(tabID)` on the
    // host (not this padding), so no surface is re-parented across the change (issue #3).
    .padding(1)
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
    // `multiPane || UITestFixture.isActive`: with one pane there's normally no need to mark it
    // selected, but that left single-pane keyboard focus with NO queryable signal, so a UI test
    // asserting "the terminal has focus" could only ever be vacuous — and focus races here are a
    // recurring bug class (the ⌘F find-bar hatch in TerminalContainerView, DiffPaneFocusUITests, and
    // the dialog-vs-terminal race this trait now covers). Fixture-gated rather than unconditional:
    // a lone pane announcing itself "selected" to VoiceOver would be wrong for real users.
    .accessibilityAddTraits(
      focused && (multiPane || UITestFixture.isActive) ? .isSelected : [])
  }

  /// The pane's centre: a hosted terminal surface, or a diff viewer for a content tab. Clipped to the
  /// same rounded shape the focus border draws (the terminal host already clips itself).
  @ViewBuilder private var paneContent: some View {
    switch content {
    case .terminal(let s):
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
          view: s.view, isFocusedPane: focused && store.activePicker == nil
        )
        // Scrollback find bar (⌘F), pinned top-trailing over the focused pane only — search state
        // is per-surface, and only the focused pane can be searched. Nothing until active.
        .overlay(alignment: .topTrailing) {
          if focused {
            TerminalSearchBar(model: s.view.searchModel)
          }
        }
        TerminalStatusBar(target: target, tabID: tabID, state: s)
      }
    case .diff(let descriptor):
      // The diff pane body carries the SAME context menu as its tab chip (issue #72) — fetch the live
      // tab so "Keep Open" / split-guard reflect its current preview / split state. A diff leaf is
      // always a live tab while it renders, so the `else` is just a safety fallback.
      let diff = DiffViewer(
        descriptor: descriptor, directory: target.path,
        projectRoot: store.projectRoot(forTarget: target),
        viewModeOverride: sessions.tab(tabID, for: target)?.diffViewModeOverride,
        isFocused: focused, find: store.contentFind
      )
      if let tab = sessions.tab(tabID, for: target) {
        contentPanel(
          diff.tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions))
      } else {
        contentPanel(diff)
      }
    case .file(let descriptor):
      // Read-only file viewer (Files inspector section). Same rounded clip + chip context menu as the
      // diff leaf, so "Keep Open"/Close behave identically on a previewed file.
      let file = PlainFileViewer(
        descriptor: descriptor, directory: target.path, isFocused: focused,
        previewOverride: sessions.tab(tabID, for: target)?.markdownPreviewOverride,
        find: store.contentFind
      )
      if let tab = sessions.tab(tabID, for: target) {
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
        descriptor: descriptor, directory: target.path, tabID: tabID, target: target,
        isFocused: focused, find: store.contentFind)
      if let tab = sessions.tab(tabID, for: target) {
        contentPanel(
          detail.tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions))
      } else {
        contentPanel(detail)
      }
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
  private var accessibilityLabel: String {
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
  private var titleBar: some View {
    let tab = sessions.tab(tabID, for: target)
    return PaneTitleBar(
      title: PaneTitlePresentation.title(for: content, tabTitle: title),
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
  private var helpText: String {
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
      active: activeState != .inactive, tokens: theme.tokens)
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
    private var monitor: Any?

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

    func teardownMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    deinit { teardownMonitor() }
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
  /// The translation this drag measures FROM — zero normally, re-based when the drag re-anchors
  /// mid-gesture (`value.translation` is cumulative, so a new anchor needs a new origin).
  @State private var baseTranslation: CGSize = .zero
  /// The last ratio this drag emitted. An incoming `ratio` that differs from it came from somewhere
  /// else — an auto-even landing while the mouse is down (issue #126).
  @State private var lastEmitted: CGFloat?

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            // Re-anchor when the divider moved for a reason other than this drag. `equalized()`
            // keeps every split node's `id`, so an auto-even landing mid-drag leaves this view and
            // its latched start alive over a tree that has since changed; replaying
            // `stale start + whole-gesture translation` would undo the even on the very next tick.
            if PaneTreeLayout.shouldReanchorDrag(
              currentRatio: ratio, lastEmitted: lastEmitted, hasStarted: startRatio != nil)
            {
              startRatio = ratio
              baseTranslation = value.translation
            }
            let usable = max(1, total - PaneTreeLayout.dividerThickness)
            let moved =
              orientation == .horizontal
              ? value.translation.width - baseTranslation.width
              : value.translation.height - baseTranslation.height
            let next = PaneTreeLayout.clampRatio(
              (startRatio ?? ratio) + moved / usable, total: total, along: orientation)
            lastEmitted = next
            onRatio(next)
          }
          .onEnded { _ in
            startRatio = nil
            lastEmitted = nil
            baseTranslation = .zero
          }
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
        case .increment:
          onRatio(PaneTreeLayout.clampRatio(ratio + step, total: total, along: orientation))
        case .decrement:
          onRatio(PaneTreeLayout.clampRatio(ratio - step, total: total, along: orientation))
        @unknown default: break
        }
      }
  }
}
