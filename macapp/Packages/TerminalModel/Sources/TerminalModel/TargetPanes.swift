import Observation

/// One target's layout in one window: its `PaneState` (order, split groups, focus, counter) over
/// tab ids. The tabs themselves are app-wide, in `TabRecords`, so two windows showing one workroom
/// each arrange their own tabs here (#444 Q12), and a move between windows shifts ids from one
/// window's layout to the other's while every tab stays where it is (D2 as revised by eng review
/// D4). Each window's `TerminalPanes` holds one per target it shows, in a dictionary that changes only
/// when a target is added or removed, so a change here is this target's alone (eng review D3).
///
/// Views observe it through Observation: a view that reads one target's arrangement re-renders
/// when it changes, and not when another target's does (plan step 3.5).
///
/// Every write goes through the methods below, and each calls `willChange` first. That is how the
/// sessions' `paneWillChange` fires BEFORE every layout change, which `AppStore`'s saved-layout dirty
/// mark hangs off.
@MainActor
@Observable
public final class TargetPanes<ID: Hashable> {
  /// The ids-only arrangement: `order` is the list of every tab the target holds here.
  public private(set) var state = PaneState<ID>()
  /// Whether the target holds any tab here. Stored, and written only when it flips, so a reader
  /// that asks only this (whether a workroom has a terminal, across windows) re-renders when a
  /// target gains its first tab or loses its last, and not on any other change.
  public private(set) var hasTabs = false
  /// The tabs `order` names, stored and written only when that set changes, as `hasTabs` is: a
  /// reader looking one tab up re-renders as tabs join or leave the target, and not on a focus
  /// move, a divider commit or a reorder.
  private var members: Set<ID> = []

  @ObservationIgnored private let willChange: () -> Void

  public init(willChange: @escaping () -> Void) {
    self.willChange = willChange
  }

  /// Whether the target holds `id` here, detached panes included.
  public func holds(_ id: ID) -> Bool { members.contains(id) }

  /// Edit the arrangement.
  @discardableResult
  public func updateState<Result>(_ body: (inout PaneState<ID>) -> Result) -> Result {
    willChange()
    let result = body(&state)
    noteMembership()
    return result
  }

  /// Every tab gone, the counter kept (`PaneState.emptied`): the target is emptied, not forgotten.
  public func empty() {
    willChange()
    state = state.emptied()
    noteMembership()
  }

  private func noteMembership() {
    let has = !state.order.isEmpty
    if has != hasTabs { hasTabs = has }
    let ids = Set(state.order)
    if ids != members { members = ids }
  }
}
