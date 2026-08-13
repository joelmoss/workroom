import XCTest

@testable import Workroom

/// `withTimeout` had zero test coverage before this file, despite being the timeout seam every VCS
/// read in the app relies on (`WorkroomStatusResolver`, `BranchResolver`, `JJSnapshotGate`'s own
/// internal use). Covers the pre-existing success/deadline races plus the cancellation-propagation
/// fix (VCS-foundation eng-review, `/review` follow-up): `withTimeout` used to only race its own
/// internal deadline against the operation, never observing the CALLING task being cancelled from
/// outside, so a superseded caller (e.g. a new status sweep replacing an old one) waited out the
/// full race anyway instead of returning as soon as it stopped caring.
final class TimeoutTests: XCTestCase {

  func testReturnsTheOperationsResultWhenItFinishesFirst() async throws {
    let result = try await withTimeout(seconds: 5) { 42 }
    XCTAssertEqual(result, 42)
  }

  func testPropagatesTheOperationsOwnThrownError() async {
    struct Boom: Error {}
    do {
      _ = try await withTimeout(seconds: 5) { throw Boom() }
      XCTFail("expected Boom to propagate")
    } catch is Boom {
    } catch {
      XCTFail("expected Boom, got \(error)")
    }
  }

  func testThrowsVCSTimeoutErrorWhenTheDeadlineElapsesFirst() async {
    let started = Date()
    do {
      _ = try await withTimeout(seconds: 0.05) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 1
      }
      XCTFail("expected VCSTimeoutError")
    } catch is VCSTimeoutError {
    } catch {
      XCTFail("expected VCSTimeoutError, got \(error)")
    }
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 1.0,
      "the deadline is 0.05s — this should not have waited anywhere near 1s")
  }

  /// REGRESSION: the calling task being cancelled from outside must settle the wait immediately,
  /// not after the full `seconds:` deadline. Uses a 5s deadline and a 5s operation — either path
  /// NOT observing cancellation would make this test itself hang for ~5s, so a tight assertion on
  /// elapsed time is the actual mechanism under test, not an incidental nicety.
  func testCallerCancellationSettlesTheWaitImmediately() async throws {
    let started = Date()
    let task = Task {
      try await withTimeout(seconds: 5) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 1
      }
    }
    // Give the operation a moment to actually start (so this exercises the "cancelled mid-race"
    // ordering, not just "cancelled before it began" — that's the next test).
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected VCSCancellationError")
    } catch is VCSCancellationError {
    } catch {
      XCTFail("expected VCSCancellationError, got \(error)")
    }
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 1.0,
      "cancellation should settle well under the 5s deadline and 5s operation")
  }

  /// The other ordering `TimeoutCancelBox` has to handle: the task is ALREADY cancelled before
  /// `withTimeout` even starts racing, so Swift may invoke `onCancel` before the operation/deadline
  /// race's own cancel handler ever attaches.
  func testAlreadyCancelledCallerNeverWaitsOnTheRace() async throws {
    let started = Date()
    let task = Task {
      try await withTimeout(seconds: 5) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 1
      }
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected VCSCancellationError or CancellationError")
    } catch is VCSCancellationError {
    } catch is CancellationError {
      // Swift's own Task machinery can short-circuit an already-cancelled task before its body
      // runs at all — still proves no 5s wait, which is what this test actually guards.
    } catch {
      XCTFail("expected VCSCancellationError or CancellationError, got \(error)")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
  }

  /// Stress the exactly-once guarantee under a race: cancellation firing at nearly the same instant
  /// the operation naturally completes must never double-resume the continuation (a
  /// "SWIFT TASK CONTINUATION MISUSE" trap would crash the process, not fail an assertion — this
  /// test's real value is running clean at all across many iterations, not the counter it returns).
  func testCancellationRacingCompletionNeverDoubleSettles() async {
    for _ in 0..<200 {
      let task = Task {
        try await withTimeout(seconds: 5) { 1 }
      }
      task.cancel()
      _ = try? await task.value
    }
  }
}
