import WorkroomDomain
import WorkroomGit
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// Commit, push, pull and fetch in the repository a terminal's inspector follows (#808): the same
/// Changes actions a workroom has, against a repository no project owns. Its registration with the
/// repository router lasts while some window follows it, and a write lands in the repository the
/// user acted on, never the one the terminal has moved to since. Real throwaway repositories and
/// local bare remotes; `gh` never runs.
@MainActor
final class FollowedRepositoryWritesTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private var scratch: URL!
  private let router = RepositoryRouter.shared

  /// A watch that watches nothing: these tests drive every refresh themselves.
  private final class NoWatcher: RepositoryWatching {
    func start(path: String) {}
    func stop() {}
  }

  /// `git` runs for real; `gh` answers as a repository with no GitHub remote.
  private struct NoGitHubRunner: StatusCommandRunning {
    let real = StatusCommandRunner()
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      guard executable == "gh" else {
        return await real.run(executable, args, in: directory, timeout: timeout)
      }
      if args.first == "--version" {
        return CommandResult(
          stdout: "gh version 2.60.0 (2024-10-01)\n", stderr: "", exitCode: 0, timedOut: false)
      }
      if args.first == "auth" {
        return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
      }
      return CommandResult(
        stdout: "", stderr: "no git remotes found", exitCode: 1, timedOut: false)
    }
  }

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(sh("command -v git", in: NSTemporaryDirectory()).exit != 0, "git is missing")
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("followed-writes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    scratch = URL(fileURLWithPath: VCSStatusService.canonicalPath(made.path))
  }

  override func tearDown() async throws {
    // The router is the process's: leave no project registration of this test's behind.
    router.replaceLocal([])
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    try await super.tearDown()
  }

  // MARK: Scaffold

  private func makeStatus() -> VCSStatusService {
    let status = VCSStatusService(projectStore: projects)
    status.statusResolver = WorkroomStatusResolver(runner: NoGitHubRunner())
    status.followedProbeDebounce = 0
    status.makeRepositoryWatcher = { _ in NoWatcher() }
    return status
  }

  private func makeStore(_ status: VCSStatusService) -> AppStore {
    let store = AppStore(
      projectStore: projects, vcsStatus: status, terminalsSection: section,
      commitHistory: HistoryModel(resolve: { _ in GitProvider() }))
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

  /// The shell in `tab` reports `folder`; wait for everything that follows it to settle.
  /// `toolbar: false` while a toolbar action is held on a gate: waiting for it would never end.
  private func cd(
    _ store: AppStore, _ tab: TerminalTab, _ folder: String, toolbar: Bool = true
  ) async throws {
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder)
    await settle(store, toolbar: toolbar)
  }

  private func settle(_ store: AppStore, toolbar: Bool = true) async {
    await store.followedFolderResolved()
    await store.vcsStatus.followedRegistrationsSettled()
    await store.vcsStatus.followedStatusSettled()
    await store.commitHistory.awaitCurrentLoad()
    if toolbar { await store.remoteState.awaitCurrentLoad() }
  }

  private func changedPaths(_ store: AppStore) -> [String]? {
    store.vcsStatus.status(for: store.inspectorSubject)?.changedFiles?.map(\.path)
  }

  /// A commit of everything `target`'s status lists, through the store's commit ask.
  private static func commit(
    _ store: AppStore, _ target: VCSActionTarget, message: String
  ) async -> VCSCommitResult {
    let files = store.vcsStatus.status(for: target)?.changedFiles ?? []
    return await withCheckedContinuation { done in
      store.performCommit(
        VCSCommitRequest(message: message, files: files, mode: .commit), on: target
      ) { done.resume(returning: $0) }
    }
  }

  private func act(_ store: AppStore, _ action: VCSRemoteAction) async {
    store.performRemoteAction(action)
    await store.remoteState.awaitCurrentLoad()
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
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (out, p.terminationStatus)
  }

  private func folder(_ name: String) -> String {
    let path = scratch.appendingPathComponent(name).path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// The app's own `git commit` reads the repository's config: an identity, and no signing.
  private static let identity =
    "git config user.email t@e.com && git config user.name T && git config commit.gpgsign false"

  /// A git repository with one commit (`base`) and a pending edit to `a.txt`.
  private func repo(_ name: String) -> String {
    let dir = folder(name)
    sh("git init -q -b main . && \(Self.identity)", in: dir)
    try? "x\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    sh("git add -A && git commit -qm base", in: dir)
    try? "edited\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    return dir
  }

  /// A clone of a local bare remote with `pushed` on `origin/main` and one commit (`local work`)
  /// not pushed yet. Returns the work tree and the bare remote.
  private func clone(_ name: String) -> (work: String, bare: String) {
    let dir = folder(name)
    sh(
      """
      git init -q --bare -b main bare.git && git clone -q bare.git work && cd work \
        && \(Self.identity) && git checkout -q -b main \
        && echo one > a.txt && git add . && git commit -qm pushed && git push -qu origin main \
        && echo two > b.txt && git add . && git commit -qm 'local work'
      """, in: dir)
    return (dir + "/work", dir + "/bare.git")
  }

  private func head(_ dir: String, _ ref: String = "HEAD") -> String {
    sh("git log -1 --format=%s \(ref)", in: dir).out
  }

  /// Wait for `path` to exist: a hook saying it has started.
  private func waitForFile(_ path: String) async throws {
    for _ in 0..<400 where !FileManager.default.fileExists(atPath: path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(path) never appeared")
  }

  /// A hook in `repo` that says it started, then waits for its gate file.
  private func installGatedHook(_ hook: String, in repo: String) -> (started: String, gate: String)
  {
    let started = repo + "/.git/hook-started"
    let gate = repo + "/.git/hook-gate"
    let script = """
      #!/bin/sh
      touch '\(started)'
      while [ ! -f '\(gate)' ]; do sleep 0.02; done
      exit 0

      """
    let path = repo + "/.git/hooks/\(hook)"
    try? FileManager.default.createDirectory(
      atPath: repo + "/.git/hooks", withIntermediateDirectories: true)
    try? script.write(toFile: path, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return (started, gate)
  }

  // MARK: The Changes actions

  /// Value: protects=a commit through the Changes flow in a followed repository no project owns
  /// (AC 1, 4); fails_when=the commit button stays off, the sheet's asks find nothing to address,
  /// or the router refuses the write; why_new=#808; seam=AppStore; no_claim=the sheet's rendering
  func testACommitLandsInAFollowedRepositoryNoProjectOwns() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)

    let target = try XCTUnwrap(store.inspectorActionTarget)
    XCTAssertEqual(target, .followed(root: root))
    XCTAssertTrue(store.canCommit(target))
    store.requestCommit(target)
    XCTAssertEqual(store.modals.pendingCommit, PendingCommit(target: target))

    let preflight: Result<VCSCommitPreflight, Error> = await withCheckedContinuation { done in
      store.commitPreflight(on: target) { done.resume(returning: $0) }
    }
    XCTAssertNoThrow(try preflight.get())
    let files = try XCTUnwrap(status.status(for: target)?.changedFiles)
    let atRisk: Result<[String], Error> = await withCheckedContinuation { done in
      store.stagedContentAtRisk(on: target, files: files) { done.resume(returning: $0) }
    }
    XCTAssertEqual(try atRisk.get(), [])

    let result = await Self.commit(store, target, message: "from the inspector")
    guard case .ok = result else { return XCTFail("commit: \(result)") }
    await settle(store)

    XCTAssertEqual(head(root), "from the inspector")
    XCTAssertEqual(changedPaths(store), [], "Changes re-reads the repository it committed")
    XCTAssertFalse(store.canCommit(target), "nothing left to commit")
    XCTAssertEqual(store.commitHistory.commits.first?.summary, "from the inspector")
    XCTAssertTrue(status.workroomStatuses.isEmpty, "no sidebar row gains a status")
    XCTAssertTrue(status.committingFollowedRoots.isEmpty)
  }

  /// Value: protects=the toolbar's push, fetch and pull in a followed repository (AC 1, 3);
  /// fails_when=the toolbar has no target for it, or its read or action meets no registration;
  /// why_new=#808; seam=AppStore + RemoteStateModel, a local bare remote; no_claim=the toolbar's
  /// rendering, credentials
  func testPushFetchAndPullRunInAFollowedRepository() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let (work, bare) = clone("origin")
    try await cd(store, tab, work)

    XCTAssertEqual(store.remoteState.target?.followedRoot, work)
    XCTAssertNotNil(store.remoteState.snapshot, "the toolbar reads the followed repository")
    XCTAssertTrue(store.remoteState.canPush)

    await act(store, .push)
    XCTAssertNil(store.remoteState.lastFailure)
    XCTAssertEqual(head(bare, "main"), "local work")

    // Another clone pushes; fetch then sees it, and pull brings it in.
    sh(
      """
      git clone -q bare.git other && cd other && \(Self.identity) \
        && echo three > c.txt && git add . && git commit -qm theirs && git push -q origin main
      """, in: (bare as NSString).deletingLastPathComponent)
    await act(store, .fetch)
    XCTAssertNil(store.remoteState.lastFailure)
    XCTAssertEqual(head(work, "origin/main"), "theirs")
    XCTAssertEqual(head(work), "local work")

    await act(store, .pull)
    XCTAssertNil(store.remoteState.lastFailure)
    XCTAssertNil(store.modals.pendingRemoteConfirm, "a clean tree pulls without asking")
    XCTAssertEqual(head(work), "theirs")
  }

  // MARK: Refusals

  /// Value: protects=no write outside a repository; fails_when=a folder in no repository offers a
  /// commit or a toolbar action, or registers anything; why_new=#808; seam=AppStore;
  /// no_claim=the empty state's copy (#807)
  func testAFolderOutsideARepositoryOffersNoWrites() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let plain = folder("plain")
    try await cd(store, tab, plain)

    XCTAssertNil(store.inspectorActionTarget)
    XCTAssertFalse(store.canCommit(store.inspectorActionTarget))
    store.requestCommit(store.inspectorActionTarget)
    XCTAssertNil(store.modals.pendingCommit)
    XCTAssertNil(store.remoteTarget())
    store.performRemoteAction(.push)
    XCTAssertNil(store.remoteState.inFlight)
    let location = try await RepositoryLocation.local(plain)
    XCTAssertNil(router.entry(for: location))
  }

  /// Value: protects=no write while git couldn't tell which repository the folder is in (R1–R4:
  /// couldn't-tell has no repository, so a write addresses nothing); fails_when=the commit or the
  /// toolbar acts on the repository the terminal was in before; why_new=#808; seam=AppStore, the
  /// resolve seam; no_claim=the retry schedule
  func testWhenGitCouldNotTellNothingIsWritten() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    XCTAssertEqual(store.inspectorActionTarget, .followed(root: root))
    let real = store.resolveFollowedRepository
    let unknown = root + "/elsewhere"
    try FileManager.default.createDirectory(atPath: unknown, withIntermediateDirectories: true)
    store.resolveFollowedRepository = { folder in
      folder == unknown ? .unknown : await real(folder)
    }
    store.followedFolderRetryWait = { _ in try? await Task.sleep(for: .seconds(3600)) }

    try await cd(store, tab, unknown)

    guard case .followed(let followed) = store.inspectorSubject else {
      return XCTFail("subject is \(store.inspectorSubject)")
    }
    XCTAssertTrue(followed.repositoryUndetermined)
    XCTAssertNil(store.inspectorActionTarget)
    XCTAssertNil(store.remoteTarget())
    store.requestCommit(store.inspectorActionTarget)
    XCTAssertNil(store.modals.pendingCommit)
    // The repository it was in before is let go, so a write still addressed to it is refused.
    let late = await Self.commit(store, .followed(root: root), message: "late")
    XCTAssertEqual(late, .failed(.other("That repository is no longer available.")))
    XCTAssertEqual(head(root), "base")
  }

  /// Value: protects=a commit sheet whose repository the terminal left before Commit was pressed;
  /// fails_when=the commit lands in the repository the terminal is in now, or in the one it left
  /// with nothing following it; why_new=#808; seam=AppStore; no_claim=the sheet's own copy
  func testACommitForARepositoryNoLongerFollowedIsRefused() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = repo("first")
    let second = repo("second")
    try await cd(store, tab, first)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    store.requestCommit(target)

    try await cd(store, tab, second)

    let result = await Self.commit(store, target, message: "stray")
    XCTAssertEqual(result, .failed(.other("That repository is no longer available.")))
    let preflight: Result<VCSCommitPreflight, Error> = await withCheckedContinuation { done in
      store.commitPreflight(on: target) { done.resume(returning: $0) }
    }
    XCTAssertThrowsError(try preflight.get())
    XCTAssertEqual(head(first), "base")
    XCTAssertEqual(head(second), "base")
    XCTAssertEqual(changedPaths(store), ["a.txt"], "the second repository's own change still shows")
  }

  // MARK: Races with a `cd`

  /// Value: protects=a commit racing a `cd` to another repository; fails_when=the commit, its
  /// status refresh or its History refresh lands in the repository the terminal moved to, or the
  /// write marks leak; why_new=#808; seam=AppStore, a pre-commit hook held on a gate file;
  /// no_claim=the sheet's progress UI
  func testACommitRacingACdLandsInTheRepositoryItWasStartedIn() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = repo("first")
    let second = repo("second")
    let hook = installGatedHook("pre-commit", in: first)
    try await cd(store, tab, first)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    let location = try await RepositoryLocation.local(first)

    async let pending = Self.commit(store, target, message: "mid-flight")
    try await waitForFile(hook.started)
    XCTAssertTrue(status.isWritingProject(location), "the commit holds the write mark")
    XCTAssertTrue(
      status.isCommittingProject(status.followedSharedLocation(first)),
      "and keeps the followed repository's read lanes off it meanwhile")
    try await cd(store, tab, second)
    XCTAssertEqual(store.inspectorActionTarget, .followed(root: second))
    FileManager.default.createFile(atPath: hook.gate, contents: nil)
    let result = await pending
    await settle(store)

    guard case .ok = result else { return XCTFail("commit: \(result)") }
    XCTAssertEqual(head(first), "mid-flight", "it lands where the user committed")
    XCTAssertEqual(head(second), "base", "never where the terminal went")
    XCTAssertEqual(changedPaths(store), ["a.txt"], "the second repository's change still shows")
    XCTAssertNil(status.followedStatuses[first], "nothing re-creates the status of one let go")
    XCTAssertEqual(store.commitHistory.commits.map(\.summary), ["base"], "History is the second's")
    XCTAssertFalse(status.isWritingProject(location), "the write mark is released")
    XCTAssertTrue(status.committingFollowedRoots.isEmpty)
    XCTAssertFalse(router.isHeldFollowed(location), "and so is the registration")
  }

  /// Value: protects=a push racing a `cd` to another repository; fails_when=the push runs against
  /// the repository the terminal moved to, or its outcome is shown on that one's toolbar;
  /// why_new=#808; seam=AppStore + RemoteStateModel, a pre-push hook held on a gate file;
  /// no_claim=the failure dialog
  func testAPushRacingACdPushesTheRepositoryItWasStartedIn() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = clone("first")
    let second = clone("second")
    let hook = installGatedHook("pre-push", in: first.work)
    try await cd(store, tab, first.work)

    store.performRemoteAction(.push)
    try await waitForFile(hook.started)
    try await cd(store, tab, second.work, toolbar: false)
    XCTAssertEqual(store.remoteState.target?.followedRoot, second.work)
    FileManager.default.createFile(atPath: hook.gate, contents: nil)
    await store.remoteState.awaitCurrentLoad()
    await settle(store)

    XCTAssertEqual(head(first.bare, "main"), "local work", "the first repository was pushed")
    XCTAssertEqual(head(second.bare, "main"), "pushed", "the second was not")
    XCTAssertNil(store.remoteState.inFlight)
    XCTAssertNil(store.remoteState.lastFailure)
    XCTAssertNil(store.remoteState.activeAction)
  }

  /// Value: protects=a pull confirmation answered after the terminal moved to another repository;
  /// fails_when=the confirmed pull rewrites the repository the terminal is in now (its row is the
  /// same terminal, so the row alone can't tell them apart); why_new=#808; seam=AppStore;
  /// no_claim=the dialog
  func testAConfirmedPullNeverRunsInTheRepositoryTheTerminalMovedTo() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = clone("first")
    let second = clone("second")
    try "dirty\n".write(toFile: first.work + "/a.txt", atomically: true, encoding: .utf8)
    try await cd(store, tab, first.work)

    store.performRemoteAction(.pull)
    let asked = try XCTUnwrap(store.modals.pendingRemoteConfirm, "a dirty tree asks first")
    XCTAssertEqual(asked.followedRoot, first.work)
    XCTAssertNil(store.remoteState.inFlight)
    try await cd(store, tab, second.work)

    store.runRemoteAction(asked.action, on: asked.sid, followedRoot: asked.followedRoot)
    XCTAssertNil(store.remoteState.inFlight, "nothing runs against the second repository")

    // Negative control: answered while still in the repository it asked about, it runs.
    try await cd(store, tab, first.work)
    store.runRemoteAction(asked.action, on: asked.sid, followedRoot: asked.followedRoot)
    XCTAssertEqual(store.remoteState.inFlight, .pull)
    await store.remoteState.awaitCurrentLoad()
  }

  // MARK: Registration

  /// Value: protects=the registration lasting exactly while some window follows the repository
  /// (AC 2); fails_when=it is dropped while a window still follows it, or outlives the last one;
  /// why_new=#808; seam=AppStore x2 + the router; no_claim=window close (below)
  func testTheRegistrationLastsWhileSomeWindowFollowsTheRepository() async throws {
    let status = makeStatus()
    let first = makeStore(status)
    let second = makeStore(status)
    let root = repo("app")
    let location = try await RepositoryLocation.local(root)
    do {
      _ = try await router.writer(for: location)
      XCTFail("nothing follows it yet: a write needs a registration")
    } catch {}
    let firstTab = try await openTerminal(first)
    try await cd(first, firstTab, root)
    let secondTab = try await openTerminal(second)
    try await cd(second, secondTab, root)
    XCTAssertTrue(router.isHeldFollowed(location))
    _ = try await router.writer(for: location)

    try await cd(first, firstTab, folder("elsewhere"))
    XCTAssertTrue(router.isHeldFollowed(location), "the other window still follows it")
    XCTAssertEqual(second.inspectorActionTarget, .followed(root: root))

    // A project reload replaces the projects' registrations, never a followed repository's.
    router.replaceLocal([])
    XCTAssertTrue(router.isHeldFollowed(location))
    _ = try await router.writer(for: location)

    second.selectedTargetID = nil
    await status.followedRegistrationsSettled()
    XCTAssertFalse(router.isHeldFollowed(location), "no window follows it any more")
    XCTAssertNil(router.entry(for: location))
    do {
      _ = try await router.writer(for: location)
      XCTFail("a write to a repository nothing follows is refused")
    } catch {}
  }

  /// Value: protects=a repository let go and followed again while its registration is in flight
  /// (the review of #807's finding 6 class); fails_when=the two holds unbalance: one left behind
  /// with nothing following, or none while a window follows; why_new=#808; seam=VCSStatusService +
  /// the router; no_claim=timing of the real resolve
  func testLettingGoAndFollowingAgainLeavesExactlyOneRegistration() async throws {
    let status = makeStatus()
    let root = repo("app")
    let location = try await RepositoryLocation.local(root)

    status.follow(root)
    status.unfollow(root)
    status.follow(root)
    await status.followedRegistrationsSettled()
    XCTAssertTrue(router.isHeldFollowed(location), "the second follow's hold stands")

    status.unfollow(root)
    await status.followedRegistrationsSettled()
    XCTAssertFalse(router.isHeldFollowed(location), "and its release leaves none")
  }

  /// Value: protects=a closed window letting go of its followed repository's registration;
  /// fails_when=a window that closed while following keeps the repository writable for good;
  /// why_new=#808; seam=AppStore's lifetime; no_claim=AppKit's window teardown
  func testAClosedWindowReleasesItsRegistration() async throws {
    let status = makeStatus()
    let root = repo("app")
    let location = try await RepositoryLocation.local(root)
    weak var closed: AppStore?
    do {
      let store = makeStore(status)
      let tab = try await openTerminal(store)
      try await cd(store, tab, root)
      XCTAssertTrue(router.isHeldFollowed(location))
      closed = store
    }
    for _ in 0..<200 where closed != nil || status.isFollowing(root) {
      try await Task.sleep(for: .milliseconds(10))
    }
    try XCTSkipIf(closed != nil, "the store outlived its last reference in this harness")
    await status.followedRegistrationsSettled()
    XCTAssertFalse(status.isFollowing(root))
    XCTAssertFalse(router.isHeldFollowed(location))
  }

  /// Value: protects=a registered project's repository keeping its own registration (AC 2), and
  /// its Changes actions working in place from a terminal; fails_when=following it replaces or,
  /// on unfollow, removes the project's registration, or the commit goes to a second entry;
  /// why_new=#808; seam=AppStore + the router; no_claim=the sidebar
  func testARegisteredProjectsRepositoryKeepsItsOwnRegistration() async throws {
    let root = repo("platform")
    projects.projects = [Project(path: root, vcs: "git", workrooms: [])]
    router.replaceLocal(try await RepositoryRouter.prepare(projects.projects))
    let location = try XCTUnwrap(router.localLocation(for: root))
    let registered = try XCTUnwrap(router.entry(for: location))
    let row = SidebarID.root(project: projects.projects[0].id)
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    try await cd(store, tab, root)

    XCTAssertEqual(store.inspectorActionTarget, .row(row), "it acts as its row, in place")
    XCTAssertEqual(store.remoteState.target?.sid, row)
    XCTAssertNil(store.remoteState.target?.followedRoot)
    let result = await Self.commit(store, .row(row), message: "in place")
    guard case .ok = result else { return XCTFail("commit: \(result)") }
    await settle(store)
    XCTAssertEqual(head(root), "in place")
    XCTAssertEqual(changedPaths(store), [])
    XCTAssertTrue(status.followedStatuses.isEmpty)

    store.selectedTargetID = nil
    await status.followedRegistrationsSettled()
    XCTAssertFalse(router.isHeldFollowed(location))
    XCTAssertEqual(router.entry(for: location), registered, "the project's registration stands")
    _ = try await router.writer(for: location)
  }

  // MARK: The router's holds

  /// Value: protects=the router's followed registrations as counted holds apart from the
  /// projects'; fails_when=one release drops another holder's, a release removes a project's
  /// registration, or a project's is shadowed by a followed one; why_new=#808; seam=RepositoryRouter;
  /// no_claim=remote hosts (never held)
  func testTheRoutersFollowedHoldsAreCountedAndNeverTouchAProjectsRegistration() async throws {
    let router = RepositoryRouter()
    let root = repo("app")
    let location = try await RepositoryLocation.local(root)
    let other = try await RepositoryLocation.local(folder("main"))
    let followed = try RepositoryRouter.Registration(
      location: location, sharedLocation: location, localSourcePath: root)

    router.holdFollowed(followed)
    router.holdFollowed(followed)
    router.releaseFollowed(location)
    XCTAssertEqual(router.entry(for: location)?.sharedLocation, location, "one hold still stands")
    XCTAssertEqual(router.localLocation(for: root), location)
    router.releaseFollowed(location)
    XCTAssertNil(router.entry(for: location))
    XCTAssertNil(router.localLocation(for: root))
    router.releaseFollowed(location)
    XCTAssertFalse(router.isHeldFollowed(location), "a release with no hold does nothing")

    // A project's registration of the same place routes it, and no release removes it.
    router.replaceLocal([try .init(location: location, sharedLocation: other)])
    router.holdFollowed(followed)
    XCTAssertEqual(router.entry(for: location)?.sharedLocation, other)
    router.releaseFollowed(location)
    router.releaseFollowed(location)
    XCTAssertEqual(router.entry(for: location)?.sharedLocation, other)
  }

  /// Value: protects=what a followed repository's writes are serialised on; fails_when=a linked
  /// worktree is registered as its own repository (its commits would race its main working
  /// tree's), or a plain repository as anything but itself; why_new=#808;
  /// seam=VCSStatusService.followedRegistration, real git; no_claim=submodules, bare repositories
  func testALinkedWorktreeSharesItsMainRepositorysWriteLock() async throws {
    let main = repo("main")
    let linked = scratch.appendingPathComponent("linked").path
    sh("git worktree add -q -b side '\(linked)'", in: main)

    let plain = await VCSStatusService.followedRegistration(root: main)
    let worktree = await VCSStatusService.followedRegistration(root: linked)

    let mainLocation = try await RepositoryLocation.local(main)
    let linkedLocation = try await RepositoryLocation.local(linked)
    XCTAssertEqual(plain?.location, mainLocation)
    XCTAssertEqual(plain?.entry.sharedLocation, mainLocation)
    XCTAssertEqual(worktree?.location, linkedLocation)
    XCTAssertEqual(worktree?.entry.sharedLocation, mainLocation)
  }
}
