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
}
