import CoreGraphics
import Foundation

/// The split groups of one view of panes: the workroom split of a window (`SidebarID` leaves,
/// `AppStore.workroomSplits`) and the terminal split of one target (tab-id leaves,
/// `TerminalPanes`). Both are a LIST of `PaneLayout` trees, disjoint (a leaf belongs to at most
/// one) and each holding at least two leaves, since a lone leaf is "no split". **Array order carries
/// no meaning**: a group is addressed by membership, and a strip places each group's run at its
/// earliest member's slot (`normalized(_:)`).
///
/// Every structural rule both splits share lives here once: which group holds a leaf, the strip
/// order, inserting with move semantics, removing, setting a divider, and when and along which axis
/// a group is evened (issue #126). What the two callers do differently on purpose — the workroom
/// split prunes leaves that no longer resolve and weights each workroom by its terminals; the
/// terminal split does neither — arrives as a `PaneSplitPolicy` on each call.
///
/// Edits return a new value and never hand out an index, so no caller can hold a group index across
/// a mutation (the stale-index class `TerminalPanes.setSplit` once asserted against).
public struct PaneSplitGroups<Leaf: Hashable>: Equatable {
  public private(set) var groups: [PaneLayout<Leaf>]

  public init(_ groups: [PaneLayout<Leaf>] = []) { self.groups = groups }

  public var isEmpty: Bool { groups.isEmpty }

  /// The group `leaf` belongs to, or nil when it isn't grouped. Groups are disjoint, so this is the
  /// one authority on "which group is this leaf in".
  public func group(containing leaf: Leaf) -> PaneLayout<Leaf>? {
    index(containing: leaf).map { groups[$0] }
  }

  /// `member → group index` for every grouped leaf, so a strip can bracket each group's run and tell
  /// a group boundary (member of A next to member of B, or next to a solo chip) from an interior one.
  /// Empty when nothing is grouped. Build it ONCE per render pass and thread it down: it walks every
  /// leaf of every group, and a strip consults it per chip.
  ///
  /// First-group-wins on a repeat leaf, matching `group(containing:)`. Groups are disjoint by
  /// construction, so that can't fire today; the tie-break is here because if it ever did, a
  /// last-wins map would disagree with `group(containing:)` and make `normalized(_:)` emit the same
  /// chip under two group runs — duplicate `ForEach` ids, which SwiftUI renders as garbage rather
  /// than degrading.
  public var groupIndices: [Leaf: Int] {
    var groupOf: [Leaf: Int] = [:]
    for (index, group) in groups.enumerated() {
      for leaf in group.tabIDs where groupOf[leaf] == nil { groupOf[leaf] = index }
    }
    return groupOf
  }

  /// `order` with EACH group's members replaced by that group's tree order, as one contiguous run at
  /// its earliest member's slot. So each bracket is always one run, and strip order always matches
  /// pane order (rearranging panes IS strip reorder). Members missing from `order` are emitted in
  /// their group's run all the same; a caller that shows only some leaves filters afterwards.
  public func normalized(_ order: [Leaf]) -> [Leaf] {
    guard !groups.isEmpty else { return order }
    let groupOf = groupIndices
    var emitted: Set<Int> = []
    var placed: Set<Leaf> = []
    var result: [Leaf] = []
    for leaf in order {
      guard let group = groupOf[leaf] else {
        result.append(leaf)
        continue
      }
      // First member of this group in strip order: emit the whole group here (in tree order) and
      // skip its later members. `placed` keeps a leaf from being emitted twice even if the
      // disjointness invariant ever broke — a duplicate id in a strip is a duplicate `ForEach`
      // identity, which SwiftUI renders as garbage rather than degrading.
      guard emitted.insert(group).inserted else { continue }
      for member in groups[group].tabIDs where placed.insert(member).inserted {
        result.append(member)
      }
    }
    return result
  }

  /// Whether inserting `leaf` beside `anchor` GROWS a group, rather than rearranging within one: a
  /// move across groups, or in from solo. Two members of one group swapping places leave the pane
  /// count, and so every pane floor, unchanged, which is why both fit guards apply only to an
  /// addition.
  public func addsMember(_ leaf: Leaf, beside anchor: Leaf) -> Bool {
    let from = index(containing: leaf)
    return from == nil || from != index(containing: anchor)
  }

  /// Insert `leaf` beside `anchor` on `edge`, with MOVE semantics: `leaf` leaves its current group
  /// first, so dragging an existing pane to a new edge moves it rather than duplicating it. Joins
  /// `anchor`'s group, or seeds a new one from the two of them, leaving every other group untouched.
  ///
  /// Evening (issue #126), each only when `policy` can honour it:
  /// - A genuine move evens the group it LEFT along the axis it left, exactly as a removal does.
  /// - The group it joins is evened along `edge`'s axis.
  /// - A rearrange within one group rebuilds the tree around `leaf` (`A | B | C` with C dropped left
  ///   of A comes out ¼, ¼, ½), so its leaving is not evened; the group is evened once, after the
  ///   insert, along the axis `leaf` joined, or along both when it also left the other one.
  ///
  /// The joined group is evened as `policy.live` sees it. When that even is declined, the group is
  /// stored as grown, unpruned: the workroom split's ghost leaves go on the next sweep instead.
  public func inserting(
    _ leaf: Leaf, beside anchor: Leaf, edge: PaneEdge, policy: PaneSplitPolicy<Leaf>
  ) -> PaneSplitGroups {
    // Read BEFORE the leaf leaves its group: afterwards every move would look like an addition.
    let adds = addsMember(leaf, beside: anchor)
    let leftAxis = adds ? nil : group(containing: leaf)?.axis(around: leaf)
    let evenAxis = adds || leftAxis == edge.orientation ? edge.orientation : nil
    var result = detaching(leaf, evenedBy: adds ? policy : nil)
    if let index = result.index(containing: anchor) {
      let grown = result.groups[index].inserting(
        leaf, beside: anchor, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
      let live = policy.live(grown)
      result.groups[index] =
        live.tabIDs.count >= 2 ? policy.evened(live, along: evenAxis) ?? grown : grown
    } else {
      let dropped = PaneLayout<Leaf>.leaf(leaf)
      let existing = PaneLayout<Leaf>.leaf(anchor)
      let pair = PaneLayout<Leaf>.split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? dropped : existing,
        second: edge.placesDroppedFirst ? existing : dropped)
      result.groups.append(policy.evened(pair, along: edge.orientation) ?? pair)
    }
    return result
  }

  /// Drop `leaf` from whatever group holds it, collapsing that group to the surviving subtree, or
  /// dissolving it when fewer than two leaves would remain. Every other group is untouched. The
  /// survivors' dividers still budget space for the pane that left (`A | B | C` at root 1/3
  /// collapses to `A | B` still at 1/3), so they are evened along the axis it left, when `policy`
  /// can honour it; dividers running the other way stay put. No-op when `leaf` is solo.
  public func removing(_ leaf: Leaf, policy: PaneSplitPolicy<Leaf>) -> PaneSplitGroups {
    detaching(leaf, evenedBy: policy)
  }

  /// `removing(_:policy:)`, evening nothing when `policy` is nil: the rearrange half of `inserting`.
  private func detaching(_ leaf: Leaf, evenedBy policy: PaneSplitPolicy<Leaf>?) -> PaneSplitGroups {
    guard let index = index(containing: leaf) else { return self }
    var result = self
    let group = groups[index]
    if let collapsed = group.removingLeaf(leaf), collapsed.tabIDs.count >= 2 {
      result.groups[index] =
        policy?.evened(collapsed, along: group.axis(around: leaf)) ?? collapsed
    } else {
      result.groups.remove(at: index)
    }
    return result
  }

  /// The group holding `leaf` evened along `axis` (nil: both ways), when `policy` can honour it: its
  /// leaves' weights changed (the workroom split, when a workroom's terminals change). Unchanged
  /// when `leaf` is solo or the even is declined; a caller whose store publishes compares first.
  public func evening(
    groupOf leaf: Leaf, along axis: SplitOrientation?, policy: PaneSplitPolicy<Leaf>
  ) -> PaneSplitGroups {
    guard let index = index(containing: leaf),
      let evened = policy.evened(groups[index], along: axis)
    else { return self }
    var result = self
    result.groups[index] = evened
    return result
  }

  /// `tree` stored over the group `member` belongs to, or appended as a new group when `member` is
  /// nil or solo; a `tree` under two leaves deletes `member`'s group instead. Not evened. For
  /// putting a group back as it was, around a leaf that replaced one of its members (a run tab's
  /// restart, issue #40).
  public func storing(_ tree: PaneLayout<Leaf>, overGroupOf member: Leaf?) -> PaneSplitGroups {
    var result = self
    let index = member.flatMap { self.index(containing: $0) }
    guard tree.tabIDs.count >= 2 else {
      if let index { result.groups.remove(at: index) }
      return result
    }
    if let index {
      result.groups[index] = tree
    } else {
      result.groups.append(tree)
    }
    return result
  }

  /// Set the divider ratio of split node `splitID`, wherever it lives (node ids are unique across
  /// every group). nil when no group holds that node, so a caller whose store publishes writes
  /// nothing.
  public func settingRatio(_ ratio: CGFloat, forSplit splitID: UUID) -> PaneSplitGroups? {
    guard let index = groups.firstIndex(where: { $0.containsSplit(splitID) }) else { return nil }
    var result = self
    result.groups[index] = groups[index].settingRatio(ratio, forSplit: splitID)
    return result
  }

  /// Whether inserting `leaf` beside `anchor` on `edge` leaves every pane at its floor, judged on
  /// the group as it will be STORED, in `policy.space`. nil when that space is unmeasured, for the
  /// caller's pre-layout fallback (the anchor's own rect, `PaneTreeLayout.canSplit`).
  ///
  /// Group-aware (issue #126): with auto-even on, adding a pane redistributes the whole group rather
  /// than halving the anchor, so a pane dragged narrow must not veto a split the group has room for.
  /// The prospective tree goes through the same `policy.evened` step the commit uses, so the guard
  /// and the commit cannot disagree. The base is the anchor's group as `policy.live` sees it: a
  /// leaf the renderer no longer shows must not take up room. `leaf` may be a placeholder for a
  /// pane that does not exist yet (⌘D), since without leaf weights only the count matters.
  public func admits(
    _ leaf: Leaf, beside anchor: Leaf, edge: PaneEdge, policy: PaneSplitPolicy<Leaf>
  ) -> Bool? {
    guard let space = policy.space, space.width > 0, space.height > 0 else { return nil }
    let base = group(containing: anchor).map(policy.live) ?? .leaf(anchor)
    let prospective = base.inserting(
      leaf, beside: anchor, orientation: edge.orientation,
      newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    let stored = policy.evened(prospective, along: edge.orientation) ?? prospective
    return PaneTreeLayout.fitsEveryPane(stored, in: space, notWorseThan: base, splitting: anchor)
  }

  /// Index into `groups` of the group holding `leaf`. Private: an index is valid only until the
  /// next edit, so it must not leave this type.
  private func index(containing leaf: Leaf) -> Int? {
    groups.firstIndex { $0.contains(leaf) }
  }
}

extension PaneSplitGroups: Sendable where Leaf: Sendable {}

/// How one caller's splits are evened and judged: the part of `PaneSplitGroups`' rules the two
/// splits differ on, on purpose.
public struct PaneSplitPolicy<Leaf: Hashable> {
  /// The container the group is laid out in; nil before the first layout pass, which evens
  /// optimistically and leaves fit checks to the caller's fallback.
  public var space: CGRect?
  /// The "Automatically resize splits evenly" setting (issue #126).
  public var autoEven: Bool
  /// Each leaf's weight along an axis, as `PaneLayout.equalized` takes it: the workroom split
  /// counts a workroom's terminals; nil weighs every leaf one.
  public var leafSlots: ((Leaf, SplitOrientation) -> Int)?
  /// The group as the renderer shows it: the workroom split drops workrooms that no longer resolve
  /// (deleted elsewhere, until the next sweep prunes them). Identity by default.
  public var live: (PaneLayout<Leaf>) -> PaneLayout<Leaf>

  public init(
    space: CGRect?, autoEven: Bool, leafSlots: ((Leaf, SplitOrientation) -> Int)? = nil,
    live: @escaping (PaneLayout<Leaf>) -> PaneLayout<Leaf> = { $0 }
  ) {
    self.space = space
    self.autoEven = autoEven
    self.leafSlots = leafSlots
    self.live = live
  }

  /// `tree` evened along `axis` (nil: both ways), weighted by `leafSlots`; nil when the setting is
  /// off or `space` cannot render the even (`PaneTreeLayout.evened`).
  public func evened(_ tree: PaneLayout<Leaf>, along axis: SplitOrientation?) -> PaneLayout<Leaf>? {
    PaneTreeLayout.evened(tree, in: space, enabled: autoEven, along: axis, leafSlots: leafSlots)
  }
}
