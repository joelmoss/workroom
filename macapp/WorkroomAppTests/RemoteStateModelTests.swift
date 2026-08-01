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
    m.onDidMutate = { mutations.append($0) }
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

  func testMutationCallbackDoesNotFireOnFailure() async {
    let writer = StubWriter(state: .state(state()), action: .failed(.locked(nil)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    var mutations: [VCSRemoteAction] = []
    m.onDidMutate = { mutations.append($0) }
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
    m.noteConflictState(true)
    XCTAssertTrue(m.lastPullConflicted)
  }

  func testConflictFlagIsIgnoredForNonPullActions() async {
    let writer = StubWriter(state: .state(state(ahead: 1)))
    let m = model(writer, ttl: 0)
    m.focus(target)
    await m.awaitCurrentLoad()
    m.perform(.push)
    await m.awaitCurrentLoad()
    m.noteConflictState(true)
    XCTAssertFalse(m.lastPullConflicted, "a push can't produce a rebase conflict")
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
