import Foundation
import WorkroomDomain

/// Terminal groups in a window (ADR 0077): making a named one, its edits, and deleting it, which
/// makes its terminals standalone in its place. The group's entry is the app's `TerminalsSection`;
/// its terminals are each window's own, as a workroom's are, so a window that selects a group with
/// none of its terminals opens one (`ensureInitialTerminal`).
extension AppStore {
  /// New Terminal Group…: a named group just below the selected row when that is in the Terminals
  /// section, else at the section's end, selected, with its first terminal open. A name that trims
  /// to nothing makes no group.
  @discardableResult
  func newTerminalGroup(named name: String) -> SidebarID? {
    guard TerminalPanes.cleanedName(name) != nil else { return nil }
    let anchor = selectedTargetID.flatMap { $0.isInTerminalsSection ? $0.targetID : nil }
    let id = terminalsSection.addGroup(named: name, after: anchor)
    guard let sid = id.sidebarID, let target = target(for: sid) else { return nil }
    selectedTargetID = sid
    selectedProjectID = nil
    terminals.addTab(for: target)
    refreshSelectionHasTabs()
    return sid
  }

  /// The group `sid` names while it is listed, else nil.
  func terminalGroup(_ sid: SidebarID) -> TerminalGroup? {
    sid.targetID.flatMap(terminalsSection.group)
  }

  /// Whether deleting group `sid` asks first: only when it has terminals, in any window.
  func terminalGroupDeleteAsks(_ sid: SidebarID) -> Bool {
    guard let id = sid.targetID else { return false }
    return !terminalsSection.terminalNames(of: id).isEmpty
  }

  /// Deletes group `sid`: every window's terminals in it become standalone terminals in its place,
  /// in order, keeping their shells. The group goes once none is left in it; a terminal that
  /// couldn't be moved keeps it, so no shell is ever left in a group that isn't listed.
  func deleteTerminalGroup(_ sid: SidebarID) async {
    guard let id = sid.targetID, terminalsSection.group(id) != nil else { return }
    var anchor = id
    for holder in terminalsSection.allHolders {
      anchor = await holder.releaseTerminals(of: id, after: anchor)
    }
    guard terminalsSection.terminalNames(of: id).isEmpty else { return }
    terminalsSection.remove(id)
  }

  func releaseTerminals(of group: TargetID, after anchor: TargetID) async -> TargetID {
    guard let from = terminalTarget(forID: group) else { return anchor }
    let wasSelected = selectedTargetID?.targetID == group
    var anchor = anchor
    var first: SidebarID?
    for tab in terminals.tabs(for: from) {
      let id = terminalsSection.addStandalone(after: anchor)
      guard let into = terminalTarget(forID: id), await retarget(tab.id, from: from, to: into)
      else {
        terminalsSection.remove(id)
        continue
      }
      anchor = id
      first = first ?? id.sidebarID
    }
    if wasSelected, let first {
      selectedTargetID = first
      refreshSelectionHasTabs()
    }
    markSessionDirty()
    return anchor
  }

  /// Moves this window's tab `tabID` from `from` to `into`, both this window's targets, keeping its
  /// shell: its session is retagged as `into`'s first, and nothing moves if that fails. The one
  /// step a group's delete takes per terminal, which a group forming and dissolving takes too.
  func retarget(_ tabID: TerminalTab.ID, from: TerminalTarget, to into: TerminalTarget) async
    -> Bool
  {
    let sessionID = terminals.sessionID(forTab: tabID, inTarget: from.id)
    let service = terminals.sessionService
    if let sessionID,
      !(await service.retag(sessionID: sessionID, workroom: into.sessionWorkroomKey))
    {
      return false
    }
    notifications.repoint(tab: tabID, to: into.id, in: paneMoveOrigin)
    guard let handOff = terminals.handOffTab(tabID, from: from, to: into) else {
      // A popped-out pane stays where it is, under its old tag.
      if let sessionID {
        _ = await service.retag(sessionID: sessionID, workroom: from.sessionWorkroomKey)
      }
      notifications.repoint(tab: tabID, to: from.id, in: paneMoveOrigin)
      return false
    }
    terminals.adopt(handOff)
    return true
  }

  /// Names group `sid` (inline rename in the sidebar). An empty name makes it unnamed.
  func renameTerminalGroup(_ sid: SidebarID, to name: String) {
    guard let id = sid.targetID else { return }
    terminalsSection.renameGroup(id, to: name)
  }

  /// Set Starting Folder…: where group `sid`'s new terminals start; nil follows "New terminals open
  /// in" again.
  func setTerminalGroupStartingFolder(_ sid: SidebarID, to folder: String?) {
    guard let id = sid.targetID else { return }
    terminalsSection.setStartingFolder(id, to: folder)
  }
}
