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
}
