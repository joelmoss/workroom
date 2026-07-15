import XCTest

@testable import Workroom

/// Cross-backend conformance: on a **colocated** jj+git repo (where a jj commit-id == the git sha),
/// `RustJJProvider` (jj-lib) and `GitProvider` (SwiftGitX) must produce the SAME changeset file list
/// for the same commit. This guards against the two backends drifting on add/modify/delete
/// classification — the risk the hybrid architecture accepts (plan: "unify at the model layer +
/// a cross-backend conformance test").
///
/// Requires real `git` + `jj` (CI installs both). Throwaway repos under `NSTemporaryDirectory()`,
/// removed in `tearDown` — never touches a developer's own repositories.
final class VCSProviderConformanceTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  func testColocatedChangesetFileListMatchesAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedFixture()
    let url = URL(fileURLWithPath: root)

    // The changeset under test = the parent of the working copy (the last real commit).
    let cid = sh(
      "jj log -r @- --no-graph --ignore-working-copy --color never -T 'commit_id'", in: root
    ).out.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(cid.isEmpty, "could not resolve a commit id")

    let jj = try await RustJJProvider().changeset(root: url, commitID: cid)
    let git = try await GitProvider().changeset(root: url, commitID: cid)

    func key(_ f: VCSChangedFile) -> String { "\(f.kind):\(f.path)" }
    XCTAssertEqual(
      Set(jj.files.map(key)), Set(git.files.map(key)),
      "changeset file lists differ between jj and git backends")
    XCTAssertEqual(jj.commit.summary, git.commit.summary, "commit summary differs")
    XCTAssertEqual(
      Set(jj.files.map(key)), Set(["modified:a.txt", "added:b.txt"]),
      "unexpected changed files")

    // The changeset header's +/- line-count summary. This commit adds one line to a.txt ("two") and
    // adds b.txt ("new") — 2 insertions, 0 deletions — and both backends must agree (git = summed
    // libgit2 patch lines; jj = one `jj diff --stat`).
    XCTAssertEqual(git.insertions, 2, "git changeset insertions")
    XCTAssertEqual(git.deletions, 0, "git changeset deletions")
    XCTAssertEqual(jj.insertions, git.insertions, "insertions differ between jj and git backends")
    XCTAssertEqual(jj.deletions, git.deletions, "deletions differ between jj and git backends")
  }

  /// The working-copy per-file diff, read structurally by each backend (git = SwiftGitX/libgit2, jj
  /// = the `jj diff --git` CLI fallback), must reflect an uncommitted on-disk edit — and git must
  /// render an untracked file as an all-added diff from `/dev/null` (the SwiftGitX `patch(from:)`
  /// path that replaced the old `git diff --no-index` shell-out).
  func testWorkingFileDiffAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedFixture()
    let url = URL(fileURLWithPath: root)

    // An uncommitted edit to a tracked file + a brand-new untracked file.
    let r = sh(
      "printf 'one\\ntwo\\nthree\\n' > a.txt\nprintf 'brand new\\n' > c.txt\necho done", in: root)
    XCTAssertTrue(r.out.contains("done"), "working-copy edit failed: \(r.out)")

    // Read git first (all git reads before any jj read, so jj's snapshot can't perturb git status).
    let git = GitProvider()
    let gitModified = try await git.workingFileDiff(root: url, path: "a.txt", base: .workingCopy)
    XCTAssertTrue(gitModified.contains("diff --git a/a.txt b/a.txt"), "git header: \(gitModified)")
    XCTAssertTrue(gitModified.contains("+three"), "git missing the edit: \(gitModified)")

    let gitUntracked = try await git.workingFileDiff(root: url, path: "c.txt", base: .workingCopy)
    XCTAssertTrue(gitUntracked.contains("+brand new"), "git untracked content: \(gitUntracked)")
    XCTAssertTrue(
      gitUntracked.contains("/dev/null"), "untracked old side is /dev/null: \(gitUntracked)")

    // git has no working-copy parent concept → unsupported (jj-only surface).
    do {
      _ = try await git.workingFileDiff(root: url, path: "a.txt", base: .parent)
      XCTFail("git .parent working diff should be unsupported")
    } catch let error as VCSError {
      guard case .unsupportedRepo = error else {
        return XCTFail("expected .unsupportedRepo: \(error)")
      }
    }

    // jj snapshots `@` and shows the same edit.
    let jjModified = try await RustJJProvider().workingFileDiff(
      root: url, path: "a.txt", base: .workingCopy)
    XCTAssertTrue(jjModified.contains("+three"), "jj missing the edit: \(jjModified)")
  }

  /// `fileContent` (the new-side content that feeds syntax highlighting) must return the file's
  /// bytes at a committed revision from both backends (git = tree-walk to blob, jj = `jj file show`),
  /// and `nil` for a path absent at that revision.
  func testFileContentAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedFixture()
    let url = URL(fileURLWithPath: root)

    // The last real commit (@-): a.txt is "one\ntwo\n", b.txt was added.
    let cid = sh(
      "jj log -r @- --no-graph --ignore-working-copy --color never -T 'commit_id'", in: root
    ).out.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(cid.isEmpty, "could not resolve a commit id")

    let gitContent = try await GitProvider().fileContent(root: url, rev: cid, path: "a.txt")
    XCTAssertEqual(gitContent, "one\ntwo\n", "git blob content at the commit")

    let jjContent = try await RustJJProvider().fileContent(root: url, rev: cid, path: "a.txt")
    XCTAssertEqual(jjContent, "one\ntwo\n", "jj file show content at the commit")

    // A path that doesn't exist at that revision → nil from both (render plain, never throw out).
    let gitMissing = try await GitProvider().fileContent(root: url, rev: cid, path: "nope.txt")
    XCTAssertNil(gitMissing)
    let jjMissing = try await RustJJProvider().fileContent(root: url, rev: cid, path: "nope.txt")
    XCTAssertNil(jjMissing)
  }

  /// `GitProvider.log` (SwiftGitX) against a real repo: newest-first ordering and the `reachedEnd`
  /// boundary (it takes one extra commit to learn whether more history exists). Previously only a
  /// stub/fake exercised `log`; the real libgit2 walk had no coverage.
  func testGitLogOrderingAndPagination() async throws {
    try requireTool("git")
    let root = try plainGitFixture()
    let url = URL(fileURLWithPath: root)
    let git = GitProvider()

    let all = try git.log(root: url, limit: 10)
    XCTAssertEqual(all.commits.map(\.summary), ["third", "second", "first"], "newest-first")
    XCTAssertTrue(all.reachedEnd, "the whole history fits in the page")

    let page = try git.log(root: url, limit: 2)
    XCTAssertEqual(page.commits.map(\.summary), ["third", "second"], "first page, newest-first")
    XCTAssertFalse(page.reachedEnd, "a third commit exists beyond the 2-commit page")
  }

  /// `GitProvider.currentRef` real branches: an attached HEAD reports its branch; a detached HEAD
  /// reports the short SHA with `.detached`. (The unborn-HEAD path depends on git config resolution
  /// and is left to manual verification.)
  func testGitCurrentRefBranchAndDetached() async throws {
    try requireTool("git")
    let root = try plainGitFixture()
    let url = URL(fileURLWithPath: root)

    let onBranch = try await GitProvider().currentRef(root: url)
    XCTAssertEqual(onBranch.kind, .branch)
    XCTAssertEqual(onBranch.name, "main")

    // Detach HEAD at the tip → the short SHA, kind `.detached`.
    let sha = sh("git rev-parse HEAD", in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = sh("git checkout --detach \(sha) >/dev/null 2>&1; echo done", in: root)
    let detached = try await GitProvider().currentRef(root: url)
    XCTAssertEqual(detached.kind, .detached)
    let name = try XCTUnwrap(detached.name)
    XCTAssertTrue(sha.hasPrefix(name), "detached ref \(name) should be a prefix of HEAD \(sha)")
  }

  /// `RustJJProvider.log` (jj-lib `log_page`) and `currentRef` against a real jj repo — neither had
  /// real-backend coverage. The log must surface both real commits plus the `@` working-copy commit;
  /// a bookmark placed on `@` must resolve as the current `.branch`.
  func testJJLogAndCurrentRef() async throws {
    try requireTool("jj")
    let root = try jjBookmarkFixture()
    let url = URL(fileURLWithPath: root)

    let page = try RustJJProvider().log(root: url, limit: 20)
    let summaries = page.commits.map(\.summary)
    XCTAssertTrue(
      summaries.contains("modify a, add b"), "jj log missing newest commit: \(summaries)")
    XCTAssertTrue(summaries.contains("add a.txt"), "jj log missing first commit: \(summaries)")
    XCTAssertTrue(
      page.commits.contains { $0.isWorkingCopy }, "jj log should include the @ working-copy commit")

    let ref = try await RustJJProvider().currentRef(root: url)
    XCTAssertEqual(ref.name, "feature", "the bookmark on @ is the current ref")
    XCTAssertEqual(ref.kind, .branch)
  }

  // MARK: - Fixture helpers (mirror WorkroomStatusIntegrationTests)

  private struct MissingTool: Error { let name: String }

  private func requireTool(_ name: String) throws {
    if sh("command -v \(name)", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`\(name)` is required for conformance tests; CI installs it (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-conf-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    dirs.append(d)
    return d
  }

  /// A colocated jj+git repo with two real commits; the second changes a.txt (modified) and adds
  /// b.txt (added). Colocated init means jj exports commits to git, so the git repo sees the same
  /// commit under the same sha.
  private func colocatedFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      jj git init . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      printf 'one\\n' > a.txt
      jj commit -m 'add a.txt' >/dev/null 2>&1
      printf 'one\\ntwo\\n' > a.txt
      printf 'new\\n' > b.txt
      jj commit -m 'modify a, add b' >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "colocated fixture setup failed: \(r.out)")
    return root
  }

  /// A plain git repo on branch `main` with three commits (`first`, `second`, `third`, oldest→newest).
  private func plainGitFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      git init -b main >/dev/null 2>&1
      git config user.name t >/dev/null 2>&1
      git config user.email a@b.c >/dev/null 2>&1
      printf 'one\\n' > a.txt && git add a.txt && git commit -m first >/dev/null 2>&1
      printf 'two\\n' >> a.txt && git commit -am second >/dev/null 2>&1
      printf 'three\\n' >> a.txt && git commit -am third >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "plain git fixture setup failed: \(r.out)")
    return root
  }

  /// A jj repo with two commits and a bookmark `feature` on `@` (the working copy), so `currentRef`
  /// resolves to that branch.
  private func jjBookmarkFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      jj git init . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      printf 'one\\n' > a.txt
      jj commit -m 'add a.txt' >/dev/null 2>&1
      printf 'one\\ntwo\\n' > a.txt
      printf 'new\\n' > b.txt
      jj commit -m 'modify a, add b' >/dev/null 2>&1
      jj bookmark create feature -r @ >/dev/null 2>&1 || jj bookmark set feature -r @ >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "jj bookmark fixture setup failed: \(r.out)")
    return root
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
}
