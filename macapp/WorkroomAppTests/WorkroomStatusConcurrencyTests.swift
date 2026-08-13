import XCTest

@testable import Workroom

/// Counts in-flight `workingStatus` calls and records the peak seen — the invariant
/// `AppStore.runLocalSweep`'s `cap`-bounded `withTaskGroup` fan-out must hold, and had ZERO test
/// coverage before this file (confirmed by grep: no hits for `runLocalSweep`/`localConcurrency` in
/// this test target). Shared by any status double that needs to prove it never over-runs.
private final class InFlightCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var current = 0
  private(set) var peak = 0

  func enter() {
    lock.lock()
    current += 1
    peak = max(peak, current)
    lock.unlock()
  }
  func leave() {
    lock.lock()
    current -= 1
    lock.unlock()
  }
}

/// A `GitStatusReading` double that holds briefly while counting concurrent callers — long enough
/// that more than `cap` probes would visibly overlap if the fan-out weren't actually bounded, short
/// enough the test doesn't feel it (8 items / cap 5 ⇒ two sequential batches of ~20ms).
private struct CountingGitStatus: GitStatusReading {
  let counter: InFlightCounter
  func workingStatus(root: URL) throws -> GitWorkingStatus {
    counter.enter()
    defer { counter.leave() }
    Thread.sleep(forTimeInterval: 0.02)
    return GitWorkingStatus(
      dirty: false, conflicted: false, files: [], branch: nil, insertions: nil, deletions: nil)
  }
}

/// Reports every tool as missing (exit 127) so `refreshGitHubCLI` resolves to "not available" and
/// the sweep's CI stage never fires a real `gh` process — this test is only about the LOCAL stage's
/// concurrency bound.
private struct MissingToolRunner: StatusCommandRunning {
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    CommandResult(stdout: "", stderr: "", exitCode: CommandResult.commandNotFound, timedOut: false)
  }
}

/// REGRESSION (Muxy test-practices review, filed in TODOS.md — "N-in-flight concurrency accounting
/// test for status sweeps"): `WorkroomStatusResolver.resolveGit`/`resolveJJ` called `GitProvider()`/
/// `RustJJProvider()` directly, bypassing any injection seam, so this invariant was untestable until
/// `GitStatusReading`/`JJStatusReading` existed.
final class WorkroomStatusConcurrencyTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  /// A throwaway, empty directory standing in for a project root — `resolveLocal`'s `fileExists`
  /// guard must pass, but nothing inside it is ever read (the injected double never touches disk).
  private func throwawayProject(_ name: String) -> Project {
    let path = NSTemporaryDirectory() + "wr-cap-\(name)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    dirs.append(path)
    return Project(path: path, vcs: "git", workrooms: [])
  }

  /// More work items than the sweep's cap, across DIFFERENT projects (so `JJSnapshotGate`'s
  /// per-project serialization can't be mistaken for the thing bounding concurrency — these are all
  /// git anyway, which is never gated): asserts `runLocalSweep` never lets more than 5 local probes
  /// run at once, and that the fan-out actually overlaps at all (else this would pass even fully
  /// serial, proving nothing).
  @MainActor
  func testLocalSweepNeverExceedsItsConcurrencyCap() async {
    let store = AppStore()
    store.projects = (0..<8).map { throwawayProject("\($0)") }

    let counter = InFlightCounter()
    store.statusResolver = WorkroomStatusResolver(
      runner: MissingToolRunner(), gitStatus: CountingGitStatus(counter: counter))

    store.refreshWorkroomStatuses(force: true)
    await store.statusSweepTask?.value

    // Mirrors `AppStore.localConcurrency` (`AppStore+WorkroomStatus.swift`), which is `fileprivate`
    // and so not reachable here by name — a change to that constant should update this literal too.
    XCTAssertLessThanOrEqual(
      counter.peak, 5, "runLocalSweep let more than its cap of 5 local probes run at once")
    XCTAssertGreaterThan(
      counter.peak, 1,
      "the fan-out never actually overlapped — this test would pass even against a fully serial "
        + "sweep, so it isn't proving the cap does any work")
  }
}
