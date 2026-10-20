import WorkroomVCS
import XCTest

/// `VCSPushScope.unpushedHelp`: the unpushed badge's tooltip, shared by the History row and the
/// changeset header.
final class VCSPushScopeTests: XCTestCase {
  func testUnpushedHelpNamesASingleOriginBranch() {
    let help = VCSPushScope.unpushedHelp(VCSPushScope(refName: "origin/main", count: 1))
    XCTAssertEqual(
      help,
      "Not pushed — this commit isn't on origin/main, based on your local remote-tracking refs.")
  }

  func testUnpushedHelpCountsWhenOriginHasManyBranches() {
    let help = VCSPushScope.unpushedHelp(VCSPushScope(refName: nil, count: 7))
    XCTAssertTrue(help.contains("any of origin's 7 branches"), help)
  }

  /// The copy says "local remote-tracking refs", never "your last fetch": a local push updates those
  /// refs too, so naming only fetch would be wrong half the time.
  func testUnpushedHelpFallsBackToOriginAndNamesTheRightFreshnessSource() {
    let help = VCSPushScope.unpushedHelp(nil)
    XCTAssertTrue(help.contains("isn't on origin"), help)
    XCTAssertTrue(help.contains("local remote-tracking refs"), help)
    XCTAssertFalse(help.contains("fetch"), "freshness comes from refs, not specifically a fetch")
  }
}
