import Foundation

@MainActor
enum PersistentSessionRecovery {
  /// Materialize restored panes whose daemon session is still running so they reattach
  /// without waiting for a click. A dead session just opens a fresh shell. Only targets
  /// `reattaches` passes: a local one that opens on this Mac.
  static func recover(
    in sessions: TerminalSessions, reattaches: (TerminalTarget.ID) -> Bool
  ) async {
    await sessions.materializeLivePersistentSessions(reattaches: reattaches) {
      await PersistentSessionService.shared.liveSessions()
    }
  }
}
