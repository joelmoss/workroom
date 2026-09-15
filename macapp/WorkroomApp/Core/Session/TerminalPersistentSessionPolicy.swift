import Defaults
import Foundation

enum TerminalPersistentSessionPolicy {
  /// Quick terminals aren't excluded here because they never reach this policy:
  /// `QuickTerminalController` builds its own `GhosttySurfaceView` in a bare `NSWindow`, bypassing
  /// `TerminalSessions` entirely, so they get no session ID by construction.
  ///
  /// **`isAvailable` gates only a NEW id.** It answers for the backend a new session would be
  /// created in, so it goes false whenever that backend cannot run — and a pane RESTORED from a
  /// previous launch already has an id naming a session some helper may still be holding. Running
  /// that id through the same gate threw it away before anything could ask who owned it, which is
  /// precisely the case the attach-only shim exists for: an unhealthy agent stranded every session
  /// the Swift daemon was still holding. An id the pane already has is a fact about the past, not a
  /// request for a new resource.
  ///
  /// Keeping the id when nothing can attach to it is harmless: `attachCommand(forSession:)` returns
  /// nil for an unresolved owner and `GhosttySurfaceView` opens a plain shell, which is the same
  /// outcome as having no id at all.
  static func usesPersistentSession(
    preferenceEnabled: Bool = Defaults[.backgroundSessions],
    isAvailable: Bool,
    isRunCommand: Bool,
    hasExistingSession: Bool,
    isFixture: Bool = UITestFixture.isActive
  ) -> Bool {
    preferenceEnabled && (isAvailable || hasExistingSession) && !isRunCommand && !isFixture
  }
}
