import Defaults
import XCTest

@testable import Workroom

/// A `ReleasesFetching` fake: returns a canned list, or throws to simulate a network failure.
private struct FakeReleases: ReleasesFetching {
  var releases: [GitHubRelease] = []
  var error: Error?
  func releases() async throws -> [GitHubRelease] {
    if let error { throw error }
    return releases
  }
}

private func rel(
  _ tag: String, name: String? = nil, body: String? = "notes", draft: Bool = false,
  prerelease: Bool = false
) -> GitHubRelease {
  GitHubRelease(
    tagName: tag, name: name, body: body, draft: draft, prerelease: prerelease,
    publishedAt: nil, htmlURL: URL(string: "https://example.com/\(tag)"))
}

@MainActor
final class WhatsNewServiceTests: XCTestCase {
  override func setUp() {
    super.setUp()
    resetDefaults()
  }
  override func tearDown() {
    resetDefaults()
    super.tearDown()
  }
  // Nonisolated: XCTest's `setUp` and `tearDown` are, and a defaults write needs no actor.
  nonisolated private func resetDefaults() {
    Defaults[.lastSeenVersion] = nil
    Defaults[.whatsNewAttemptVersion] = nil
    Defaults[.whatsNewAttempts] = 0
  }

  // MARK: - Pure filtering

  func testNotesInRangeNewestFirst() {
    let releases = [
      rel("v1.0.0"), rel("v1.1.0"), rel("v1.2.0"), rel("v2.0.0"),
    ]
    let notes = WhatsNewService.notes(
      from: releases, after: SemanticVersion("1.0.0")!, upTo: SemanticVersion("1.2.0")!)
    XCTAssertEqual(notes.map(\.version), ["1.2.0", "1.1.0"])  // (1.0.0, 1.2.0], newest first
  }

  func testExcludesDraftsAndUnparseableTags() {
    let releases = [
      rel("v1.1.0"),
      rel("v1.2.0", draft: true),  // draft → excluded
      rel("appcast"),  // not semver → excluded, no special-case needed
      rel("nightly"),  // not semver → excluded
    ]
    let notes = WhatsNewService.notes(
      from: releases, after: SemanticVersion("1.0.0")!, upTo: SemanticVersion("2.0.0")!)
    XCTAssertEqual(notes.map(\.version), ["1.1.0"])
  }

  func testBetaToStableShowsTheStableRelease() {
    // The regression Finding 2 guards: last == a beta, current == the stable of the same core.
    let releases = [rel("v2.0.0-beta.1"), rel("v2.0.0")]
    let notes = WhatsNewService.notes(
      from: releases, after: SemanticVersion("2.0.0-beta.1")!, upTo: SemanticVersion("2.0.0")!)
    XCTAssertEqual(notes.map(\.version), ["2.0.0"])
  }

  func testUnnamedReleaseTitleFallsBackToVersion() {
    let notes = WhatsNewService.notes(
      from: [rel("v1.1.0", name: nil)], after: SemanticVersion("1.0.0")!,
      upTo: SemanticVersion("1.1.0")!)
    XCTAssertEqual(notes.first?.title, "1.1.0")
  }

  // MARK: - checkOnLaunch branches

  func testFirstRunRecordsVersionNoDialog() async {
    let svc = WhatsNewService(
      fetcher: FakeReleases(releases: [rel("v1.0.0")]), currentVersion: "1.0.0")
    let notes = await svc.checkOnLaunch()
    XCTAssertNil(notes)
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.0.0")
  }

  func testEqualVersionNoDialog() async {
    Defaults[.lastSeenVersion] = "1.0.0"
    let svc = WhatsNewService(fetcher: FakeReleases(), currentVersion: "1.0.0")
    let notes = await svc.checkOnLaunch()
    XCTAssertNil(notes)
  }

  func testDowngradeNoDialog() async {
    Defaults[.lastSeenVersion] = "2.0.0"
    let svc = WhatsNewService(fetcher: FakeReleases(), currentVersion: "1.0.0")
    let notes = await svc.checkOnLaunch()
    XCTAssertNil(notes)
    XCTAssertEqual(Defaults[.lastSeenVersion], "2.0.0")  // not moved backward
  }

  func testUpgradeShowsNotesAndAdvancesMarker() async {
    Defaults[.lastSeenVersion] = "1.0.0"
    let svc = WhatsNewService(
      fetcher: FakeReleases(releases: [rel("v1.1.0"), rel("v1.2.0")]), currentVersion: "1.2.0")
    let notes = await svc.checkOnLaunch()
    XCTAssertEqual(notes?.map(\.version), ["1.2.0", "1.1.0"])
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.2.0")
  }

  func testEmptyInRangeAdvancesMarkerNoDialog() async {
    Defaults[.lastSeenVersion] = "1.0.0"
    let svc = WhatsNewService(fetcher: FakeReleases(releases: []), currentVersion: "1.1.0")
    let notes = await svc.checkOnLaunch()
    XCTAssertNil(notes)
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.1.0")  // resolved (empty) → advance
  }

  func testUnparseableCurrentSkips() async {
    Defaults[.lastSeenVersion] = "1.0.0"
    let svc = WhatsNewService(fetcher: FakeReleases(), currentVersion: "garbage")
    let notes = await svc.checkOnLaunch()
    XCTAssertNil(notes)
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.0.0")  // untouched
  }

  func testTransientFailureRetriesThenGivesUp() async {
    Defaults[.lastSeenVersion] = "1.0.0"
    let failing = FakeReleases(error: URLError(.notConnectedToInternet))
    func attempt() async {
      _ = await WhatsNewService(fetcher: failing, currentVersion: "1.2.0").checkOnLaunch()
    }

    await attempt()
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.0.0")  // still retrying
    XCTAssertEqual(Defaults[.whatsNewAttempts], 1)
    await attempt()
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.0.0")
    XCTAssertEqual(Defaults[.whatsNewAttempts], 2)
    await attempt()  // 3rd failure → give up
    XCTAssertEqual(Defaults[.lastSeenVersion], "1.2.0")
    XCTAssertEqual(Defaults[.whatsNewAttempts], 0)
  }

  func testAttemptCounterResetsWhenVersionChanges() async {
    Defaults[.lastSeenVersion] = "1.0.0"
    let failing = FakeReleases(error: URLError(.timedOut))
    _ = await WhatsNewService(fetcher: failing, currentVersion: "1.1.0").checkOnLaunch()
    XCTAssertEqual(Defaults[.whatsNewAttempts], 1)
    // A new version arrives before giving up on the old one → counter restarts.
    _ = await WhatsNewService(fetcher: failing, currentVersion: "1.2.0").checkOnLaunch()
    XCTAssertEqual(Defaults[.whatsNewAttempts], 1)
    XCTAssertEqual(Defaults[.whatsNewAttemptVersion], "1.2.0")
  }

}
