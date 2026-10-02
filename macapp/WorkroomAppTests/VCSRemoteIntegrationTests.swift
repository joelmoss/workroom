import XCTest

@testable import Workroom

/// `CLIVCSWriter` against REAL git repos through the REAL `StatusCommandRunner`.
///
/// **No network.** Every "remote" is a bare repo on disk reached over `file://`, so fetch, push and
/// pull are genuine end-to-end operations with no credentials, no rate limits and no flakiness. Every
/// repo is a throwaway under `NSTemporaryDirectory()`, removed in `tearDown` — these never touch a
/// developer's own repositories.
///
/// Two tests here exist specifically to pin bugs that shipped in the design and were caught in review:
/// - `testCountsAreIdenticalUnderEveryPushDefault` — the original design read ahead/behind from
///   `%(push:track)`, which is EMPTY for a branch with no upstream under git's default
///   `push.default=simple`, i.e. for every `git worktree add -b` workroom.
/// - `testFetchAtTheRootMovesAWorkroomsLastFetchLabel` — `FETCH_HEAD` is per-worktree, so fetching at
///   the project root never writes the workroom's copy; reading the wrong one meant "never fetched"
///   forever.
final class VCSRemoteIntegrationTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: helpers

  private func tool(_ name: String) -> Bool {
    sh("command -v \(name)", in: NSTemporaryDirectory()).exit == 0
  }

  private struct MissingTool: Error { let name: String }
  private func requireTool(_ name: String) throws {
    if !tool(name) {
      XCTFail("`\(name)` is required for integration tests; CI installs it (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-remote-\(UUID().uuidString)"
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
    // Isolate from the developer's own git config — including `push.default`, which is exactly what
    // one of these tests is about.
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["GIT_AUTHOR_NAME"] = "T"
    env["GIT_AUTHOR_EMAIL"] = "t@e.com"
    env["GIT_COMMITTER_NAME"] = "T"
    env["GIT_COMMITTER_EMAIL"] = "t@e.com"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
  }

  private func writer() -> CLIVCSWriter {
    CLIVCSWriter(
      runner: StatusCommandRunner(), makeProvider: { _ in GitProvider() },
      gate: RepositoryWriteGate(maxChainWait: 5))
  }

  /// A git project with a `file://` origin and `commitsAhead` unpushed commits.
  ///
  /// The branch name is DISCOVERED, never assumed. `init.defaultBranch` differs between machines and CI
  /// (and survives `GIT_CONFIG_GLOBAL=/dev/null` on this host), so hardcoding `master` created a repo on
  /// `main` whose remote branch was `master` — a local branch with no counterpart. Every count then
  /// correctly came back "no counterpart", which looked like a bug in the writer and wasn't.
  private func gitFixture(commitsAhead: Int = 0) -> (
    root: String, project: String, branch: String
  ) {
    let root = tempDir()
    sh("git init -q --bare origin.git", in: root)
    sh("git init -q app", in: root)
    let project = root + "/app"
    sh("git commit -q --allow-empty -m initial", in: project)
    let branch = sh("git branch --show-current", in: project).out
      .trimmingCharacters(in: .whitespacesAndNewlines)
    sh("git remote add origin ../origin.git", in: project)
    sh("git push -q -u origin HEAD:refs/heads/\(branch)", in: project)
    for i in 0..<commitsAhead {
      sh(
        "echo 'line \(i)' >> notes.md && git add notes.md && git commit -q -m 'change \(i)'",
        in: project)
    }
    sh("git fetch -q origin", in: project)
    return (root, project, branch)
  }

  private struct Unresolved: Error {}

  /// **Fails, never skips.** This helper is the funnel every assertion in the file goes through, and it
  /// used to `throw XCTSkip` when the resolution wasn't `.state`. A regression that made every repo
  /// resolve `.failed`/`.keepPrior`/`.absent` — a broken arg builder, an over-eager `classify` rule, an
  /// unparseable template — would then have reported ~20 tests as SKIPPED and left the gate green.
  /// `requireTool` already `XCTFail`s, so skipping here also disagreed with the file's own policy.
  private func state(_ w: CLIVCSWriter, path: String, projectRoot: String) async throws
    -> VCSRemoteState
  {
    let resolution = await w.remoteState(path: path, projectRoot: projectRoot)
    guard case .state(let s) = resolution else {
      XCTFail("expected a resolved state, got \(resolution)")
      throw Unresolved()
    }
    return s
  }

  // MARK: - git: counts

  /// **The regression test for the design's biggest bug.** `%(push:track)` resolves to nothing for a
  /// branch with no upstream under `push.default=simple` — git's built-in default — so counts derived
  /// from it were blank on any machine not set to `current`. An explicit `rev-list` is config-independent,
  /// and this asserts exactly that across every `push.default` value.
  func testCountsAreIdenticalUnderEveryPushDefault() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 5)
    let w = writer()
    for pushDefault in ["simple", "current", "upstream", "nothing", "matching"] {
      sh("git config push.default \(pushDefault)", in: f.project)
      let s = try await state(w, path: f.project, projectRoot: f.project)
      XCTAssertEqual(
        s.tracking?.ahead, 5, "ahead must not depend on push.default (\(pushDefault))")
      XCTAssertEqual(s.tracking?.behind, 0, "behind under push.default=\(pushDefault)")
    }
  }

  func testBehindIsCountedAfterTheRemoteMovesOn() async throws {
    try requireTool("git")
    let f = gitFixture()
    // A second clone pushes, so origin advances past us.
    sh("git clone -q origin.git other", in: f.root)
    sh(
      "git commit -q --allow-empty -m remote-side && git push -q origin HEAD:\(f.branch)",
      in: f.root + "/other")
    sh("git fetch -q origin", in: f.project)
    let s = try await state(writer(), path: f.project, projectRoot: f.project)
    XCTAssertEqual(s.tracking?.behind, 1)
    XCTAssertEqual(s.tracking?.ahead, 0)
  }

  func testDivergedCountsBothDirections() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 2)
    sh("git clone -q origin.git other", in: f.root)
    sh(
      "git commit -q --allow-empty -m remote-side && git push -q origin HEAD:\(f.branch)",
      in: f.root + "/other")
    sh("git fetch -q origin", in: f.project)
    let s = try await state(writer(), path: f.project, projectRoot: f.project)
    XCTAssertEqual(s.tracking?.ahead, 2)
    XCTAssertEqual(s.tracking?.behind, 1)
  }

  /// A workroom is `git worktree add -b` with NO upstream and no counterpart on the remote. This is the
  /// product's default state, and it must read as "publish", not as an error or a phantom count.
  func testFreshWorkroomHasNoCounterpartAndIsMarkedGone() async throws {
    try requireTool("git")
    let f = gitFixture()
    sh("git worktree add -q -b workroom/coral ../coral", in: f.project)
    let workroom = f.root + "/coral"
    let s = try await state(writer(), path: workroom, projectRoot: f.project)
    XCTAssertEqual(s.current.name, "workroom/coral")
    XCTAssertEqual(s.tracking?.gone, true, "no counterpart on the remote yet")
    XCTAssertNil(s.tracking?.ahead, "a missing counterpart can't be counted against")
  }

  func testRemoteRefsAndPrimaryRemoteAreResolved() async throws {
    try requireTool("git")
    let f = gitFixture()
    let s = try await state(writer(), path: f.project, projectRoot: f.project)
    XCTAssertEqual(s.remotes, ["origin"])
    XCTAssertEqual(s.primaryRemote, "origin")
  }

  /// git's half of the same bug: `git remote add` writes config and no `refs/remotes/*`, so a
  /// ref-derived remotes list reads as "No remote configured" on a repo that can publish.
  func testGitRemoteAddedButNeverFetchedIsStillARemote() async throws {
    try requireTool("git")
    let root = tempDir()
    sh("git init -q --bare origin.git", in: root)
    sh("git init -q app", in: root)
    let project = root + "/app"
    sh("git commit -q --allow-empty -m initial", in: project)
    sh("git remote add origin ../origin.git", in: project)
    XCTAssertTrue(
      sh("git for-each-ref refs/remotes", in: project).out.isEmpty,
      "precondition: no remote-tracking ref exists yet")

    let s = try await state(writer(), path: project, projectRoot: project)
    XCTAssertEqual(s.remotes, ["origin"])
    XCTAssertEqual(s.primaryRemote, "origin")
    XCTAssertEqual(s.tracking?.gone, true, "no counterpart yet — this is the Publish state")
  }

  /// `refs/remotes/origin/HEAD` is a symref whose short name is the bare remote — without dropping it,
  /// `origin` looks like a branch. Real repos DO have it (verified), so this is not hypothetical.
  func testOriginHeadSymrefIsNotMistakenForABranch() async throws {
    try requireTool("git")
    let f = gitFixture()
    sh("git remote set-head origin master", in: f.project)
    let s = try await state(writer(), path: f.project, projectRoot: f.project)
    XCTAssertEqual(s.remotes, ["origin"], "the symref must not add a phantom remote or branch")
  }

  // MARK: - git: last fetch

  /// **The regression test for the second design bug.** Fetch runs at the project root so every
  /// workroom shares one answer — but `FETCH_HEAD` is per-worktree, so the workroom must read the
  /// COMMON git dir. Reading its own would report "never fetched" forever.
  func testFetchAtTheRootMovesAWorkroomsLastFetchLabel() async throws {
    try requireTool("git")
    let f = gitFixture()
    sh("git worktree add -q -b workroom/coral ../coral", in: f.project)
    let workroom = f.root + "/coral"
    let w = writer()

    // The workroom has never fetched in its own right.
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.project + "/.git/worktrees/coral/FETCH_HEAD"),
      "precondition: the per-worktree FETCH_HEAD does not exist")

    let result = await w.fetch(path: workroom, projectRoot: f.project, remote: "origin")
    guard case .ok = result else { return XCTFail("fetch failed: \(result)") }

    let s = try await state(w, path: workroom, projectRoot: f.project)
    guard case .at = s.lastFetch else {
      return XCTFail("the workroom must see the root's fetch, got \(s.lastFetch)")
    }
  }

  func testNeverFetchedRepoReportsNever() async throws {
    try requireTool("git")
    let root = tempDir()
    sh("git init -q solo", in: root)
    let project = root + "/solo"
    sh("git commit -q --allow-empty -m initial", in: project)
    let s = try await state(writer(), path: project, projectRoot: project)
    XCTAssertEqual(s.lastFetch, .never, "clone/init never write FETCH_HEAD")
    XCTAssertNil(s.primaryRemote, "no remote configured")
  }

  // MARK: - git: actions

  func testPushMovesTheRemoteRefAndClearsAhead() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 3)
    let w = writer()
    let before = try await state(w, path: f.project, projectRoot: f.project)
    XCTAssertEqual(before.tracking?.ahead, 3)

    let result = await w.push(
      path: f.project, projectRoot: f.project, current: before.current, remote: "origin",
      setUpstream: false)
    guard case .ok = result else { return XCTFail("push failed: \(result)") }

    let after = try await state(w, path: f.project, projectRoot: f.project)
    XCTAssertEqual(after.tracking?.ahead, 0)
  }

  /// Publishing a fresh workroom: no counterpart, so the push both creates it and sets tracking.
  func testPublishingAWorkroomCreatesItsCounterpart() async throws {
    try requireTool("git")
    let f = gitFixture()
    sh("git worktree add -q -b workroom/coral ../coral", in: f.project)
    let workroom = f.root + "/coral"
    sh("echo hi > a.txt && git add a.txt && git commit -q -m 'work'", in: workroom)
    let w = writer()
    let before = try await state(w, path: workroom, projectRoot: f.project)
    XCTAssertEqual(before.tracking?.gone, true)

    let result = await w.push(
      path: workroom, projectRoot: f.project, current: before.current, remote: "origin",
      setUpstream: true)
    guard case .ok = result else { return XCTFail("publish failed: \(result)") }

    sh("git fetch -q origin", in: f.project)
    let after = try await state(w, path: workroom, projectRoot: f.project)
    XCTAssertEqual(after.tracking?.gone, false, "the counterpart now exists")
    XCTAssertEqual(after.tracking?.ahead, 0)
  }

  /// Workroom trees are essentially always dirty, so `--autostash` is what makes pull usable at all.
  func testPullRebasesOverADirtyTreeAndPreservesTheChanges() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 1)
    sh("git clone -q origin.git other", in: f.root)
    sh(
      "git commit -q --allow-empty -m remote-side && git push -q origin HEAD:\(f.branch)",
      in: f.root + "/other")
    // An uncommitted change that must survive the rebase.
    sh("echo 'work in progress' > wip.txt && git add wip.txt", in: f.project)

    let w = writer()
    let before = try await state(w, path: f.project, projectRoot: f.project)
    let result = await w.pullRebase(
      path: f.project, projectRoot: f.project, current: before.current, remote: "origin",
      tracking: before.tracking)
    guard case .ok = result else { return XCTFail("pull failed: \(result)") }

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: f.project + "/wip.txt"),
      "--autostash must reapply the uncommitted work")
    let after = try await state(w, path: f.project, projectRoot: f.project)
    XCTAssertEqual(after.tracking?.behind, 0, "the remote commit is now ours")
    XCTAssertEqual(after.tracking?.ahead, 1, "our own commit rebased on top")
  }

  /// A leftover `index.lock` must be REPORTED, with the file located, against real git.
  ///
  /// This is the whole reason the failure carries a payload: a located lock withholds the Retry button,
  /// because retrying fails identically for as long as the file is there. The unit tests pin the parsing
  /// and the presentation; only this proves the two halves meet — that real git's actual message is one
  /// `parseLockPath` can read.
  ///
  /// It very nearly wasn't. git's index-lock failure leads with "Another git process seems to be running
  /// in this repository, or the lock file may be stale", which names no path; the path arrives on a later
  /// line as `error: Unable to create '<abs path>': File exists.` A parser written against the headline
  /// would find nothing and silently degrade every real lock to "busy, try again".
  ///
  /// The pull must have REAL work to do. With the branch already up to date, git short-circuits before it
  /// ever takes the index lock and the pull SUCCEEDS with the lock file sitting right there — so a version
  /// of this test without `commitsAhead` and a remote-side commit passes while proving nothing.
  func testALeftoverIndexLockIsReportedWithItsPath() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 1)
    sh("git clone -q origin.git other", in: f.root)
    sh(
      "git commit -q --allow-empty -m remote-side && git push -q origin HEAD:\(f.branch)",
      in: f.root + "/other")
    sh("echo 'work in progress' > wip.txt && git add wip.txt", in: f.project)

    let lockPath = f.project + "/.git/index.lock"
    XCTAssertTrue(
      FileManager.default.createFile(atPath: lockPath, contents: Data()), "couldn't plant the lock")

    let w = writer()
    let before = try await state(w, path: f.project, projectRoot: f.project)
    let result = await w.pullRebase(
      path: f.project, projectRoot: f.project, current: before.current, remote: "origin",
      tracking: before.tracking)

    guard case .failed(let failure) = result else {
      return XCTFail("a planted index.lock must fail the pull; got \(result)")
    }
    guard case .locked(let file) = failure else {
      return XCTFail("expected .locked, got \(failure)")
    }
    let located = try XCTUnwrap(file, "the path is in git's stderr, so it must be located")
    // Resolved on both sides: the fixture builds its path from `NSTemporaryDirectory()` (`/var/…`)
    // while git reports the one it actually opened (`/private/var/…`), and `/var` is a symlink to
    // `/private/var`. Comparing the raw strings comes down to which side happened to resolve it.
    XCTAssertEqual(
      URL(fileURLWithPath: located.path).resolvingSymlinksInPath().path,
      URL(fileURLWithPath: lockPath).resolvingSymlinksInPath().path)
    XCTAssertEqual(located.filename, "index.lock")

    // The consequence that matters: no Retry, because there is nothing a retry could achieve.
    XCTAssertNil(
      VCSSyncPresenter.retryAction(for: failure, lastAction: .pull),
      "a located lock must offer no retry")
    XCTAssertTrue(
      VCSSyncPresenter.explain(failure, now: Date()).contains(lockPath),
      "the tooltip has to name the file the user must delete")
  }

  func testPushIsRejectedWhenTheRemoteHasMovedOn() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 1)
    sh("git clone -q origin.git other", in: f.root)
    sh(
      "git commit -q --allow-empty -m remote-side && git push -q origin HEAD:\(f.branch)",
      in: f.root + "/other")
    sh("git fetch -q origin", in: f.project)

    let w = writer()
    let s = try await state(w, path: f.project, projectRoot: f.project)
    let result = await w.push(
      path: f.project, projectRoot: f.project, current: s.current, remote: "origin",
      setUpstream: false)
    guard case .failed(let failure) = result else {
      return XCTFail("a non-fast-forward push must be rejected, got \(result)")
    }
    guard case .rejected(let message) = failure else {
      return XCTFail("expected .rejected, got \(failure)")
    }
    // Pins the `--porcelain` flag against REAL git, not a fixture string: if the flag is ever dropped
    // from `gitPushArgs` this line goes, and the classification silently falls back to matching English
    // prose that a French locale would defeat.
    XCTAssertTrue(
      message.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("!\t") },
      "the porcelain flag column must be present in the output we classified: \(message)")
  }

  /// **Abort must run the REAL `git rebase --abort`.** A conflicted rebase — what a `git rebase` run by
  /// hand in the workroom's terminal leaves behind — is built with plain git, then aborted through the
  /// writer. The summary alone could be faked; `.git/rebase-merge` being gone cannot.
  func testAbortRebaseRunsTheRealGitAbort() async throws {
    try requireTool("git")
    let f = gitFixture()
    sh("echo base > a.txt && git add a.txt && git commit -qm base", in: f.project)
    sh("git checkout -q -b other && echo other >> a.txt && git commit -qam other", in: f.project)
    sh("git checkout -q \(f.branch) && echo mine >> a.txt && git commit -qam mine", in: f.project)
    sh("git checkout -q other && git rebase \(f.branch)", in: f.project)
    let rebaseMerge = f.project + "/.git/rebase-merge"
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: rebaseMerge),
      "setup must actually leave a rebase-merge behind, or this test proves nothing")

    let result = await writer().abortRebase(path: f.project, projectRoot: f.project)

    guard case .ok(let summary) = result else { return XCTFail("expected .ok, got \(result)") }
    XCTAssertEqual(summary, "Rebase aborted")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: rebaseMerge),
      "the real `git rebase --abort` must have cleared it")
  }
}
