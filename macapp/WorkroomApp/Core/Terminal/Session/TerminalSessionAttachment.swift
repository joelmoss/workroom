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
    let previous = state.sessionID
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
