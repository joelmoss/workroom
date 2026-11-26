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
    let id = terminalsSection.addGroup(named: name, after: selectedTargetID?.targetID)
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
  /// Runs in turn with the groups forming and dissolving (`enqueueRegroup`), so an unnamed group
  /// losing its terminals here isn't dissolved underneath it.
  func deleteTerminalGroup(_ sid: SidebarID) async {
    // The Quick Terminal's group is built in, and never deleted.
    guard let id = sid.targetID, id != .quickTerminal, terminalsSection.group(id) != nil else {
      return
    }
    let section = terminalsSection
    await section.enqueueRegroup {
      guard section.group(id) != nil else { return }
      var anchor = id
      for holder in section.allHolders {
        anchor = await holder.releaseTerminals(of: id, after: anchor)
      }
      guard section.terminalNames(of: id).isEmpty else { return }
      section.remove(id)
    }.value
  }

  func releaseTerminals(of group: TargetID, after anchor: TargetID) async -> TargetID {
    guard let from = terminalTarget(forID: group) else { return anchor }
    let wasSelected = selectedTargetID?.targetID == group
    var anchor = anchor
    var first: SidebarID?
    for tab in terminals.tabs(for: from) {
      let id = terminalsSection.addStandalone(after: anchor)
      // The selected group's first terminal to move takes the selection with it, in the same
      // step, so the inspector moves once, to it, rather than hop through each terminal left in the
      // group as they move out one at a time (#806).
      let selects = wasSelected && first == nil
      guard let into = terminalTarget(forID: id),
        await retarget(tab.id, from: from, to: into, inPlace: selects)
      else {
        terminalsSection.remove(id)
        continue
      }
      anchor = id
      first = first ?? id.sidebarID
      if selects, let first { moveSelection(withMovedTab: tab.id, to: first) }
    }
    if wasSelected, let first, selectedTargetID != first {
      selectedTargetID = first
      refreshSelectionHasTabs()
    }
    markSessionDirty()
    return anchor
  }

  /// Selects `row`, which tab `tabID` was just moved to in place out of the selected group, and
  /// points the inspector at it: the one move it makes for the delete. The tidy-up a close gets,
  /// which the in-place move skipped, isn't wanted (the group's selection is moved here, its row
  /// goes with the delete), apart from the back/forward history naming the group's tab.
  private func moveSelection(withMovedTab tabID: TerminalTab.ID, to row: SidebarID) {
    history.prune(removing: [tabID])
    selectedTargetID = row
    refreshSelectionHasTabs()
    focusHistoryIfShown()
    focusRemoteStateIfShown()
  }

  /// Moves this window's tab `tabID` from `from` to `into`, both this window's targets, keeping its
  /// shell: its session is retagged as `into`'s first, and nothing moves if that fails. The one
  /// step a group's delete takes per terminal, which a group forming and dissolving takes too.
  /// `inPlace`: the hand-over itself is a move in place (`isMovingTerminalsInPlace`), so the
  /// inspector holds still through it and the caller points it on.
  func retarget(
    _ tabID: TerminalTab.ID, from: TerminalTarget, to into: TerminalTarget, inPlace: Bool = false
  ) async -> Bool {
    let sessionID = terminals.sessionID(forTab: tabID, inTarget: from.id)
    let service = terminals.sessionService
    if let sessionID,
      !(await service.retag(sessionID: sessionID, workroom: into.sessionWorkroomKey))
    {
      return false
    }
    notifications.repoint(tab: tabID, to: into.id, in: paneMoveOrigin)
    // Held only over the synchronous hand-over, never across an await, so no other target's
    // close is taken for a move.
    if inPlace { isMovingTerminalsInPlace = true }
    let handOff = terminals.handOffTab(tabID, from: from, to: into)
    if let handOff { terminals.adopt(handOff) }
    if inPlace { isMovingTerminalsInPlace = false }
    guard handOff != nil else {
      // A popped-out pane stays where it is, under its old tag.
      if let sessionID {
        _ = await service.retag(sessionID: sessionID, workroom: from.sessionWorkroomKey)
      }
      notifications.repoint(tab: tabID, to: from.id, in: paneMoveOrigin)
      return false
    }
    return true
  }

  /// Names group `sid` (inline rename in the sidebar). An empty name makes it unnamed, and an
  /// unnamed group with one terminal, or none, dissolves at once (#659).
  func renameTerminalGroup(_ sid: SidebarID, to name: String) {
    guard let id = sid.targetID else { return }
    terminalsSection.renameGroup(id, to: name)
    if terminalsSection.group(id)?.name == nil { terminalsSection.settleGroup(id) }
  }

  /// Names standalone terminal `sid`, in whichever window holds it. An empty name gives its
  /// default back.
  func renameStandaloneTerminal(_ sid: SidebarID, to name: String) {
    guard let (holder, target, tab) = standaloneTerminal(sid) else { return }
    holder.terminals.setUserTitle(name, forTab: tab.id, in: target)
  }

  /// New Terminal in Group from group `sid`'s tab: a terminal in it in this window, with the group
  /// selected; the Quick Terminal's opens in its panel.
  func newTerminalInGroup(_ sid: SidebarID) {
    if sid.targetID == .quickTerminal { return revealQuickTerminal(newTerminal: true) }
    guard case .terminalGroup = sid, let target = target(for: sid) else { return }
    selectedTargetID = sid
    selectedProjectID = nil
    newTerminal(in: target)
  }

  /// Rename… for Terminals-section row `sid` from away from its row (its title-bar tab): asks the
  /// row to edit its name in place, and says whether it could. It can't while the sidebar is hidden,
  /// shows its Projects view, or doesn't draw the row in this window; the caller then shows the
  /// sheet.
  func beginSidebarRename(_ sid: SidebarID) -> Bool {
    guard sid.isInTerminalsSection, sidebarVisible, sidebarView == .open else { return false }
    return sidebarRename.begin(sid)
  }

  /// Set Starting Folder…: where group `sid`'s new terminals start; nil follows "New terminals open
  /// in" again.
  func setTerminalGroupStartingFolder(_ sid: SidebarID, to folder: String?) {
    guard let id = sid.targetID else { return }
    terminalsSection.setStartingFolder(id, to: folder)
  }
}
