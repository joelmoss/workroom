import Foundation
import WorkroomDomain

/// Standalone terminals in a window (ADR 0077): opening one, and its row going when its terminal
/// closes. The rows themselves are the app's `TerminalsSection`; the tabs are this window's.
extension AppStore: TerminalsSectionHolder {
  func terminalTitles(forTargetID targetID: TargetID) -> [TerminalTitle] {
    terminals.terminalTitles(forTargetID: targetID)
  }

  func holdsTerminals(forTargetID targetID: TargetID) -> Bool {
    terminals.tabCount(forTargetID: targetID) > 0
  }

  /// Raise this window and show `targetID`'s terminal in it, focused: where a notification, or a
  /// selection made in another window, takes you to a standalone terminal.
  func revealTerminals(forTargetID targetID: TargetID) {
    guard let target = terminalTarget(forID: targetID) else { return }
    // `allTabs`: a popped-out terminal is still this window's, raised in its own window.
    let tab = terminals.focusedTab(for: target)?.id ?? terminals.allTabs(for: target).first?.id
    if let window = window(forTab: tab) { raiseWindow(window) }
    openTerminal(targetID: targetID, tabID: tab)
  }

  /// Raise this window (or the pane's own, when it is popped out) and focus its terminal `tabID`.
  func revealTerminal(_ tabID: TerminalTab.ID, inTarget targetID: TargetID) {
    if let window = window(forTab: tabID) { raiseWindow(window) }
    openTerminal(targetID: targetID, tabID: tabID)
  }

  /// Slides the Quick Terminal's panel in, with a new terminal in it when `newTerminal`: its row's
  /// click and its New Terminal in Group. The panel is the group's only holder, so no window opens
  /// one of its terminals.
  func revealQuickTerminal(newTerminal: Bool = false) {
    guard let panel = terminalsSection.quickTerminalHolder as? QuickTerminalHost else {
      // Not made yet: the summon makes it, with its first terminal.
      NotificationCenter.default.post(name: .showQuickTerminal, object: nil)
      return
    }
    if newTerminal { panel.newTerminal(in: panel.target) }
    panel.revealTerminals(forTargetID: .quickTerminal)
  }

  /// The window that holds `sid`'s terminal when it is not this one: a standalone terminal is one
  /// terminal, so selecting it here goes there instead.
  func otherHolder(of sid: SidebarID) -> (any TerminalsSectionHolder)? {
    guard case .standalone = sid, let id = sid.targetID, !holdsTerminals(forTargetID: id)
    else { return nil }
    return terminalsSection.holder(of: id, other: self)
  }

  /// What closing this window asks first (ADR 0077): it holds a standalone terminal, which ends
  /// with it. nil when it holds none.
  var windowClosePrompt: WindowClosePrompt? {
    let held = terminals.activeTargetIDs.filter { $0.isStandaloneTerminal }
    guard !held.isEmpty else { return nil }
    return WindowClosePrompt(
      title: "Close this window?",
      detail: held.count == 1
        ? "It holds a terminal that isn't in a project. Closing the window ends it."
        : "It holds \(held.count) terminals that aren't in a project. Closing the window ends them."
    )
  }

  /// A window closing ends the standalone terminals it holds, and their rows go, and ends its own
  /// terminals in a group: each by its session, so another window's terminals in that group run
  /// on. Not on a quit, which keeps them for the next launch. It stops holding terminals for the
  /// section, so a group it had terminals in is counted without them, and settled: one no other
  /// window holds goes.
  func endStandaloneTerminalsOnClose() async {
    guard !WindowRegistry.shared.isTerminating else { return }
    let groups = terminals.activeTargetIDs.filter(\.isTerminalGroup)
    terminalsSection.unregister(self)
    for id in groups { groupTabsRemoved(id) }
    for id in groups { await terminals.reap(id, endingTargetSessions: false) }
    for id in terminals.activeTargetIDs where id.isStandaloneTerminal {
      await terminals.reap(id)
      terminalsSection.remove(id)
    }
  }

  /// New Standalone Terminal (⌥⌘T), and ⌘T where the selection opens no terminals: a new row just
  /// below the selected one when that is in the Terminals section, else at the section's end,
  /// selected, with its one terminal open in "New terminals open in".
  func newStandaloneTerminal() {
    let id = terminalsSection.addStandalone(after: selectedTargetID?.targetID)
    guard let sid = id.sidebarID, let target = target(for: sid) else { return }
    selectedTargetID = sid
    terminals.addTab(for: target)
    refreshSelectionHasTabs()
  }

  /// Where this window's selection goes when the tabs in `closing` were the last of selected
  /// Terminals-section row `targetID`, and so the row goes: a standalone terminal closed, or a
  /// group's last terminal. The previous place this window showed that is still live
  /// (`previousLiveLocation`), else the nearest row above with terminals in this window, else the
  /// nearest below. nil leaves it to the fallback every target has (`selectFallbackWorkroomAfterEmpty`),
  /// and so does a row that stays: moved, or a group another window still has terminals in.
  /// Read before the close prunes the history and drops the row.
  func closeSuccessor(of targetID: TargetID, closing: Set<TerminalTab.ID>)
    -> (sid: SidebarID, tab: TerminalTab.ID?)?
  {
    guard let sid = targetID.sidebarID, sid.isInTerminalsSection, targetID != .quickTerminal,
      selectedTargetID == sid, terminals.tabCount(forTargetID: targetID) == 0,
      terminals.handingOffTo == nil, !WindowRegistry.shared.isTerminating,
      terminalsSection.contains(targetID), terminalsSection.terminalNames(of: targetID).isEmpty
    else { return nil }
    if let previous = previousLiveLocation(excluding: sid, closing: closing) {
      return (previous.target, previous.tab)
    }
    let ids = terminalsSection.entries.map(\.targetID)
    guard let index = ids.firstIndex(of: targetID) else { return nil }
    let nearest = Array(ids[..<index].reversed()) + ids[(index + 1)...]
    return nearest.first { $0 != .quickTerminal && holdsTerminals(forTargetID: $0) }
      .flatMap(\.sidebarID).map { ($0, nil) }
  }

  /// A standalone terminal's row goes once its terminal has left it in every holder: closed, or
  /// moved into another target. Moving to another window keeps it, and so does a quit, which must
  /// bring it back at the next launch.
  func standaloneTabsRemoved(_ targetID: TargetID) {
    guard case .standalone = targetID, terminals.handingOffTo != targetID,
      !WindowRegistry.shared.isTerminating, terminalsSection.terminalNames(of: targetID).isEmpty
    else { return }
    terminalsSection.remove(targetID)
  }
}

/// What a window asks before it closes (see `AppStore.windowClosePrompt`).
struct WindowClosePrompt: Equatable {
  let title: String
  let detail: String
}
