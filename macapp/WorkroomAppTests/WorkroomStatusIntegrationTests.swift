import XCTest

@testable import Workroom

/// Integration tests that exercise `WorkroomStatusResolver` against REAL git repos through the
/// REAL `StatusCommandRunner` (no mock). These prove the status reads match what the actual
/// binaries emit (git 2.54 verified) — the unit tests only cover hand-written fixtures.
///
/// They **require** real `git` (CI installs it — see `.github/workflows/ci.yml`); a
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

  private func registeredStatus(path: String, vcs: String, projectRoot: String) async
    -> WorkroomStatus
  {
    do {
      let location = try await RepositoryLocation.local(path)
      let shared = try await RepositoryLocation.local(projectRoot)
      let router = RepositoryRouter()
      try router.register(
        .init(location: location, sharedLocation: shared))
      return await resolver.resolve(location: location, router: router)
    } catch {
      XCTFail("\(error)")
      return WorkroomStatus(dirty: nil, failure: .unavailable)
    }
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
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, false)
    XCTAssertEqual(s.branchForCI, "main")
    XCTAssertNil(s.failure)
  }

  func testGitModifiedAndUntracked() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && echo new > untr.txt", in: dir)
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertFalse(s.conflicted)
    let kinds = Set((s.changedFiles ?? []).map(\.change))
    XCTAssertTrue(kinds.contains(.modified))
    XCTAssertTrue(kinds.contains(.untracked))
  }

  func testGitStagedAdd() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo s > staged.txt && git add staged.txt", in: dir)
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "staged.txt" && $0.change == .added })
  }

  func testGitCommittedIsClean() async throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && git commit -qam work", in: dir)  // commit locally, don't push
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, false)  // committed → working tree clean
  }

  func testGitRename() async throws {
    let dir = try gitRepoWithUpstream()
    sh("git mv a.txt renamed.txt", in: dir)
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(
      (s.changedFiles ?? []).contains { $0.path == "renamed.txt" && $0.change == .renamed })
  }

  func testGitDetachedHead() async throws {
    let dir = try gitRepoWithUpstream()
    sh("git checkout -q \"$(git rev-parse HEAD)\"", in: dir)
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertNil(s.branchForCI)  // (detached) → no branch for CI
  }

  // MARK: GitProvider.workingStatus (SwiftGitX / libgit2 — the structured status read)

  func testGitProviderWorkingStatus() throws {
    let dir = try gitRepoWithUpstream()
    sh("echo two >> a.txt && echo new > untr.txt", in: dir)  // modify tracked + add untracked
    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertEqual(ws.dirty, true)
    XCTAssertFalse(ws.conflicted)
    XCTAssertEqual(ws.branchForCI, "main")
    let byChange = Dictionary(grouping: ws.changedFiles ?? [], by: \.change).mapValues {
      $0.map(\.path)
    }
    XCTAssertEqual(byChange[.modified], ["a.txt"])
    XCTAssertEqual(byChange[.untracked], ["untr.txt"])
    // `git diff HEAD` counts the tracked modification (one added line); untracked is excluded.
    XCTAssertEqual(ws.insertions, 1)
    XCTAssertEqual(ws.deletions, 0)
  }

  func testGitProviderWorkingStatusClean() throws {
    let dir = try gitRepoWithUpstream()
    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertEqual(ws.dirty, false)
    XCTAssertTrue((ws.changedFiles ?? []).isEmpty)
    XCTAssertEqual(ws.branchForCI, "main")
    // A clean tree is a real `(0, 0)` read, NOT an unanswerable `nil` — `nil` is reserved for a failed
    // read, and the badge presentation distinguishes them.
    XCTAssertEqual(ws.insertions, 0)
    XCTAssertEqual(ws.deletions, 0)
  }

  /// The working counts must match `git diff --shortstat` on the one case where a hand-rolled sum over
  /// SwiftGitX's hunk lines does NOT: a change to a file's trailing newline. libgit2 emits an EOFNL
  /// marker line (`\ No newline at end of file`) alongside the real deletion, and the old code counted
  /// it as a second deletion. git counts one, and so does `GitDiffStats` (via `git_diff_get_stats`).
  func testGitProviderWorkingStatusIgnoresEOFNLMarkers() throws {
    let dir = try gitRepoWithUpstream()
    // Commit b.txt with NO trailing newline, then add ONLY that newline.
    sh("printf 'one\\ntwo' > b.txt && git add b.txt && git commit -qm b", in: dir)
    sh("printf 'one\\ntwo\\n' > b.txt", in: dir)

    // Anchor the expectation to git itself rather than to this test's arithmetic.
    let numstat = sh("git diff --numstat", in: dir).out.trimmingCharacters(
      in: .whitespacesAndNewlines)
    XCTAssertEqual(numstat, "1\t1\tb.txt", "git's own count for a trailing-newline-only change")

    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertEqual(ws.insertions, 1, "the EOFNL marker must not count as an insertion")
    XCTAssertEqual(ws.deletions, 1, "the EOFNL marker must not count as a deletion")
  }

  /// A staged pure rename costs ZERO lines. The two halves of `workingStatus` are built from separate
  /// diffs — the file list from libgit2's status (which pairs renames) and the counts from
  /// `GitDiffStats` — so until the stat diff ran `git_diff_find_similar` too, a moved file was a
  /// delete plus an add there and its whole content landed in the badge: one row reading "renamed"
  /// beside `+8 −8`. git says nothing changed, and the expectation is anchored to git, not to this
  /// test's arithmetic.
  func testGitProviderWorkingStatusPairsStagedRenames() throws {
    let dir = try gitRepoWithUpstream()
    // Committed first so the rename is HEAD→worktree; 8 lines is plenty for the 50% similarity
    // default to measure, and `git mv` alone edits nothing.
    sh(
      """
      printf '1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n' > big.txt
      git add big.txt && git commit -qm big
      git mv big.txt moved.txt
      """, in: dir)

    let numstat = sh("git diff HEAD --numstat", in: dir).out.trimmingCharacters(
      in: .whitespacesAndNewlines)
    XCTAssertEqual(
      numstat, "0\t0\tbig.txt => moved.txt", "git pairs the rename and counts no lines for it")

    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertEqual(
      (ws.changedFiles ?? []).map(\.change), [.renamed],
      "the file list pairs it: \(ws.changedFiles ?? [])")
    XCTAssertEqual(ws.insertions, 0, "a rename inserts nothing")
    XCTAssertEqual(ws.deletions, 0, "a rename deletes nothing")
  }

  /// The same EOFNL rule on the changeset (commit) path, which reads its counts through
  /// `GitCommitDiff` — the same `git_diff_get_stats` call, on the commit's rename-detected diff. No
  /// `+N −M` in the app is summed off SwiftGitX hunk lines any more; this pins that down against
  /// `git show --numstat`.
  func testGitProviderChangesetIgnoresEOFNLMarkers() async throws {
    let dir = try gitRepoWithUpstream()
    sh("printf 'one\\ntwo' > b.txt && git add b.txt && git commit -qm b", in: dir)
    sh("printf 'one\\ntwo\\n' > b.txt && git commit -qam newline", in: dir)
    let sha = sh("git rev-parse HEAD", in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)

    let numstat = sh("git show --numstat --format= HEAD", in: dir).out
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(numstat, "1\t1\tb.txt", "git's own count for the committed newline change")

    let cs = try await GitProvider().changeset(root: URL(fileURLWithPath: dir), commitID: sha)
    XCTAssertEqual(cs.insertions, 1)
    XCTAssertEqual(cs.deletions, 1)
  }

  /// A repo with no commits yet: there is no HEAD tree to diff against, so the counts come from the
  /// empty tree and a staged file reads as insertions. git has no comparison to offer here — `git diff
  /// HEAD` is fatal without a HEAD — but the badge must not go blank or throw on a fresh project.
  func testGitProviderWorkingStatusUnbornHEAD() throws {
    try requireTool("git")
    let dir = tempDir()
    sh("git init -q . && git config user.email a@b.c && git config user.name t", in: dir)
    sh("printf 'one\\ntwo\\n' > a.txt && git add a.txt", in: dir)

    let ws = try GitProvider().workingStatus(root: URL(fileURLWithPath: dir))
    XCTAssertEqual(ws.dirty, true)
    XCTAssertNil(ws.branchForCI, "an unborn branch has no commit for CI to look up")
    XCTAssertEqual(ws.insertions, 2, "both staged lines count against the empty tree")
    XCTAssertEqual(ws.deletions, 0)
  }

  /// History rows carry branch/tag decoration: the tip
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
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(s.conflicted)
    XCTAssertTrue((s.changedFiles ?? []).contains { $0.change == .conflicted })
  }

  func testGitNotARepoIsUnknownNotClean() async throws {
    try requireTool("git")
    let dir = tempDir()  // a plain empty directory, not a git repo
    let s = await registeredStatus(path: dir, vcs: "git", projectRoot: dir)
    XCTAssertNil(s.dirty)  // unknown, NOT clean
    XCTAssertEqual(s.failure, .notRepository)
  }
}
