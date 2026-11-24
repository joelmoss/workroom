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
    init(onGitHub: Bool) { self.onGitHub = onGitHub }
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      guard executable == "gh" else {
        return await real.run(executable, args, in: directory, timeout: timeout)
      }
      if args.prefix(2) == ["pr", "list"] {
        let branch = args.firstIndex(of: "--head").map { args.index(after: $0) }
          .flatMap { args.indices.contains($0) ? args[$0] : nil }
        pullRequestLists.withLock { $0.append(branch) }
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

  private func makeStatus(onGitHub: Bool = false, debounce: TimeInterval = 0) -> VCSStatusService {
    let status = VCSStatusService(projectStore: projects)
    runner = GitHubRunner(onGitHub: onGitHub)
    status.statusResolver = WorkroomStatusResolver(runner: runner)
    status.followedProbeDebounce = debounce
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
    XCTAssertEqual(status.registeredSidebarID(forRepositoryRoot: root), row)
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
    XCTAssertEqual(status.registeredSidebarID(forRepositoryRoot: root), row)
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

    sh("git switch -q main", in: root)
    try XCTUnwrap(store.terminals.surface(tab)).onEvent?(.commandFinished(0))
    await settle(store)
    guard case .followed(let afterCommand) = store.inspectorSubject else { return XCTFail() }
    XCTAssertEqual(afterCommand.repository?.branch, "main")
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
    XCTAssertGreaterThan(counted.withLock { $0 }, before, "a new project rebuilds the index")
  }

  /// Value: protects=arrow-keying past terminals in different repositories (review of #807,
  /// finding 5); fails_when=a repository followed for less than the selection's debounce forks
  /// git and gh; why_new=review; seam=VCSStatusService follow/unfollow (gh stubbed);
  /// no_claim=the folder's resolve
  func testARepositoryPassedByQuicklyIsNotProbed() async throws {
    let status = makeStatus(onGitHub: true, debounce: 0.3)
    let one = repo("one", branch: "passed-by")
    let two = repo("two")

    status.follow(one)
    status.unfollow(one)
    status.follow(two)
    await status.followedStatusSettled()

    XCTAssertEqual(pullRequestBranches, ["main"], "only the repository stayed on is asked about")
    XCTAssertEqual(status.followedStatuses[two]?.changedFiles?.map(\.path), ["src/a.txt"])
  }
}
