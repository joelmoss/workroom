import Foundation

enum TerminalPersistentSessionPolicy {
  /// The Quick Terminal's panes take sessions too, ended at quit rather than kept (ADR 0064).
  ///
  /// **`isAvailable` gates only a NEW id.** It answers for the backend a new session would be
  /// created in, so it goes false whenever that backend cannot run — and a pane RESTORED from a
  /// previous launch already has an id naming a session some helper may still be holding. Running
  /// that id through the same gate threw it away before anything could ask who owned it, which is
  /// precisely the case the attach-only shim exists for: an unhealthy daemon stranded every session
  /// the Swift helper was still holding. An id the pane already has is a fact about the past, not a
  /// request for a new resource.
  ///
  /// Keeping the id when nothing can attach to it is harmless: `attachCommand(forSession:)` returns
  /// nil for an unresolved owner and `GhosttySurfaceView` opens a plain shell, which is the same
  /// outcome as having no id at all (a run tab runs nothing instead, and says why).
  ///
  /// `inProcessCommand`: the pane runs a command in its own process, as an Investigate tab runs its
  /// agent, so it has no session. A run tab's command is a run session's (#522), so it does.
  static func usesPersistentSession(
    isAvailable: Bool,
    inProcessCommand: Bool,
    hasExistingSession: Bool,
    isFixture: Bool = isPlainFixturePane
  ) -> Bool {
    (isAvailable || hasExistingSession) && !inProcessCommand && !isFixture
  }

  /// A fixture pane is a plain shell, unless the launch gave it a scratch daemon of its own. Never
  /// in Release.
  static var isPlainFixturePane: Bool {
    #if DEBUG
      AppEnvironment.current.isFixture && UITestFixture.liveDaemonDirectory == nil
    #else
      false
    #endif
  }
}
