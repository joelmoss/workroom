import Observation
import Synchronization
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// What following a terminal's folder costs per event (perf review of #812): `git` spawns per
/// resolve, resolves per `cd`, per finished command, per revisit and per burst of `cd`s, and what a
/// `cd` within one repository invalidates. Real throwaway repositories, a counting resolve seam and
/// recording watches.
@MainActor
final class FollowedResolveCostTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private var scratch: URL!
  private var watchers: [FollowedRepositoryStatusTests.RecordingWatcher] = []
  private final class ResolveLog: Sendable {
    let folders = Mutex<[String]>([])
  }
  private let resolves = ResolveLog()

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(sh("command -v git", in: NSTemporaryDirectory()) != 0, "git is not installed")
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("resolve-cost-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    scratch = URL(fileURLWithPath: VCSStatusService.canonicalPath(made.path))
  }

  override func tearDown() async throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    try await super.tearDown()
  }

  // MARK: Scaffold

  private final class CountingRunner: StatusCommandRunning, Sendable {
    private let real = StatusCommandRunner()
    let runs = Mutex<[[String]]>([])
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      runs.withLock { $0.append(args) }
      return await real.run(executable, args, in: directory, timeout: timeout)
    }
    func run(
      _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
      environment: [String: String]
    ) async -> CommandResult {
      runs.withLock { $0.append(args) }
      return await real.run(
        executable, args, in: directory, timeout: timeout, environment: environment)
    }
  }

  private func makeStore() -> AppStore {
    let status = VCSStatusService(projectStore: projects)
    status.followedProbeDebounce = 0
    status.makeRepositoryWatcher = { [weak self] onChange in
      let watcher = FollowedRepositoryStatusTests.RecordingWatcher(onChange: onChange)
      self?.watchers.append(watcher)
      return watcher
    }
    let store = AppStore(
      projectStore: projects, vcsStatus: status, terminalsSection: section,
      commitHistory: HistoryModel())
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    store.inspectorVisibleOverrideForTesting = true
    store.isolatesInspectorSectionForTesting = true
    store.isolatesInspectorLayoutForTesting = true
    store.activeInspectorSection = .changes
    let resolves = resolves
    store.resolveFollowedRepository = { folder in
      resolves.folders.withLock { $0.append(folder) }
      return await GitRepositoryProbe().discoverRepository(containing: folder)
    }
    return store
  }

  private var resolveCount: Int { resolves.folders.withLock { $0.count } }

  private func openTerminal(_ store: AppStore) async throws -> TerminalTab {
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.selectedTarget)
    guard case .standalone = target.id else { throw XCTSkip("not a standalone terminal") }
    await store.followedFolderResolved()
    return try XCTUnwrap(store.terminals.tabs(for: target).first)
  }

  private func settle(_ store: AppStore) async {
    await store.followedFolderResolved()
    await store.vcsStatus.followedWatchesSettled()
    await store.vcsStatus.followedStatusSettled()
  }

  private func cd(_ store: AppStore, _ tab: TerminalTab, _ folder: String) async throws {
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder)
    await settle(store)
  }

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": dir]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  private func repo(_ name: String) -> String {
    let path = scratch.appendingPathComponent(name).path
    try? FileManager.default.createDirectory(
      atPath: path + "/src/lib", withIntermediateDirectories: true)
    sh(
      "git init -q -b main . && echo x > src/lib/a.txt && git add . && "
        + "git -c user.name=t -c user.email=t@t commit -qm init", in: path)
    return path
  }

  private func finishCommand(_ store: AppStore, _ tab: TerminalTab) throws {
    try XCTUnwrap(store.terminals.surface(tab)).onEvent?(.commandFinished(0))
  }

  // MARK: The resolve

  /// Value: protects=a resolve costing one `git` spawn in the usual layouts (VCS N2);
  /// fails_when=it runs the root's `rev-parse` and `symbolic-ref` again; why_new=#812 perf;
  /// seam=GitRepositoryProbe's runners; no_claim=`core.worktree` (its own test keeps the check)
  func testAResolveSpawnsOneGitInARepositoryAndALinkedWorktree() async throws {
    let root = repo("app")
    let worktree = scratch.appendingPathComponent("wt").path
    sh("git worktree add -q -b topic \(worktree)", in: root)
    let runner = CountingRunner()
    let probe = GitRepositoryProbe(runner: runner, discoveryRunner: runner)

    let inRepo = await probe.discoverRepository(containing: root + "/src/lib")
    let inWorktree = await probe.discoverRepository(containing: worktree + "/src")

    guard case .repository(let found) = inRepo, case .repository(let linked) = inWorktree else {
      return XCTFail("both resolve: \(inRepo), \(inWorktree)")
    }
    XCTAssertEqual(found.root, root)
    XCTAssertEqual(found.branch, "main")
    XCTAssertEqual(linked.root, worktree)
    XCTAssertEqual(linked.branch, "topic")
    XCTAssertEqual(runner.runs.withLock { $0.count }, 2, "one git spawn per resolve")
  }

  /// Value: protects=a detached HEAD reading as no branch with no `symbolic-ref` (VCS N2);
  /// fails_when=the HEAD file's object name reads as a branch; why_new=#812 perf;
  /// seam=GitRepositoryProbe.headBranch; no_claim=reftable (it falls back to git)
  func testHeadReadsBranchDetachedAndReftableStub() throws {
    let dir = scratch.appendingPathComponent("heads").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func head(_ text: String) throws -> GitRepositoryProbe.Head {
      try text.write(toFile: dir + "/HEAD", atomically: true, encoding: .utf8)
      return GitRepositoryProbe.headBranch(gitDir: dir)
    }

    XCTAssertEqual(try head("ref: refs/heads/feature/x\n"), .branch("feature/x"))
    XCTAssertEqual(try head(String(repeating: "a", count: 40) + "\n"), .detached)
    XCTAssertEqual(try head("ref: refs/heads/.invalid\n"), .unreadable)
  }

  // MARK: Finished commands

  /// Value: protects=a finished command costing no `git` while a live watch covers the followed
  /// repository (UI #2, VCS I1); fails_when=every Enter at the prompt re-resolves; why_new=#812
  /// perf; seam=AppStore's resolve seam; no_claim=the watch's own re-resolve (FollowedRepository-
  /// StatusTests)
  func testAFinishedCommandInAWatchedRepositoryRunsNoResolve() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    XCTAssertTrue(store.followedWatchVouches(for: root), "the fixture's watch is live")
    let before = resolveCount

    for _ in 0..<5 { try finishCommand(store, tab) }
    await settle(store)

    XCTAssertEqual(resolveCount, before, "no resolve for five finished commands")
  }

  /// Value: protects=a `cd` resolving once (VCS I1); fails_when=the prompt's finished command
  /// that follows the shell's folder report starts the resolve over; why_new=#812 perf;
  /// seam=AppStore's resolve seam; no_claim=the zsh integration's order (OSC 7 then 133;D)
  func testACdFollowedByItsFinishedCommandResolvesOnce() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let before = resolveCount

    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(root + "/src/lib")
    try finishCommand(store, tab)
    await settle(store)

    XCTAssertEqual(resolveCount, before + 1)
    guard case .followed(let followed) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(followed.repository?.subfolder, "src/lib")
  }

  /// Value: protects=`cd app && git switch topic` into a repository not yet watched still showing
  /// `topic` (#807's recorded behaviour); fails_when=a command finishing mid-resolve is dropped;
  /// why_new=#812 perf; seam=AppStore's resolve seam (gated); no_claim=the watch
  func testASwitchDuringTheResolveOfANewRepositoryIsReChecked() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    let gate = AsyncStream<Void>.makeStream()
    let gated = ResolveLog()
    gated.folders.withLock { $0 = ["gated"] }
    store.resolveFollowedRepository = { folder in
      let found = await GitRepositoryProbe().discoverRepository(containing: folder)
      if !gated.folders.withLock({ $0.isEmpty }) { for await _ in gate.stream { break } }
      return found
    }
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(root)
    // The resolve has read `main`; the command then switches before it lands.
    try await Task.sleep(for: .milliseconds(200))
    sh("git switch -q -c topic", in: root)
    try finishCommand(store, tab)
    gated.folders.withLock { $0 = [] }
    gate.continuation.yield()
    await settle(store)

    guard case .followed(let followed) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(followed.repository?.branch, "topic")
  }

  // MARK: Cache

  /// Value: protects=a revisit of a folder with a fresh or watched answer running no `git` (UI #3,
  /// VCS I2); fails_when=a cache hit resolves anyway; why_new=#812 perf; seam=AppStore's resolve
  /// seam and the tracker's clock; no_claim=a revisit to an unwatched repository (resolves)
  func testARevisitWithAWatchedAnswerRunsNoGit() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    try await cd(store, tab, root + "/src/lib")
    let before = resolveCount
    // Long past freshness: only the watch vouches now.
    let later = ContinuousClock.now + .seconds(60)
    store.followedFolder.now = { later }

    try await cd(store, tab, root + "/src")
    try await cd(store, tab, root + "/src/lib")

    XCTAssertEqual(resolveCount, before, "the watched answers stand")
    guard case .followed(let followed) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(followed.repository?.subfolder, "src/lib")
  }

  /// Value: protects=a change under the repository still forgetting a watched answer (#807);
  /// fails_when=a trusted cache entry outlives the change its watch reported; why_new=#812 perf;
  /// seam=the recording watch; no_claim=the header's rendering
  func testAWatchReportedChangeForgetsTheWatchedAnswers() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    try await cd(store, tab, root + "/src/lib")
    sh("git switch -q -c topic", in: root)
    try XCTUnwrap(watchers.last { $0.path == root }).onChange([root + "/.git/HEAD"], false)
    await settle(store)
    let before = resolveCount

    try await cd(store, tab, root + "/src")

    XCTAssertEqual(resolveCount, before + 1, "the forgotten answer resolves afresh")
    guard case .followed(let followed) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(followed.repository?.branch, "topic")
  }

  // MARK: Bursts

  /// Value: protects=a loop of `cd`s spawning and following only the folder it settles on (VCS
  /// I8); fails_when=each folder passed spawns a git or follows and unfollows its repository;
  /// why_new=#812 perf; seam=the tracker's burst wait; no_claim=the debounce's length
  func testABurstOfCdsResolvesAndFollowsOnlyTheSettledFolder() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let roots = (0..<8).map { repo("r\($0)") }
    let surface = try XCTUnwrap(store.terminals.surface(tab))
    let before = resolveCount
    let watchesBefore = watchers.count

    for root in roots { surface.handlePwd(root) }
    await settle(store)

    XCTAssertLessThanOrEqual(
      resolveCount - before, 2, "the first folder's resolve and the settled one's, no more")
    XCTAssertEqual(store.heldFollowedRepository, roots.last)
    XCTAssertEqual(
      Set(watchers.dropFirst(watchesBefore).compactMap(\.path)), [roots.last!],
      "only the settled repository is watched")
  }

  // MARK: Invalidation

  /// Value: protects=a `cd` within one repository invalidating only the folder's readers (UI #1);
  /// fails_when=Changes, History, Pull Request, the toolbar, the activity bar or the menu observe
  /// the folder; why_new=#812 perf; seam=Observation tracking of the accessors those views read;
  /// no_claim=SwiftUI's diffing
  func testACdWithinOneRepositoryInvalidatesOnlyTheFolderReaders() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    try await cd(store, tab, root + "/src/lib")
    try await cd(store, tab, root + "/src")

    let repositoryReaders = ResolveLog()
    let folderReaders = ResolveLog()
    withObservationTracking {
      // What the version-control sections, the toolbar, the activity bar and the menu read.
      _ = store.vcsStatus.status(for: store.inspectorRepositorySubject)
      _ = store.inspectorRepositorySubject.repositoryKey
      _ = store.inspectorShowsRepositoryControls
      _ = store.inspectorActionTarget
      _ = store.inspectorPullRequestTarget
      _ = store.inspectorMemoryKey(for: .changes)
      _ = store.inspectorMemoryKey(for: .history)
      _ = store.inspectorMemoryKey(for: .pullRequest)
      _ = store.followedFolderLoaderShown
      _ = store.remoteTarget()
      _ = store.toolbarBranchName(for: store.remoteTarget())
      _ = store.inspectorHistoryTarget
      _ = store.inspectorTargetID
    } onChange: {
      repositoryReaders.folders.withLock { $0.append("x") }
    }
    withObservationTracking {
      _ = store.inspectorSubject
    } onChange: {
      folderReaders.folders.withLock { $0.append("x") }
    }

    try await cd(store, tab, root + "/src/lib")

    XCTAssertEqual(
      folderReaders.folders.withLock { $0.count }, 1, "the header, Details and Files re-read")
    XCTAssertEqual(
      repositoryReaders.folders.withLock { $0.count }, 0,
      "nothing reading the repository part re-renders")
  }
}
