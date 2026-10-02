import XCTest

@testable import Workroom

/// `GitProvider` (SwiftGitX) against real git repos: changeset file lists and line counts, working-copy
/// diffs, file content, history, current ref, renames and push state.
///
/// Requires real `git`. Throwaway repos under `NSTemporaryDirectory()`, removed in `tearDown` — never
/// touches a developer's own repositories.
final class VCSProviderConformanceTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  func testChangesetFileListAndLineCounts() async throws {
    try requireTool("git")
    let root = try gitFixture()
    let url = URL(fileURLWithPath: root)

    let cid = headID(root)
    XCTAssertFalse(cid.isEmpty, "could not resolve a commit id")

    let git = try await GitProvider().changeset(root: url, commitID: cid)

    func key(_ f: VCSChangedFile) -> String { "\(f.kind):\(f.path)" }
    XCTAssertEqual(git.commit.summary, "modify a, add b", "commit summary")
    XCTAssertEqual(
      Set(git.files.map(key)), Set(["modified:a.txt", "added:b.txt"]),
      "unexpected changed files")

    // The changeset header's +/- line-count summary. This commit adds one line to a.txt ("two") and
    // adds b.txt ("new") — 2 insertions, 0 deletions (summed libgit2 patch lines).
    XCTAssertEqual(git.insertions, 2, "git changeset insertions")
    XCTAssertEqual(git.deletions, 0, "git changeset deletions")
  }

  /// The working-copy per-file diff, read structurally (SwiftGitX/libgit2), must reflect an
  /// uncommitted on-disk edit — and must render an untracked file as an all-added diff from
  /// `/dev/null` (the SwiftGitX `patch(from:)` path that replaced the old `git diff --no-index`
  /// shell-out).
  func testWorkingFileDiff() async throws {
    try requireTool("git")
    let root = try gitFixture()
    let url = URL(fileURLWithPath: root)

    // An uncommitted edit to a tracked file + a brand-new untracked file.
    let r = sh(
      "printf 'one\\ntwo\\nthree\\n' > a.txt\nprintf 'brand new\\n' > c.txt\necho done", in: root)
    XCTAssertTrue(r.out.contains("done"), "working-copy edit failed: \(r.out)")

    let git = GitProvider()
    let gitModified = try await git.workingFileDiff(root: url, path: "a.txt", base: .workingCopy)
    XCTAssertTrue(gitModified.contains("diff --git a/a.txt b/a.txt"), "git header: \(gitModified)")
    XCTAssertTrue(gitModified.contains("+three"), "git missing the edit: \(gitModified)")

    let gitUntracked = try await git.workingFileDiff(root: url, path: "c.txt", base: .workingCopy)
    XCTAssertTrue(gitUntracked.contains("+brand new"), "git untracked content: \(gitUntracked)")
    XCTAssertTrue(
      gitUntracked.contains("/dev/null"), "untracked old side is /dev/null: \(gitUntracked)")
  }

  /// A file staged AND further modified in the worktree carries BOTH a `.index` delta (HEAD→index)
  /// and a `.workingTree` delta (index→worktree). `GitProvider.workingFileDiff` used to pick
  /// `.workingTree` alone (`entry.workingTree ?? entry.index`), so the diff showed only the SECOND
  /// edit and silently dropped the staged one.
  func testWorkingFileDiffCombinesStagedAndFurtherModifiedEdits() async throws {
    try requireTool("git")
    let root = try gitFixture()
    let url = URL(fileURLWithPath: root)

    // a.txt is "one\ntwo\n" at HEAD (see `gitFixture`). Stage one edit, then make a second,
    // unstaged edit on top of it.
    let r = sh(
      """
      printf 'one\\ntwo\\nthree\\n' > a.txt
      git add a.txt
      printf 'one\\ntwo\\nthree\\nfour\\n' > a.txt
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "staged+further-modified setup failed: \(r.out)")

    let diff = try await GitProvider().workingFileDiff(root: url, path: "a.txt", base: .workingCopy)
    XCTAssertTrue(diff.contains("diff --git a/a.txt b/a.txt"), "header: \(diff)")
    XCTAssertTrue(diff.contains("+three"), "staged half missing from combined diff: \(diff)")
    XCTAssertTrue(diff.contains("+four"), "unstaged half missing from combined diff: \(diff)")

    // Same shape for a file that never existed at HEAD: staged as a new file, then edited again —
    // the combined diff must still read as a whole-file add (`/dev/null` old side), not a
    // same-file modification against the STAGED snapshot.
    let r2 = sh(
      """
      printf 'first\\n' > d.txt
      git add d.txt
      printf 'first\\nsecond\\n' > d.txt
      echo done
      """, in: root)
    XCTAssertTrue(r2.out.contains("done"), "staged-add+further-modified setup failed: \(r2.out)")

    let addDiff = try await GitProvider().workingFileDiff(
      root: url, path: "d.txt", base: .workingCopy)
    XCTAssertTrue(addDiff.contains("/dev/null"), "new-since-HEAD old side: \(addDiff)")
    XCTAssertTrue(addDiff.contains("+first"), "staged half missing: \(addDiff)")
    XCTAssertTrue(addDiff.contains("+second"), "unstaged half missing: \(addDiff)")
  }

  /// The other half of `combinedWorkingDiff`: the worktree half DELETES what was staged, rather
  /// than further modifying it — `GitProvider.combinedWorkingDiff`'s dedicated `.deleted` branch,
  /// untested until now. A file that existed at HEAD (staged edit, then `rm` before commit) must
  /// still show as a deletion of the HEAD content — real `git diff HEAD` (not `--cached`) shows
  /// exactly this: the staged intermediate content was never simultaneously on disk with the HEAD
  /// blob, so it can't appear in a HEAD→worktree diff. A file that never existed at HEAD (staged as
  /// new, then `rm` before commit) has nothing to show either way.
  func testWorkingFileDiffHandlesStagedThenDeletedFromDisk() async throws {
    try requireTool("git")
    let root = try gitFixture()
    let url = URL(fileURLWithPath: root)

    // a.txt is "one\ntwo\n" at HEAD. Stage an edit, then delete the file from disk without staging
    // the deletion.
    let r = sh(
      """
      printf 'one\\ntwo\\nthree\\n' > a.txt
      git add a.txt
      rm a.txt
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "staged+deleted setup failed: \(r.out)")

    let diff = try await GitProvider().workingFileDiff(root: url, path: "a.txt", base: .workingCopy)
    XCTAssertTrue(diff.contains("diff --git a/a.txt b/a.txt"), "header: \(diff)")
    XCTAssertTrue(diff.contains("-one"), "HEAD content must render as removed: \(diff)")
    XCTAssertTrue(diff.contains("-two"), "HEAD content must render as removed: \(diff)")

    // Same shape for a file that never existed at HEAD: staged as new, then deleted before commit.
    let r2 = sh(
      """
      printf 'first\\n' > d.txt
      git add d.txt
      rm d.txt
      echo done
      """, in: root)
    XCTAssertTrue(r2.out.contains("done"), "staged-add+deleted setup failed: \(r2.out)")

    let addDiff = try await GitProvider().workingFileDiff(
      root: url, path: "d.txt", base: .workingCopy)
    XCTAssertEqual(
      addDiff, "",
      "staged-new-then-deleted never existed at HEAD and doesn't exist now — nothing to diff: \(addDiff)"
    )
  }

  /// A third shape `combinedWorkingDiff` must not mislabel: the INDEX half is a staged DELETE
  /// (`git rm`), then the worktree half recreates the file with new, untracked content. Both HEAD
  /// and disk have real content here — `gitFormat`'s `type` param only controls which SIDE renders
  /// as `/dev/null` (old side for `.added`/`.untracked`, new side for `.deleted`; it emits no
  /// rename/copy metadata regardless of type), so deriving it from the staged delta's raw
  /// `.deleted` type forced `/dev/null` onto the new side even though the patch's own hunks show
  /// real added lines against the recreated content — a self-contradictory diff.
  func testWorkingFileDiffHandlesStagedDeleteThenRecreatedOnDisk() async throws {
    try requireTool("git")
    let root = try gitFixture()
    let url = URL(fileURLWithPath: root)

    // a.txt is "one\ntwo\n" at HEAD. Stage its deletion, then recreate it with different content.
    let r = sh(
      """
      git rm a.txt
      printf 'brand new content\\n' > a.txt
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "staged-delete+recreated setup failed: \(r.out)")

    let diff = try await GitProvider().workingFileDiff(root: url, path: "a.txt", base: .workingCopy)
    XCTAssertTrue(diff.contains("diff --git a/a.txt b/a.txt"), "header: \(diff)")
    XCTAssertFalse(
      diff.contains("+++ /dev/null"),
      "the new side has real content (the recreated file) — must not render as /dev/null: \(diff)")
    XCTAssertTrue(
      diff.contains("+brand new content"), "recreated content missing from the diff: \(diff)")
  }

  /// `fileContent` (the new-side content that feeds syntax highlighting) must return the file's
  /// bytes at a committed revision (tree-walk to blob), and `nil` for a path absent at that revision.
  func testFileContentAtACommit() async throws {
    try requireTool("git")
    let root = try gitFixture()
    let url = URL(fileURLWithPath: root)

    // The last commit: a.txt is "one\ntwo\n", b.txt was added.
    let cid = headID(root)
    XCTAssertFalse(cid.isEmpty, "could not resolve a commit id")

    let gitContent = try await GitProvider().fileContent(root: url, rev: cid, path: "a.txt")
    XCTAssertEqual(gitContent, "one\ntwo\n", "git blob content at the commit")

    // A path that doesn't exist at that revision → nil (render plain, never throw out).
    let gitMissing = try await GitProvider().fileContent(root: url, rev: cid, path: "nope.txt")
    XCTAssertNil(gitMissing)
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

  /// Renames, which `testChangesetFileListAndLineCounts`'s fixture has none of.
  ///
  /// **Working-copy** state: git needs the rename staged (libgit2's `.renamesIndex` — an unstaged `mv`
  /// is a delete + an untracked file, with nothing to pair). It must land on `.renamed` at the NEW
  /// path, carry the old one, and NOT also list the old path as a separate delete.
  func testWorkingCopyRenameIsOneRow() async throws {
    try requireTool("git")
    let root = try gitRenameFixture()
    let url = URL(fileURLWithPath: root)

    let git = try GitProvider().workingStatus(root: url)
    let gitRow = try XCTUnwrap(
      (git.changedFiles ?? []).first { $0.path == "new.txt" },
      "git should report the renamed path; got \((git.changedFiles ?? []).map(\.id))")
    XCTAssertEqual(gitRow.change, .renamed, "git rename detection is on for status")
    XCTAssertEqual(gitRow.oldPath, "old.txt", "git carries the pre-move path")
    XCTAssertFalse(
      (git.changedFiles ?? []).contains { $0.path == "old.txt" },
      "git pairs the delete into the rename row; got \((git.changedFiles ?? []).map(\.id))")
  }

  /// The **commit** (History) counterpart of the working-copy test above, and the reason
  /// `GitCommitDiff` exists: a SwiftGitX `repo.diff(commit:)` is a plain tree-to-tree diff that no
  /// `git_diff_find_similar` ever touched, so git used to report delete + add here. git's own CLI
  /// defaults to `diff.renames=true`, so `git show` on this commit has always shown one rename row;
  /// this asserts we agree with it.
  ///
  /// The per-file diff text is checked too: a file list that says "renamed" while its diff renders a
  /// whole-file add is the half-fixed state, so it must carry `rename from` for the parser.
  func testCommitRenameIsOneRow() async throws {
    try requireTool("git")
    let root = try gitRenameFixture()
    let url = URL(fileURLWithPath: root)
    // Commit the staged rename so it can be read back by id.
    _ = sh("git commit -q -m 'rename old.txt' >/dev/null 2>&1; echo done", in: root)
    let cid = headID(root)
    XCTAssertFalse(cid.isEmpty, "could not resolve the rename commit id")

    let git = try await GitProvider().changeset(root: url, commitID: cid)
    XCTAssertEqual(
      Set(git.files.map { "\($0.kind):\($0.path)" }), Set(["renamed:new.txt"]),
      "git must pair a committed rename too; got \(git.files)")
    XCTAssertEqual(git.files.first?.oldPath, "old.txt")

    let text = try await GitProvider().fileDiff(root: url, commitID: cid, path: "new.txt")
    XCTAssertEqual(
      UnifiedDiff.parse(text).renamedFrom, "old.txt",
      "the per-file diff should name the pre-move path: \(text)")
  }

  /// Push state: libgit2 walks `HEAD --not refs/remotes/origin/*`. One pushed and one local-only
  /// commit must each decide — an all-`.unknown` page would mean nothing was measured.
  func testPushStateAgainstOrigin() async throws {
    try requireTool("git")
    let root = try gitWithOriginFixture()
    let url = URL(fileURLWithPath: root)

    let gitPage = try GitProvider().log(root: url, limit: 20)
    XCTAssertEqual(
      gitPage.commits.first { $0.summary == "first" }?.pushState, .pushed, "first is on origin")
    XCTAssertEqual(
      gitPage.commits.first { $0.summary == "second" }?.pushState, .unpushed,
      "second is local-only")
    XCTAssertEqual(gitPage.pushScope?.refName, "origin/main")
  }

  // MARK: - Fixture helpers

  /// A git repo on `main` with a bare `origin`: `first` is pushed to `origin/main`, `second` is
  /// local-only.
  private func gitWithOriginFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      git init -q --bare origin.git
      mkdir -p work && cd work
      git init -q -b main .
      git config user.name t && git config user.email a@b.c
      printf 'one\\n' > a.txt && git add a.txt && git commit -q -m first
      git remote add origin ../origin.git
      git push -q origin main >/dev/null 2>&1
      printf 'two\\n' > b.txt && git add b.txt && git commit -q -m second
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "git+origin fixture setup failed: \(r.out)")
    return root + "/work"
  }

  private func headID(_ root: String) -> String {
    sh("git rev-parse HEAD", in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct MissingTool: Error { let name: String }

  private func requireTool(_ name: String) throws {
    if sh("command -v \(name)", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`\(name)` is required for these tests; CI installs it (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-conf-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    dirs.append(d)
    return d
  }

  /// A git repo with two commits; the second changes a.txt (modified) and adds b.txt (added).
  private func gitFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      git init -q -b main .
      git config user.name t && git config user.email a@b.c
      printf 'one\\n' > a.txt && git add a.txt && git commit -q -m 'add a.txt'
      printf 'one\\ntwo\\n' > a.txt && printf 'new\\n' > b.txt
      git add a.txt b.txt && git commit -q -m 'modify a, add b'
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "git fixture setup failed: \(r.out)")
    return root
  }

  /// A git repo with `old.txt` committed, then renamed to `new.txt` and **staged** (`git mv`).
  /// Staging is what lets libgit2's status pair the rename. The body is 8 distinct lines so the two
  /// blobs are an exact match — libgit2 pairs identical content outright, no similarity threshold
  /// involved.
  private func gitRenameFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      git init -q -b main .
      git config user.name t && git config user.email a@b.c
      printf 'one\\ntwo\\nthree\\nfour\\nfive\\nsix\\nseven\\neight\\n' > old.txt
      git add old.txt && git commit -q -m 'add old.txt'
      git mv old.txt new.txt >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "rename fixture setup failed: \(r.out)")
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
