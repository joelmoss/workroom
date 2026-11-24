import Synchronization
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// Tests for the live filesystem watch that keeps the selected workroom's VCS status current
/// (issue #24 follow-up): the FSEvents watcher fires on a real change, the jj-internal churn
/// filters, and the root-branch watch target.
final class WorkroomFileWatcherTests: XCTestCase {

  // MARK: - jj-internal churn filters (a colocated repo left from jj can still have `jj` run in it)

  func testIsJJInternalPath() {
    // A `.jj` path component ⇒ internal (jj writes here; Workroom never does).
    XCTAssertTrue(AppStore.isJJInternalPath("/repo/.jj/working_copy/checkout"))
    XCTAssertTrue(AppStore.isJJInternalPath("/repo/.jj"))
    // Working files are not internal — these must still trigger a refresh.
    XCTAssertFalse(AppStore.isJJInternalPath("/repo/src/main.swift"))
    XCTAssertFalse(AppStore.isJJInternalPath("/repo"))
    // Component-based, so a file merely *named* like `.jj…` isn't treated as internal.
    XCTAssertFalse(AppStore.isJJInternalPath("/repo/.jjconfig.toml"))
  }

  /// The Files tree's reload filter: `.git/` and `.jj/` churn alone never reloads; a real edit, or an
  /// overflowed batch, always does.
  func testFileTreeIgnoresGitAndJJInternalChurn() {
    XCTAssertFalse(FileTreeModel.isRelevantChange(["/repo/.git/index"], overflow: false))
    XCTAssertFalse(FileTreeModel.isRelevantChange(["/repo/.jj/repo/op_heads/x"], overflow: false))
    XCTAssertFalse(
      FileTreeModel.isRelevantChange(["/repo/.git/HEAD", "/repo/.jj/x"], overflow: false))
    XCTAssertTrue(
      FileTreeModel.isRelevantChange(["/repo/.jj/x", "/repo/src/main.swift"], overflow: false))
    XCTAssertTrue(FileTreeModel.isRelevantChange(["/repo/.jj/x"], overflow: true))
  }

  // MARK: - VCS metadata dir (WorkroomLifecycle.vcsMetadataDir — root-branch watch target, #3)

  func testVCSMetadataDir() {
    // git maps to the metadata dir whose changes signal a branch move.
    XCTAssertEqual(WorkroomLifecycle.vcsMetadataDir(path: "/repo", vcs: "git"), "/repo/.git")
    // Trailing slash is normalized by appendingPathComponent (no double slash).
    XCTAssertEqual(WorkroomLifecycle.vcsMetadataDir(path: "/repo/", vcs: "git"), "/repo/.git")
    // Unknown vcs ⇒ no watch target — including a stale "jj" from an old config.
    XCTAssertNil(WorkroomLifecycle.vcsMetadataDir(path: "/repo", vcs: "hg"))
    XCTAssertNil(WorkroomLifecycle.vcsMetadataDir(path: "/repo", vcs: "jj"))
  }

  // MARK: - WorkroomFileWatcher (real FSEvents)

  @MainActor
  func testWatcherFiresOnFileChange() async throws {
    let dir = NSTemporaryDirectory() + "wfw-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let changed = expectation(description: "watcher reports a filesystem change")
    changed.assertForOverFulfill = false  // FSEvents may coalesce into ≥1 callbacks
    let watcher = WorkroomFileWatcher(latency: 0.2) { _ in changed.fulfill() }
    watcher.start(path: dir)
    defer { watcher.stop() }

    // Give FSEvents a beat to arm before mutating, so the write lands inside the stream's window.
    try await Task.sleep(nanoseconds: 300_000_000)
    try "hello".write(toFile: dir + "/file.txt", atomically: true, encoding: .utf8)

    await fulfillment(of: [changed], timeout: 5)
  }

  /// `stop()` is idempotent and safe before any `start` (deinit path / no-selection teardown).
  @MainActor
  func testWatcherStopWithoutStartIsSafe() {
    let watcher = WorkroomFileWatcher { _ in }
    watcher.stop()
    watcher.stop()
  }

  // MARK: - Leading + trailing coalescing (the create-time FSEvents storm fix)

  @MainActor private final class Sink {
    var count = 0
    var paths = Set<String>()
  }

  /// A sustained write burst (spread past the coalescing window, the case where FSEvents' own
  /// `latency` breaks down and delivers ~one callback per flush) must collapse to a small, bounded
  /// number of `onChange` calls — leading + trailing — NOT one per raw flush. This is the general
  /// fix that also protects the Files inspector's watcher; the exact ~70/sec→~2 reduction is proven
  /// by the standalone FSEvents-replica profiling harness.
  @MainActor
  func testWatcherCoalescesSustainedBurst() async throws {
    let dir = NSTemporaryDirectory() + "wfw-coalesce-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let sink = Sink()
    let watcher = WorkroomFileWatcher(latency: 0.1, coalesceWindow: 0.3) { paths in
      sink.count += 1
      sink.paths.formUnion(paths)
    }
    watcher.start(path: dir)
    defer { watcher.stop() }

    try await Task.sleep(nanoseconds: 250_000_000)  // let the stream arm
    // 30 writes spaced 30ms apart ≈ 0.9s of sustained churn — long enough that FSEvents flushes
    // several raw callbacks, so only the app-level state machine keeps the delivered count low.
    for i in 0..<30 {
      try "x".write(toFile: dir + "/f\(i).txt", atomically: true, encoding: .utf8)
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    try await Task.sleep(nanoseconds: 700_000_000)  // > coalesceWindow, so the trailing edge fires

    XCTAssertGreaterThanOrEqual(sink.count, 1, "the leading edge must deliver at least once")
    XCTAssertLessThanOrEqual(
      sink.count, 8,
      "a sustained burst must coalesce, not deliver per-flush (got \(sink.count))")
    XCTAssertFalse(sink.paths.isEmpty, "delivered batches must carry the changed paths")
  }

  /// `stop()` cancels any pending trailing emit — no `onChange` may arrive after teardown.
  @MainActor
  func testWatcherStopCancelsPendingTrailing() async throws {
    let dir = NSTemporaryDirectory() + "wfw-stop-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let sink = Sink()
    let watcher = WorkroomFileWatcher(latency: 0.1, coalesceWindow: 0.5) { _ in sink.count += 1 }
    watcher.start(path: dir)
    try await Task.sleep(nanoseconds: 250_000_000)
    try "a".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    try await Task.sleep(nanoseconds: 200_000_000)  // leading likely fired; trailing still pending
    let afterLeading = sink.count
    watcher.stop()
    try await Task.sleep(nanoseconds: 700_000_000)  // past the trailing window
    XCTAssertEqual(sink.count, afterLeading, "no trailing delivery may fire after stop()")
  }

  // MARK: - HostFileWatcher on a stalled path (offactor review I2)

  /// Counts what a host watcher's loop asked for, and lets a test stall its path's resolve.
  private final class StalledResolve: Sendable {
    let resolves = Mutex(0)
    let filesAsked = Mutex(0)
    let blocked = Mutex(0)
    let peakBlocked = Mutex(0)
    let failuresLeft: Mutex<Int>
    private let gate = DispatchSemaphore(value: 0)
    init(failures: Int = 0) { failuresLeft = Mutex(failures) }

    /// Blocks until `release`, as `realpath` on a hung mount does, counting how many threads it
    /// holds at once.
    func block() {
      let now = blocked.withLock {
        $0 += 1
        return $0
      }
      peakBlocked.withLock { $0 = max($0, now) }
      _ = gate.wait(timeout: .now() + 10)
      blocked.withLock { $0 -= 1 }
    }
    func release() { for _ in 0..<64 { gate.signal() } }
  }

  /// Value: protects=a host watcher on a stalled mount backing off rather than starting a watch on
  /// a path it couldn't resolve (offactor review I2); fails_when=a resolve that timed out starts
  /// the FSEvents fallback (which would stall the shared stream queue) or the daemon's watch, or a
  /// watch that does go live reports no gap; why_new=review; seam=HostFileWatcher's resolve +
  /// the router's local files (counted); no_claim=a real network mount
  func testAHostWatcherWhosePathCannotBeResolvedBacksOffAndRecovers() async throws {
    let dir = NSTemporaryDirectory() + "hfw-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let probe = StalledResolve(failures: 2)
    let overflows = Mutex(0)
    let watcher = HostFileWatcher(
      router: RepositoryRouter(localFiles: { _ in
        probe.filesAsked.withLock { $0 += 1 }
        throw VCSError.backendVersion("old")
      }),
      resolveLocation: { path in
        probe.resolves.withLock { $0 += 1 }
        let fail = probe.failuresLeft.withLock { left in
          defer { left -= 1 }
          return left > 0
        }
        return fail ? nil : try? await RepositoryLocation.local(path)
      },
      onChange: { paths, overflow in if paths.isEmpty, overflow { overflows.withLock { $0 += 1 } } }
    )
    watcher.start(path: dir)
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(probe.resolves.withLock { $0 }, 1)
    XCTAssertEqual(probe.filesAsked.withLock { $0 }, 0, "nothing watches an unresolved path")

    let deadline = Date().addingTimeInterval(6)
    while overflows.withLock({ $0 }) == 0, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(probe.resolves.withLock { $0 }, 3, "retried on the backoff until it resolved")
    XCTAssertGreaterThan(probe.filesAsked.withLock { $0 }, 0)
    XCTAssertEqual(overflows.withLock { $0 }, 1, "one refresh for the gap, once the watch is live")
  }

  /// Value: protects=the GCD pool against watcher churn on a stalled mount (offactor review I2);
  /// fails_when=each watcher of a stalled path parks a thread of its own in its resolve, so a
  /// storm of follows drains the pool every `runBlocking` read shares; why_new=review;
  /// seam=HostFileWatcher's resolve, through the shared joined read; no_claim=a real network
  /// mount. Also measures the unjoined resolve the watcher used before, for the report.
  func testWatchersOfAStalledPathHoldOneThreadBetweenThem() async throws {
    let path = NSTemporaryDirectory() + "hfw-stalled-\(UUID().uuidString)"
    func peak(joined: Bool) async throws -> Int {
      let probe = StalledResolve()
      defer { probe.release() }
      let watchers = (0..<20).map { _ in
        HostFileWatcher(
          router: RepositoryRouter(localFiles: { _ in throw VCSError.backendVersion("old") }),
          resolveLocation: { path in
            if joined {
              // The shape of `GitRepositoryProbe.localLocation`: joined by path, bounded.
              _ = await GitRepositoryProbe.blockingRead(
                "watch-test\u{0}\(path)", timeout: 0.3, { probe.block() })
            } else {
              // The watcher's resolve before: `RepositoryLocation.local`'s bare `runBlocking`.
              _ = try? await runBlocking { probe.block() }
            }
            return nil
          },
          onChange: { _, _ in })
      }
      for watcher in watchers { watcher.start(path: path) }
      try await Task.sleep(for: .seconds(1.2))
      for watcher in watchers { watcher.stop() }
      return probe.peakBlocked.withLock { $0 }
    }
    let after = try await peak(joined: true)
    let before = try await peak(joined: false)
    print("stalled-path watchers: \(before) blocked threads unjoined, \(after) joined")
    XCTAssertEqual(after, 1, "one thread for every watcher of the path")
    XCTAssertEqual(before, 20)
  }
}
