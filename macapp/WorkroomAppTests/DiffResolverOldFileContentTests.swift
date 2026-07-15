import XCTest

@testable import Workroom

/// Tests for `DiffResolver.oldFileContent` — the PRE-IMAGE (old-side) content fetch that feeds
/// syntax-highlighting of a diff's DELETED lines. The crucial invariant is which backend method each
/// `DiffSource` routes to, and the base it resolves:
///   - `.commit(id)`               → `commitParentFileContent(commitID: id)` (the commit's first parent)
///   - `.gitWorktree` / `.jjWorkingCopy` → `workingBaseFileContent(base: .workingCopy)`
///   - `.jjParent`                 → `workingBaseFileContent(base: .parent)`
/// Real-backend behaviour (git parent walk / jj `@-`/`@--`) is covered by `VCSProviderConformanceTests`.
final class DiffResolverOldFileContentTests: XCTestCase {

  /// Records which pre-image method was called (and with what commit id / base), returning a
  /// configurable result. The two recorded methods override `VCSProviding`'s nil-returning defaults.
  private final class StubOldContentProvider: VCSProviding, @unchecked Sendable {
    var result: Result<String?, Error> = .success(nil)
    private let lock = NSLock()
    private var _parentCalls: [(commitID: String, path: String)] = []
    private var _baseCalls: [(base: VCSWorkingDiffBase, path: String)] = []
    var parentCalls: [(commitID: String, path: String)] {
      lock.lock()
      defer { lock.unlock() }
      return _parentCalls
    }
    var baseCalls: [(base: VCSWorkingDiffBase, path: String)] {
      lock.lock()
      defer { lock.unlock() }
      return _baseCalls
    }

    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
      .init(commits: [], reachedEnd: true)
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("unused")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String { "" }
    func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
      ""
    }
    func currentRef(root: URL) async throws -> VCSRef { .none }
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }

    func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String?
    {
      lock.lock()
      _parentCalls.append((commitID, path))
      lock.unlock()
      return try resolved()
    }
    func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
      -> String?
    {
      lock.lock()
      _baseCalls.append((base, path))
      lock.unlock()
      return try resolved()
    }

    private func resolved() throws -> String? {
      switch result {
      case .success(let s): return s
      case .failure(let e): throw e
      }
    }
  }

  private func resolver(_ provider: StubOldContentProvider) -> DiffResolver {
    DiffResolver(makeProvider: { _ in provider })
  }

  private func makeWorkroom() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("workroom-ofc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func desc(_ path: String, _ source: DiffSource) -> DiffDescriptor {
    DiffDescriptor(path: path, change: .modified, source: source, isPreview: false)
  }

  // MARK: - Routing: each source resolves to the right pre-image base

  func testCommitRoutesToParentContent() async throws {
    let dir = try makeWorkroom()
    let p = StubOldContentProvider()
    p.result = .success("old class User\nend\n")
    let content = await resolver(p).oldFileContent(
      for: desc("user.rb", .commit("abc123")), in: dir.path)
    XCTAssertEqual(content, "old class User\nend\n")
    XCTAssertEqual(p.parentCalls.first?.commitID, "abc123")
    XCTAssertEqual(p.parentCalls.first?.path, "user.rb")
    XCTAssertTrue(p.baseCalls.isEmpty, "a commit source must not use the working-copy base")
  }

  func testGitWorktreeRoutesToWorkingCopyBase() async throws {
    let dir = try makeWorkroom()
    let p = StubOldContentProvider()
    p.result = .success("before\n")
    let content = await resolver(p).oldFileContent(for: desc("a.go", .gitWorktree), in: dir.path)
    XCTAssertEqual(content, "before\n")
    XCTAssertEqual(p.baseCalls.first?.base, .workingCopy)
    XCTAssertTrue(p.parentCalls.isEmpty)
  }

  func testJJWorkingCopyRoutesToWorkingCopyBase() async throws {
    let dir = try makeWorkroom()
    let p = StubOldContentProvider()
    p.result = .success("before\n")
    _ = await resolver(p).oldFileContent(for: desc("a.rb", .jjWorkingCopy), in: dir.path)
    XCTAssertEqual(p.baseCalls.first?.base, .workingCopy)
  }

  func testJJParentRoutesToParentBase() async throws {
    let dir = try makeWorkroom()
    let p = StubOldContentProvider()
    p.result = .success("before\n")
    _ = await resolver(p).oldFileContent(for: desc("a.rb", .jjParent), in: dir.path)
    // The jj parent's pre-image is `@--` (base `.parent`), never `@-` (the working-copy base).
    XCTAssertEqual(p.baseCalls.first?.base, .parent)
    XCTAssertTrue(p.parentCalls.isEmpty)
  }

  // MARK: - Best-effort: absence / error degrades to nil (deletions render plain)

  func testProviderNilContentIsNil() async throws {
    let dir = try makeWorkroom()
    let p = StubOldContentProvider()
    p.result = .success(nil)  // added-at-this-commit / root commit / binary / over-cap
    let content = await resolver(p).oldFileContent(
      for: desc("x.rb", .commit("c1")), in: dir.path)
    XCTAssertNil(content)
  }

  func testProviderErrorIsNil() async throws {
    let dir = try makeWorkroom()
    let p = StubOldContentProvider()
    p.result = .failure(VCSError.notFound("no parent"))
    let content = await resolver(p).oldFileContent(for: desc("x.rb", .jjParent), in: dir.path)
    XCTAssertNil(content, "a backend error degrades to plain, never propagates")
  }
}
