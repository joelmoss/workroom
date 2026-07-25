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

  /// The ONE place the two backends are *allowed* to disagree, asserted so it can't be mistaken for
  /// drift: a **conflicted commit**. jj stores conflicts in the tree, so `RustJJProvider` reports the
  /// conflicted path with `.conflicted`. git has no such concept, and a colocated repo doesn't see a
  /// conflict at all — jj exports the commit with its internal sidecar representation
  /// (`.jjconflict-base-0/…`, `.jjconflict-side-N/…`, `JJ-CONFLICT-README`), so `GitProvider` reports
  /// those paths as ADDs and never mentions the conflicted file.
  ///
  /// Consequence for `testColocatedChangesetFileListMatchesAcrossBackends`: its set-equality assertion
  /// holds for add/modify/delete only. Do NOT add a conflict to `colocatedFixture()` expecting parity —
  /// conflicted commits are covered here instead.
  func testColocatedConflictedCommitDivergesByDesign() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedConflictFixture()
    let url = URL(fileURLWithPath: root)

    // The conflicted merge is now `@-` (the fixture commits it).
    let cid = sh(
      "jj log -r @- --no-graph --ignore-working-copy --color never -T 'commit_id'", in: root
    ).out.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(cid.isEmpty, "could not resolve the merge commit id")
    XCTAssertEqual(
      sh("jj log --no-graph --ignore-working-copy --color never -r \(cid) -T conflict", in: root)
        .out.trimmingCharacters(in: .whitespacesAndNewlines), "true",
      "fixture commit should be conflicted")

    // jj: the conflicted path, reported as such.
    let jj = try await RustJJProvider().changeset(root: url, commitID: cid)
    XCTAssertTrue(
      jj.files.contains { $0.path == "f.txt" && $0.kind == .conflicted },
      "jj should report f.txt as .conflicted; got \(jj.files.map { "\($0.kind):\($0.path)" })")

    // git: jj's sidecar trees, no conflict, no f.txt.
    let git = try await GitProvider().changeset(root: url, commitID: cid)
    let gitPaths = git.files.map(\.path)
    XCTAssertTrue(
      gitPaths.contains { $0.hasPrefix(".jjconflict-") },
      "git should see jj's conflict sidecar trees; got \(gitPaths)")
    XCTAssertFalse(
      git.files.contains { $0.kind == .conflicted },
      "a git commit-to-commit diff can never yield .conflicted; got \(gitPaths)")
    XCTAssertFalse(
      gitPaths.contains("f.txt"),
      "git doesn't see the conflicted path itself in this commit; got \(gitPaths)")
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

  /// A **merge** working copy must still produce real per-file diffs. `jj diff -r @` diffs a merge
  /// against its *auto-merged parents*, so it returns NOTHING for a file that differs only from the
  /// first parent — which is precisely what the Changes panel lists (`changed_files` diffs the first
  /// parent). Reported live: clicking a conflicted row opened a tab reading "No changes".
  ///
  /// Both halves are asserted because the bug is not conflict-specific:
  ///   - the conflicted file must render its conflict markers, and
  ///   - an ordinary file arriving from the OTHER side of the merge must render its content too.
  func testMergeWorkingCopyFileDiffsAreNotEmpty() async throws {
    try requireTool("jj")
    let root = try jjMergeFixture()
    let url = URL(fileURLWithPath: root)
    let jj = RustJJProvider()

    // The conflicted file: markers, not emptiness.
    let conflicted = try await jj.workingFileDiff(root: url, path: "f.txt", base: .workingCopy)
    XCTAssertFalse(conflicted.isEmpty, "a conflicted file must produce a diff, not nothing")
    XCTAssertTrue(
      conflicted.contains("<<<<<<<"), "the conflict markers should render; got \(conflicted)")

    // A file that exists only on the right side — no conflict, still invisible to `jj diff -r @`.
    let fromOtherSide = try await jj.workingFileDiff(
      root: url, path: "right.txt", base: .workingCopy)
    XCTAssertFalse(
      fromOtherSide.isEmpty, "a file from the merge's other side must produce a diff")
    XCTAssertTrue(
      fromOtherSide.contains("right only"), "its content should render; got \(fromOtherSide)")

    // And the first-parent id the diff anchors to is resolvable on a merge (where `@-` is ambiguous).
    let first = try await RustJJProvider.firstParentID(root: url)
    XCTAssertEqual(first?.count, 40, "a full commit id for @'s first parent; got \(first ?? "nil")")
  }

  /// The same first-parent anchoring must apply to a COMMITTED merge, which is what the History
  /// detail pane reads through `fileDiff`. Reported live: after the working-copy diff was fixed,
  /// opening the same conflicted file from its history row still rendered "No changes".
  ///
  /// Also covers the old-side content read (`commitParentFileContent`), which fed the deleted-line
  /// syntax highlighting the `<commitID>-` revset couldn't resolve on a merge.
  func testMergeCommitFileDiffIsNotEmpty() async throws {
    try requireTool("jj")
    let root = try jjMergeFixture()
    let url = URL(fileURLWithPath: root)
    let jj = RustJJProvider()

    // Commit the conflicted merge so it becomes a history entry, then read it back by id.
    let r = sh("jj commit -m 'merged with conflict' >/dev/null 2>&1; echo done", in: root)
    XCTAssertTrue(r.out.contains("done"), "committing the merge failed: \(r.out)")
    let cid = sh(
      "jj log -r @- --no-graph --ignore-working-copy --color never -T commit_id", in: root
    ).out.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(cid.isEmpty, "could not resolve the merge commit id")

    let conflicted = try await jj.fileDiff(root: url, commitID: cid, path: "f.txt")
    XCTAssertFalse(conflicted.isEmpty, "a conflicted file in a merge COMMIT must produce a diff")
    XCTAssertTrue(
      conflicted.contains("<<<<<<<"), "the conflict markers should render; got \(conflicted)")

    let fromOtherSide = try await jj.fileDiff(root: url, commitID: cid, path: "right.txt")
    XCTAssertFalse(fromOtherSide.isEmpty, "a file from the merge's other side must produce a diff")

    // The old side resolves too — `<commitID>-` would error on a merge, leaving deletions unhighlighted.
    let oldSide = try await jj.commitParentFileContent(root: url, commitID: cid, path: "f.txt")
    XCTAssertEqual(oldSide, "left\n", "the old side is the FIRST parent's content")

    // The header's +/- must describe the same diff as the file list: on the auto-merged-parents base
    // the conflicted file contributes nothing, so the counts disagreed with the rows beside them.
    let changeset = try await jj.changeset(root: url, commitID: cid)
    XCTAssertTrue(
      changeset.files.contains { $0.path == "f.txt" }, "the conflicted file is listed")
    let insertions = try XCTUnwrap(changeset.insertions, "the header should carry a line count")
    XCTAssertGreaterThan(
      insertions, 1, "the totals should include the conflicted file's lines; got \(insertions)")
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

  /// Renames, which `testColocatedChangesetFileListMatchesAcrossBackends`'s fixture has none of — so
  /// its set-equality guard passed while jj reported delete+add and git reported one rename row.
  ///
  /// **Working-copy** state, where both backends can pair: git needs the rename staged (libgit2's
  /// `.renamesIndex` — an unstaged `mv` is a delete + an untracked file, with nothing to pair), jj
  /// pairs it from the backend's copy records either way. Both must land on `.renamed` at the NEW
  /// path, carry the old one, and NOT also list the old path as a separate delete.
  func testColocatedWorkingCopyRenameMatchesAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedRenameFixture()
    let url = URL(fileURLWithPath: root)

    // git first: jj's status read snapshots `@`, which would rewrite the state git is describing.
    let git = try GitProvider().workingStatus(root: url)
    let gitRow = try XCTUnwrap(
      git.files.first { $0.path == "new.txt" },
      "git should report the renamed path; got \(git.files.map(\.id))")
    XCTAssertEqual(gitRow.change, .renamed, "git rename detection is on for status")
    XCTAssertEqual(gitRow.oldPath, "old.txt", "git carries the pre-move path")
    XCTAssertFalse(
      git.files.contains { $0.path == "old.txt" },
      "git pairs the delete into the rename row; got \(git.files.map(\.id))")

    let jj = try await RustJJProvider().workingStatus(root: url)
    let jjRow = try XCTUnwrap(
      (jj.changedFiles ?? []).first { $0.path == "new.txt" },
      "jj should report the renamed path; got \((jj.changedFiles ?? []).map(\.id))")
    XCTAssertEqual(jjRow.change, .renamed, "jj must not report a rename as a plain add")
    XCTAssertEqual(jjRow.oldPath, "old.txt", "jj carries the pre-move path")
    XCTAssertFalse(
      (jj.changedFiles ?? []).contains { $0.path == "old.txt" },
      "jj pairs the delete into the rename row; got \((jj.changedFiles ?? []).map(\.id))")
  }

  /// The **commit** (History) counterpart of the working-copy test above — the last rename divergence
  /// between the backends, and the reason `GitCommitDiff` exists: jj pairs renames natively, while a
  /// SwiftGitX `repo.diff(commit:)` is a plain tree-to-tree diff that no `git_diff_find_similar` ever
  /// touched, so git used to report delete + add here. git's own CLI defaults to `diff.renames=true`,
  /// so `git show` on this commit has always shown one rename row; this asserts our two backends now
  /// agree with it and with each other.
  ///
  /// The per-file diff text is checked too: a file list that says "renamed" while its diff renders a
  /// whole-file add is the half-fixed state, so both sides must carry `rename from` for the parser.
  func testColocatedCommitRenameMatchesAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedRenameFixture()
    let url = URL(fileURLWithPath: root)
    // Commit the staged rename so both backends can read it back by id.
    _ = sh("jj commit -m 'rename old.txt' >/dev/null 2>&1; echo done", in: root)
    let cid = sh(
      "jj log -r @- --no-graph --ignore-working-copy --color never -T 'commit_id'", in: root
    ).out.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(cid.isEmpty, "could not resolve the rename commit id")

    let jj = try await RustJJProvider().changeset(root: url, commitID: cid)
    XCTAssertEqual(
      Set(jj.files.map { "\($0.kind):\($0.path)" }), Set(["renamed:new.txt"]),
      "jj reports a committed rename as one row")
    XCTAssertEqual(jj.files.first?.oldPath, "old.txt")

    let git = try await GitProvider().changeset(root: url, commitID: cid)
    XCTAssertEqual(
      Set(git.files.map { "\($0.kind):\($0.path)" }), Set(["renamed:new.txt"]),
      "git must pair a committed rename too; got \(git.files)")
    XCTAssertEqual(git.files.first?.oldPath, "old.txt")

    for (name, text) in [
      ("git", try await GitProvider().fileDiff(root: url, commitID: cid, path: "new.txt")),
      ("jj", try await RustJJProvider().fileDiff(root: url, commitID: cid, path: "new.txt")),
    ] {
      XCTAssertEqual(
        UnifiedDiff.parse(text).renamedFrom, "old.txt",
        "\(name)'s per-file diff should name the pre-move path: \(text)")
    }
  }

  // MARK: - Fixture helpers (mirror WorkroomStatusIntegrationTests)

  /// Push state must mean the SAME thing in both backends. They compute it differently — git walks
  /// `HEAD --not refs/remotes/origin/*` in libgit2, jj evaluates `ancestors(<tracked @origin tips>)` in
  /// jj-lib — so this is the only test that catches them drifting apart (e.g. one silently widening to
  /// "any remote").
  ///
  /// A colocated `jj git push` exports `refs/remotes/origin/main` into the git repo, so both backends
  /// genuinely see the same tip. Only shas present in BOTH pages are compared: jj's page starts at the
  /// working-copy commit `@`, which git's HEAD (pointed at `@-`) never sees.
  func testColocatedPushStateMatchesAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedWithOriginFixture()
    let url = URL(fileURLWithPath: root)

    let jjPage = try RustJJProvider().log(root: url, limit: 20)
    let gitPage = try GitProvider().log(root: url, limit: 20)

    let jjStates = Dictionary(
      uniqueKeysWithValues: jjPage.commits.map { ($0.commitID, $0.pushState) })
    var compared = 0
    for row in gitPage.commits {
      guard let jjState = jjStates[row.commitID] else { continue }
      XCTAssertEqual(
        row.pushState, jjState,
        "backends disagree on \(row.summary) (\(row.commitID.prefix(8)))")
      compared += 1
    }
    XCTAssertGreaterThanOrEqual(compared, 2, "both a pushed and an unpushed commit were compared")

    // And both must have actually decided something — an all-`.unknown` page would make the equality
    // above vacuously true.
    XCTAssertTrue(gitPage.commits.contains { $0.pushState == .pushed })
    XCTAssertTrue(gitPage.commits.contains { $0.pushState == .unpushed })
    XCTAssertEqual(gitPage.pushScope?.refName, "origin/main")
    XCTAssertEqual(jjPage.pushScope?.refName, "origin/main")
  }

  /// A colocated jj+git repo with a bare `origin`: `first` is pushed to `origin/main`, `second` is
  /// local-only. Both backends read the same refs.
  private func colocatedWithOriginFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      git init -q --bare origin.git
      mkdir -p work && cd work
      jj git init --colocate . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      printf 'one\\n' > a.txt
      jj commit -m first >/dev/null 2>&1
      jj bookmark create main -r @- >/dev/null 2>&1
      jj git remote add origin ../origin.git >/dev/null 2>&1
      jj git push -b main >/dev/null 2>&1
      printf 'two\\n' > b.txt
      jj commit -m second >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "colocated+origin fixture setup failed: \(r.out)")
    return root + "/work"
  }

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

  /// A colocated jj+git repo with `old.txt` committed, then renamed to `new.txt` and **staged**
  /// (`git mv`). Staging is what lets libgit2's status pair the rename; jj pairs it from the git
  /// backend's copy records regardless. The body is 8 distinct lines so the two blobs are an exact
  /// match — gix and libgit2 both pair identical content outright, no similarity threshold involved.
  private func colocatedRenameFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      jj git init . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      printf 'one\\ntwo\\nthree\\nfour\\nfive\\nsix\\nseven\\neight\\n' > old.txt
      jj commit -m 'add old.txt' >/dev/null 2>&1
      git mv old.txt new.txt >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "rename fixture setup failed: \(r.out)")
    return root
  }

  /// A colocated jj+git repo whose `@-` is a **conflicted** 2-sided merge commit: `base` → (`left`,
  /// `right`) both change `f.txt`, `jj new <left> <right>` merges them into a conflict, and the merge
  /// is then committed so it can be read back by commit-id from both backends.
  ///
  /// The sides are addressed by **commit id**, not bookmark: this fixture inherits the developer's
  /// own `~/.config/jj`, and with `experimental-advance-branches` enabled `jj commit` advances a
  /// bookmark onto the new commit — which collapses the two sides onto one and yields no conflict.
  private func colocatedConflictFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      jj git init . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      id() { jj log -r @- --no-graph --ignore-working-copy --color never -T commit_id; }
      printf 'base\\n' > f.txt
      jj commit -m base >/dev/null 2>&1
      BASE=$(id)
      printf 'left\\n' > f.txt
      jj commit -m left >/dev/null 2>&1
      LEFT=$(id)
      jj new "$BASE" -m right >/dev/null 2>&1
      printf 'right\\n' > f.txt
      jj commit -m right >/dev/null 2>&1
      RIGHT=$(id)
      jj new "$LEFT" "$RIGHT" >/dev/null 2>&1
      jj commit -m 'merged with conflict' >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "colocated conflict fixture setup failed: \(r.out)")
    return root
  }

  /// A jj repo whose `@` is a 2-sided merge that is BOTH conflicted (`f.txt`, changed differently on
  /// each side) and carries a file present only on the right side (`right.txt`). Sides are addressed
  /// by commit id, not bookmark — `experimental-advance-branches` would otherwise advance a bookmark
  /// onto the new commit and collapse the two sides into one.
  private func jjMergeFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      jj git init . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      id() { jj log -r @- --no-graph --ignore-working-copy --color never -T commit_id; }
      printf 'base\\n' > f.txt
      jj commit -m base >/dev/null 2>&1
      BASE=$(id)
      printf 'left\\n' > f.txt
      jj commit -m left >/dev/null 2>&1
      LEFT=$(id)
      jj new "$BASE" -m right >/dev/null 2>&1
      printf 'right\\n' > f.txt
      printf 'right only\\n' > right.txt
      jj commit -m right >/dev/null 2>&1
      RIGHT=$(id)
      jj new "$LEFT" "$RIGHT" >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "jj merge fixture setup failed: \(r.out)")
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
