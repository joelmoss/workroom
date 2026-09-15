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

      // Regroup app hangs before they're sent. See `appHangFingerprint`.
      options.beforeSend = { event in
        if let fingerprint = appHangFingerprint(for: event) { event.fingerprint = fingerprint }
        return event
      }
    }
  }

  // MARK: App-hang fingerprinting

  /// Sentry groups a Cocoa event by its *in-app* frames, and a macOS app hang has exactly one —
  /// `main` at `main.swift:57` — because everything below it is AppKit, SwiftUI and libdispatch. So
  /// every hang the app ever reports lands in a single issue regardless of cause. That issue is
  /// WORKROOM-2T, and by 2026-09-14 it held 38 events across at least five mechanisms that share
  /// nothing but the group: a synchronous LaunchServices XPC round-trip, WindowServer menu-bar
  /// replicant-window creation, a SwiftUI `LazyStack` measuring every child of a `ForEach`, a
  /// dispatch-source dispose blocked on the objc sidetable lock, and a plainly idle main thread. A
  /// grab-bag can't be triaged, assigned or closed — every alert costs a full re-investigation.
  ///
  /// So fingerprint each hang here instead, on the binary that owns the deepest meaningful frame.
  ///
  /// **It has to be the binary, not the function.** Sentry Cocoa symbolicates SERVER-side: the
  /// frames handed to `beforeSend` carry `instructionAddress`, `imageAddress`, `package` and
  /// `inApp`, and nothing else — `SentryCrashStackEntryMapper.sentryCrashStackEntryToSentryFrame:`
  /// sets exactly those four. Measured on this SDK (9.25.0) through the same capture path: 95
  /// frames, 0 with a `function`. A function-name fingerprint therefore groups every hang as
  /// "unknown", which looks like a fix and is not one. Function-level grouping is possible, but
  /// only in Sentry's own Stack Trace / Fingerprint Rules, which run after symbolication.
  ///
  /// Deliberately NOT the leaf's binary. The hang tracker samples the main thread once, roughly 2s
  /// into the stall, so the leaf is wherever the sample happened to land rather than where the time
  /// went — routinely the allocator, a lock, or dispatch plumbing. `isNoiseBinary` skips exactly
  /// those, and the first survivor walking up from the leaf is the framework doing real work.
  ///
  /// Coarser than a function name: two different SwiftUI hangs share a group. That is the honest
  /// ceiling of client-side grouping, and it still turns one unclosable issue into one per
  /// responsible framework. It errs toward over-splitting, which is the safe direction — two groups
  /// for one cause is a merge, one group for six causes is what this replaced. Binary names are
  /// also stable across macOS updates in a way SwiftUI's internal symbols are not.
  ///
  /// Only the last path component is used. `package` is a full path, and for the app's own binary
  /// that path runs through the developer's home directory — the fingerprint is transmitted, and
  /// `sendDefaultPii` is false, so the path must not travel with it.
  /// The `beforeSend` body, extracted purely so a test can reach it. `SentrySDK.start` never runs in
  /// the test host (`shouldStart` is `!isDebugBuild`), so an inline closure is unreachable from
  /// tests — which is precisely how a first version of this, keyed on `Frame.function`, shipped with
  /// every test green while grouping every hang as "unknown". Returns nil for anything that is not
  /// an app hang, meaning "leave this event's grouping alone".
  static func appHangFingerprint(for event: Event) -> [String]? {
    guard event.exceptions?.first?.mechanism?.type == "AppHang" else { return nil }
    let frames = event.exceptions?.first?.stacktrace?.frames ?? []
    return appHangFingerprint(packages: frames.compactMap(\.package))
  }

  static func appHangFingerprint(packages: [String]) -> [String] {
    let binaries = packages.map { ($0 as NSString).lastPathComponent }
    return ["app-hang", binaries.last(where: { !isNoiseBinary($0) }) ?? "unknown"]
  }

  /// Binaries that never name the cause of a hang: the allocator, locks, the objc/Swift runtimes,
  /// dispatch, and the loader. Everything else — AppKit, SwiftUI, HIToolbox, SkyLight, CoreServices,
  /// the app itself — names something worth splitting on.
  static func isNoiseBinary(_ binary: String) -> Bool { noiseBinaries.contains(binary) }

  private static let noiseBinaries: Set<String> = [
    "libsystem_kernel.dylib", "libsystem_malloc.dylib", "libsystem_platform.dylib",
    "libsystem_pthread.dylib", "libsystem_c.dylib", "libsystem_blocks.dylib",
    "libobjc.A.dylib", "libdispatch.dylib", "libswiftCore.dylib", "libswiftDispatch.dylib",
    "libc++abi.dylib", "libc++.1.dylib", "dyld",
  ]

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
