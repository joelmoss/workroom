import Observation
import TerminalModel

/// One target's panes in one window: its tab records and its `PaneState` (order, split groups,
/// focus, counter). `TerminalSessions` holds one per target it shows, in a dictionary that changes
/// only when a target is added or removed, so a change here is this target's alone (eng review D3).
///
/// Every write goes through the methods below, and each calls `willChange` first. That is how the
/// sessions' `objectWillChange` still fires BEFORE every pane mutation, as it did when this state
/// was `@Published` dictionaries on the sessions: `AppStore`'s saved-layout dirty mark, the
/// `@ObservedObject` views and the menu commands all hang off it, until the sessions move to
/// `@Observable` (plan step 3.5).
@MainActor
@Observable
final class TargetPanes {
  /// Every tab of the target, by id: the single source of truth for surfaces and titles. A tab is a
  /// value, so a live update replaces its record here.
  private(set) var tabs: [TerminalTab.ID: TerminalTab] = [:]
  /// The ids-only arrangement of those tabs.
  private(set) var state = PaneState<TerminalTab.ID>()

  @ObservationIgnored private let willChange: () -> Void

  init(willChange: @escaping () -> Void) {
    self.willChange = willChange
  }

  /// The tabs in `normalizedOrder`, detached panes included.
  var orderedTabs: [TerminalTab] { state.normalizedOrder.compactMap { tabs[$0] } }

  /// Store `tab`, adding it or replacing the record with its id.
  func setTab(_ tab: TerminalTab) {
    willChange()
    tabs[tab.id] = tab
  }

  /// Drop the record of `id`.
  func removeTab(_ id: TerminalTab.ID) {
    willChange()
    tabs[id] = nil
  }

  /// Replace every tab record at once (a restore).
  func setTabs(_ records: [TerminalTab.ID: TerminalTab]) {
    willChange()
    tabs = records
  }

  /// Edit the arrangement.
  @discardableResult
  func updateState<Result>(_ body: (inout PaneState<TerminalTab.ID>) -> Result) -> Result {
    willChange()
    return body(&state)
  }

  /// Every tab gone, the counter kept (`PaneState.emptied`): the target is emptied, not forgotten.
  func empty() {
    willChange()
    tabs = [:]
    state = state.emptied()
  }
}
