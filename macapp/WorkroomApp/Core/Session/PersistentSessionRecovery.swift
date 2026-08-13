import Foundation

@MainActor
enum PersistentSessionRecovery {
  /// Materialize restored panes whose daemon session is still running so they reattach
  /// without waiting for a click. A dead session just opens a fresh shell.
  static func recover(in sessions: TerminalSessions) async {
    let live = await PersistentSessionService.shared.liveSessions()
    let liveIDs = Set(live.compactMap(\.identifier.uuid))
    guard !liveIDs.isEmpty else { return }
    sessions.materializeLivePersistentSessions(liveIDs)
  }
}
