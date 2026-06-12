import Foundation

/// Split-pane layout, generic over the leaf identity (issue #3 terminal panes; issue #23 workroom
/// panes). Two instantiations exist:
/// - `PaneLayout<TerminalTab.ID>` (alias `TerminalPaneLayout`) — a terminal target's split of tabs.
/// - `PaneLayout<SidebarID>` — the workroom-into-workroom split (issue #23 follow-up).
///
/// The model is **single-layout**: a container has at most ONE split at a time, plus solo leaves. A
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
/// `settingRatio`); callers never walk the tree inline (DRY).
enum SplitOrientation: Equatable {
  case horizontal  // panes side by side — a vertical divider   (⌘D "split right")
  case vertical  // panes stacked    — a horizontal divider (⇧⌘D "split down")
}

/// Which edge of a pane a leaf was dropped on (drag-to-split, issue #3). Resolves to the split
/// orientation and which side the dropped leaf lands on.
enum PaneEdge {
  case top, right, bottom, left

  var orientation: SplitOrientation { self == .left || self == .right ? .horizontal : .vertical }
  /// True when the dropped leaf should become the leading/top child (a left or top drop).
  var placesDroppedFirst: Bool { self == .left || self == .top }
}

/// A direction to move keyboard focus between panes (⌃⌘arrows, issue #3 Phase 3).
enum PaneDirection { case left, right, up, down }

/// Ratio sanitisation, split off the generic `PaneLayout` so it can be called without a leaf type in
/// context (a bare `PaneLayout.sanitize` on the generic enum can't infer `Leaf`).
enum PaneRatio {
  /// Keep a stored ratio strictly inside (0, 1) so a node can never be exactly collapsed in the model;
  /// the renderer applies the real min-pane (points-based) clamp on top.
  static func sanitize(_ ratio: CGFloat) -> CGFloat { min(0.999, max(0.001, ratio)) }
}

indirect enum PaneLayout<Leaf: Hashable>: Equatable {
  case leaf(Leaf)
  case split(
    id: UUID, orientation: SplitOrientation, ratio: CGFloat, first: PaneLayout<Leaf>,
    second: PaneLayout<Leaf>)

  /// Leaf ids in reading order (left→right / top→bottom). Always non-empty; a strip renders the
  /// split's members as this contiguous run.
  var tabIDs: [Leaf] {
    switch self {
    case .leaf(let id):
      return [id]
    case .split(_, _, _, let first, let second):
      return first.tabIDs + second.tabIDs
    }
  }

  /// The first leaf in reading order. Safe: every node has ≥1 leaf.
  var firstTabID: Leaf { tabIDs[0] }

  func contains(_ id: Leaf) -> Bool { tabIDs.contains(id) }

  // MARK: Pure transforms

  /// Replace `.leaf(beside)` with a new split of `beside` and `newLeaf` in `orientation`. `newLeafFirst`
  /// puts the new pane on the leading/top side (a left/up drop); otherwise trailing/bottom (right/down).
  /// `ratio` is the leading child's fraction. Returns the tree unchanged if `beside` isn't a leaf here
  /// (defensive — callers pass a leaf they located).
  func inserting(
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
  func removingLeaf(_ id: Leaf) -> PaneLayout<Leaf>? {
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
  func replacingLeaf(_ old: Leaf, with new: Leaf) -> PaneLayout<Leaf> {
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
  func settingRatio(_ ratio: CGFloat, forSplit splitID: UUID) -> PaneLayout<Leaf> {
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
}

/// The terminal split's concrete instantiation (issue #3): leaves are tab ids. Keeps terminal call
/// sites reading unchanged after the generic refactor (issue #23 needs `PaneLayout<SidebarID>`).
typealias TerminalPaneLayout = PaneLayout<TerminalTab.ID>
