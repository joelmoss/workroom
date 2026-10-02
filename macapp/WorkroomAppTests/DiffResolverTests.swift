import XCTest

@testable import Workroom

// MARK: - Test doubles

/// A `LocalVCSProviding` stub that records calls and returns configurable text (or throws). A class so
/// its closures record into it without capturing a mutable `var` across the `@Sendable` boundary.
private final class StubDiffProvider: LocalVCSProviding, @unchecked Sendable {
  var commitText: (@Sendable (_ commitID: String, _ path: String) throws -> String)?
  var workingText: (@Sendable (_ path: String) throws -> String)?

  private let lock = NSLock()
  private var _commitCalls = 0
  private var _workingCalls: [String] = []
  private var _lastCommit: (commitID: String, path: String)?

  var commitCalls: Int {
    lock.lock()
    defer { lock.unlock() }
    return _commitCalls
  }
  var workingCalls: [String] {
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

  func workingFileDiff(root: URL, path: String) async throws -> String {
    lock.lock()
    _workingCalls.append(path)
    lock.unlock()
    return try workingText?(path) ?? ""
  }

  func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
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

  /// A resolver wired to `provider` and (by default) a fresh cache so tests are isolated from each
  /// other and the shared commit cache.
  private func resolver(_ provider: StubDiffProvider, cache: DiffCache = DiffCache())
    -> DiffResolver
  {
    DiffResolver(makeProvider: { _ in provider }, cache: cache)
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

  // MARK: - resolve: working-copy sources route to workingFileDiff with the right base

  func testResolveGitWorktreeUsesWorkingCopyBase() async {
    let p = StubDiffProvider()
    p.workingText = { _ in sampleDiff }
    let result = await resolver(p).resolve(
      desc("f.txt", .modified, .gitWorktree), in: "/repo")
    guard case .diff = result else { return XCTFail("expected .diff, got \(result)") }
    XCTAssertEqual(p.workingCalls, ["f.txt"])
  }

  func testResolveWorkingMapsBinaryEmptyTooLarge() async {
    let p = StubDiffProvider()
    p.workingText = { path in
      switch path {
      case "img.png": return binaryDiff
      case "clean.txt": return ""
      default: return String(repeating: "x", count: DiffResolver.maxDiffBytes + 1)
      }
    }
    let r = resolver(p)
    let binary = await r.resolve(
      desc("img.png", .modified, .gitWorktree), in: "/repo")
    XCTAssertEqual(binary, .binary)
    let empty = await r.resolve(
      desc("clean.txt", .modified, .gitWorktree), in: "/repo")
    XCTAssertEqual(empty, .empty)
    let big = await r.resolve(
      desc("huge.txt", .modified, .gitWorktree), in: "/repo")
    XCTAssertEqual(big, .tooLarge)
  }

  func testResolveWorkingBackendErrorFails() async {
    let p = StubDiffProvider()
    p.workingText = { _ in throw VCSError.lockContention }
    let result = await resolver(p).resolve(
      desc("f.txt", .modified, .gitWorktree), in: "/repo")
    XCTAssertEqual(result, .failed("Repository is busy"))
  }

  // MARK: - resolve: .commit routes through the backend (never shells) and is cached

  func testResolveCommitRoutesThroughProviderAndNeverShells() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in sampleDiff }
    let result = await resolver(p).resolve(
      desc("b.txt", .modified, .commit("abc123")), in: "/repo")
    guard case .diff = result else { return XCTFail("expected .diff, got \(result)") }
    XCTAssertTrue(p.workingCalls.isEmpty, "a commit diff never uses the working-copy path")
    XCTAssertEqual(p.lastCommit?.commitID, "abc123")
    XCTAssertEqual(p.lastCommit?.path, "b.txt")
  }

  func testResolveCommitMapsBinaryAndEmpty() async {
    let bin = StubDiffProvider()
    bin.commitText = { _, _ in binaryDiff }
    let binResult = await resolver(bin).resolve(
      desc("img.png", .modified, .commit("x")), in: "/repo")
    XCTAssertEqual(binResult, .binary)

    let mt = StubDiffProvider()
    mt.commitText = { _, _ in "   \n" }
    let emptyResult = await resolver(mt).resolve(
      desc("a.txt", .modified, .commit("x")), in: "/repo")
    XCTAssertEqual(emptyResult, .empty)
  }

  func testResolveCommitBackendErrorFails() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in throw VCSError.notFound("no such commit") }
    let result = await resolver(p).resolve(
      desc("a.txt", .modified, .commit("bad")), in: "/repo")
    guard case .failed(let message) = result else {
      return XCTFail("expected .failed, got \(result)")
    }
    XCTAssertTrue(message.contains("no such commit"), "the backend message is surfaced: \(message)")
  }

  func testCommitDiffIsCachedSecondCallDoesNotHitProvider() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in sampleDiff }
    let r = resolver(p)  // fresh cache
    _ = await r.resolve(desc("f.txt", .modified, .commit("c1")), in: "/repo")
    _ = await r.resolve(desc("f.txt", .modified, .commit("c1")), in: "/repo")
    XCTAssertEqual(p.commitCalls, 1, "the second resolve is served from cache")
  }

  func testDifferentCommitsAreCachedSeparately() async {
    let p = StubDiffProvider()
    p.commitText = { _, _ in sampleDiff }
    let r = resolver(p)
    _ = await r.resolve(desc("f.txt", .modified, .commit("c1")), in: "/repo")
    _ = await r.resolve(desc("f.txt", .modified, .commit("c2")), in: "/repo")
    XCTAssertEqual(p.commitCalls, 2, "a different commit id is a distinct cache entry")
  }

  func testWorkingCopyDiffIsNotCached() async {
    let p = StubDiffProvider()
    p.workingText = { _ in sampleDiff }
    let r = resolver(p)
    _ = await r.resolve(desc("f.txt", .modified, .gitWorktree), in: "/repo")
    _ = await r.resolve(desc("f.txt", .modified, .gitWorktree), in: "/repo")
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
      desc("f.txt", .modified, .commit("c1")), in: "/repo")
    guard case .failed = first else { return XCTFail("expected .failed, got \(first)") }
    // A transient failure isn't cached, so the retry re-hits the backend and succeeds.
    let second = await r.resolve(
      desc("f.txt", .modified, .commit("c1")), in: "/repo")
    guard case .diff = second else { return XCTFail("expected .diff on retry, got \(second)") }
  }
}

// MARK: - DiffCache (LRU byte budget)

final class DiffCacheTests: XCTestCase {
  private func key(_ value: String) -> DiffCache.Key {
    let location = try! RepositoryLocation.remote(
      host: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, path: "/repo")
    return DiffCache.Key(location: location, revision: value, path: "file")
  }

  func testEvictsLeastRecentlyUsedOverBudget() async {
    let c = DiffCache(budget: 120)
    await c.set(key("a"), .empty, bytes: 60)
    await c.set(key("b"), .empty, bytes: 60)  // total 120 — at budget, nothing evicted
    await c.set(key("c"), .empty, bytes: 60)  // total 180 > 120 — evict LRU ("a")
    let a = await c.get(key("a"))
    let b = await c.get(key("b"))
    let cc = await c.get(key("c"))
    XCTAssertNil(a, "a was least-recently-used and should be evicted")
    XCTAssertNotNil(b)
    XCTAssertNotNil(cc)
  }

  func testGetTouchesRecency() async {
    let c = DiffCache(budget: 120)
    await c.set(key("a"), .empty, bytes: 60)
    await c.set(key("b"), .empty, bytes: 60)
    _ = await c.get(key("a"))  // touch a → b becomes least-recently-used
    await c.set(key("c"), .empty, bytes: 60)  // evicts the LRU, now b
    let a = await c.get(key("a"))
    let b = await c.get(key("b"))
    let cc = await c.get(key("c"))
    XCTAssertNotNil(a, "a was touched, so it survives")
    XCTAssertNil(b, "b was LRU after a's touch")
    XCTAssertNotNil(cc)
  }

  func testKeepsMostRecentEvenWhenOversized() async {
    let c = DiffCache(budget: 10)
    await c.set(key("big"), .empty, bytes: 999)  // over budget on its own
    let big = await c.get(key("big"))
    XCTAssertNotNil(big, "the sole/most-recent entry is kept even over budget")
  }

  func testReplacingKeyUpdatesTotalBytes() async {
    let c = DiffCache(budget: 100)
    await c.set(key("a"), .empty, bytes: 90)
    await c.set(key("a"), .empty, bytes: 10)  // replace, not add — total is 10, not 100
    await c.set(key("b"), .empty, bytes: 80)  // 10 + 80 = 90 ≤ 100 — nothing evicted
    let a = await c.get(key("a"))
    let b = await c.get(key("b"))
    XCTAssertNotNil(a, "a's bytes were replaced, so b fits without evicting it")
    XCTAssertNotNil(b)
  }
}
