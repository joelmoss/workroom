import XCTest

@testable import Workroom

/// Integration tests that exercise `WorkroomStatusResolver` against REAL git/jj repos through the
/// REAL `StatusCommandRunner` (no mock). These prove the porcelain-v2/jj parsing matches what the
/// actual binaries emit (git 2.54, jj 0.42 verified) — the unit tests only cover hand-written
/// fixtures.
///
/// They **require** real `git` and `jj` (CI installs both — see `.github/workflows/ci.yml`); a
/// missing tool FAILS the suite rather than silently skipping, so the VCS layer can never go
/// un-exercised. Every repo is a **throwaway** created fresh under `NSTemporaryDirectory()` and
/// removed in `tearDown` — these tests NEVER touch any of the developer's own repositories.
final class WorkroomStatusIntegrationTests: XCTestCase {
  private var dirs: [String] = []
  private let resolver = WorkroomStatusResolver()  // real StatusCommandRunner

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: helpers

  private func tool(_ name: String) -> Bool {
    sh("command -v \(name)", in: NSTemporaryDirectory()).exit == 0
  }

  /// These tests REQUIRE the tool — a missing one is a hard failure (CI must install it), not a
  /// skip. Throws to abort the rest of the test once the failure is recorded.
  private struct MissingTool: Error { let name: String }
  private func requireTool(_ name: String) throws {
    if !tool(name) {
      XCTFail("`\(name)` is required for integration tests; CI installs it (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-it-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    dirs.append(d)
    return d
  }

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> (out: String, exit: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
      try p.run()
    } catch {
      return ("", -1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
  }

  /// A git repo with one commit on `main`, configured, with a bare upstream it tracks.
  private func gitRepoWithUpstream() throws -> String {
    try requireTool("git")
    let root = tempDir()
    sh(
      """
      git init -q --bare bare.git
      git clone -q bare.git work
      cd work && git config user.email a@b.c && git config user.name t \
        && git checkout -q -b main && echo one > a.txt && git add . && git commit -qm init \
        && git push -qu origin main
      """, in: root)
    return root + "/work"
  }

  // MARK: git

  func testGitClean() async throws {
    let dir = try gitRepoWithUpstream()
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertEqual(s.dirty, false)
    XCTAssertEqual(s.ahead, 0)
    XCTAssertEqual(s.behind, 0)
    XCTAssertEqual(s.branchForCI, "main")
    XCTAssertNil(s.failure)
  }

  func testGitModifiedAndUntracked() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && echo new > untr.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertEqual(s.dirty, true)
    XCTAssertFalse(s.conflicted)
    let kinds = Set((s.changedFiles ?? []).map(\.change))
    XCTAssertTrue(kinds.contains(.modified))
    XCTAssertTrue(kinds.contains(.untracked))
  }

  func testGitStagedAdd() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo s > staged.txt && git add staged.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "staged.txt" && $0.change == .added })
  }

  func testGitAheadOne() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && git commit -qam work", in: dir)  // commit locally, don't push
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertEqual(s.ahead, 1)
    XCTAssertEqual(s.behind, 0)
    XCTAssertEqual(s.dirty, false)  // committed → working tree clean
  }

  func testGitRename() async throws {
    let dir = try gitRepoWithUpstream()
    sh("git mv a.txt renamed.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "renamed.txt" && $0.change == .renamed })
  }

  func testGitDetachedHead() async throws {
    let dir = try gitRepoWithUpstream()
    sh("git checkout -q \"$(git rev-parse HEAD)\"", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertNil(s.ahead)  // detached → no upstream comparison
    XCTAssertNil(s.behind)
    XCTAssertNil(s.branchForCI)  // (detached) → no branch for CI
  }

  func testGitConflict() async throws {
    let dir = try gitRepoWithUpstream()
    sh(
      """
      git checkout -q -b feat && echo X > conf.txt && git add . && git commit -qm fx
      git checkout -q main && echo Y > conf.txt && git add . && git commit -qm mx
      git merge feat >/dev/null 2>&1 || true
      """, in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(s.conflicted)
    XCTAssertTrue((s.changedFiles ?? []).contains { $0.change == .conflicted })
  }

  func testGitNotARepoIsUnknownNotClean() async throws {
    try requireTool("git")
    let dir = tempDir()  // a plain empty directory, not a git repo
    let s = await resolver.resolveLocal(path: dir, vcs: "git")
    XCTAssertNil(s.dirty)  // unknown, NOT clean
    XCTAssertEqual(s.failure, .notRepository)
  }

  // MARK: jj (jj 0.42)

  private func jjRepo() throws -> String {
    try requireTool("jj")
    let dir = tempDir()
    let r = sh("jj git init . 2>/dev/null || jj init --git . 2>/dev/null; echo done", in: dir)
    XCTAssertTrue(r.out.contains("done"), "jj init failed in \(dir)")
    // Self-contained author so `jj commit`/`jj describe` work on a fresh CI runner (no global
    // jj config there — locally these would otherwise piggyback on the developer's ~/.jjconfig).
    sh("jj config set --repo user.email a@b.c; jj config set --repo user.name t", in: dir)
    return dir
  }

  func testJJClean() async throws {
    let dir = try jjRepo()
    let s = await resolver.resolveLocal(path: dir, vcs: "jj")
    XCTAssertEqual(s.dirty, false)
    XCTAssertFalse(s.conflicted)
    XCTAssertNil(s.ahead)  // jj omits ahead/behind in Phase 1
    XCTAssertNil(s.failure)
  }

  func testJJDirtyWithFiles() async throws {
    let dir = try jjRepo()
    sh("echo hello > f1.txt && echo world > f2.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "jj")
    XCTAssertEqual(s.dirty, true)
    XCTAssertEqual((s.changedFiles ?? []).count, 2)
    XCTAssertTrue((s.changedFiles ?? []).allSatisfy { $0.change == .added })
  }

  func testJJModifyAndDelete() async throws {
    let dir = try jjRepo()
    sh("echo a > f1.txt && echo b > f2.txt && jj commit -m base 2>/dev/null", in: dir)
    sh("echo changed > f1.txt && rm f2.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "jj")
    XCTAssertEqual(s.dirty, true)
    let kinds = Set((s.changedFiles ?? []).map(\.change))
    XCTAssertTrue(kinds.contains(.modified))
    XCTAssertTrue(kinds.contains(.deleted))
  }

  /// Proves the real jj head template + parse produce the description + bookmark for the Changes
  /// header (the jj "branch name" equivalent).
  func testJJHeadDescriptionAndBookmark() async throws {
    let dir = try jjRepo()
    sh("echo a > f.txt", in: dir)
    sh("jj describe -m 'my change (#9)' 2>/dev/null", in: dir)
    sh("jj bookmark create mybook -r @ 2>/dev/null", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "jj")
    XCTAssertEqual(s.jjDescription, "my change (#9)")
    XCTAssertEqual(s.jjRefs, ["mybook"])
    XCTAssertNotNil(s.jjChangeID)  // real jj always yields a change-id + commit-id for @
    XCTAssertNotNil(s.jjCommitID)
    // The change-id is its shortest unique prefix, unpadded (a one-commit repo → a 1-char prefix).
    XCTAssertFalse((s.jjChangeID ?? "").isEmpty)
    XCTAssertEqual((s.jjCommitID ?? "").count, 8)  // commit-id is jj's shortest-8 id
  }

  /// The real reason `branchForCI` exists for jj: `@` is a *detached* git HEAD (so the
  /// `git symbolic-ref` fallback in resolveCI/resolvePR finds nothing), and a bookmark normally
  /// sits at `@-` because `@` is an empty working-copy change on top. This proves the
  /// `heads(::@ & bookmarks())` revset resolves that ancestor bookmark — the branch pushed to
  /// origin that `gh` keys PR/CI off — even though it's not on `@` itself. Without it, PR/CI are
  /// inert for every jj workroom.
  func testJJBranchForCIResolvesAncestorBookmark() async throws {
    let dir = try jjRepo()
    sh("echo a > f.txt && jj describe -m base 2>/dev/null", in: dir)
    sh("jj bookmark create feature/login -r @ 2>/dev/null", in: dir)
    sh("jj new 2>/dev/null", in: dir)  // @ becomes a fresh empty change; the bookmark stays at @-
    let s = await resolver.resolveLocal(path: dir, vcs: "jj")
    // git symbolic-ref would fail here (detached HEAD); the revset finds the nearest bookmark.
    XCTAssertEqual(s.branchForCI, "feature/login")
  }
}
