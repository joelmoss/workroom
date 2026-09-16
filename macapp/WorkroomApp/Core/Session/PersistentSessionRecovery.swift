import Foundation

@MainActor
enum PersistentSessionRecovery {
  /// Materialize restored panes whose daemon session is still running so they reattach
  /// without waiting for a click. A dead session just opens a fresh shell.
  static func recover(in sessions: TerminalSessions) async {
    await sessions.materializeLivePersistentSessions {
      await PersistentSessionService.shared.liveSessions()
    }
  }
}
