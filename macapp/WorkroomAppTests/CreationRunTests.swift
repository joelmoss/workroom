import Foundation
import WorkroomDomain
import XCTest

@testable import Workroom

/// A create's progress model (#483): the step plan each kind shows up front, and how the step
/// events the CLI and the drivers send move each row through its states.
@MainActor
final class CreationRunTests: XCTestCase {
  /// A clock the test moves by hand, so durations are exact.
  private final class Clock {
    var now = Date(timeIntervalSinceReferenceDate: 1000)
    func advance(_ seconds: TimeInterval) { now += seconds }
  }

  private let project = Project(path: "/p", vcs: "git", workrooms: [])

  private func run(_ kind: CreationKind = .local, clock: Clock = Clock()) -> CreationRun {
    CreationRun(
      project: project, kind: kind, splitAnchor: nil, previousSelection: nil,
      now: { clock.now })
  }

  private func states(_ run: CreationRun) -> [String: CreationStep.State] {
    Dictionary(uniqueKeysWithValues: run.steps.map { ($0.id, $0.state) })
  }

  /// Value: protects=every kind lists its whole plan, in the spec's order and titles, from the first
  /// frame; fails_when=a step is missing, reordered or retitled; no_claim=none beyond protects
  func testEachKindListsItsWholePlanUpFront() {
    XCTAssertEqual(
      run(.local).steps.map(\.title), ["Fetch base branch", "Create worktree", "Run setup script"])
    XCTAssertEqual(
      run(.container(.docker)).steps.map(\.id),
      ["repository", "image", "machine", "connect", "clone", "checkout"])
    XCTAssertEqual(run(.container(.docker)).steps[2].title, "Start container")
    XCTAssertEqual(
      run(.boxd).steps.map(\.title),
      [
        "Check repository", "Check boxd account", "Create machine", "Set up machine", "Connect",
        "Clone repository", "Check out branch",
      ])
    XCTAssertEqual(
      run(.exeDev).steps.map(\.id),
      ["repository", "account", "machine", "boot", "setup", "connect", "clone", "checkout"])
    XCTAssertEqual(run(.exeDev).steps[1].title, "Check exe.dev account")
    XCTAssertEqual(run(.exeDev).steps[2].title, "Create VM")
    XCTAssertTrue(run(.boxd).steps.allSatisfy { $0.state == .pending })
    XCTAssertEqual(run(.boxd).outcome, .running)
  }

  /// Value: protects=begin ends the running step done and skips the pending steps it jumped;
  /// fails_when=the previous step stays running or a jumped step stays pending; no_claim=none
  /// beyond protects
  func testBeginEndsTheRunningStepAndSkipsTheOnesItJumped() {
    let run = run(.boxd)
    run.begin("repository")
    run.begin("machine")
    XCTAssertEqual(states(run)["repository"], .done)
    XCTAssertEqual(states(run)["account"], .skipped(reason: nil))
    XCTAssertEqual(states(run)["machine"], .running)
    XCTAssertEqual(states(run)["setup"], .pending)

    run.begin("machine")
    XCTAssertEqual(states(run)["machine"], .running, "a step announced twice keeps running")
  }

  /// Value: protects=the CLI's done, warning and skipped events end their row with the reason as
  /// sent; fails_when=finish drops the reason or leaves the row running; no_claim=none beyond
  /// protects
  func testFinishEndsARowAsTheEventSays() {
    let run = run(.local)
    run.finish("fetch", as: .skipped(reason: "No remote to fetch from"))
    run.begin("worktree")
    run.finish("worktree", as: .done)
    run.finish("script", as: .warning("slow"))
    XCTAssertEqual(
      run.steps.map(\.state),
      [.skipped(reason: "No remote to fetch from"), .done, .warning("slow")])
    XCTAssertNil(run.runningStep)
  }

  /// Value: protects=succeed ends the running step done and skips the rest; fails_when=a step stays
  /// pending or running after success; no_claim=none beyond protects
  func testSucceedSkipsWhatNeverRan() {
    let run = run(.local)
    run.begin("worktree")
    run.succeed()
    XCTAssertEqual(
      run.steps.map(\.state), [.skipped(reason: nil), .done, .skipped(reason: nil)])
    XCTAssertEqual(run.outcome, .succeeded)
  }

  /// Value: protects=O4, a failure marks the running step failed and skips every later one, so
  /// every row ends in a final state (AC 3); fails_when=later steps stay pending or the failed row
  /// isn't marked; no_claim=none beyond protects
  func testFailMarksTheRunningStepAndSkipsTheRest() {
    let run = run(.container(.docker))
    run.begin("repository")
    run.begin("image")
    run.fail(.remoteFailed(message: "boom", leftBehind: false))
    XCTAssertEqual(
      run.steps.map(\.state),
      [
        .done, .failed, .skipped(reason: nil), .skipped(reason: nil), .skipped(reason: nil),
        .skipped(reason: nil),
      ])
    XCTAssertEqual(run.outcome, .remoteFailed(message: "boom", leftBehind: false))
  }

  /// Value: protects=a failure before any step began marks the first step failed; fails_when=no row
  /// shows what failed; no_claim=none beyond protects
  func testAFailureBeforeAnyStepMarksTheFirst() {
    let run = run(.local)
    run.fail(.failedBeforeWorkroom(message: "no"))
    XCTAssertEqual(run.steps.map(\.state), [.failed, .skipped(reason: nil), .skipped(reason: nil)])
  }

  /// Value: protects=a step the CLI already marked failed stays the failed one; fails_when=the next
  /// pending step is marked failed too; no_claim=none beyond protects
  func testAFailAfterTheStepFailedItselfMarksNothingElse() {
    let run = run(.local)
    run.begin("worktree")
    run.begin("script")
    run.finish("script", as: .failed)
    run.fail(.setupScriptFailed(message: "exit 1"))
    XCTAssertEqual(run.steps.map(\.state), [.skipped(reason: nil), .done, .failed])
  }

  /// Value: protects=durations come from the injected clock: start at begin, end at the next begin;
  /// fails_when=durations use the wall clock or a step's end is not stamped; no_claim=how the pane
  /// formats them
  func testDurationsComeFromTheInjectedClock() {
    let clock = Clock()
    let run = run(.local, clock: clock)
    run.begin("fetch")
    clock.advance(4)
    run.begin("worktree")
    clock.advance(72)
    run.succeed()
    XCTAssertEqual(run.steps[0].duration, 4)
    XCTAssertEqual(run.steps[1].duration, 72)
    XCTAssertNil(run.steps[2].duration, "a skipped step never ran")
  }

  /// Value: protects=D8, the account step waits for the user with its timer paused, and carrying on
  /// restarts it from zero; fails_when=the wait counts toward the step's time or the step never
  /// returns to running; no_claim=the pane's glyph and copy
  func testWaitingForTheUserPausesTheTimerAndCarryingOnRestartsIt() {
    let clock = Clock()
    let run = run(.boxd, clock: clock)
    run.begin("account")
    clock.advance(2)
    run.waitForUser("account")
    XCTAssertEqual(states(run)["account"], .waitingForUser)
    XCTAssertEqual(run.runningStep?.id, "account", "a waiting step is still the current one")
    clock.advance(300)
    run.begin("account")
    XCTAssertEqual(states(run)["account"], .running)
    clock.advance(3)
    run.begin("machine")
    XCTAssertEqual(run.steps[1].duration, 3, "only the time after carrying on counts")
  }

  /// Value: protects=log lines land on their own step, ANSI-stripped, and an untagged or unknown
  /// one on the running step, else the first; fails_when=a line is lost or filed under the wrong
  /// row; no_claim=none beyond protects
  func testLogLinesLandOnTheirStepAndStrayOnesOnTheRunningStep() {
    let run = run(.local)
    run.append("before anything", to: nil)
    run.begin("worktree")
    run.append("$ git worktree add", to: "worktree")
    run.append("\u{1B}[32mgreen\u{1B}[0m", to: "script")
    run.append("stray", to: "sayStatus")
    XCTAssertEqual(run.steps[0].log, ["before anything"])
    XCTAssertEqual(run.steps[1].log, ["$ git worktree add", "stray"])
    XCTAssertEqual(run.steps[2].log, ["green"])
  }

  /// Value: protects=the step circle counts done, warning and skipped as complete and names the
  /// running step; fails_when=skipped steps are left out of the fraction; no_claim=the circle's
  /// drawing
  func testProgressCountsSkippedAsCompleteAndNamesTheRunningStep() {
    let run = run(.local)
    run.finish("fetch", as: .skipped(reason: nil))
    run.begin("worktree")
    XCTAssertEqual(run.progress.fraction, 1.0 / 3)
    XCTAssertEqual(run.progress.label, "Create worktree")
  }

  /// Value: protects=the destination text the pane's subtitle and the provisional row share;
  /// fails_when=a kind names the wrong place; no_claim=none beyond protects
  func testEachKindNamesItsDestination() {
    XCTAssertEqual(CreationKind.local.destination, "This Mac")
    XCTAssertEqual(CreationKind.container(.apple).destination, "Apple Container")
    XCTAssertEqual(CreationKind.boxd.destination, "boxd")
    XCTAssertEqual(CreationKind.exeDev.destination, "exe.dev")
  }
}
