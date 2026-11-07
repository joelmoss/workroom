import WorkroomVCS
import XCTest

@testable import Workroom

final class WorkingStatusResolverTests: XCTestCase {

  /// An existing directory, so the `.missingPath` guard in `resolve(location:)` passes.
  private let existing = NSTemporaryDirectory()

  // git status is now read structurally via GitProvider (SwiftGitX); the porcelain-v2 parser is
  // gone. See WorkroomStatusIntegrationTests.testGitProviderWorkingStatus* for real-repo coverage.

  // MARK: - resolveLocal

  func testResolveLocalMissingPath() async {
    let r = WorkingStatusResolver()
    let missing = "/definitely/not/here-\(UUID().uuidString)"
    let s = await r.resolveLocal(path: missing)
    XCTAssertNil(s.dirty)  // unknown, NOT clean
    XCTAssertEqual(s.failure, .missingPath)
  }

  // A dirty git working tree is now read via GitProvider/SwiftGitX (not the mock runner + porcelain
  // parser) — covered by WorkroomStatusIntegrationTests.testGitProviderWorkingStatus on a real repo.

  func testResolveLocalGitFailureIsUnknownNotClean() async {
    // `existing` is a real directory but NOT a git repo, so the SwiftGitX read fails → notRepository.
    // The regression-critical property: a failed probe is UNKNOWN, never clean.
    let r = WorkingStatusResolver()
    let s = await r.resolveLocal(path: existing)
    XCTAssertNil(s.dirty)
    XCTAssertFalse(s.isClean)
    XCTAssertTrue(s.isUnknown)
    XCTAssertEqual(s.failure, .notRepository)
  }

  // MARK: - typed backend error → status failure

  /// Every `VCSError` the backends can raise must land on a badge deliberately, since a probe failure
  /// is the one status the user can't verify by looking at the row. The two retryable states get
  /// their own badge; the rest keep `.notRepository`, which is what the git side needs — `GitProvider`
  /// can't bind SwiftGitX's typed error, so a missing/broken repo arrives as `.io`.
  func testFailureMappingPerVCSError() {
    XCTAssertEqual(WorkingStatusResolver.failure(for: .lockContention), .busy)
    XCTAssertEqual(WorkingStatusResolver.failure(for: .staleSnapshot), .staleWorkingCopy)
    XCTAssertEqual(
      WorkingStatusResolver.failure(for: .unsupportedRepo("no .git")), .notRepository)
    XCTAssertEqual(WorkingStatusResolver.failure(for: .notFound("f.txt")), .notRepository)
    XCTAssertEqual(
      WorkingStatusResolver.failure(for: .partialData("diff read failed")), .notRepository)
    XCTAssertEqual(
      WorkingStatusResolver.failure(for: .backendVersion("from-the-future")), .notRepository)
    XCTAssertEqual(WorkingStatusResolver.failure(for: .io("boom")), .notRepository)
  }
}
