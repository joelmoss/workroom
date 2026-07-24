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
