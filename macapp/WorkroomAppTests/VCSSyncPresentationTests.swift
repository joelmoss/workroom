import XCTest

@testable import Workroom

/// `VCSSyncPresenter` — the toolbar's middle-segment state machine.
///
/// A pure mapping with a hand-ordered precedence, which is exactly the shape that drifts silently
/// (`ChangeBadge`'s doc records how its own switch drifted once already). Every state and every
/// precedence edge is pinned here, before any view exists.
///
/// The single most important test in this file is `testNoCounterpartOffersPublishNotPush`: a fresh
/// workroom is `git worktree add -b` with no upstream, so "no counterpart" is the DEFAULT state, and
/// getting it wrong makes every new workroom read "Push origin" against a ref that doesn't exist.
final class VCSSyncPresentationTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func state(
    branch: String? = "main", kind: VCSRefKind = .branch, ahead: Int? = 0, behind: Int? = 0,
    gone: Bool = false, hasTracking: Bool = true, remotes: [String] = ["origin"],
    lastFetch: VCSLastFetch = .at(Date(timeIntervalSince1970: 1_699_999_460))  // 9 minutes before
  ) -> VCSRemoteState {
    VCSRemoteState(
      current: VCSRef(name: branch, kind: kind),
      tracking: hasTracking
        ? VCSTracking(
          comparedTo: "origin/\(branch ?? "?")", ahead: ahead, behind: behind, gone: gone)
        : nil,
      remotes: remotes, primaryRemote: CLIVCSWriter.primaryRemote(remotes),
      lastFetch: lastFetch, resolvedAt: now)
  }

  // MARK: States

  func testNoTargetIsDisabled() {
    let p = VCSSyncPresenter.make(state: nil, hasTarget: false, now: now)
    XCTAssertEqual(p.subtitle, "No workroom selected")
    XCTAssertFalse(p.isEnabled)
    XCTAssertNil(p.action)
    XCTAssertTrue(p.isSingleLine)
  }

  func testTargetWithNoRepoIsDisabled() {
    let p = VCSSyncPresenter.make(state: nil, hasTarget: true, now: now)
    XCTAssertEqual(p.subtitle, "No repository")
    XCTAssertFalse(p.isEnabled)
    XCTAssertEqual(p.tone, .warning)
  }

  func testNoRemoteIsDisabled() {
    let p = VCSSyncPresenter.make(state: state(remotes: []), hasTarget: true, now: now)
    XCTAssertEqual(p.subtitle, "No remote configured")
    XCTAssertFalse(p.isEnabled)
    XCTAssertNil(p.action)
  }

  /// THE workroom default. `git worktree add -b` sets no upstream, so the counterpart is absent for
  /// every freshly created workroom — this must offer Publish, never Push against a missing ref.
  func testNoCounterpartOffersPublishNotPush() {
    let p = VCSSyncPresenter.make(
      state: state(branch: "workroom/coral-bone", ahead: nil, behind: nil, gone: true),
      hasTarget: true, now: now)
    XCTAssertEqual(p.title, "Publish branch")
    XCTAssertEqual(p.action, .push)
    XCTAssertTrue(p.isEnabled)
    XCTAssertTrue(p.subtitle.contains("workroom/coral-bone"))
    XCTAssertTrue(p.subtitle.contains("isn’t on origin yet"))
  }

  func testAheadOffersPush() {
    let p = VCSSyncPresenter.make(state: state(ahead: 5, behind: 0), hasTarget: true, now: now)
    XCTAssertEqual(p.title, "Push origin")
    XCTAssertEqual(p.action, .push)
    XCTAssertEqual(p.badge, .init(count: 5, direction: .ahead))
    XCTAssertNil(p.secondaryBadge)
    XCTAssertEqual(p.subtitle, "Fetched 9 minutes ago")
    XCTAssertEqual(p.accessibilityValue, "5 ahead")
  }

  func testBehindOffersPullWithRebase() {
    let p = VCSSyncPresenter.make(state: state(ahead: 0, behind: 3), hasTarget: true, now: now)
    XCTAssertEqual(p.title, "Pull origin with rebase")
    XCTAssertEqual(p.action, .pull)
    XCTAssertEqual(p.badge, .init(count: 3, direction: .behind))
    XCTAssertEqual(p.accessibilityValue, "3 behind")
  }

  func testPullWordingDropsRebaseWhenTheRepoDoesNotRebase() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 0, behind: 3), hasTarget: true, pullRebase: false, now: now)
    XCTAssertEqual(p.title, "Pull origin")
  }

  /// Diverged offers PULL, not push: git refuses a non-fast-forward push, so Push here would send the
  /// user straight into a rejection. Badges show behind FIRST — the one the action addresses.
  func testDivergedOffersPullAndShowsBehindFirst() {
    let p = VCSSyncPresenter.make(state: state(ahead: 2, behind: 4), hasTarget: true, now: now)
    XCTAssertEqual(p.action, .pull, "git refuses a non-fast-forward push")
    XCTAssertEqual(p.badge?.direction, .behind, "the badge the action addresses comes first")
    XCTAssertEqual(p.badge?.count, 4)
    XCTAssertEqual(p.secondaryBadge, .init(count: 2, direction: .ahead))
    XCTAssertEqual(p.accessibilityValue, "4 behind, 2 ahead")
  }

  func testInSyncBecomesAFetchButton() {
    let p = VCSSyncPresenter.make(state: state(ahead: 0, behind: 0), hasTarget: true, now: now)
    XCTAssertEqual(p.action, .fetch)
    XCTAssertTrue(p.isEnabled)
    XCTAssertTrue(p.isSingleLine, "nothing to say beyond the timestamp")
    XCTAssertEqual(p.subtitle, "Fetched 9 minutes ago")
    XCTAssertNil(p.badge)
  }

  func testNeverFetchedStillOffersFetch() {
    let p = VCSSyncPresenter.make(state: state(lastFetch: .never), hasTarget: true, now: now)
    XCTAssertEqual(p.subtitle, "Never fetched")
    XCTAssertEqual(p.action, .fetch)
    XCTAssertTrue(p.isEnabled)
  }

  /// A detached HEAD (or a jj `@` with nothing to compare) has no tracking at all — that's in-sync-ish,
  /// not an error, and Fetch is still meaningful.
  func testNoTrackingFallsThroughToFetch() {
    let p = VCSSyncPresenter.make(
      state: state(kind: .detached, hasTracking: false), hasTarget: true, now: now)
    XCTAssertEqual(p.action, .fetch)
    XCTAssertNil(p.badge)
  }

  // MARK: Tool floor

  /// A below-floor tool outranks every count: no action below it could succeed, so offering one would
  /// be a lie. The warning toast carries the version detail; this segment just has to stop inviting.
  func testUnusableToolsDisableTheSegment() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 5), hasTarget: true, toolsUsable: false, now: now)
    XCTAssertFalse(p.isEnabled)
    XCTAssertNil(p.action)
    XCTAssertEqual(p.tone, .warning)
  }

  // MARK: In flight

  func testInFlightShowsProgressAndDisables() {
    for action in [VCSRemoteAction.fetch, .push, .pull] {
      let p = VCSSyncPresenter.make(
        state: state(ahead: 5), hasTarget: true, activity: .running(action), now: now)
      XCTAssertFalse(p.isEnabled, "\(action) in flight must disable")
      XCTAssertNil(p.action, "no second click while one is running")
      XCTAssertTrue(p.title?.hasSuffix("…") == true, "got \(p.title ?? "nil")")
    }
  }

  func testInFlightKeepsTheCountVisible() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 5), hasTarget: true, activity: .running(.push), now: now)
    XCTAssertEqual(p.badge, .init(count: 5, direction: .ahead))
  }

  // MARK: Failures

  func testFailureOutranksAnAvailableCount() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 5), hasTarget: true, failure: .authRequired("boom"), lastAction: .push,
      now: now)
    XCTAssertEqual(p.tone, .failure)
    XCTAssertEqual(p.symbol, "exclamationmark.triangle.fill")
    XCTAssertTrue(p.subtitle.contains("authenticate"))
    XCTAssertEqual(p.action, .push, "retries the action that failed")
  }

  /// An in-flight action outranks a stale failure — otherwise clicking Retry would keep showing the old
  /// error while the retry ran.
  func testInFlightOutranksAFailure() {
    let p = VCSSyncPresenter.make(
      state: state(), hasTarget: true, activity: .running(.push), failure: .locked,
      lastAction: .push, now: now)
    XCTAssertEqual(p.tone, .normal)
    XCTAssertEqual(p.title, "Pushing…")
  }

  /// A parked rebase must offer ABORT, never a retry — a retry fails identically until it's cleared.
  func testRebaseInProgressOffersAbortNotRetry() {
    let p = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .rebaseInProgress, lastAction: .pull, now: now)
    XCTAssertEqual(p.action, .abortRebase)
    XCTAssertTrue(p.isEnabled)
    XCTAssertTrue(p.subtitle.contains("Abort"))
  }

  /// The fix for a rejection is to pull, never to force — the engine has no force-push.
  func testRejectionOffersPull() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 2), hasTarget: true, failure: .rejected("! [rejected]"),
      lastAction: .push,
      now: now)
    XCTAssertEqual(p.action, .pull)
  }

  /// Nothing a click can do about a missing binary.
  func testToolMissingOffersNoAction() {
    let p = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .toolMissing("git"), lastAction: .fetch, now: now)
    XCTAssertNil(p.action)
    XCTAssertFalse(p.isEnabled)
  }

  func testAuthFailureCopyIsWrittenNotRawStderr() {
    let raw = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
    let message = VCSSyncPresenter.describe(.authRequired(raw))
    XCTAssertFalse(message.contains("terminal prompts disabled"), "raw stderr is baffling here")
    XCTAssertTrue(message.contains("ssh-agent") || message.contains("credential helper"))
  }

  func testHostKeyCopyIsDistinctFromAuthCopy() {
    let host = VCSSyncPresenter.describe(.hostKeyUnverified("Host key verification failed."))
    let auth = VCSSyncPresenter.describe(.authRequired("Permission denied (publickey)."))
    XCTAssertNotEqual(host, auth, "telling them to fix credentials would be wrong advice")
    XCTAssertTrue(host.contains("key isn’t known"))
  }

  func testOtherFailureShowsOnlyTheFirstLine() {
    let message = VCSSyncPresenter.describe(.other("first line\nsecond line\nthird"))
    XCTAssertEqual(message, "first line")
  }

  // MARK: Copy invariants

  /// `remote.pushDefault` can make the push remote something other than `origin`, so no string may
  /// hardcode it.
  func testRemoteNameIsInterpolatedNotHardcoded() {
    let s = state(remotes: ["upstream"])
    for p in [
      VCSSyncPresenter.make(state: s, hasTarget: true, now: now),
      VCSSyncPresenter.make(
        state: state(ahead: 1, remotes: ["upstream"]), hasTarget: true, now: now),
      VCSSyncPresenter.make(
        state: state(behind: 1, remotes: ["upstream"]), hasTarget: true, now: now),
      VCSSyncPresenter.make(
        state: state(ahead: 1, behind: 1, remotes: ["upstream"]), hasTarget: true, now: now),
      VCSSyncPresenter.make(
        state: state(gone: true, remotes: ["upstream"]), hasTarget: true, now: now),
    ] {
      let text = ((p.title ?? "") + p.subtitle + p.help + p.accessibility)
      XCTAssertFalse(text.contains("origin"), "hardcoded origin in: \(text)")
    }
  }

  /// The `ViewThatFits` ladder tries variants in order, so the longest MUST be first. Inverting this
  /// silently defeats the whole ladder — the first variant always fits.
  func testTitleVariantsAreOrderedLongestFirst() {
    for p in [
      VCSSyncPresenter.make(state: state(ahead: 1), hasTarget: true, now: now),
      VCSSyncPresenter.make(state: state(behind: 1), hasTarget: true, now: now),
      VCSSyncPresenter.make(state: state(gone: true), hasTarget: true, now: now),
    ] {
      let lengths = p.titleVariants.map(\.count)
      XCTAssertEqual(
        lengths, lengths.sorted(by: >), "longest first, got \(p.titleVariants)")
      XCTAssertFalse(p.titleVariants.isEmpty)
    }
  }

  func testEveryEnabledStateHasAnAction() {
    for p in [
      VCSSyncPresenter.make(state: state(ahead: 1), hasTarget: true, now: now),
      VCSSyncPresenter.make(state: state(behind: 1), hasTarget: true, now: now),
      VCSSyncPresenter.make(state: state(ahead: 1, behind: 1), hasTarget: true, now: now),
      VCSSyncPresenter.make(state: state(gone: true), hasTarget: true, now: now),
      VCSSyncPresenter.make(state: state(), hasTarget: true, now: now),
    ] {
      XCTAssertTrue(p.isEnabled)
      XCTAssertNotNil(p.action, "an enabled segment must do something when clicked")
      XCTAssertFalse(p.help.isEmpty)
      XCTAssertFalse(p.accessibility.isEmpty)
    }
  }

  // MARK: fetchedAgo

  func testSubMinuteReadsJustNow() {
    XCTAssertEqual(
      VCSSyncPresenter.fetchedAgo(.at(now), now: now), "Fetched just now",
      "RelativeDateTimeFormatter would say 'in 0 seconds' here")
    XCTAssertEqual(
      VCSSyncPresenter.fetchedAgo(.at(now.addingTimeInterval(-59)), now: now),
      "Fetched just now")
  }

  func testMinutesHoursAndDays() {
    XCTAssertEqual(
      VCSSyncPresenter.fetchedAgo(.at(now.addingTimeInterval(-540)), now: now),
      "Fetched 9 minutes ago", "the string from the reference screenshot")
    XCTAssertTrue(
      VCSSyncPresenter.fetchedAgo(.at(now.addingTimeInterval(-5400)), now: now).contains("hour"))
    XCTAssertTrue(
      VCSSyncPresenter.fetchedAgo(.at(now.addingTimeInterval(-259_200)), now: now).contains("day"))
  }

  func testShortFormIsShorter() {
    let full = VCSSyncPresenter.fetchedAgo(.at(now.addingTimeInterval(-540)), now: now)
    let short = VCSSyncPresenter.fetchedAgo(
      .at(now.addingTimeInterval(-540)), now: now, short: true)
    XCTAssertLessThan(short.count, full.count)
    XCTAssertTrue(short.hasPrefix("Fetched"))
  }

  func testNeverAndUnknownAreDifferentFacts() {
    XCTAssertEqual(VCSSyncPresenter.fetchedAgo(.never, now: now), "Never fetched")
    XCTAssertEqual(
      VCSSyncPresenter.fetchedAgo(.unknown, now: now), "",
      "unknown means we couldn't tell — rendering 'never' would be a claim we can't make")
  }

  // MARK: backend vocabulary

  /// jj repos must say "bookmark", not "branch". The two behave differently — a jj bookmark doesn't
  /// advance as you commit — so the wrong word teaches the wrong model of the tool in use.
  ///
  /// This is the assertion standing in for a screenshot: the caption is inside the toolbar view, and
  /// reaching it in a real jj project needs both a selected sidebar row and an open terminal.
  func testJJSaysBookmarkAndGitSaysBranch() {
    XCTAssertEqual(VCSSyncPresenter.refNoun(vcs: "jj"), "bookmark")
    XCTAssertEqual(VCSSyncPresenter.refNoun(vcs: "git"), "branch")
    XCTAssertEqual(VCSSyncPresenter.refCaption(vcs: "jj"), "Current Bookmark")
    XCTAssertEqual(VCSSyncPresenter.refCaption(vcs: "git"), "Current Branch")
  }

  /// An unknown or absent backend reads as git. `vcs` comes from the CLI config, so "git" is both the
  /// safe default and correct for every non-jj repo the app can open — and a nil target (nothing
  /// selected) still has to render a caption rather than an empty line.
  func testUnknownBackendFallsBackToBranch() {
    XCTAssertEqual(VCSSyncPresenter.refNoun(vcs: nil), "branch")
    XCTAssertEqual(VCSSyncPresenter.refNoun(vcs: ""), "branch")
    XCTAssertEqual(VCSSyncPresenter.refNoun(vcs: "hg"), "branch")
  }

  /// The caption is derived from the noun, not written twice — so a change to one can't leave the other
  /// saying something else.
  func testCaptionDerivesFromTheNoun() {
    for vcs in ["jj", "git", "", "hg"] {
      XCTAssertEqual(
        VCSSyncPresenter.refCaption(vcs: vcs),
        "Current \(VCSSyncPresenter.refNoun(vcs: vcs).capitalized)")
    }
  }
}
