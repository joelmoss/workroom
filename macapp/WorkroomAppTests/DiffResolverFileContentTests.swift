import XCTest

@testable import Workroom

/// Tests for `DiffResolver.fileContent` — the new-side content fetch that feeds syntax highlighting.
/// Working-copy sources read disk directly (guarded; exercised against a real temp workroom, never a
/// real repo); commit / jj-parent sources read through `VCSProviding.fileContent` (a stub here — the
/// crucial invariant is the revision each source resolves to, and that working-copy reads never touch
/// the backend). Real-backend behaviour is covered by `VCSProviderConformanceTests`.
final class DiffResolverFileContentTests: XCTestCase {

  /// Records `fileContent` calls and returns a configurable result (or throws). All other
  /// `VCSProviding` members are unused stubs.
  private final class StubContentProvider: VCSProviding, @unchecked Sendable {
    var result: Result<String?, Error> = .success(nil)
    private let lock = NSLock()
    private var _calls: [(rev: String, path: String)] = []
    var calls: [(rev: String, path: String)] {
      lock.lock()
      defer { lock.unlock() }
      return _calls
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
    func fileContent(root: URL, rev: String, path: String) async throws -> String? {
      lock.lock()
      _calls.append((rev, path))
      lock.unlock()
      switch result {
      case .success(let s): return s
      case .failure(let e): throw e
      }
    }
  }

  private func resolver(_ provider: StubContentProvider) -> DiffResolver {
    DiffResolver(makeProvider: { _ in provider })
  }

  /// A fresh temp workroom directory, auto-removed at test end.
  private func makeWorkroom() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("workroom-fc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func desc(_ path: String, _ source: DiffSource, _ change: ChangedFile.Change = .modified)
    -> DiffDescriptor
  {
    DiffDescriptor(path: path, change: change, source: source, isPreview: false)
  }

  // MARK: - Committed sources read through the backend at the right revision

  func testCommitRoutesToProviderAtCommitRev() async throws {
    let dir = try makeWorkroom()
    let p = StubContentProvider()
    p.result = .success("class User\nend\n")
    let content = await resolver(p).fileContent(
      for: desc("user.rb", .commit("abc123")), in: dir.path)
    XCTAssertEqual(content, "class User\nend\n")
    XCTAssertEqual(p.calls.first?.rev, "abc123")
    XCTAssertEqual(p.calls.first?.path, "user.rb")
  }

  func testJJParentRoutesToProviderAtParentRev() async throws {
    let dir = try makeWorkroom()
    let p = StubContentProvider()
    p.result = .success("puts 1\n")
    let content = await resolver(p).fileContent(for: desc("a.rb", .jjParent), in: dir.path)
    XCTAssertEqual(content, "puts 1\n")
    // The jj parent's content must come from `@-`, never `@` (which would take the working-copy lock).
    XCTAssertEqual(p.calls.first?.rev, "@-")
    XCTAssertFalse(p.calls.contains { $0.rev == "@" }, "must never read -r @")
  }

  func testProviderNilContentIsNil() async throws {
    let dir = try makeWorkroom()
    let p = StubContentProvider()
    p.result = .success(nil)  // absent / binary / over-cap at the backend
    let content = await resolver(p).fileContent(for: desc("x.rb", .commit("c1")), in: dir.path)
    XCTAssertNil(content)
  }

  func testProviderErrorIsNil() async throws {
    let dir = try makeWorkroom()
    let p = StubContentProvider()
    p.result = .failure(VCSError.notFound("no such path"))
    let content = await resolver(p).fileContent(for: desc("x.rb", .jjParent), in: dir.path)
    XCTAssertNil(content, "a backend error degrades to plain, never propagates")
  }

  // MARK: - Working-copy sources read disk (the backend must NOT be touched)

  func testGitWorktreeReadsDiskWithoutBackend() async throws {
    let dir = try makeWorkroom()
    let body = "func main() {}\n"
    try body.write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
    let p = StubContentProvider()
    let content = await resolver(p).fileContent(for: desc("main.go", .gitWorktree), in: dir.path)
    XCTAssertEqual(content, body)
    XCTAssertTrue(p.calls.isEmpty, "working-copy reads come from disk, never the backend")
  }

  func testJJWorkingCopyReadsDisk() async throws {
    let dir = try makeWorkroom()
    let body = "puts 'hi'\n"
    try body.write(to: dir.appendingPathComponent("a.rb"), atomically: true, encoding: .utf8)
    let p = StubContentProvider()
    let content = await resolver(p).fileContent(for: desc("a.rb", .jjWorkingCopy), in: dir.path)
    XCTAssertEqual(content, body)
    XCTAssertTrue(p.calls.isEmpty)
  }

  func testNestedPathReadsDisk() async throws {
    let dir = try makeWorkroom()
    let sub = dir.appendingPathComponent("app/models", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let body = "class User; end\n"
    try body.write(to: sub.appendingPathComponent("user.rb"), atomically: true, encoding: .utf8)
    let content = await resolver(StubContentProvider()).fileContent(
      for: desc("app/models/user.rb", .gitWorktree), in: dir.path)
    XCTAssertEqual(content, body)
  }

  // MARK: - Guards (working-copy disk read)

  func testMissingFileIsNil() async throws {
    let dir = try makeWorkroom()
    let content = await resolver(StubContentProvider()).fileContent(
      for: desc("gone.swift", .gitWorktree), in: dir.path)
    XCTAssertNil(content)
  }

  func testSymlinkLeafIsNil() async throws {
    let dir = try makeWorkroom()
    // A real file outside the workroom, and a symlink inside pointing at it.
    let outside = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fc-target-\(UUID().uuidString).swift")
    try "let secret = 1\n".write(to: outside, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
    let link = dir.appendingPathComponent("link.swift")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let content = await resolver(StubContentProvider()).fileContent(
      for: desc("link.swift", .gitWorktree), in: dir.path)
    XCTAssertNil(content, "a symlink's diff is its target-path text, not file content → plain")
  }

  func testPathEscapingWorkroomIsNil() async throws {
    let dir = try makeWorkroom()
    let content = await resolver(StubContentProvider()).fileContent(
      for: desc("../../../../etc/hosts", .gitWorktree), in: dir.path)
    XCTAssertNil(content, "a path escaping the workroom must not be read")
  }

  func testOverCapFileIsNil() async throws {
    let dir = try makeWorkroom()
    let big = String(repeating: "x", count: SyntaxLanguage.byteCap + 10)
    try big.write(to: dir.appendingPathComponent("big.json"), atomically: true, encoding: .utf8)
    let content = await resolver(StubContentProvider()).fileContent(
      for: desc("big.json", .gitWorktree), in: dir.path)
    XCTAssertNil(content, "files over the byte cap must render plain")
  }
}
