import XCTest

@testable import Workroom

/// `GitGraph` unit tests against REAL throwaway git repos. This is the only file in the app that
/// exercises raw libgit2, and what matters is not the graph math (libgit2 owns that) but the CONTRACT:
///
/// - `origin` only — a commit on some other remote is still unpushed.
/// - Every failure returns `nil`, never a partial answer. A caller turns `nil` into "no badge on any
///   row"; a partial set would badge a pushed commit as unpushed, which is the one outcome the feature
///   forbids.
/// - It works when called FIRST in the process, with no `SwiftGitX.Repository` ever opened — proof that
///   `GitGraph` owns its own `git_libgit2_init` rather than free-riding on SwiftGitX's.
///
/// Repos are created fresh under `NSTemporaryDirectory()` and removed in `tearDown`; these never touch
/// a developer's own repository.
final class GitGraphTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: - helpers

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-gg-\(UUID().uuidString)"
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
    do { try p.run() } catch { return ("", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
  }

  private func requireGit() throws {
    struct MissingTool: Error {}
    if sh("command -v git", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`git` is required for GitGraph tests")
      throw MissingTool()
    }
  }

  /// `work` cloned from a bare `origin`, with `main` pushed, then `n` local-only commits on top.
  /// Returns the work tree path.
  private func repoWithOrigin(localCommits n: Int = 2) throws -> String {
    try requireGit()
    let root = tempDir()
    sh(
      """
      git init -q --bare bare.git
      git clone -q bare.git work
      cd work && git config user.email a@b.c && git config user.name t \
        && git checkout -q -b main && echo one > a.txt && git add . && git commit -qm pushed \
        && git push -qu origin main
      """, in: root)
    for i in 0..<n {
      sh("cd work && echo local\(i) > l\(i).txt && git add . && git commit -qm local\(i)", in: root)
    }
    return root + "/work"
  }

  /// Newest-first commit ids of `HEAD`, via git itself (so the expectations don't depend on the code
  /// under test).
  private func revList(_ work: String) -> [String] {
    sh("git rev-list HEAD", in: work).out
      .split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
  }

  // MARK: - page reads

  func testUnpushedSplitsAtTheOriginTip() throws {
    let work = try repoWithOrigin(localCommits: 2)
    let ids = revList(work)
    XCTAssertEqual(ids.count, 3, "2 local + 1 pushed")
    let local = Set(ids.prefix(2))
    let pushed = ids[2]

    let read = GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(ids))
    let result = try XCTUnwrap(read)
    XCTAssertEqual(result.unpushed, local)
    XCTAssertFalse(result.unpushed.contains(pushed))
    XCTAssertEqual(result.scope.count, 1)
    XCTAssertEqual(result.scope.refName, "origin/main")
  }

  /// A commit that IS an origin tip must read pushed. libgit2's `git_graph_descendant_of` explicitly
  /// does NOT treat a commit as its own descendant, so the equality case is exactly the kind of thing
  /// that silently inverts — pin it rather than assume.
  func testCommitAtTheOriginTipIsPushed() throws {
    let work = try repoWithOrigin(localCommits: 0)
    let tip = try XCTUnwrap(revList(work).first)

    let read = try XCTUnwrap(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: [tip]))
    XCTAssertTrue(read.unpushed.isEmpty, "the tip itself is pushed")

    let single = try XCTUnwrap(GitGraph.isPushed(root: URL(fileURLWithPath: work), commitID: tip))
    XCTAssertTrue(single.pushed)
  }

  func testMultipleOriginBranchesUnionAndDropTheRefName() throws {
    let work = try repoWithOrigin(localCommits: 1)
    let ids = revList(work)
    let localTip = ids[0]
    // Push the local commit under a SECOND origin branch. It's then on origin, so it must flip to
    // pushed even though `origin/main` still doesn't contain it — the tips are a union.
    sh("git push -q origin HEAD:refs/heads/feature", in: work)

    let read = try XCTUnwrap(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(ids)))
    XCTAssertTrue(read.unpushed.isEmpty, "every commit is now on one origin branch or the other")
    XCTAssertEqual(read.scope.count, 2)
    XCTAssertNil(read.scope.refName, "more than one branch ⇒ the tooltip counts instead of naming")
    _ = localTip
  }

  /// A pushed commit far behind the remote tip is still pushed: this is reachability, not "at or below
  /// HEAD". Guards a future "optimize" that compares positions instead of ancestry.
  func testCommitBehindTheOriginTipIsStillPushed() throws {
    let work = try repoWithOrigin(localCommits: 2)
    sh("git push -q origin main", in: work)
    // Reset the local branch behind what origin now has.
    sh("git reset -q --hard HEAD~1", in: work)
    let ids = revList(work)

    let read = try XCTUnwrap(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(ids)))
    XCTAssertTrue(read.unpushed.isEmpty, "everything local is an ancestor of the origin tip")
  }

  /// Detached HEAD works: origin-scoping needs no upstream configuration, unlike `@{u}`.
  func testDetachedHeadStillAnswers() throws {
    let work = try repoWithOrigin(localCommits: 1)
    let ids = revList(work)
    sh("git checkout -q --detach HEAD", in: work)

    let read = try XCTUnwrap(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(ids)))
    XCTAssertEqual(read.unpushed, [ids[0]], "the local commit is still the only unpushed one")
  }

  // MARK: - unanswerable reads (⇒ caller reports .unknown for every row)

  func testNoOriginRemoteIsUnanswerable() throws {
    try requireGit()
    let root = tempDir()
    sh(
      """
      git init -q work && cd work && git config user.email a@b.c && git config user.name t \
        && echo x > x.txt && git add . && git commit -qm only
      """, in: root)
    let work = root + "/work"

    XCTAssertNil(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(revList(work))),
      "no origin ⇒ nil, so the caller shows no badge rather than badging everything")
    XCTAssertNil(
      GitGraph.isPushed(
        root: URL(fileURLWithPath: work), commitID: try XCTUnwrap(revList(work).first)))
  }

  /// A remote that exists but isn't named `origin` doesn't count: its commits are not on the project's
  /// shared repo, which is what the badge claims.
  func testNonOriginRemoteIsIgnored() throws {
    try requireGit()
    let root = tempDir()
    sh(
      """
      git init -q --bare backup.git
      git init -q work && cd work && git config user.email a@b.c && git config user.name t \
        && echo x > x.txt && git add . && git commit -qm only \
        && git remote add backup ../backup.git && git push -q backup HEAD:refs/heads/main
      """, in: root)
    let work = root + "/work"

    XCTAssertNil(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(revList(work))),
      "`backup` is not `origin`, so there is still nothing to compare against")
  }

  func testUnopenablePathIsUnanswerable() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory() + "wr-gg-nope-\(UUID().uuidString)")
    XCTAssertNil(GitGraph.unpushed(root: missing, decide: ["deadbeef"]))
    XCTAssertNil(GitGraph.isPushed(root: missing, commitID: "deadbeef"))
  }

  /// An origin ref whose object is gone (a manually corrupted ref) must invalidate the WHOLE read.
  /// Skipping the bad tip would falsely badge any commit that only that tip contained.
  func testDamagedOriginRefIsUnanswerable() throws {
    let work = try repoWithOrigin(localCommits: 1)
    // Point origin/main at an object that doesn't exist. Written as a loose ref by hand on purpose:
    // `git update-ref` validates the target and refuses ("trying to write ref with nonexistent
    // object"), so it cannot produce the corruption this test is about.
    sh(
      """
      mkdir -p .git/refs/remotes/origin \
        && echo 0000000000000000000000000000000000000001 > .git/refs/remotes/origin/main
      """, in: work)
    XCTAssertEqual(
      sh("git rev-parse refs/remotes/origin/main", in: work).out.trimmingCharacters(
        in: .whitespacesAndNewlines),
      "0000000000000000000000000000000000000001",
      "the dangling ref is in place")

    XCTAssertNil(
      GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(revList(work))),
      "an unhideable tip makes the whole read unknown, not a partial answer")
  }

  func testUnknownCommitIdIsUnanswerable() throws {
    let work = try repoWithOrigin(localCommits: 1)
    XCTAssertNil(
      GitGraph.isPushed(
        root: URL(fileURLWithPath: work),
        commitID: "0000000000000000000000000000000000000001"))
    XCTAssertNil(
      GitGraph.isPushed(root: URL(fileURLWithPath: work), commitID: "not-a-sha"),
      "an unparseable id is unknown, not a crash")
  }

  // MARK: - libgit2 ownership

  /// `GitGraph` must not depend on a `SwiftGitX.Repository` having been opened first: SwiftGitX
  /// initializes libgit2 inside `Repository.open`, and this entry point can be reached before any
  /// repository exists (this test, a future direct caller). The assertion is simply that a read
  /// succeeds without touching SwiftGitX at all.
  func testWorksWithoutSwiftGitXHavingInitializedLibgit2() throws {
    let work = try repoWithOrigin(localCommits: 1)
    let read = GitGraph.unpushed(root: URL(fileURLWithPath: work), decide: Set(revList(work)))
    XCTAssertNotNil(read, "GitGraph initializes libgit2 itself")
  }
}
