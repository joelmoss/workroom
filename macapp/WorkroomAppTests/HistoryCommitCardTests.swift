import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The History row's hover card. XCUITest can't drive `.onHover`, so this is where the card's push-state
/// wiring is verified.
///
/// **Scope, stated honestly.** A unit-test process has no accessibility tree for a hosted SwiftUI view —
/// macOS only materializes SwiftUI's a11y elements for a live AX client, so `NSHostingView`'s a11y
/// children are empty here (verified: the root reports an `AXGroup` with 0 children). So this suite
/// asserts two things: the card's decision (`showsUnpushedMarker`, the same predicate the row's chip
/// uses) and that hosting the card renders without blowing up in every push state. The *visual* is
/// covered where it can be driven for real — `HistoryPushStateUITests` on the row and the changeset
/// header.
///
/// Also pins the shared tooltip copy (`VCSPushScope.unpushedHelp`), which all three surfaces use.
@MainActor
final class HistoryCommitCardTests: XCTestCase {
  private func commit(pushState: VCSPushState, isWorkingCopy: Bool = false) -> VCSCommit {
    VCSCommit(
      commitID: "c1", shortID: "c1abc123", changeID: nil, summary: "Add push state", body: "",
      authors: [VCSAuthor(name: "Ada", email: "ada@example.com")],
      timestamp: Date(timeIntervalSince1970: 1_700_000_000), refs: [], parentIDs: [],
      isWorkingCopy: isWorkingCopy, pushState: pushState)
  }

  private func card(_ commit: VCSCommit) -> HistoryCommitCard {
    HistoryCommitCard(commit: commit, pushScope: VCSPushScope(refName: "origin/main", count: 1))
  }

  /// Mount the card in an off-screen window (same harness idea as `PaneRenderingTests`) so a layout or
  /// force-unwrap crash in the new branch would fail the test rather than ship.
  private func render(_ commit: VCSCommit) {
    let hosting = NSHostingView(rootView: card(commit))
    hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // ARC owns the window; opt out of the programmatic default so `close()` isn't a second release.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    window.close()
  }

  // MARK: - what the card decides

  func testCardMarksAnUnpushedCommit() {
    XCTAssertTrue(card(commit(pushState: .unpushed)).showsUnpushedMarker)
  }

  func testCardOmitsTheMarkerForAPushedCommit() {
    XCTAssertFalse(card(commit(pushState: .pushed)).showsUnpushedMarker)
  }

  func testCardOmitsTheMarkerForAnUnknownState() {
    XCTAssertFalse(
      card(commit(pushState: .unknown)).showsUnpushedMarker,
      "unknown renders nothing — it is not a synonym for unpushed")
  }

  /// The card follows the same `@`-suppression rule as the row: hovering the working copy shouldn't
  /// announce it as unpushed work.
  func testCardSuppressesTheMarkerOnTheWorkingCopy() {
    XCTAssertFalse(card(commit(pushState: .unpushed, isWorkingCopy: true)).showsUnpushedMarker)
  }

  /// Every state renders. Cheap, but it's what catches a crash in the branch that only fires for one of
  /// them.
  func testCardRendersInEveryPushState() {
    render(commit(pushState: .unpushed))
    render(commit(pushState: .pushed))
    render(commit(pushState: .unknown))
    render(commit(pushState: .unpushed, isWorkingCopy: true))
  }

  // MARK: - shared tooltip copy

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
