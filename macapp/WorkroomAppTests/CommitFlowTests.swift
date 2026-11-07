import WorkroomVCS
import XCTest

@testable import Workroom

/// The commit dialog's phase machine, driven through `CommitFlow` with every ask held open by hand,
/// so each completion lands exactly when a test says — including after the user has moved on.
@MainActor
final class CommitFlowTests: XCTestCase {
  private struct Failure: LocalizedError {
    var errorDescription: String? { "the repository went away" }
  }

  /// Records every ask and keeps its completion, so a test decides when (and whether) it lands.
  @MainActor
  private final class Asks {
    var preflights: [(Result<VCSCommitPreflight, Error>) -> Void] = []
    var stagedChecks: [(files: [ChangedFile], reply: (Result<[String], Error>) -> Void)] = []
    var commits: [(request: VCSCommitRequest, reply: (VCSCommitResult) -> Void)] = []
    var dismissals = 0
    var draft = CommitFlow.Draft(message: "Fix the thing", files: [CommitFlowTests.file("a.swift")])

    var context: CommitFlow.Context {
      CommitFlow.Context(
        preflight: { self.preflights.append($0) },
        stagedContentAtRisk: { self.stagedChecks.append(($0, $1)) },
        performCommit: { self.commits.append(($0, $1)) },
        draft: { self.draft },
        dismiss: { self.dismissals += 1 })
    }
  }

  private static func file(_ path: String) -> ChangedFile {
    ChangedFile(path: path, change: .modified)
  }

  /// A flow whose preflight has already succeeded, the state every commit starts from.
  private func readyFlow(_ asks: Asks) -> CommitFlow {
    let flow = CommitFlow()
    flow.prefill(asks.context)
    asks.preflights.removeFirst()(
      .success(VCSCommitPreflight(sequencer: nil, amendTarget: "abc123 Last")))
    return flow
  }

  // MARK: Preflight

  func testPrefillAsksOnceAndShowsWhatTheRepoSaid() {
    let asks = Asks()
    let flow = CommitFlow()

    flow.prefill(asks.context)
    XCTAssertTrue(flow.preflightState.isLoading)
    flow.prefill(asks.context)
    XCTAssertEqual(asks.preflights.count, 1, "a second prefill while one is pending must not ask")

    asks.preflights[0](.success(VCSCommitPreflight(sequencer: "merge", amendTarget: "abc Last")))

    XCTAssertTrue(flow.preflightState.isReady)
    XCTAssertEqual(flow.sequencer, "merge")
    XCTAssertEqual(flow.amendTarget, "abc Last")
    XCTAssertEqual(flow.phase, .editing)
  }

  func testAFailedPreflightIsShownAndCanBeRetried() {
    let asks = Asks()
    let flow = CommitFlow()

    flow.prefill(asks.context)
    asks.preflights[0](.failure(Failure()))

    XCTAssertEqual(
      flow.phase,
      .failed(
        VCSSyncPresenter.commitFailureDialog(.other("the repository went away"), mode: .commit)))
    XCTAssertFalse(flow.preflightState.isReady)

    flow.commit(mode: .commit, asks.context)
    XCTAssertEqual(asks.preflights.count, 2, "a press after a failed preflight retries it")
    XCTAssertTrue(asks.commits.isEmpty, "and never commits without one")
  }

  // MARK: Staged-work check

  func testStagedWorkAtRiskAsksForConfirmationBeforeCommitting() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commitChecking(mode: .commit, asks.context)
    XCTAssertEqual(asks.stagedChecks.map(\.files), [[Self.file("a.swift")]])
    asks.stagedChecks[0].reply(.success(["a.swift"]))

    XCTAssertEqual(flow.phase, .confirmingStagedLoss(["a.swift"]))
    XCTAssertTrue(asks.commits.isEmpty)

    flow.commit(mode: .commit, asks.context)
    XCTAssertEqual(flow.phase, .committing)
    XCTAssertEqual(asks.commits.count, 1)
  }

  func testNothingAtRiskCommitsTheDraftAsItIsWhenTheCheckLands() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commitChecking(mode: .commit, asks.context)
    asks.draft = CommitFlow.Draft(message: "Edited meanwhile", files: [Self.file("b.swift")])
    asks.stagedChecks[0].reply(.success([]))

    XCTAssertEqual(flow.phase, .committing)
    XCTAssertEqual(
      asks.commits.map(\.request),
      [VCSCommitRequest(message: "Edited meanwhile", files: [Self.file("b.swift")], mode: .commit)])
  }

  /// The concurrent-commit race: Amend is pressable while the staged check runs, and the check's
  /// late answer must not stamp `.confirmingStagedLoss` over the amend already in flight — that
  /// would re-enable the primary button and let a second commit through on the same repo.
  func testALateStagedCheckNeverReopensACommitInFlight() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commitChecking(mode: .commit, asks.context)
    flow.commit(mode: .amendMessage, asks.context)
    XCTAssertEqual(flow.phase, .committing)

    asks.stagedChecks[0].reply(.success(["a.swift"]))
    XCTAssertEqual(flow.phase, .committing, "the late check must not reopen the dialog")

    asks.stagedChecks.removeAll()
    flow.commitChecking(mode: .commit, asks.context)
    asks.stagedChecks.first?.reply(.success([]))
    XCTAssertEqual(asks.commits.count, 1, "no second commit while one is in flight")
  }

  func testAFailedStagedCheckIsShownRatherThanCommitting() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commitChecking(mode: .commit, asks.context)
    asks.stagedChecks[0].reply(.failure(Failure()))

    XCTAssertEqual(
      flow.phase,
      .failed(
        VCSSyncPresenter.commitFailureDialog(.other("the repository went away"), mode: .commit)))
    XCTAssertTrue(asks.commits.isEmpty)
  }

  // MARK: Commit outcomes

  func testACleanCommitClosesTheSheet() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commit(mode: .commit, asks.context)
    flow.commit(mode: .commit, asks.context)
    XCTAssertEqual(asks.commits.count, 1, "a second press while committing does nothing")

    asks.commits[0].reply(.ok(summary: "Fix the thing", revision: "abc"))
    XCTAssertEqual(asks.dismissals, 1)
  }

  func testAmendSendsNoPaths() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commitChecking(mode: .amendMessage, asks.context)

    XCTAssertTrue(
      asks.stagedChecks.isEmpty, "amend takes no pathspec, so there is nothing to check")
    XCTAssertEqual(
      asks.commits.map(\.request),
      [VCSCommitRequest(message: "Fix the thing", files: [], mode: .amendMessage)])
  }

  func testACommitThatLandedThenFailedIsSpent() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commit(mode: .commit, asks.context)
    asks.commits[0].reply(.committedThenFailed(revision: "abc", detail: "post-commit: boom"))

    guard case .landedThenFailed(let dialog) = flow.phase else {
      return XCTFail("expected .landedThenFailed, got \(flow.phase)")
    }
    XCTAssertEqual(dialog.details, "post-commit: boom")
    XCTAssertTrue(flow.isSpent)
    XCTAssertEqual(asks.dismissals, 0)

    flow.prefill(asks.context)
    XCTAssertTrue(asks.preflights.isEmpty, "a spent flow reads nothing more")
  }

  func testAnUnknownOutcomeIsSpentNotARetryableFailure() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commit(mode: .commit, asks.context)
    asks.commits[0].reply(.failed(.outcomeUnknown("connection lost")))

    XCTAssertEqual(
      flow.phase,
      .outcomeUnknown(
        VCSSyncPresenter.commitFailureDialog(.outcomeUnknown("connection lost"), mode: .commit)))
    XCTAssertTrue(flow.isSpent)
  }

  func testARejectedCommitCanBeRetriedThroughTheStagedCheck() {
    let asks = Asks()
    let flow = readyFlow(asks)

    flow.commit(mode: .commit, asks.context)
    asks.commits[0].reply(.failed(.hookRejected("lint: 2 problems")))

    XCTAssertEqual(
      flow.phase,
      .failed(
        VCSSyncPresenter.commitFailureDialog(.hookRejected("lint: 2 problems"), mode: .commit)))
    XCTAssertFalse(flow.isSpent)

    flow.commitChecking(mode: .commit, asks.context)
    XCTAssertEqual(asks.stagedChecks.count, 1, "a retry after a rejection is checked too")
  }
}
