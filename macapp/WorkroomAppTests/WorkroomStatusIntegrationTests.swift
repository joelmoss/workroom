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
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, false)
    XCTAssertEqual(s.branchForCI, "main")
    XCTAssertNil(s.failure)
  }

  func testGitModifiedAndUntracked() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && echo new > untr.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertFalse(s.conflicted)
    let kinds = Set((s.changedFiles ?? []).map(\.change))
    XCTAssertTrue(kinds.contains(.modified))
    XCTAssertTrue(kinds.contains(.untracked))
  }

  func testGitStagedAdd() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo s > staged.txt && git add staged.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "staged.txt" && $0.change == .added })
  }

  func testGitCommittedIsClean() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && git commit -qam work", in: dir)  // commit locally, don't push
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, false)  // committed → working tree clean
  }

  func testGitRename() async throws {
    let dir = try gitRepoWithUpstream()
    sh("git mv a.txt renamed.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "renamed.txt" && $0.change == .renamed })
  }

  func testGitDetachedHead() async throws {
    let dir = try gitRepoWithUpstream()
    sh("git checkout -q \"$(git rev-parse HEAD)\"", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertNil(s.branchForCI)  // (detached) → no branch for CI
  }

  // MARK: GitProvider.workingStatus (SwiftGitX / libgit2 — the structured status read)

  func testGitProviderWorkingStatus() throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && echo new > untr.txt", in: dir)  // modify tracked + add untracked
    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertTrue(ws.dirty)
    XCTAssertFalse(ws.conflicted)
    XCTAssertEqual(ws.branch, "main")
    let byChange = Dictionary(grouping: ws.files, by: \.change).mapValues { $0.map(\.path) }
    XCTAssertEqual(byChange[.modified], ["a.txt"])
    XCTAssertEqual(byChange[.untracked], ["untr.txt"])
    // `git diff HEAD` counts the tracked modification (one added line); untracked is excluded.
    XCTAssertEqual(ws.insertions, 1)
    XCTAssertEqual(ws.deletions, 0)
  }

  func testGitProviderWorkingStatusClean() throws {
    let dir = try gitRepoWithUpstream()
    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertFalse(ws.dirty)
    XCTAssertTrue(ws.files.isEmpty)
    XCTAssertEqual(ws.branch, "main")
  }

  /// History rows carry branch/tag decoration on git, the way they carry bookmarks on jj: the tip
  /// commit gets its local branches + tags, the older commit gets none, and remote-tracking refs
  /// (`origin/main`, which points at the same tip here) are excluded so labels don't double up.
  func testGitProviderLogRefs() throws {
    let dir = try gitRepoWithUpstream()  // one commit on `main`, pushed to `origin/main`
    sh(
      """
      echo two >> a.txt && git commit -qam second
      git branch feat && git tag v1 && git tag -a v2 -m annotated
      """, in: dir)
    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    XCTAssertEqual(page.commits.count, 2)
    XCTAssertEqual(page.commits[0].summary, "second")
    XCTAssertEqual(page.commits[0].refs, ["feat", "main", "v1", "v2"])
    XCTAssertEqual(page.commits[1].refs, [])
  }

  // MARK: git push state
  //
  // `GitGraphTests` covers the reachability contract itself; these prove the PROVIDER wires it onto
  // every row of a real page, and that the tri-state reaches the model intact.

  /// The split: commits above `origin/main` are unpushed, the pushed base is pushed, and the page
  /// carries the comparison scope so the tooltip can name the branch.
  func testGitProviderLogPushStateSplitsAtOrigin() throws {
    let dir = try gitRepoWithUpstream()  // one commit on `main`, pushed to `origin/main`
    sh("echo two >> a.txt && git commit -qam second", in: dir)
    sh("echo three >> a.txt && git commit -qam third", in: dir)

    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    XCTAssertEqual(page.commits.map(\.summary), ["third", "second", "init"])
    XCTAssertEqual(page.commits[0].pushState, .unpushed)
    XCTAssertEqual(page.commits[1].pushState, .unpushed)
    XCTAssertEqual(page.commits[2].pushState, .pushed)
    XCTAssertEqual(page.pushScope?.refName, "origin/main")
    XCTAssertEqual(page.pushScope?.count, 1)
    // The badge shows for exactly the unpushed rows (git has no working-copy commit to suppress).
    XCTAssertEqual(page.commits.filter(\.showsUnpushedBadge).map(\.summary), ["third", "second"])
  }

  /// No origin ⇒ `.unknown` on every row, NOT `.unpushed`. A repo you never pushed anywhere shows no
  /// badges at all rather than badging its entire history.
  func testGitProviderLogPushStateUnknownWithoutOrigin() throws {
    try requireTool("git")
    let dir = tempDir()
    sh(
      """
      git init -q . && git config user.email a@b.c && git config user.name t \
        && echo one > a.txt && git add . && git commit -qm init
      """, in: dir)
    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    XCTAssertEqual(page.commits.map(\.pushState), [.unknown])
    XCTAssertNil(page.pushScope)
    XCTAssertTrue(page.commits.allSatisfy { !$0.showsUnpushedBadge })
  }

  /// Origin-scoped, not any-remote: a commit pushed only to `backup` is still unpushed.
  func testGitProviderLogPushStateIgnoresNonOriginRemotes() throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && git commit -qam second", in: dir)
    sh(
      """
      git init -q --bare ../backup.git && git remote add backup ../backup.git \
        && git push -q backup HEAD:refs/heads/main
      """, in: dir)

    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    XCTAssertEqual(page.commits[0].summary, "second")
    XCTAssertEqual(page.commits[0].pushState, .unpushed, "`backup` is not the project's remote")
    XCTAssertEqual(page.pushScope?.count, 1, "only origin's branch is in scope")
  }

  /// Reachability, not "at or below HEAD": a local tip behind what origin has is still pushed.
  func testGitProviderLogPushStateWhenBehindOrigin() throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && git commit -qam second && git push -q origin main", in: dir)
    sh("git reset -q --hard HEAD~1", in: dir)

    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    XCTAssertEqual(page.commits.map(\.pushState), [.pushed])
  }

  /// A merge of an unpushed side branch: the merge and the side commit are unpushed, the pushed base
  /// isn't. Guards a future "walk first-parent only" optimization, which would get this wrong.
  func testGitProviderLogPushStateAcrossAMerge() throws {
    let dir = try gitRepoWithUpstream()
    sh(
      """
      git checkout -q -b side && echo s > s.txt && git add . && git commit -qm sidework
      git checkout -q main && git merge -q --no-ff -m merged side
      """, in: dir)

    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    let bySummary = Dictionary(
      uniqueKeysWithValues: page.commits.map { ($0.summary, $0.pushState) })
    XCTAssertEqual(bySummary["merged"], .unpushed)
    XCTAssertEqual(bySummary["sidework"], .unpushed)
    XCTAssertEqual(bySummary["init"], .pushed)
  }

  /// Amending a pushed commit makes a NEW object, so the row reads unpushed even though "the same
  /// work" is on origin. Intended: the alternative (patch-id matching) would make the badge lie in the
  /// worse direction.
  func testGitProviderLogPushStateAfterAmend() throws {
    let dir = try gitRepoWithUpstream()
    sh("git commit -q --amend -m amended", in: dir)

    let page = try GitProvider().log(root: URL(fileURLWithPath: dir), limit: 10)
    XCTAssertEqual(page.commits[0].summary, "amended")
    XCTAssertEqual(page.commits[0].pushState, .unpushed)
  }

  /// The changeset path (the detail header) must agree with the row it was opened from — a badge that
  /// vanishes when you click the commit reads as a bug.
  func testGitProviderChangesetPushStateMatchesTheRow() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && git commit -qam second", in: dir)
    let provider = GitProvider()
    let page = try provider.log(root: URL(fileURLWithPath: dir), limit: 10)

    for row in page.commits {
      let cs = try await provider.changeset(
        root: URL(fileURLWithPath: dir), commitID: row.commitID)
      XCTAssertEqual(cs.commit.pushState, row.pushState, "\(row.summary) agrees")
      XCTAssertEqual(cs.pushScope?.refName, "origin/main")
    }
  }

  func testGitConflict() async throws {
    let dir = try gitRepoWithUpstream()
    sh(
      """
      git checkout -q -b feat && echo X > conf.txt && git add . && git commit -qm fx
      git checkout -q main && echo Y > conf.txt && git add . && git commit -qm mx
      git merge feat >/dev/null 2>&1 || true
      """, in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(s.conflicted)
    XCTAssertTrue((s.changedFiles ?? []).contains { $0.change == .conflicted })
  }

  func testGitNotARepoIsUnknownNotClean() async throws {
    try requireTool("git")
    let dir = tempDir()  // a plain empty directory, not a git repo
    let s = await resolver.resolveLocal(path: dir, vcs: "git", projectRoot: dir)
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
    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(s.dirty, false)
    XCTAssertFalse(s.conflicted)
    XCTAssertNil(s.failure)
  }

  func testJJDirtyWithFiles() async throws {
    let dir = try jjRepo()
    sh("echo hello > f1.txt && echo world > f2.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertEqual((s.changedFiles ?? []).count, 2)
    XCTAssertTrue((s.changedFiles ?? []).allSatisfy { $0.change == .added })
  }

  func testJJModifyAndDelete() async throws {
    let dir = try jjRepo()
    sh("echo a > f1.txt && echo b > f2.txt && jj commit -m base 2>/dev/null", in: dir)
    sh("echo changed > f1.txt && rm f2.txt", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    let kinds = Set((s.changedFiles ?? []).map(\.change))
    XCTAssertTrue(kinds.contains(.modified))
    XCTAssertTrue(kinds.contains(.deleted))
  }

  /// The jj twin of `testGitConflict`: a conflicted jj working copy must report the conflict
  /// **per file**, not as a plain modification. jj stores conflicts in the tree, so this rides the
  /// whole native path the cargo test can't reach — `jj_backend::changed_files` → UniFFI →
  /// `RustJJProvider.statusChange` → `WorkroomStatus.changedFiles`, which is what the Changes panel
  /// renders. A mapping regression anywhere in that chain shows up here and nowhere else.
  ///
  /// `jj new <left> <right>` makes `@` a 2-sided merge of two commits that changed `f.txt`
  /// differently, which is jj's ordinary way to end up with a conflicted working copy.
  ///
  /// The two sides are addressed by **commit id**, never by bookmark: these fixtures inherit the
  /// developer's own `~/.config/jj` (only `user.name`/`user.email` are set per-repo), and with
  /// `experimental-advance-branches` enabled a `jj commit` silently advances a bookmark onto the new
  /// commit — which collapsed `jj new base` onto `left` and produced no conflict at all.
  func testJJConflict() async throws {
    let dir = try jjRepo()
    sh(
      """
      id() { jj log -r @- --no-graph --ignore-working-copy --color never -T commit_id; }
      echo base > f.txt && jj commit -m base 2>/dev/null
      BASE=$(id)
      echo left > f.txt && jj commit -m left 2>/dev/null
      LEFT=$(id)
      jj new "$BASE" -m right 2>/dev/null
      echo right > f.txt && jj commit -m right 2>/dev/null
      RIGHT=$(id)
      jj new "$LEFT" "$RIGHT" 2>/dev/null
      """, in: dir)
    // Guard the fixture itself: if jj doesn't consider `@` conflicted, a failure below is the
    // fixture's fault, not the resolver's.
    XCTAssertEqual(
      sh("jj log --no-graph --ignore-working-copy --color never -r @ -T conflict", in: dir).out
        .trimmingCharacters(in: .whitespacesAndNewlines), "true",
      "fixture should produce a conflicted @")

    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(s.conflicted)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "f.txt" && $0.change == .conflicted },
      "f.txt should be .conflicted, not .modified; got \(s.changedFiles ?? [])")
  }

  /// The Changes header's `+N −M` must describe the SAME diff as the rows beside it, on a **merge** `@`
  /// — end to end through the native read (`changed_files`' per-file counts → UniFFI →
  /// `RustJJProvider.workingStatus` → `WorkroomStatus.insertions`).
  ///
  /// `@` is a clean 2-sided merge: `left` edited `a.txt`, `right` added a 3-line `right.txt`. The file
  /// list is a tree diff against the FIRST parent, so `right.txt` is listed. The totals used to come
  /// from a separate `jj diff -r @ --stat` process, and `-r @` on a merge diffs the *auto-merged
  /// parents* — empty here — so the panel showed a listed 3-line file with no line delta at all. This
  /// asserts both halves: our count, and that the old read really does report nothing.
  ///
  /// Sides are addressed by **commit id**, never by bookmark: with `experimental-advance-branches`
  /// enabled (as in the author's own config) `jj commit` advances a bookmark onto the new commit, which
  /// collapses the two sides and leaves no merge to test.
  func testJJMergeWorkingCopyCountsMatchTheFileList() async throws {
    let dir = try jjRepo()
    sh(
      """
      id() { jj log -r @- --no-graph --ignore-working-copy --color never -T commit_id; }
      printf 'one\\ntwo\\n' > a.txt && jj commit -m base 2>/dev/null
      BASE=$(id)
      printf 'ONE\\ntwo\\n' > a.txt && jj commit -m left 2>/dev/null
      LEFT=$(id)
      jj new "$BASE" -m right 2>/dev/null
      printf 'r1\\nr2\\nr3\\n' > right.txt && jj commit -m right 2>/dev/null
      RIGHT=$(id)
      jj new "$LEFT" "$RIGHT" 2>/dev/null
      """, in: dir)
    // Guard the fixture: without a real merge `@` this test cannot fail, since the two diff bases
    // coincide on a single-parent commit.
    XCTAssertEqual(
      sh("jj log --no-graph --ignore-working-copy --color never -r @ -T 'parents.len()'", in: dir)
        .out
        .trimmingCharacters(in: .whitespacesAndNewlines), "2",
      "fixture should produce a 2-parent @")

    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "right.txt" },
      "the file arriving from the merge's other side is listed; got \(s.changedFiles ?? [])")
    XCTAssertEqual(s.insertions, 3, "…so its three lines must be in the header's total")
    XCTAssertEqual(s.deletions, 0)

    // The read this replaced, still reproducible through the CLI: against the auto-merged parents this
    // merge changed NOTHING, so the header used to show no delta beside a listed 3-line file. (jj still
    // prints its summary line at zero — "0 files changed, 0 insertions(+), 0 deletions(-)" — so match
    // the file count, not the presence of the word "insertions".)
    let stale = sh("jj diff -r @ --ignore-working-copy --stat --color never", in: dir).out
    XCTAssertTrue(
      stale.contains("0 files changed"),
      "`-r @` on a merge is the wrong base this fixed — if it now reports files, re-derive this test; got \(stale)"
    )
  }

  /// A jj command the user runs in a workroom terminal holds the working-copy lock, and the status
  /// sweep must report that as a distinct, self-explaining state — end to end: `jj_backend`'s
  /// non-blocking lock probe → `VcsError::LockContention` → UniFFI → `RustJJProvider.mapError` →
  /// `WorkroomStatusResolver.failure(for:)` → the row's `.busy` badge. Nothing else in the suite
  /// covers that chain, and the failure mode without the probe is the worst kind: jj-lib's `flock`
  /// blocks with no timeout, so the row would sit on the sweep's 15s ceiling and report `.timeout`
  /// while pinning the project's snapshot gate.
  ///
  /// The lock is taken the way another process takes it — `flock(2)` on jj's own lock file — since
  /// `flock` is per open file description, so this really does contend with the probe's `try_lock`.
  func testJJLockContentionReportsBusy() async throws {
    let dir = try jjRepo()
    sh("echo a > f.txt", in: dir)
    // Baseline: a snapshot succeeds while nothing holds the lock, so `.busy` below can only be the lock.
    let before = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(before.dirty, true)
    XCTAssertNil(before.failure)

    let lockPath = (dir as NSString).appendingPathComponent(".jj/working_copy/working_copy.lock")
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    try XCTSkipIf(fd < 0, "could not open jj's working-copy lock file at \(lockPath)")
    XCTAssertEqual(flock(fd, LOCK_EX), 0, "hold the working-copy lock")

    let busy = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(
      busy.failure, .busy, "a held working-copy lock reads as busy, not timeout/notRepo")
    XCTAssertNil(busy.dirty)  // unknown, never clean

    flock(fd, LOCK_UN)
    close(fd)

    // And it recovers: the probe must not have disturbed the repo or the lock file it touched.
    let after = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    XCTAssertEqual(after.dirty, true)
    XCTAssertNil(after.failure)
  }

  /// Proves the real jj head template + parse produce the description + bookmark for the Changes
  /// header (the jj "branch name" equivalent).
  func testJJHeadDescriptionAndBookmark() async throws {
    let dir = try jjRepo()
    sh("echo a > f.txt", in: dir)
    sh("jj describe -m 'my change (#9)' 2>/dev/null", in: dir)
    sh("jj bookmark create mybook -r @ 2>/dev/null", in: dir)
    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    let wc = s.jjWorkingCopy
    XCTAssertEqual(wc?.description, "my change (#9)")
    XCTAssertEqual(wc?.refs, ["mybook"])
    XCTAssertNotNil(wc?.changeID)  // real jj always yields a change-id + commit-id for @
    XCTAssertNotNil(wc?.commitID)
    // The change-id is its shortest unique prefix, unpadded (a one-commit repo → a 1-char prefix).
    XCTAssertFalse((wc?.changeID ?? "").isEmpty)
    XCTAssertEqual((wc?.commitID ?? "").count, 8)  // commit-id is jj's shortest-8 id
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
    let s = await resolver.resolveLocal(path: dir, vcs: "jj", projectRoot: dir)
    // git symbolic-ref would fail here (detached HEAD); the revset finds the nearest bookmark.
    XCTAssertEqual(s.branchForCI, "feature/login")
  }

  /// A primary `main` jj workspace + a secondary `ws` workspace (`jj workspace add`) sharing one
  /// backing repo — the fixture shape for both `testJJWorkspaceResolvesAsJJ` and
  /// `testConcurrentJJSnapshotsAcrossWorkspacesOfOneProjectDoNotRace`. Returns their paths;
  /// `extraSetup` runs (in `main`) after `describe` but before `workspace add`, for a test that
  /// needs e.g. a bookmark.
  private func makeJJWorkspaceFixture(extraSetup: String = "") throws -> (main: String, ws: String)
  {
    try requireTool("jj")
    let root = tempDir()
    sh(
      """
      mkdir -p main && cd main
      jj git init . 2>/dev/null || jj init --git . 2>/dev/null
      jj config set --repo user.email a@b.c; jj config set --repo user.name t
      echo hello > f.txt && jj describe -m base 2>/dev/null
      \(extraSetup)
      jj workspace add ../ws --name workroom/ws 2>/dev/null
      """, in: root)
    return (main: root + "/main", ws: root + "/ws")
  }

  /// The reported bug: a jj *workroom* is a `jj workspace add` workspace, not the main repo — and
  /// (unlike the colocated main repo) a secondary workspace has no `.git`. It must be resolved as
  /// "jj" (the project's VCS type), NOT by the workroom's `vcs_name` (`workroom/<name>`), which
  /// made resolveLocal fall through to `.notRepository` and the header render the git "detached"
  /// fallback. Proves a real workspace path reports its dirty state, the jj head, and the ancestor
  /// bookmark — i.e. the Changes panel shows the jj line, not "not a repository" / "detached".
  func testJJWorkspaceResolvesAsJJ() async throws {
    let (main, ws) = try makeJJWorkspaceFixture(
      extraSetup: "jj bookmark create feature/login -r @ 2>/dev/null\njj new 2>/dev/null")
    sh("echo dirty >> f.txt", in: ws)
    // `projectRoot` is the primary workspace's path (the parent project), NOT `ws` itself — same
    // convention as `StatusWorkItem.projectRoot` for a workroom.
    let s = await resolver.resolveLocal(path: ws, vcs: "jj", projectRoot: main)
    XCTAssertNil(s.failure)  // NOT .notRepository
    XCTAssertEqual(s.dirty, true)
    XCTAssertEqual(s.branchForCI, "feature/login")  // ancestor bookmark via the jj revset
    XCTAssertNotNil(s.jjWorkingCopy?.changeID)  // jj head populated → Changes shows the jj line
  }

  /// Regression for the VCS-foundation eng-review: two of a project's jj workspaces (the primary
  /// `main` and a secondary `ws`) share one backing repo, so concurrent `resolveLocal` snapshots
  /// used to be free to race on it (observed live as a `packed-refs.lock could not be obtained`
  /// error). With `JJSnapshotGate` serializing same-`projectRoot` snapshots, both concurrent probes
  /// must still resolve cleanly instead of racing. Uses an isolated gate (not `.shared`) so this
  /// test can't be affected by/affect any other test.
  func testConcurrentJJSnapshotsAcrossWorkspacesOfOneProjectDoNotRace() async throws {
    let (main, ws) = try makeJJWorkspaceFixture()
    let gatedResolver = WorkroomStatusResolver(gate: JJSnapshotGate())
    async let mainStatus = gatedResolver.resolveLocal(path: main, vcs: "jj", projectRoot: main)
    async let wsStatus = gatedResolver.resolveLocal(path: ws, vcs: "jj", projectRoot: main)
    let (m, w) = await (mainStatus, wsStatus)
    XCTAssertNil(m.failure, "main workspace snapshot must not fail under concurrent contention")
    XCTAssertNil(
      w.failure, "secondary workspace snapshot must not fail under concurrent contention")
  }
}
