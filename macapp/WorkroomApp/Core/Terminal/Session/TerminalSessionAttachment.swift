import Foundation
import WorkroomWire

@MainActor
enum TerminalSessionAttachment {
  /// Point the focused terminal tab at `sessionID`. The tab's previous session stays running
  /// (detached). Returns false if the session is already owned by another tab. The tab is named
  /// as the new session is (#694), as opening it in a new tab names it: by `label`, the session's
  /// own as its daemon listed it, then by whatever its daemon told of it since; the old session's
  /// name, and what this Mac agreed with its daemon about it, go with the old session.
  @discardableResult
  static func attachToActivePane(
    sessionID: UUID,
    target: TerminalTarget,
    sessions: TerminalPanes,
    label: String? = nil
  ) -> Bool {
    guard var tab = sessions.focusedTab(for: target),
      case .terminal(var state) = tab.content,
      let view = sessions.surface(of: tab.id)
    else { return false }
    if let owner = sessions.owner(of: sessionID, in: target), owner != tab.id {
      return false
    }
    if state.sessionID != sessionID {
      state.userTitle = nil
      state.syncedLabel = nil
      // The old session's resume record goes with it (#824); the new one's comes from its daemon.
      state.resume = nil
      view.attachment.metadata = target.sessionMetadata(title: state.sessionLabel)
    }
    // A remote workroom's session from its host's list is attached on that host, as a new tab's
    // is (`makeTerminalTab`): unregistered, its attach would go to this Mac's helpers.
    sessions.registerHostSession(sessionID, for: target, metadata: view.attachment.metadata)
    let previous = state.sessionID
    // Let go here, so the list offers it while its host still counts the old ssh (#584).
    if let previous, previous != sessionID { sessions.sessionService.sessionReleased(previous) }
    state.sessionID = sessionID
    tab.content = .terminal(state)
    // The tab first: its session is the one the surface reads as it attaches again.
    sessions.replace(tab, for: target)
    view.attachment.sessionChanged()
    sessions.refreshProgramStatus(tab: tab.id, target: target.id)
    if previous != sessionID {
      if let previous { ProgramStatusAlerts.shared.paneLeft(session: previous) }
      // A numbered label an older build gave it names nothing.
      if let label, !TerminalState.isNumberedName(label) {
        sessions.applySessionLabel(label, forTab: tab.id, in: target)
      }
      SessionLabels.shared.mounted(sessionID, on: target.hostID)
    }
    // The waiting list counts only sessions an open pane shows.
    WindowRegistry.shared.recomputeBadge()
    return true
  }
}
