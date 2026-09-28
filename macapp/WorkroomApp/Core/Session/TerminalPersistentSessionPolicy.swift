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

  /// Whether quitting ends every session the helpers hold — the quit paths' promise that with
  /// persistence off nothing outlives the app (`AppDelegate.installSigtermHandler` and
  /// `stopRunCommandsThenTerminate`, which must agree).
  ///
  /// **Never from a test launch.** "Every session" means every session on the sockets under
  /// `Application Support/<bundle id>/`, whoever made them, and a test launch has made none: with
  /// persistence off nothing new is persisted, and a fixture never persists anything anyway. So
  /// all it could reach are the sessions of the developer's own Workroom Dev with the same bundle
  /// id — and fixture mode pins `backgroundSessions` off in its throwaway suite, whatever the
  /// developer chose. XCUITest ends the app with SIGTERM (`terminate()`), which runs this path,
  /// so every `make app-uitest` used to end the terminals of the Dev app it shared an id with.
  static func endsSessionsOnQuit(
    preferenceEnabled: Bool = Defaults[.backgroundSessions],
    isTestLaunch: Bool = TerminalPersistentSessionPolicy.isTestLaunch
  ) -> Bool {
    !preferenceEnabled && !isTestLaunch
  }

  /// A hosted unit run (`XCTestConfigurationFilePath`), or an app XCUITest launched, which has no
  /// such variable and is known by its fixture flags — the same three signals
  /// `applicationDidFinishLaunching` uses to keep a test launch off the developer's real agent.
  static var isTestLaunch: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || UITestFixture.isActive || UITestFixture.isolatesPreferences
  }
}
