import Foundation

/// What this process runs with, on two separate axes (D10): its **services**, the real CLI, VCS and
/// providers or `UITestFixture`'s deterministic fakes, and its **isolation**, whether it must keep
/// out of the user's real preferences and files. The one place the three test signals are read.
///
/// The axes are separate because a UI test can launch with `fixture: false` to exercise the real
/// bootstrap (`WorkroomWorkflowUITests`): live services, yet still a test process whose
/// preferences must not land in the developer's own domain. Folding that launch into "not a
/// fixture" is how it once wrote the developer's window state, selection and release-channel
/// migration.
///
/// Read fresh each time, not cached: tests flip the fixture flag in the argument domain at runtime
/// (`DiffViewerLazyRenderingTests`, `SharedPrefDefaultsTests`). In Release it is always
/// (live, none), without reading any defaults: a stray `defaults write` must never latch a shipped
/// build into fixture mode or a throwaway preferences suite.
struct AppEnvironment: Equatable {
  enum Services: Equatable { case live, fixture }
  enum Isolation: Equatable { case none, testProcess }

  let services: Services
  let isolation: Isolation

  /// Fixture services: fake projects and statuses instead of the user's real configuration.
  var isFixture: Bool { services == .fixture }

  /// Whether this process is running tests **at all**, by any of the three signals that tell them
  /// apart — the one question `UserDefaults.app`, `GhosttyApp.themeConfigURLForCurrentEnvironment`
  /// and `WorkroomApp`'s prompt-watch guard each have to answer the same way.
  var isTestProcess: Bool { isolation == .testProcess }

  /// The environment for the three signals, and why none is sufficient alone:
  /// - `fixtureFlag` (`-WorkroomUITestFixture 1`): a fixture launch, which has no
  ///   `XCTestConfigurationFilePath`.
  /// - `isolatesPreferences` (`-WorkroomUITestIsolatePreferences 1`): a UI test that launches with
  ///   `fixture: false` to exercise the real bootstrap, which has neither of the others.
  /// - `hostedUnitRun` (`XCTestConfigurationFilePath`): set in a hosted unit process, never in an
  ///   app launched by XCUITest (the runner is the test process there, not the app).
  static func select(fixtureFlag: Bool, isolatesPreferences: Bool, hostedUnitRun: Bool)
    -> AppEnvironment
  {
    AppEnvironment(
      services: fixtureFlag ? .fixture : .live,
      isolation: fixtureFlag || isolatesPreferences || hostedUnitRun ? .testProcess : .none)
  }

  /// This process's environment. Release never reads a signal: the env-var probe alone would hand
  /// a factory-reset app to a user whose shell still exports `XCTestConfigurationFilePath`.
  static var current: AppEnvironment {
    #if DEBUG
      select(
        fixtureFlag: UITestFixture.fixtureFlag,
        isolatesPreferences: UITestFixture.isolatesPreferences,
        hostedUnitRun: isHostedUnitRun())
    #else
      AppEnvironment(services: .live, isolation: .none)
    #endif
  }

  /// The `XCTestConfigurationFilePath` signal: set in a hosted unit process, never in an app
  /// launched by XCUITest. Not gated on Debug, unlike `current`.
  static func isHostedUnitRun(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  /// Whether this is an app launched **by a UI test** (a fixture launch, or a `fixture: false`
  /// launch that still isolates preferences). The latter loads the developer's REAL projects (the
  /// real-bootstrap smoke test) and is deliberately hermetic too: its run tabs no longer see rc-only
  /// `PATH` entries. Narrower than `isTestProcess`, which also answers true for a hosted unit run —
  /// `WorkroomApp` skips the shell probe there for its own reason, and `ShellEnvironmentTests` needs
  /// the process environment left alone.
  static var isUILaunch: Bool { UITestFixture.fixtureFlag || UITestFixture.isolatesPreferences }

  /// Whether `WorkroomApp.init` starts the background `$SHELL -ilc` probe. Not in a hosted unit run
  /// (`ShellEnvironmentTests` needs the cache to hold only what it put there) and not in a UI-test
  /// launch (which has no use for the enrichment, and would otherwise execute the shell's startup
  /// files). Pure, so the decision is testable without launching the app.
  static func runsLaunchShellProbe(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    isUILaunch: Bool = isUILaunch
  ) -> Bool {
    !isHostedUnitRun(environment: environment) && !isUILaunch
  }
}
