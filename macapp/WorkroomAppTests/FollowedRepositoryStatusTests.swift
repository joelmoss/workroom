import Synchronization
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// Changes and Pull Request for the repository a terminal's inspector follows, kept live (#807):
/// its status comes from the repository's root, not a sidebar row; a registered workroom's repository
/// shows that row's status in place; and the repository is watched while some window follows it.
/// Real throwaway repositories; the watch is a recorder whose changes the test delivers.
@MainActor
final class FollowedRepositoryStatusTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private var scratch: URL!
  private var watchers: [RecordingWatcher] = []

  /// A watch that records what it watches; `fire` delivers a change as the host watcher would.
  final class RecordingWatcher: RepositoryWatching {
    let onChange: @MainActor ([String], Bool) -> Void
    private(set) var path: String?
    private(set) var stopped = false
    init(onChange: @escaping @MainActor ([String], Bool) -> Void) { self.onChange = onChange }
    func start(path: String) { self.path = path }
    func stop() { stopped = true }
  }

  /// `git` runs for real; `gh` never does. With `onGitHub` it answers as a GitHub repository with
  /// one open pull request, else as a repository with no GitHub remote.
  private final class GitHubRunner: StatusCommandRunning, Sendable {
    private let real = StatusCommandRunner()
    private let onGitHub: Bool
    /// The branch each `gh pr list` run asked about.
    let pullRequestLists = Mutex<[String?]>([])
    /// How many times `gh` ran at all.
    let gitHubRuns = Mutex(0)
    /// While set, `gh pr list` waits: a GitHub round held in flight.
    let holdsPullRequests = Mutex(false)
    init(onGitHub: Bool) { self.onGitHub = onGitHub }
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      guard executable == "gh" else {
        return await real.run(executable, args, in: directory, timeout: timeout)
      }
      gitHubRuns.withLock { $0 += 1 }
      if args.prefix(2) == ["pr", "list"] {
        let branch = args.firstIndex(of: "--head").map { args.index(after: $0) }
          .flatMap { args.indices.contains($0) ? args[$0] : nil }
        pullRequestLists.withLock { $0.append(branch) }
        while holdsPullRequests.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
      }
      func ok(_ out: String) -> CommandResult {
        CommandResult(stdout: out, stderr: "", exitCode: 0, timedOut: false)
      }
      if args.first == "--version" { return ok("gh version 2.60.0 (2024-10-01)\n") }
      guard onGitHub else {
        if args.first == "auth" { return ok("") }
        return CommandResult(
          stdout: "", stderr: "no git remotes found", exitCode: 1, timedOut: false)
      }
      if args.prefix(2) == ["repo", "view"] { return ok("https://github.com/octo/repo\n") }
      if args.prefix(2) == ["pr", "checks"] { return ok("[]") }
      if args.contains("graphql") {
        return ok(#"{"data":{"repository":{"object":{"statusCheckRollup":null}}}}"#)
      }
      if args.prefix(2) == ["pr", "list"] {
        return ok(
          #"[{"number":9,"title":"Feature","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null}]"#
        )
      }
      return ok("")
    }
  }

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(sh("command -v git", in: NSTemporaryDirectory()) != 0, "git is not installed")
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("followed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    scratch = URL(fileURLWithPath: VCSStatusService.canonicalPath(made.path))
  }

  override func tearDown() async throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    try await super.tearDown()
  }

  // MARK: Scaffold

  private var runner: GitHubRunner!

  /// The branches `gh pr list` was asked about, in order.
  private var pullRequestBranches: [String?] {
    runner.pullRequestLists.withLock { $0 }
  }

  private func makeStatus(
    onGitHub: Bool = false, debounce: TimeInterval = 0,
    seeded: (@MainActor () -> AppServices.SeededStatuses)? = nil
  ) -> VCSStatusService {
    let status = VCSStatusService(projectStore: projects, seededStatuses: seeded)
    runner = GitHubRunner(onGitHub: onGitHub)
    status.statusResolver = WorkroomStatusResolver(runner: runner)
    status.followedProbeDebounce = debounce
    // Let go of at once: the grace a last unfollow gets has its own tests, which set it.
    status.followedUnfollowGrace = 0
    status.makeRepositoryWatcher = { [weak self] onChange in
      let watcher = RecordingWatcher(onChange: onChange)
      self?.watchers.append(watcher)
      return watcher
    }
    return status
  }

  private func makeStore(_ status: VCSStatusService) -> AppStore {
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
    store.historySectionCollapsed = false
    return store
  }

  private func openTerminal(_ store: AppStore) async throws -> TerminalTab {
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.selectedTarget)
    guard case .standalone = target.id else { throw XCTSkip("not a standalone terminal") }
    await store.followedFolderResolved()
    return try XCTUnwrap(store.terminals.tabs(for: target).first)
  }

  /// The shell in `tab` reports `folder`; wait for its repository and status to settle.
  private func cd(_ store: AppStore, _ tab: TerminalTab, _ folder: String) async throws {
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder)
    await settle(store)
  }

  private func settle(_ store: AppStore) async {
    await store.followedFolderResolved()
    await store.vcsStatus.followedStatusSettled()
    await store.commitHistory.awaitCurrentLoad()
  }

  private func watcher(for path: String) -> RecordingWatcher? {
    watchers.last { $0.path == path }
  }

  private func changedPaths(_ store: AppStore) -> [String]? {
    store.vcsStatus.status(for: store.inspectorSubject)?.changedFiles?.map(\.path)
  }

  // MARK: Repositories on disk

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["GIT_AUTHOR_NAME"] = "T"
    env["GIT_AUTHOR_EMAIL"] = "t@e.com"
    env["GIT_COMMITTER_NAME"] = "T"
    env["GIT_COMMITTER_EMAIL"] = "t@e.com"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  private func folder(_ name: String) -> String {
    let path = scratch.appendingPathComponent(name).path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// A git repository with one commit on `branch`, a `src` folder, and a pending edit to `a.txt`.
  private func repo(_ name: String, branch: String = "main") -> String {
    let dir = folder(name)
    sh("git init -q -b \(branch) .", in: dir)
    try? FileManager.default.createDirectory(
      atPath: dir + "/src", withIntermediateDirectories: true)
    try? "x\n".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
    sh("git add -A && git commit -qm base", in: dir)
    try? "edited\n".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
    return dir
  }

  // MARK: Changes and Pull Request

  /// Value: protects=Changes for a followed repository (AC 1); fails_when=a followed folder shows
  /// no status, or the repository's changes are written under the terminal's sidebar row (AC 7);
  /// why_new=#807; seam=AppStore + VCSStatusService; no_claim=the panel's rendering
  func testChangesListsTheFollowedRepositorysChangesUnderNoSidebarRow() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")

    try await cd(store, tab, root + "/src")

    XCTAssertEqual(changedPaths(store), ["src/a.txt"])
    XCTAssertNotNil(status.followedStatuses[root])
    let sid = try XCTUnwrap(store.selectedTargetID)
    XCTAssertNil(status.workroomStatuses[sid], "a terminal's row gains no changes badge")
    XCTAssertTrue(status.workroomStatuses.isEmpty)
  }

  /// Value: protects=Pull Request for a followed repository's branch (AC 1); fails_when=the PR
  /// probe never runs for a followed repository, or lands nowhere the panel reads; why_new=#807;
  /// seam=VCSStatusService (gh stubbed, git real); no_claim=the PR actions (#808)
  func testPullRequestShowsTheFollowedBranchsPullRequest() async throws {
    let status = makeStatus(onGitHub: true)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app", branch: "feature/x")

    try await cd(store, tab, root)

    let followed = try XCTUnwrap(status.status(for: store.inspectorSubject))
    XCTAssertEqual(followed.pr?.number, 9)
    XCTAssertNotNil(followed.prCheckedAt)
  }

  /// Value: protects=a save while the pull request is being read; fails_when=the watch's
  /// local-only re-read cancels the PR probe, leaving "Checking…" until a manual refresh;
  /// why_new=#807; seam=VCSStatusService; no_claim=timing of the real watch
  func testASaveWhileThePullRequestLoadsDoesNotCancelIt() async throws {
    let status = makeStatus(onGitHub: true)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app", branch: "feature/x")

    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(root)
    await store.followedFolderResolved()
    try XCTUnwrap(watcher(for: root)).onChange([root + "/src/a.txt"], false)
    await settle(store)

    XCTAssertEqual(status.status(for: store.inspectorSubject)?.pr?.number, 9)
  }

  /// Value: protects=a followed repository with no GitHub remote settling (no "Checking…" forever);
  /// fails_when=its PR check stamp stays nil; why_new=#807; seam=VCSStatusService; no_claim=CI
  func testAFollowedRepositoryWithNoGitHubRemoteSettlesWithNoPullRequest() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)

    try await cd(store, tab, repo("app"))

    let followed = try XCTUnwrap(status.status(for: store.inspectorSubject))
    XCTAssertNil(followed.pr)
    XCTAssertNotNil(followed.prCheckedAt, "the section settles as having no pull request")
  }

  /// Value: protects=the UI-test fixture's followed repositories (QA of #803); fails_when=seeded
  /// statuses stop a followed repository's probe, so Changes and Pull Request say "Checking…"
  /// forever, or a followed repository there reaches `gh`; why_new=#803 QA; seam=VCSStatusService
  /// with seeded statuses; no_claim=History (the fixture's reader), registered workrooms
  func testSeededStatusesStillProbeAFollowedRepositoryButNeverAskGitHub() async throws {
    let status = makeStatus(
      onGitHub: true,
      seeded: {
        AppServices.SeededStatuses(root: .unresolved, workroom: .unresolved, gitHubCLI: nil)
      })
    XCTAssertFalse(status.probesRepositories, "the fixture's workrooms stay seeded")
    let store = makeStore(status)
    let tab = try await openTerminal(store)

    try await cd(store, tab, repo("app", branch: "feature/x") + "/src")

    XCTAssertEqual(changedPaths(store), ["src/a.txt"])
    let followed = try XCTUnwrap(status.status(for: store.inspectorSubject))
    XCTAssertNil(followed.pr)
    XCTAssertNotNil(followed.prCheckedAt, "Pull Request settles as having none")
    XCTAssertEqual(runner.gitHubRuns.withLock { $0 }, 0, "gh never runs under seeded statuses")
  }

  /// Value: protects=History for the UI-test fixture's followed repositories (QA of #803);
  /// fails_when=the fixture's reader serves its canned commits for a real repository, or reads a
  /// fixture path (not a repository) for real; why_new=#803 QA; seam=AppServices.fixture.vcsReader;
  /// no_claim=the History panel's rendering
  func testTheFixturesReaderReadsARealRepositoryForRealAndAFixturePathCanned() throws {
    let read = try XCTUnwrap(AppServices.fixture.vcsReader)
    let root = URL(fileURLWithPath: repo("app"))
    XCTAssertEqual(try read(root).log(root: root, limit: 10).commits.map(\.summary), ["base"])

    let plain = URL(fileURLWithPath: folder("plain"))
    XCTAssertEqual(
      try read(plain).log(root: plain, limit: 10).commits.first?.summary, "Fixture commit 1")
  }

  /// Value: protects=a registered workroom's repository showing in place (AC 2); fails_when=the
  /// selection or sidebar moves, or a second, sidebar-less entry shadows the row's status;
  /// why_new=#807; seam=AppStore + VCSStatusService; no_claim=the sidebar's rendering
  func testARegisteredWorkroomsRepositoryShowsInPlace() async throws {
    let root = repo("platform")
    projects.projects = [Project(path: root, vcs: "git", workrooms: [])]
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let selected = store.selectedTargetID

    try await cd(store, tab, root + "/src")

    XCTAssertEqual(store.selectedTargetID, selected, "the selection does not move")
    guard case .followed = store.inspectorSubject else {
      return XCTFail("subject is \(store.inspectorSubject)")
    }
    let row = SidebarID.root(project: projects.projects[0].id)
    XCTAssertEqual(status.registeredSidebarID(forCanonicalRoot: root), row)
    XCTAssertEqual(status.status(for: store.inspectorSubject), status.workroomStatuses[row])
    XCTAssertEqual(changedPaths(store), ["src/a.txt"])
    XCTAssertTrue(status.followedStatuses.isEmpty)
  }

  /// Value: protects=the registered match comparing canonical paths (parent decision after #805):
  /// a workroom registered as `/var/...` while git names it `/private/var/...`; fails_when=the
  /// spelling difference makes it a second, sidebar-less entry; why_new=#807;
  /// seam=VCSStatusService; no_claim=remote workrooms (never matched)
  func testAWorkroomRegisteredByAnotherSpellingStillShowsInPlace() async throws {
    let root = repo("wr")
    let spelled = root.hasPrefix("/private/") ? String(root.dropFirst("/private".count)) : root
    try XCTSkipIf(spelled == root, "the scratch folder has no second spelling")
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: spelled, vcsName: "workroom/a", warnings: [])])
    ]
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)

    try await cd(store, tab, root)

    let row = SidebarID.workroom(project: "/p", name: "a")
    XCTAssertEqual(status.registeredSidebarID(forCanonicalRoot: root), row)
    XCTAssertEqual(status.workroomStatuses[row]?.changedFiles?.map(\.path), ["src/a.txt"])
    XCTAssertTrue(status.followedStatuses.isEmpty)
  }

  /// Value: protects=a diff opened from a followed repository reading that repository, and two
  /// repositories' same-named files staying apart; fails_when=the diff reads the terminal's folder,
  /// or repo two's `src/a.txt` re-selects repo one's tab; why_new=#807; seam=AppStore content
  /// tabs; no_claim=the diff's rendering
  func testADiffFromAFollowedRepositoryReadsThatRepository() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let one = repo("one")
    let two = repo("two")
    let target = try XCTUnwrap(store.selectedTarget)
    let file = ChangedFile(path: "src/a.txt", change: .modified)
    func focusedDiffRoot() -> String? {
      guard case .diff(let d) = store.terminals.focusedTab(for: target)?.content else { return nil }
      return d.repositoryRoot
    }

    try await cd(store, tab, one)
    store.openDiffPersistent(file, source: .gitWorktree)
    XCTAssertEqual(focusedDiffRoot(), one)

    try await cd(store, tab, two)
    store.openDiffPersistent(file, source: .gitWorktree)
    XCTAssertEqual(focusedDiffRoot(), two)
  }

  /// Value: protects=the not-a-repo state's store half (AC 5); fails_when=a folder outside any
  /// repository gets a status or a watch; why_new=#807; seam=AppStore; no_claim=the copy
  func testOutsideARepositoryThereIsNoStatusAndNoWatch() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)

    try await cd(store, tab, folder("plain"))

    XCTAssertNil(status.status(for: store.inspectorSubject))
    XCTAssertTrue(watchers.isEmpty)
    XCTAssertNil(store.heldFollowedRepository)
  }

  // MARK: Live

  /// Value: protects=an edit in the followed repository refreshing Changes, and a commit refreshing
  /// History (AC 3); fails_when=the watch's change re-reads nothing; why_new=#807;
  /// seam=VCSStatusService change handler (the watch's delivery); no_claim=FSEvents itself
  func testAnEditRefreshesChangesAndACommitRefreshesHistory() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let watch = try XCTUnwrap(watcher(for: root))

    try "new\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
    watch.onChange([root + "/b.txt"], false)
    await settle(store)
    XCTAssertEqual(Set(changedPaths(store) ?? []), ["src/a.txt", "b.txt"])

    let before = store.commitHistory.commits.count
    sh("git add -A && git commit -qm second", in: root)
    watch.onChange([root + "/.git/refs/heads/main"], false)
    await settle(store)
    XCTAssertEqual(changedPaths(store), [])
    XCTAssertEqual(store.commitHistory.commits.count, before + 1, "History re-reads the log")
  }

  /// Value: protects=the watch's lifetime (AC 4), refcounted across windows; fails_when=a second
  /// window's leaving stops the first's watch, or the last one leaving keeps it (and its status);
  /// why_new=#807; seam=AppStore + VCSStatusService; no_claim=the daemon's subscription
  func testWatchingLastsWhileSomeWindowFollowsTheRepository() async throws {
    let status = makeStatus()
    let first = makeStore(status)
    let second = makeStore(status)
    let root = repo("app")
    let firstTab = try await openTerminal(first)
    try await cd(first, firstTab, root)
    let secondTab = try await openTerminal(second)
    try await cd(second, secondTab, root + "/src")
    let watch = try XCTUnwrap(watcher(for: root))
    XCTAssertEqual(watchers.filter { $0.path == root }.count, 1, "one watch for both windows")

    try await cd(first, firstTab, folder("elsewhere"))
    XCTAssertFalse(watch.stopped, "the other window still follows it")
    XCTAssertNotNil(status.followedStatuses[root])

    second.selectedTargetID = nil
    XCTAssertTrue(watch.stopped, "no window follows it any more")
    XCTAssertNil(status.followedStatuses[root])
    XCTAssertFalse(status.isFollowing(root))
  }

  /// Value: protects=a deleted or moved repository falling back to not-a-repo (AC 6);
  /// fails_when=its stale status or an error stays on screen; why_new=#807; seam=AppStore +
  /// VCSStatusService; no_claim=the copy
  func testADeletedRepositoryFallsBackToNotARepository() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    let watch = try XCTUnwrap(watcher(for: root))

    try FileManager.default.moveItem(atPath: root, toPath: root + "-moved")
    watch.onChange([], true)
    await settle(store)

    guard case .followed(let followed) = store.inspectorSubject else {
      return XCTFail("subject is \(store.inspectorSubject)")
    }
    XCTAssertNil(followed.repository)
    XCTAssertNil(status.status(for: store.inspectorSubject))
    XCTAssertTrue(watch.stopped)
    XCTAssertTrue(status.followedStatuses.isEmpty)
  }

  /// Value: protects=the header's branch following a `git switch` without a `cd` (parent decision
  /// after #805), from the watch and from a finished command; fails_when=the branch stays stale;
  /// why_new=#807; seam=AppStore; no_claim=the header's rendering
  func testASwitchedBranchIsReReadWithoutACd() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let watch = try XCTUnwrap(watcher(for: root))

    sh("git switch -q -c topic", in: root)
    watch.onChange([root + "/.git/HEAD"], false)
    await settle(store)
    guard case .followed(let afterWatch) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(afterWatch.repository?.branch, "topic")

    // A finished command re-reads nothing while the live watch covers the repository (#812 perf):
    // the watch's own report of the switch is what re-reads it.
    await store.vcsStatus.followedWatchesSettled()
    sh("git switch -q main", in: root)
    try XCTUnwrap(store.terminals.surface(tab)).onEvent?(.commandFinished(0))
    await settle(store)
    guard case .followed(let afterCommand) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(afterCommand.repository?.branch, "topic", "the command alone runs no git")
    watch.onChange([root + "/.git/HEAD"], false)
    await settle(store)
    guard case .followed(let afterSwitch) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(afterSwitch.repository?.branch, "main")
  }

  /// Value: protects=Files staying on a browsed folder across a re-read of the repository (#809
  /// meets #807); fails_when=a save or a finished command snaps Files back; why_new=#807;
  /// seam=AppStore; no_claim=the breadcrumb's rendering
  func testAReReadKeepsTheFolderFilesIsBrowsing() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    store.browseFiles(toSegment: 0)
    let browse = try XCTUnwrap(store.filesBrowse)

    try XCTUnwrap(watcher(for: root)).onChange([root + "/src/a.txt"], false)
    try XCTUnwrap(store.terminals.surface(tab)).onEvent?(.commandFinished(0))
    await settle(store)

    XCTAssertEqual(store.filesBrowse, browse)
  }

  /// Value: protects=a `git init` in the followed folder, with no `cd`, making it a repository
  /// (adversarial review of #805, finding 2); fails_when=the folder stays not-a-repo;
  /// why_new=#807; seam=AppStore; no_claim=the watch
  func testAGitInitIsPickedUpAfterTheCommandFinishes() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let plain = folder("plain")
    try await cd(store, tab, plain)

    sh("git init -q -b main .", in: plain)
    try XCTUnwrap(store.terminals.surface(tab)).onEvent?(.commandFinished(0))
    await settle(store)

    guard case .followed(let followed) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(followed.repository?.root, plain)
    XCTAssertTrue(status.isFollowing(plain))
  }

  // MARK: Review of #807

  /// Value: protects=a `cd` back to a folder seen before holding its repository (review of #807,
  /// finding 1); fails_when=the cached folder shows its repository with no status and no watch, or
  /// the repository left behind stays watched; why_new=review; seam=AppStore + VCSStatusService;
  /// no_claim=the panels' rendering
  func testACdBackToAFolderSeenBeforeFollowsItsRepository() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let one = repo("one")
    let two = repo("two")

    try await cd(store, tab, one)
    try await cd(store, tab, folder("plain"))
    try await cd(store, tab, one)

    XCTAssertTrue(status.isFollowing(one))
    XCTAssertEqual(store.heldFollowedRepository, one)
    XCTAssertEqual(watcher(for: one)?.stopped, false, "the repository shown is watched")
    XCTAssertEqual(changedPaths(store), ["src/a.txt"])

    try await cd(store, tab, two)
    try await cd(store, tab, one)

    XCTAssertTrue(status.isFollowing(one))
    XCTAssertFalse(status.isFollowing(two))
    XCTAssertEqual(watcher(for: two)?.stopped, true, "the repository left behind is not watched")
  }

  /// Value: protects=instant revisits (QA round 2): going back to a repository followed lately
  /// shows its last-known Changes, Pull Request and History at once, and refreshes them behind;
  /// fails_when=the last unfollow drops them, so a revisit shows "Checking…" and "Loading
  /// history…" until the fresh reads land; why_new=QA round 2; seam=AppStore + VCSStatusService +
  /// HistoryModel; no_claim=the panels' rendering
  func testARevisitShowsTheRepositorysLastKnownStateAtOnce() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let one = repo("one")

    try await cd(store, tab, one)
    let known = try XCTUnwrap(status.followedStatuses[one])
    XCTAssertEqual(store.commitHistory.commits.map(\.summary), ["base"])
    try await cd(store, tab, folder("plain"))
    XCTAssertFalse(status.isFollowing(one))

    // The fresh reads are held back, so only what was kept can show.
    status.followedProbeDebounce = 3600
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(one)
    await store.followedFolderResolved()

    XCTAssertEqual(status.followedStatuses[one], known, "Changes and Pull Request, at once")
    XCTAssertEqual(changedPaths(store), ["src/a.txt"])
    XCTAssertEqual(store.commitHistory.commits.map(\.summary), ["base"], "History, at once")
    XCTAssertEqual(store.commitHistory.state, .loading, "and re-read behind it")
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertEqual(store.commitHistory.state, .loaded)
  }

  /// Value: protects=stale cached data is never acted on (QA round 2); fails_when=a repository
  /// kept only in the recent cache counts as followed, or a write resolves through it rather than
  /// the live hold's registration; why_new=QA round 2; seam=VCSStatusService;
  /// no_claim=the write itself (FollowedRepositoryWritesTests)
  func testAKeptRepositoryIsNeverWrittenThroughUntilItIsFollowedAgain() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let one = repo("one")

    try await cd(store, tab, one)
    await status.followedRegistrationsSettled()
    try await cd(store, tab, folder("plain"))
    await status.followedRegistrationsSettled()

    XCTAssertFalse(status.canAddress(.followed(root: one)))
    let refused = await status.followedWriteLocation(one)
    XCTAssertNil(refused, "a kept status addresses nothing")
    do {
      _ = try await status.writeLocation(for: .followed(root: one))
      XCTFail("a write to a repository no window follows is refused")
    } catch is FollowedRepositoryGone {}

    try await cd(store, tab, one)
    await status.followedRegistrationsSettled()
    XCTAssertTrue(status.canAddress(.followed(root: one)))
    let live = await status.followedWriteLocation(one)
    XCTAssertEqual(
      live.map { VCSStatusService.canonicalPath($0.path) }, one,
      "through the new hold's registration")
  }

  /// Value: protects=Pull Request following a branch switched, committed or pushed in the terminal
  /// (review of #807, finding 2); fails_when=a change to the repository's refs never asks GitHub
  /// again, or a plain save does; why_new=review; seam=VCSStatusService change handler (gh
  /// stubbed); no_claim=CI finishing on GitHub with nothing changed here
  func testAMovedRefReProbesThePullRequestAndASaveDoesNot() async throws {
    let status = makeStatus(onGitHub: true)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let watch = try XCTUnwrap(watcher(for: root))
    XCTAssertEqual(pullRequestBranches, ["main"])

    try "saved\n".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
    watch.onChange([root + "/src/a.txt"], false)
    watch.onChange([root + "/.git/index"], false)
    await settle(store)
    XCTAssertEqual(
      pullRequestBranches, ["main"], "a save, and git's index write, ask GitHub nothing")

    sh("git switch -q -c feature", in: root)
    watch.onChange([root + "/.git/HEAD"], false)
    await settle(store)
    XCTAssertEqual(pullRequestBranches, ["main", "feature"])
    XCTAssertEqual(status.status(for: store.inspectorSubject)?.pr?.number, 9)

    watch.onChange([root + "/.git/refs/remotes/origin/feature"], false)
    await settle(store)
    XCTAssertEqual(pullRequestBranches, ["main", "feature", "feature"], "a push asks again")
  }

  /// Value: protects=a repository rooted at the home folder (a dotfiles repository) not being
  /// watched as a tree (review of #807, finding 3); fails_when=the watch covers all of `~`, or the
  /// repository's branch stops being watched; why_new=review; seam=VCSStatusService (watch
  /// recorder); no_claim=the daemon's cost
  func testARepositoryAtTheHomeFolderWatchesOnlyItsGitDirectory() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let home = repo("home")
    status.watchHome = home

    try await cd(store, tab, home + "/src")

    XCTAssertNil(watcher(for: home), "the home folder's tree is not watched")
    XCTAssertNotNil(watcher(for: home + "/.git"), "its git directory is")
    XCTAssertEqual(changedPaths(store), ["src/a.txt"], "its status still reads on follow")
  }

  /// Value: the bound itself; fails_when=`/`, the home folder, `/Users` or a volume's root is
  /// watched as a tree, or an ordinary folder isn't; why_new=review of #807, finding 3;
  /// seam=pure function; no_claim=which folders a user keeps repositories in
  func testTheWatchBoundRefusesTheHomeFolderTheDiskAndVolumes() {
    let home = "/Users/me"
    for root in ["/", "/Users", "/Users/me", "/Volumes/Backup"] {
      XCTAssertTrue(HostFileWatcher.isTooBroadToWatch(root, home: home), root)
    }
    for root in ["/Users/me/dev/app", "/Volumes/Backup/app", "/private/tmp/x"] {
      XCTAssertFalse(HostFileWatcher.isTooBroadToWatch(root, home: home), root)
    }
  }

  /// Value: protects=a save re-reading the status only (review of #807, finding 3); fails_when=
  /// every save in the tree re-resolves the folder in every window following it; why_new=review;
  /// seam=AppStore resolve seam (counted); no_claim=FSEvents itself
  func testASaveDoesNotReResolveTheFolder() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let resolves = Mutex(0)
    let resolve = store.resolveFollowedRepository
    store.resolveFollowedRepository = { folder in
      resolves.withLock { $0 += 1 }
      return await resolve(folder)
    }
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let watch = try XCTUnwrap(watcher(for: root))
    let before = resolves.withLock { $0 }

    watch.onChange([root + "/src/a.txt"], false)
    await settle(store)
    XCTAssertEqual(resolves.withLock { $0 }, before)

    watch.onChange([root + "/.git/HEAD"], false)
    await settle(store)
    XCTAssertEqual(resolves.withLock { $0 }, before + 1, "a change to its git directory does")
  }

  /// Value: protects=the inspector's status reads touching no file system (review of #807,
  /// finding 4); fails_when=a read canonicalises the registered paths again; why_new=review;
  /// seam=VCSStatusService's canonicaliser (counted); no_claim=the first index build
  func testReadingAFollowedStatusCanonicalisesNothing() async throws {
    let root = repo("platform")
    projects.projects = [
      Project(
        path: root, vcs: "git",
        workrooms: [Workroom(name: "a", path: folder("wr"), vcsName: "workroom/a", warnings: [])])
    ]
    let status = makeStatus()
    let counted = Mutex(0)
    status.canonicalise = { path in
      counted.withLock { $0 += 1 }
      return VCSStatusService.canonicalPath(path)
    }
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    try await cd(store, tab, root + "/src")
    XCTAssertNotNil(status.status(for: store.inspectorSubject))
    let before = counted.withLock { $0 }

    for _ in 0..<10 { _ = status.status(for: store.inspectorSubject) }

    XCTAssertEqual(counted.withLock { $0 }, before)
    projects.projects.append(Project(path: folder("later"), vcs: "git", workrooms: []))
    XCTAssertNotNil(status.status(for: store.inspectorSubject))
    await status.registeredIndexSettled()
    XCTAssertGreaterThan(counted.withLock { $0 }, before, "a new project rebuilds the index")
  }

  /// Value: protects=a stalled mount never freezing the windows (Codex on #812); fails_when=
  /// following, asking about, refreshing or letting go of a followed repository resolves its path
  /// (`realpath`) on the main actor, rather than reading git's canonical root as the key it is;
  /// why_new=review; seam=VCSStatusService follow/unfollow + `canonicalise`; no_claim=a real stall
  func testFollowingAndLettingGoResolveNoPath() async throws {
    let root = repo("app")
    let link = scratch.appendingPathComponent("link").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
    let status = makeStatus()
    let counted = Mutex(0)
    status.canonicalise = { path in
      counted.withLock { $0 += 1 }
      return VCSStatusService.canonicalPath(path)
    }

    status.follow(root)
    XCTAssertTrue(status.isFollowing(root))
    XCTAssertFalse(status.isFollowing(link), "a key is read as given: nothing resolves it")
    status.refreshFollowedStatus(root, gitHub: false)
    status.retryFollowedRegistration(root)
    await status.followedStatusSettled()
    status.unfollow(link)
    XCTAssertTrue(status.isFollowing(root), "another spelling holds nothing")
    status.unfollow(root)

    XCTAssertFalse(status.isFollowing(root))
    XCTAssertEqual(watcher(for: root)?.stopped, true)
    XCTAssertEqual(counted.withLock { $0 }, 0)
    await status.followedRegistrationsSettled()
  }

  /// Value: protects=a held followed repository's pull request and CI staying current (Codex on
  /// #812); fails_when=the status sweep refreshes only registered rows, so CI finishing or a PR
  /// merging elsewhere leaves a followed repository's state stale; why_new=review;
  /// seam=VCSStatusService.refreshWorkroomStatuses (gh stubbed); no_claim=the timer's interval
  func testTheSweepRefreshesAFollowedRepositorysGitHubStateOnTheWorkroomsCadence() async throws {
    let status = makeStatus(onGitHub: true)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app", branch: "feature/x")
    try await cd(store, tab, root)
    let checked = try XCTUnwrap(status.followedStatuses[root]?.ciCheckedAt)
    let probed = pullRequestBranches.count

    status.refreshWorkroomStatuses()
    await status.statusSweepTask?.value
    await status.followedStatusSettled()
    XCTAssertEqual(pullRequestBranches.count, probed, "not again within the CI TTL")

    status.followedStatuses[root]?.ciCheckedAt = checked.addingTimeInterval(-3600)
    status.refreshWorkroomStatuses()
    await status.statusSweepTask?.value
    await status.followedStatusSettled()
    XCTAssertEqual(pullRequestBranches.count, probed + 1, "once it is stale, as a workroom's")
  }

  /// Value: protects=arrow-keying past terminals in different repositories (review of #807,
  /// finding 5); fails_when=a repository followed for less than the selection's debounce forks
  /// git and gh; why_new=review; seam=VCSStatusService follow/unfollow (gh stubbed);
  /// no_claim=the folder's resolve
  func testARepositoryPassedByQuicklyIsNotProbed() async throws {
    let status = makeStatus(onGitHub: true, debounce: 0.3)
    // Even while the repository passed by lingers in its unfollow grace.
    status.followedUnfollowGrace = 3600
    let one = repo("one", branch: "passed-by")
    let two = repo("two")

    status.follow(one)
    status.unfollow(one)
    status.follow(two)
    await status.followedStatusSettled()

    XCTAssertEqual(pullRequestBranches, ["main"], "only the repository stayed on is asked about")
    XCTAssertEqual(status.followedStatuses[two]?.changedFiles?.map(\.path), ["src/a.txt"])
  }

  // MARK: Watch lifetime

  /// A linked worktree of `root` at a sibling folder `name`, on a new branch `name`.
  private func worktree(of root: String, _ name: String) -> String {
    let path = scratch.appendingPathComponent(name).path
    sh("git worktree add -q -b \(name) \(path)", in: root)
    return path
  }

  /// Value: protects=a closed window letting go of its terminal's repository (AC 4, the `deinit`
  /// path); fails_when=closing the last window following a repository keeps its watch and status;
  /// why_new=deferred from #807; seam=AppStore deinit + VCSStatusService; no_claim=NSWindow close
  func testClosingAWindowStopsWatchingItsRepository() async throws {
    let status = makeStatus()
    let root = repo("app")
    weak var closed: AppStore?
    do {
      let store = makeStore(status)
      let tab = try await openTerminal(store)
      try await cd(store, tab, root + "/src")
      closed = store
    }
    let watch = try XCTUnwrap(watcher(for: root))
    XCTAssertNil(closed, "the window's store is gone")
    // `deinit` hands the unfollow to the main actor.
    for _ in 0..<100 where !watch.stopped { await Task.yield() }

    XCTAssertTrue(watch.stopped, "no window follows it any more")
    XCTAssertFalse(status.isFollowing(root))
    XCTAssertNil(status.followedStatuses[root])
  }

  /// Value: protects=a linked worktree's HEAD and refs being watched where they live, in its main
  /// repository's git directory (#807); fails_when=a commit or `git switch` in a linked worktree
  /// goes unseen until a save, or that watch outlives the follow; why_new=deferred from #807;
  /// seam=VCSStatusService (watch recorder); no_claim=FSEvents itself
  func testALinkedWorktreeAlsoWatchesItsRepositorysGitDirectory() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    sh("git commit -qam edit", in: root)
    let linked = worktree(of: root, "feature")

    try await cd(store, tab, linked)
    await status.followedWatchesSettled()

    let tree = try XCTUnwrap(watcher(for: linked), "its tree is watched")
    let gitDirectory = try XCTUnwrap(watcher(for: root + "/.git"), "so is its repository's")
    XCTAssertEqual(changedPaths(store), [])

    let before = store.commitHistory.commits.count
    try "new\n".write(toFile: linked + "/b.txt", atomically: true, encoding: .utf8)
    sh("git add -A && git commit -qm second", in: linked)
    gitDirectory.onChange([root + "/.git/worktrees/feature/HEAD"], false)
    await settle(store)
    XCTAssertEqual(changedPaths(store), [], "Changes re-reads")
    XCTAssertEqual(store.commitHistory.commits.count, before + 1, "History re-reads the log")

    store.selectedTargetID = nil
    XCTAssertTrue(tree.stopped)
    XCTAssertTrue(gitDirectory.stopped, "the git directory's watch ends with the follow")
  }

  /// Value: protects=one git-directory watch per followed linked worktree (review of #807,
  /// finding 6); fails_when=a follow let go of and taken again while git names the git directory
  /// adds a second watch, so every ref change is handled twice; why_new=review;
  /// seam=VCSStatusService (watch recorder); no_claim=FSEvents itself
  func testALinkedWorktreeFollowedAgainQuicklyHasOneGitDirectoryWatch() async throws {
    let status = makeStatus()
    let root = repo("app")
    let linked = worktree(of: root, "feature")

    status.follow(linked)
    status.unfollow(linked)
    status.follow(linked)
    await status.followedWatchesSettled()

    let live = watchers.filter { $0.path == root + "/.git" && !$0.stopped }
    XCTAssertEqual(live.count, 1, "one watch on the repository's git directory")
    status.unfollow(linked)
    XCTAssertTrue(watchers.allSatisfy(\.stopped))
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
  }

  /// A stat that never returns while its gate stands: a stalled SMB or NFS mount. `release` lets
  /// it return at last, as the kernel giving up would, so no GCD thread outlives the test.
  private final class StuckStat: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    let calls = Mutex(0)
    var stat: @Sendable (String) -> Bool {
      { [self] _ in
        calls.withLock { $0 += 1 }
        _ = gate.wait(timeout: .now() + 10)
        return false
      }
    }
    func release() { gate.signal() }
  }

  /// Value: protects=a stalled mount never freezing the windows on a revisit (Codex on #812):
  /// following a repository stats its `.git` off the main actor, under a bounded wait;
  /// fails_when=`follow` (from `updateFollowedFolder`'s cached repository) runs the stat on the
  /// main actor, or the watch setup waits on it unbounded; why_new=review;
  /// seam=VCSStatusService follow + the stat seam (stuck); no_claim=a real network mount
  func testAStuckStatNeverBlocksTheMainActor() async throws {
    let status = makeStatus()
    let stuck = StuckStat()
    defer { stuck.release() }
    status.followedGitFileStat = stuck.stat
    status.followedStatTimeout = 0.2
    let root = repo("app")
    status.watchHome = root

    let started = Date()
    status.follow(root)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1, "follow returns at once")
    await status.followedWatchesSettled()

    XCTAssertEqual(stuck.calls.withLock { $0 }, 1, "the stat was asked, off the main actor")
    XCTAssertNotNil(watcher(for: root + "/.git"), "the watch goes on without it")
    status.unfollow(root)
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
  }

  /// Value: protects=no watch for a hold let go of while its `.git` was stat'd (Codex on #812);
  /// fails_when=a watch is installed once the stat returns though no window follows the
  /// repository any more, or a hold taken afresh meanwhile gets the old one's watch as well as
  /// its own; why_new=review; seam=VCSStatusService follow/unfollow + the stat seam (stuck);
  /// no_claim=a real network mount
  func testAHoldLetGoOfDuringAStuckStatGetsNoWatch() async throws {
    let status = makeStatus()
    let stuck = StuckStat()
    status.followedGitFileStat = stuck.stat
    let root = repo("app")
    status.watchHome = root

    status.follow(root)
    status.unfollow(root)
    stuck.release()
    await status.followedWatchesSettled()
    XCTAssertTrue(watchers.isEmpty, "nothing watches a repository no window follows")

    status.followedGitFileStat = { _ in false }
    status.follow(root)
    await status.followedWatchesSettled()
    XCTAssertEqual(watchers.filter { !$0.stopped }.map(\.path), [root + "/.git"])
    status.unfollow(root)
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
  }

  // MARK: Off the main actor (Codex on #812)

  /// A canonicaliser that records any call made on the main thread, and stalls on `stalled` until
  /// released, as a hung network mount would.
  final class GuardedCanonicaliser: Sendable {
    let stalled: String?
    private let gate = DispatchSemaphore(value: 0)
    let onMainThread = Mutex<[String]>([])
    init(stalled: String? = nil) { self.stalled = stalled }
    var canonicalise: @Sendable (String) -> String {
      { [self] path in
        if Thread.isMainThread { onMainThread.withLock { $0.append(path) } }
        if path == stalled { _ = gate.wait(timeout: .now() + 5) }
        return VCSStatusService.canonicalPath(path)
      }
    }
    func release() { for _ in 0..<8 { gate.signal() } }
  }

  /// Value: protects=a stalled registered project never freezing a follow (Codex on #812, thread
  /// 4681358213); fails_when=the registered-path index runs `realpath` on the main actor, or one
  /// stalled entry keeps the rest of the index from landing; why_new=review;
  /// seam=VCSStatusService follow + lookup + the canonicaliser (stalled, main-thread guarded);
  /// no_claim=a real network mount
  func testAStalledRegisteredProjectNeverBlocksFollowingAHealthyRepository() async throws {
    let healthy = repo("app")
    let stalled = folder("stalled")
    let status = makeStatus()
    let guarded = GuardedCanonicaliser(stalled: stalled)
    defer { guarded.release() }
    status.canonicalise = guarded.canonicalise
    status.registeredPathTimeout = 0.2
    projects.projects = [
      Project(path: stalled, vcs: "git", workrooms: []),
      Project(path: healthy, vcs: "git", workrooms: []),
    ]

    let started = Date()
    status.follow(healthy)
    _ = status.status(forFollowedRoot: healthy)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1, "follow and a read return at once")
    await status.registeredIndexSettled()

    XCTAssertEqual(guarded.onMainThread.withLock { $0 }, [], "no realpath on the main actor")
    XCTAssertEqual(
      status.registeredSidebarID(forCanonicalRoot: healthy), .root(project: healthy),
      "the healthy entry lands though another stalled")
    XCTAssertEqual(
      status.registeredSidebarID(forCanonicalRoot: stalled), .root(project: stalled),
      "a timed-out entry falls back to its literal path")
    status.unfollow(healthy)
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
  }

  /// Value: protects=a followed repository's status source following the registered index
  /// (Codex on #812); fails_when=a rebuild that registers the root leaves its own status behind,
  /// a probe in flight across the switch lands in the source it left, or the watch is dropped;
  /// why_new=the index builds off the main actor; seam=VCSStatusService follow + the project
  /// list; no_claim=the sidebar's rendering
  func testARebuildMovesAFollowedRepositoryInPlaceAndBack() async throws {
    let root = repo("app")
    let status = makeStatus()
    status.follow(root)
    await status.followedStatusSettled()
    XCTAssertEqual(status.followedStatuses[root]?.changedFiles?.map(\.path), ["src/a.txt"])

    // A probe in flight across the switch, held by its debounce.
    status.followedProbeDebounce = 5
    let stale = status.refreshFollowedStatus(root, gitHub: true, debounced: true)
    status.followedProbeDebounce = 0
    projects.projects = [Project(path: root, vcs: "git", workrooms: [])]
    await status.followedStatusSettled()
    await stale?.value

    let row = SidebarID.root(project: root)
    XCTAssertEqual(status.registeredSidebarID(forCanonicalRoot: root), row)
    XCTAssertNil(status.followedStatuses[root], "in place: no status of its own")
    XCTAssertEqual(status.workroomStatuses[row]?.changedFiles?.map(\.path), ["src/a.txt"])
    XCTAssertEqual(status.status(forFollowedRoot: root), status.workroomStatuses[row])
    XCTAssertEqual(watchers.filter { !$0.stopped }.map(\.path), [root], "its watch stands")

    projects.projects = []
    await status.followedStatusSettled()

    XCTAssertNil(status.registeredSidebarID(forCanonicalRoot: root))
    XCTAssertEqual(status.followedStatuses[root]?.changedFiles?.map(\.path), ["src/a.txt"])
    XCTAssertNotNil(status.followedStatuses[root]?.prCheckedAt, "its own probe ran again")
    XCTAssertEqual(watchers.filter { !$0.stopped }.map(\.path), [root])
    status.unfollow(root)
    XCTAssertTrue(watchers.allSatisfy(\.stopped))
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
  }

  /// Value: protects=holds, watches and router registrations balancing through follow and
  /// unfollow storms while an index build is stalled (Codex on #812); fails_when=a build landing
  /// re-routes a repository no window follows, leaves a followed one's own status behind once it
  /// is registered, or touches the file system on the main actor; why_new=the index builds off
  /// the main actor; seam=VCSStatusService follow/unfollow + the canonicaliser (stalled);
  /// no_claim=a real network mount
  func testFollowAndUnfollowStormsWhileARebuildIsInFlight() async throws {
    let one = repo("one")
    let two = repo("two")
    let status = makeStatus()
    let guarded = GuardedCanonicaliser(stalled: one)
    defer { guarded.release() }
    status.canonicalise = guarded.canonicalise
    status.registeredPathTimeout = 5
    projects.projects = [Project(path: one, vcs: "git", workrooms: [])]
    status.rebuildRegisteredIndex()

    for _ in 0..<20 {
      status.follow(one)
      status.follow(two)
      status.unfollow(one)
    }
    status.follow(one)
    XCTAssertNil(status.registeredSidebarID(forCanonicalRoot: one), "the build is still out")
    guarded.release()
    await status.followedStatusSettled()
    await status.followedWatchesSettled()

    XCTAssertEqual(guarded.onMainThread.withLock { $0 }, [], "no realpath on the main actor")
    XCTAssertEqual(status.registeredSidebarID(forCanonicalRoot: one), .root(project: one))
    XCTAssertNil(status.followedStatuses[one], "in place once the build lands")
    XCTAssertEqual(status.followedStatuses[two]?.changedFiles?.map(\.path), ["src/a.txt"])
    XCTAssertEqual(
      Set(watchers.filter { !$0.stopped }.map(\.path)), [one, two], "one watch each")

    for _ in 0..<20 { status.unfollow(two) }
    status.unfollow(one)
    XCTAssertFalse(status.isFollowing(one) || status.isFollowing(two))
    XCTAssertTrue(watchers.allSatisfy(\.stopped))
    XCTAssertTrue(status.followedStatuses.isEmpty)
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
    XCTAssertNil(RepositoryRouter.shared.localLocation(for: one), "every router hold released")
    XCTAssertNil(RepositoryRouter.shared.localLocation(for: two))
  }

  // MARK: Probe cost (#812 perf lane P3)

  /// Counts the followed working-status reads (each one a daemon `working_status`: 2 to 4 git
  /// processes), and holds them open while `holds` is set, as a slow read on a large tree does.
  private final class ReadCounter: Sendable {
    let started = Mutex(0)
    let running = Mutex(0)
    let mostAtOnce = Mutex(0)
    let holds = Mutex(false)
    var count: Int { started.withLock { $0 } }
  }

  private func countReads(_ status: VCSStatusService) -> ReadCounter {
    let counter = ReadCounter()
    status.readFollowedWorkingStatus = { resolver, item, path in
      counter.started.withLock { $0 += 1 }
      let now = counter.running.withLock {
        $0 += 1
        return $0
      }
      counter.mostAtOnce.withLock { $0 = max($0, now) }
      while counter.holds.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
      let read = await VCSStatusService.readWorkingStatus(resolver, item: item, path: path)
      counter.running.withLock { $0 -= 1 }
      return read
    }
    return counter
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), "timed out")
  }

  /// Value: protects=one `git status` per ref change (perf I3); fails_when=the local lane and the
  /// full probe each read the status for the same change; why_new=#812 perf review;
  /// seam=VCSStatusService change handler (read counted); no_claim=the daemon's own cost
  func testARefChangeReadsTheStatusOnce() async throws {
    let status = makeStatus(onGitHub: true)
    let root = repo("app")
    status.follow(root)
    await status.followedStatusSettled()
    let watch = try XCTUnwrap(watcher(for: root))
    let reads = countReads(status)

    sh("git commit -qam second", in: root)
    watch.onChange([root + "/.git/refs/heads/main", root + "/.git/index"], false)
    await status.followedStatusSettled()

    XCTAssertEqual(reads.count, 1, "the full probe reuses the local lane's read")
    XCTAssertEqual(pullRequestBranches, ["main", "main"], "and still asks GitHub")
    XCTAssertEqual(status.followedStatuses[root]?.changedFiles, [])
  }

  /// Value: protects=single-flight status reads per repository (perf I4); fails_when=a change
  /// landing while a read runs starts a second read beside it (the daemon can't cancel the
  /// first), or a burst queues more than one follow-up; why_new=#812 perf review;
  /// seam=VCSStatusService change handler (read held open); no_claim=the daemon's permit pool
  func testChangesDuringAReadQueueOneFollowUpAndNeverOverlap() async throws {
    let status = makeStatus()
    let root = repo("app")
    status.follow(root)
    await status.followedStatusSettled()
    let watch = try XCTUnwrap(watcher(for: root))
    let reads = countReads(status)
    reads.holds.withLock { $0 = true }

    watch.onChange([root + "/src/a.txt"], false)
    try await waitUntil { reads.count == 1 }
    try "later\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
    for _ in 0..<3 { watch.onChange([root + "/b.txt"], false) }
    status.refreshFollowedStatus(root, gitHub: false)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(reads.count, 1, "nothing starts beside the read in flight")
    reads.holds.withLock { $0 = false }
    await status.followedStatusSettled()

    XCTAssertEqual(reads.count, 2, "one follow-up for the whole burst")
    XCTAssertEqual(reads.mostAtOnce.withLock { $0 }, 1)
    XCTAssertEqual(
      Set(status.followedStatuses[root]?.changedFiles?.map(\.path) ?? []), ["src/a.txt", "b.txt"],
      "the follow-up saw the later change")
  }

  /// Value: protects=a commit the daemon delivers as a leading and a trailing batch costing one
  /// GitHub round (perf I3); fails_when=the trailing batch cancels the round in flight and asks
  /// GitHub again; why_new=#812 perf review; seam=VCSStatusService change handler (gh held);
  /// no_claim=a second commit landing mid-round (it keeps the round's answer until the TTL)
  func testACommitDeliveredInTwoBatchesAsksGitHubOnce() async throws {
    let status = makeStatus(onGitHub: true)
    let root = repo("app")
    status.follow(root)
    await status.followedStatusSettled()
    let watch = try XCTUnwrap(watcher(for: root))
    let reads = countReads(status)
    runner.holdsPullRequests.withLock { $0 = true }

    sh("git commit -qam second", in: root)
    watch.onChange([root + "/.git/refs/heads/main", root + "/.git/index"], false)
    try await waitUntil { self.pullRequestBranches.count == 2 }
    watch.onChange([root + "/.git/refs/heads/main", root + "/.git/logs/HEAD"], false)
    runner.holdsPullRequests.withLock { $0 = false }
    await status.followedStatusSettled()

    XCTAssertEqual(pullRequestBranches, ["main", "main"], "one GitHub round for the commit")
    XCTAssertLessThanOrEqual(reads.count, 2)
    XCTAssertEqual(status.followedStatuses[root]?.pr?.number, 9)
  }

  /// Value: protects=what a git-directory path costs (perf I6); fails_when=an index write, an
  /// object or a reflog counts as metadata (a re-resolve per window) or asks GitHub, or a ref
  /// stops doing either; why_new=#812 perf review; seam=the change classifier;
  /// no_claim=FSEvents' path spelling
  func testOnlyRefsAndTheGitEntryCountAsMetadata() {
    let r = "/r"
    func change(_ paths: [String], overflow: Bool = false) -> FollowedRepositoryChange {
      VCSStatusService.followedChange(paths: paths, overflow: overflow)
    }
    let none = FollowedRepositoryChange(readsStatus: false, asksGitHub: false, metadata: false)
    let local = FollowedRepositoryChange(readsStatus: true, asksGitHub: false, metadata: false)
    let all = FollowedRepositoryChange(readsStatus: true, asksGitHub: true, metadata: true)
    XCTAssertEqual(change([r + "/src/a.txt"]), local)
    XCTAssertEqual(change([r + "/.git/index"]), local, "an index write is a local change only")
    XCTAssertEqual(change([r + "/.git/objects/ab/cdef", r + "/.git/logs/HEAD"]), none)
    XCTAssertEqual(change([r + "/.git/index.lock", r + "/.git/COMMIT_EDITMSG"]), none)
    XCTAssertEqual(change([r + "/.git/HEAD"]), all)
    XCTAssertEqual(change([r + "/.git/refs/heads/main"]), all)
    XCTAssertEqual(change([r + "/.git/packed-refs"]), all)
    XCTAssertEqual(change([r + "/.git/FETCH_HEAD"]), all)
    XCTAssertEqual(change([r + "/sub/.git"]), all, "a `git init` or `rm -rf .git`")
    XCTAssertEqual(change([r + "/.git/objects/x", r + "/src/a.txt"]), local)
    XCTAssertEqual(change([], overflow: true), all)
    XCTAssertEqual(change([]), all)
    XCTAssertTrue(change([r + "/.git/refs/heads/main"]).movesOnlyLocalBranches)
    XCTAssertFalse(change([r + "/.git/refs/remotes/origin/main"]).movesOnlyLocalBranches)
    XCTAssertFalse(change([r + "/.git/HEAD"]).movesOnlyLocalBranches)

    // A linked worktree's watch on its repository's git directory.
    func linked(_ paths: [String], own: String = r + "/.git/worktrees/wt")
      -> FollowedRepositoryChange
    {
      VCSStatusService.followedChange(
        paths: paths, overflow: false, gitDirectory: own, commonDirectory: r + "/.git")
    }
    XCTAssertEqual(linked([r + "/.git/worktrees/wt/HEAD"]), all)
    XCTAssertEqual(linked([r + "/.git/worktrees/wt/FETCH_HEAD"]), all)
    XCTAssertEqual(linked([r + "/.git/worktrees/wt/index"]), local)
    XCTAssertEqual(linked([r + "/.git/refs/heads/wt"]), all)
    XCTAssertEqual(
      linked([r + "/.git/worktrees/other/index", r + "/.git/index", r + "/.git/objects/a"]), none)
    XCTAssertEqual(linked(["/elsewhere/.git/refs/heads/wt"]), all, "a spelling it can't place")
    XCTAssertEqual(
      linked([r + "/.git/refs/heads/main"], own: r + "/.git"), all,
      "a submodule's git directory is its own and its repository's")
  }

  /// Value: protects=an object or reflog write costing nothing (perf I6); fails_when=it re-reads
  /// the status or asks GitHub; why_new=#812 perf review; seam=VCSStatusService change handler;
  /// no_claim=the classifier's every path (above)
  func testAnObjectWriteReadsNothing() async throws {
    let status = makeStatus(onGitHub: true)
    let root = repo("app")
    status.follow(root)
    await status.followedStatusSettled()
    let watch = try XCTUnwrap(watcher(for: root))
    let reads = countReads(status)

    watch.onChange([root + "/.git/objects/ab/cdef", root + "/.git/logs/HEAD"], false)
    await status.followedStatusSettled()
    XCTAssertEqual(reads.count, 0)
    XCTAssertEqual(pullRequestBranches, ["main"])
  }

  /// Value: protects=a followed linked worktree ignoring its siblings (perf I5); fails_when=a
  /// sibling's index write, an object or the main checkout's index in the shared git directory
  /// reads its status or asks GitHub, or its own HEAD and index stop doing so; why_new=#812 perf
  /// review; seam=VCSStatusService (watch recorder); no_claim=FSEvents itself
  func testALinkedWorktreeIgnoresItsSiblingsInTheSharedGitDirectory() async throws {
    let status = makeStatus(onGitHub: true)
    let root = repo("app")
    sh("git commit -qam edit", in: root)
    let linked = worktree(of: root, "feature")
    _ = worktree(of: root, "other")
    status.follow(linked)
    await status.followedWatchesSettled()
    await status.followedStatusSettled()
    let gitDirectory = try XCTUnwrap(watcher(for: root + "/.git"))
    let reads = countReads(status)
    let asked = pullRequestBranches.count

    gitDirectory.onChange(
      [
        root + "/.git/worktrees/other/index", root + "/.git/worktrees/other/HEAD",
        root + "/.git/objects/ab/cdef", root + "/.git/index",
      ], false)
    await status.followedStatusSettled()
    XCTAssertEqual(reads.count, 0, "a sibling's writes read nothing")
    XCTAssertEqual(pullRequestBranches.count, asked)

    gitDirectory.onChange([root + "/.git/worktrees/feature/index"], false)
    await status.followedStatusSettled()
    XCTAssertEqual(reads.count, 1, "its own index re-reads Changes")
    XCTAssertEqual(pullRequestBranches.count, asked, "and asks GitHub nothing")

    gitDirectory.onChange([root + "/.git/refs/heads/feature"], false)
    await status.followedStatusSettled()
    XCTAssertEqual(pullRequestBranches.count, asked + 1, "a ref asks GitHub")
  }

  // MARK: Unfollow grace (#812 perf lane P3)

  /// Value: protects=focus moving between panes in two repositories (perf-files note);
  /// fails_when=the last unfollow drops the watch at once, so a re-follow sets it up and asks
  /// GitHub again, or the grace keeps the right to write; why_new=#812 perf review;
  /// seam=VCSStatusService follow/unfollow + writeLocation; no_claim=the router's own refusals
  func testAReFollowInsideTheGraceReusesTheWatchAndStatusButNotTheWrite() async throws {
    let status = makeStatus(onGitHub: true)
    status.followedUnfollowGrace = 3600
    let root = repo("app")
    status.follow(root)
    await status.followedStatusSettled()
    await status.followedRegistrationsSettled()
    let watch = try XCTUnwrap(watcher(for: root))
    let hold = try XCTUnwrap(status.followedHold(of: root))
    let watches = watchers.count
    let reads = countReads(status)
    let gitHubRuns = runner.gitHubRuns.withLock { $0 }

    status.unfollow(root)
    XCTAssertFalse(watch.stopped, "the watch outlives the unfollow")
    XCTAssertNotNil(status.followedStatuses[root], "so does the status")
    XCTAssertFalse(status.isFollowing(root))
    XCTAssertFalse(status.canAddress(.followed(root: root)))
    XCTAssertNil(status.followedHold(of: root))
    let refused = await status.followedWriteLocation(root)
    XCTAssertNil(refused, "nothing writes through a repository no window follows")
    do {
      _ = try await status.writeLocation(for: .followed(root: root))
      XCTFail("refused")
    } catch is FollowedRepositoryGone {}
    await status.followedRegistrationsSettled()
    XCTAssertNil(RepositoryRouter.shared.localLocation(for: root), "the router lets go at once")

    status.follow(root)
    await status.followedStatusSettled()
    await status.followedRegistrationsSettled()
    XCTAssertEqual(watchers.count, watches, "no new watch")
    XCTAssertFalse(watch.stopped)
    XCTAssertEqual(reads.count, 0, "no status read")
    XCTAssertEqual(runner.gitHubRuns.withLock { $0 }, gitHubRuns, "and no GitHub round")
    XCTAssertTrue(status.isFollowing(root))
    let renewed = try XCTUnwrap(status.followedHold(of: root))
    XCTAssertNotEqual(renewed, hold, "a write captured before the unfollow stays refused")
    let live = await status.followedWriteLocation(root)
    XCTAssertEqual(live.map { VCSStatusService.canonicalPath($0.path) }, root)

    status.followedUnfollowGrace = 0
    status.unfollow(root)
    XCTAssertTrue(watch.stopped)
    await status.followedRegistrationsSettled()
    XCTAssertNil(RepositoryRouter.shared.localLocation(for: root))
  }

  /// Value: protects=the grace costing nothing and ending (perf-files note); fails_when=a change
  /// while no window follows reads or asks GitHub, a re-follow after one shows it stale, or the
  /// watch and status outlive the grace; why_new=#812 perf review; seam=VCSStatusService;
  /// no_claim=the 10 s figure
  func testAChangeInTheGraceWaitsForAReFollowAndTheGraceEnds() async throws {
    let status = makeStatus(onGitHub: true)
    status.followedUnfollowGrace = 3600
    let root = repo("app")
    status.follow(root)
    await status.followedStatusSettled()
    let watch = try XCTUnwrap(watcher(for: root))
    let reads = countReads(status)
    status.unfollow(root)

    sh("git commit -qam second", in: root)
    watch.onChange([root + "/.git/refs/heads/main"], false)
    await status.followedStatusSettled()
    XCTAssertEqual(reads.count, 0, "nothing reads while no window follows it")
    XCTAssertEqual(pullRequestBranches, ["main"])

    status.follow(root)
    await status.followedStatusSettled()
    XCTAssertEqual(reads.count, 1, "the re-follow reads what changed")
    XCTAssertEqual(pullRequestBranches, ["main", "main"])
    XCTAssertEqual(status.followedStatuses[root]?.changedFiles, [])

    status.followedUnfollowGrace = 0.01
    status.unfollow(root)
    XCTAssertFalse(watch.stopped)
    await status.followedGraceSettled()
    XCTAssertTrue(watch.stopped, "the grace ends")
    XCTAssertNil(status.followedStatuses[root])
    XCTAssertFalse(status.isFollowing(root))
  }

  // MARK: The registered-path index (offactor review)

  /// Value: protects=the index always ending on the current project list (offactor review I1);
  /// fails_when=a list that goes A, B and back to A while B's build is stalled installs B's index
  /// over A's, or a repository followed while B's build was out is never probed; why_new=review;
  /// seam=VCSStatusService's canonicaliser (stalled on B's path only); no_claim=a real network
  /// mount
  func testAListThatGoesAToBAndBackNeverInstallsBsIndex() async throws {
    let a = repo("a")
    let b = folder("b")
    let other = repo("other")
    let status = makeStatus()
    let guarded = GuardedCanonicaliser(stalled: b)
    defer { guarded.release() }
    status.canonicalise = guarded.canonicalise
    status.registeredPathTimeout = 5
    let listA = [Project(path: a, vcs: "git", workrooms: [])]
    projects.projects = listA
    await status.registeredIndexSettled()

    projects.projects = listA + [Project(path: b, vcs: "git", workrooms: [])]
    status.rebuildRegisteredIndex()
    let buildB = try XCTUnwrap(status.registeredIndexBuild?.task)
    status.follow(other)
    projects.projects = listA
    status.rebuildRegisteredIndex()
    guarded.release()
    await buildB.value
    // Read before any settle, which would rebuild for the current list and hide a stale install.
    XCTAssertEqual(status.registeredIndex?.projects, listA, "B's build landing installs nothing")
    XCTAssertNil(status.registeredSidebarID(forCanonicalRoot: b))
    await status.registeredIndexSettled()

    await status.followedStatusSettled()
    XCTAssertEqual(status.registeredIndex?.projects, listA, "A's list stays indexed")
    XCTAssertNil(status.registeredSidebarID(forCanonicalRoot: b), "B's build never lands")
    XCTAssertEqual(status.registeredSidebarID(forCanonicalRoot: a), .root(project: a))
    XCTAssertEqual(
      status.followedStatuses[other]?.changedFiles?.map(\.path), ["src/a.txt"],
      "followed while B's build was out, and probed once the list is A's again")
    status.unfollow(other)
    await status.followedRegistrationsSettled()
  }

  /// Value: protects=a registered path whose `realpath` timed out healing on its own (offactor
  /// review N2); fails_when=a timed-out entry stays indexed by its literal path until some follow
  /// or project change; why_new=review; seam=VCSStatusService's canonicaliser (stalled) + the
  /// retry wait (recorded); no_claim=the real backoff's timing
  func testATimedOutRegisteredPathIsRetriedOnABackoff() async throws {
    let real = repo("real")
    let link = scratch.appendingPathComponent("link").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    let status = makeStatus()
    let guarded = GuardedCanonicaliser(stalled: link)
    defer { guarded.release() }
    status.canonicalise = guarded.canonicalise
    status.registeredPathTimeout = 0.2
    let streaks = Mutex<[Int]>([])
    // The wait is where the mount recovers.
    status.registeredIndexRetryWait = { streak in
      streaks.withLock { $0.append(streak) }
      guarded.release()
    }
    projects.projects = [Project(path: link, vcs: "git", workrooms: [])]
    await status.registeredIndexSettled()
    XCTAssertEqual(status.registeredIndex?.timedOut, [link])

    await status.registeredIndexRetry?.value
    await status.registeredIndexSettled()

    XCTAssertEqual(streaks.withLock { $0 }, [1])
    XCTAssertEqual(status.registeredIndex?.timedOut, [])
    XCTAssertEqual(status.registeredSidebarID(forCanonicalRoot: real), .root(project: link))
    XCTAssertNil(status.registeredIndexRetry, "a clean build schedules no retry")
  }

  /// Value: protects=a registered row followed before the index lands never being read as
  /// unregistered (offactor review N3); fails_when=it gets a status of its own (or a recent one)
  /// while its source is unknown, or an unregistered repository followed meanwhile is never
  /// probed once it lands; why_new=review; seam=VCSStatusService follow + the canonicaliser
  /// (stalled); no_claim=the sidebar's rendering
  func testARepositoryFollowedBeforeTheIndexLandsWaitsForIt() async throws {
    let registered = repo("registered")
    let other = repo("other")
    let status = makeStatus()
    await status.registeredIndexSettled()
    let guarded = GuardedCanonicaliser(stalled: registered)
    defer { guarded.release() }
    status.canonicalise = guarded.canonicalise
    status.registeredPathTimeout = 5
    projects.projects = [Project(path: registered, vcs: "git", workrooms: [])]
    status.rebuildRegisteredIndex()

    status.follow(registered)
    status.follow(other)
    status.handleFollowedRepositoryChange(registered, paths: [], overflow: true)
    XCTAssertNil(status.followedStatuses[registered], "no status of its own while it waits")
    XCTAssertNil(status.followedStatuses[other])
    guarded.release()
    await status.followedStatusSettled()

    let row = SidebarID.root(project: registered)
    XCTAssertNil(status.followedStatuses[registered])
    XCTAssertNil(status.recentFollowedStatuses.value(for: registered), "nor a recent one")
    XCTAssertEqual(status.workroomStatuses[row]?.changedFiles?.map(\.path), ["src/a.txt"])
    XCTAssertEqual(
      status.followedStatuses[other]?.changedFiles?.map(\.path), ["src/a.txt"],
      "one unregistered is probed once the index lands")
    status.unfollow(registered)
    status.unfollow(other)
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
  }

  /// Value: protects=Changes leaving "Checking…" once a commit ends, for a repository re-routed
  /// while it committed (offactor review N4); fails_when=the re-route's probe, held off by the
  /// commit, waits for a watch event; why_new=review; seam=VCSStatusService's commit marks + the
  /// project list; no_claim=the commit itself
  func testARepositoryReRoutedWhileItCommitsIsProbedWhenTheCommitEnds() async throws {
    let root = repo("app")
    projects.projects = [Project(path: root, vcs: "git", workrooms: [])]
    let status = makeStatus()
    status.follow(root)
    await status.followedRegistrationsSettled()
    await status.followedStatusSettled()
    XCTAssertNil(status.followedStatuses[root], "in place")
    let shared = try XCTUnwrap(status.followedSharedLocation(root))

    status.beginCommit(.followed(root: root), root: shared)
    projects.projects = []
    await status.followedStatusSettled()
    XCTAssertEqual(status.followedStatuses[root], .unresolved, "held off while it commits")

    status.endCommit(.followed(root: root), root: shared)
    await status.followedStatusSettled()

    XCTAssertEqual(status.followedStatuses[root]?.changedFiles?.map(\.path), ["src/a.txt"])
    status.unfollow(root)
    await status.followedRegistrationsSettled()
  }
}
