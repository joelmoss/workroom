import Synchronization
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// A standalone terminal's inspector follows its terminal's folder (#805, ADR 0081): the subject is
/// the folder the shell is in (OSC 7, else the folder it started in) and the innermost git
/// repository containing it, and History reads that repository. Real throwaway repositories on
/// disk; the folder arrives through the surface's pwd handler, as a shell's report does.
@MainActor
final class StandaloneFollowsFolderTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  private var scratch: URL!

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(
      sh("command -v git", in: NSTemporaryDirectory()).exit != 0, "git is not installed")
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
    // Canonical (`/private/var/...`), as git names a repository's root: `realpath`, not
    // `resolvingSymlinksInPath`, which strips `/private` back off.
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("follows-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    let canonical = try XCTUnwrap(realpath(made.path, nil))
    defer { free(canonical) }
    scratch = URL(fileURLWithPath: String(cString: canonical))
  }

  override func tearDown() async throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    try await super.tearDown()
  }

  // MARK: Store

  private final class CountingProvider: LocalVCSProviding, Sendable {
    private let roots = Mutex<[String]>([])
    /// The roots History read a log of, in order.
    var logRoots: [String] { roots.withLock { $0 } }
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
      roots.withLock { $0.append(root.path) }
      return VCSHistoryPage(commits: [], reachedEnd: true)
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("x")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
      throw VCSError.io("x")
    }
    func workingFileDiff(root: URL, path: String) async throws -> String { throw VCSError.io("x") }
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private let provider = CountingProvider()

  /// A window store with History showing, its log read through `provider`.
  /// `realHistory`: History reads through the repository router, as the app does, not `provider`.
  private func makeStore(realHistory: Bool = false) -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section,
      commitHistory: realHistory
        ? HistoryModel() : HistoryModel(resolve: { [provider] _ in provider }))
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

  /// Open a standalone terminal in `store` and return its one terminal tab.
  private func openTerminal(_ store: AppStore) async throws -> TerminalTab {
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.selectedTarget)
    guard case .standalone = target.id else { throw XCTSkip("not a standalone terminal") }
    await store.followedFolderResolved()
    return try XCTUnwrap(store.terminals.tabs(for: target).first)
  }

  /// The shell in `tab` reports `folder` (OSC 7); wait for its repository to resolve.
  private func cd(_ store: AppStore, _ tab: TerminalTab, _ folder: String) async throws {
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder)
    await store.followedFolderResolved()
    await store.commitHistory.awaitCurrentLoad()
  }

  private func followed(
    _ store: AppStore, file: StaticString = #filePath, line: UInt = #line
  ) -> FollowedFolder? {
    guard case .followed(let followed) = store.inspectorSubject else {
      XCTFail("subject is \(store.inspectorSubject)", file: file, line: line)
      return nil
    }
    return followed
  }

  // MARK: Repositories on disk

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> (out: String, exit: Int32) {
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
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
  }

  /// A folder under the scratch directory, made.
  private func folder(_ name: String) -> String {
    let path = scratch.appendingPathComponent(name).path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// A git repository with one commit on `branch`, and a `src/lib` folder inside it.
  private func repo(_ name: String, branch: String = "main") -> String {
    let dir = folder(name)
    sh("git init -q -b \(branch) .", in: dir)
    try? FileManager.default.createDirectory(
      atPath: dir + "/src/lib", withIntermediateDirectories: true)
    try? "x\n".write(toFile: dir + "/src/lib/a.txt", atomically: true, encoding: .utf8)
    sh("git add -A && git commit -qm base", in: dir)
    return dir
  }

  // MARK: Following a cd

  /// Value: protects=the inspector naming the repo the shell is in (stories 1, 2, 18);
  /// fails_when=a standalone terminal still has nothing to inspect, or names the folder's own path
  /// rather than the repo's root; why_new=#805; seam=AppStore; no_claim=the header's rendering
  func testACdIntoARepositoryFollowsItsFolderAndRepository() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app", branch: "feature/x")

    try await cd(store, tab, root + "/src")

    let subject = followed(store)
    XCTAssertEqual(subject?.folder, root + "/src")
    XCTAssertEqual(subject?.repository?.root, root)
    XCTAssertEqual(subject?.repository?.branch, "feature/x")
    XCTAssertEqual(subject?.repository?.isWritable, true)
    XCTAssertNil(store.inspectorTargetID, "a followed folder is no sidebar item")
    XCTAssertEqual(store.inspectorHistoryTarget?.path, root, "History reads the repository")
    XCTAssertEqual(provider.logRoots.last, root)
  }

  /// Value: protects=History not reloading on a cd inside one repo, and switching on a cd into
  /// another (stories 3, 4); fails_when=a same-repo cd re-reads the log, or a repo switch keeps the
  /// old one; why_new=#805; seam=AppStore + HistoryModel; no_claim=Changes and Pull Request (#807)
  func testACdWithinARepositoryKeepsHistoryAndACdToAnotherSwitchesIt() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let first = repo("one")
    let second = repo("two")

    try await cd(store, tab, first)
    let reads = provider.logRoots.count
    let key = store.inspectorSubject.repositoryKey

    try await cd(store, tab, first + "/src/lib")
    XCTAssertEqual(followed(store)?.folder, first + "/src/lib", "the folder follows")
    XCTAssertEqual(store.inspectorSubject.repositoryKey, key)
    XCTAssertEqual(provider.logRoots.count, reads, "a cd within one repository reads no log")

    try await cd(store, tab, second + "/src")
    XCTAssertEqual(followed(store)?.repository?.root, second)
    XCTAssertEqual(provider.logRoots.last, second, "History switches to the new repository")
  }

  /// Value: protects=the not-a-repo state (story 19); fails_when=a plain folder reads as a repo,
  /// or History keeps the last repo; why_new=#805; seam=AppStore; no_claim=its copy
  func testAFolderOutsideAnyRepositoryHasNoRepository() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let plain = folder("plain/deeper")
    try await cd(store, tab, repo("app"))

    try await cd(store, tab, plain)

    let subject = followed(store)
    XCTAssertEqual(subject?.folder, plain)
    XCTAssertNil(subject?.repository)
    XCTAssertNil(store.inspectorHistoryTarget, "History has no repository to read")
    XCTAssertNil(store.commitHistory.root, "and empties")
  }

  /// Value: protects=the innermost repo winning (stories 25, 26); fails_when=a nested repo, a
  /// linked worktree or a submodule resolves to its outer repository; why_new=#805;
  /// seam=AppStore over real git; no_claim=git's own resolution beyond these three shapes
  func testTheInnermostRepositoryWinsForNestedWorktreeAndSubmodule() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let outer = repo("outer")
    // A repository nested inside another's working tree, not a submodule.
    let nested = outer + "/vendor/inner"
    try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
    sh("git init -q -b main . && git commit -q --allow-empty -m base", in: nested)
    // A linked worktree of `outer`, on a branch of its own.
    let worktree = scratch.appendingPathComponent("outer-wt").path
    sh("git worktree add -q -b wt \(worktree)", in: outer)
    // A submodule of a fresh superproject.
    let superproject = repo("super")
    let library = repo("library")
    sh(
      "git -c protocol.file.allow=always submodule add -q \(library) lib && git commit -qm sub",
      in: superproject)

    try await cd(store, tab, nested)
    XCTAssertEqual(followed(store)?.repository?.root, nested, "a nested repository")

    try await cd(store, tab, worktree + "/src")
    XCTAssertEqual(followed(store)?.repository?.root, worktree, "a linked worktree")
    XCTAssertEqual(followed(store)?.repository?.branch, "wt", "on its own branch")

    try await cd(store, tab, superproject + "/lib/src")
    XCTAssertEqual(followed(store)?.repository?.root, superproject + "/lib", "a submodule")
  }

  /// Value: protects=the launch-folder fallback (story 27); fails_when=a shell that hasn't
  /// reported a folder leaves the inspector empty; why_new=#805; seam=AppStore; no_claim=which
  /// folder new terminals open in (Settings)
  func testAShellThatHasNotReportedAFolderFollowsTheFolderItStartedIn() async throws {
    let store = makeStore()
    _ = try await openTerminal(store)

    XCTAssertEqual(followed(store)?.folder, TerminalsSection.newTerminalDirectory())
  }

  /// Value: protects=the inspector keeping the last local folder after an `ssh` (story 34);
  /// fails_when=a remote command's reports blank or move the subject; why_new=#805; seam=AppStore
  /// (libghostty sends no pwd for a foreign host, so only the command's own events arrive);
  /// no_claim=libghostty's filtering
  func testAnSshSessionKeepsTheLastLocalFolder() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let before = store.inspectorSubject

    let surface = try XCTUnwrap(store.terminals.surface(tab))
    surface.onEvent?(.titleChanged("ssh build-host"))
    surface.onEvent?(.commandFinished(0))
    await store.followedFolderResolved()

    XCTAssertEqual(store.inspectorSubject, before)
  }

  /// Value: protects=a commit opened from a followed repo's History reading that repo (story 1);
  /// fails_when=its changeset tab reads the folder the terminal opened in; why_new=#805;
  /// seam=AppStore's content tabs; no_claim=the detail view's own load
  func testACommitOpenedFromFollowedHistoryReadsTheFollowedRepository() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    let target = try XCTUnwrap(store.selectedTarget)

    store.openChangesetPersistent(commitID: "abc", title: "base")

    let opened = store.terminals.tabs(for: target).compactMap { tab -> ChangesetDescriptor? in
      if case .changeset(let changeset) = tab.content { return changeset }
      return nil
    }
    XCTAssertEqual(opened.map(\.repositoryRoot), [root])
    XCTAssertEqual(
      followed(store)?.repository?.root, root,
      "with the changeset focused, the terminal it was opened from is still followed")
  }

  /// Value: protects=History loading a followed repo's log through the app's real read path, for
  /// a plain repo, a linked worktree and a submodule (stories 1, 25, 26); fails_when=the router
  /// can't read an unregistered root whose `.git` is a file; why_new=#805; seam=AppStore +
  /// HistoryModel over the repository router; no_claim=paging
  func testHistoryReadsAFollowedRepositorysLogThroughTheRouter() async throws {
    let store = makeStore(realHistory: true)
    let tab = try await openTerminal(store)
    let plain = repo("plain")
    let worktree = scratch.appendingPathComponent("plain-wt").path
    sh("git worktree add -q -b wt \(worktree) && git commit -q --allow-empty -m one", in: plain)
    sh("git commit -q --allow-empty -m wt-only", in: worktree)
    let superproject = repo("super")
    sh(
      "git -c protocol.file.allow=always submodule add -q \(repo("library")) lib"
        + " && git commit -qm sub", in: superproject)

    for (folder, summary) in [
      (plain + "/src", "one"), (worktree, "wt-only"), (superproject + "/lib", "base"),
    ] {
      try await cd(store, tab, folder)
      XCTAssertEqual(
        store.commitHistory.commits.first?.summary, summary, "the log of \(folder)'s repository")
    }
  }

  /// Value: protects=every other git read keeping the ceiling that stops it finding an ANCESTOR
  /// repository (negative control for lifting it in the one resolve); fails_when=the lift leaks
  /// into the runner, so a commit aimed at a broken workroom lands in its parent; why_new=#805;
  /// seam=GitRepositoryProbe + StatusCommandRunner; no_claim=the daemon-routed runner
  func testOnlyTheFollowedResolveLooksAboveItsFolder() async throws {
    let root = repo("app")
    let sub = root + "/src/lib"

    let resolved = await GitRepositoryProbe().repository(containing: sub)
    let plain = await StatusCommandRunner().run(
      "git", ["rev-parse", "--show-toplevel"], in: sub, timeout: 5)

    XCTAssertEqual(resolved?.root, root, "the resolve finds the repository above the folder")
    XCTAssertFalse(plain.ok, "a plain read in a subfolder still stops at the ceiling")
  }

  /// Returns one canned result for every command.
  private struct CannedRunner: StatusCommandRunning {
    let result: CommandResult
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    { result }
  }

  /// Real git with no per-call environment, as the daemon-routed runner has none.
  private struct NoEnvironmentRunner: StatusCommandRunning {
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    { await StatusCommandRunner().run(executable, args, in: directory, timeout: timeout) }
  }

  /// Value: protects=the followed repository being the one the folder is in (review finding 1);
  /// fails_when=a `core.worktree` pointing elsewhere makes the folder resolve to an unrelated
  /// repository, or to a plain folder shown as a detached checkout; why_new=#805 review;
  /// seam=GitRepositoryProbe over real git; no_claim=a submodule (its own test keeps it resolving)
  func testAWorkTreeSetElsewhereIsNotTheFolderRepository() async throws {
    let other = repo("other")
    let plain = folder("plain")
    let pointsAtRepo = repo("holder")
    sh("git config core.worktree \(other)", in: pointsAtRepo)
    let pointsAtPlain = repo("holder2")
    sh("git config core.worktree \(plain)", in: pointsAtPlain)
    let probe = GitRepositoryProbe()

    let atRepo = await probe.discoverRepository(containing: folder("holder/sub"))
    let atPlain = await probe.discoverRepository(containing: folder("holder2/sub"))

    XCTAssertEqual(atRepo, .notARepository, "not the unrelated repository its work tree names")
    XCTAssertEqual(atPlain, .notARepository, "not a plain folder read as a detached checkout")
    let own = await probe.repository(containing: other + "/src")
    XCTAssertEqual(own?.root, other, "the work tree's own repository still resolves from inside")
  }

  /// Value: protects=telling "not a repository" from "couldn't tell" (review finding 3);
  /// fails_when=a timeout, a failed spawn or a refused (dubious-ownership) repository reads as no
  /// repository; why_new=#805 review; seam=GitRepositoryProbe; no_claim=the inspector's copy
  func testCouldNotTellIsNotNotARepository() async throws {
    let app = repo("app")
    func probe(_ result: CommandResult) -> GitRepositoryProbe {
      GitRepositoryProbe(discoveryRunner: CannedRunner(result: result))
    }

    // git's own answer for a repository owned by someone else, canned: on CI, real git with
    // GIT_TEST_ASSUME_DIFFERENT_OWNER=1 still returned the repository, so it can't produce it there.
    let refused = await probe(
      CommandResult(
        stdout: "",
        stderr: "fatal: detected dubious ownership in repository at '\(app)'\n"
          + "To add an exception for this directory, call:\n\n"
          + "\tgit config --global --add safe.directory \(app)\n",
        exitCode: CommandResult.gitFatal, timedOut: false)
    ).discoverRepository(containing: app + "/src")
    let timedOut = await probe(
      CommandResult(stdout: "", stderr: "", exitCode: 15, timedOut: true, signaled: true)
    ).discoverRepository(containing: app)
    let notLaunched = await probe(
      CommandResult(stdout: "", stderr: "", exitCode: CommandResult.launchFailed, timedOut: false)
    ).discoverRepository(containing: app)
    let plain = await GitRepositoryProbe().discoverRepository(containing: folder("plain"))
    let insideGitDir = await GitRepositoryProbe().discoverRepository(containing: app + "/.git")
    let gone = await GitRepositoryProbe().discoverRepository(containing: app + "/no-such-folder")

    XCTAssertEqual(refused, .unknown, "git refused a repository it found")
    XCTAssertEqual(timedOut, .unknown)
    XCTAssertEqual(
      notLaunched, .unknown, "the folder is there, so git failing to start says nothing")
    XCTAssertEqual(plain, .notARepository)
    XCTAssertEqual(insideGitDir, .notARepository)
    XCTAssertEqual(gone, .notARepository)
  }

  /// Value: protects=the subject naming the folder the terminal is in when git can't tell (re-review
  /// R1); fails_when=a `cd` into a folder git can't read keeps showing the previous folder's
  /// repository (History, Details and writes addressing the wrong repository), the undetermined
  /// state is cached, every event re-runs git, or it is never retried; why_new=#805 re-review;
  /// seam=AppStore; no_claim=the copy the panels show
  func testAFolderThatCannotTellShowsItselfUndeterminedAndRetries() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")
    let refused = repo("refused")
    try await cd(store, tab, app)
    let fails = Mutex(true)
    let resolves = Mutex(0)
    let retries = Gate()
    let streaks = Mutex<[Int]>([])
    store.followedFolderRetryWait = { streak in
      streaks.withLock { $0.append(streak) }
      await retries.pass()
    }
    store.resolveFollowedRepository = { folder in
      resolves.withLock { $0 += 1 }
      if fails.withLock({ $0 }) { return .unknown }
      return await GitRepositoryProbe().discoverRepository(containing: folder)
    }

    try await cd(store, tab, refused)
    XCTAssertEqual(followed(store)?.folder, refused, "the subject moves to the new folder")
    XCTAssertNil(followed(store)?.repository, "not the previous folder's repository")
    XCTAssertEqual(followed(store)?.repositoryUndetermined, true)
    XCTAssertNil(store.inspectorHistoryTarget, "History addresses no repository")
    XCTAssertNil(store.followedRepositoryRoot)
    XCTAssertNil(store.followedFolder.cache[refused], "and nothing is cached for the folder")

    // Focus and tab events meanwhile wait for the retry rather than each re-running git.
    store.refreshFollowedFolder()
    store.refreshFollowedFolder()
    await store.followedFolderResolved()
    XCTAssertEqual(resolves.withLock { $0 }, 1, "events before the retry run no git")

    retries.open()
    await store.followedFolderRetried()
    XCTAssertEqual(resolves.withLock { $0 }, 2, "the retry asks again")
    XCTAssertEqual(followed(store)?.repositoryUndetermined, true, "and still can't tell")

    fails.withLock { $0 = false }
    retries.open()
    await store.followedFolderRetried()
    XCTAssertEqual(streaks.withLock { $0 }, [1, 2], "each retry counts the failures before it")
    XCTAssertEqual(
      [1, 2, 3, 6, 9].map(FollowedFolderTracker.retryDelay),
      [.seconds(2), .seconds(4), .seconds(8), .seconds(60), .seconds(60)],
      "and waits longer for each, up to a minute")
    XCTAssertEqual(followed(store)?.repository?.root, refused, "the retry resolves it")
    XCTAssertEqual(followed(store)?.repositoryUndetermined, false)
  }

  /// Value: protects=a first visit whose resolve can't tell showing the folder undetermined, not
  /// pending for good (review C1); fails_when=the pending folder shown at once is taken for the
  /// folder already shown, so the answer never replaces it; why_new=#803 code review;
  /// seam=AppStore; no_claim=the retry (testAFolderThatCannotTellShowsItselfUndeterminedAndRetries)
  func testAFirstVisitThatCannotTellShowsTheFolderUndetermined() async throws {
    let store = makeStore()
    store.followedFolderRetryWait = { _ in try? await Task.sleep(for: .seconds(3600)) }
    store.resolveFollowedRepository = { _ in .unknown }

    store.newTerminalInSelectedTarget()
    XCTAssertEqual(followed(store)?.repositoryPending, true)
    await store.followedFolderResolved()

    XCTAssertEqual(followed(store)?.repositoryPending, false)
    XCTAssertEqual(followed(store)?.repositoryUndetermined, true)
    store.followedFolder.retryTask?.cancel()
  }

  // MARK: Delayed loader

  /// Value: protects=a slow repository lookup showing the sections' loader after a short delay, and
  /// dropping it on the answer (#803 polish); fails_when=the loader shows at once, never shows, or
  /// outlives the answer; why_new=#803 owner's UI decision; seam=AppStore; no_claim=the panels'
  /// rendering
  func testASlowLookupShowsTheLoaderOnlyAfterTheDelay() async throws {
    let store = makeStore()
    let delay = Gate()
    let lookup = Gate()
    store.followedFolderLoaderWait = { await delay.pass() }
    store.resolveFollowedRepository = { _ in
      await lookup.pass()
      return .notARepository
    }

    store.newTerminalInSelectedTarget()
    XCTAssertEqual(followed(store)?.repositoryPending, true)
    XCTAssertFalse(store.followedFolderLoaderShown, "blank before the delay")

    delay.open()
    await store.followedFolderLoaderElapsed()
    XCTAssertTrue(store.followedFolderLoaderShown, "the loader after it")

    lookup.open()
    await store.followedFolderResolved()
    XCTAssertEqual(followed(store)?.repositoryPending, false)
    XCTAssertFalse(store.followedFolderLoaderShown, "gone with the answer")
    XCTAssertEqual(FollowedFolderTracker.loaderDelay, .milliseconds(300))
  }

  /// Value: protects=a fast answer never flashing the loader (#803 polish); fails_when=the delay
  /// elapsing after the answer still shows it; why_new=#803 owner's UI decision; seam=AppStore;
  /// no_claim=the panels' rendering
  func testAFastLookupNeverShowsTheLoader() async throws {
    let store = makeStore()
    let delay = Gate()
    store.followedFolderLoaderWait = { await delay.pass() }
    store.resolveFollowedRepository = { _ in .notARepository }

    store.newTerminalInSelectedTarget()
    let wait = try XCTUnwrap(store.followedFolder.loaderTask, "the delay starts with the lookup")
    await store.followedFolderResolved()
    delay.open()
    await wait.value

    XCTAssertFalse(store.followedFolderLoaderShown)
  }

  /// Value: protects=the loader staying up across a cd while still pending, and restarting its
  /// delay after the terminal is left mid-lookup (#803 polish); fails_when=a cd blinks the loader
  /// off, or a return shows it at once; why_new=#803 owner's UI decision; seam=AppStore;
  /// no_claim=the panels' rendering
  func testTheLoaderSurvivesACdAndRestartsAfterLeavingTheTerminal() async throws {
    let store = makeStore()
    let delay = Gate()
    let lookup = Gate()
    store.followedFolderLoaderWait = { await delay.pass() }
    store.resolveFollowedRepository = { _ in
      await lookup.pass()
      return .notARepository
    }
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.selectedTarget)
    let terminal = try XCTUnwrap(store.selectedTargetID)
    let tab = try XCTUnwrap(store.terminals.tabs(for: target).first)
    delay.open()
    await store.followedFolderLoaderElapsed()
    XCTAssertTrue(store.followedFolderLoaderShown)

    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder("elsewhere"))
    XCTAssertEqual(followed(store)?.repositoryPending, true)
    XCTAssertTrue(store.followedFolderLoaderShown, "a cd while pending keeps the loader")

    store.terminals.addTab(for: try XCTUnwrap(store.target(for: workroom)))
    store.selectedTargetID = workroom
    XCTAssertFalse(store.followedFolderLoaderShown)
    store.selectedTargetID = terminal
    XCTAssertEqual(followed(store)?.repositoryPending, true)
    XCTAssertFalse(store.followedFolderLoaderShown, "a return waits out the delay again")
    delay.open()
    await store.followedFolderLoaderElapsed()
    XCTAssertTrue(store.followedFolderLoaderShown)

    for _ in 0..<3 { lookup.open() }
    await store.followedFolderResolved()
    XCTAssertFalse(store.followedFolderLoaderShown)
  }

  /// Value: protects=a lookup that can't tell dropping the loader for its message (#803 polish);
  /// fails_when=the undetermined folder keeps the loader up; why_new=#803 owner's UI decision;
  /// seam=AppStore; no_claim=the retry
  func testALookupThatCannotTellDropsTheLoader() async throws {
    let store = makeStore()
    let delay = Gate()
    let lookup = Gate()
    store.followedFolderLoaderWait = { await delay.pass() }
    store.followedFolderRetryWait = { _ in try? await Task.sleep(for: .seconds(3600)) }
    store.resolveFollowedRepository = { _ in
      await lookup.pass()
      return .unknown
    }
    store.newTerminalInSelectedTarget()
    delay.open()
    await store.followedFolderLoaderElapsed()
    XCTAssertTrue(store.followedFolderLoaderShown)

    lookup.open()
    await store.followedFolderResolved()
    XCTAssertEqual(followed(store)?.repositoryUndetermined, true)
    XCTAssertFalse(store.followedFolderLoaderShown)
    store.followedFolder.retryTask?.cancel()
  }

  /// One waiter let through per `open()`, whichever comes first.
  private final class Gate: Sendable {
    private let state = Mutex<(permits: Int, waiters: [CheckedContinuation<Void, Never>])>((0, []))
    func pass() async {
      await withCheckedContinuation { continuation in
        let passes = state.withLock { s -> Bool in
          if s.permits > 0 {
            s.permits -= 1
            return true
          }
          s.waiters.append(continuation)
          return false
        }
        if passes { continuation.resume() }
      }
    }
    func open() {
      let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
        if s.waiters.isEmpty {
          s.permits += 1
          return nil
        }
        return s.waiters.removeFirst()
      }
      waiter?.resume()
    }
  }

  /// Value: negative control for R1: protects=a re-read of the folder already shown keeping its
  /// repository when git can't tell this time; fails_when=a transient timeout on a re-read (a
  /// watch event, a finished command) blanks the repository shown; why_new=#805 re-review;
  /// seam=AppStore; no_claim=the retry's timing
  func testAReReadThatCannotTellKeepsTheRepositoryShown() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")
    try await cd(store, tab, app)
    store.followedFolderRetryWait = { _ in try? await Task.sleep(for: .seconds(3600)) }
    store.resolveFollowedRepository = { _ in .unknown }

    store.reresolveFollowedFolder()
    await store.followedFolderResolved()

    XCTAssertEqual(followed(store)?.repository?.root, app)
    XCTAssertEqual(followed(store)?.repositoryUndetermined, false)
    store.followedFolder.retryTask?.cancel()
  }

  /// Value: protects=a wedged mount costing one blocked thread, not one per event (re-review R2);
  /// fails_when=every resolve of a folder whose stat never returns blocks another GCD thread, until
  /// the global pool starves History and status reads; why_new=#805 re-review;
  /// seam=GitRepositoryProbe with a stat that blocks; no_claim=git runs (the runner kills those)
  func testAStuckFolderBlocksOneReadHoweverOftenItIsAsked() async throws {
    let app = repo("app")
    let gate = DispatchSemaphore(value: 0)
    let blocks = Mutex(true)
    let stats = Mutex(0)
    let probe = GitRepositoryProbe(
      timeout: 0.1,
      isFolder: { path in
        stats.withLock { $0 += 1 }
        if blocks.withLock({ $0 }) { gate.wait() }
        return GitRepositoryProbe.isFolder(path)
      })
    defer {
      blocks.withLock { $0 = false }
      gate.signal()
    }

    for _ in 0..<5 {
      let discovered = await probe.discoverRepository(containing: app)
      XCTAssertEqual(discovered, .unknown, "the stat outruns its timeout")
    }
    XCTAssertEqual(stats.withLock { $0 }, 1, "one blocked read, joined by every later ask")

    blocks.withLock { $0 = false }
    gate.signal()
    // The blocked read's entry clears once it returns, and is shared by every probe. A default
    // timeout here, so a slow git spawn on a loaded runner never reads as couldn't tell.
    var discovered = GitRepositoryProbe.Discovery.unknown
    for _ in 0..<100 where discovered == .unknown {
      try await Task.sleep(for: .milliseconds(20))
      discovered = await GitRepositoryProbe().discoverRepository(containing: app)
    }
    guard case .repository(let found) = discovered else {
      return XCTFail("once the read returns, the folder resolves: \(discovered)")
    }
    XCTAssertEqual(found.root, app)
  }

  /// Value: protects=an unreachable main repository reading as "couldn't tell" (re-review R4);
  /// fails_when=a linked worktree whose `.git` file names a git directory that isn't there (an
  /// unmounted volume) is cached as no repository for the session; why_new=#805 re-review;
  /// seam=GitRepositoryProbe over real git; no_claim=a plain folder (its own test)
  func testAWorktreeWhoseRepositoryIsUnreachableCannotTell() async throws {
    let orphan = folder("orphan")
    try "gitdir: /nonexistent/\(UUID().uuidString)\n".write(
      toFile: orphan + "/.git", atomically: true, encoding: .utf8)

    let discovered = await GitRepositoryProbe().discoverRepository(containing: orphan)

    XCTAssertEqual(discovered, .unknown)
  }

  /// Value: protects=the resolve finding a repository above the folder over any runner (finding 5);
  /// fails_when=a runner that drops the per-call environment (the daemon's) makes every subfolder
  /// read as no repository; why_new=#805 review; seam=GitRepositoryProbe; no_claim=the daemon
  func testTheResolveLooksAboveTheFolderWhateverTheProbesRunner() async throws {
    let root = repo("app")

    let resolved = await GitRepositoryProbe(runner: NoEnvironmentRunner())
      .repository(containing: root + "/src/lib")

    XCTAssertEqual(resolved?.root, root)
  }

  /// Value: protects=the user's own discovery limits (finding 6); fails_when=a shell's
  /// `GIT_CEILING_DIRECTORIES` (a dotfiles repository at $HOME) is overridden, so the inspector
  /// shows a repository the user's prompt doesn't; why_new=#805 review; seam=GitRepositoryProbe;
  /// no_claim=how the login shell is probed
  func testTheUsersCeilingIsHonoured() async throws {
    let home = repo("home")
    let downloads = folder("home/Downloads")

    let limited = await GitRepositoryProbe(discoveryEnvironment: {
      GitRepositoryProbe.discoveryLimits(
        inherited: [:], probed: ["GIT_CEILING_DIRECTORIES": home])
    }).discoverRepository(containing: downloads)
    let unlimited = await GitRepositoryProbe(discoveryEnvironment: {
      GitRepositoryProbe.discoveryLimits(inherited: [:], probed: [:])
    }).repository(containing: downloads)

    XCTAssertEqual(limited, .notARepository)
    XCTAssertEqual(unlimited?.root, home, "negative control: with no ceiling it finds $HOME's")
    XCTAssertEqual(
      GitRepositoryProbe.discoveryLimits(
        inherited: ["GIT_CEILING_DIRECTORIES": "/a"],
        probed: ["GIT_CEILING_DIRECTORIES": "/b", "GIT_DISCOVERY_ACROSS_FILESYSTEM": "1"]),
      ["GIT_CEILING_DIRECTORIES": "/a", "GIT_DISCOVERY_ACROSS_FILESYSTEM": "1"],
      "the app's own environment wins over the probed shell's, as for network commands")
  }

  // MARK: Selection

  /// Value: protects=straight-away switches (stories 31, 32); fails_when=going back to the
  /// terminal waits on a resolve, or the workroom inspector changes; why_new=#805;
  /// seam=AppStore; no_claim=the panels' rendering
  func testWorkroomToTerminalToWorkroomShowsTheRightSubjectAtOnce() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let terminal = try XCTUnwrap(store.selectedTargetID)
    let root = repo("app")
    try await cd(store, tab, root)
    store.terminals.addTab(for: try XCTUnwrap(store.target(for: workroom)))

    store.selectedTargetID = workroom
    XCTAssertEqual(store.inspectorSubject, .target(workroom))
    XCTAssertEqual(store.inspectorHistoryTarget?.path, "/p/a")

    store.selectedTargetID = terminal
    XCTAssertEqual(followed(store)?.repository?.root, root, "at once, before any resolve")
    XCTAssertEqual(store.inspectorHistoryTarget?.path, root)

    store.selectedTargetID = workroom
    XCTAssertEqual(store.inspectorSubject, .target(workroom))
  }

  /// Value: protects=per-window subjects and the Quick Terminal's exclusion (stories 28, 30);
  /// fails_when=one window's cd, or a Quick Terminal pane's, moves another window's inspector;
  /// why_new=#805; seam=AppStore + QuickTerminalHost; no_claim=the panel's own status bar
  func testOtherWindowsAndTheQuickTerminalLeaveTheSubjectAlone() async throws {
    let first = makeStore()
    let tab = try await openTerminal(first)
    let root = repo("app")
    try await cd(first, tab, root)
    let second = makeStore()
    second.terminals.addTab(for: try XCTUnwrap(second.target(for: workroom)))
    second.selectedTargetID = workroom
    let panel = makeQuickTerminalHost(notifications: NotificationCenterStore(), section: section)
    let quick = panel.terminals.addTab(for: panel.target)

    try await cd(first, tab, repo("other"))
    XCTAssertEqual(second.inspectorSubject, .target(workroom), "the other window stays put")

    let firstSubject = first.inspectorSubject
    try XCTUnwrap(panel.terminals.surface(quick)).handlePwd(root)
    await first.followedFolderResolved()
    XCTAssertEqual(first.inspectorSubject, firstSubject, "the Quick Terminal feeds no window")
    XCTAssertEqual(second.inspectorSubject, .target(workroom))
  }

  /// Value: protects=the subject emptying when the terminal closes (story 36); fails_when=a
  /// closed terminal's folder lingers; why_new=#805; seam=AppStore; no_claim=the successor's own
  /// inspector beyond its subject
  func testClosingTheTerminalStopsFollowingIt() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    try await cd(store, tab, repo("app"))
    let target = try XCTUnwrap(store.selectedTarget)

    store.terminals.closeTab(tab.id, for: target)

    if case .followed = store.inspectorSubject {
      XCTFail("still following a closed terminal")
    }
  }
}
