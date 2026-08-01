import XCTest

@testable import Workroom

/// `CLIVCSWriter` against REAL git and jj repos through the REAL `StatusCommandRunner`.
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

  private func writer(_ vcs: String) -> CLIVCSWriter {
    CLIVCSWriter(
      vcs: vcs, runner: StatusCommandRunner(), makeProvider: { try VCS.provider(for: $0) },
      gate: JJSnapshotGate(maxChainWait: 5))
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

  private func state(_ w: CLIVCSWriter, path: String, projectRoot: String) async throws
    -> VCSRemoteState
  {
    guard case .state(let s) = await w.remoteState(path: path, projectRoot: projectRoot) else {
      throw XCTSkip("expected a resolved state")
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
    let w = writer("git")
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
    let s = try await state(writer("git"), path: f.project, projectRoot: f.project)
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
    let s = try await state(writer("git"), path: f.project, projectRoot: f.project)
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
    let s = try await state(writer("git"), path: workroom, projectRoot: f.project)
    XCTAssertEqual(s.current.name, "workroom/coral")
    XCTAssertEqual(s.tracking?.gone, true, "no counterpart on the remote yet")
    XCTAssertNil(s.tracking?.ahead, "a missing counterpart can't be counted against")
  }

  func testRemoteRefsAndPrimaryRemoteAreResolved() async throws {
    try requireTool("git")
    let f = gitFixture()
    let s = try await state(writer("git"), path: f.project, projectRoot: f.project)
    XCTAssertEqual(s.remotes, ["origin"])
    XCTAssertEqual(s.primaryRemote, "origin")
  }

  /// `refs/remotes/origin/HEAD` is a symref whose short name is the bare remote — without dropping it,
  /// `origin` looks like a branch. Real repos DO have it (verified), so this is not hypothetical.
  func testOriginHeadSymrefIsNotMistakenForABranch() async throws {
    try requireTool("git")
    let f = gitFixture()
    sh("git remote set-head origin master", in: f.project)
    let s = try await state(writer("git"), path: f.project, projectRoot: f.project)
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
    let w = writer("git")

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
    let s = try await state(writer("git"), path: project, projectRoot: project)
    XCTAssertEqual(s.lastFetch, .never, "clone/init never write FETCH_HEAD")
    XCTAssertNil(s.primaryRemote, "no remote configured")
  }

  // MARK: - git: actions

  func testPushMovesTheRemoteRefAndClearsAhead() async throws {
    try requireTool("git")
    let f = gitFixture(commitsAhead: 3)
    let w = writer("git")
    let before = try await state(w, path: f.project, projectRoot: f.project)
    XCTAssertEqual(before.tracking?.ahead, 3)

    let result = await w.push(
      path: f.project, projectRoot: f.project, current: before.current, remote: "origin",
      setUpstream: false, anonymousRevision: "@")
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
    let w = writer("git")
    let before = try await state(w, path: workroom, projectRoot: f.project)
    XCTAssertEqual(before.tracking?.gone, true)

    let result = await w.push(
      path: workroom, projectRoot: f.project, current: before.current, remote: "origin",
      setUpstream: true, anonymousRevision: "@")
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

    let w = writer("git")
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

    let w = writer("git")
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
    XCTAssertEqual(located.path, lockPath)
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

    let w = writer("git")
    let s = try await state(w, path: f.project, projectRoot: f.project)
    let result = await w.push(
      path: f.project, projectRoot: f.project, current: s.current, remote: "origin",
      setUpstream: false, anonymousRevision: "@")
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

  // MARK: - jj

  private func jjFixture() -> (root: String, project: String, config: String)? {
    let root = tempDir()
    let config = root + "/jjconfig.toml"
    try? "[user]\nname=\"T\"\nemail=\"t@e.com\"\n".write(
      toFile: config, atomically: true, encoding: .utf8)
    sh("git init -q --bare origin.git", in: root)
    let env = "JJ_CONFIG=\(config)"
    guard sh("\(env) jj git init --colocate app", in: root).exit == 0 else { return nil }
    let project = root + "/app"
    sh("echo hi > a.txt && \(env) jj describe -m first", in: project)
    sh("\(env) jj bookmark create main -r @", in: project)
    sh("\(env) jj git remote add origin ../origin.git", in: project)
    // No `--allow-new`: jj 0.43 removed it and now tracks a new bookmark automatically. Passing it
    // makes the push fail with "unexpected argument", which left the fixture with no remote at all.
    sh("\(env) jj git push --bookmark main", in: project)
    return (root, project, config)
  }

  /// **Cross-backend parity.** jj states its tracking counts from the REMOTE ref's point of view, so
  /// they are swapped on ingest. This asserts a jj repo and a git repo in the SAME state report the
  /// same app-level `VCSTracking` — the only test that would catch the swap being dropped or doubled.
  func testJJAndGitAgreeOnAheadBehindForTheSameState() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    let env = "JJ_CONFIG=\(j.config)"
    // Two local commits on the bookmark, unpushed.
    sh("\(env) jj new -m second && echo b > b.txt", in: j.project)
    sh("\(env) jj bookmark set main -r @", in: j.project)

    let jjState = try await state(writer("jj"), path: j.project, projectRoot: j.project)
    let g = gitFixture(commitsAhead: 1)
    let gitFixtureState = try await state(writer("git"), path: g.project, projectRoot: g.project)

    XCTAssertEqual(
      jjState.tracking?.ahead, 1,
      "jj must report AHEAD (local has work the remote lacks), not behind — the counts are inverted "
        + "at the source and swapped on ingest")
    XCTAssertEqual(jjState.tracking?.behind, 0)
    XCTAssertEqual(
      jjState.tracking?.ahead, gitFixtureState.tracking?.ahead,
      "both backends must describe the same situation identically")
  }

  /// **The bug this suite existed to catch and didn't.** An unbookmarked `@` counted behind as
  /// `@..remote_bookmarks(remote=…)`, which is every commit on every remote branch that isn't ours — so a
  /// repo with unmerged feature branches reported their work as "to pull" while sitting exactly on the
  /// tip of the main line. On a real project that read "97 to pull" from a clean checkout.
  ///
  /// The fixture is the minimum that shows it: `side@origin` holds one commit that `main` doesn't, and
  /// `@` is a fresh child of `main`. Behind must be 0. The old revset counted 1.
  func testBehindIgnoresOtherRemoteBookmarks() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    let env = "JJ_CONFIG=\(j.config)"
    // A side branch with a commit of its own, pushed — unmerged into main, and nothing to do with us.
    sh("\(env) jj new main -m side-work && echo s > s.txt", in: j.project)
    sh("\(env) jj bookmark create side -r @", in: j.project)
    sh("\(env) jj git push --bookmark side", in: j.project)
    // Back onto main, unbookmarked: the normal workroom shape, and NOT behind by anything.
    sh("\(env) jj new main -m mine", in: j.project)

    let s = try await state(writer("jj"), path: j.project, projectRoot: j.project)
    XCTAssertEqual(
      s.current.kind, .ancestor, "`@` must be unbookmarked for this to be the right path")
    XCTAssertEqual(
      s.tracking?.behind, 0,
      "another bookmark's unmerged commits are not ours to pull — behind must be measured against "
        + "trunk() alone")
  }

  /// A clean workroom must not claim work to push. `jj new` leaves `@` empty and undescribed, which jj
  /// refuses to push at all, yet it was counted — so every untouched workroom showed "1 ↑".
  func testAnEmptyWorkingCopyIsNotCountedAsAhead() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    sh("JJ_CONFIG=\(j.config) jj new main", in: j.project)  // no -m, no edits

    let s = try await state(writer("jj"), path: j.project, projectRoot: j.project)
    XCTAssertEqual(s.tracking?.ahead, 0, "an empty, undescribed `@` is not pushable and not ahead")
  }

  /// **Pull must actually rebase an unbookmarked `@`.** It used to fetch and return `.ok` — jj moves the
  /// remote bookmarks on fetch but does NOT move `@`, so the workroom stayed exactly as far behind as it
  /// started while the toolbar went on offering Pull. git's Pull has always been pull-and-rebase.
  ///
  /// Asserts behind BEFORE as well as after: without the before-assertion this would pass on a fixture
  /// that was never behind in the first place.
  func testPullRebasesAnUnbookmarkedWorkingCopyOntoTrunk() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    let env = "JJ_CONFIG=\(j.config)"
    // Our own unbookmarked work, off the current main.
    sh("\(env) jj new main -m mine && echo w > w.txt", in: j.project)
    // The remote main moves on, from a plain git clone of the same bare origin.
    //
    // `-b main` is required, unlike the git fixtures' bare `git clone`: jj pushed `main`, but the bare
    // repo's HEAD is whatever `git init --bare` chose (`master` here), so a plain clone warns "remote
    // HEAD refers to nonexistent ref", checks nothing out, and commits onto an unborn branch. The push
    // then fails as a non-fast-forward and the remote never moves — which made this test's own
    // precondition fail rather than the code under test.
    sh("git clone -q -b main origin.git other", in: j.root)
    sh(
      "git commit -q --allow-empty -m remote-side && git push -q origin HEAD:main",
      in: j.root + "/other")
    // Fetch first, exactly as the git tests do: `remoteState` reads local refs and never fetches, so
    // without this `main@origin` is still the old tip and the repo is legitimately not behind yet.
    sh("\(env) jj git fetch --remote origin", in: j.project)

    let w = writer("jj")
    let before = try await state(w, path: j.project, projectRoot: j.project)
    // `.none`, not `.ancestor`: the fetch fast-forwarded the local `main` past `@`, so `@`'s ancestry
    // holds no bookmark at all. Asserted rather than assumed, because this kind used to route to
    // `tracking = nil` — the counts and Pull disappeared at exactly this moment.
    XCTAssertEqual(before.current.kind, VCSRefKind.none)
    XCTAssertEqual(
      before.tracking?.behind, 1,
      "an unbookmarked `@` whose base moved must still report behind — got "
        + "\(String(describing: before.tracking))")

    let result = await w.pullRebase(
      path: j.project, projectRoot: j.project, current: before.current, remote: "origin",
      tracking: before.tracking)
    guard case .ok = result else { return XCTFail("jj pull failed: \(result)") }

    let after = try await state(w, path: j.project, projectRoot: j.project)
    XCTAssertEqual(
      after.tracking?.behind, 0, "pull must land `@` on top of trunk, not merely fetch")
    XCTAssertEqual(after.tracking?.ahead, 1, "and must keep our own commit")
  }

  /// jj's fetch passes `--no-write-fetch-head`, so `FETCH_HEAD` is never written. This encodes the
  /// finding so nobody "simplifies" the op-log scan away by reading `FETCH_HEAD` for jj too.
  func testJJFetchDoesNotWriteFetchHead() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    let fetchHead = j.project + "/.git/FETCH_HEAD"
    try? FileManager.default.removeItem(atPath: fetchHead)

    let result = await writer("jj").fetch(
      path: j.project, projectRoot: j.project, remote: "origin")
    guard case .ok = result else { return XCTFail("jj fetch failed: \(result)") }

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fetchHead),
      "jj fetches with --no-write-fetch-head; reading FETCH_HEAD for jj would report a stale or "
        + "absent time forever")
  }

  /// The `git` pseudo-remote a colocated repo exposes is not a remote, and must never appear.
  func testJJColocatedGitPseudoRemoteIsNotListed() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    let s = try await state(writer("jj"), path: j.project, projectRoot: j.project)
    XCTAssertFalse(s.remotes.contains("git"), "`git` is jj's local pseudo-remote, not a real one")
    XCTAssertEqual(s.primaryRemote, "origin")
  }

  /// A jj workspace has no bookmark on `@`, so push goes through jj's `--change` path, which mints and
  /// tracks a `push-<change-id>` bookmark.
  func testAnonymousJJPushCreatesATrackedPushBookmark() async throws {
    try requireTool("git")
    try requireTool("jj")
    guard let j = jjFixture() else { throw XCTSkip("jj fixture could not be created") }
    let env = "JJ_CONFIG=\(j.config)"
    // `jj new` leaves `@` unbookmarked — the normal workroom state.
    sh("\(env) jj new -m 'anonymous work' && echo c > c.txt", in: j.project)

    let w = writer("jj")
    let s = try await state(w, path: j.project, projectRoot: j.project)
    let result = await w.push(
      path: j.project, projectRoot: j.project, current: s.current, remote: "origin",
      setUpstream: false,
      anonymousRevision: CLIVCSWriter.jjPushRevision(hasChanges: true, hasDescription: true))
    guard case .ok = result else { return XCTFail("anonymous push failed: \(result)") }

    let remoteRefs = sh(
      "git for-each-ref --format='%(refname:short)' refs/heads", in: j.root + "/origin.git"
    ).out
    XCTAssertTrue(
      remoteRefs.contains("push-"),
      "jj should have minted a push-<change-id> bookmark on the remote, got: \(remoteRefs)")
  }
}
