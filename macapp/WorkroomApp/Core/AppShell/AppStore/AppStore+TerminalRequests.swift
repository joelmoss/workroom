import AppKit
import Foundation
import WorkroomDomain

/// A window as `workroom new` and `workroom close` see it (#693, `TerminalRequests`).
extension AppStore: TerminalRequestHolder {
  func isShowingTarget(_ targetID: TerminalTarget.ID) -> Bool {
    guard let window = hostWindow, window.isVisible, !window.isMiniaturized,
      let selected = selectedTargetID, let shown = targetID.sidebarID
    else { return false }
    return selected == shown
      || workroomSplits.contains { $0.contains(selected) && $0.contains(shown) }
  }

  var isKeyHolder: Bool { hostWindow?.isKeyWindow == true }

  /// In a standalone terminal, the new terminal joins it in an unnamed group made in its place,
  /// as a split does (ADR 0077), and its session is tagged with the group, as the caller's is by
  /// the move; anywhere else, it opens in the caller's target.
  ///
  /// A standalone terminal's or a group's request waits its turn behind every regroup queued
  /// before it (`enqueueRegroup`), then looks again for where the caller's tab is now: an earlier
  /// `new` from the same standalone terminal may have made it a group meanwhile, which this one
  /// then joins, and a group may have dissolved. One whose caller's tab has gone, or whose
  /// standalone terminal can't become a group, is `unplaced`, never dropped.
  func showRequestedSession(
    _ session: UUID, label: String?, caller: TerminalTab.ID, in target: TerminalTarget,
    split edge: PaneEdge?, unplaced: @escaping () -> Void
  ) {
    guard target.id.isStandaloneTerminal || target.id.isTerminalGroup else {
      openRequestedPane(
        session, label: label, in: target, beside: edge.map { _ in caller }, on: edge)
      markSessionDirty()
      return
    }
    let section = terminalsSection
    section.enqueueRegroup { [weak self] in
      guard let self, let nowID = self.terminals.targetID(ofTab: caller),
        var now = self.terminalTarget(forID: nowID)
      else { return unplaced() }
      if now.id.isStandaloneTerminal {
        guard let group = await section.convertToGroup(now.id),
          let grouped = self.terminalTarget(forID: group)
        else { return unplaced() }
        now = grouped
      }
      // Tagged with the caller's target as it was asked; with where it opens, if that moved.
      if now.sessionWorkroomKey != target.sessionWorkroomKey {
        _ = await self.terminals.sessionService.retag(
          sessionID: session, workroom: now.sessionWorkroomKey)
      }
      self.openRequestedPane(
        session, label: label, in: now, beside: edge.map { _ in caller }, on: edge)
      self.markSessionDirty()
    }
  }

  func closeRequestedTab(_ tabID: TerminalTab.ID, in target: TerminalTarget) {
    closeFlow.performClose([tabID], for: target)
  }
}
