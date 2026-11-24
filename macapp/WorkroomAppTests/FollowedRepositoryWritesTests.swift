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

  private func makeStatus(
    runner: any StatusCommandRunning = NoGitHubRunner()
  ) -> VCSStatusService {
    let status = VCSStatusService(projectStore: projects)
    status.statusResolver = WorkroomStatusResolver(runner: runner)
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

    XCTAssertEqual(store.remoteState.target?.actionTarget.followedRoot, work)
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

  /// Value: protects=a followed repository whose `.git` was removed underneath, still followed
  /// (no watch event has re-resolved it yet); fails_when=the write runs anyway and git, finding
  /// no repository at the root, commits into the repository AROUND it; why_new=#808 (the
  /// registration skips the unregistered path's `.git` check); seam=AppStore + RemoteStateModel,
  /// a repository nested in another; no_claim=the re-resolve that follows a watch event (#807)
  func testARepositoryRemovedUnderneathIsNeverWrittenThroughToTheOneAroundIt() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let outer = repo("outer")
    sh("git commit -qam outer-edit", in: outer)
    let inner = clone("outer/inner").work
    try "edited\n".write(toFile: inner + "/a.txt", atomically: true, encoding: .utf8)
    try await cd(store, tab, inner)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    XCTAssertEqual(target, .followed(root: inner))
    XCTAssertTrue(store.canCommit(target))
    XCTAssertTrue(store.remoteState.canPush)
    let files = try XCTUnwrap(status.status(for: target)?.changedFiles)

    try FileManager.default.removeItem(atPath: inner + "/.git")

    let result: VCSCommitResult = await withCheckedContinuation { done in
      store.performCommit(
        VCSCommitRequest(message: "stray", files: files, mode: .commit), on: target
      ) { done.resume(returning: $0) }
    }
    XCTAssertEqual(result, .failed(.other("That repository is no longer available.")))
    await act(store, .push)
    XCTAssertEqual(
      store.remoteState.lastFailure, .other("That repository is no longer available."))
    XCTAssertEqual(head(outer), "outer-edit", "the repository around it gains no commit")
    XCTAssertEqual(sh("git diff --cached --name-only", in: outer).out, "", "nor a staged file")
  }

  /// Value: protects=the actions coming back when the selection returns to the terminal with no
  /// `cd` (the review of #807's finding 1 class: they depend on the hold matching the subject);
  /// fails_when=after leaving and reselecting, the commit button or the toolbar has no target;
  /// why_new=#808; seam=AppStore; no_claim=the sidebar
  func testReselectingTheTerminalBringsItsActionsBack() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    let row = try XCTUnwrap(store.selectedTargetID)

    store.selectedTargetID = nil
    await settle(store)
    XCTAssertNil(store.inspectorActionTarget)
    XCTAssertNil(store.remoteState.target)
    store.selectedTargetID = row
    await settle(store)

    XCTAssertEqual(store.inspectorActionTarget, .followed(root: root))
    XCTAssertEqual(store.remoteState.target?.actionTarget.followedRoot, root)
    let result = await Self.commit(store, .followed(root: root), message: "after returning")
    guard case .ok = result else { return XCTFail("commit: \(result)") }
    XCTAssertEqual(head(root), "after returning")
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
    XCTAssertEqual(store.remoteState.target?.actionTarget.followedRoot, second.work)
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
    XCTAssertEqual(asked.target, .followed(root: first.work))
    XCTAssertNil(store.remoteState.inFlight)
    try await cd(store, tab, second.work)

    store.runRemoteAction(asked.action, on: asked.target)
    XCTAssertNil(store.remoteState.inFlight, "nothing runs against the second repository")

    // Negative control: answered while still in the repository it asked about, it runs.
    try await cd(store, tab, first.work)
    store.runRemoteAction(asked.action, on: asked.target)
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
    XCTAssertNil(store.remoteState.target?.actionTarget.followedRoot)
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

  // MARK: Pull request actions

  /// `git` runs for real. `gh repo view` names each repository after its folder (`octo/<name>`),
  /// so the `--repo` a pull request write carries says which repository it addressed; the writes
  /// (`gh pr ready`, `gh pr merge`, …) are recorded and answer `writeResult`, and with `gated` each
  /// waits for `release()` first. Every other `gh` call answers as a branch with no pull request.
  private final class RecordingGitHubRunner: StatusCommandRunning, @unchecked Sendable {
    private let real = StatusCommandRunner()
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var calls: [[String]] = []
    private var released = false
    var gated = false
    var writeResult = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)

    var writes: [[String]] { lock.withLock { recorded } }
    var allCalls: [[String]] { lock.withLock { calls } }
    func release() { lock.withLock { released = true } }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      guard executable == "gh" else {
        return await real.run(executable, args, in: directory, timeout: timeout)
      }
      lock.withLock { calls.append(args) }
      switch args.first {
      case "--version":
        return CommandResult(
          stdout: "gh version 2.60.0 (2024-10-01)\n", stderr: "", exitCode: 0, timedOut: false)
      case "auth": return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
      default: break
      }
      if args.prefix(2) == ["repo", "view"] {
        let name = (directory as NSString).lastPathComponent
        return CommandResult(
          stdout: "https://github.com/octo/\(name)\n", stderr: "", exitCode: 0, timedOut: false)
      }
      let writeVerbs: Set<String> = ["ready", "merge", "close", "reopen"]
      if args.first == "pr", args.count > 1, writeVerbs.contains(args[1]) {
        lock.withLock { recorded.append(args) }
        while gated, !lock.withLock({ released }) {
          try? await Task.sleep(for: .milliseconds(10))
        }
        return writeResult
      }
      // `gh pr list` and the rest: no pull request for the branch.
      return CommandResult(stdout: "[]", stderr: "", exitCode: 0, timedOut: false)
    }
  }

  private static func pullRequest(
    _ number: Int, draft: Bool, mergeable: Bool = false
  ) -> PullRequestInfo {
    PullRequestInfo(
      number: number, title: "t", state: .open, isDraft: draft, url: "u", reviewDecision: nil,
      reviewers: [], mergeable: mergeable)
  }

  /// Seed what GitHub would have said about `target`'s pull request.
  private static func seed(
    _ pr: PullRequestInfo, on target: VCSActionTarget, in s: VCSStatusService
  ) {
    switch target {
    case .row(let sid):
      var status = s.workroomStatuses[sid] ?? WorkroomStatus(dirty: false)
      status.pr = pr
      s.workroomStatuses[sid] = status
    case .followed(let root):
      var status = s.followedStatuses[root] ?? WorkroomStatus(dirty: false)
      status.pr = pr
      s.followedStatuses[root] = status
    }
  }

  private func waitForPRAction(_ store: AppStore) async {
    for _ in 0..<400 where store.prActionInFlight {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(store.prActionInFlight, "the pull request action never settled")
  }

  private func waitForWrites(_ runner: RecordingGitHubRunner, count: Int) async {
    for _ in 0..<400 where runner.writes.count < count {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(runner.writes.count, count, "gh writes: \(runner.writes)")
  }

  /// Value: protects=Ready for Review and Merge on a followed repository's pull request, as a
  /// workroom has them (#808, "full read-write"); fails_when=either does nothing, or `gh` is
  /// pointed at any repository but the followed one; why_new=#808 review; seam=AppStore, `gh`
  /// stubbed per repository; no_claim=GitHub's own answer
  func testPullRequestActionsActOnAFollowedRepository() async throws {
    let runner = RecordingGitHubRunner()
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("first")
    try await cd(store, tab, root)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    XCTAssertEqual(target, .followed(root: root))

    Self.seed(Self.pullRequest(5, draft: true), on: target, in: status)
    store.performPRAction(.markReady, number: 5, on: target)
    XCTAssertEqual(status.followedStatuses[root]?.pr?.isDraft, false, "flipped at the click")
    XCTAssertTrue(store.prActionInFlight)
    await waitForPRAction(store)
    XCTAssertNil(store.modals.errorMessage)
    XCTAssertEqual(runner.writes, [["pr", "ready", "5", "--repo", "github.com/octo/first"]])
    await settle(store)

    Self.seed(Self.pullRequest(5, draft: false, mergeable: true), on: target, in: status)
    store.performMerge(.squash, number: 5, on: target)
    XCTAssertEqual(status.followedStatuses[root]?.pr?.state, .merged)
    await waitForPRAction(store)
    XCTAssertNil(store.modals.errorMessage)
    XCTAssertEqual(
      runner.writes.last, ["pr", "merge", "5", "--squash", "--repo", "github.com/octo/first"])
    await settle(store)
  }

  /// Value: protects=a failed pull request write in a followed repository; fails_when=the
  /// optimistic flip stays (the panel lies), or the failure goes unreported; why_new=#808 review;
  /// seam=AppStore; no_claim=the dialog's rendering
  func testAFailedPullRequestActionInAFollowedRepositoryReverts() async throws {
    let runner = RecordingGitHubRunner()
    runner.writeResult = CommandResult(stdout: "", stderr: "nope", exitCode: 1, timedOut: false)
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("first")
    try await cd(store, tab, root)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    let draft = Self.pullRequest(5, draft: true)
    Self.seed(draft, on: target, in: status)

    store.performPRAction(.markReady, number: 5, on: target)
    await waitForPRAction(store)

    XCTAssertEqual(runner.writes.count, 1)
    XCTAssertEqual(status.followedStatuses[root]?.pr, draft)
    XCTAssertEqual(store.modals.errorTitle, "Couldn\u{2019}t ready for review")
    XCTAssertEqual(store.modals.errorMessage, "nope")
  }

  /// Value: protects=a pull request action addressed to a repository the terminal has left;
  /// fails_when=it runs against the repository the terminal is in now (same PR number there), or
  /// flips that one's badge; why_new=#808 review; seam=AppStore; no_claim=the confirmation dialogs
  func testAPullRequestActionForARepositoryNoLongerFollowedIsRefused() async throws {
    let runner = RecordingGitHubRunner()
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = repo("first")
    let second = repo("second")
    try await cd(store, tab, first)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    Self.seed(Self.pullRequest(5, draft: true), on: target, in: status)

    try await cd(store, tab, second)
    let theirs = Self.pullRequest(5, draft: true)
    Self.seed(theirs, on: try XCTUnwrap(store.inspectorActionTarget), in: status)

    store.performPRAction(.markReady, number: 5, on: target)
    await waitForPRAction(store)
    XCTAssertEqual(store.modals.errorMessage, "That repository is no longer available.")
    store.modals.errorMessage = nil
    store.performMerge(.squash, number: 5, on: target)
    await waitForPRAction(store)

    XCTAssertEqual(runner.writes, [], "no gh write runs")
    XCTAssertEqual(store.modals.errorMessage, "That repository is no longer available.")
    XCTAssertEqual(status.followedStatuses[second]?.pr, theirs, "the second's badge is untouched")
    XCTAssertNil(status.followedStatuses[first], "nothing re-creates the status of one let go")
  }

  /// Value: protects=a pull request write still running when the terminal moves to another
  /// repository; fails_when=its failure revert lands on the repository the terminal moved to,
  /// re-creates the one let go, or the write went anywhere but where it started; why_new=#808
  /// review; seam=AppStore, `gh` held on a gate; no_claim=GitHub's own answer
  func testAPullRequestActionRacingACdStaysWithItsRepository() async throws {
    let runner = RecordingGitHubRunner()
    runner.gated = true
    runner.writeResult = CommandResult(stdout: "", stderr: "nope", exitCode: 1, timedOut: false)
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = repo("first")
    let second = repo("second")
    try await cd(store, tab, first)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    Self.seed(Self.pullRequest(5, draft: true), on: target, in: status)

    store.performPRAction(.markReady, number: 5, on: target)
    await waitForWrites(runner, count: 1)
    try await cd(store, tab, second)
    let theirs = Self.pullRequest(5, draft: true)
    Self.seed(theirs, on: try XCTUnwrap(store.inspectorActionTarget), in: status)
    runner.release()
    await waitForPRAction(store)

    XCTAssertEqual(runner.writes, [["pr", "ready", "5", "--repo", "github.com/octo/first"]])
    XCTAssertEqual(status.followedStatuses[second]?.pr, theirs, "the revert stays off the second")
    XCTAssertNil(status.followedStatuses[first], "nothing re-creates the status of one let go")
    XCTAssertEqual(store.modals.errorMessage, "nope", "the failure is still the user's to see")
    XCTAssertEqual(
      store.modals.errorTitle,
      "Couldn\u{2019}t ready for review in \((first as NSString).abbreviatingWithTildeInPath)",
      "it names the repository it failed in, which the inspector no longer shows")
  }

  /// Value: protects=a pull request write whose repository's `.git` went away before it ran, still
  /// followed; fails_when=`gh` runs for it anyway (resolved from the path, not the registration's
  /// checked location); why_new=#808 review; seam=AppStore; no_claim=the watch's re-resolve
  func testAPullRequestActionInARepositoryRemovedUnderneathIsRefused() async throws {
    let runner = RecordingGitHubRunner()
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("first")
    try await cd(store, tab, root)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    let draft = Self.pullRequest(5, draft: true)
    Self.seed(draft, on: target, in: status)

    try FileManager.default.removeItem(atPath: root + "/.git")
    store.performPRAction(.markReady, number: 5, on: target)
    await waitForPRAction(store)

    XCTAssertEqual(runner.writes, [])
    XCTAssertEqual(status.followedStatuses[root]?.pr, draft, "the optimistic flip is undone")
    XCTAssertEqual(store.modals.errorMessage, "That repository is no longer available.")
  }

  /// Value: protects=a failing pull request write that outlives its hold, the repository followed
  /// afresh before it returns; fails_when=its revert overwrites the fresh hold's re-read pull
  /// request; why_new=#808 review; seam=AppStore, `gh` held on a gate; no_claim=GitHub's answer
  func testAPullRequestRevertNeverLandsOnAHoldTakenAfresh() async throws {
    let runner = RecordingGitHubRunner()
    runner.gated = true
    runner.writeResult = CommandResult(stdout: "", stderr: "nope", exitCode: 1, timedOut: false)
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let first = repo("first")
    let second = repo("second")
    try await cd(store, tab, first)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    Self.seed(Self.pullRequest(5, draft: true), on: target, in: status)

    store.performPRAction(.markReady, number: 5, on: target)
    await waitForWrites(runner, count: 1)
    try await cd(store, tab, second)
    try await cd(store, tab, first)
    let fresh = Self.pullRequest(6, draft: false)
    Self.seed(fresh, on: target, in: status)
    runner.release()
    await waitForPRAction(store)

    XCTAssertEqual(status.followedStatuses[first]?.pr, fresh)
    XCTAssertEqual(store.modals.errorMessage, "nope")
  }

  /// Value: protects=pull request actions on a registered project's repository followed from a
  /// terminal, in place; fails_when=the write goes elsewhere, or no GitHub re-read follows it (no
  /// selection refresh reaches the row while a terminal is selected); why_new=#808 review;
  /// seam=AppStore + the router; no_claim=the sidebar
  func testPullRequestActionsActOnARegisteredRepositoryInPlace() async throws {
    let root = repo("platform")
    projects.projects = [Project(path: root, vcs: "git", workrooms: [])]
    router.replaceLocal(try await RepositoryRouter.prepare(projects.projects))
    let row = SidebarID.root(project: projects.projects[0].id)
    let runner = RecordingGitHubRunner()
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    try await cd(store, tab, root)
    let target = try XCTUnwrap(store.inspectorActionTarget)
    XCTAssertEqual(target, .row(row))
    Self.seed(Self.pullRequest(5, draft: true), on: target, in: status)
    let before = runner.allCalls.count

    store.performPRAction(.markReady, number: 5, on: target)
    await waitForPRAction(store)
    await status.followedStatusSettled()

    XCTAssertNil(store.modals.errorMessage)
    XCTAssertEqual(runner.writes, [["pr", "ready", "5", "--repo", "github.com/octo/platform"]])
    let after = Array(runner.allCalls.dropFirst(before))
    XCTAssertTrue(
      after.contains { $0.prefix(2) == ["pr", "list"] },
      "GitHub is asked again for the row's pull request: \(after)")
  }

  /// Value: protects=the Room menu's draft item for a followed repository, addressed at the
  /// repository and number it showed; fails_when=it is missing, or carries no target, so a click
  /// after a `cd` could pair one repository's number with another's; why_new=#808 review;
  /// seam=RoomCommandState; no_claim=the menu's rendering
  func testTheRoomMenuOffersTheDraftItemForAFollowedRepository() async throws {
    let runner = RecordingGitHubRunner()
    let status = makeStatus(runner: runner)
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("first")
    try await cd(store, tab, root)
    status.githubCLIStatus = .available
    Self.seed(Self.pullRequest(5, draft: true), on: .followed(root: root), in: status)

    let state = RoomCommandState.read(store)
    let pr = try XCTUnwrap(state.pullRequest)
    XCTAssertEqual(pr.draftAction, .markReady)
    XCTAssertEqual(pr.target, .followed(root: root))
    XCTAssertEqual(pr.number, 5)
    XCTAssertTrue(state.canChangeDraft)
  }

  // MARK: Review nits

  /// Value: protects=the toolbar agreeing with Commit on a repository the app can't write to;
  /// fails_when=Fetch, Push or Pull are offered where Commit is not; why_new=#808 review nit 1;
  /// seam=AppStore, the resolve seam; no_claim=the toolbar's rendering
  func testTheToolbarOffersNoWritesWhereCommitIsOff() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    let real = store.resolveFollowedRepository
    store.resolveFollowedRepository = { folder in
      let found = await real(folder)
      guard case .repository(var repository) = found else { return found }
      repository.isWritable = false
      return .repository(repository)
    }
    try await cd(store, tab, root)

    XCTAssertNil(store.inspectorActionTarget)
    XCTAssertNil(store.remoteTarget())
    store.performRemoteAction(.push)
    XCTAssertNil(store.remoteState.inFlight)
  }

  /// Value: protects=a followed repository whose registration came back empty; fails_when=Commit,
  /// the pull request's actions, the Room menu's items or the toolbar are offered for it, only to
  /// fail with "no longer available"; why_new=#808 review finding 5; seam=the registration seam;
  /// no_claim=git's own `--git-common-dir` failure
  func testAnUnregisteredFollowedRepositoryOffersNoWrites() async throws {
    let status = makeStatus()
    status.resolveFollowedRegistration = { _ in nil }
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root)
    status.githubCLIStatus = .available
    Self.seed(Self.pullRequest(5, draft: true), on: .followed(root: root), in: status)

    XCTAssertTrue(status.isFollowing(root), "the status stays, for the inspector to show")
    XCTAssertNil(store.inspectorActionTarget)
    XCTAssertNil(store.inspectorPullRequestTarget)
    XCTAssertNil(store.remoteTarget())
    XCTAssertNil(store.remoteState.target, "the toolbar let go of it")
    let state = RoomCommandState.read(store)
    XCTAssertFalse(state.canCommit)
    XCTAssertNil(state.pullRequest)
  }

  /// Value: protects=pull request actions on a followed repository the app can't write to, which
  /// `gh` writes only on GitHub, as the same repository's registered row has them; fails_when=they
  /// are hidden with Commit, or Commit is offered with them; why_new=#808 review finding 6;
  /// seam=AppStore, the resolve seam; no_claim=the panel's rendering
  func testAReadOnlyFollowedRepositoryKeepsItsPullRequestActions() async throws {
    let status = makeStatus()
    let store = makeStore(status)
    let tab = try await openTerminal(store)
    let root = repo("app")
    let real = store.resolveFollowedRepository
    store.resolveFollowedRepository = { folder in
      let found = await real(folder)
      guard case .repository(var repository) = found else { return found }
      repository.isWritable = false
      return .repository(repository)
    }
    try await cd(store, tab, root)
    status.githubCLIStatus = .available
    Self.seed(Self.pullRequest(5, draft: true), on: .followed(root: root), in: status)

    XCTAssertNil(store.inspectorActionTarget)
    XCTAssertEqual(store.inspectorPullRequestTarget, .followed(root: root))
    let state = RoomCommandState.read(store)
    XCTAssertFalse(state.canCommit)
    XCTAssertEqual(state.pullRequest?.target, .followed(root: root))
    XCTAssertTrue(state.canChangeDraft)
  }

  /// Value: protects=a linked worktree whose main repository git couldn't name; fails_when=it is
  /// registered as its own repository, so its writes and its main repository's stop refusing each
  /// other; why_new=#808 review nit 2; seam=VCSStatusService.followedRegistration, real git;
  /// no_claim=the 3 s timeout itself
  func testALinkedWorktreeWhoseMainRepositoryCantBeReadIsNotRegistered() async throws {
    let broken = folder("broken")
    try "gitdir: \(scratch.path)/nowhere/.git/worktrees/broken\n".write(
      toFile: broken + "/.git", atomically: true, encoding: .utf8)

    let registration = await VCSStatusService.followedRegistration(root: broken)

    XCTAssertNil(registration, "refused, to be retried on the next follow")
  }
}
