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
    sessions: TerminalSessions
  ) -> Bool {
    guard var tab = sessions.focusedTab(for: target),
      case .terminal(var state) = tab.content,
      let view = sessions.surface(of: tab.id)
    else { return false }
    if let owner = sessions.owner(of: sessionID, in: target), owner != tab.id {
      return false
    }
    // The tab's session id and its surface's attach id are written together, here and when the
    // tab is made (`TerminalSessions.makeTerminalTab`), so readers of the tab's need not ask the view.
    let previous = state.sessionID
    state.sessionID = sessionID
    view.attachment.sessionID = sessionID
    // Always restored: this path exists to point a pane at a session that already exists, chosen
    // by the user from the detached-sessions list.
    view.attachment.isRestored = true
    view.attachment.reattach()
    tab.content = .terminal(state)
    sessions.replace(tab, for: target)
    sessions.refreshProgramStatus(tab: tab.id, target: target.id)
    if let previous, previous != sessionID {
      ProgramStatusAlerts.shared.paneLeft(session: previous)
    }
    // The waiting list counts only sessions an open pane shows.
    WindowRegistry.shared.recomputeBadge()
    return true
  }
}
