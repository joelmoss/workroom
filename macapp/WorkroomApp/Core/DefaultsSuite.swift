import Defaults
import Foundation

extension UserDefaults {
  /// The domain every Workroom preference lives in — the app's own `.standard` normally, and a
  /// throwaway suite whenever the process is running tests.
  ///
  /// **Why this exists.** `Defaults.Key` captures its suite at DECLARATION and defaults to
  /// `.standard`, so a `Defaults[…]` write anywhere in the app lands in the developer's real
  /// preferences. Under `make app-test` that is not hypothetical: the unit suite is *app-hosted*
  /// (`TEST_HOST` is `Workroom Dev.app`), so the whole app boots and every test that touches a
  /// preference — theme, release channel, run commands, inspector layout — rewrites the domain the
  /// developer actually uses. Tests must run against fixtures, never against real state, and the
  /// three guards the app already had (`ShellEnvironment` probe, the window bootstrap, the session
  /// store) each closed one hole of the same shape without closing this one.
  ///
  /// Isolation covers **both** test paths: a hosted unit run (`XCTestConfigurationFilePath`, set in
  /// this process) and the app launched under XCUITest (`UITestFixture.isActive`, where
  /// `applyFixtureDefaults` would otherwise pin values into the real domain for every fixture
  /// launch). `UITestFixture` itself keeps reading `.standard`, because that is where the *launch
  /// arguments* live — arguments are a separate domain from preferences, and isolating one must not
  /// hide the other.
  ///
  /// The suite is named, not random: a fresh name per run would litter `~/Library/Preferences` with
  /// one plist per test run. It is wiped on creation instead, so every run still starts clean.
  static let app: UserDefaults = {
    let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    guard underTest || UITestFixture.isActive else { return .standard }
    let name = "com.developwithstyle.workroom.tests"
    guard let suite = UserDefaults(suiteName: name) else { return .standard }
    suite.removePersistentDomain(forName: name)
    return suite
  }()
}
