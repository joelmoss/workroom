import CoreGraphics
import Foundation

// Pure layout and drop math for a `PaneLayout` tree, shared by both splits' renderers
// (`PaneTreeView`, `WorkroomSplitView`) and their fit guards. View-free, so `swift test` covers it.

public struct PaneDividerFrame: Identifiable, Sendable {
  public let id: UUID
  public let orientation: SplitOrientation
  /// The 4pt visual gutter rect — where the divider sits and the value `.position` centers on.
  public let rect: CGRect
  /// The draggable hit-zone rect (issue #83): `rect` widened along the split axis to
  /// `dividerHitThickness`, centered on `rect`. Wider than the visual gutter so the divider is
  /// easier to grab, but still entirely within the transparent gutter + pane padding so it never
  /// overhangs a live terminal surface (which would steal the terminal's own mouse input).
  public let hitRect: CGRect
  public let ratio: CGFloat
  public let total: CGFloat
}

public enum PaneTreeLayout {
  public typealias Plan<Leaf: Hashable> = (panes: [Leaf: CGRect], dividers: [PaneDividerFrame])

  public static var dividerThickness: CGFloat { PaneMetrics.dividerThickness }
  public static var minPaneWidth: CGFloat { PaneMetrics.minPaneWidth }
  public static var minPaneHeight: CGFloat { PaneMetrics.minPaneHeight }

  /// The pane floor along the axis a split divides: width for side-by-side, height for stacked. The two
  /// differ because the tab strip's furniture only constrains width — see `PaneMetrics.minPaneWidth`.
  /// Every clamp and fit guard reads the floor through here, so the axis can never be picked twice.
  /// Whether `rect` can be split along `orientation` without either half landing under the axis
  /// floor. The same arithmetic as `TerminalSessions.fits`, but over a MEASURED pane rect rather than
  /// a live `GhosttySurfaceView`'s bounds — so it also works for the workroom pane tree, whose leaves
  /// are `SidebarID`s with no surface to measure (`AppStore.insertWorkroomSplit` had no fit guard at
  /// all, and a third workroom dropped into ~700pt produced two 172pt panes).
  ///
  /// A zero/degenerate rect permits the split, matching `fits`' `available > 0` escape: nothing has
  /// been laid out yet, so the renderer's own points-based clamp is the authority.
  public static func canSplit(_ rect: CGRect, along orientation: SplitOrientation) -> Bool {
    let available = orientation == .horizontal ? rect.width : rect.height
    guard available > 0 else { return true }
    return (available - dividerThickness) / 2 >= minPane(along: orientation)
  }

  public static func minPane(along orientation: SplitOrientation) -> CGFloat {
    orientation == .horizontal ? minPaneWidth : minPaneHeight
  }

  /// How far a divider's incoming ratio may sit from the last value THIS drag emitted before the
  /// drag treats it as having been moved by something else.
  public static let reanchorTolerance: CGFloat = 0.0005

  /// Whether a divider drag must re-anchor: it has not started yet, or the ratio it is being handed
  /// no longer matches the last one it emitted, which means something other than this drag moved it.
  ///
  /// That second case is an auto-even landing while the mouse is down (issue #126): `equalized()`
  /// preserves every split node's `id`, so the divider view — and its latched start ratio — survive
  /// a tree that has changed underneath them. Replaying `stale start + whole-gesture translation`
  /// then undoes the even, on the next tick for a live-writing divider and at mouse-up for a
  /// committing one. Read by the one `SplitDivider` both splits use.
  public static func shouldReanchorDrag(
    currentRatio: CGFloat, lastEmitted: CGFloat?, hasStarted: Bool
  ) -> Bool {
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
  ///
  /// `evenedAxis` is the axis an axis-only even rebalanced. A divider of the other axis was left
  /// where the user put it, so it is laid out as the renderer will (clamped) rather than judged: a
  /// clamped divider the even never touched must not veto it.
  ///
  /// `leafSlots` is the weight the tree was evened by. A leaf weighted N along an axis holds N panes
  /// that way, so it needs room for N panes at the floor there.
  public static func plansEvenly<Leaf: Hashable>(
    _ tree: PaneLayout<Leaf>, in container: CGRect, evenedAxis: SplitOrientation? = nil,
    leafSlots: ((Leaf, SplitOrientation) -> Int)? = nil
  ) -> Bool {
    guard container.width > 0, container.height > 0 else { return true }
    if case .leaf(let leaf) = tree {
      return SplitOrientation.allCases.allSatisfy { axis in
        guard evenedAxis == nil || evenedAxis == axis else { return true }
        let count = leafSlots?(leaf, axis) ?? 1
        let length = axis == .horizontal ? container.width : container.height
        return count <= 1
          || length >= CGFloat(count) * minPane(along: axis) + CGFloat(count - 1)
            * dividerThickness
      }
    }
    guard case .split(_, let orientation, let ratio, let first, let second) = tree else {
      return true
    }
    let axis = orientation == .horizontal ? container.width : container.height
    let usable = max(0, axis - dividerThickness)
    if let evenedAxis, evenedAxis != orientation {
      let (firstLen, secondLen) = lengths(total: axis, ratio: ratio, along: orientation)
      let (firstRect, secondRect) = childRects(container, orientation, firstLen, secondLen)
      return plansEvenly(first, in: firstRect, evenedAxis: evenedAxis, leafSlots: leafSlots)
        && plansEvenly(second, in: secondRect, evenedAxis: evenedAxis, leafSlots: leafSlots)
    }
    // BELOW twice the floor `lengths` abandons the ratio and returns a bare half-and-half, which
    // EQUALS the ratio-implied length whenever the stored ratio is already 0.5 — so the drift check
    // below cannot see it, and both children are under the floor by construction. Measured (the
    // shape two reviewers independently cited): `A | ((B / E) / (C | D))` at root 0.28 in 1100x1000,
    // close E, and evening takes C and D from 395/394 to 274/273 against a 300pt floor.
    //
    // AT exactly twice the floor the fallback still fires, but its two children land exactly ON the
    // floor rather than under it — an honourable result the drift check can then adjudicate on its
    // own (a ratio other than 0.5 still diverges from half-and-half and is caught). Rejecting the
    // equality cancelled evening for the whole group over a split that fits precisely.
    guard usable >= 2 * minPane(along: orientation) else { return false }
    let (firstLen, secondLen) = lengths(total: axis, ratio: ratio, along: orientation)
    // What the ratio asked for, before any clamp. More than a point of drift means the renderer
    // overrode it.
    guard abs(firstLen - (usable * ratio).rounded()) <= 1 else { return false }
    let (firstRect, secondRect) = childRects(container, orientation, firstLen, secondLen)
    return plansEvenly(first, in: firstRect, evenedAxis: evenedAxis, leafSlots: leafSlots)
      && plansEvenly(second, in: secondRect, evenedAxis: evenedAxis, leafSlots: leafSlots)
  }

  /// The two children's rects (origin-free; only their size matters here) for a split of
  /// `container` along `orientation` whose children are `firstLen` and `secondLen` long.
  private static func childRects(
    _ container: CGRect, _ orientation: SplitOrientation, _ firstLen: CGFloat,
    _ secondLen: CGFloat
  ) -> (CGRect, CGRect) {
    orientation == .horizontal
      ? (
        CGRect(x: 0, y: 0, width: firstLen, height: container.height),
        CGRect(x: 0, y: 0, width: secondLen, height: container.height)
      )
      : (
        CGRect(x: 0, y: 0, width: container.width, height: firstLen),
        CGRect(x: 0, y: 0, width: container.width, height: secondLen)
      )
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
  /// the "⌘D silently does nothing" papercut, reintroduced from the other side.
  ///
  /// The comparison is PER PANE, by identity. A global minimum was the first shape and it was wrong:
  /// one narrow pane anywhere pinned the minimum for the whole tree, so an unrelated healthy pane
  /// could be split clean through the floor and the guard still said yes. Measured on the shape that
  /// found it — `(A | B) | (C | D)` at root 0.3 in 1000pt is `149, 149, 348, 348`, and splitting the
  /// 348 gave `149, 149, 173, 173, 348` with the old rule admitting it. A pane that SURVIVES the
  /// edit may not shrink below its own current size once it is under the floor; a pane the edit
  /// CREATES is held to the floor outright. Omit the argument to demand the floor of everything.
  public static func fitsEveryPane<Leaf: Hashable>(
    _ tree: PaneLayout<Leaf>, in container: CGRect, notWorseThan current: PaneLayout<Leaf>? = nil,
    splitting anchor: Leaf? = nil
  ) -> Bool {
    guard container.width > 0, container.height > 0 else { return true }
    let after = plan(tree, in: container).panes
    guard let current else {
      return after.values.allSatisfy { $0.width >= minPaneWidth && $0.height >= minPaneHeight }
    }
    let before = plan(current, in: container).panes
    for (leaf, rect) in after {
      // What this pane has to answer to. A survivor answers to its own previous size. A pane the
      // edit CREATED answers to the anchor it was split from — it cannot be wider than the column
      // it was carved out of, so holding it to the bare floor would refuse a ⇧⌘D that divides only
      // the height of an already-narrow pane, which is the papercut `notWorseThan` exists to avoid.
      guard let was = before[leaf] ?? anchor.flatMap({ before[$0] }) else {
        // No reference at all (no anchor passed): hold it to the floor.
        guard rect.width >= minPaneWidth, rect.height >= minPaneHeight else { return false }
        continue
      }
      guard rect.width >= min(was.width, minPaneWidth),
        rect.height >= min(was.height, minPaneHeight)
      else { return false }
    }
    return true
  }

  /// The tree a mutation will ACTUALLY store (issue #126): evened when the auto-even pref is on and
  /// the container can honour equality, otherwise untouched. A nil container — nothing measured yet
  /// — evens optimistically, the same posture `canSplit` takes when it has no rect.
  ///
  /// Shared by the fit guard and the commit that follows it, so the guard can never admit a split
  /// whose real result it didn't measure. That divergence is the class
  /// `WorkroomSplitTests.testAdmissibilityMatchesWhatInsertActuallyDoes` exists to catch.
  ///
  /// `axis` limits the even to that direction's dividers: the orientation of the split being added,
  /// or of the split a removed pane left. `leafSlots` weights each leaf, as `equalized` does.
  public static func evenedIfHonourable<Leaf: Hashable>(
    _ tree: PaneLayout<Leaf>, in container: CGRect?, enabled: Bool,
    along axis: SplitOrientation? = nil,
    leafSlots: ((Leaf, SplitOrientation) -> Int)? = nil
  ) -> PaneLayout<Leaf> {
    evened(tree, in: container, enabled: enabled, along: axis, leafSlots: leafSlots) ?? tree
  }

  /// `evenedIfHonourable`, but nil where that returns `tree` unchanged: the pref is off, or the
  /// container cannot render the even. A caller that stores something other than `tree` when the
  /// even declines (the workroom split's ghost-leaf case, `PaneSplitGroups.inserting`) needs to
  /// tell the two apart.
  public static func evened<Leaf: Hashable>(
    _ tree: PaneLayout<Leaf>, in container: CGRect?, enabled: Bool,
    along axis: SplitOrientation? = nil,
    leafSlots: ((Leaf, SplitOrientation) -> Int)? = nil
  ) -> PaneLayout<Leaf>? {
    guard enabled else { return nil }
    let evened = tree.equalized(along: axis, leafSlots: leafSlots)
    guard let container else { return evened }
    return plansEvenly(evened, in: container, evenedAxis: axis, leafSlots: leafSlots)
      ? evened : nil
  }

  /// Draggable hit-zone thickness for the resize divider (issue #83). The visible gutter stays
  /// `dividerThickness` (2pt); the hit zone is widened to this so the divider is easier to grab. It is
  /// capped at `dividerThickness + 1pt pane padding on each side` (= 4pt) — the widest band that stays
  /// over only the transparent gutter + the panes' 1pt padding (see `PaneLeafView`'s `.padding(1)`), so
  /// it never overhangs a live terminal surface and can't intercept the terminal's own mouse input
  /// (text selection, OSC8 link clicks, right-click menu, TUI mouse reporting).
  public static var dividerHitThickness: CGFloat { dividerThickness + 2 }

  /// Lengths of the first/second child along the split axis for a container of `total` points. Rounds
  /// the first child to whole points (avoids sub-pixel seams) and clamps so neither child falls below
  /// the axis's floor (`minPane(along:)`); when the container is too small to honor that, falls back to
  /// an even split.
  public static func lengths(
    total: CGFloat, ratio: CGFloat, along orientation: SplitOrientation
  ) -> (first: CGFloat, second: CGFloat) {
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
  public static func clampRatio(
    _ ratio: CGFloat, total: CGFloat, along orientation: SplitOrientation
  ) -> CGFloat {
    let floor = minPane(along: orientation)
    let usable = max(1, total - dividerThickness)
    guard usable > 2 * floor else { return ratio }
    let minR = floor / usable
    return min(1 - minR, max(minR, ratio))
  }

  /// Absolute frames for every leaf (by tab id) and every divider, laying `node` out in `rect`.
  public static func plan<Leaf: Hashable>(_ node: PaneLayout<Leaf>, in rect: CGRect) -> Plan<Leaf> {
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
  public static func dropTarget<Leaf: Hashable>(at point: CGPoint, panes: [Leaf: CGRect])
    -> (tab: Leaf, edge: PaneEdge)?
  {
    guard let hit = panes.first(where: { $0.value.contains(point) }) else { return nil }
    return (hit.key, nearestEdge(of: point, in: hit.value))
  }

  /// What a pane-handle drag should do when the mouse comes up (issue #172). Pure geometry, so the
  /// three-way branch — and crucially its ORDER — is unit-testable without a window or a mouse, the
  /// same reason `plan`/`dropTarget` live here rather than in the renderer.
  ///
  /// Every point is in the pane tree's own content space, including `windowBounds`: one coordinate
  /// space in, no conversion inside.
  public enum PaneDragOutcome<Leaf: Hashable>: Equatable {
    /// Drop onto another pane's edge — rearrange, or add a member to the split.
    case move(tab: Leaf, edge: PaneEdge)
    /// Dragged up out of the panes but still inside the window → pop out of the split to solo.
    case extract
    /// Dragged clear of the window on ANY edge → detach into its own window.
    case detach
    /// Dropped somewhere that means nothing; put it back.
    case none
  }

  /// Resolve a finished pane drag. The order is the contract: **move beats extract beats detach.**
  ///
  /// `extract` is fenced to `windowBounds`, and that fence is the whole reason this is a function
  /// rather than the two inline conditions it replaced. The old test was a bare `location.y < 0`
  /// ("above the panes" ⇒ pop out to solo), which is ALSO true once the cursor has left the top of
  /// the window — so without the fence the top edge could never tear a pane off, and it is the edge
  /// the pane title bar's own accessibility hint points people toward ("drag to the tab strip to pop
  /// out"). Fenced, the two gestures separate by distance: still inside ⇒ extract, past the edge in
  /// any direction ⇒ detach.
  public static func dragOutcome<Leaf: Hashable>(
    cursor: CGPoint, windowBounds: CGRect, panes: [Leaf: CGRect], dragging: Leaf
  ) -> PaneDragOutcome<Leaf> {
    if let hit = dropTarget(at: cursor, panes: panes), hit.tab != dragging {
      return .move(tab: hit.tab, edge: hit.edge)
    }
    guard windowBounds.contains(cursor) else { return .detach }
    return cursor.y < 0 ? .extract : .none
  }

  /// The edge of `rect` nearest `point`, normalised by the rect's aspect (so a wide pane still splits
  /// top/bottom near its short edges).
  public static func nearestEdge(of point: CGPoint, in rect: CGRect) -> PaneEdge {
    let dx = rect.width == 0 ? 0 : (point.x - rect.midX) / rect.width
    let dy = rect.height == 0 ? 0 : (point.y - rect.midY) / rect.height
    if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
    return dy < 0 ? .top : .bottom
  }

  /// The pane nearest `tabID` in `direction` within `layout`: the closest pane that lies that way and
  /// overlaps on the perpendicular axis (so ⌃⌘→ from a tall left pane lands on whichever right pane
  /// shares the most rows). At the split's edge it wraps to the farthest overlapping pane the other
  /// way, as iTerm does. Pure geometry over a reference rect — `nil` if no pane overlaps on that axis.
  public static func adjacentPane<Leaf: Hashable>(
    to tabID: Leaf, direction: PaneDirection, in layout: PaneLayout<Leaf>
  ) -> Leaf? {
    let panes = plan(layout, in: CGRect(x: 0, y: 0, width: 1000, height: 1000)).panes
    guard let from = panes[tabID] else { return nil }
    let horizontal = direction == .left || direction == .right
    var best: (id: Leaf, primary: CGFloat, secondary: CGFloat)?
    var wrap: (id: Leaf, primary: CGFloat, secondary: CGFloat)?
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
      guard overlaps else { continue }
      let primary = horizontal ? abs(r.midX - from.midX) : abs(r.midY - from.midY)
      let secondary = horizontal ? abs(r.midY - from.midY) : abs(r.midX - from.midX)
      if inDirection {
        if best == nil || primary < best!.primary
          || (primary == best!.primary && secondary < best!.secondary)
        {
          best = (id, primary, secondary)
        }
      } else if primary > 0,
        wrap == nil || primary > wrap!.primary
          || (primary == wrap!.primary && secondary < wrap!.secondary)
      {
        wrap = (id, primary, secondary)
      }
    }
    return best?.id ?? wrap?.id
  }

  /// The half-pane band to highlight for a drop on `edge`.
  public static func edgeBand(_ edge: PaneEdge, in rect: CGRect) -> CGRect {
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
