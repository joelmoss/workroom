import Foundation
import Sentry

/// Sentry SDK setup, kept out of `WorkroomApp.init()` so the app entry point stays readable.
///
/// macOS-trimmed option set: Workroom is macOS-only, so the iOS-only features in Sentry's
/// quick-start are deliberately left off — Session Replay, watchdog-termination tracking, and
/// screenshot/view-hierarchy attachment aren't supported on macOS. What remains is the coverage
/// that's valid here: crash reporting, app-hang detection, tracing, profiling, and metrics.
///
/// The DSN is a *public* client key (safe to embed — it only permits sending events, not reading
/// them), so it ships in the binary; `SENTRY_DSN` overrides it for local experiments. Structured
/// logs (`enableLogs`) are off: it wouldn't pick up the app's existing `os.Logger` calls anyway —
/// surfacing those would need explicit `SentrySDK.capture(...)` at the call sites (the `GhosttyApp`
/// terminal-startup failures being the prime candidates).
enum SentryConfig {
  /// Public ingest DSN. Overridable via `SENTRY_DSN` to point local runs at a different project.
  private static let dsn =
    "https://01c27f42380699d6072a6e30abe6e175@o272130.ingest.us.sentry.io/4511524517249024"

  static func start() {
    guard shouldStart() else { return }

    SentrySDK.start { options in
      options.dsn = ProcessInfo.processInfo.environment["SENTRY_DSN"] ?? dsn

      // Tag dev builds so local crashes/traces don't pollute the production environment in Sentry.
      // `SENTRY_ENVIRONMENT` overrides either default.
      options.environment =
        ProcessInfo.processInfo.environment["SENTRY_ENVIRONMENT"] ?? defaultEnvironment()
      // releaseName defaults to "<bundle id>@<version>+<build>", which release.sh already drives.

      // Error monitoring: crashes + app hangs. Watchdog-termination tracking and the
      // non-fully-blocking app-hang report (`enableReportNonFullyBlockingAppHangs`) are both
      // iOS/tvOS/visionOS-only — unavailable on macOS — so they're left out entirely.
      options.enableCrashHandler = true
      options.enableAppHangTracking = true

      // Don't attach PII (IP address / user context). The SDK default, restated for intent: a local
      // dev tool gains little from it, and it keeps user-identifying data out of events.
      options.sendDefaultPii = false

      // Tracing — auto-instruments app launch, network, and SwiftUI. A desktop app sees low
      // transaction volume, so full sampling is affordable; lower this if that ever changes.
      options.tracesSampleRate = 1.0

      // Profiling (macOS-supported). `.trace` lifecycle ties profiles to sampled transactions.
      options.configureProfiling = {
        $0.sessionSampleRate = 1.0
        $0.lifecycle = .trace
      }

      // Metrics are on by default in SDK 9.12+; explicit for intent.
      options.enableMetrics = true
    }
  }

  /// The Sentry `environment` for this build: `development` for Debug, `nightly` for the side-by-side
  /// Workroom Nightly product, `production` for the shipping app.
  ///
  /// Nightly needs its own environment, not just its own release name. The `Nightly` build config is
  /// release-type (no `DEBUG`), so nightly events used to arrive tagged `production` — which is how
  /// WORKROOM-2B, an App Hang from a build that ships from the tip of `master` to a handful of people,
  /// was indistinguishable from a hang in the released app. Alert rules and saved searches scoped to
  /// `environment:production` will stop matching nightly events, which is the point.
  ///
  /// Both parameters default to the real build facts and exist purely so `SentryConfigTests` never has
  /// to fake a build configuration (the same seam `UITestFixture` uses).
  static func defaultEnvironment(
    nightly: Bool = ReleaseChannel.isNightlyBuild, debug: Bool = isDebugBuild
  ) -> String {
    if debug { return "development" }
    return nightly ? "nightly" : "production"
  }

  /// Whether Sentry should run at all. Never for local dev builds — CI test runs (GitHub Actions
  /// macOS runners are VMs) and everyday Debug launches were reporting real crash/hang/trace
  /// telemetry to the shared Sentry project, indistinguishable from a genuine release event except
  /// for the `environment` tag — that's how VM/CI noise like WORKROOM-2Y ended up looking like a
  /// user report.
  static func shouldStart(debug: Bool = isDebugBuild) -> Bool { !debug }

  /// Whether this is a Debug build. A stored fact rather than an `#if` at the use site so
  /// `defaultEnvironment` stays a pure function of its inputs.
  static let isDebugBuild: Bool = {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }()
}
