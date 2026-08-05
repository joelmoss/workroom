import XCTest

@testable import Workroom

/// The Pull Request inspector section's unusable-`gh` warning copy.
///
/// This layer had NO coverage at all, which mattered because the copy was a chain of
/// `status == .notInstalled` ternaries: anything that wasn't `.notInstalled` printed "not signed in".
/// That is how a version problem would have inherited a sign-in message. The mapping is the part that
/// regresses silently — a wrong-but-plausible warning still renders perfectly — so it is pinned per
/// state here rather than left to the view.
final class PullRequestPanelCopyTests: XCTestCase {
  func testNotInstalledOffersTheInstallLink() {
    let copy = PullRequestPanel.ghWarningCopy(for: .notInstalled)
    XCTAssertEqual(copy.title, "GitHub CLI not found")
    XCTAssertTrue(copy.body.contains("Install the gh command-line tool"))
    XCTAssertTrue(copy.showsInstallLink, "the one state where a download link is the fix")
  }

  func testNotAuthenticatedTellsYouToLogIn() {
    let copy = PullRequestPanel.ghWarningCopy(for: .notAuthenticated)
    XCTAssertEqual(copy.title, "GitHub CLI not signed in")
    XCTAssertTrue(copy.body.contains("gh auth login"))
    XCTAssertFalse(copy.showsInstallLink, "gh is installed — a download link would misdirect")
  }

  /// An old gh is installed and may well be signed in, so the message must name the version and
  /// point at an upgrade. Two things it must NOT do: claim you aren't signed in (sends you to
  /// `gh auth login`, which changes nothing), or offer the install link (it's already installed).
  func testTooOldNamesTheVersionAndOffersNoInstallLink() {
    let copy = PullRequestPanel.ghWarningCopy(for: .tooOld)
    XCTAssertEqual(copy.title, "GitHub CLI too old")
    XCTAssertTrue(copy.body.contains("2.57"), "say which version, so the fix is checkable")
    XCTAssertTrue(copy.body.lowercased().contains("upgrade"))
    XCTAssertFalse(copy.showsInstallLink)
    XCTAssertFalse(
      copy.body.contains("gh auth login"), "an upgrade problem must not be sold as a sign-in one")
  }

  /// Every state gets DISTINCT copy. A switch that mapped two states to the same message would still
  /// compile and still render, and this is what catches it.
  func testEveryWarningStateHasItsOwnTitle() {
    let titles = [GitHubCLIStatus.notInstalled, .notAuthenticated, .tooOld]
      .map { PullRequestPanel.ghWarningCopy(for: $0).title }
    XCTAssertEqual(Set(titles).count, titles.count, "two states share a title: \(titles)")
    XCTAssertFalse(titles.contains(""), "a warning state rendered an empty title")
  }

  /// The a11y-identifier suffix must be distinct per state too — it is the ONLY handle a UI test has,
  /// because the rendered `Text`s expose empty accessibility labels. Two states sharing an id would
  /// make "wrong warning for the state" invisible to the UI suite.
  func testEveryWarningStateHasItsOwnAccessibilityID() {
    let ids = [GitHubCLIStatus.notInstalled, .notAuthenticated, .tooOld, .available]
      .map { PullRequestPanel.ghWarningCopy(for: $0).id }
    XCTAssertEqual(Set(ids).count, ids.count, "two states share an a11y id: \(ids)")
    XCTAssertFalse(ids.contains(""), "a state has no a11y id, so a UI test cannot see it")
  }

  /// `.available` renders no warning at all (the caller gates on `!= .available`), so its copy is
  /// deliberately empty rather than a stale leftover that could leak into the UI.
  func testAvailableHasNoWarningCopy() {
    let copy = PullRequestPanel.ghWarningCopy(for: .available)
    XCTAssertTrue(copy.title.isEmpty)
    XCTAssertTrue(copy.body.isEmpty)
    XCTAssertFalse(copy.showsInstallLink)
  }
}
