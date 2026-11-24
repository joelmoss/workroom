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

  /// A measurement (offactor review I2): how many GCD threads 20 watchers of one stalled path hold,
  /// resolving it joined (`GitRepositoryProbe.blockingRead`, the shape `localLocation` has) against
  /// unjoined (`runBlocking`, the watcher's resolve before). Its seam re-implements the join, so a
  /// regression in the watcher's default resolve would not fail it; no_claim=a real network mount.
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
  }

  // MARK: - HostFileWatcher on a healthy workroom path (#812 perf review N6)

  /// How long a fresh watcher takes from `start` to asking the router for the path's files, and
  /// which path it asked for. The router throws, as a pre-upgrade daemon does, so the watch falls
  /// back; only the first ask is timed.
  private func timeToFirstAsk(
    _ dir: String,
    resolveLocation: (@Sendable (String) async -> RepositoryLocation?)? = nil
  ) async throws -> (Duration, String) {
    let asked = Mutex<(ContinuousClock.Instant, String)?>(nil)
    let router = RepositoryRouter(localFiles: { context in
      asked.withLock { if $0 == nil { $0 = (.now, context.location.path) } }
      throw VCSError.backendVersion("old")
    })
    let watcher =
      if let resolveLocation {
        HostFileWatcher(router: router, resolveLocation: resolveLocation, onChange: { _, _ in })
      } else {
        HostFileWatcher(router: router, onChange: { _, _ in })
      }
    let start = ContinuousClock.now
    watcher.start(path: dir)
    defer { watcher.stop() }
    let deadline = start + .seconds(5)
    while asked.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    let first = try XCTUnwrap(asked.withLock { $0 }, "the watch was never asked for")
    return (first.0 - start, first.1)
  }

  /// Value: protects=an ordinary workroom watch starting as fast as it did before the bounded
  /// resolve, on its first resolve (#812 perf review N6); fails_when=the default resolve adds a
  /// delay (a timeout waited out, a retry) or asks for the unresolved path; why_new=review N6;
  /// seam=HostFileWatcher's default resolve + the router's local files (timed); no_claim=a real
  /// network mount. Measures the bare `RepositoryLocation.local` resolve it used before, for the
  /// report.
  func testAHealthyWorkroomWatchStartsOnItsFirstResolveAsFastAsBefore() async throws {
    // `NSTemporaryDirectory` is under `/var`, a symlink to `/private/var`: a resolved ask says so.
    let dir = NSTemporaryDirectory() + "hfw-healthy-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path

    var before: [Duration] = []
    var after: [Duration] = []
    for _ in 0..<15 {
      let (bare, barePath) = try await timeToFirstAsk(
        dir, resolveLocation: { try? await RepositoryLocation.local($0) })
      let (bounded, boundedPath) = try await timeToFirstAsk(dir)
      XCTAssertEqual(barePath, resolved)
      XCTAssertEqual(boundedPath, resolved, "the default resolve asks for the resolved path")
      before.append(bare)
      after.append(bounded)
    }
    func median(_ d: [Duration]) -> Duration { d.sorted()[d.count / 2] }
    func ms(_ d: Duration) -> String {
      let (s, atto) = d.components
      return String(format: "%.2f ms", Double(s) * 1000 + Double(atto) / 1e15)
    }
    print(
      "healthy workroom watch, start to first ask: before (bare) median \(ms(median(before))) "
        + "max \(ms(before.max()!)); after (bounded) median \(ms(median(after))) "
        + "max \(ms(after.max()!))")
    // A retry costs the 500 ms backoff on every sample, a waited-out timeout 3 s: the fastest is
    // far below both only if the first resolve always lands.
    XCTAssertLessThan(after.min()!, .milliseconds(100), "resolved first time, with no backoff")
    XCTAssertLessThan(median(after), .milliseconds(250))
    XCTAssertLessThan(median(after), median(before) + .milliseconds(20))
  }

  /// Value: protects=a watch on a slow but live volume going live once its resolve lands, rather
  /// than looping on the backoff because each try times out (#812 perf review N6); fails_when=a
  /// resolve that outlasts the timeout is restarted on every try, so it never finishes inside one;
  /// why_new=review N6; seam=HostFileWatcher's resolve, through the shared joined, bounded read
  /// (the shape of `GitRepositoryProbe.localLocation`, scaled down); no_claim=a real network mount
  func testASlowButLiveWorkroomPathIsWatchedOnceItsResolveLands() async throws {
    let dir = NSTemporaryDirectory() + "hfw-slow-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let reads = Mutex(0)
    let key = "watch-slow-test\u{0}\(dir)"
    // A realpath of 0.95 s against a 0.3 s bound: the first try times out at 0.3 s, and the retry
    // after the 0.5 s backoff (0.8 s) joins the read still in flight.
    let (elapsed, _) = try await timeToFirstAsk(
      dir,
      resolveLocation: { path in
        let location = await GitRepositoryProbe.boundedRead(key, timeout: 0.3) {
          reads.withLock { $0 += 1 }
          try? await Task.sleep(for: .milliseconds(950))
          return try? await RepositoryLocation.local(path)
        }
        return location ?? nil
      })
    print("slow workroom path (0.95 s resolve, 0.3 s bound): watched after \(elapsed)")
    XCTAssertEqual(reads.withLock { $0 }, 1, "the retry joined the read in flight")
    XCTAssertLessThan(
      elapsed, .milliseconds(1500), "watched once the read landed, not after the backoff")
  }

  /// Value: protects=a workroom watch on a stalled path backing off on the bound rather than
  /// hanging in one resolve forever (#812 perf review N6); fails_when=the resolve never returns,
  /// so the loop never retries and never recovers; why_new=review N6; seam=HostFileWatcher's
  /// resolve, bare (before) and joined + bounded (after, the shape of
  /// `GitRepositoryProbe.localLocation`, scaled down); no_claim=a real network mount
  func testAStalledWorkroomPathBacksOffRatherThanHanging() async throws {
    let path = NSTemporaryDirectory() + "hfw-stalled-ws-\(UUID().uuidString)"
    func resolves(bounded: Bool) async throws -> (tries: Int, returned: Int) {
      let probe = StalledResolve()
      defer { probe.release() }
      let returned = Mutex(0)
      let watcher = HostFileWatcher(
        router: RepositoryRouter(localFiles: { _ in throw VCSError.backendVersion("old") }),
        resolveLocation: { path in
          probe.resolves.withLock { $0 += 1 }
          if bounded {
            _ = await GitRepositoryProbe.blockingRead(
              "watch-stalled-ws\u{0}\(path)", timeout: 0.3, { probe.block() })
          } else {
            _ = try? await runBlocking { probe.block() }
          }
          returned.withLock { $0 += 1 }
          return nil
        },
        onChange: { _, _ in })
      watcher.start(path: path)
      try await Task.sleep(for: .milliseconds(1500))
      watcher.stop()
      return (probe.resolves.withLock { $0 }, returned.withLock { $0 })
    }
    let after = try await resolves(bounded: true)
    let before = try await resolves(bounded: false)
    print(
      "stalled workroom path over 1.5 s: before (bare) \(before.tries) tries, "
        + "\(before.returned) returned; after (bounded 0.3 s) \(after.tries) tries, "
        + "\(after.returned) returned")
    XCTAssertEqual(before.returned, 0, "the bare resolve hangs")
    // 0.3 s bound, 0.5 s backoff, 0.3 s, 1 s backoff: two returned tries and a third under way.
    XCTAssertGreaterThanOrEqual(after.returned, 2, "the bounded resolve returns and is retried")
  }
}
