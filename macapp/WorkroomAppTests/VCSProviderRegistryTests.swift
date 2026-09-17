import Foundation
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
      try RepositoryRouter.Registration(location: remote, backend: .git, sharedLocation: local))
    let router = RepositoryRouter()
    try router.register(.init(location: remote, backend: .jj, sharedLocation: remote))
    router.replaceLocal([try .init(location: local, backend: .git, sharedLocation: local)])
    router.replaceLocal([])
    XCTAssertNil(router.entry(for: local))
    XCTAssertEqual(router.entry(for: remote)?.backend, .jj)
  }

  func testWriterAndSupportingReaderKeepCapturedBackend() async throws {
    let location = try await RepositoryLocation.local("/tmp/registered-no-repository")
    let router = RepositoryRouter()
    try router.register(.init(location: location, backend: .jj, sharedLocation: location))
    let writer = try await router.writer(for: location)
    let reader = try await router.reader(for: location)
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    XCTAssertEqual(writer.context.backend, .jj)
    XCTAssertEqual(writer.reader.context, writer.context)
    XCTAssertEqual(reader.context.backend, .jj)
    let replacement = try await router.reader(for: location)
    XCTAssertEqual(replacement.context.backend, .git)
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
          try router.register(.init(location: remote, backend: .git, sharedLocation: remote))
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

  func testUnregisteredJJSiblingRequiresOwnershipBeforeSnapshotOrWrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = StatusCommandRunner()
    let initialized = await runner.run(
      "jj", ["git", "init", "--colocate", "."], in: directory.path, timeout: 10)
    XCTAssertTrue(initialized.ok, initialized.stderr)
    let siblingPath = directory.appendingPathComponent("sibling").path
    let added = await runner.run(
      "jj", ["workspace", "add", siblingPath], in: directory.path, timeout: 10)
    XCTAssertTrue(added.ok, added.stderr)
    let shared = try await RepositoryLocation.local(directory.path)
    let sibling = try await RepositoryLocation.local(siblingPath)
    let router = RepositoryRouter()
    try router.register(.init(location: shared, backend: .jj, sharedLocation: shared))
    let reader = try await router.reader(for: sibling)
    XCTAssertNil(reader.context.sharedLocation)
    _ = try await reader.log(limit: 1)
    do {
      _ = try await reader.workingStatus()
      XCTFail("unregistered snapshot")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .registrationRequired) }
    do {
      _ = try await reader.workingFileDiff(path: "file", base: .workingCopy)
      XCTFail("unregistered diff snapshot")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .registrationRequired) }
    do {
      _ = try await router.writer(for: sibling)
      XCTFail("unregistered writer")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .registrationRequired) }
    try router.register(.init(location: sibling, backend: .jj, sharedLocation: shared))
    let registered = try await router.reader(for: sibling)
    XCTAssertEqual(registered.context.sharedLocation, shared)
    _ = try await registered.workingStatus()
    // The old reader remains an unowned snapshot after registration.
    XCTAssertNil(reader.context.sharedLocation)
  }

  func testPreparationUsesProjectBackendAndSharedRoot() async throws {
    let project = Project(
      path: "/tmp/project", vcs: "jj",
      workrooms: [
        Workroom(name: "one", path: "/tmp/workroom", vcsName: "workroom/one", warnings: [])
      ])
    let entries = try await RepositoryRouter.prepare([project])
    XCTAssertEqual(entries.count, 2)
    XCTAssertTrue(entries.allSatisfy { $0.entry.backend == .jj })
    XCTAssertEqual(entries[0].entry.sharedLocation, entries[1].entry.sharedLocation)
    let unknown = try await RepositoryRouter.prepare([
      Project(path: "/unknown", vcs: "hg", workrooms: [])
    ])
    XCTAssertTrue(unknown.isEmpty)
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
        commitID: "\(marker)-\(index)", shortID: "\(index)", changeID: nil,
        summary: marker, body: "", authors: [], timestamp: Date(timeIntervalSince1970: 0),
        refs: [], parentIDs: [], isWorkingCopy: false)
    }
    return VCSHistoryPage(commits: commits, reachedEnd: limit >= 3)
  }
  func changeset(commitID: String) async throws -> VCSChangeset { throw VCSError.io("unused") }
  func fileDiff(commitID: String, path: String) async throws -> String {
    "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+\(marker)\n"
  }
  func workingFileDiff(path: String, base: VCSWorkingDiffBase) async throws -> String {
    try await fileDiff(commitID: "", path: path)
  }
  func fileContent(rev: String, path: String) async throws -> String? { nil }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? { nil }
  func workingBaseFileContent(base: VCSWorkingDiffBase, path: String) async throws -> String? {
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
      try router.register(.init(location: location, backend: .git, sharedLocation: location))
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
      try router.register(.init(location: location, backend: .git, sharedLocation: location))
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
    let gitKey = DiffCache.Key(location: one, backend: .git, revision: "same", path: "file")
    let jjKey = DiffCache.Key(location: one, backend: .jj, revision: "same", path: "file")
    XCTAssertNotEqual(gitKey, jjKey)
  }

  @MainActor
  func testRemoteFilesAndGitHubCannotInvokeLocalCommands() async throws {
    let location = try RepositoryLocation.remote(host: UUID(), path: "/private/tmp")
    let router = RepositoryRouter()
    try router.register(.init(location: location, backend: .jj, sharedLocation: location))
    let runner = HostCountingRunner()
    let listing = await FileTreeModel.list(location: location, runner: runner, router: router)
    XCTAssertEqual(listing, .failed(.unavailable(location.host)))
    let files = FileTreeModel(runner: runner)
    files.activate(location: location)
    files.reload()
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
      .init(location: local, backend: .git, sharedLocation: local))
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
      .init(location: location, backend: .git, sharedLocation: location))
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
      vcs: "git", runner: FailingPreflightRunner(),
      makeProvider: { _ in GitProvider() }, gate: JJSnapshotGate())
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

  func testUnregisteredFileListDoesNotInvokeJJSnapshot() async throws {
    let location = try await RepositoryLocation.local(
      "/private/tmp/unregistered-\(UUID().uuidString)")
    let runner = HostCountingRunner()
    let result = await FileTreeModel.list(
      location: location, runner: runner, router: RepositoryRouter())
    XCTAssertEqual(result, .failed(.registrationRequired))
    let calls = await runner.calls
    XCTAssertEqual(calls, 1, "only immutable git listing may run before ownership is known")
  }
}
