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
    let tab = terminals.focusedTab(for: target)?.id ?? terminals.tabs(for: target).first?.id
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

  /// A window closing ends the standalone terminals it holds, and their rows go. Not on a quit,
  /// which keeps them for the next launch. It stops holding terminals for the section, so a group
  /// it had terminals in is counted without them, and settled: one no other window holds goes.
  func endStandaloneTerminalsOnClose() async {
    guard !WindowRegistry.shared.isTerminating else { return }
    let groups = terminals.activeTargetIDs.filter {
      if case .terminalGroup = $0 { return true }
      return false
    }
    terminalsSection.unregister(self)
    for id in groups { groupTabsRemoved(id) }
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

extension TargetID {
  /// A standalone terminal's id.
  var isStandaloneTerminal: Bool {
    if case .standalone = self { return true }
    return false
  }
}
