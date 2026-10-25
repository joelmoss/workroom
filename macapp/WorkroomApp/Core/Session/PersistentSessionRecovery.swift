import Foundation

@MainActor
enum PersistentSessionRecovery {
  /// Recover live restored panes after the window displays. Hidden panes still attach so programs'
  /// own desktop notifications reach the app, paced across main-loop turns rather than one burst.
  /// Only targets `reattaches` passes: a local one that opens on this Mac.
  static func recover(
    in sessions: TerminalSessions, reattaches: (TerminalTarget.ID) -> Bool
  ) async {
    await sessions.materializeLivePersistentSessions(reattaches: reattaches) {
      await PersistentSessionService.shared.liveSessions()
    }
  }
}
