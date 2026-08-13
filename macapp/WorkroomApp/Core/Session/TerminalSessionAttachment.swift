import Foundation
import WorkroomSessionProtocol

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
      case .terminal(var state) = tab.content
    else { return false }
    if let owner = sessions.owner(of: sessionID, in: target), owner != tab.id {
      return false
    }
    state.sessionID = sessionID
    state.view.persistentSessionID = sessionID
    state.view.reattachPersistentSession()
    tab.content = .terminal(state)
    sessions.replace(tab, for: target)
    return true
  }
}
