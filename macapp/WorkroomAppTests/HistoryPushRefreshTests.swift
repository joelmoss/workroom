import Defaults
import XCTest

@testable import Workroom

/// The end-to-end claim the unpushed badge makes: **push, and it clears** — without touching the UI.
///
/// Unlike `HistoryLiveRefreshTests` (which counts `log` calls through a stub to test the gating logic),
/// this drives a REAL git repo through the REAL `GitProvider`, so the assertion is about the push state
/// actually flipping after a push.
///
/// **Scope, stated honestly.** It invokes `AppStore.handleRootBranchChange` directly, which is the
/// callback the per-project `WorkroomFileWatcher` fires. So it proves the refresh path recomputes push
/// state; it does NOT prove FSEvents delivers the event (that the watcher points at the right directory
/// is `WorkroomFileWatcherTests`' and `AppStore.vcsMetadataDir`'s business — a push from a workroom
/// writes `refs/remotes/*` into the project's shared `.git`, which is what's watched).
@MainActor
final class HistoryPushRefreshTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    Defaults[.showInspector] = false
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: - fixture

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-pushref-\(UUID().uuidString)"
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

  /// A repo with `pushed` on `origin/main` and one local-only commit on top. Returns the work tree.
  private func repoWithLocalCommit() throws -> String {
    struct MissingTool: Error {}
    if sh("command -v git", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`git` is required for this test")
      throw MissingTool()
    }
    let root = tempDir()
    sh(
      """
      git init -q --bare bare.git
      git clone -q bare.git work
      cd work && git config user.email a@b.c && git config user.name t \
        && git checkout -q -b main && echo one > a.txt && git add . && git commit -qm pushed \
        && git push -qu origin main \
        && echo two > b.txt && git add . && git commit -qm localwork
      """, in: root)
    return root + "/work"
  }

  /// A store whose History pane is live on `path` (inspector visible, section History, the workroom has
  /// a tab so `inspectorTargetID` resolves) reading through the real `GitProvider`.
  private func liveHistoryStore(on path: String) async -> AppStore {
    let store = AppStore(commitHistory: HistoryModel(resolve: { _ in GitProvider() }))
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    // One project whose single "workroom" IS the repo itself — enough for the History pane, and it keeps
    // the fixture to one real repo.
    store.projects = [
      Project(
        path: path, vcs: "git",
        workrooms: [
          Workroom(name: "repo", path: path, vcsName: "main", warnings: [])
        ])
    ]
    Defaults[.showInspector] = true
    store.activeInspectorSection = .history
    let id = SidebarID.workroom(project: path, name: "repo")
    store.terminals.addTab(for: store.target(for: id)!)
    store.selectedTargetID = id
    await store.commitHistory.awaitCurrentLoad()
    return store
  }

  private func state(_ store: AppStore, _ summary: String) -> VCSPushState? {
    store.commitHistory.commits.first { $0.summary == summary }?.pushState
  }

  // MARK: - the flow

  func testPushClearsTheUnpushedStateOnRefresh() async throws {
    let repo = try repoWithLocalCommit()
    let store = await liveHistoryStore(on: repo)

    XCTAssertEqual(state(store, "localwork"), .unpushed, "the local commit starts unpushed")
    XCTAssertEqual(state(store, "pushed"), .pushed)
    XCTAssertEqual(store.commitHistory.pushScope?.refName, "origin/main")

    // Push from the repo, as a terminal in a workroom would.
    XCTAssertEqual(sh("git push -q origin main", in: repo).exit, 0)

    // The watcher's callback: a ref moved under the project's VCS metadata dir.
    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      state(store, "localwork"), .pushed,
      "after a push the refresh must recompute push state, not reuse the old page")
    XCTAssertTrue(
      store.commitHistory.commits.allSatisfy { !$0.showsUnpushedBadge },
      "no row badges once everything is on origin")
  }

  /// The reverse direction, so the test can't pass by simply reporting `.pushed` for everything: a NEW
  /// local commit after the refresh must badge again.
  func testNewLocalCommitBadgesAgainAfterRefresh() async throws {
    let repo = try repoWithLocalCommit()
    let store = await liveHistoryStore(on: repo)
    XCTAssertEqual(sh("git push -q origin main", in: repo).exit, 0)
    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertTrue(store.commitHistory.commits.allSatisfy { !$0.showsUnpushedBadge })

    sh("echo three > c.txt && git add . && git commit -qm afterpush", in: repo)
    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(state(store, "afterpush"), .unpushed)
    XCTAssertEqual(
      store.commitHistory.commits.filter(\.showsUnpushedBadge).map(\.summary), ["afterpush"])
  }
}
