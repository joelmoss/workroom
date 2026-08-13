import Defaults
import Foundation

enum TerminalPersistentSessionPolicy {
  static func usesPersistentSession(
    preferenceEnabled: Bool = Defaults[.backgroundSessions],
    isAvailable: Bool,
    isRunCommand: Bool,
    isQuickTerminal: Bool,
    isFixture: Bool = UITestFixture.isActive
  ) -> Bool {
    preferenceEnabled && isAvailable && !isRunCommand && !isQuickTerminal && !isFixture
  }
}
