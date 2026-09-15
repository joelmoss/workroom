import Sentry
import XCTest

@testable import Workroom

/// The Sentry `environment` split (WORKROOM-2B follow-up).
///
/// The `Nightly` build config is release-type, so it defines no `DEBUG` and nightly events used to
/// arrive tagged `production` — a hang from a build that ships nightly from the tip of `master` to a
/// handful of people looked exactly like a hang in the released app. `defaultEnvironment` takes its
/// inputs as parameters precisely so this can be asserted without faking a build configuration.
final class SentryConfigTests: XCTestCase {

  func testNightlyReleaseBuildReportsNightly() {
    XCTAssertEqual(SentryConfig.defaultEnvironment(nightly: true, debug: false), "nightly")
  }

  func testShippingReleaseBuildReportsProduction() {
    XCTAssertEqual(SentryConfig.defaultEnvironment(nightly: false, debug: false), "production")
  }

  func testDebugWinsOverEveryOtherIdentity() {
    // A local "Workroom Dev" build must never file events as nightly OR production, whatever the
    // channel marker says.
    XCTAssertEqual(SentryConfig.defaultEnvironment(nightly: true, debug: true), "development")
    XCTAssertEqual(SentryConfig.defaultEnvironment(nightly: false, debug: true), "development")
  }

  func testThisTestHostIsADebugBuild() {
    // Sanity check on the defaulted parameter: the test host is built Debug, so the no-argument call
    // must agree with the explicit one. Catches the seam being wired to the wrong fact.
    XCTAssertTrue(SentryConfig.isDebugBuild)
    XCTAssertEqual(SentryConfig.defaultEnvironment(), "development")
  }

  func testDevBuildNeverStartsSentry() {
    XCTAssertFalse(SentryConfig.shouldStart(debug: true))
  }

  func testReleaseChannelsStartSentry() {
    XCTAssertTrue(SentryConfig.shouldStart(debug: false))
  }
}

/// App-hang fingerprinting (WORKROOM-2T).
///
/// Sentry groups a Cocoa event on its in-app frames, and a macOS app hang has exactly one (`main`),
/// so every hang the app reports collapsed into ONE issue. These fixtures are the binary paths
/// behind six real WORKROOM-2T stacks captured 2026-09-01..14, oldest-first, as Sentry orders
/// `stacktrace.frames`. Paths, not function names, because that is all `beforeSend` ever sees:
/// Sentry Cocoa symbolicates server-side (measured: 95 frames, 0 with a `function`).
final class SentryAppHangFingerprintTests: XCTestCase {

  private let sys = "/System/Library/Frameworks/"
  private let priv = "/System/Library/PrivateFrameworks/"
  private var kernel: String { "/usr/lib/system/libsystem_kernel.dylib" }
  private var malloc: String { "/usr/lib/system/libsystem_malloc.dylib" }
  private var objc: String { "/usr/lib/libobjc.A.dylib" }
  private var dispatch: String { "/usr/lib/system/libdispatch.dylib" }
  private var app: String { "/Applications/Workroom.app/Contents/MacOS/Workroom" }

  /// `LazyStack.measureEstimates` walking a `ForEach`.
  private var lazyStackLayout: [String] {
    [
      app, sys + "AppKit.framework/Versions/C/AppKit", sys + "SwiftUI.framework/Versions/A/SwiftUI",
      objc,
    ]
  }
  /// dispatch-source dispose blocked on the objc sidetable lock.
  private var dispatchSourceDispose: [String] {
    [app, dispatch, objc, "/usr/lib/system/libsystem_platform.dylib", kernel]
  }
  /// Synchronous LaunchServices XPC from the menu bar.
  private var launchServicesXPC: [String] {
    [
      sys + "AppKit.framework/Versions/C/AppKit",
      sys + "CoreServices.framework/Versions/A/CoreServices", dispatch, kernel,
    ]
  }
  /// WindowServer menu-bar replicant-window creation.
  private var windowServerMenuBar: [String] {
    [
      sys + "AppKit.framework/Versions/C/AppKit", priv + "SkyLight.framework/Versions/A/SkyLight",
      kernel,
    ]
  }
  /// A SwiftUI trait write that ended in the allocator.
  private var traitTransform: [String] {
    [app, sys + "SwiftUI.framework/Versions/A/SwiftUI", malloc, kernel]
  }
  /// A plainly idle main thread.
  private var idleMainThread: [String] {
    [
      sys + "AppKit.framework/Versions/C/AppKit", priv + "HIToolbox.framework/Versions/A/HIToolbox",
      sys + "CoreFoundation.framework/Versions/A/CoreFoundation", kernel,
    ]
  }

  /// The regression. Before this fingerprint all six were one issue; they must now separate by the
  /// framework responsible. The two SwiftUI stacks legitimately share a group — that is the stated
  /// ceiling of binary-level grouping — so six mechanisms yield five groups, not one.
  func testTheSixRealMechanismsSeparateByResponsibleFramework() {
    let groups = [
      lazyStackLayout, dispatchSourceDispose, launchServicesXPC, windowServerMenuBar,
      traitTransform, idleMainThread,
    ].map { SentryConfig.appHangFingerprint(packages: $0)[1] }

    // The idle stack resolves to CoreFoundation, not HIToolbox: HIToolbox's event-loop frames sit
    // ABOVE `__CFRunLoopRun`/`__CFRunLoopServiceMachPort`, so CoreFoundation is genuinely the
    // deepest non-noise binary there.
    XCTAssertEqual(
      groups, ["SwiftUI", "Workroom", "CoreServices", "SkyLight", "SwiftUI", "CoreFoundation"])
    XCTAssertEqual(Set(groups).count, 5)
  }

  /// The leaf is where the tracker happened to sample ~2s in, not where the time went. Every one of
  /// these stacks ends in the kernel, the allocator or objc; a leaf-based fingerprint would put all
  /// six in one group, which is the bug.
  func testFingerprintIgnoresTheSampledLeaf() {
    let stacks = [
      lazyStackLayout, dispatchSourceDispose, launchServicesXPC, windowServerMenuBar,
      traitTransform, idleMainThread,
    ]
    for stack in stacks {
      let leaf = (stack.last! as NSString).lastPathComponent
      XCTAssertTrue(
        SentryConfig.isNoiseBinary(leaf),
        "fixture must END in noise or this test proves nothing — \(leaf) does not")
      let group = SentryConfig.appHangFingerprint(packages: stack)[1]
      XCTAssertNotEqual(group, leaf, "fingerprint used the sampled leaf")
      XCTAssertFalse(SentryConfig.isNoiseBinary(group), "fingerprint landed on a noise binary")
    }
  }

  /// How deep into the trailing noise the sampler landed must not change the group — that is the
  /// part of "same stall, two samples" this design guarantees, and it is what stops one mechanism
  /// scattering across a group per allocator frame. Truncation, not a duplicated leaf: appending a
  /// copy of the existing leaf would pass against the leaf-based implementation this replaced.
  func testDepthIntoTheNoiseDoesNotChangeTheGroup() {
    XCTAssertEqual(
      SentryConfig.appHangFingerprint(packages: launchServicesXPC),
      SentryConfig.appHangFingerprint(packages: launchServicesXPC.dropLast(2).map { $0 }))
  }

  /// The app's own binary is a real answer, not noise — a hang in our code must be greppable.
  func testTheAppsOwnBinaryIsASignalNotNoise() {
    XCTAssertEqual(
      SentryConfig.appHangFingerprint(packages: [app, dispatch, objc]), ["app-hang", "Workroom"])
    XCTAssertFalse(SentryConfig.isNoiseBinary("Workroom"))
  }

  /// Only the last path component travels. `package` is a full path and the app's own runs through
  /// the developer's home directory; `sendDefaultPii` is false, so it must not reach Sentry.
  func testFingerprintCarriesNoFilesystemPath() {
    let devBuild = "/Users/someone/dev/workroom/macapp/DerivedData/Workroom Dev.debug.dylib"
    let group = SentryConfig.appHangFingerprint(packages: [devBuild, kernel])[1]
    XCTAssertEqual(group, "Workroom Dev.debug.dylib")
    XCTAssertFalse(group.contains("/"))
  }

  func testAllNoiseOrEmptyStackIsGroupedAsUnknown() {
    XCTAssertEqual(SentryConfig.appHangFingerprint(packages: []), ["app-hang", "unknown"])
    XCTAssertEqual(
      SentryConfig.appHangFingerprint(packages: [dispatch, objc, malloc, kernel]),
      ["app-hang", "unknown"])
  }

  /// Drives the real `beforeSend` body against a real `Sentry.Event`, built the way
  /// `SentryHangTrackingIntegration.anrDetected` builds one. This is the test that was missing: the
  /// first version of this fix read `Frame.function`, which Sentry Cocoa never populates
  /// client-side (it symbolicates server-side), so it grouped every hang as "unknown" while the
  /// pure-function tests above stayed green. A frame here carries only `package`, exactly as the
  /// SDK hands it over.
  func testBeforeSendBodyGroupsARealAppHangEvent() {
    let frame = Frame()
    frame.package = "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI"
    let noise = Frame()
    noise.package = kernel

    let event = Event(level: .error)
    let exception = Exception(value: "App hanging for at least 2000 ms.", type: "App Hanging")
    exception.mechanism = Mechanism(type: "AppHang")
    exception.stacktrace = SentryStacktrace(frames: [frame, noise], registers: [:])
    event.exceptions = [exception]

    XCTAssertEqual(SentryConfig.appHangFingerprint(for: event), ["app-hang", "SwiftUI"])
  }

  /// A frame with no `function` must still group. Pins the regression directly: if this file ever
  /// goes back to reading function names, this returns "unknown" and the test fails.
  func testFramesWithoutFunctionNamesStillGroup() {
    let frame = Frame()
    frame.package = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    XCTAssertNil(
      frame.function, "SDK does not symbolicate client-side; the fixture must reflect it")

    let event = Event(level: .error)
    let exception = Exception(value: "App hanging", type: "App Hanging")
    exception.mechanism = Mechanism(type: "AppHang")
    exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
    event.exceptions = [exception]

    XCTAssertEqual(SentryConfig.appHangFingerprint(for: event), ["app-hang", "SkyLight"])
  }

  /// Anything that is not an app hang keeps Sentry's own grouping.
  func testNonAppHangEventsAreLeftAlone() {
    let event = Event(level: .error)
    let exception = Exception(value: "boom", type: "NSInvalidArgumentException")
    exception.mechanism = Mechanism(type: "NSException")
    event.exceptions = [exception]
    XCTAssertNil(SentryConfig.appHangFingerprint(for: event))
    XCTAssertNil(SentryConfig.appHangFingerprint(for: Event(level: .error)))
  }

  func testNoiseClassification() {
    XCTAssertTrue(SentryConfig.isNoiseBinary("libsystem_kernel.dylib"))
    XCTAssertTrue(SentryConfig.isNoiseBinary("libobjc.A.dylib"))
    XCTAssertTrue(SentryConfig.isNoiseBinary("libdispatch.dylib"))
    XCTAssertFalse(SentryConfig.isNoiseBinary("SwiftUI"))
    XCTAssertFalse(SentryConfig.isNoiseBinary("CoreFoundation"))
  }
}
