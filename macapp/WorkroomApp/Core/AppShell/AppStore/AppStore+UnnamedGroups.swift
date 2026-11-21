import Foundation
import WorkroomDomain

/// Unnamed terminal groups in a window (#659, ADR 0077): splitting a standalone terminal, or
/// dropping one standalone terminal's row on another's, makes one in its place, and a group that is
/// down to one terminal across every holder dissolves back into a standalone terminal; any group
/// goes with its last terminal. Each is a
/// move of terminals between targets in place (`TerminalsSection.rehome`), which every holder
/// applies to its own terminals here.
extension AppStore {
  /// A split in a standalone terminal (⌘D, ⌘⇧D, a pane's or tab's split): it and the new terminal
  /// become an unnamed group in its place, then the split runs in the group as usual. The split's
  /// fit has been checked; a terminal that can't be moved into the group splits nothing.
  func splitStandalone(_ tabID: TerminalTab.ID, on edge: PaneEdge, in id: TargetID) {
    let section = terminalsSection
    section.enqueueRegroup { [weak self] in
      guard let group = await section.convertToGroup(id), let self,
        let target = self.terminalTarget(forID: group)
      else { return }
      self.terminals.splitTab(tabID, on: edge, for: target)
    }
  }

  /// Drops standalone terminal `dropped`'s row on standalone terminal `destination`'s: an unnamed
  /// group of the two in `destination`'s place, `dropped`'s terminal its second tab. Each terminal
  /// stays in the window that holds it.
  func dropStandalone(_ dropped: SidebarID, onto destination: SidebarID) {
    guard let dropped = dropped.targetID, let destination = destination.targetID else { return }
    let section = terminalsSection
    section.enqueueRegroup {
      _ = await section.groupStandalone(dropped, onto: destination)
    }
  }

  /// A terminal left group `targetID` in this window, closed or moved: the group is settled
  /// (`settleGroup`), so it goes once no holder has a terminal in it, and an unnamed one that is
  /// down to one becomes a standalone terminal. Not during a quit, which must bring it back as it
  /// was.
  func groupTabsRemoved(_ targetID: TargetID) {
    guard case .terminalGroup = targetID, !WindowRegistry.shared.isTerminating,
      terminalsSection.group(targetID) != nil
    else { return }
    terminalsSection.settleGroup(targetID)
  }

  // MARK: Holder

  func retagTerminals(forTargetID targetID: TargetID, as newID: TargetID) async -> Bool {
    guard let from = terminalTarget(forID: targetID) else {
      return !holdsTerminals(forTargetID: targetID)
    }
    // `allTabs`, popped-out panes included: one can't be handed over in place (`handOffTab`), so
    // nothing moves, and the regroup is refused rather than leave it under a target that goes.
    let tabs = terminals.allTabs(for: from).map(\.id)
    guard tabs.allSatisfy({ !terminals.detachedTabIDs.contains($0) }) else { return false }
    let service = terminals.sessionService
    var done: [UUID] = []
    for tab in tabs {
      guard let session = terminals.sessionID(forTab: tab, inTarget: targetID) else { continue }
      guard await service.retag(sessionID: session, workroom: newID.encoded) else {
        for session in done {
          _ = await service.retag(sessionID: session, workroom: targetID.encoded)
        }
        return false
      }
      done.append(session)
    }
    return true
  }

  func rehomeTerminals(from: TerminalTarget, to newID: TargetID) {
    guard let into = terminalTarget(forID: newID), let old = from.id.sidebarID,
      let new = newID.sidebarID
    else { return }
    let tabs = terminals.tabs(for: from).map(\.id)
    isMovingTerminalsInPlace = true
    defer { isMovingTerminalsInPlace = false }
    replaceTarget(old, with: new)
    for tab in tabs {
      notifications.repoint(tab: tab, to: newID, in: paneMoveOrigin)
      guard let handOff = terminals.handOffTab(tab, from: from, to: into) else { continue }
      terminals.adopt(handOff)
    }
    refreshSelectionHasTabs()
    markSessionDirty()
  }

  /// Puts `new` wherever `old` is in this window: the selection, the title-bar order (pinned first,
  /// so the new tab takes the old one's place), the side-by-side splits, the expanded terminal rows
  /// and the back/forward history.
  private func replaceTarget(_ old: SidebarID, with new: SidebarID) {
    guard let oldID = old.targetID, let newID = new.targetID else { return }
    let order = Self.orderedActiveTargets(
      persisted: workroomTabOrder, active: terminals.activeTargetIDs)
    var replaced: [TargetID] = []
    for id in order where !replaced.contains(id == oldID ? newID : id) {
      replaced.append(id == oldID ? newID : id)
    }
    if replaced != workroomTabOrder { workroomTabOrder = replaced }
    if workroomSplits.contains(where: { $0.contains(new) }) {
      removeWorkroomSplitMember(old)
      if selectedTargetID == old { withHistorySuppressed { selectedTargetID = new } }
    } else {
      replacePane(old, with: new)
    }
    if expandedTerminalTargets.remove(oldID) != nil { expandedTerminalTargets.insert(newID) }
    history.retarget(old, to: new)
  }
}
