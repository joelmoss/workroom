import XCTest

@testable import Workroom

/// The fixture's conflict seam (`-WorkroomUITestConflict 1`). `ChangesPanelUITests` relies on the
/// default fixture carrying NO conflicted file, so its conflicted-row assertion is driven by the flag
/// and not by something always present. That is a fact about fixture data, so it is pinned here
/// rather than by an app launch.
///
/// The flag is flipped through the REGISTRATION domain: it is in-memory and per-process, so nothing
/// reaches the test host's persisted preferences, and parallel test workers can't see each other's.
final class UITestFixtureConflictTests: XCTestCase {
  private let key = "WorkroomUITestConflict"

  override func tearDown() {
    UserDefaults.standard.register(defaults: [key: false])
    super.tearDown()
  }

  private var conflictedPaths: [String] {
    (UITestFixture.workroomStatus.changedFiles ?? []).filter { $0.change == .conflicted }.map(
      \.path)
  }

  func testDefaultFixtureHasNoConflictedFile() {
    XCTAssertFalse(UITestFixture.conflicted)
    XCTAssertFalse(UITestFixture.workroomStatus.conflicted)
    XCTAssertEqual(conflictedPaths, [])
  }

  /// The positive side, so the test above can't pass because the seam is broken outright.
  func testConflictFlagSeedsExactlyTheConflictedFile() {
    UserDefaults.standard.register(defaults: [key: true])
    XCTAssertTrue(UITestFixture.workroomStatus.conflicted)
    XCTAssertEqual(conflictedPaths, [UITestFixture.conflictedFilePath])
  }

  // Value: protects=a UI test's real-bootstrap launch (`fixture: false`) keeps its preferences out of
  // the developer's real domain; fails_when=the selector maps that launch to no isolation;
  // why_new=the selector type is new (D10); seam=none
  /// The four launch shapes and the environment each selects (D10): services and isolation are
  /// separate axes, so a `fixture: false` UI launch is live yet still a test process.
  func testEachLaunchShapeSelectsItsEnvironment() {
    let select = AppEnvironment.select
    XCTAssertEqual(
      select(false, false, false), AppEnvironment(services: .live, isolation: .none),
      "a user's launch: real services, real preferences")
    XCTAssertEqual(
      select(true, false, false), AppEnvironment(services: .fixture, isolation: .testProcess),
      "a fixture UI launch")
    XCTAssertEqual(
      select(false, true, false), AppEnvironment(services: .live, isolation: .testProcess),
      "a real-bootstrap UI launch (`fixture: false`)")
    XCTAssertEqual(
      select(false, false, true), AppEnvironment(services: .live, isolation: .testProcess),
      "a hosted unit run")
  }
}
