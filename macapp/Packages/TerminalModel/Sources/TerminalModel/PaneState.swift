import WorkroomDomain

/// One target's panes in one window, by id only: the strip order, the split groups, the focused
/// tab and the "Terminal N" counter. The tabs themselves (surfaces, titles, content) are the app's,
/// held beside this value, so every rule here reads and writes ids alone and is a plain value edit.
///
/// Generic over the id, as `PaneSplitGroups` is: the app's ids are tab UUIDs, and the rules need
/// nothing of them but equality.
///
/// A detached pane (in its own window, issue #172) stays in `order`, so a saved layout keeps its
/// strip slot, and is never in `splits`. Which tabs are detached is the window's to know, so the
/// rules that leave them out take the set.
public struct PaneState<ID: Hashable>: Equatable {
  /// The strip order (loose): every tab the target owns, detached ones included. The displayed
  /// order normalises it so each group's members are one contiguous run (`normalizedOrder`).
  public var order: [ID]
  /// The split groups: disjoint, each of at least two leaves, and in no meaningful order (a group
  /// is addressed by membership). Empty when nothing is grouped. The rules are `PaneSplitGroups`'.
  public var splits: PaneSplitGroups<ID>
  /// The focused (selected) tab: it, plus its group when it is in one, is what the target shows.
  public var focused: ID?
  /// The last "Terminal N" number handed out, so titles stay stable across closes. Nil until the
  /// target numbers its first terminal (a target of content tabs only never does).
  public private(set) var counter: Int?

  public init(
    order: [ID] = [], splits: PaneSplitGroups<ID> = PaneSplitGroups(), focused: ID? = nil,
    counter: Int? = nil
  ) {
    self.order = order
    self.splits = splits
    self.focused = focused
    self.counter = counter
  }

  // MARK: Order

  /// Strip order with EACH group's members as one contiguous run in its tree order, at its
  /// earliest member's slot (`PaneSplitGroups.normalized`), detached panes included. A fixed point:
  /// feeding it back in as `order` reproduces it, so it is safe to persist.
  public var normalizedOrder: [ID] { splits.normalized(order) }

  /// `normalizedOrder` without `detached`: what the strip and the layout show.
  public func displayedOrder(hiding detached: Set<ID>) -> [ID] {
    guard !detached.isEmpty else { return normalizedOrder }
    return normalizedOrder.filter { !detached.contains($0) }
  }

  /// Put `id` right after `other` in the loose order, or at the end when `other` is not in it.
  /// Moves `id` when it is already there. Display normalises a group's run anyway.
  public mutating func place(_ id: ID, after other: ID) {
    order.removeAll { $0 == id }
    if let index = order.firstIndex(of: other) {
      order.insert(id, at: index + 1)
    } else {
      order.append(id)
    }
  }

  /// Move `id` to `index` in the loose order, clamped to its bounds. No-op when `id` is not in it.
  public mutating func move(_ id: ID, toIndex index: Int) {
    guard let from = order.firstIndex(of: id) else { return }
    order.remove(at: from)
    order.insert(id, at: max(0, min(index, order.count)))
  }

  /// Drop `id` from the order and from whatever group holds it (`ungroup`). Focus is the caller's:
  /// it picks the successor (`closeSuccessor`) before the removal, since that reads the order.
  public mutating func remove(_ id: ID, policy: PaneSplitPolicy<ID>) {
    order.removeAll { $0 == id }
    ungroup(id, policy: policy)
  }

  // MARK: Splits and focus

  /// The group on screen: the one holding the focused tab, or nil when that tab is solo. A group
  /// whose members are all unfocused persists but is not shown.
  public var visibleGroup: PaneLayout<ID>? { focused.flatMap(splits.group(containing:)) }

  /// How many panes the target shows across each axis: the widest row and tallest column
  /// (`maxSlots`) of the visible group, or one each way for a solo tab.
  public var shownSlots: [SplitOrientation: Int] {
    let shown = visibleGroup
    return Dictionary(
      uniqueKeysWithValues: SplitOrientation.allCases.map { ($0, shown?.maxSlots(along: $0) ?? 1) })
  }

  /// Drop `id` from its group (`PaneSplitGroups.removing`): the group collapses to its survivors,
  /// evened along the axis `id` left, or dissolves below two. No-op when `id` is solo.
  public mutating func ungroup(_ id: ID, policy: PaneSplitPolicy<ID>) {
    guard splits.group(containing: id) != nil else { return }
    splits = splits.removing(id, policy: policy)
  }

  /// The tab to focus once `id` leaves: the most recent of `recency` (most recent first) still
  /// shown, else the shown neighbour that slides into its slot, else nil when nothing else shows.
  ///
  /// When `id` is a split member, only the members that survive it are candidates, the lone
  /// survivor of a two-pane group included. Focus drives what is on screen, so landing on a recent
  /// tab from outside the group would sweep a pane the user was just looking at off screen.
  public func closeSuccessor(of id: ID, hiding detached: Set<ID>, recency: [ID]) -> ID? {
    let shown = displayedOrder(hiding: detached)
    let remaining = shown.filter { $0 != id }
    guard !remaining.isEmpty else { return nil }
    // Unfiltered on member count, unlike `ungroup`: the lone survivor of a two-pane group is
    // exactly the pane that was on screen beside the one leaving.
    let candidates = splits.group(containing: id)?.removingLeaf(id)?.tabIDs ?? remaining
    if let recent = recency.first(where: candidates.contains) { return recent }
    // Positional fallback, measured within the candidates, so a surviving group's neighbour is one
    // of its own members, not whatever sits after its run on screen.
    let slots = shown.filter { $0 == id || candidates.contains($0) }
    guard let index = slots.firstIndex(of: id) else { return candidates.first }
    let after = slots.filter { $0 != id }
    return after[min(index, after.count - 1)]
  }

  // MARK: Whole state

  /// This state with every tab gone but the counter kept: what a target whose tabs all left (a
  /// move to another window) holds, so the next "Terminal N" still continues the numbering.
  public func emptied() -> PaneState { PaneState(counter: counter) }

  /// Hand out the next "Terminal N" number.
  public mutating func numberNextTerminal() -> Int {
    let next = (counter ?? 0) + 1
    counter = next
    return next
  }

  /// Raise the counter to at least `floor`: a restored or adopted target continues the higher of
  /// its saved numbering and what this window has already handed out.
  public mutating func raiseCounter(to floor: Int) {
    counter = max(floor, counter ?? 0)
  }
}

extension PaneState: Sendable where ID: Sendable {}
