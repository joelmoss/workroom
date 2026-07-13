import XCTest

@testable import Workroom

// MARK: - Test helpers

private struct MockDiffRunner: StatusCommandRunning {
  let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    handler(executable, args)
  }
}

private final class RecordingDiffRunner: StatusCommandRunning, @unchecked Sendable {
  private let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  private let lock = NSLock()
  private var _calls: [(exe: String, args: [String], dir: String)] = []
  var calls: [(exe: String, args: [String], dir: String)] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  init(_ handler: @escaping @Sendable (_ executable: String, _ args: [String]) -> CommandResult) {
    self.handler = handler
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    lock.lock()
    _calls.append((executable, args, directory))
    lock.unlock()
    return handler(executable, args)
  }
}

private func ok(_ stdout: String = "") -> CommandResult {
  CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
}

private func fail(_ stderr: String = "command failed", exitCode: Int32 = 1) -> CommandResult {
  CommandResult(stdout: "", stderr: stderr, exitCode: exitCode, timedOut: false)
}

private func timedOut() -> CommandResult {
  CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: true)
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

// MARK: - Tests

final class DiffResolverTests: XCTestCase {

  // MARK: - command(for:dir:) — jj sources

  func testCommandJJWorkingCopy() {
    let desc = DiffDescriptor(
      path: "src/foo.swift", change: .modified, source: .jjWorkingCopy, isPreview: false)
    let (exe, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertEqual(exe, "jj")
    XCTAssertEqual(args, ["diff", "--git", "-r", "@", "--color", "never", "--", "src/foo.swift"])
  }

  func testCommandJJWorkingCopyAllChangeKinds() {
    // Source is what matters for jj — change kind doesn't alter the args
    for change: ChangedFile.Change in [.modified, .added, .deleted, .renamed, .untracked, .other] {
      let desc = DiffDescriptor(
        path: "p.txt", change: change, source: .jjWorkingCopy, isPreview: false)
      let (exe, args) = DiffResolver.command(for: desc, dir: "/repo")
      XCTAssertEqual(exe, "jj")
      XCTAssertTrue(args.contains("-r"), "missing -r flag for change \(change)")
      XCTAssertTrue(args.contains("@"), "missing @ for change \(change)")
      XCTAssertFalse(
        args.contains("--ignore-working-copy"),
        "jjWorkingCopy must not have --ignore-working-copy for change \(change)")
    }
  }

  func testCommandJJParent() {
    let desc = DiffDescriptor(
      path: "lib/bar.swift", change: .modified, source: .jjParent, isPreview: false)
    let (exe, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertEqual(exe, "jj")
    XCTAssertEqual(
      args,
      [
        "diff", "--git", "-r", "@-", "--ignore-working-copy", "--color", "never", "--",
        "lib/bar.swift",
      ])
  }

  func testCommandJJParentHasIgnoreWorkingCopy() {
    let desc = DiffDescriptor(
      path: "p.txt", change: .added, source: .jjParent, isPreview: false)
    let (_, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertTrue(args.contains("--ignore-working-copy"))
    XCTAssertTrue(args.contains("@-"))
  }

  // MARK: - command(for:dir:) — git sources

  func testCommandGitWorktreeModified() {
    let desc = DiffDescriptor(
      path: "src/main.swift", change: .modified, source: .gitWorktree, isPreview: false)
    let (exe, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertEqual(exe, "git")
    // Must begin with gitHardening flags
    let hardening = WorkroomStatusResolver.gitHardening
    XCTAssertTrue(args.starts(with: hardening), "args must start with gitHardening")
    // Must contain core.quotePath=false
    XCTAssertTrue(args.contains("core.quotePath=false"))
    // Must NOT contain -M (not a rename)
    XCTAssertFalse(args.contains("-M"))
    // Must contain HEAD and the path
    XCTAssertTrue(args.contains("HEAD"))
    XCTAssertTrue(args.contains("src/main.swift"))
    // Must not contain --no-index
    XCTAssertFalse(args.contains("--no-index"))
  }

  func testCommandGitWorktreeAdded() {
    let desc = DiffDescriptor(
      path: "new.txt", change: .added, source: .gitWorktree, isPreview: false)
    let (_, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertFalse(args.contains("-M"))
    XCTAssertTrue(args.contains("HEAD"))
  }

  func testCommandGitWorktreeDeleted() {
    let desc = DiffDescriptor(
      path: "gone.txt", change: .deleted, source: .gitWorktree, isPreview: false)
    let (_, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertFalse(args.contains("-M"))
    XCTAssertTrue(args.contains("HEAD"))
  }

  func testCommandGitWorktreeRenamed() {
    let desc = DiffDescriptor(
      path: "renamed.swift", change: .renamed, source: .gitWorktree, isPreview: false)
    let (exe, args) = DiffResolver.command(for: desc, dir: "/repo")
    XCTAssertEqual(exe, "git")
    let hardening = WorkroomStatusResolver.gitHardening
    XCTAssertTrue(args.starts(with: hardening))
    XCTAssertTrue(args.contains("-M"), "renamed must include -M")
    XCTAssertTrue(args.contains("HEAD"))
    XCTAssertTrue(args.contains("renamed.swift"))
  }

  func testCommandGitWorktreeUntracked() {
    let dir = "/my/repo"
    let path = "untracked/file.txt"
    let desc = DiffDescriptor(
      path: path, change: .untracked, source: .gitWorktree, isPreview: false)
    let (exe, args) = DiffResolver.command(for: desc, dir: dir)
    XCTAssertEqual(exe, "git")
    let hardening = WorkroomStatusResolver.gitHardening
    XCTAssertTrue(args.starts(with: hardening))
    XCTAssertTrue(args.contains("--no-index"))
    XCTAssertTrue(args.contains("/dev/null"))
    // absPath must be an absolute path ending with the relative path
    let absPath = args.last ?? ""
    XCTAssertTrue(absPath.hasPrefix("/"), "absPath must be absolute: \(absPath)")
    XCTAssertTrue(absPath.hasSuffix(path), "absPath must end with the relative path: \(absPath)")
    // Must NOT contain HEAD or -M
    XCTAssertFalse(args.contains("HEAD"))
    XCTAssertFalse(args.contains("-M"))
  }

  func testCommandGitHardeningPresentInAllGitCases() {
    let hardening = WorkroomStatusResolver.gitHardening
    let cases: [(String, ChangedFile.Change)] = [
      ("f.txt", .modified), ("f.txt", .added), ("f.txt", .deleted), ("f.txt", .renamed),
      ("f.txt", .untracked), ("f.txt", .conflicted), ("f.txt", .other),
    ]
    for (path, change) in cases {
      let desc = DiffDescriptor(path: path, change: change, source: .gitWorktree, isPreview: false)
      let (_, args) = DiffResolver.command(for: desc, dir: "/repo")
      XCTAssertTrue(
        args.starts(with: hardening),
        "gitHardening must be first in args for change \(change)")
    }
  }

  // MARK: - resolve(_:in:) — success paths

  func testResolveDiff() async {
    let runner = MockDiffRunner { _, _ in ok(sampleDiff) }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "f.txt", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    guard case .diff(let ud) = result else {
      XCTFail("Expected .diff, got \(result)")
      return
    }
    XCTAssertEqual(ud.hunks.count, 1)
  }

  func testResolveBinary() async {
    let runner = MockDiffRunner { _, _ in ok(binaryDiff) }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "img.png", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .binary)
  }

  func testResolveEmpty() async {
    let runner = MockDiffRunner { _, _ in ok("") }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "f.txt", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .empty)
  }

  func testResolveEmptyWhitespace() async {
    let runner = MockDiffRunner { _, _ in ok("   \n  ") }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "f.txt", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .empty)
  }

  func testResolveTimedOut() async {
    let runner = MockDiffRunner { _, _ in timedOut() }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "f.txt", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .failed("Timed out"))
  }

  func testResolveNonZeroExit() async {
    let runner = MockDiffRunner { _, _ in fail("fatal: not a repo") }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "f.txt", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    guard case .failed(let msg) = result else {
      XCTFail("Expected .failed, got \(result)")
      return
    }
    XCTAssertEqual(msg, "fatal: not a repo")
  }

  func testResolveNonZeroExitEmptyStderr() async {
    let runner = MockDiffRunner { _, _ in
      CommandResult(stdout: "", stderr: "", exitCode: 2, timedOut: false)
    }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "f.txt", change: .modified, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .failed("Diff unavailable"))
  }

  // MARK: - resolve: untracked special cases

  func testResolveUntrackedExit1IsSuccess() async {
    // git --no-index exits 1 when files differ (that IS the success path)
    let runner = MockDiffRunner { _, _ in
      CommandResult(stdout: sampleDiff, stderr: "", exitCode: 1, timedOut: false)
    }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "new.txt", change: .untracked, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    guard case .diff = result else {
      XCTFail("Expected .diff for untracked exit-1, got \(result)")
      return
    }
  }

  func testResolveUntrackedExit0IsEmpty() async {
    // exit 0 from --no-index means files are identical → empty
    let runner = MockDiffRunner { _, _ in ok("") }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "new.txt", change: .untracked, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .empty)
  }

  func testResolveUntrackedTimedOutIsFailed() async {
    let runner = MockDiffRunner { _, _ in timedOut() }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "new.txt", change: .untracked, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    XCTAssertEqual(result, .failed("Timed out"))
  }

  func testResolveUntrackedExit2IsFailed() async {
    // Any other non-zero exit (e.g. 2 = usage error) is a genuine failure
    let runner = MockDiffRunner { _, _ in
      CommandResult(stdout: "", stderr: "bad usage", exitCode: 2, timedOut: false)
    }
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let desc = DiffDescriptor(
      path: "new.txt", change: .untracked, source: .gitWorktree, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    guard case .failed = result else {
      XCTFail("Expected .failed for untracked exit-2, got \(result)")
      return
    }
  }

  // MARK: - resolve: jj sources

  func testResolveJJWorkingCopy() async {
    let recording = RecordingDiffRunner { _, _ in ok(sampleDiff) }
    let resolver = DiffResolver(runner: recording, timeout: 5)
    let desc = DiffDescriptor(
      path: "a.txt", change: .modified, source: .jjWorkingCopy, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    guard case .diff = result else {
      XCTFail("Expected .diff, got \(result)")
      return
    }
    let call = recording.calls.first
    XCTAssertEqual(call?.exe, "jj")
    XCTAssertTrue(call?.args.contains("-r") == true)
    XCTAssertTrue(call?.args.contains("@") == true)
  }

  func testResolveJJParent() async {
    let recording = RecordingDiffRunner { _, _ in ok(sampleDiff) }
    let resolver = DiffResolver(runner: recording, timeout: 5)
    let desc = DiffDescriptor(
      path: "b.txt", change: .modified, source: .jjParent, isPreview: false)
    let result = await resolver.resolve(desc, in: "/repo")
    guard case .diff = result else {
      XCTFail("Expected .diff, got \(result)")
      return
    }
    let call = recording.calls.first
    XCTAssertEqual(call?.exe, "jj")
    XCTAssertTrue(call?.args.contains("@-") == true)
    XCTAssertTrue(call?.args.contains("--ignore-working-copy") == true)
  }

  // MARK: - .commit source routes through VCSProviding (issue #59), not the shell runner

  /// A commit-scoped diff bypasses the command runner entirely and reads through the injected VCS
  /// backend: the runner must never be called, and the backend's git-format text parses to `.diff`.
  func testResolveCommitRoutesThroughProviderAndNeverShells() async {
    let recording = RecordingDiffRunner { _, _ in
      XCTFail("commit diffs must not shell out")
      return ok("")
    }
    var seen: (root: URL, commitID: String, path: String)?
    let provider = StubDiffProvider { root, commitID, path in
      seen = (root, commitID, path)
      return sampleDiff
    }
    let resolver = DiffResolver(runner: recording, timeout: 5, makeProvider: { _ in provider })
    let desc = DiffDescriptor(
      path: "b.txt", change: .modified, source: .commit("abc123"), isPreview: false)

    let result = await resolver.resolve(desc, in: "/repo")

    guard case .diff = result else {
      XCTFail("Expected .diff, got \(result)")
      return
    }
    XCTAssertTrue(recording.calls.isEmpty, "the shell runner is never used for a commit diff")
    XCTAssertEqual(seen?.commitID, "abc123")
    XCTAssertEqual(seen?.path, "b.txt")
    XCTAssertEqual(seen?.root.path, "/repo")
  }

  func testResolveCommitMapsBinaryAndEmpty() async {
    let binary = DiffResolver(
      runner: MockDiffRunner { _, _ in ok() },
      makeProvider: { _ in StubDiffProvider { _, _, _ in binaryDiff } })
    let binResult = await binary.resolve(
      DiffDescriptor(path: "img.png", change: .modified, source: .commit("x"), isPreview: false),
      in: "/repo")
    XCTAssertEqual(binResult, .binary)

    let empty = DiffResolver(
      runner: MockDiffRunner { _, _ in ok() },
      makeProvider: { _ in StubDiffProvider { _, _, _ in "   \n" } })
    let emptyResult = await empty.resolve(
      DiffDescriptor(path: "a.txt", change: .modified, source: .commit("x"), isPreview: false),
      in: "/repo")
    XCTAssertEqual(emptyResult, .empty)
  }

  /// A backend error surfaces as `.failed` with the error's message (never a silent empty).
  func testResolveCommitBackendErrorFails() async {
    let resolver = DiffResolver(
      runner: MockDiffRunner { _, _ in ok() },
      makeProvider: { _ in StubDiffProvider { _, _, _ in throw VCSError.notFound("no such commit") }
      })
    let result = await resolver.resolve(
      DiffDescriptor(path: "a.txt", change: .modified, source: .commit("bad"), isPreview: false),
      in: "/repo")
    guard case .failed(let message) = result else {
      XCTFail("Expected .failed, got \(result)")
      return
    }
    XCTAssertTrue(message.contains("no such commit"), "the backend message is surfaced: \(message)")
  }
}

/// A `VCSProviding` whose `fileDiff` is a closure; `log`/`changeset` are unused here.
private struct StubDiffProvider: VCSProviding {
  let diff: @Sendable (_ root: URL, _ commitID: String, _ path: String) throws -> String
  func log(root: URL, limit: Int) async throws -> VCSHistoryPage {
    .init(commits: [], reachedEnd: true)
  }
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    throw VCSError.io("unused")
  }
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    try diff(root, commitID, path)
  }
  func currentRef(root: URL) async throws -> VCSRef { .none }
}
