import XCTest

@testable import Workroom

/// `VCSCommit`'s push-state badge rule.
final class VCSCommitTests: XCTestCase {
  /// Defaulted fields: a commit built without `pushState` reads `.unknown` — the guard that adding
  /// `pushState` didn't quietly start badging every commit built by an older call site.
  func testDefaultPushStateIsUnknownAndUnbadged() {
    let c = VCSCommit(
      commitID: "c1", shortID: "c1", summary: "s", body: "",
      authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [])
    XCTAssertEqual(c.pushState, .unknown)
    XCTAssertFalse(c.showsUnpushedBadge)
  }

  // MARK: - push state

  private func commit(pushState: VCSPushState) -> VCSCommit {
    VCSCommit(
      commitID: "c1", shortID: "c1", summary: "s", body: "", authors: [],
      timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [], pushState: pushState)
  }

  /// The badge renders for exactly one of the three states. `.unknown` must behave like `.pushed`
  /// here, NOT like `.unpushed`: it means "couldn't tell", and guessing would put a wrong badge on
  /// every row of a repo with no `origin`.
  func testShowsUnpushedBadgeTruthTable() {
    XCTAssertTrue(commit(pushState: .unpushed).showsUnpushedBadge)
    XCTAssertFalse(commit(pushState: .pushed).showsUnpushedBadge)
    XCTAssertFalse(commit(pushState: .unknown).showsUnpushedBadge)
  }
}
