import Defaults
import XCTest

@testable import Workroom

/// `RemoteStateModel` — the VCS toolbar's state owner.
///
/// The debounce, TTL and single-action guard are the parts that protect the app from itself: without
/// them, cycling the sidebar with arrow keys spawns a process burst per row (the shape of the recorded
/// `history-eager-focus-is-a-full-vcs-read` starvation) and a double-click fires two pushes.
@MainActor
final class RemoteStateModelTests: XCTestCase {

  private let target = RemoteStateModel.Target(
    sid: .workroom(project: "/p", name: "feat"), path: "/p/feat", vcs: "git", projectRoot: "/p")
  private let otherTarget = RemoteStateModel.Target(
    sid: .workroom(project: "/p", name: "other"), path: "/p/other", vcs: "git", projectRoot: "/p")

  /// Reset in setUp as well as tearDown. `Defaults[.vcsLastFetch]` is a PERSISTED dictionary in the
  /// standard suite keyed by project ROOT PATH, and `VCSRemoteTriggerTests` drives real `.fetch`/`.pull`
  /// completions for the same `/p` root, so `recordOwnFetch` there writes a stamp this class's
  /// never-fetched preconditions read. `-parallel-testing` workers are separate processes sharing one
  /// defaults domain, so tearDown alone leaves a window where the other class's stamp is already written.
  override func setUp() {
    super.setUp()
    Defaults.reset(.vcsLastFetch)
  }

  override func tearDown() {
    super.tearDown()
    Defaults.reset(.vcsLastFetch)
  }

  private func state(
    branch: String = "main", ahead: Int = 0, behind: Int = 0, gone: Bool = false,
    remotes: [String] = ["origin"], lastFetch: VCSLastFetch = .never
  ) -> VCSRemoteState {
    VCSRemoteState(
      current: VCSRef(name: branch, kind: .branch),
      tracking: VCSTracking(
        comparedTo: "origin/\(branch)", ahead: ahead, behind: behind, gone: gone),
      remotes: remotes, primaryRemote: remotes.first, lastFetch: lastFetch, resolvedAt: Date())
  }

  private func model(
    _ writer: StubWriter, debounce: TimeInterval = 0, ttl: TimeInterval = 15,
    autoFetchInterval: TimeInterval = 300, now: @escaping @Sendable () -> Date = Date.init
  ) -> RemoteStateModel {
    RemoteStateModel(
      makeWriter: { _ in writer }, debounce: debounce, ttl: ttl,
      autoFetchInterval: autoFetchInterval, now: now)
  }

  // MARK: Focus

  func testFocusLoadsAndPublishesTheSnapshot() async {
    let writer = StubWriter(state: .state(state(ahead: 5)))
    let m = model(writer)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.state, .loaded)
    XCTAssertEqual(m.snapshot?.tracking?.ahead, 5)
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 1)
  }

  func testFocusIsIdempotentForTheSameTarget() async {
    let writer = StubWriter(state: .state(state()))
    let m = model(writer)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.focus(target)
    await m.awaitCurrentLoad()
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 1, "re-focusing the same target must not re-read")
  }

  func testFocusNilClearsAndIdles() async {
    let writer = StubWriter(state: .state(state()))
    let m = model(writer)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.focus(nil)
    XCTAssertEqual(m.state, .idle)
    XCTAssertNil(m.snapshot)
  }

  /// A burst of selection changes must collapse to one read. Each read is 2-3 processes, and the
  /// pre-dispatch wait is what stops N rapid selections spawning N of them.
  func testDebounceCoalescesABurst() async {
    let writer = StubWriter(state: .state(state()))
    let m = model(writer, debounce: 0.05)
    for _ in 0..<10 {
      m.focus(target)
      m.focus(otherTarget)
    }
    await m.awaitCurrentLoad()
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 1, "ten re-points, one read")
  }

  /// A read that finishes after the model moved on must not overwrite the new target's state.
  func testLateReadForAStaleTargetIsDiscarded() async {
    let writer = StubWriter(state: .state(state(branch: "first")))
    let m = model(writer, debounce: 0.05)
    m.focus(target)
    m.focus(otherTarget)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.target, otherTarget)
  }

  // MARK: activate / refresh / TTL

  func testActivateRefreshesOnSettledReentry() async {
    let writer = StubWriter(state: .state(state()))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.activate(target)
    await m.awaitCurrentLoad()
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 2)
  }

  func testActivateRetriesAfterAFailure() async {
    let writer = StubWriter(state: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    guard case .failed = m.state else { return XCTFail("expected .failed") }
    m.activate(target)
    await m.awaitCurrentLoad()
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 2, "a transient failure must be retryable")
  }

  func testTTLSuppressesARereadAndForceOverrides() async {
    let writer = StubWriter(state: .state(state()))
    let m = model(writer, ttl: 600)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.refresh()
    await m.awaitCurrentLoad()
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 1, "inside the TTL, no re-read")
    m.refresh(force: true)
    await m.awaitCurrentLoad()
    let reads2 = await writer.stateReads
    XCTAssertEqual(reads2, 2, "force must override the TTL")
  }

  // MARK: Resolutions

  /// A transient blip must leave the last good snapshot standing rather than blanking the toolbar.
  func testKeepPriorPreservesAGoodSnapshot() async {
    let writer = StubWriter(state: .state(state(ahead: 3)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    await writer.setState(.keepPrior)
    m.refresh(force: true)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.snapshot?.tracking?.ahead, 3, "a blip must not blank a good toolbar")
    XCTAssertEqual(m.state, .loaded)
  }

  func testAbsentClearsTheSnapshot() async {
    let writer = StubWriter(state: .absent)
    let m = model(writer)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertNil(m.snapshot)
    XCTAssertEqual(m.state, .loaded)
  }

  /// The model is the single writer of the shared branch cache every surface reads.
  func testResolvedBranchIsPublished() async {
    let writer = StubWriter(state: .state(state(branch: "feature/x")))
    let m = model(writer)
    var published: [SidebarID: String?] = [:]
    m.onBranchResolved = { sid, name in published[sid] = name }
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertEqual(published[target.sid], "feature/x")
  }

  func testAbsentPublishesNoBranch() async {
    let writer = StubWriter(state: .absent)
    let m = model(writer)
    var published: [SidebarID: String?] = [:]
    m.onBranchResolved = { sid, name in published[sid] = name }
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertEqual(published[target.sid], String?.none)
  }

  // MARK: Derived enablement

  func testPullNeedsACounterpartOnTheRemote() async {
    let writer = StubWriter(state: .state(state(behind: 2, gone: true)))
    let m = model(writer)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.canPull, "nothing to pull from when the counterpart doesn't exist")
    XCTAssertTrue(m.canPush, "but publishing it is exactly what you'd want")
  }

  /// Aborting a rebase is purely local. Requiring a remote would leave a workroom wedged in a rebase
  /// with no way out from the UI — the one state where recovery matters most.
  func testAbortRebaseWorksWithNoRemote() async {
    let writer = StubWriter(state: .state(state(remotes: [])))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.abortRebase)
    await m.awaitCurrentLoad()
    let aborts = await writer.aborts
    XCTAssertEqual(aborts, 1)
    XCTAssertNil(m.lastFailure, "abort must not be blocked by a missing remote")
  }

  func testNoRemoteStillBlocksNetworkActions() async {
    let writer = StubWriter(state: .state(state(remotes: [])))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.fetch)
    await m.awaitCurrentLoad()
    let fetches = await writer.fetches
    XCTAssertEqual(fetches, 0)
    XCTAssertEqual(m.lastFailure, .noRemote)
  }

  func testNoRemoteDisablesEverything() async {
    let writer = StubWriter(state: .state(state(remotes: [])))
    let m = model(writer)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.canFetch)
    XCTAssertFalse(m.canPush)
    XCTAssertFalse(m.canPull)
  }

  // MARK: Actions

  func testSuccessfulActionRefreshesAndNotifies() async {
    let writer = StubWriter(state: .state(state(ahead: 1)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    var mutations: [VCSRemoteAction] = []
    m.onDidMutate = { action, _ in mutations.append(action) }
    m.perform(.push)
    await m.awaitCurrentLoad()
    XCTAssertNil(m.inFlight)
    XCTAssertNil(m.lastFailure)
    XCTAssertEqual(mutations, [.push])
    let pushes = await writer.pushes
    XCTAssertEqual(pushes, 1)
  }

  /// A failed action must leave the snapshot intact — it tells you nothing new about the repo.
  func testFailedActionKeepsTheSnapshotAndRecordsTheFailure() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .failed(.authRequired("no")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.snapshot?.tracking?.ahead, 1)
    XCTAssertEqual(m.lastFailure, .authRequired("no"))
    XCTAssertEqual(m.lastAction, .push)
    XCTAssertNil(m.inFlight)
  }

  /// The single-action guard: a double-click must not fire two pushes, and Push must not race Pull.
  func testSecondActionWhileInFlightIsDropped() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), actionDelay: 0.1)
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    XCTAssertEqual(m.inFlight, .push)
    m.perform(.push)
    m.perform(.pull)
    await m.awaitCurrentLoad()
    let pushes = await writer.pushes
    XCTAssertEqual(pushes, 1, "one push, not three")
    let pulls = await writer.pulls
    XCTAssertEqual(pulls, 0)
  }

  /// The CROSS-window guard: `inFlight == nil` only rules out this model's own action, so a second
  /// window's write on the same project root must be caught by `canStartWrite` instead — refusing
  /// outright (never queuing into the gate) rather than letting two writes physically race.
  func testActionRefusedWhenAnotherWriteIsInFlightForTheProject() async {
    let writer = StubWriter(state: .state(state(ahead: 1)))
    let m = model(writer, ttl: 0)
    m.canStartWrite = { _ in false }
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.fetch)
    await m.awaitCurrentLoad()
    let fetches = await writer.fetches
    XCTAssertEqual(fetches, 0, "must not have reached the writer at all")
    XCTAssertNil(m.inFlight, "never entered the in-flight state")
    XCTAssertEqual(m.lastFailure, .locked(nil))
    XCTAssertEqual(m.lastAction, .fetch)
  }

  /// `canStartWrite` returning true (the common case) must not block anything new.
  func testActionProceedsWhenNoOtherWriteIsInFlight() async {
    let writer = StubWriter(state: .state(state(ahead: 1)))
    let m = model(writer, ttl: 0)
    m.canStartWrite = { _ in true }
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.fetch)
    await m.awaitCurrentLoad()
    let fetches = await writer.fetches
    XCTAssertEqual(fetches, 1)
    XCTAssertNil(m.lastFailure)
  }

  /// `writeDidStart`/`writeDidFinish` must bracket the actual write exactly once each, with the
  /// project root the action ran against — this is what lets the store maintain a per-project
  /// write-in-flight count that `canStartWrite` (wired to `AppStore.isWritingProject`) reads.
  func testWriteStartAndFinishBracketASuccessfulAction() async {
    let writer = StubWriter(state: .state(state(ahead: 1)))
    let m = model(writer, ttl: 0)
    var started: [String] = []
    var finished: [String] = []
    m.writeDidStart = { root in started.append(root) }
    m.writeDidFinish = { root in finished.append(root) }
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    XCTAssertEqual(started, [target.projectRoot], "started before the write returns")
    XCTAssertEqual(finished, [], "not finished yet — the write is still in flight")
    await m.awaitCurrentLoad()
    XCTAssertEqual(started, [target.projectRoot])
    XCTAssertEqual(finished, [target.projectRoot])
  }

  /// A failed action must still call `writeDidFinish` — otherwise a project that fails to push once
  /// would stay marked "busy" forever, refusing every future write for that root.
  func testWriteDidFinishFiresEvenOnFailure() async {
    let writer = StubWriter(state: .state(state()), action: .failed(.authRequired("no")))
    let m = model(writer, ttl: 0)
    var finished: [String] = []
    m.writeDidFinish = { root in finished.append(root) }
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    XCTAssertEqual(finished, [target.projectRoot])
  }

  func testMutationCallbackDoesNotFireOnFailure() async {
    let writer = StubWriter(state: .state(state()), action: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    var mutations: [VCSRemoteAction] = []
    m.onDidMutate = { action, _ in mutations.append(action) }
    m.perform(.fetch)
    await m.awaitCurrentLoad()
    XCTAssertTrue(mutations.isEmpty)
  }

  // MARK: The jj no-op-fetch gap

  /// jj's fetch is invisible: it passes `--no-write-fetch-head`, and a fetch that brings nothing records
  /// NO operation at all. So the backend can report `.never` right after a successful fetch, and without
  /// Workroom's own stamp the user would watch a stale timestamp not move.
  func testOwnFetchStampFillsTheGapWhenTheBackendReportsNever() async {
    let writer = StubWriter(state: .state(state(lastFetch: .never)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.snapshot?.lastFetch, .never)

    m.perform(.fetch)
    await m.awaitCurrentLoad()
    guard case .at = m.snapshot?.lastFetch else {
      return XCTFail(
        "after our own fetch the label must move, got \(String(describing: m.snapshot?.lastFetch))")
    }
  }

  /// …but the backend still wins when it is newer, which is what keeps a fetch run in the user's own
  /// terminal visible.
  func testBackendEvidenceWinsWhenNewer() {
    let old = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let merged = RemoteStateModel.merging(state(lastFetch: .at(newer)), ownFetch: old)
    XCTAssertEqual(merged.lastFetch, .at(newer))
  }

  func testOwnStampWinsWhenNewer() {
    let old = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let merged = RemoteStateModel.merging(state(lastFetch: .at(old)), ownFetch: newer)
    XCTAssertEqual(merged.lastFetch, .at(newer))
  }

  func testMergingWithNoOwnStampIsANoOp() {
    let merged = RemoteStateModel.merging(state(lastFetch: .never), ownFetch: nil)
    XCTAssertEqual(merged.lastFetch, .never)
  }

  /// `.unknown` means "couldn't tell", so our own stamp is strictly better information.
  func testOwnStampReplacesUnknown() {
    let stamp = Date(timeIntervalSince1970: 5_000)
    let merged = RemoteStateModel.merging(state(lastFetch: .unknown), ownFetch: stamp)
    XCTAssertEqual(merged.lastFetch, .at(stamp))
  }

  // MARK: Conflict upgrade

  /// A jj pull can succeed AND produce conflicts (they live inside commits; the rebase exits 0), so the
  /// flag arrives from the status refresh afterwards, not from the exit code.
  func testPullConflictIsRecordedFromTheFollowUpStatus() async {
    let writer = StubWriter(state: .state(state(behind: 1)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.pull)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.lastPullConflicted)
    m.noteConflictState(true, for: target.sid)
    XCTAssertTrue(m.lastPullConflicted)
  }

  func testConflictFlagIsIgnoredForNonPullActions() async {
    let writer = StubWriter(state: .state(state(ahead: 1)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    m.noteConflictState(true, for: target.sid)
    XCTAssertFalse(m.lastPullConflicted, "a push can't produce a rebase conflict")
  }

  // MARK: Stale target

  /// **The regression this pins.** `apply` has always guarded against a read landing after the model
  /// moved on; `finish` did not. So starting a push in one workroom and switching to another put the
  /// FIRST workroom's failure — and its action label — on the SECOND workroom's toolbar, reporting a
  /// failure for a workroom where nothing was attempted.
  func testAFailedActionDoesNotLandOnAWorkroomSwitchedToMidFlight() async {
    let writer = StubWriter(
      state: .state(state(ahead: 1)), action: .failed(.authRequired("nope")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    // Switch while the push is in flight, then let it finish.
    m.focus(otherTarget)
    await m.awaitCurrentLoad()
    XCTAssertNil(
      m.lastFailure,
      "the other workroom's push failure must not surface on this one; got "
        + String(describing: m.lastFailure))
  }

  /// The successful path is target-scoped too — a completed push must not clear or re-read state for a
  /// workroom it had nothing to do with.
  func testASuccessfulActionStillReportsItsOwnWorkroomDownstream() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .ok(summary: "pushed"))
    let m = model(writer, ttl: 0)
    var mutated: [SidebarID] = []
    m.onDidMutate = { _, sid in mutated.append(sid) }
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    m.focus(otherTarget)
    await m.awaitCurrentLoad()
    XCTAssertEqual(
      mutated, [target.sid],
      "the mutation must be attributed to the workroom it ran in, not the one now selected")
  }

  /// `inFlight` is the model-wide lock (a second action must be blocked wherever it was started from),
  /// but the LABEL is per-workroom: rendering `inFlight` directly left a freshly selected workroom
  /// showing "Pushing…" with every segment disabled until someone else's action finished.
  func testTheInFlightLabelIsScopedToItsOwnWorkroom() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .ok(summary: "pushed"))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    XCTAssertEqual(m.activeAction, .push, "the acting workroom shows its own action")

    m.focus(otherTarget)
    XCTAssertNil(m.activeAction, "a different workroom must not claim someone else's action")
    XCTAssertNotNil(m.inFlight, "but the model-wide lock still holds — one action at a time")
    XCTAssertFalse(m.canPush, "so a second action stays blocked")
    await m.awaitCurrentLoad()
  }

  /// The conflict upgrade arrives from an async sweep, so the selection can move before it lands.
  func testConflictUpgradeIsIgnoredForADifferentWorkroom() async {
    let writer = StubWriter(state: .state(state(behind: 1)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.pull)
    await m.awaitCurrentLoad()
    m.noteConflictState(true, for: otherTarget.sid)
    XCTAssertFalse(
      m.lastPullConflicted, "another workroom's conflict flag must not attach to this pull")
  }

  // MARK: The failure dialog

  /// **The reported defect.** The toolbar's sync segment is one truncating line, so a failure rendered as
  /// "Describe the change bef…" with the rest only reachable by hovering. Anything the user asked for and
  /// that failed now raises a report the dialog presents in full.
  func testAUserInitiatedFailureRaisesAReport() async {
    let writer = StubWriter(
      state: .state(state(ahead: 1)), action: .failed(.needsDescription("no description")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.failureReport?.failure, .needsDescription("no description"))
    XCTAssertEqual(m.failureReport?.action, .push, "the dialog's title names what was attempted")
  }

  /// The automatic fetch is a network call nobody asked for, so failing it must be as quiet as
  /// succeeding it. It still records `lastFailure` — the toolbar tells the story — but never interrupts.
  func testAnAutomaticFetchFailureRaisesNoDialog() async {
    let writer = StubWriter(state: .state(state()), action: .failed(.authRequired("nope")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.autoFetchIfDue()
    await m.awaitCurrentLoad()
    XCTAssertNil(m.failureReport, "an unrequested fetch must not put a dialog on screen")
    XCTAssertEqual(m.lastFailure, .authRequired("nope"), "but the toolbar still reports it")
  }

  /// Dismissing is about the dialog, not about the failure: the bar goes on reporting until the next
  /// action or refresh. Erasing `lastFailure` here would make the failure vanish on a click.
  func testDismissingTheDialogKeepsTheToolbarsFailure() async {
    let writer = StubWriter(
      state: .state(state(ahead: 1)), action: .failed(.rejected("! rejected")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    m.dismissFailureReport()
    XCTAssertNil(m.failureReport)
    XCTAssertEqual(m.lastFailure, .rejected("! rejected"))
  }

  /// The segment's "Show Error Details…" path. The re-raised report needs a NEW id: `.sheet(item:)` keys
  /// on identity, so re-presenting the same failure under the same id would silently do nothing.
  func testDetailsCanBeReopenedAfterDismissal() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .failed(.authRequired("nope")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    let first = m.failureReport?.id
    m.dismissFailureReport()

    m.presentFailureDetails()
    XCTAssertEqual(m.failureReport?.failure, .authRequired("nope"))
    XCTAssertEqual(m.failureReport?.action, .push)
    XCTAssertNotEqual(m.failureReport?.id, first, "a re-presentation needs a fresh identity")
  }

  func testReopeningDoesNothingWithoutAFailure() async {
    let writer = StubWriter(state: .state(state()))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.presentFailureDetails()
    XCTAssertNil(m.failureReport)
  }

  /// Pushing with no remote fails before anything runs, and that path sets `lastFailure` directly rather
  /// than going through `finish` — so it needs its own raise, or the one failure with a written remedy
  /// would be the one that never showed it.
  func testPushingWithNoRemoteRaisesTheDialogToo() async {
    let writer = StubWriter(state: .state(state(remotes: [])))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    XCTAssertEqual(m.failureReport?.failure, .noRemote)
    XCTAssertEqual(m.failureReport?.action, .push)
  }

  /// **The reported gap.** An action outlives the selection it started from — a push takes as long as it
  /// takes — and `finish`'s identity guard used to swallow the dialog along with the toolbar notice. So
  /// starting a push and switching workrooms mid-flight reported the failure NOWHERE: no dialog, no bar,
  /// no record. The spinner stopped and nothing said why.
  func testAFailureAfterTheSelectionMovedStillReportsAndNamesTheWorkroom() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .failed(.authRequired("nope")))
    let m = model(writer, ttl: 0)
    m.describeTarget = { sid in sid == self.target.sid ? "p / feat" : "p / other" }
    m.focus(target)
    await m.awaitCurrentLoad()

    m.perform(.push)
    m.focus(otherTarget)  // the user moves on while the push is still running
    await m.awaitCurrentLoad()

    XCTAssertEqual(m.failureReport?.failure, .authRequired("nope"))
    XCTAssertEqual(
      m.failureReport?.workroom, "p / feat",
      "named, so the dialog can't be read as the workroom now on screen")
    XCTAssertNil(
      m.lastFailure, "the BAR still belongs to the selection — only the dialog crosses the switch")
  }

  /// The common case stays unnamed: naming the workroom you are looking at is noise.
  func testAFailureForTheSelectedWorkroomIsNotNamed() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .failed(.authRequired("nope")))
    let m = model(writer, ttl: 0)
    m.describeTarget = { _ in "p / feat" }
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    XCTAssertNotNil(m.failureReport)
    XCTAssertNil(m.failureReport?.workroom)
  }

  // MARK: A failed READ

  /// A failed read used to reach the toolbar as nothing but a nil snapshot, which renders "No repository" —
  /// a wrong diagnosis of a healthy repo whose `packed-refs` was momentarily locked. The failure is now
  /// published, typed, so the bar can name the cause and offer a retry.
  func testAFailedReadPublishesTheFailure() async {
    let writer = StubWriter(state: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.readFailure, .locked(nil))
    XCTAssertNil(m.snapshot)
    XCTAssertNil(m.lastFailure, "nothing was attempted, so no ACTION failed")
  }

  /// It can never outlive the condition: the next read that lands an answer clears it.
  func testASuccessfulReadClearsTheReadFailure() async {
    let writer = StubWriter(state: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertNotNil(m.readFailure)

    await writer.setState(.state(state()))
    m.refresh(force: true)
    await m.awaitCurrentLoad()
    XCTAssertNil(m.readFailure)

    // A definitive "not a repo" is an answer too, not a lingering failure.
    await writer.setState(.failed(.locked(nil)))
    m.refresh(force: true)
    await m.awaitCurrentLoad()
    await writer.setState(.absent)
    m.refresh(force: true)
    await m.awaitCurrentLoad()
    XCTAssertNil(m.readFailure)
  }

  /// `retryRead` is the tier's click: forced past the TTL, undebounced, and flagged while it runs so the
  /// segment can show it. `readInFlight` is deliberately NOT `state == .loading` — every 15s sweep and
  /// every watcher fire sets that, and a spinner on those would flicker in the bar continuously.
  func testRetryReadIsForcedAndFlagsItselfInFlight() async {
    let writer = StubWriter(state: .failed(.locked(nil)))
    let m = model(writer, debounce: 0.2, ttl: 600)
    m.focus(target)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.readInFlight, "an automatic read must not put a spinner in the bar")

    m.retryRead()
    XCTAssertTrue(m.readInFlight, "the click is acknowledged immediately, not after the debounce")
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.readInFlight, "cleared when the read settles")
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 2, "forced past the 600s TTL — the user asked for this one")
  }

  /// Switching workrooms mid-retry must not strand "Trying again…" on a workroom that isn't reading.
  func testSwitchingWorkroomsClearsTheReadInFlightFlag() async {
    let writer = StubWriter(state: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.retryRead()
    m.focus(nil)
    XCTAssertFalse(m.readInFlight)
    await m.awaitCurrentLoad()
  }

  /// The details dialog reaches a read failure too, with no action named — none was taken. An action
  /// failure still outranks it, so the dialog can't describe something different from the bar.
  func testDetailsForAReadFailureNameNoAction() async {
    let writer = StubWriter(state: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()

    m.presentFailureDetails()
    XCTAssertEqual(m.failureReport?.failure, .locked(nil))
    XCTAssertNil(m.failureReport?.action)
  }

  /// A dialog left open over a workroom the user has moved away from is reporting someone else's problem.
  func testSwitchingWorkroomsClosesTheDialog() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), action: .failed(.authRequired("nope")))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    XCTAssertNotNil(m.failureReport)
    m.focus(otherTarget)
    XCTAssertNil(m.failureReport)
    await m.awaitCurrentLoad()
  }

  // MARK: Auto-fetch

  func testAutoFetchRunsOnceThenRespectsTheInterval() async {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
    let writer = StubWriter(state: .state(state()))
    let m = model(writer, ttl: 0, autoFetchInterval: 300, now: { clock.value })
    m.focus(target)
    await m.awaitCurrentLoad()

    m.autoFetchIfDue()
    await m.awaitCurrentLoad()
    let fetches = await writer.fetches
    XCTAssertEqual(fetches, 1)

    m.autoFetchIfDue()
    await m.awaitCurrentLoad()
    let fetches2 = await writer.fetches
    XCTAssertEqual(fetches2, 1, "inside the interval, no second fetch")

    clock.value = Date(timeIntervalSince1970: 1_400)
    m.autoFetchIfDue()
    await m.awaitCurrentLoad()
    let fetches3 = await writer.fetches
    XCTAssertEqual(fetches3, 2, "past the interval, fetch again")
  }

  func testAutoFetchDoesNothingWithoutARemote() async {
    let writer = StubWriter(state: .state(state(remotes: [])))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.autoFetchIfDue()
    await m.awaitCurrentLoad()
    let fetches = await writer.fetches
    XCTAssertEqual(fetches, 0)
  }

  func testAutoFetchDoesNothingWhileAnActionIsInFlight() async {
    let writer = StubWriter(state: .state(state(ahead: 1)), actionDelay: 0.1)
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    m.autoFetchIfDue()
    await m.awaitCurrentLoad()
    let fetches = await writer.fetches
    XCTAssertEqual(fetches, 0)
  }
}

/// Records what was asked of it and returns canned results.
private actor StubWriter: VCSWriting {
  private var stateResult: VCSRemoteResolution
  private let actionResult: VCSRemoteActionResult
  private let actionDelay: TimeInterval

  private(set) var stateReads = 0
  private(set) var fetches = 0
  private(set) var pushes = 0
  private(set) var pulls = 0
  private(set) var aborts = 0

  init(
    state: VCSRemoteResolution, action: VCSRemoteActionResult = .ok(summary: "done"),
    actionDelay: TimeInterval = 0
  ) {
    self.stateResult = state
    self.actionResult = action
    self.actionDelay = actionDelay
  }

  func setState(_ state: VCSRemoteResolution) { stateResult = state }

  func remoteState(path: String, projectRoot: String) async -> VCSRemoteResolution {
    stateReads += 1
    return stateResult
  }

  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult {
    fetches += 1
    return await settle()
  }

  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool,
    anonymousRevision: String
  ) async -> VCSRemoteActionResult {
    pushes += 1
    return await settle()
  }

  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String, tracking: VCSTracking?
  ) async -> VCSRemoteActionResult {
    pulls += 1
    return await settle()
  }

  func abortRebase(path: String, projectRoot: String) async -> VCSRemoteActionResult {
    aborts += 1
    return await settle()
  }

  func commit(path: String, projectRoot: String, request: VCSCommitRequest) async
    -> VCSCommitResult
  {
    .ok(summary: "committed", revision: nil)
  }

  private func settle() async -> VCSRemoteActionResult {
    if actionDelay > 0 {
      try? await Task.sleep(nanoseconds: UInt64(actionDelay * 1_000_000_000))
    }
    return actionResult
  }
}

/// A clock a test can move, so the auto-fetch interval is exercised without waiting real time.
private final class MutableClock: @unchecked Sendable {
  var value: Date
  init(_ value: Date) { self.value = value }
}
