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

  func testLaunchFailureInMissingDirIsCommandNotFound() async {
    let r = await runner.run(
      "git", ["status"], in: "/no/such/dir-\(UUID().uuidString)", timeout: 5)
    XCTAssertEqual(r.exitCode, CommandResult.commandNotFound)
  }
}
