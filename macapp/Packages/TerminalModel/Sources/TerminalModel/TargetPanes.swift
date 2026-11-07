import Observation

/// One target's panes in one window: its tab records and its `PaneState` (order, split groups,
/// focus, counter). The app's `TerminalSessions` holds one per target it shows, in a dictionary that
/// changes only when a target is added or removed, so a change here is this target's alone (eng
/// review D3).
///
/// Views observe it through Observation: a view that reads one target's tabs or arrangement
/// re-renders when they change, and not when another target's do (plan step 3.5).
///
/// Every write goes through the methods below, and each calls `willChange` first. That is how the
/// sessions' `paneWillChange` fires BEFORE every pane mutation, which `AppStore`'s saved-layout
/// dirty mark hangs off.
///
/// Generic over the tab record, which is the app's (`TerminalTab`): a record is a value whose id is
/// the one `PaneState` arranges, and these rules need nothing else of it.
@MainActor
@Observable
public final class TargetPanes<Tab: Identifiable> {
  /// Every tab of the target, by id: the single source of truth for titles and content. A tab is a
  /// value, so a live update replaces its record here.
  public private(set) var tabs: [Tab.ID: Tab] = [:]
  /// The ids-only arrangement of those tabs.
  public private(set) var state = PaneState<Tab.ID>()

  @ObservationIgnored private let willChange: () -> Void

  public init(willChange: @escaping () -> Void) {
    self.willChange = willChange
  }

  /// The tabs in `normalizedOrder`, detached panes included.
  public var orderedTabs: [Tab] { state.normalizedOrder.compactMap { tabs[$0] } }

  /// Store `tab`, adding it or replacing the record with its id.
  public func setTab(_ tab: Tab) {
    willChange()
    tabs[tab.id] = tab
  }

  /// Drop the record of `id`.
  public func removeTab(_ id: Tab.ID) {
    willChange()
    tabs[id] = nil
  }

  /// Replace every tab record at once (a restore).
  public func setTabs(_ records: [Tab.ID: Tab]) {
    willChange()
    tabs = records
  }

  /// Edit the arrangement.
  @discardableResult
  public func updateState<Result>(_ body: (inout PaneState<Tab.ID>) -> Result) -> Result {
    willChange()
    return body(&state)
  }

  /// Every tab gone, the counter kept (`PaneState.emptied`): the target is emptied, not forgotten.
  public func empty() {
    willChange()
    tabs = [:]
    state = state.emptied()
  }
}
