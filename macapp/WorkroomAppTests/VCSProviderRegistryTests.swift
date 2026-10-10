import Foundation
import WorkroomDomain
import XCTest

@testable import Workroom

final class RepositoryRoutingTests: XCTestCase {
  func testLocalAliasesAndRemoteIdentity() async throws {
    let local = try await RepositoryLocation.local("/tmp/")
    let canonical = try await RepositoryLocation.local("/private/tmp")
    XCTAssertEqual(local, canonical)
    let host = UUID()
    let upper = try RepositoryLocation.remote(host: host, path: "/Repo///")
    XCTAssertEqual(upper.path, "/Repo")
    XCTAssertNotEqual(upper, try RepositoryLocation.remote(host: host, path: "/repo"))
    XCTAssertNotEqual(upper, try RepositoryLocation.remote(host: UUID(), path: "/Repo"))
    for invalid in ["relative", "/a/../b", "/a/./b", "/a\0b"] {
      XCTAssertThrowsError(try RepositoryLocation.remote(host: host, path: invalid))
    }
    do {
      _ = try await RepositoryLocation.local("relative")
      XCTFail("accepted relative path")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .invalidPath("relative")) }
  }

  func testRegistrationRejectsMixedHostsAndLocalRefreshPreservesRemote() async throws {
    let local = try await RepositoryLocation.local("/tmp")
    let remote = try RepositoryLocation.remote(host: UUID(), path: local.path)
    XCTAssertThrowsError(
      try RepositoryRouter.Registration(location: remote, sharedLocation: local))
    let router = RepositoryRouter()
    try router.register(.init(location: remote, sharedLocation: remote))
    router.replaceLocal([try .init(location: local, sharedLocation: local)])
    router.replaceLocal([])
    XCTAssertNil(router.entry(for: local))
    XCTAssertEqual(router.entry(for: remote)?.sharedLocation, remote)
  }

  func testWriterAndSupportingReaderKeepCapturedRegistration() async throws {
    let location = try await RepositoryLocation.local("/tmp/registered-no-repository")
    let otherShared = try await RepositoryLocation.local("/tmp")
    let router = RepositoryRouter()
    try router.register(.init(location: location, sharedLocation: location))
    let writer = try await router.writer(for: location)
    let reader = try await router.reader(for: location)
    try router.register(.init(location: location, sharedLocation: otherShared))
    XCTAssertEqual(writer.context.sharedLocation, location)
    XCTAssertEqual(writer.reader.context, writer.context)
    XCTAssertEqual(reader.context.sharedLocation, location)
    let replacement = try await router.reader(for: location)
    XCTAssertEqual(replacement.context.sharedLocation, otherShared)
  }

  func testMissingRemoteServicesNeverReadSamePathLocalRepository() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = StatusCommandRunner()
    let initialized = await runner.run("git", ["init", "-q"], in: directory.path, timeout: 5)
    XCTAssertTrue(initialized.ok)
    let local = try await RepositoryLocation.local(directory.path)
    let router = RepositoryRouter()
    let localReader = try await router.reader(for: local)
    let status = try await localReader.workingStatus()
    XCTAssertEqual(status.dirty, false)
    for host in [UUID(), UUID()] {
      let remote = try RepositoryLocation.remote(host: host, path: local.path)
      for registered in [false, true] {
        if registered {
          try router.register(.init(location: remote, sharedLocation: remote))
        }
        do {
          _ = try await router.reader(for: remote)
          XCTFail("read local repository for remote")
        } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(.remote(host))) }
        do {
          _ = try await router.writer(for: remote)
          XCTFail("constructed local writer for remote")
        } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(.remote(host))) }
      }
      let failed = await WorkroomStatusResolver().resolve(location: remote, router: router)
      XCTAssertNil(failed.dirty)
      XCTAssertEqual(failed.failure, .unavailable)
      let context = try await router.context(for: remote)
      XCTAssertThrowsError(try RepositoryGitHub(context: context))
      let content = await DiffResolver(router: router).fileContent(
        for: DiffDescriptor(
          path: "file", change: .modified, source: .gitWorktree, isPreview: false), in: remote)
      XCTAssertNil(content)
    }
  }

  func testUnregisteredSiblingReadsButRequiresOwnershipToWrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let siblingPath = directory.appendingPathComponent("sibling").path
    try FileManager.default.createDirectory(atPath: siblingPath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = StatusCommandRunner()
    for path in [directory.path, siblingPath] {
      let initialized = await runner.run("git", ["init", "-q"], in: path, timeout: 10)
      XCTAssertTrue(initialized.ok, initialized.stderr)
    }
    let shared = try await RepositoryLocation.local(directory.path)
    let sibling = try await RepositoryLocation.local(siblingPath)
    let router = RepositoryRouter()
    try router.register(.init(location: shared, sharedLocation: shared))
    let reader = try await router.reader(for: sibling)
    XCTAssertNil(reader.context.sharedLocation)
    _ = try await reader.workingStatus()
    do {
      _ = try await router.writer(for: sibling)
      XCTFail("unregistered writer")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .registrationRequired) }
    try router.register(.init(location: sibling, sharedLocation: shared))
    let registered = try await router.reader(for: sibling)
    XCTAssertEqual(registered.context.sharedLocation, shared)
    _ = try await registered.workingStatus()
    // The old reader remains unowned after registration.
    XCTAssertNil(reader.context.sharedLocation)
  }

  /// A temp folder `isGitRepo` accepts: all `prepare` checks of a repository.
  private func dotGitFolder() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try makeGitCheckout(atPath: dir.path)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir.path
  }

  func testPreparationUsesTheProjectSharedRoot() async throws {
    let project = Project(
      path: try dotGitFolder(), vcs: "git",
      workrooms: [
        Workroom(name: "one", path: try dotGitFolder(), vcsName: "workroom/one", warnings: [])
      ])
    let entries = try await RepositoryRouter.prepare([project])
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].entry.sharedLocation, entries[1].entry.sharedLocation)
    // An unsupported vcs — including a stale "jj" from an old config — registers nothing.
    let unknown = try await RepositoryRouter.prepare([
      Project(path: "/unknown", vcs: "hg", workrooms: []),
      Project(path: "/stale", vcs: "jj", workrooms: []),
    ])
    XCTAssertTrue(unknown.isEmpty)
  }

  /// `.git` as a directory holding `HEAD`, `objects/` and `refs/` (a normal repo) or a FILE pointing
  /// at a `gitdir:` (a linked worktree) is a git repo; a `.jj` alone is not, and a `.jj` beside a
  /// `.git` (a colocated repo left from jj) still is. An EMPTY or HEAD-only `.git` directory, or a
  /// `.git` file that names no `gitdir:`, is not: git rejects each and walks UP to an ancestor
  /// repository instead (probed with git 2.56).
  func testIsGitRepoChecksForDotGitOnly() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    func folder(
      _ name: String, dirs: [String] = [], files: [String: String] = [:]
    ) throws -> URL {
      let url = root.appendingPathComponent(name)
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      for dir in dirs {
        try fm.createDirectory(
          at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
      }
      for (file, contents) in files {
        try Data(contents.utf8).write(to: url.appendingPathComponent(file))
      }
      return url
    }
    let head = [".git/HEAD": "ref: refs/heads/main\n"]
    let repo = [".git", ".git/objects", ".git/refs"]
    let gitdir = [".git": "gitdir: /elsewhere/.git/worktrees/x\n"]
    XCTAssertTrue(isGitRepo(at: try folder("dir", dirs: repo, files: head)))
    XCTAssertFalse(isGitRepo(at: try folder("head-only", dirs: [".git"], files: head)))
    XCTAssertFalse(
      isGitRepo(at: try folder("no-refs", dirs: [".git", ".git/objects"], files: head)))
    XCTAssertFalse(
      isGitRepo(at: try folder("no-objects", dirs: [".git", ".git/refs"], files: head)))
    let objectsFile = [".git/HEAD": "ref: refs/heads/main\n", ".git/objects": ""]
    XCTAssertFalse(
      isGitRepo(at: try folder("objects-file", dirs: [".git", ".git/refs"], files: objectsFile)))
    XCTAssertFalse(isGitRepo(at: try folder("no-head", dirs: repo)))
    XCTAssertTrue(isGitRepo(at: try folder("worktree", files: gitdir)))
    XCTAssertFalse(isGitRepo(at: try folder("jj", dirs: [".jj"])))
    XCTAssertTrue(isGitRepo(at: try folder("colocated", dirs: [".jj"] + repo, files: head)))
    XCTAssertFalse(isGitRepo(at: try folder("empty")))
    XCTAssertFalse(isGitRepo(at: try folder("empty-dot-git", dirs: [".git"])))
    XCTAssertFalse(isGitRepo(at: try folder("not-a-gitdir", files: [".git": "hello\n"])))
    XCTAssertFalse(isGitRepo(at: try folder("empty-file", files: [".git": ""])))
  }

  /// A project whose root is not a git repository registers nothing — not even its workrooms. git run
  /// at that root would discover an ANCESTOR repository and act on it.
  func testPreparationSkipsAProjectWhoseRootIsNotARepository() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = Project(
      path: root.path, vcs: "git",
      workrooms: [
        Workroom(name: "one", path: try dotGitFolder(), vcsName: "workroom/one", warnings: [])
      ])
    let registrations = try await RepositoryRouter.prepare([project])
    XCTAssertTrue(registrations.isEmpty, "\(registrations.map(\.localSourcePath))")
  }

  /// A workroom left from the jj era has a `.jj` and no `.git`. Registering it would hand git a folder
  /// whose discovery walks UP to an ancestor repository — and a commit there lands in that repo. So
  /// `prepare` skips it, and both a read and a write for it refuse rather than run git.
  func testPreparationSkipsAWorkroomWithoutDotGit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let gitWorkroom = root.appendingPathComponent(".workrooms/git")
    let jjWorkroom = root.appendingPathComponent(".workrooms/jj")
    for dir in [gitWorkroom, jjWorkroom.appendingPathComponent(".jj")] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = StatusCommandRunner()
    for path in [root.path, gitWorkroom.path] {
      let initialized = await runner.run("git", ["init", "-q"], in: path, timeout: 10)
      XCTAssertTrue(initialized.ok, initialized.stderr)
    }
    let project = Project(
      path: root.path, vcs: "git",
      workrooms: [
        Workroom(name: "git", path: gitWorkroom.path, vcsName: "workroom/git", warnings: []),
        Workroom(name: "jj", path: jjWorkroom.path, vcsName: "workroom/jj", warnings: []),
      ])
    let registrations = try await RepositoryRouter.prepare([project])
    XCTAssertEqual(registrations.map(\.localSourcePath), [root.path, gitWorkroom.path])

    let router = RepositoryRouter()
    router.replaceLocal(registrations)
    let jj = try await RepositoryLocation.local(jjWorkroom.path)
    XCTAssertNil(router.entry(for: jj))
    do {
      _ = try await router.reader(for: jj)
      XCTFail("built a reader for a folder with no .git")
    } catch VCSError.unsupportedRepo(_) {}
    do {
      _ = try await router.writer(for: jj)
      XCTFail("built a writer for a folder with no .git")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .registrationRequired) }
  }

  /// A remote workroom's path is on its host: it must never be registered as a local repository.
  func testPreparationSkipsRemoteWorkrooms() async throws {
    let local = try dotGitFolder()
    let root = try dotGitFolder()
    let project = Project(
      path: root, vcs: "git",
      workrooms: [
        Workroom(name: "local", path: local, vcsName: "workroom/local", warnings: []),
        Workroom(
          name: "remote", path: "/home/remote", vcsName: "workroom/remote", warnings: [],
          host: HostDescriptor()),
      ])
    let entries = try await RepositoryRouter.prepare([project])
    XCTAssertEqual(entries.map(\.localSourcePath), [root, local])
  }
}

private struct HostTestReader: VCSProviding {
  let context: RepositoryContext
  var delay: UInt64 = 0
  var marker: String { String(describing: context.location.host) }
  func log(limit: Int) async throws -> VCSHistoryPage {
    // Ignore cancellation, as native work does: the model must reject a late response itself.
    if delay > 0 {
      try await runBlocking { Thread.sleep(forTimeInterval: Double(delay) / 1_000_000_000) }
    }
    let commits = (0..<3).prefix(limit).map { index in
      VCSCommit(
        commitID: "\(marker)-\(index)", shortID: "\(index)",
        summary: marker, body: "", authors: [], timestamp: Date(timeIntervalSince1970: 0),
        refs: [], parentIDs: [])
    }
    return VCSHistoryPage(commits: commits, reachedEnd: limit >= 3)
  }
  func changeset(commitID: String) async throws -> VCSChangeset { throw VCSError.io("unused") }
  func fileDiff(commitID: String, path: String) async throws -> String {
    "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+\(marker)\n"
  }
  func workingFileDiff(path: String) async throws -> String {
    try await fileDiff(commitID: "", path: path)
  }
  func fileContent(rev: String, path: String) async throws -> String? { nil }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? { nil }
  func workingBaseFileContent(path: String) async throws -> String? {
    nil
  }
  func workingStatus() async throws -> WorkroomStatus { WorkroomStatus(dirty: false) }
  func currentRef() async throws -> VCSRef { .none }
}

private actor HostCountingRunner: StatusCommandRunning {
  private(set) var calls = 0
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    calls += 1
    return CommandResult(stdout: "", stderr: "unexpected command", exitCode: 1, timedOut: false)
  }
}

extension RepositoryRoutingTests {
  @MainActor
  func testHostSwitchDiscardsLateHistoryAndNilClearsSelection() async throws {
    let one = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let two = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let router = RepositoryRouter(remoteReader: { context in
      HostTestReader(context: context, delay: context.location == one ? 150_000_000 : 0)
    })
    for location in [one, two] {
      try router.register(.init(location: location, sharedLocation: location))
    }
    let model = HistoryModel(pageSize: 1, debounce: 0, router: router)
    model.focus(location: one)
    try await Task.sleep(nanoseconds: 30_000_000)
    model.focus(location: two)
    await model.awaitCurrentLoad()
    XCTAssertEqual(model.commits.first?.summary, String(describing: two.host))
    model.loadMore()
    await model.awaitCurrentLoad()
    XCTAssertEqual(model.commits.count, 2)
    try await Task.sleep(nanoseconds: 180_000_000)
    XCTAssertEqual(model.commits.first?.summary, String(describing: two.host))
    model.focus(nil)
    XCTAssertEqual(model.state, .idle)
    XCTAssertTrue(model.commits.isEmpty)
    XCTAssertNil(model.pushScope)
  }

  func testHostAndBackendSeparateDiffCacheEntries() async throws {
    let one = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let two = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let router = RepositoryRouter(remoteReader: { HostTestReader(context: $0) })
    for location in [one, two] {
      try router.register(.init(location: location, sharedLocation: location))
    }
    let cache = DiffCache()
    let resolver = DiffResolver(router: router, cache: cache)
    let descriptor = DiffDescriptor(
      path: "file", change: .modified, source: .commit("same"), isPreview: false)
    let first = await resolver.resolve(descriptor, in: one)
    let second = await resolver.resolve(descriptor, in: two)
    XCTAssertNotEqual(first, second)
    let repeated = await resolver.resolve(descriptor, in: one)
    XCTAssertEqual(first, repeated)
  }

  @MainActor
  func testRemoteFilesAndGitHubCannotInvokeLocalCommands() async throws {
    let location = try RepositoryLocation.remote(host: UUID(), path: "/private/tmp")
    let router = RepositoryRouter()
    try router.register(.init(location: location, sharedLocation: location))
    let runner = HostCountingRunner()
    let listing = await FileTreeModel.list(location: location, runner: runner, router: router)
    XCTAssertEqual(listing, .failed(.unavailable(location.host)))
    let files = FileTreeModel(runner: runner)
    files.activate(location: location)
    // A remote tree is listed through its host (#253). With no connection to it, the listing
    // fails, and nothing ran on this Mac.
    let deadline = ContinuousClock.now + .seconds(5)
    while files.state == .loading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(
      files.state, .failed(RepositoryRoutingError.unavailable(location.host).localizedDescription))
    do {
      _ = try await router.gitHub(for: location, resolver: WorkroomStatusResolver(runner: runner))
      XCTFail("remote GitHub service constructed")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(location.host)) }
    let calls = await runner.calls
    XCTAssertEqual(calls, 0)
  }
}

extension RepositoryRoutingTests {
  @MainActor
  func testRemotePRMutationDoesNotApplyOptimisticLocalState() async throws {
    let path = "/private/tmp"
    let local = try await RepositoryLocation.local(path)
    try RepositoryRouter.shared.register(
      .init(location: local, sharedLocation: local))
    let store = AppStore()
    store.projects = [Project(path: path, vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: path)
    let prior = PullRequestInfo(
      number: 1, title: "t", state: .open, isDraft: false,
      url: "u", reviewDecision: nil, reviewers: [])
    store.workroomStatuses[sid] = WorkroomStatus(dirty: false, pr: prior)
    let runner = HostCountingRunner()
    store.statusResolver = WorkroomStatusResolver(runner: runner)
    for host in [UUID(), UUID()] {
      let remote = try RepositoryLocation.remote(host: host, path: path)
      let item = AppStore.StatusWorkItem(
        sid: sid, path: path, vcs: "git", projectRoot: path,
        location: remote)
      store.performPRAction(.convertToDraft, number: 1, on: item)
      XCTAssertEqual(store.workroomStatuses[sid]?.pr, prior)
      XCTAssertFalse(store.prActionInFlight)
      XCTAssertEqual(
        store.errorMessage, RepositoryRoutingError.unavailable(remote.host).localizedDescription)
    }
    let calls = await runner.calls
    XCTAssertEqual(calls, 0)
  }

  @MainActor
  func testRegisteredLocalRemoteTargetPublishesItsBranch() async throws {
    let path = "/private/tmp/registered-target"
    let location = try await RepositoryLocation.local(path)
    try RepositoryRouter.shared.register(
      .init(location: location, sharedLocation: location))
    let store = AppStore()
    store.projects = [Project(path: path, vcs: "git", workrooms: [])]
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    let sid = SidebarID.root(project: path)
    let terminalTarget = try XCTUnwrap(store.target(for: sid))
    store.terminals.addTab(for: terminalTarget)
    store.selectedTargetID = sid
    let target = try XCTUnwrap(store.remoteTarget())
    XCTAssertEqual(target.location, location)
    store.remoteState.onBranchResolved?(target, "host-aware-branch")
    XCTAssertEqual(store.branchName(for: target.sid), "host-aware-branch")
  }
}

private struct FailingPreflightRunner: StatusCommandRunning {
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    if args.contains("symbolic-ref") {
      return CommandResult(stdout: "refs/heads/new\n", stderr: "", exitCode: 0, timedOut: false)
    }
    return CommandResult(
      stdout: "", stderr: "interrupted", exitCode: 1, timedOut: false, signaled: true)
  }
}

extension RepositoryRoutingTests {
  func testFailedPreflightCannotBecomeEmptySuccess() async throws {
    let writer = CLIVCSWriter(
      runner: FailingPreflightRunner(),
      makeProvider: { _ in GitProvider() }, gate: RepositoryWriteGate())
    do {
      _ = try await writer.commitPreflight(path: "/nonexistent")
      XCTFail("failed ref probe permitted commit")
    } catch { XCTAssertTrue(error is VCSError) }
    do {
      _ = try await writer.stagedContentAtRisk(
        path: "/nonexistent",
        files: [ChangedFile(path: "file", change: .modified)])
      XCTFail("failed staged-risk probe reported no risk")
    } catch { XCTAssertTrue(error is VCSError) }
  }

  @MainActor
  func testRemoteToSamePathLocalFileSelectionDoesNotNoOp() throws {
    let location = try RepositoryLocation.remote(host: UUID(), path: "/private/tmp")
    let model = FileTreeModel(runner: HostCountingRunner())
    model.activate(location: location)
    model.activate(path: location.path)
    XCTAssertEqual(model.state, .loading)
    model.activate(path: nil)
    XCTAssertEqual(model.state, .idle)
  }

  func testMissingPathStatusKeepsCompletionTimestamp() async throws {
    let location = try await RepositoryLocation.local("/private/tmp/missing-\(UUID().uuidString)")
    let status = await WorkroomStatusResolver().resolve(
      location: location, router: RepositoryRouter())
    XCTAssertEqual(status.failure, .missingPath)
    XCTAssertNotNil(status.localReadAt)
  }

  /// A workroom Jujutsu made before #266 has `.jj` and no `.git`. Listing it must not run git at
  /// all: git there would discover an ANCESTOR repository and list that tree instead.
  func testAFolderWithoutDotGitListsNothingAndRunsNoGit() async throws {
    let path = NSTemporaryDirectory() + "jj-era-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: path + "/.jj", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let location = try await RepositoryLocation.local(path)
    let runner = HostCountingRunner()
    let result = await FileTreeModel.list(
      location: location, runner: runner, router: RepositoryRouter())
    XCTAssertEqual(result, .unavailable)
    let calls = await runner.calls
    XCTAssertEqual(calls, 0, "git must not run in a folder without .git")
  }

  /// An unregistered location lists through git alone — one command, no registration needed.
  func testUnregisteredFileListRunsOnlyTheGitListing() async throws {
    let path = NSTemporaryDirectory() + "unregistered-\(UUID().uuidString)"
    try makeGitCheckout(atPath: path)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let location = try await RepositoryLocation.local(path)
    let runner = HostCountingRunner()
    let result = await FileTreeModel.list(
      location: location, runner: runner, router: RepositoryRouter())
    // The counting runner fails every command, so the listing is unavailable — not a registration
    // refusal, which only the jj listing ever raised.
    XCTAssertEqual(result, .unavailable)
    let calls = await runner.calls
    XCTAssertEqual(calls, 1, "only the git listing runs")
  }
}
