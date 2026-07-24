import XCTest

@testable import Workroom

// MARK: - Test doubles

/// A `VCSProviding` stub that records calls and returns configurable text (or throws). A class so
/// its closures record into it without capturing a mutable `var` across the `@Sendable` boundary.
private final class StubDiffProvider: VCSProviding, @unchecked Sendable {
  var commitText: (@Sendable (_ commitID: String, _ path: String) throws -> String)?
  var workingText: (@Sendable (_ path: String, _ base: VCSWorkingDiffBase) throws -> String)?

  private let lock = NSLock()
  private var _commitCalls = 0
  private var _workingCalls: [(path: String, base: VCSWorkingDiffBase)] = []
  private var _lastCommit: (commitID: String, path: String)?

  var commitCalls: Int {
    lock.lock()
    defer { lock.unlock() }
    return _commitCalls
  }
  var workingCalls: [(path: String, base: VCSWorkingDiffBase)] {
    lock.lock()
    defer { lock.unlock() }
    return _workingCalls
  }
  var lastCommit: (commitID: String, path: String)? {
    lock.lock()
    defer { lock.unlock() }
    return _lastCommit
  }

  func log(root: URL, limit: Int) throws -> VCSHistoryPage {
    .init(commits: [], reachedEnd: true)
  }
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    throw VCSError.io("unused")
  }
  func currentRef(root: URL) async throws -> VCSRef { .none }

  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    lock.lock()
    _commitCalls += 1
    _lastCommit = (commitID, path)
    lock.unlock()
    return try commitText?(commitID, path) ?? ""
  }

  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    lock.lock()
    _workingCalls.append((path, base))
    lock.unlock()
    return try workingText?(path, base) ?? ""
  }

  func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
}

/// Tracks the peak number of concurrently-running sections between `enter()`/`exit()` pairs — used
/// by the `JJSnapshotGate` test to prove two gated calls never overlap. A plain lock (not an
/// `actor`) so it's callable from `StubDiffProvider`'s synchronous `workingText` closure.
private final class ConcurrencyRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var running = 0
  private(set) var maxConcurrent = 0

  func enter() {
    lock.lock()
    running += 1
    maxConcurrent = max(maxConcurrent, running)
    lock.unlock()
  }

  func exit() {
    lock.lock()
    running -= 1
    lock.unlock()
  }
}

private let sampleDiff = """
  diff --git a/foo.txt b/foo.txt
  --- a/foo.txt
  +++ b/foo.txt
  @@ -1,1 +1,1 @@
  -old
  +new
  """

private let binaryDiff = "Binary files a/img.png and b/img.png differ"

private func desc(_ path: String, _ change: ChangedFile.Change, _ source: DiffSource)
  -> DiffDescriptor
{
  DiffDescriptor(path: path, change: change, source: source, isPreview: false)
}

// MARK: - Tests

final class DiffResolverTests: XCTestCase {

  /// A resolver wired to `provider` and (by default) a fresh cache + gate so tests are isolated
  /// from each other, the shared commit cache, and the process-wide `JJSnapshotGate.shared`.
  private func resolver(
    _ provider: StubDiffProvider, cache: DiffCache = DiffCache(),
    gate: JJSnapshotGate = JJSnapshotGate()
  ) -> DiffResolver {
    DiffResolver(makeProvider: { _ in provider }, cache: cache, gate: gate)
  }

  // MARK: - interpret (pure classification)

  func testInterpretParsesDiff() {
    guard case .diff(let ud) = DiffResolver.interpret(sampleDiff) else {
      return XCTFail("expected .diff")
    }
    XCTAssertEqual(ud.hunks.count, 1)
  }

  func testInterpretBinary() {
    XCTAssertEqual(DiffResolver.interpret(binaryDiff), .binary)
  }

  func testInterpretEmptyAndWhitespace() {
    XCTAssertEqual(DiffResolver.interpret(""), .empty)
    XCTAssertEqual(DiffResolver.interpret("   \n  "), .empty)
  }

  func testInterpretTooLarge() {
    // One byte over the cap → tooLarge, never parsed.
    let big = String(repeating: "x", count: DiffResolver.maxDiffBytes + 1)
    XCTAssertEqual(DiffResolver.interpret(big), .tooLarge)
  }

  // MARK: - jj working-copy args (pure; the invariant the deleted command(for:) tests guarded)

  func testJJWorkingCopyArgsSnapshot() {
    let args = RustJJProvider.workingDiffArgs(path: "src/foo.swift", base: .workingCopy)
    XCTAssertEqual(
      args, ["diff", "--git", "-r", "@", "--color", "never", "--", "src/foo.swift"])
    // Must NOT ignore the working copy — `.workingCopy` has to snapshot `@` to reflect disk.
    XCTAssertFalse(args.contains("--ignore-working-copy"))
  }

  func testJJParentArgsIgnoreWorkingCopy() {
    let args = RustJJProvider.workingDiffArgs(path: "lib/bar.swift", base: .parent)
    XCTAssertTrue(args.contains("@-"))
    // Must reuse the snapshot (never re-lock the working copy) when reading the parent.
    XCTAssertTrue(args.contains("--ignore-working-copy"))
  }

  // MARK: - resolve: working-copy sources route to workingFileDiff with the right base

  func testResolveGitWorktreeUsesWorkingCopyBase() async {
    let p = StubDiffProvider()
    p.workingText = { _, _ in sampleDiff }
    let result = await resolver(p).resolve(
      desc("f.txt", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    guard case .diff = result else { return XCTFail("expected .diff, got \(result)") }
    XCTAssertEqual(p.workingCalls.map(\.base), [.workingCopy])
    XCTAssertEqual(p.workingCalls.first?.path, "f.txt")
  }

  func testResolveJJWorkingCopyUsesWorkingCopyBase() async {
    let p = StubDiffProvider()
    p.workingText = { _, _ in sampleDiff }
    _ = await resolver(p).resolve(
      desc("a.txt", .modified, .jjWorkingCopy), in: "/repo", projectRoot: nil)
    XCTAssertEqual(p.workingCalls.map(\.base), [.workingCopy])
  }

  /// The one case that snapshots `@` — `.jjWorkingCopy` — must serialize per `projectRoot` through
  /// `JJSnapshotGate`, since a project's workrooms share a backing repo a concurrent snapshot could
  /// contend on (VCS-foundation eng-review).
  func testJJWorkingCopyDiffsSameProjectDoNotOverlap() async {
    let p = StubDiffProvider()
    let recorder = ConcurrencyRecorder()
    p.workingText = { _, _ in
      recorder.enter()
      Thread.sleep(forTimeInterval: 0.05)
      recorder.exit()
      return sampleDiff
    }
    let r = resolver(p, gate: JJSnapshotGate())
    async let first = r.resolve(
      desc("a.txt", .modified, .jjWorkingCopy), in: "/repo", projectRoot: "/proj")
    async let second = r.resolve(
      desc("b.txt", .modified, .jjWorkingCopy), in: "/repo", projectRoot: "/proj")
    _ = await (first, second)
    XCTAssertEqual(recorder.maxConcurrent, 1, "same-project jj working-copy diffs must be gated")
  }

  func testResolveJJParentUsesParentBase() async {
    let p = StubDiffProvider()
    p.workingText = { _, _ in sampleDiff }
    _ = await resolver(p).resolve(
      desc("b.txt", .modified, .jjParent), in: "/repo", projectRoot: nil)
    XCTAssertEqual(p.workingCalls.map(\.base), [.parent])
  }

  func testResolveWorkingMapsBinaryEmptyTooLarge() async {
    let p = StubDiffProvider()
    p.workingText = { path, _ in
      switch path {
      case "img.png": return binaryDiff
      case "clean.txt": return ""
      default: return String(repeating: "x", count: DiffResolver.maxDiffBytes + 1)
      }
    }
    let r = resolver(p)
    let binary = await r.resolve(
      desc("img.png", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    XCTAssertEqual(binary, .binary)
    let empty = await r.resolve(
      desc("clean.txt", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    XCTAssertEqual(empty, .empty)
    let big = await r.resolve(
      desc("huge.txt", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    XCTAssertEqual(big, .tooLarge)
  }

  func testResolveWorkingBackendErrorFails() async {
    let p = StubDiffProvider()
    p.workingText = { _, _ in throw VCSError.lockContention }
    let result = await resolver(p).resolve(
      desc("f.txt", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    XCTAssertEqual(result, .failed("Repository is busy"))
  }

  /// The above covers the ungated `.gitWorktree` path; `.jjWorkingCopy` additionally routes through
  /// `JJSnapshotGate` — prove a thrown backend error still surfaces as `.failed` through the gate,
  /// AND that the gate's tail isn't left poisoned (a queued next call for the same project must
  /// still run normally).
  func testJJWorkingCopyErrorWhileGatedStillFailsAndUnblocksQueue() async {
    let p = StubDiffProvider()
    p.workingText = { _, _ in throw VCSError.lockContention }
    let gate = JJSnapshotGate()
    let r = resolver(p, gate: gate)
    let result = await r.resolve(
      desc("a.txt", .modified, .jjWorkingCopy), in: "/repo", projectRoot: "/proj")
    XCTAssertEqual(result, .failed("Repository is busy"))

    p.workingText = { _, _ in sampleDiff }
    let next = await r.resolve(
      desc("b.txt", .modified, .jjWorkingCopy), in: "/repo", projectRoot: "/proj")
    guard case .diff = next else {
      return XCTFail("queue should not be wedged after a prior error")
    }
  }

  // MARK: - resolve: .commit routes through the backend (never shells) and is cached

  func testResolveCommitRoutesThroughProviderAndNeverShells() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in sampleDiff }
    let result = await resolver(p).resolve(
      desc("b.txt", .modified, .commit("abc123")), in: "/repo", projectRoot: nil)
    guard case .diff = result else { return XCTFail("expected .diff, got \(result)") }
    XCTAssertTrue(p.workingCalls.isEmpty, "a commit diff never uses the working-copy path")
    XCTAssertEqual(p.lastCommit?.commitID, "abc123")
    XCTAssertEqual(p.lastCommit?.path, "b.txt")
  }

  func testResolveCommitMapsBinaryAndEmpty() async {
    let bin = StubDiffProvider()
    bin.commitText = { _, _ in binaryDiff }
    let binResult = await resolver(bin).resolve(
      desc("img.png", .modified, .commit("x")), in: "/repo", projectRoot: nil)
    XCTAssertEqual(binResult, .binary)

    let mt = StubDiffProvider()
    mt.commitText = { _, _ in "   \n" }
    let emptyResult = await resolver(mt).resolve(
      desc("a.txt", .modified, .commit("x")), in: "/repo", projectRoot: nil)
    XCTAssertEqual(emptyResult, .empty)
  }

  func testResolveCommitBackendErrorFails() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in throw VCSError.notFound("no such commit") }
    let result = await resolver(p).resolve(
      desc("a.txt", .modified, .commit("bad")), in: "/repo", projectRoot: nil)
    guard case .failed(let message) = result else {
      return XCTFail("expected .failed, got \(result)")
    }
    XCTAssertTrue(message.contains("no such commit"), "the backend message is surfaced: \(message)")
  }

  func testCommitDiffIsCachedSecondCallDoesNotHitProvider() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in sampleDiff }
    let r = resolver(p)  // fresh cache
    _ = await r.resolve(desc("f.txt", .modified, .commit("c1")), in: "/repo", projectRoot: nil)
    _ = await r.resolve(desc("f.txt", .modified, .commit("c1")), in: "/repo", projectRoot: nil)
    XCTAssertEqual(p.commitCalls, 1, "the second resolve is served from cache")
  }

  func testDifferentCommitsAreCachedSeparately() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in sampleDiff }
    let r = resolver(p)
    _ = await r.resolve(desc("f.txt", .modified, .commit("c1")), in: "/repo", projectRoot: nil)
    _ = await r.resolve(desc("f.txt", .modified, .commit("c2")), in: "/repo", projectRoot: nil)
    XCTAssertEqual(p.commitCalls, 2, "a different commit id is a distinct cache entry")
  }

  func testWorkingCopyDiffIsNotCached() async {
    let p = StubDiffProvider()
    p.workingText = { _, _ in sampleDiff }
    let r = resolver(p)
    _ = await r.resolve(desc("f.txt", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    _ = await r.resolve(desc("f.txt", .modified, .gitWorktree), in: "/repo", projectRoot: nil)
    XCTAssertEqual(
      p.workingCalls.count, 2, "working-copy diffs must never be cached (mutable content)")
  }

  func testFailedCommitDiffIsNotCached() async {
    let p = StubDiffProvider()
    var attempts = 0
    p.commitText = { _, _ in
      attempts += 1
      if attempts == 1 { throw VCSError.io("blip") }
      return sampleDiff
    }
    let r = resolver(p)
    let first = await r.resolve(
      desc("f.txt", .modified, .commit("c1")), in: "/repo", projectRoot: nil)
    guard case .failed = first else { return XCTFail("expected .failed, got \(first)") }
    // A transient failure isn't cached, so the retry re-hits the backend and succeeds.
    let second = await r.resolve(
      desc("f.txt", .modified, .commit("c1")), in: "/repo", projectRoot: nil)
    guard case .diff = second else { return XCTFail("expected .diff on retry, got \(second)") }
  }
}

// MARK: - DiffCache (LRU byte budget)

final class DiffCacheTests: XCTestCase {
  func testEvictsLeastRecentlyUsedOverBudget() async {
    let c = DiffCache(budget: 120)
    await c.set("a", .empty, bytes: 60)
    await c.set("b", .empty, bytes: 60)  // total 120 — at budget, nothing evicted
    await c.set("c", .empty, bytes: 60)  // total 180 > 120 — evict LRU ("a")
    let a = await c.get("a")
    let b = await c.get("b")
    let cc = await c.get("c")
    XCTAssertNil(a, "a was least-recently-used and should be evicted")
    XCTAssertNotNil(b)
    XCTAssertNotNil(cc)
  }

  func testGetTouchesRecency() async {
    let c = DiffCache(budget: 120)
    await c.set("a", .empty, bytes: 60)
    await c.set("b", .empty, bytes: 60)
    _ = await c.get("a")  // touch a → b becomes least-recently-used
    await c.set("c", .empty, bytes: 60)  // evicts the LRU, now b
    let a = await c.get("a")
    let b = await c.get("b")
    let cc = await c.get("c")
    XCTAssertNotNil(a, "a was touched, so it survives")
    XCTAssertNil(b, "b was LRU after a's touch")
    XCTAssertNotNil(cc)
  }

  func testKeepsMostRecentEvenWhenOversized() async {
    let c = DiffCache(budget: 10)
    await c.set("big", .empty, bytes: 999)  // over budget on its own
    let big = await c.get("big")
    XCTAssertNotNil(big, "the sole/most-recent entry is kept even over budget")
  }

  func testReplacingKeyUpdatesTotalBytes() async {
    let c = DiffCache(budget: 100)
    await c.set("a", .empty, bytes: 90)
    await c.set("a", .empty, bytes: 10)  // replace, not add — total is 10, not 100
    await c.set("b", .empty, bytes: 80)  // 10 + 80 = 90 ≤ 100 — nothing evicted
    let a = await c.get("a")
    let b = await c.get("b")
    XCTAssertNotNil(a, "a's bytes were replaced, so b fits without evicting it")
    XCTAssertNotNil(b)
  }
}
