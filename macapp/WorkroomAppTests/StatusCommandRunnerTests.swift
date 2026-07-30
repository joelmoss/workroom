import XCTest

@testable import Workroom

/// Direct tests of the real `StatusCommandRunner` against real shell tools (no git/jj repo): the
/// concurrent drain, the byte cap, the timeout→terminate path, and the launch-failure path — the
/// deadlock-/crash-free guarantees the whole status layer rests on.
final class StatusCommandRunnerTests: XCTestCase {
  private let runner = StatusCommandRunner(maxBytes: 64 * 1024)
  private let tmp = NSTemporaryDirectory()

  func testCapturesStdoutStderrAndExitCode() async {
    let r = await runner.run(
      "sh", ["-c", "printf out; printf err 1>&2; exit 3"], in: tmp, timeout: 5)
    XCTAssertEqual(r.stdout, "out")
    XCTAssertEqual(r.stderr, "err")
    XCTAssertEqual(r.exitCode, 3)
    XCTAssertFalse(r.timedOut)
    XCTAssertFalse(r.ok)
  }

  func testLargeOutputCappedWithoutDeadlock() async {
    // ~1MB of output, far over the 64KB cap. The drain must keep reading past the cap (so the
    // child never blocks on a full pipe buffer) while retaining only `maxBytes`. Must finish fast.
    let r = await runner.run("sh", ["-c", "yes aaaa | head -n 200000"], in: tmp, timeout: 10)
    XCTAssertEqual(r.exitCode, 0)
    XCTAssertFalse(r.timedOut)
    XCTAssertFalse(r.stdout.isEmpty)
    XCTAssertLessThanOrEqual(r.stdout.utf8.count, 64 * 1024)
  }

  func testTimeoutTerminatesAndFlags() async {
    let r = await runner.run("sh", ["-c", "sleep 10"], in: tmp, timeout: 0.3)
    XCTAssertTrue(r.timedOut)
    XCTAssertFalse(r.ok)
  }

  func testSigtermIgnoringChildIsSigkilledAndStillReturns() async {
    // A child that traps SIGTERM must NOT hang the continuation forever: the hard-kill fallback
    // SIGKILLs it ~2s after the timeout, terminationHandler fires, and the bounded drain resumes.
    // Assert the call returns (flagged timed-out) well within the SIGKILL grace rather than hanging.
    let start = Date()
    let r = await runner.run("sh", ["-c", "trap '' TERM; sleep 30"], in: tmp, timeout: 0.3)
    XCTAssertTrue(r.timedOut)
    XCTAssertFalse(r.ok)
    XCTAssertLessThan(Date().timeIntervalSince(start), 8)  // not the 30s sleep
  }

  func testCancellingAProbeDoesNotBlockTheCancellingThread() async {
    // `withTaskCancellationHandler`'s `onCancel` runs synchronously on whichever thread calls
    // `cancel()`, and the hottest canceller is the MAIN thread — every selection change supersedes the
    // in-flight status probe. The kill walks the child's process tree with a blocking `pgrep -P` per
    // node, so inline it stalled that thread for the whole walk (and a blocking wait spins a nested run
    // loop, reordering queued main-queue work against SwiftUI's update — how this surfaced).
    //
    // A wide child tree makes the difference unmissable: ~40 children means ~41 sequential `pgrep`
    // spawns, several hundred ms inline. The bound below sits well under that and far above the cost of
    // simply enqueueing the work.
    let runner = self.runner
    let tmp = self.tmp
    let task = Task {
      await runner.run(
        "sh", ["-c", "for i in $(seq 40); do sleep 30 & done; wait"], in: tmp, timeout: 30)
    }
    // Let the tree actually spawn, or the walk would have nothing to traverse and this would pass
    // against the blocking version too.
    try? await Task.sleep(nanoseconds: 700_000_000)

    let start = Date()
    task.cancel()
    let blocked = Date().timeIntervalSince(start)

    XCTAssertLessThan(blocked, 0.3, "cancelling a probe blocked the cancelling thread on the kill")
    // And the kill still lands: the probe resumes instead of running out its 30s sleep.
    let r = await task.value
    XCTAssertFalse(r.ok, "a cancelled probe's result is abandoned, not a success")
    XCTAssertLessThan(Date().timeIntervalSince(start), 10, "not the 30s sleep")
  }

  func testLaunchFailureInMissingDirIsCommandNotFound() async {
    let r = await runner.run(
      "git", ["status"], in: "/no/such/dir-\(UUID().uuidString)", timeout: 5)
    XCTAssertEqual(r.exitCode, CommandResult.commandNotFound)
  }
}
