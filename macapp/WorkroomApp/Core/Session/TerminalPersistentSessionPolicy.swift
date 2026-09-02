import Defaults
import Foundation

enum TerminalPersistentSessionPolicy {
  /// Quick terminals aren't excluded here because they never reach this policy:
  /// `QuickTerminalController` builds its own `GhosttySurfaceView` in a bare `NSWindow`, bypassing
  /// `TerminalSessions` entirely, so they get no session ID by construction.
  static func usesPersistentSession(
    preferenceEnabled: Bool = Defaults[.backgroundSessions],
    isAvailable: Bool,
    isRunCommand: Bool,
    isFixture: Bool = UITestFixture.isActive
  ) -> Bool {
    preferenceEnabled && isAvailable && !isRunCommand && !isFixture
  }
}
