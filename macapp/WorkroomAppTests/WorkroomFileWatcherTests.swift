import XCTest

@testable import Workroom

/// Tests for the live filesystem watch that keeps the selected workroom's VCS status current
/// (issue #24 follow-up): the FSEvents watcher fires on a real change, and the jj-internal path
/// filter that breaks the snapshot self-trigger loop.
final class WorkroomFileWatcherTests: XCTestCase {

  // MARK: - jj-internal path filter (AppStore.isJJInternalPath)

  func testIsJJInternalPath() {
    // A `.jj` path component ⇒ internal (the jj snapshot writes here; must be ignored for jj).
    XCTAssertTrue(AppStore.isJJInternalPath("/repo/.jj/working_copy/checkout"))
    XCTAssertTrue(AppStore.isJJInternalPath("/repo/.jj"))
    // Working files are not internal — these must still trigger a refresh.
    XCTAssertFalse(AppStore.isJJInternalPath("/repo/src/main.swift"))
    XCTAssertFalse(AppStore.isJJInternalPath("/repo"))
    // Component-based, so a file merely *named* like `.jj…` isn't treated as internal.
    XCTAssertFalse(AppStore.isJJInternalPath("/repo/.jjconfig.toml"))
  }

  // MARK: - VCS metadata dir (AppStore.vcsMetadataDir — root-branch watch target, #3)

  func testVCSMetadataDir() {
    // git/jj map to the metadata dir whose changes signal a branch/bookmark move.
    XCTAssertEqual(AppStore.vcsMetadataDir(path: "/repo", vcs: "git"), "/repo/.git")
    XCTAssertEqual(AppStore.vcsMetadataDir(path: "/repo", vcs: "jj"), "/repo/.jj")
    // Trailing slash is normalized by appendingPathComponent (no double slash).
    XCTAssertEqual(AppStore.vcsMetadataDir(path: "/repo/", vcs: "git"), "/repo/.git")
    // Unknown vcs ⇒ no watch target.
    XCTAssertNil(AppStore.vcsMetadataDir(path: "/repo", vcs: "hg"))
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
}
