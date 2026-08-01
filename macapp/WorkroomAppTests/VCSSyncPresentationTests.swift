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

  // MARK: Lock failures

  private func lock(_ path: String = "/r/.git/index.lock", ageSeconds: TimeInterval = 900)
    -> VCSLockFile
  {
    VCSLockFile(path: path, modifiedAt: now.addingTimeInterval(-ageSeconds))
  }

  /// **The defect this fixes.** A lock file that is sitting on disk cannot be retried away: the button
  /// would fail identically every time it's pressed. Same reasoning as `.rebaseInProgress`, which has
  /// always refused to offer a retry.
  func testALocatedLockOffersNoRetry() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 5), hasTarget: true, failure: .locked(lock()), lastAction: .push, now: now
    )
    XCTAssertNil(p.action, "a lock file on disk makes every retry fail identically")
    XCTAssertFalse(p.isEnabled)
    XCTAssertTrue(
      p.titleVariants.isEmpty,
      "with no recovery to offer, the title must not read as a button; got \(p.titleVariants)")
    XCTAssertEqual(p.tone, .failure)
  }

  /// The other half: a lock we could NOT locate had already cleared, which is ordinary contention. Retry
  /// is the correct offer there, and withholding it would make a self-healing case look fatal.
  func testAnUnlocatableLockStillOffersRetry() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 5), hasTarget: true, failure: .locked(nil), lastAction: .push, now: now)
    XCTAssertEqual(p.action, .push)
    XCTAssertTrue(p.isEnabled)
    XCTAssertEqual(p.subtitle, "The repository was busy. Try again.")
  }

  func testLockedCopyNamesTheFile() {
    let p = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .locked(lock()), lastAction: .fetch, now: now)
    XCTAssertEqual(p.subtitle, "A leftover index.lock is blocking git.")
    XCTAssertFalse(
      p.subtitle.contains("Try again"), "the one thing it must never say for a located lock")
  }

  /// The subtitle is one line in the bar, so the actual remedy lives in the tooltip — and it has to be
  /// complete, because Workroom deliberately won't remove the file itself.
  func testTheTooltipCarriesThePathAgeAndRemedy() {
    let p = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .locked(lock(ageSeconds: 900)), lastAction: .fetch,
      now: now)
    XCTAssertTrue(p.help.contains("/r/.git/index.lock"), "got \(p.help)")
    XCTAssertTrue(p.help.contains("15 minutes ago"), "the age is the judgement call; got \(p.help)")
    XCTAssertTrue(p.help.contains("rm "), "the remedy must be copy-pasteable; got \(p.help)")
    XCTAssertTrue(
      p.help.contains("If no git command is running"),
      "the caveat is what makes removal safe advice rather than reckless advice")
  }

  /// The path rides on the presentation so the segment can offer Copy / Reveal — retyping a path out of
  /// a tooltip is exactly the friction that makes people give up and ignore the error.
  func testTheLockPathIsCarriedForTheContextMenu() {
    let located = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .locked(lock()), lastAction: .fetch, now: now)
    XCTAssertEqual(located.lockPath, "/r/.git/index.lock")

    let transient = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .locked(nil), lastAction: .fetch, now: now)
    XCTAssertNil(transient.lockPath, "nothing to copy or reveal when there's no file")
  }

  /// An in-flight action outranks a stale failure — otherwise clicking Retry would keep showing the old
  /// error while the retry ran.
  func testInFlightOutranksAFailure() {
    let p = VCSSyncPresenter.make(
      state: state(), hasTarget: true, activity: .running(.push), failure: .locked(nil),
      lastAction: .push, now: now)
    XCTAssertEqual(p.tone, .normal)
    XCTAssertEqual(p.title, "Pushing…")
  }

  // MARK: - permanent failures must not offer a retry

  /// Two failures added because they are PERMANENT until the user acts outside Workroom. Both used to
  /// fall through `retryAction`'s `default: return lastAction` and render a button that ran the identical
  /// doomed command — the same defect the located-lock case exists to prevent.
  func testPermanentFailuresOfferNoRetry() {
    // jj refuses to push a commit with an empty description, changes or not — the state every workroom is
    // in between the first edit and the first message. Measured: `Won't push commit … since it has no
    // description`.
    let undescribed = VCSSyncPresenter.make(
      state: state(ahead: 1), hasTarget: true, failure: .needsDescription("no description"),
      lastAction: .push, now: now)
    XCTAssertNil(undescribed.action, "retrying the same push fails identically")
    XCTAssertFalse(undescribed.isEnabled)
    XCTAssertTrue(undescribed.subtitle.contains("Describe"), "got \(undescribed.subtitle)")

    // jj refuses to rewrite commits `immutable_heads()` protects, which `rebase -b @` hits whenever the
    // branch containing `@` holds a remote-tracked commit. Measured: `Commit … is immutable`.
    let immutable = VCSSyncPresenter.make(
      state: state(behind: 2), hasTarget: true, failure: .immutableHistory("is immutable"),
      lastAction: .pull, now: now)
    XCTAssertNil(immutable.action)
    XCTAssertFalse(immutable.isEnabled)
    XCTAssertTrue(immutable.titleVariants.isEmpty, "no title means no button to click")
  }

  /// The recovery button must name the action it PERFORMS. It took its title from `lastAction` while its
  /// action came from `recovery`, so a rejected push rendered "Push" and ran a Pull.
  func testTheRecoveryButtonNamesWhatItDoes() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 2), hasTarget: true, failure: .rejected("! [rejected]"),
      lastAction: .push, now: now)
    XCTAssertEqual(p.action, .pull)
    XCTAssertEqual(
      p.title, "Pull", "the button said \"Push\" and performed a Pull; got \(p.title ?? "nil")")
  }

  // MARK: - the failure dialog

  /// **What the one-line segment could never do.** The bar truncated `describe`'s sentence
  /// ("Describe the change bef…") and hid the remedy in a tooltip. The dialog carries the whole thing.
  func testTheDialogCarriesTheRemedyTheBarCannot() {
    let d = VCSSyncPresenter.failureDialog(
      .needsDescription("Error: Won't push commit 050e657d3c36 since it has no description"),
      action: .push, now: now)
    XCTAssertEqual(d.title, "Push failed", "the dialog names what was attempted")
    XCTAssertTrue(d.message.contains("Describe the change"), "got \(d.message)")
    XCTAssertTrue(d.message.contains("jj describe"), "the remedy must be copy-pasteable")
    XCTAssertNil(d.recovery, "a permanent failure must not get a default button either")
  }

  /// The tool's own words, kept apart from ours. For `.other` this is the ONLY complete account — the
  /// segment shows that output's first line and nothing else.
  func testTheDialogCarriesTheToolsOwnOutput() {
    let raw = "error: failed to push some refs\nhint: Updates were rejected\nhint: pull first"
    let d = VCSSyncPresenter.failureDialog(.other(raw), action: .push, now: now)
    XCTAssertEqual(d.details, raw, "the whole output, not the first line the bar shows")
    XCTAssertEqual(
      d.message, "error: failed to push some refs",
      "we have no advice to add to raw output, so the message stays the one-liner")
  }

  /// Failures Workroom raises itself ran no command, so there is nothing to put under Details.
  func testFailuresWithNoToolOutputHaveNoDetails() {
    XCTAssertNil(VCSSyncPresenter.rawOutput(of: .noRemote))
    XCTAssertNil(VCSSyncPresenter.rawOutput(of: .timedOut(.fetch)))
    XCTAssertNil(VCSSyncPresenter.rawOutput(of: .rebaseInProgress))
    XCTAssertNil(
      VCSSyncPresenter.rawOutput(of: .authRequired("   ")), "whitespace is not evidence")
  }

  /// The dialog's default button comes from the same `retryAction` the bar uses, so the two can't
  /// disagree about whether a retry is worth offering — and a doomed command can't end up under Return.
  func testTheDialogsRecoveryMatchesTheBars() {
    let rejected = VCSSyncPresenter.failureDialog(
      .rejected("! [rejected]"), action: .push, now: now)
    XCTAssertEqual(rejected.recovery, .pull, "the fix for a rejection is to pull, never to force")

    let auth = VCSSyncPresenter.failureDialog(.authRequired("nope"), action: .fetch, now: now)
    XCTAssertEqual(auth.recovery, .fetch)

    let lock = VCSSyncPresenter.failureDialog(
      .locked(lock()), action: .fetch, now: now)
    XCTAssertNil(lock.recovery, "a lock file on disk makes every retry fail identically")
  }

  /// A located lock's tooltip text is already the complete account — path, age, remedy, caveat — so the
  /// dialog uses it whole rather than re-assembling a half-duplicate of it.
  func testALocatedLockKeepsItsFullExplanationAndOffersTheFile() {
    let d = VCSSyncPresenter.failureDialog(.locked(lock()), action: .fetch, now: now)
    XCTAssertEqual(d.lockPath, "/r/.git/index.lock", "so the dialog can reveal it in Finder")
    XCTAssertTrue(d.message.contains("/r/.git/index.lock"), "got \(d.message)")
    XCTAssertTrue(d.message.contains("rm "), "got \(d.message)")
    XCTAssertTrue(d.message.contains("If no git command is running"), "the caveat must survive")
  }

  /// The one failure whose remedy is a command the user has to run before anything else can work.
  func testNoRemoteTellsYouHowToAddOne() {
    let d = VCSSyncPresenter.failureDialog(.noRemote, action: .push, now: now)
    XCTAssertTrue(d.message.contains("git remote add origin"), "got \(d.message)")
    XCTAssertTrue(d.message.contains("jj git remote add origin"), "both backends; got \(d.message)")
  }

  // MARK: - an action running for another workroom

  /// `inFlight` is a model-wide lock but `activity` is per-target, so another workroom's action left this
  /// segment rendering an enabled button whose click `perform` silently dropped — and via the
  /// confirmation path, a dialog the user answered for nothing.
  func testAnActionElsewhereDisablesTheSegmentWithoutChangingItsCopy() {
    let idle = VCSSyncPresenter.make(state: state(ahead: 3), hasTarget: true, now: now)
    let busy = VCSSyncPresenter.make(
      state: state(ahead: 3), hasTarget: true, busyElsewhere: true, now: now)

    XCTAssertEqual(idle.action, .push)
    XCTAssertNil(busy.action, "a click here would be dropped, so it must not be offered")
    XCTAssertFalse(busy.isEnabled)
    XCTAssertEqual(
      busy.titleVariants, idle.titleVariants, "the copy must still report the real state")
    XCTAssertEqual(busy.badge, idle.badge, "and so must the count")
  }

  // MARK: - [14] a pull that landed conflicts

  /// jj's rebase commits conflicts and exits 0, so a conflicted pull is a SUCCESS the segment still has
  /// to report. Before this it said nothing: behind returns to 0, so the count tiers rendered "Push
  /// origin" over a conflicted tree.
  func testAConflictedPullIsReportedAndOffersNoAction() {
    let p = VCSSyncPresenter.make(
      state: state(ahead: 1), hasTarget: true, lastAction: .pull, pullConflicted: true, now: now)
    XCTAssertEqual(p.subtitle, "Pulled with conflicts")
    XCTAssertEqual(p.tone, .warning, "an outcome needing work, not a failed operation")
    XCTAssertNil(p.action, "resolving conflicts is work in an editor; a button can't do it")
    XCTAssertFalse(p.isEnabled)
    XCTAssertTrue(p.help.contains("Resolve"), "the remedy belongs in the tooltip; got \(p.help)")
  }

  /// It must outrank the counts — the whole point — but yield to both an in-flight action (a running
  /// action's progress beats a previous outcome) and a failure (which has recovery to offer).
  func testConflictedPullOutranksCountsButYieldsToFlightAndFailure() {
    let counts = VCSSyncPresenter.make(
      state: state(ahead: 3), hasTarget: true, pullConflicted: true, now: now)
    XCTAssertEqual(
      counts.subtitle, "Pulled with conflicts", "a push offer would hide the conflicts")
    XCTAssertNil(counts.badge, "no count pill competing with the conflict message")

    let running = VCSSyncPresenter.make(
      state: state(), hasTarget: true, activity: .running(.fetch), pullConflicted: true, now: now)
    XCTAssertEqual(running.title, "Fetching…")

    let failed = VCSSyncPresenter.make(
      state: state(), hasTarget: true, failure: .authRequired("nope"), lastAction: .pull,
      pullConflicted: true, now: now)
    XCTAssertEqual(failed.tone, .failure)
  }

  /// Both flags are required. `lastPullConflicted` alone would attribute a terminal-side merge conflict
  /// to Workroom's Pull; the live status alone would let the message outlive the conflicts, since the
  /// flag is cleared only by a new action or a workroom switch.
  func testPullConflictedNeedsBothOurPullAndAStillConflictedTree() {
    XCTAssertTrue(
      VCSSyncPresenter.pullConflicted(lastPullConflicted: true, statusConflicted: true))
    XCTAssertFalse(
      VCSSyncPresenter.pullConflicted(lastPullConflicted: true, statusConflicted: false),
      "resolved in a terminal — the message must clear on the next sweep")
    XCTAssertFalse(
      VCSSyncPresenter.pullConflicted(lastPullConflicted: false, statusConflicted: true),
      "conflicted, but not by our pull — don't claim the credit")
    XCTAssertFalse(
      VCSSyncPresenter.pullConflicted(lastPullConflicted: false, statusConflicted: false))
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
