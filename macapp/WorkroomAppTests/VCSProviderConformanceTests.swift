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
