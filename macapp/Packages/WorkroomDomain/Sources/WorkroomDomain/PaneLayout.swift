import Foundation

/// Split-pane layout, generic over the leaf identity (issue #3 terminal panes; issue #23 workroom
/// panes). Two instantiations exist:
/// - `PaneLayout<TerminalTab.ID>` (alias `TerminalPaneLayout`) — a terminal target's split of tabs.
/// - `PaneLayout<SidebarID>` — the workroom-into-workroom split (issue #23 follow-up).
///
/// Both instantiations hold a LIST of these trees: several disjoint groups at once, each with ≥2
/// leaves and at most one visible — a `PaneSplitGroups`, whose rules both share, held per terminal
/// target by `TerminalSessions` and per window by `AppStore`. Either way a
/// leaf REFERENCES its content by id — it does not own the view/surface (the tab / target detail does).
/// That keeps this a pure value tree: `Equatable`, and unit-testable with no AppKit/libghostty in sight.
///
/// ```
///   split(h, 0.5, leaf(B), split(v, 0.6, leaf(C), leaf(D)))
///
///   ┌─────────┬───────────────┐      tabIDs == [B, C, D]   (left→right / top→bottom)
///   │         │      C         │      firstTabID == B
///   │    B    ├───────────────┤      a lone leaf is NOT a PaneLayout — it's just "no split".
///   │         │      D         │      Split nodes carry a stable `id` so a divider can address
///   └─────────┴───────────────┘      exactly one node when the user drags it (resize).
/// ```
///
/// All structural edits go through the pure transforms below (`inserting` / `removingLeaf` /
/// `settingRatio` / `equalized`); callers never walk the tree inline (DRY). Anything that needs a
/// MEASURED answer (does this still fit? would evening actually render evenly?) belongs on
/// `PaneTreeLayout` instead — this type has no geometry.
public enum SplitOrientation: Hashable, CaseIterable, Sendable {
  case horizontal  // panes side by side — a vertical divider   (⌘D "split right")
  case vertical  // panes stacked    — a horizontal divider (⇧⌘D "split down")
}

/// Which edge of a pane a leaf was dropped on (drag-to-split, issue #3). Resolves to the split
/// orientation and which side the dropped leaf lands on.
public enum PaneEdge: Sendable {
  case top, right, bottom, left

  public var orientation: SplitOrientation {
    self == .left || self == .right ? .horizontal : .vertical
  }
  /// True when the dropped leaf should become the leading/top child (a left or top drop).
  public var placesDroppedFirst: Bool { self == .left || self == .top }
}

/// A direction to move keyboard focus between panes (⌃⌘arrows, issue #3 Phase 3).
public enum PaneDirection: Sendable { case left, right, up, down }

/// Ratio sanitisation, split off the generic `PaneLayout` so it can be called without a leaf type in
/// context (a bare `PaneLayout.sanitize` on the generic enum can't infer `Leaf`).
public enum PaneRatio {
  /// Keep a stored ratio strictly inside (0, 1) so a node can never be exactly collapsed in the model;
  /// the renderer applies the real min-pane (points-based) clamp on top.
  public static func sanitize(_ ratio: CGFloat) -> CGFloat { min(0.999, max(0.001, ratio)) }
}

public indirect enum PaneLayout<Leaf: Hashable>: Equatable {
  case leaf(Leaf)
  case split(
    id: UUID, orientation: SplitOrientation, ratio: CGFloat, first: PaneLayout<Leaf>,
    second: PaneLayout<Leaf>)

  /// Leaf ids in reading order (left→right / top→bottom). Always non-empty; a strip renders the
  /// split's members as this contiguous run.
  public var tabIDs: [Leaf] {
    switch self {
    case .leaf(let id):
      return [id]
    case .split(_, _, _, let first, let second):
      return first.tabIDs + second.tabIDs
    }
  }

  /// The first leaf in reading order. Safe: every node has ≥1 leaf.
  public var firstTabID: Leaf { tabIDs[0] }

  public func contains(_ id: Leaf) -> Bool { tabIDs.contains(id) }

  /// The stored divider fraction of the split node with `splitID`, or nil if this tree has no such
  /// node. Lets a live drag notice that its node moved for some other reason (issue #126).
  public func ratio(forSplit splitID: UUID) -> CGFloat? {
    switch self {
    case .leaf:
      return nil
    case .split(let id, _, let ratio, let first, let second):
      if id == splitID { return ratio }
      return first.ratio(forSplit: splitID) ?? second.ratio(forSplit: splitID)
    }
  }

  /// The orientation of the split directly holding leaf `id`: the axis that leaf's removal frees
  /// space along. nil if `id` isn't a leaf of this tree, or the tree is that lone leaf.
  public func axis(around id: Leaf) -> SplitOrientation? {
    guard case .split(_, let o, _, let first, let second) = self else { return nil }
    for child in [first, second] {
      if case .leaf(let leaf) = child, leaf == id { return o }
    }
    return first.axis(around: id) ?? second.axis(around: id)
  }

  /// Whether this (sub)tree holds the split NODE `splitID` — the divider-addressing counterpart to
  /// `contains(_:)`. Lets a caller holding several trees (the window's workroom split groups, issue #23
  /// follow-up) find which one owns the divider being dragged, instead of rewriting them all.
  public func containsSplit(_ splitID: UUID) -> Bool {
    switch self {
    case .leaf:
      return false
    case .split(let id, _, _, let first, let second):
      return id == splitID || first.containsSplit(splitID) || second.containsSplit(splitID)
    }
  }

  // MARK: Pure transforms

  /// Replace `.leaf(beside)` with a new split of `beside` and `newLeaf` in `orientation`. `newLeafFirst`
  /// puts the new pane on the leading/top side (a left/up drop); otherwise trailing/bottom (right/down).
  /// `ratio` is the leading child's fraction. Returns the tree unchanged if `beside` isn't a leaf here
  /// (defensive — callers pass a leaf they located).
  public func inserting(
    _ newLeaf: Leaf, beside: Leaf, orientation: SplitOrientation,
    newLeafFirst: Bool, ratio: CGFloat
  ) -> PaneLayout<Leaf> {
    switch self {
    case .leaf(let id):
      guard id == beside else { return self }
      let existing = PaneLayout<Leaf>.leaf(id)
      let added = PaneLayout<Leaf>.leaf(newLeaf)
      return .split(
        id: UUID(), orientation: orientation, ratio: ratio,
        first: newLeafFirst ? added : existing,
        second: newLeafFirst ? existing : added)
    case .split(let sid, let o, let r, let first, let second):
      return .split(
        id: sid, orientation: o, ratio: r,
        first: first.inserting(
          newLeaf, beside: beside, orientation: orientation, newLeafFirst: newLeafFirst,
          ratio: ratio),
        second: second.inserting(
          newLeaf, beside: beside, orientation: orientation, newLeafFirst: newLeafFirst,
          ratio: ratio))
    }
  }

  /// Remove `id` and collapse its parent split to the surviving sibling subtree (its ratio drops out).
  /// Returns the collapsed tree — which may be a single `.leaf` when a two-pane split loses one member
  /// (the caller then dissolves the split: a lone leaf is "no split"). Returns `nil` only when the whole
  /// (sub)tree WAS `.leaf(id)`. Returns the tree unchanged if `id` isn't present.
  public func removingLeaf(_ id: Leaf) -> PaneLayout<Leaf>? {
    switch self {
    case .leaf(let leafID):
      return leafID == id ? nil : self
    case .split(let sid, let o, let r, let first, let second):
      guard contains(id) else { return self }
      if let newFirst = first.removingLeaf(id) {
        guard let newSecond = second.removingLeaf(id) else { return newFirst }
        return .split(id: sid, orientation: o, ratio: r, first: newFirst, second: newSecond)
      }
      // `first` was (or collapsed to) nothing — promote the sibling.
      return second.removingLeaf(id) ?? second
    }
  }

  /// Swap one leaf's identity in place — same slot, orientation, ratio, and siblings — returning the
  /// tree unchanged if `old` isn't present. Lets a tab be respawned into a split member's exact
  /// position (issue #40): a run-command restart closes the old run tab (freeing its port via SIGHUP)
  /// and the replacement takes its slot, instead of the split collapsing and the new pane reappearing
  /// solo outside it.
  public func replacingLeaf(_ old: Leaf, with new: Leaf) -> PaneLayout<Leaf> {
    switch self {
    case .leaf(let id):
      return id == old ? .leaf(new) : self
    case .split(let sid, let o, let r, let first, let second):
      return .split(
        id: sid, orientation: o, ratio: r,
        first: first.replacingLeaf(old, with: new),
        second: second.replacingLeaf(old, with: new))
    }
  }

  /// Set the divider fraction of the split node with `splitID`. No-op if not found. The view owns the
  /// usable clamp (min-pane is a points concern); this stores the value with only a sanity bound.
  public func settingRatio(_ ratio: CGFloat, forSplit splitID: UUID) -> PaneLayout<Leaf> {
    switch self {
    case .leaf:
      return self
    case .split(let sid, let o, let r, let first, let second):
      if sid == splitID {
        return .split(
          id: sid, orientation: o, ratio: PaneRatio.sanitize(ratio), first: first, second: second)
      }
      return .split(
        id: sid, orientation: o, ratio: r,
        first: first.settingRatio(ratio, forSplit: splitID),
        second: second.settingRatio(ratio, forSplit: splitID))
    }
  }

  /// This tree as a divider drag shows it: `ratio` on the split node `splitID`, while that node
  /// still holds `stored`, its ratio when the drag began. Once the node has moved for another
  /// reason (a re-even landing mid-drag, issue #126), or is gone, the tree as it is, so the
  /// divider re-anchors on the new value instead of replaying its stale start. Both splits'
  /// dividers draw through this while a drag is live and write their ratio only on release.
  public func showingDrag(_ ratio: CGFloat, forSplit splitID: UUID, from stored: CGFloat)
    -> PaneLayout<Leaf>
  {
    guard self.ratio(forSplit: splitID) == stored else { return self }
    return settingRatio(ratio, forSplit: splitID)
  }

  /// Number of leaves in this (sub)tree (issue #83). A lone leaf is 1; a split is the sum of its
  /// children. Kept for callers that need the true pane count; `equalized()` deliberately does NOT
  /// weight by it — see `slots(along:)`.
  public var leafCount: Int {
    switch self {
    case .leaf:
      return 1
    case .split(_, _, _, let first, let second):
      return first.leafCount + second.leafCount
    }
  }

  /// How many divisions this (sub)tree contributes ALONG `orientation` — the weight `equalized()`
  /// shares space by. A leaf is one. A split of the same orientation is the sum of its children (an
  /// `A | B | C` chain is three columns). A split of the OTHER orientation is one: its internal
  /// divider runs the other way, so whatever it does inside never changes how much of this axis it
  /// needs.
  ///
  /// That last case is the whole point, and weighting by `leafCount` got it wrong: splitting the
  /// bottom half of `A / B` sideways made the tree `A / (B | C)`, and three leaves against one gave
  /// the untouched pane A a third of the HEIGHT it had before. Splitting one pane must never resize
  /// a pane in a different row (issue #126).
  ///
  /// `leafSlots` weights each leaf (at least one): a workroom showing two terminals side by side
  /// counts as two columns, so evening the workroom split gives every terminal the same width. A
  /// weighted split of the other orientation counts as its widest child rather than one, so a
  /// column of stacked workrooms makes room for the most terminals any of them shows across.
  public func slots(
    along orientation: SplitOrientation, leafSlots: ((Leaf, SplitOrientation) -> Int)? = nil
  ) -> Int {
    switch self {
    case .leaf(let leaf):
      return max(1, leafSlots?(leaf, orientation) ?? 1)
    case .split(_, let o, _, let first, let second):
      guard o == orientation || leafSlots != nil else { return 1 }
      let firstSlots = first.slots(along: orientation, leafSlots: leafSlots)
      let secondSlots = second.slots(along: orientation, leafSlots: leafSlots)
      return o == orientation ? firstSlots + secondSlots : max(firstSlots, secondSlots)
    }
  }

  /// The most panes any single row (`.horizontal`) or column (`.vertical`) of this tree holds: a
  /// same-axis split adds its children, an other-axis split takes the larger. `A / (B | C)` is two
  /// columns wide, because its bottom row needs room for two panes side by side, where
  /// `slots(along:)` counts it as one.
  public func maxSlots(along orientation: SplitOrientation) -> Int {
    guard case .split(_, let o, _, let first, let second) = self else { return 1 }
    let firstSlots = first.maxSlots(along: orientation)
    let secondSlots = second.maxSlots(along: orientation)
    return o == orientation ? firstSlots + secondSlots : max(firstSlots, secondSlots)
  }

  /// "Resize splits evenly" (issue #83, reshaped by #126): rebalance every split node so the panes
  /// it divides get an even share of that node's axis. Each node's ratio becomes its first child's
  /// share of the SAME-AXIS slot count, so `A | B | C` (one chain) lands on thirds, while a nested
  /// split of the other axis counts as one and leaves its parent's divider where it was.
  ///
  /// The result is the grid you'd draw by hand: every row splits its height evenly, every column
  /// its width, and a 2×2 tree renders four identical panes. It is NOT equal-area in a mixed tree —
  /// a full-width pane above two side-by-side ones is twice their area, exactly as it is in every
  /// other tiling terminal, and that is the point: the alternative resized panes the user never
  /// touched. The renderer subtracts a divider per split and rounds, so visible sizes land within a
  /// divider-thickness of even — sub-character drift on a terminal, deliberately not corrected here.
  ///
  /// `axis` limits the rebalance to dividers of that orientation, keeping every other divider where
  /// it is: adding or removing a pane in a left/right split must never change any pane's height,
  /// nor in a top/bottom split any pane's width. nil evens every divider.
  ///
  /// `leafSlots` weights each leaf as `slots(along:leafSlots:)` does.
  public func equalized(
    along axis: SplitOrientation? = nil,
    leafSlots: ((Leaf, SplitOrientation) -> Int)? = nil
  ) -> PaneLayout<Leaf> {
    switch self {
    case .leaf:
      return self
    case .split(let sid, let o, let r, let first, let second):
      let ours = first.slots(along: o, leafSlots: leafSlots)
      let theirs = second.slots(along: o, leafSlots: leafSlots)
      let ratio = axis == nil || axis == o ? CGFloat(ours) / CGFloat(ours + theirs) : r
      return .split(
        id: sid, orientation: o, ratio: PaneRatio.sanitize(ratio),
        first: first.equalized(along: axis, leafSlots: leafSlots),
        second: second.equalized(along: axis, leafSlots: leafSlots))
    }
  }
}

extension PaneLayout: Sendable where Leaf: Sendable {}
