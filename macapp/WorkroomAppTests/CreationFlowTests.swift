import AgentConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// A create's pane against `AppStore` (#483): where it opens, how it lands, how it ends, and what
/// its failures offer. Local creates run against a fake CLI; remote ones against a fake CLI, a fake
/// driver and a `FakeAgent` for the host's git, through `remoteCreateServices`.
@MainActor
final class CreationFlowTests: XCTestCase {
  private let projectPath = "/private/var/tmp/wr-creation-flow"
  private var emptyProject: Project { Project(path: projectPath, vcs: "git", workrooms: []) }

  private func project(_ names: [String]) -> Project {
    Project(
      path: projectPath, vcs: "git",
      workrooms: names.map {
        Workroom(name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
      })
  }

  private func makeStore(_ cli: WorkroomCLIProtocol) -> AppStore {
    let store = AppStore(cli: cli)
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.creationSuccessHold = .zero
    store.closesFinishedCreations = { true }
    return store
  }

  private func waitUntil(
    _ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<1000 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail(message, file: file, line: line)
  }

  // MARK: - Local

  /// Value: protects=AC 1 and AC 6 in a split, the pane opens beside the anchor before the CLI
  /// answers and becomes the workroom's in the same place; fails_when=the pane waits for the name,
  /// lands solo, or moves when the name arrives; no_claim=the drawing of the split
  func testAPaneOpensBesideItsAnchorAndTakesTheWorkroomsNameInPlace() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr"], hasSetup: false, gate: .beforeReady,
      existing: ["anchor"])
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let anchor = SidebarID.workroom(project: projectPath, name: "anchor")
    store.selectedTargetID = anchor

    let task = Task { await store.createWorkroom(in: emptyProject, splitAnchor: anchor) }
    await waitUntil({ fake.assignedCount == 1 }, "the create never reached the CLI")
    guard case .creation(_, let id)? = store.workroomSplits.first?.tabIDs.last else {
      fake.release("wr")
      await task.value
      return XCTFail("the creation pane must sit beside its anchor from the click")
    }
    XCTAssertEqual(store.workroomSplits.first?.tabIDs.first, anchor)
    XCTAssertEqual(store.selectedTargetID, .creation(project: projectPath, id: id))

    fake.release("wr")
    await task.value
    let created = SidebarID.workroom(project: projectPath, name: "wr")
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [anchor, created], "the same place")
    XCTAssertEqual(store.selectedTargetID, created)
  }

  /// Value: protects=D13, a finished create's checklist holds, terminal still withheld, then goes;
  /// fails_when=the run goes at once or never; no_claim=the crossfade
  func testAFinishedCreateHoldsItsChecklistThenGoes() async throws {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr"], hasSetup: false)
    fake.release("wr")
    let store = makeStore(fake)
    store.creationSuccessHold = .seconds(1)
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")

    let task = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil(
      { store.creationRuns.values.first?.outcome == .succeeded }, "the create never finished")
    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertTrue(store.isCreationBlocking(id), "the checklist still covers the pane")
    XCTAssertTrue(run.steps.allSatisfy(\.state.isComplete), "every row ended")

    await task.value
    XCTAssertTrue(store.creationRuns.isEmpty, "after the hold the run goes")
    XCTAssertFalse(store.isCreationBlocking(id), "and the terminal mounts")
  }

  /// Value: protects=a finished create's checklist stays, terminal withheld, until Done when it
  /// doesn't close by itself (the default); fails_when=the run goes on its own, or Done leaves it;
  /// no_claim=the footer's drawing
  func testAFinishedCreateWaitsForDone() async throws {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr"], hasSetup: false)
    fake.release("wr")
    let store = makeStore(fake)
    store.closesFinishedCreations = { false }
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")

    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first, "the run waits for Done")
    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertTrue(store.isCreationBlocking(id), "the checklist still covers the pane")

    store.finishCreation(run)
    XCTAssertTrue(store.creationRuns.isEmpty)
    XCTAssertFalse(store.isCreationBlocking(id), "Done mounts the terminal")
  }

  /// Value: protects=unticking "Close automatically when done" during the hold keeps the finished
  /// checklist for Done; fails_when=the run still closes after the box is unticked;
  /// no_claim=the Defaults key behind the closure
  func testUntickingCloseDuringTheHoldKeepsTheChecklist() async throws {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr"], hasSetup: false)
    fake.release("wr")
    let store = makeStore(fake)
    store.creationSuccessHold = .milliseconds(50)
    var answers = [true, false]
    store.closesFinishedCreations = { answers.isEmpty ? false : answers.removeFirst() }

    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first, "the run waits for Done")
    XCTAssertEqual(run.outcome, .succeeded)
    store.finishCreation(run)
    XCTAssertTrue(store.creationRuns.isEmpty)
  }

  /// Value: protects=a local create in a project with scripts/workroom_setup lists the setup row from
  /// the first frame; fails_when=the row is left out though the script exists;
  /// no_claim=the CLI actually running the script
  func testALocalCreateWithASetupScriptListsItsRow() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent("scripts/workroom_setup").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.path
    let fake = GatedFakeCLI(projectPath: path, names: ["wr"], hasSetup: true, gate: .beforeReady)
    let store = makeStore(fake)

    let task = Task {
      await store.createWorkroom(in: Project(path: path, vcs: "git", workrooms: []))
    }
    await waitUntil({ fake.assignedCount == 1 }, "the create never reached the CLI")
    XCTAssertEqual(
      store.creationRuns.values.first?.steps.map(\.id), ["fetch", "worktree", "script"])
    fake.release("wr")
    await task.value
  }

  /// Value: protects=AC 7, a successful create mounts its terminal with no click and the auto-run
  /// armed at landing fires as its first tab; fails_when=the run outlives success or the arm is
  /// lost; no_claim=the shell itself (no PTY is spawned)
  func testASuccessfulCreateMountsItsTerminalWithItsAutoRun() async throws {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr"], hasSetup: true)
    fake.release("wr")
    let store = makeStore(fake)
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: true), forProject: projectPath)
    defer { store.setRunConfig(.empty, forProject: projectPath) }

    await store.createWorkroom(in: emptyProject)

    XCTAssertFalse(store.isCreationBlocking(id), "nothing withholds the terminal")
    guard case .running = store.runStates[id] else {
      return XCTFail("the armed auto-run must have started")
    }
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 2, "the run, then the shell")
    let target = try XCTUnwrap(store.target(for: .workroom(project: projectPath, name: "wr")))
    store.ensureInitialTerminal(for: target)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 2, "the mount opens nothing more")
  }

  /// Value: protects=an armed auto-run starts when the create succeeds, while its checklist still
  /// waits for Done, backgrounded beside the shell Done lands on (owner); fails_when=the run waits
  /// for Done, or Done opens a second run or no shell; no_claim=the run's process (no PTY is spawned)
  func testAnArmedAutoRunStartsBeforeDone() async throws {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr"], hasSetup: true)
    fake.release("wr")
    let store = makeStore(fake)
    store.closesFinishedCreations = { false }
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: true), forProject: projectPath)
    defer { store.setRunConfig(.empty, forProject: projectPath) }

    await store.createWorkroom(in: emptyProject)

    let run = try XCTUnwrap(store.creationRuns.values.first, "the checklist waits for Done")
    XCTAssertTrue(store.isCreationBlocking(id), "the checklist still covers the pane")
    XCTAssertFalse(store.isRunBlocked(id), "a made workroom can run")
    guard case .running = store.runStates[id] else {
      return XCTFail("the armed auto-run must start without waiting for Done")
    }
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 2, "the run, then the shell")

    store.finishCreation(run)
    let target = try XCTUnwrap(store.target(for: .workroom(project: projectPath, name: "wr")))
    store.ensureInitialTerminal(for: target)  // as the pane mounting after Done does
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 2, "Done adds no second run or shell")
  }

  /// A local create whose worktree fails the first time and succeeds the second.
  private final class WorktreeFailsOnceCLI: WorkroomCLIProtocol, @unchecked Sendable {
    let projectPath: String
    private let lock = NSLock()
    private var calls = 0
    private var made: [String] = []
    init(projectPath: String) { self.projectPath = projectPath }
    var createCalls: Int { lock.withLock { calls } }

    func list(warnings: String, project: String?) async throws -> ListResponse {
      let names = lock.withLock { made }
      return ListResponse(
        projects: [
          Project(
            path: projectPath, vcs: "git",
            workrooms: (["anchor"] + names).map {
              Workroom(
                name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
            })
        ], workroomsDir: nil, configPath: nil)
    }
    func addProject(_ path: String, create: Bool) async throws -> String { path }
    func create(project: String, onEvent: @escaping @Sendable (StreamEvent) -> Void) async throws
      -> CreateResponse
    {
      let first = lock.withLock {
        calls += 1
        return calls == 1
      }
      let path = "\(projectPath)/.workrooms/wr"
      onEvent(CreateEvents.step("fetch", "skipped", "No remote to fetch from"))
      onEvent(CreateEvents.step("worktree", "running"))
      onEvent(CreateEvents.log("$ git worktree add -b workroom/wr \(path)", step: "worktree"))
      if first {
        onEvent(CreateEvents.log("fatal: '\(path)' already exists", step: "worktree"))
        onEvent(CreateEvents.step("worktree", "failed", "git worktree add failed"))
        throw WorkroomCLIError.cli(kind: "VCSError", message: "git worktree add failed")
      }
      onEvent(CreateEvents.step("worktree", "done"))
      lock.withLock { made.append("wr") }
      onEvent(CreateEvents.created(name: "wr", path: path, setup: false))
      onEvent(CreateEvents.step("script", "skipped", "No setup script"))
      return CreateResponse(name: "wr", path: path, vcs: "git", project: project)
    }
    func create(
      project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
    ) async throws -> CreateResponse { throw WorkroomCLIError.timedOut }
    func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}
    func deleteProject(
      _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
    ) async throws -> [URL] { [] }
  }

  /// Value: protects=AC 8, a failed `git worktree add` shows the worktree row failed with its
  /// log, and Try Again re-runs in the same pane; fails_when=the failure goes to an error sheet,
  /// the log is lost, or Try Again lands elsewhere; no_claim=the footer's drawing
  func testAFailedWorktreeKeepsItsPaneAndTryAgainRunsThere() async throws {
    let store = makeStore(WorktreeFailsOnceCLI(projectPath: projectPath))
    store.projects = [project(["anchor"])]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let anchor = SidebarID.workroom(project: projectPath, name: "anchor")
    store.selectedTargetID = anchor

    await store.createWorkroom(in: emptyProject, splitAnchor: anchor)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    let pane = SidebarID.creation(project: projectPath, id: run.id)
    XCTAssertEqual(run.outcome, .failedBeforeWorkroom(message: "git worktree add failed"))
    XCTAssertEqual(run.steps[1].state, .failed)
    XCTAssertEqual(run.steps[1].log.last, "fatal: '\(projectPath)/.workrooms/wr' already exists")
    XCTAssertNil(store.errorMessage, "the pane says it, not an error sheet")
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [anchor, pane], "the pane stays put")

    await store.retryCreation(run)

    XCTAssertEqual(
      store.workroomSplits.first?.tabIDs, [anchor, .workroom(project: projectPath, name: "wr")],
      "Try Again ran in the same pane")
    XCTAssertTrue(store.creationRuns.isEmpty)
  }

  /// Value: protects=AC 2, a running create's pane can't be taken out of its split (its pane has no
  /// ✕, and the store refuses too); fails_when=the running pane leaves the split; no_claim=the bare
  /// pane's drawing, and a failed pane's Close (testAFailedWorktreeKeepsItsPaneAndTryAgainRunsThere
  /// and testCloseGoesBackToThePreviousSelection)
  func testARunningCreatesPaneCanNotBeTakenOutOfItsSplit() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr"], hasSetup: false, gate: .beforeReady,
      existing: ["anchor"])
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let anchor = SidebarID.workroom(project: projectPath, name: "anchor")
    store.selectedTargetID = anchor

    let task = Task { await store.createWorkroom(in: emptyProject, splitAnchor: anchor) }
    await waitUntil({ fake.assignedCount == 1 }, "the create never reached the CLI")
    guard let pane = store.workroomSplits.first?.tabIDs.last else {
      fake.release("wr")
      await task.value
      return XCTFail("no creation pane in the split")
    }
    store.removeWorkroomSplitMember(pane)
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [anchor, pane], "the running pane stays")

    fake.release("wr")
    await task.value
  }

  /// Value: protects=D17, VoiceOver hears a failure naming its step and a success naming the
  /// workroom, once each; fails_when=a step-by-step announcement is posted, or a moment is silent;
  /// no_claim=that VoiceOver speaks them (the poster is replaced)
  func testAFailureAndASuccessAreAnnounced() async throws {
    var heard: [String] = []
    let post = AppStore.announceCreation
    AppStore.announceCreation = { heard.append($0) }
    defer { AppStore.announceCreation = post }
    let store = makeStore(WorktreeFailsOnceCLI(projectPath: projectPath))
    store.projects = [project(["anchor"])]

    await store.createWorkroom(in: emptyProject)
    XCTAssertEqual(heard, ["Couldn't create the workroom: Create worktree failed"])
    let run = try XCTUnwrap(store.creationRuns.values.first)
    await store.retryCreation(run)
    XCTAssertEqual(heard.last, "wr is ready")
    XCTAssertEqual(heard.count, 2)
  }

  /// Value: protects=a double-click on Try Again starts one create, not two (for a remote create, a
  /// second paid machine); fails_when=the second click starts its own create; no_claim=the button
  func testTryAgainTwiceOnOneFailureStartsOneCreate() async throws {
    let fake = WorktreeFailsOnceCLI(projectPath: projectPath)
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first)

    let first = Task { await store.retryCreation(run) }
    let second = Task { await store.retryCreation(run) }
    await first.value
    await second.value

    XCTAssertEqual(fake.createCalls, 2, "the failed create and one retry")
  }

  /// Value: protects=Close on a failed create removes its pane and goes back to what was selected;
  /// fails_when=the pane or its run stays, or the selection is lost; no_claim=the split case
  /// (collapses through `removeWorkroomSplitMember`, covered by the split tests)
  func testCloseGoesBackToThePreviousSelection() async throws {
    let store = makeStore(WorktreeFailsOnceCLI(projectPath: projectPath))
    store.projects = [project(["anchor"])]
    store.selectedTargetID = .root(project: projectPath)

    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(store.selectedTargetID, .creation(project: projectPath, id: run.id))

    store.closeCreation(run)
    XCTAssertEqual(store.selectedTargetID, .root(project: projectPath))
    XCTAssertTrue(store.creationRuns.isEmpty)
    XCTAssertTrue(store.creationRunForTarget.isEmpty)
  }

  /// Value: protects=O1, Delete Project is refused while a create runs, before it has a name;
  /// fails_when=the project is torn down under an unnamed create; no_claim=a named create
  /// (`creatingWorkrooms`, covered by the existing guard)
  func testDeleteProjectIsRefusedWhileAnUnnamedCreateRuns() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr"], hasSetup: false, gate: .beforeReady)
    let store = makeStore(fake)
    store.projects = [emptyProject]

    let task = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 1 }, "the create never reached the CLI")
    store.deleteProject(emptyProject, scope: .configOnly)
    XCTAssertEqual(
      store.errorMessage,
      "A workroom is still being created in this project. Wait for it to finish, then try again.")
    XCTAssertTrue(store.deletingProjects.isEmpty, "nothing was deleted")

    fake.release("wr")
    await task.value
  }

  /// Value: protects=R5, each unnamed create lists a provisional row, numbered per destination,
  /// whose id reselects its pane, and which gives way to the named row on landing; fails_when=a
  /// row is missing, mislabelled, outlives its landing, or doesn't resolve; no_claim=the row's
  /// drawing (the UI lane's)
  func testUnnamedCreatesListProvisionalRowsUntilTheyLand() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: false, gate: .beforeReady)
    let store = makeStore(fake)
    store.projects = [emptyProject]

    let a = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 1 }, "A never reached the CLI")
    let b = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 2 }, "B never reached the CLI")

    let rows = store.provisionalCreationRows(inProject: projectPath)
    XCTAssertEqual(rows.map(\.label), ["New workroom · This Mac", "New workroom · This Mac 2"])

    store.selectedTargetID = .root(project: projectPath)
    store.selectedTargetID = rows[0].id
    XCTAssertEqual(store.selectedTarget?.unavailability, .creating, "the row reselects its pane")

    fake.release("wr-a")
    await a.value
    XCTAssertEqual(
      store.provisionalCreationRows(inProject: projectPath).map(\.id), [rows[1].id],
      "A's row gave way")
    XCTAssertTrue(store.projects.first?.workrooms.contains { $0.name == "wr-a" } ?? false)

    fake.release("wr-b")
    await b.value
    XCTAssertTrue(store.provisionalCreationRows(inProject: projectPath).isEmpty)
  }

  // MARK: - Remote

  private final class RemoteFakeCLI: WorkroomCLIProtocol, @unchecked Sendable {
    let projectPath: String
    private let lock = NSLock()
    private var reserved: [String] = []
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    init(projectPath: String) { self.projectPath = projectPath }

    func list(warnings: String, project: String?) async throws -> ListResponse {
      let names = lock.withLock { ["anchor"] + reserved }
      return ListResponse(
        projects: [
          Project(
            path: projectPath, vcs: "git",
            workrooms: names.map {
              Workroom(name: $0, path: "/home/boxd/r", vcsName: "workroom/\($0)", warnings: [])
            })
        ], workroomsDir: nil, configPath: nil)
    }
    func createRemote(project: String, hostPath: String, descriptor: Data) async throws
      -> CreateResponse
    {
      lock.withLock {
        reserved.append("calm-river")
        log.append("reserve")
      }
      return CreateResponse(name: "calm-river", path: hostPath, vcs: "git", project: project)
    }
    func setHost(project: String, workroom: String?, descriptor: Data?) async throws {
      let state = try descriptor.map { try JSONDecoder().decode(HostDescriptor.self, from: $0) }
      lock.withLock { log.append("host \(state?.state ?? "serving")") }
    }
    func addProject(_ path: String, create: Bool) async throws -> String { path }
    func create(
      project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
    ) async throws -> CreateResponse { throw WorkroomCLIError.timedOut }
    func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {
      lock.withLock {
        reserved.removeAll { $0 == name }
        log.append("delete \(name)")
      }
    }
    func deleteProject(
      _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
    ) async throws -> [URL] { [] }
  }

  private final class FakeDriver: HostTerminalDriver, @unchecked Sendable {
    let destroyFails: Bool
    private let lock = NSLock()
    private var destroyed = 0
    var destroys: Int { lock.withLock { destroyed } }
    init(destroyFails: Bool = false) { self.destroyFails = destroyFails }

    var agentSocket: String { "/home/boxd/.workroom/agent.sock" }
    func create() async throws -> HostID { .remote(UUID()) }
    func destroy(_ host: HostID) async throws {
      lock.withLock { destroyed += 1 }
      if destroyFails { throw HostDriverError.provisioning("remove failed") }
    }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no exec")
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)]
    ) throws -> String { "" }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }
    func lastAttachLostLink(of session: UUID, on host: HostID) -> Bool { false }
  }

  @MainActor
  private final class FakeSetup: RemoteSetup {
    var isReady = false
    func cancel() {}
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
  }

  private static let gitFails =
    #"{"stdout":"","stderr":"fatal: repository 'https://github.com/o/r.git/' not found","exit_code":128,"timed_out":false,"signaled":false}"#
  private static let gitSucceeds =
    #"{"stdout":"","stderr":"","exit_code":0,"timed_out":false,"signaled":false}"#

  private func services(
    driver: any HostTerminalDriver, agent: FakeAgent?, setup: (any RemoteSetup)? = nil,
    plans: Counter = Counter(), hosts: Counter = Counter(),
    gitHubToken: (@Sendable () async throws -> String)? = nil,
    grantRepository: (@Sendable (GitHubRepository) async throws -> Void)? = nil
  ) -> RemoteCreateServices {
    let repository = GitHubRepository(host: "github.com", owner: "o", name: "r")
    return RemoteCreateServices(
      plan: { _, _ in
        plans.add()
        return RemoteCreatePlan(
          repository: repository!, cloneURL: "https://github.com/o/r.git", startBranch: nil,
          defaultNotUsed: nil)
      },
      setupNeeded: { _ in setup },
      host: { _ in
        hosts.add()
        guard let agent else { throw HostDriverError.provisioning("no host") }
        let socket = agent.socketPath
        return RemoteCreateHost(
          key: .boxd(org: "acme", account: "u"), driver: driver,
          environment: RemoteProvisioning.Environment(
            driver: driver, agentSocket: driver.agentSocket, gitHubToken: gitHubToken,
            grantRepository: grantRepository,
            connect: { host in try await AgentVCSConnection.connect(host: host, socketPath: socket)
            }
          ))
      })
  }

  private func remoteStore(_ cli: RemoteFakeCLI) -> AppStore {
    let store = makeStore(cli)
    store.projects = [project(["anchor"])]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    return store
  }

  /// Value: protects=a repository the provider refuses fails the repository row, not the account
  /// row the checklist had moved on to; fails_when=the failure lands on account or image;
  /// no_claim=a real provider (a fake grant refuses)
  func testARefusedRepositoryGrantFailsTheRepositoryRow() async throws {
    let agent = try FakeAgent(version: 4)
    defer { agent.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(
      driver: FakeDriver(), agent: agent,
      grantRepository: { _ in throw HostDriverError.provisioning("o/r is not shared") })

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.steps.first { $0.id == "repository" }?.state, .failed)
    XCTAssertEqual(run.steps.first { $0.id == "account" }?.state, .done)
  }

  /// Value: protects=AC 10 and O2 solo, a remote create failing in `clone` keeps its pane, the git
  /// error in the clone row's log, and Try Again, with its machine rolled back; fails_when=the
  /// reload prunes the pane, the log is lost, or the machine stays; no_claim=a real host (a fake
  /// driver and FakeAgent stand in)
  func testARemoteCreateFailingInCloneKeepsItsPaneAndLog() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitFails)
    defer { agent.stop() }
    let cli = RemoteFakeCLI(projectPath: projectPath)
    let driver = FakeDriver()
    let store = remoteStore(cli)
    store.remoteCreateServices = services(driver: driver, agent: agent)

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    guard case .remoteFailed(let message, leftBehind: false) = run.outcome else {
      return XCTFail("expected a rolled-back failure, got \(run.outcome)")
    }
    XCTAssertTrue(message.contains("not found"), message)
    XCTAssertEqual(store.selectedTargetID, .creation(project: projectPath, id: run.id))
    XCTAssertEqual(store.selectedTarget?.unavailability, .creating, "the pane survived the reload")
    let clone = try XCTUnwrap(run.steps.first { $0.id == "clone" })
    XCTAssertEqual(clone.state, .failed)
    XCTAssertEqual(
      clone.log.first,
      "$ git clone --quiet --origin origin -- https://github.com/o/r.git /home/boxd/r")
    XCTAssertTrue(clone.log.contains { $0.contains("not found") }, "\(clone.log)")
    XCTAssertEqual(run.steps.first { $0.id == "checkout" }?.state, .skipped(reason: nil))
    XCTAssertEqual(driver.destroys, 1, "the machine was rolled back")
    XCTAssertTrue(cli.calls.contains("delete calm-river"), "and its record forgotten")
    XCTAssertFalse(store.projects.first?.workrooms.contains { $0.name == "calm-river" } ?? true)
    XCTAssertTrue(store.creatingWorkrooms.isEmpty)
  }

  /// Value: protects=O2 in a split, the rolled-back pane stays beside its anchor; fails_when=the
  /// reload prunes the split leaf; no_claim=a real host
  func testARemoteCreateFailingInCloneKeepsItsSplitPane() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitFails)
    defer { agent.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(), agent: agent)
    let anchor = SidebarID.workroom(project: projectPath, name: "anchor")
    store.selectedTargetID = anchor

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd, splitAnchor: anchor)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(
      store.workroomSplits.first?.tabIDs, [anchor, .creation(project: projectPath, id: run.id)])
  }

  /// Value: protects=D12, a failure whose machine could not be taken down keeps the workroom's
  /// pane and record for Delete; fails_when=the pane goes back to provisional or leftBehind is
  /// lost; no_claim=a real host
  func testARemoteCreateThatLeavesItsMachineKeepsItsWorkroomPane() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitFails)
    defer { agent.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(destroyFails: true), agent: agent)

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    guard case .remoteFailed(_, leftBehind: true) = run.outcome else {
      return XCTFail("expected a left-behind failure, got \(run.outcome)")
    }
    let id = TerminalTarget.workroomID(project: projectPath, name: "calm-river")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-river"))
    XCTAssertTrue(store.isCreationBlocking(id), "its pane still shows the failed run")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "and Delete is allowed")
  }

  /// Value: protects=a remote create's steps, landing and end: repository, account, connect,
  /// clone and checkout run in order, the pane becomes the workroom's, and the run ends;
  /// fails_when=a step is out of order or left running, or the pane is lost; no_claim=a driver's
  /// own machine steps (the fake reports none)
  func testARemoteCreateLandsInItsPaneAndEnds() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(), agent: agent)
    // The run waits for Done: a create against the fake agent ends within one poll of the
    // run's start, so watching `creationRuns` for it mid-flight is a race.
    store.closesFinishedCreations = { false }

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)
    let run = try XCTUnwrap(store.creationRuns.values.first, "the run waits for Done")

    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertEqual(
      run.steps.map(\.state),
      [
        .done, .done, .skipped(reason: nil), .skipped(reason: nil), .done, .done, .done,
      ])
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-river"))
    store.finishCreation(run)
    XCTAssertTrue(store.creationRuns.isEmpty)
    XCTAssertTrue(store.creatingWorkrooms.isEmpty)
  }

  /// What a fake script service was asked, and whether the workroom was still undeletable then.
  @MainActor
  private final class ScriptCall {
    var request: RemoteWorkrooms.ScriptRequest?
    var undeletable = false
  }

  /// A project whose root has a setup script, so a create of any kind lists its row.
  private func projectWithASetupScript() throws -> Project {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent("scripts/workroom_setup").path,
      contents: Data("#!/bin/sh\n".utf8))
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return Project(path: dir.path, vcs: "git", workrooms: [])
  }

  /// Value: protects=a remote create runs its setup script on the host after the checkout, under
  /// the shared "Run setup script" row with its lines, while the workroom is still undeletable
  /// (C2), and lands when it passes; fails_when=the script is skipped, runs once the workroom can be
  /// deleted, or its lines miss the row; no_claim=a real host (RemoteScriptTests runs the agent)
  func testARemoteCreateRunsItsSetupScriptBeforeItCanBeDeleted() async throws {
    let project = try projectWithASetupScript()
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let store = makeStore(RemoteFakeCLI(projectPath: project.path))
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let call = ScriptCall()
    var services = services(driver: FakeDriver(), agent: agent)
    services.script = { [weak store] request in
      call.request = request
      call.undeletable = !(store?.creatingWorkrooms.isEmpty ?? true)
      request.onStart()
      request.onLine("installing")
      return .passed
    }
    store.remoteCreateServices = services
    // The run waits for Done, as in `testARemoteCreateLandsInItsPaneAndEnds`.
    store.closesFinishedCreations = { false }

    await store.createRemoteWorkroom(in: project, place: .boxd)
    let run = try XCTUnwrap(store.creationRuns.values.first, "the run waits for Done")

    XCTAssertEqual(run.outcome, .succeeded)
    let row = try XCTUnwrap(run.steps.first { $0.id == "script" })
    XCTAssertEqual(row.title, "Run setup script")
    XCTAssertEqual(row.state, .done)
    XCTAssertEqual(row.log, ["installing"])
    let request = try XCTUnwrap(call.request)
    XCTAssertEqual(request.script, .setup)
    XCTAssertEqual(request.workroom, "calm-river")
    XCTAssertEqual(request.rootScript?.path, project.path + "/scripts/workroom_setup")
    XCTAssertTrue(call.undeletable, "the script ran after the workroom could be deleted")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty)
  }

  /// Value: protects=a remote setup that fails ends the create as a local one does
  /// (`.setupScriptFailed`, Open Anyway or Delete), with the workroom and its machine kept;
  /// fails_when=the machine is destroyed, the record forgotten, or the outcome is a remote failure;
  /// no_claim=a real host
  func testARemoteSetupFailureKeepsTheWorkroomAndItsMachine() async throws {
    let project = try projectWithASetupScript()
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let cli = RemoteFakeCLI(projectPath: project.path)
    let driver = FakeDriver()
    let store = makeStore(cli)
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let why =
      "setup script failed: /home/boxd/r/scripts/workroom_setup returned a non-zero exit code"
    var services = services(driver: driver, agent: agent)
    services.script = { request in
      request.onStart()
      return .failed(why)
    }
    store.remoteCreateServices = services

    await store.createRemoteWorkroom(in: project, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.outcome, .setupScriptFailed(message: why))
    XCTAssertEqual(run.steps.first { $0.id == "script" }?.state, .failed)
    XCTAssertEqual(driver.destroys, 0, "the machine was taken down")
    XCTAssertFalse(cli.calls.contains("delete calm-river"), "the record was forgotten")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "and Delete is allowed")
  }

  /// Value: protects=a setup that fails before its script starts (the connect, its check, the
  /// root's copy) fails the "Run setup script" row, not the checkout before it; fails_when=the
  /// checkout row is marked failed and the script row skipped; no_claim=which failures those are
  /// (RemoteScriptTests)
  func testARemoteSetupThatFailsBeforeItsScriptStartsFailsItsOwnRow() async throws {
    let project = try projectWithASetupScript()
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let store = makeStore(RemoteFakeCLI(projectPath: project.path))
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    var services = services(driver: FakeDriver(), agent: agent)
    services.script = { _ in .failed("setup script failed: couldn't reach the host") }
    store.remoteCreateServices = services

    await store.createRemoteWorkroom(in: project, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.steps.first { $0.id == "checkout" }?.state, .done)
    XCTAssertEqual(run.steps.first { $0.id == "script" }?.state, .failed)
  }

  /// Value: protects=a root with a `.worktreeinclude` gets its "Copy local files" row after the
  /// checkout, and a copy that fails ends that row as a warning while the create still lands and
  /// its host is kept (#367, Q4); fails_when=the copy is skipped, its failure fails the create, or
  /// the host is destroyed; no_claim=a real archive or host (RemoteIncludeTests covers those)
  func testARemoteCreateWhoseCopyFailsStillLandsWithAWarning() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent(".worktreeinclude").path, contents: Data(".env\n".utf8))
    defer { try? FileManager.default.removeItem(at: dir) }
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let driver = FakeDriver()
    let store = makeStore(RemoteFakeCLI(projectPath: dir.path))
    let project = Project(path: dir.path, vcs: "git", workrooms: [])
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    store.remoteCreateServices = services(driver: driver, agent: agent)
    // The run waits for Done, as in `testARemoteCreateLandsInItsPaneAndEnds`.
    store.closesFinishedCreations = { false }

    await store.createRemoteWorkroom(in: project, place: .boxd)
    let run = try XCTUnwrap(store.creationRuns.values.first, "the run waits for Done")

    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertEqual(run.steps.suffix(2).map(\.id), ["checkout", "include"])
    guard case .warning(let text) = run.steps.last?.state else {
      return XCTFail("include ended \(String(describing: run.steps.last?.state))")
    }
    XCTAssertTrue(text.contains("includeArchive is not faked"), text)
    XCTAssertEqual(driver.destroys, 0, "a failed copy took the host down")
  }

  /// Value: protects=AC 11, with boxd not set up the pane opens and waits on its account step under
  /// the sheet, and Create Workroom carries on the same run without re-checking the repository;
  /// fails_when=the sheet replaces the pane, the repository is checked twice, or a second create
  /// starts; no_claim=the sheet's own steps
  func testTheSetupSheetHoldsTheRunAndCreateCarriesItOn() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let plans = Counter()
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(
      driver: FakeDriver(), agent: agent, setup: FakeSetup(), plans: plans)

    let task = Task { await store.createRemoteWorkroom(in: emptyProject, place: .boxd) }
    await waitUntil({ store.pendingRemoteSetup != nil }, "the setup sheet never came up")
    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(store.selectedTargetID, .creation(project: projectPath, id: run.id))
    XCTAssertEqual(run.steps[1].state, .waitingForUser)

    store.resolveRemoteSetup(carryOn: true)
    await task.value

    XCTAssertEqual(plans.count, 1, "the repository was checked once")
    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertEqual(run.steps[1].state, .done)
    XCTAssertNil(store.pendingRemoteSetup)
  }

  /// Value: protects=Cancel on the setup sheet ends the run and removes its pane; fails_when=the
  /// run or pane stays, or the create carries on; no_claim=none beyond protects
  func testCancellingTheSetupSheetRemovesThePane() async throws {
    let hosts = Counter()
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.selectedTargetID = .root(project: projectPath)
    store.remoteCreateServices = services(
      driver: FakeDriver(), agent: nil, setup: FakeSetup(), hosts: hosts)

    let task = Task { await store.createRemoteWorkroom(in: emptyProject, place: .boxd) }
    await waitUntil({ store.pendingRemoteSetup != nil }, "the setup sheet never came up")
    let run = try XCTUnwrap(store.creationRuns.values.first)
    store.resolveRemoteSetup(carryOn: false)
    await task.value

    XCTAssertEqual(run.outcome, .cancelled)
    XCTAssertTrue(store.creationRuns.isEmpty)
    XCTAssertEqual(store.selectedTargetID, .root(project: projectPath))
    XCTAssertEqual(hosts.count, 0, "nothing was made")
  }

  /// Value: protects=section 6, two providers' sheets queue, one at a time across the app, each
  /// announced as it comes up (D17); fails_when=the second provider's sheet replaces the first, is
  /// never shown, or its creates are stranded; no_claim=the sheets' drawing
  func testTwoProvidersSetupSheetsQueueOneAfterTheOther() async throws {
    var heard: [String] = []
    let post = AppStore.announceCreation
    AppStore.announceCreation = { heard.append($0) }
    defer { AppStore.announceCreation = post }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(), agent: nil, setup: FakeSetup())

    let boxd = Task { await store.createRemoteWorkroom(in: emptyProject, place: .boxd) }
    await waitUntil({ store.pendingRemoteSetup != nil }, "boxd's sheet never came up")
    let exeDev = Task { await store.createRemoteWorkroom(in: emptyProject, place: .exeDev) }
    await waitUntil(
      { store.projectStore.remoteSetupWaits.count == 2 }, "exe.dev's create never queued")
    XCTAssertEqual(store.pendingRemoteSetup?.place, .boxd, "the first sheet stays up")

    store.resolveRemoteSetup(carryOn: false)
    await boxd.value
    XCTAssertEqual(store.pendingRemoteSetup?.place, .exeDev, "the next provider's sheet follows")
    let waiting = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(waiting.kind, .exeDev)
    XCTAssertEqual(waiting.steps[1].state, .waitingForUser)

    store.resolveRemoteSetup(carryOn: false)
    await exeDev.value
    XCTAssertNil(store.pendingRemoteSetup)
    XCTAssertTrue(store.creationRuns.isEmpty)
    XCTAssertEqual(heard, ["boxd needs setting up", "exe.dev needs setting up"])
  }

  /// A stand-in container runtime: `image inspect` answers `inspect` (0 when the image is here),
  /// `pull` succeeds, and anything else (the container's `run`) fails, ending the create there.
  private func stubRuntime(inspect: Int) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let runtime = directory.appendingPathComponent("docker")
    try """
    #!/bin/sh
    case "$*" in
      "image inspect"*) exit \(inspect) ;;
      pull*) exit 0 ;;
    esac
    exit 1
    """.write(to: runtime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    return runtime
  }

  /// Value: protects=section 3, a container create whose host image is already here shows its
  /// image step skipped with "Image already downloaded", and one that pulls shows it done;
  /// fails_when=a present image reads as pulled, or a pull reads as skipped; no_claim=a real runtime
  /// (a stub script stands in for docker)
  func testAnImageAlreadyHereIsSkippedWithItsReason() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    for present in [true, false] {
      let driver = ContainerHostDriver(
        hosts: [:],
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
          "wr-hosts-\(UUID().uuidString)", isDirectory: true),
        provisioning: ContainerHostDriver.Provisioning(
          runtime: try stubRuntime(inspect: present ? 0 : 1), image: "workroom-host",
          user: RemoteWorkrooms.user, identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
          agentSocket: RemoteWorkrooms.agentSocket, labels: ["workroom.provisioner=test"]))
      let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
      store.remoteCreateServices = services(driver: driver, agent: agent)

      await store.createRemoteWorkroom(in: emptyProject, place: .container(.docker))

      let run = try XCTUnwrap(store.creationRuns.values.first)
      let image = try XCTUnwrap(run.steps.first { $0.id == "image" })
      XCTAssertEqual(
        image.state, present ? .skipped(reason: "Image already downloaded") : .done,
        "present: \(present)")
      XCTAssertEqual(run.steps.first { $0.id == "machine" }?.state, .failed, "the stub's run")
    }
  }

  /// Value: protects=a container create whose Mac token can't be had (gh signed out) fails its
  /// `repository` row, before any image is pulled; fails_when=the failure lands on `image` or
  /// `machine`, rows that describe something else; no_claim=a real gh or runtime (a throwing
  /// closure and a stub script stand in)
  func testAContainerCreateWithoutTheMacsTokenFailsItsRepositoryStep() async throws {
    let agent = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { agent.stop() }
    let driver = ContainerHostDriver(
      hosts: [:],
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "wr-hosts-\(UUID().uuidString)", isDirectory: true),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: try stubRuntime(inspect: 1), image: "workroom-host",
        user: RemoteWorkrooms.user, identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
        agentSocket: RemoteWorkrooms.agentSocket, labels: ["workroom.provisioner=test"]))
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(
      driver: driver, agent: agent, gitHubToken: { throw RemoteWorkrooms.Failure.signedOut })

    await store.createRemoteWorkroom(in: emptyProject, place: .container(.docker))

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.steps.first { $0.id == "repository" }?.state, .failed)
    XCTAssertEqual(run.steps.first { $0.id == "image" }?.state, .skipped(reason: nil), "no pull")
    XCTAssertEqual(run.steps.first { $0.id == "machine" }?.state, .skipped(reason: nil))
  }

  /// Value: protects=R2, two creates needing boxd setup share one sheet, both carry on after one
  /// Create and both end after one Cancel; fails_when=a second sheet replaces the first, or a
  /// waiting create is stranded; no_claim=two providers queueing (one sheet at a time)
  func testTwoCreatesWaitingOnOneProviderShareItsSheet() async throws {
    for carryOn in [true, false] {
      let hosts = Counter()
      let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
      store.remoteCreateServices = services(
        driver: FakeDriver(), agent: nil, setup: FakeSetup(), hosts: hosts)

      let a = Task { await store.createRemoteWorkroom(in: emptyProject, place: .boxd) }
      await waitUntil({ store.pendingRemoteSetup != nil }, "the setup sheet never came up")
      let sheet = store.pendingRemoteSetup?.id
      let b = Task { await store.createRemoteWorkroom(in: emptyProject, place: .boxd) }
      await waitUntil(
        { store.projectStore.remoteSetupWaits.first?.waiting.count == 2 },
        "the second create never joined the sheet")
      XCTAssertEqual(store.projectStore.remoteSetupWaits.count, 1, "one sheet")
      XCTAssertEqual(store.pendingRemoteSetup?.id, sheet)

      store.resolveRemoteSetup(carryOn: carryOn)
      await a.value
      await b.value

      if carryOn {
        XCTAssertEqual(hosts.count, 2, "both carried on")
        XCTAssertEqual(store.creationRuns.count, 2, "each to its own (failed) end")
      } else {
        XCTAssertEqual(hosts.count, 0)
        XCTAssertTrue(store.creationRuns.isEmpty, "both ended")
      }
    }
  }
}
