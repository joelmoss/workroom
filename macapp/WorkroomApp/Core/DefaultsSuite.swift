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
  /// The hosted unit run is scoped PER PROCESS, because `make app-test` spreads classes across
  /// parallel worker processes (`APP_TEST_FLAGS`) and this is a `static let` — one wipe per worker,
  /// each landing at whatever moment that worker first touches a preference. On a shared name that
  /// wipe is a race: a late worker clears the domain out from under a test another worker is part
  /// way through. The Makefile documents the same hazard for `.standard`; moving domains would have
  /// carried it along and added a destructive step the old domain never had.
  ///
  /// The XCUITest path keeps ONE stable name and no wipe: only one app process runs at a time, and
  /// a quit-and-relaunch test should see the preferences it left behind, exactly as it did on
  /// `.standard` before this existed.
  static let app: UserDefaults = {
    #if DEBUG
      let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      // `isolatesPreferences` is separate from `isActive` on purpose: a UI test that launches
      // WITHOUT fixture mode (to exercise the real bootstrap) has neither the fixture flag nor
      // `XCTestConfigurationFilePath`, and used to land straight in the developer's real domain.
      guard underTest || UITestFixture.isActive || UITestFixture.isolatesPreferences else {
        return .standard
      }
      let base = "com.developwithstyle.workroom.tests"
      let name = underTest ? "\(base).\(ProcessInfo.processInfo.processIdentifier)" : base
      guard let suite = UserDefaults(suiteName: name) else { return .standard }
      if underTest {
        // A reused pid must not inherit its predecessor's values.
        suite.removePersistentDomain(forName: name)
        pruneDeadSuites(base: base, keeping: name)
      }
      return suite
    #else
      // Release never redirects preferences. The env-var probe above is not enough on its own: a
      // shipped app launched from a shell that still exports `XCTestConfigurationFilePath` (a
      // wrapper script, `launchctl setenv`, a terminal left over from a test run) would otherwise
      // take the throwaway branch and hand the user a factory-reset app whose every later setting
      // lands in a suite a future test run deletes. Silent settings loss, no error path.
      return .standard
    #endif
  }()

  /// Delete the per-process suites left by test runs whose process is gone, so per-pid naming does
  /// not accumulate a plist per run. A pid that is still alive is skipped — that file belongs to a
  /// worker running right now, and deleting it would be the very race the naming avoids.
  private static func pruneDeadSuites(base: String, keeping current: String) {
    let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("Preferences")
    guard let preferences,
      let files = try? FileManager.default.contentsOfDirectory(
        at: preferences, includingPropertiesForKeys: nil)
    else { return }
    for file in files where file.pathExtension == "plist" {
      let name = file.deletingPathExtension().lastPathComponent
      guard name != current, name.hasPrefix("\(base)."),
        let pid = Int32(name.dropFirst(base.count + 1)),
        kill(pid, 0) != 0, errno == ESRCH
      else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }
}
