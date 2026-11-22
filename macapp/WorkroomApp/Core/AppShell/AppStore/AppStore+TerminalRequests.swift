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
  func showRequestedSession(
    _ session: UUID, label: String?, in target: TerminalTarget, beside anchor: TerminalTab.ID?,
    on edge: PaneEdge?
  ) {
    guard target.id.isStandaloneTerminal else {
      openRequestedPane(session, label: label, in: target, beside: anchor, on: edge)
      markSessionDirty()
      return
    }
    let section = terminalsSection
    section.enqueueRegroup { [weak self] in
      guard let group = await section.convertToGroup(target.id), let self,
        let grouped = self.terminalTarget(forID: group)
      else { return }
      _ = await self.terminals.sessionService.retag(sessionID: session, workroom: group.encoded)
      self.openRequestedPane(session, label: label, in: grouped, beside: anchor, on: edge)
      self.markSessionDirty()
    }
  }

  func closeRequestedTab(_ tabID: TerminalTab.ID, in target: TerminalTarget) {
    closeFlow.performClose([tabID], for: target)
  }
}
