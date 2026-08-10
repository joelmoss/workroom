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
    // A child that CHOSE its exit status is not signalled, so 3 really is an exit code here. This is
    // the baseline the flag distinguishes from a 9/15 that only looks like one.
    XCTAssertFalse(r.signaled)
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
    // ORDERING LOCK: the timeout path SIGTERMs the child, so a timed-out result carries `signaled`
    // too and `exitCode` is the signal number, not an exit status. Every classifier must therefore
    // test `timedOut` BEFORE `signaled` — see `WorkroomStatusResolver.classifyGitHubCLI`.
    XCTAssertTrue(r.signaled, "our timeout kills the child, so a timeout is also a signal")
    XCTAssertEqual(r.exitCode, 15)  // SIGTERM, not something `sleep` chose
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
    // The result shape a cancelled probe actually has — and the one `classifyGitHubCLI` used to read
    // as a logout. Killed by SIGKILL, so `exitCode` is the SIGNAL NUMBER (9), `timedOut` is false
    // (the 30s deadline never fired), and stdout is empty or half-written. Nothing here is evidence
    // about gh's auth state, which is why the flag exists.
    XCTAssertTrue(r.signaled, "a cancelled probe's child was killed by a signal")
    XCTAssertFalse(r.timedOut, "cancellation is not a timeout")
    XCTAssertEqual(r.exitCode, 9)  // SIGKILL, not a CLI exit status
  }

  /// A missing cwd must classify as `launchFailed`, NOT `commandNotFound` — the two are different
  /// facts (nothing ran at all vs. `env` ran and searched PATH), and every consumer that reads 127
  /// as "tool not installed" would otherwise misdiagnose a deleted workroom as a missing git/jj/gh.
  func testLaunchFailureInMissingDirIsLaunchFailedNotCommandNotFound() async {
    let r = await runner.run(
      "git", ["status"], in: "/no/such/dir-\(UUID().uuidString)", timeout: 5)
    XCTAssertEqual(r.exitCode, CommandResult.launchFailed)
    XCTAssertNotEqual(
      r.exitCode, CommandResult.commandNotFound,
      "a vanished directory is not the same fact as env searching PATH and failing")
    XCTAssertFalse(r.stderr.isEmpty, "the underlying launch error must be preserved for diagnosis")
    // Nothing was ever spawned, so nothing was signalled — this must stay a clean, fixed sentinel.
    XCTAssertFalse(r.signaled)
  }

  // MARK: stdin

  /// A child must never inherit the app's stdin. Unpinned it does, and under `make app-run` that is a
  /// real terminal — so a prompting `git`/`ssh` could block on a tty the Finder-launched build won't
  /// have. Pinned to /dev/null, any read is an immediate EOF. `read` returns non-zero at EOF, so the
  /// assertion is that this returns AT ALL rather than hitting the timeout.
  func testStdinIsNullDeviceSoAPromptingChildGetsEOF() async {
    let r = await runner.run(
      "sh", ["-c", "read x; printf 'got=[%s]' \"$x\""], in: tmp, timeout: 5)
    XCTAssertFalse(r.timedOut, "a child reading stdin must hit EOF, not block until the timeout")
    XCTAssertEqual(r.stdout, "got=[]")
  }

  // MARK: network environment (pure)

  func testNetworkEnvironmentForwardsAuthVarsFromTheProbe() {
    let env = StatusCommandRunner.networkEnvironment(
      base: ["PATH": "/usr/bin"],
      probed: [
        "SSH_AUTH_SOCK": "/tmp/agent.sock", "SSH_AGENT_PID": "42",
        "GIT_CONFIG_GLOBAL": "/home/me/.gitconfig", "XDG_CONFIG_HOME": "/home/me/.config",
        "IRRELEVANT": "nope",
      ])
    XCTAssertEqual(env["SSH_AUTH_SOCK"], "/tmp/agent.sock")
    XCTAssertEqual(env["SSH_AGENT_PID"], "42")
    XCTAssertEqual(env["GIT_CONFIG_GLOBAL"], "/home/me/.gitconfig")
    XCTAssertEqual(env["XDG_CONFIG_HOME"], "/home/me/.config")
    XCTAssertNil(env["IRRELEVANT"], "only the allowlist is forwarded, not the whole probed env")
  }

  func testNetworkEnvironmentPinsBatchModeAndAskpassRequire() {
    let env = StatusCommandRunner.networkEnvironment(base: [:], probed: [:])
    XCTAssertEqual(env["GIT_SSH_COMMAND"], "ssh -o BatchMode=yes")
    XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "never")
  }

  /// A user's own `GIT_SSH_COMMAND` commonly carries `-i <key>` or a proxy command. It must survive.
  func testNetworkEnvironmentAppendsToAUserGitSshCommand() {
    let env = StatusCommandRunner.networkEnvironment(
      base: [:], probed: ["GIT_SSH_COMMAND": "ssh -i /home/me/.ssh/work"])
    XCTAssertEqual(env["GIT_SSH_COMMAND"], "ssh -i /home/me/.ssh/work -o BatchMode=yes")
  }

  /// If the app was launched from a shell that already had the variable, that value is at least as
  /// current as the probe's — the inherited one wins.
  func testNetworkEnvironmentPrefersInheritedOverProbed() {
    let env = StatusCommandRunner.networkEnvironment(
      base: ["SSH_AUTH_SOCK": "/inherited.sock"], probed: ["SSH_AUTH_SOCK": "/probed.sock"])
    XCTAssertEqual(env["SSH_AUTH_SOCK"], "/inherited.sock")
  }

  func testNetworkEnvironmentClearsAskpassAndDisplay() {
    let env = StatusCommandRunner.networkEnvironment(
      base: ["SSH_ASKPASS": "/usr/bin/gui-prompt", "DISPLAY": ":0"], probed: [:])
    XCTAssertNil(env["SSH_ASKPASS"], "ssh must not find a graphical prompt helper")
    XCTAssertNil(env["DISPLAY"])
  }

  func testNetworkEnvironmentIgnoresEmptyProbedValues() {
    let env = StatusCommandRunner.networkEnvironment(base: [:], probed: ["SSH_AUTH_SOCK": ""])
    XCTAssertNil(env["SSH_AUTH_SOCK"], "an empty value is worse than absent — it looks configured")
  }

  // MARK: network environment (reaches the child)

  func testRunNetworkSetsBatchModeInTheChild() async {
    let r = await runner.runNetwork(
      "sh", ["-c", "printf '%s|%s' \"$GIT_SSH_COMMAND\" \"$SSH_ASKPASS_REQUIRE\""],
      in: tmp, timeout: 5)
    XCTAssertTrue(r.ok)
    XCTAssertTrue(r.stdout.hasSuffix("|never"), "got \(r.stdout)")
    XCTAssertTrue(r.stdout.contains("-o BatchMode=yes"), "got \(r.stdout)")
  }

  /// The hardening is scoped to network ops: a plain status read keeps the environment it always had,
  /// so the automatic sweep's behaviour is unchanged by this feature.
  ///
  /// Asserted differentially rather than against a literal empty string — `run` inherits the process
  /// environment, so a machine that legitimately exports `GIT_SSH_COMMAND` would fail an absolute
  /// assertion. The invariant that actually matters is that only `runNetwork` adds the BatchMode flag.
  func testOnlyRunNetworkAddsBatchMode() async {
    let script = "printf '%s' \"$GIT_SSH_COMMAND\""
    let plain = await runner.run("sh", ["-c", script], in: tmp, timeout: 5)
    let network = await runner.runNetwork("sh", ["-c", script], in: tmp, timeout: 5)
    XCTAssertTrue(plain.ok)
    XCTAssertTrue(network.ok)
    XCTAssertFalse(
      plain.stdout.contains("-o BatchMode=yes"), "plain run must not be hardened: \(plain.stdout)")
    let expectedBase = plain.stdout.isEmpty ? "ssh" : plain.stdout
    XCTAssertEqual(network.stdout, "\(expectedBase) -o BatchMode=yes")
  }
}
