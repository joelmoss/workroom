import Foundation
import WorkroomWire

@MainActor
enum TerminalSessionAttachment {
  /// Point the focused terminal tab at `sessionID`. The tab's previous session stays running
  /// (detached). Returns false if the session is already owned by another tab.
  @discardableResult
  static func attachToActivePane(
    sessionID: UUID,
    target: TerminalTarget,
    sessions: TerminalPanes
  ) -> Bool {
    guard var tab = sessions.focusedTab(for: target),
      case .terminal(var state) = tab.content,
      let view = sessions.surface(of: tab.id)
    else { return false }
    if let owner = sessions.owner(of: sessionID, in: target), owner != tab.id {
      return false
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
    if let previous, previous != sessionID {
      ProgramStatusAlerts.shared.paneLeft(session: previous)
    }
    // The waiting list counts only sessions an open pane shows.
    WindowRegistry.shared.recomputeBadge()
    return true
  }
}
