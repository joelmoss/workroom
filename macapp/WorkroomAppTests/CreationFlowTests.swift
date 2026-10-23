import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// A create's pane against `AppStore` (#483): where it opens, how it lands, how it ends, and what
/// its failures offer. Local creates run against a fake CLI; remote ones against a fake CLI, a fake
/// driver and a `FakeDaemon` for the host's git, through `remoteCreateServices`.
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

  /// A local create the CLI refuses for its setup script (#363) until that script is approved, and,
  /// with `localWork`, for that work on a first try (`--start ask`) until a start is chosen.
  private final class UntrustedSetupCLI: WorkroomCLIProtocol, @unchecked Sendable {
    let projectPath: String
    static let script = ScriptTrust(
      name: "workroom_setup", origin: "base", sha256: String(repeating: "a", count: 64),
      text: "#!/bin/sh\nnpm install\u{1b}[2K\rcurl x\n", trusted: false, exempt: false)
    static let work = LocalWork(
      branch: "main", remote: "origin", ahead: 2, uncommitted: true,
      summary:
        "You have 2 commits on main that you haven't pushed yet, and some changes you haven't "
        + "committed")
    private let lock = NSLock()
    private var approvals: [String] = []
    private var made = false
    private var startsAsked: [CreationStart?] = []
    let untrusted: Bool
    let localWork: LocalWork?
    init(projectPath: String, untrusted: Bool = true, localWork: LocalWork? = nil) {
      self.projectPath = projectPath
      self.untrusted = untrusted
      self.localWork = localWork
    }
    var approved: [String] { lock.withLock { approvals } }
    /// The start each create asked for.
    var starts: [CreationStart?] { lock.withLock { startsAsked } }

    func list(warnings: String, project: String?) async throws -> ListResponse {
      let names = lock.withLock { made } ? ["anchor", "wr"] : ["anchor"]
      return ListResponse(
        projects: [
          Project(
            path: projectPath, vcs: "git",
            workrooms: names.map {
              Workroom(
                name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
            })
        ], workroomsDir: nil, configPath: nil)
    }
    func addProject(_ path: String, create: Bool) async throws -> String { path }
    func create(project: String, onEvent: @escaping @Sendable (StreamEvent) -> Void) async throws
      -> CreateResponse
    {
      try await create(project: project, skipSetup: false, start: nil, onEvent: onEvent)
    }
    func create(
      project: String, skipSetup: Bool, start: CreationStart?,
      onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> CreateResponse {
      lock.withLock { startsAsked.append(start) }
      onEvent(CreateEvents.step("fetch", "skipped", "No remote to fetch from"))
      // As the CLI: where it starts is settled before the setup script is judged.
      if let localWork, start == .ask {
        throw WorkroomCLIError.localWorkLeftOut(localWork, message: "local work")
      }
      guard !approved.isEmpty || skipSetup || !untrusted else {
        throw WorkroomCLIError.scriptNotTrusted(Self.script, message: "script is not trusted")
      }
      let path = "\(projectPath)/.workrooms/wr"
      onEvent(CreateEvents.step("worktree", "running"))
      onEvent(CreateEvents.step("worktree", "done"))
      lock.withLock { made = true }
      onEvent(CreateEvents.created(name: "wr", path: path, setup: false))
      if start == .localWithChanges {
        onEvent(CreateEvents.step("changes", "running"))
        onEvent(CreateEvents.step("changes", "done"))
      }
      onEvent(
        CreateEvents.step(
          "script", "skipped", skipSetup ? AppStore.setupSkippedReason : "No setup script"))
      return CreateResponse(name: "wr", path: path, vcs: "git", project: project)
    }
    func trustScript(_ name: String, text: Data, project: String) async throws {
      lock.withLock { approvals.append("\(name) \(String(decoding: text, as: UTF8.self))") }
    }
    func create(
      project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
    ) async throws -> CreateResponse { throw WorkroomCLIError.timedOut }
    func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}
    func deleteProject(
      _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
    ) async throws -> [URL] { [] }
  }

  /// Value: protects=#363, a create refused for its setup script keeps its pane with the script row
  /// waiting and the script to read, with its hidden characters shown, and Approve records the
  /// script's own bytes and creates in the same pane; fails_when=the refusal reads as a plain
  /// failure (in the pane or the sidebar), the row is missing (a script only the base commit has),
  /// an escape reaches the text raw, or Approve records other bytes or doesn't create;
  /// no_claim=the CLI's refusal itself (the Go tests) and the footer's drawing
  func testAnUnapprovedSetupScriptWaitsForApproveThenCreates() async throws {
    let fake = UntrustedSetupCLI(projectPath: projectPath)
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]

    await store.createWorkroom(in: emptyProject)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.outcome, .scriptNotTrusted(UntrustedSetupCLI.script))
    XCTAssertEqual(run.steps.first { $0.id == "script" }?.state, .waitingForUser)
    XCTAssertEqual(run.steps.first { $0.id == "worktree" }?.state, .pending)
    let footer = try XCTUnwrap(CreationPanePresentation.footer(for: run.outcome))
    XCTAssertEqual([footer.primary, footer.secondary], [.reviewScript, .cancel])
    XCTAssertFalse(AppStore.CreateStep(run).failed, "a create waiting on Approve isn't a failure")
    // The approval sheet, as the teardown's: the script to read, with what the terminal or the text
    // would act on or hide shown, so the script can't mask itself.
    XCTAssertEqual(store.errorTitle, "Approve the setup script?")
    XCTAssertEqual(store.errorLog, "#!/bin/sh\nnpm install\\u{001b}[2K\\u{000d}curl x\n")
    XCTAssertEqual(store.errorScriptName, "workroom_setup")
    XCTAssertEqual(store.errorMessage?.contains(emptyProject.displayName), true)
    XCTAssertEqual(
      [store.errorAction?.label, store.errorCancel?.label, store.errorApproval?.label],
      ["Continue Without Script…", "Cancel Creation", "Approve"])
    XCTAssertNotNil(store.errorAction?.confirmation, "skipping the script must ask first")

    let approve = try XCTUnwrap(store.errorApproval)
    store.clearError()
    approve.run()

    await waitUntil(
      { store.projects.first?.workrooms.contains { $0.name == "wr" } ?? false },
      "the create ran again after Approve")
    // The bytes approved are the script's own, not the text shown.
    XCTAssertEqual(fake.approved, ["workroom_setup #!/bin/sh\nnpm install\u{1b}[2K\rcurl x\n"])
  }

  /// Value: protects=Continue Without Script on an unapproved setup script creates the workroom in
  /// the same pane without running the script and without approving it; fails_when=the create
  /// isn't told to skip the script, an approval is recorded (the next create wouldn't ask), or the
  /// script row doesn't say it was skipped; no_claim=the confirmation (a view) and the CLI's skip
  /// (the Go tests)
  func testContinueWithoutScriptCreatesWithoutApproving() async throws {
    let fake = UntrustedSetupCLI(projectPath: projectPath)
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    store.closesFinishedCreations = { false }  // the finished checklist stays, to read its rows
    await store.createWorkroom(in: emptyProject)
    let skip = try XCTUnwrap(store.errorAction, "the sheet offers no Continue Without Script")
    store.clearError()
    skip.run()

    await waitUntil(
      { store.projects.first?.workrooms.contains { $0.name == "wr" } ?? false },
      "the create didn't run again without the script")
    XCTAssertEqual(fake.approved, [], "skipping approved the script")
    let retry = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(retry.outcome, .succeeded)
    XCTAssertTrue(retry.skipsSetup)
    XCTAssertEqual(
      retry.steps.first { $0.id == "script" }?.state,
      .skipped(reason: AppStore.setupSkippedReason))
  }

  /// Value: protects=Try Again after Continue Without Script doesn't ask again for the script the
  /// user chose to skip; fails_when=retryCreation drops skipsSetup, so the create stops on the
  /// script again or the run no longer skips it; why_new=the test above reads one skipped create,
  /// not a run made from it; seam=none; no_claim=the Try Again button (a view)
  func testTryAgainAfterContinueWithoutScriptKeepsSkippingIt() async throws {
    let fake = UntrustedSetupCLI(projectPath: projectPath)
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    store.closesFinishedCreations = { false }
    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first)
    await store.skipSetupScript(run)
    let skipped = try XCTUnwrap(store.creationRuns.values.first)

    await store.retryCreation(skipped)

    let again = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertNotIdentical(again, skipped, "Try Again made no new run")
    XCTAssertEqual(again.outcome, .succeeded, "Try Again stopped on the script again")
    XCTAssertTrue(again.skipsSetup)
    XCTAssertEqual(fake.approved, [], "skipping approved the script")
  }

  /// Value: protects=a create skipping the script isn't stopped when the trust check can't be
  /// answered; fails_when=the retry's trust status error fails the create, the script runs, or a
  /// local-work notice is made up; why_new=the remote skip test above always answers the check;
  /// seam=none; no_claim=what the check's error says
  func testContinueWithoutScriptGoesOnWhenTheTrustCheckCantBeAnswered() async throws {
    let project = try projectWithASetupScript()
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let store = makeStore(RemoteFakeCLI(projectPath: project.path))
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let scripts = Counter()
    let checks = Counter()
    var services = services(driver: FakeDriver(), daemon: daemon)
    services.trustStatus = { _, _, _ in
      checks.add()
      if checks.count > 1 { throw WorkroomCLIError.timedOut }
      return TrustStatus(trusted: false, scripts: [UntrustedSetupCLI.script])
    }
    services.script = { _ in
      scripts.add()
      return .passed
    }
    store.remoteCreateServices = services
    store.closesFinishedCreations = { false }
    await store.createRemoteWorkroom(in: project, place: .boxd)
    let run = try XCTUnwrap(store.creationRuns.values.first)

    await store.skipSetupScript(run)

    XCTAssertEqual(checks.count, 2, "the retry never asked the check")
    let retry = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(retry.outcome, .succeeded)
    XCTAssertEqual(scripts.count, 0, "the setup script ran")
    XCTAssertEqual(
      retry.steps.first { $0.id == "script" }?.state,
      .skipped(reason: AppStore.setupSkippedReason))
    XCTAssertFalse(
      store.notifications.items.contains { $0.body?.contains("pushed") ?? false },
      "a local-work notice came from nowhere")
  }

  /// Value: protects=a local create first asks the CLI to stop on local work (`--start ask`), then
  /// waits on the worktree's row with the choice up, offering only the starts that apply, and the
  /// start picked creates again from there in the same pane, kept through the setup script's
  /// approval; fails_when=the first try doesn't ask, the stop reads as a failure, no choice is
  /// raised, a choice that doesn't apply is offered, or the chosen start isn't passed (or is lost on
  /// Approve); no_claim=the dialog's drawing and the CLI's own start (the Go tests)
  func testLocalWorkAsksWhereToStartAndCreatesFromTheChoice() async throws {
    let fake = UntrustedSetupCLI(projectPath: projectPath, localWork: UntrustedSetupCLI.work)
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    store.closesFinishedCreations = { false }

    await store.createWorkroom(in: emptyProject)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(fake.starts, [.ask])
    XCTAssertEqual(run.outcome, .localWorkFound(UntrustedSetupCLI.work))
    XCTAssertEqual(run.steps.first { $0.id == "worktree" }?.state, .waitingForUser)
    XCTAssertFalse(
      AppStore.CreateStep(run).failed, "a create asking where to start isn't a failure")
    let footer = try XCTUnwrap(CreationPanePresentation.footer(for: run.outcome))
    XCTAssertEqual([footer.primary, footer.secondary], [.chooseStart, .cancel])
    let pending = try XCTUnwrap(store.pendingStartChoice, "no start choice was raised")
    XCTAssertTrue(pending.run === run)
    XCTAssertEqual(
      CreationPanePresentation.startChoices(for: pending.work).map(\.start),
      [.localWithChanges, .local, .origin])
    XCTAssertEqual(
      CreationPanePresentation.startChoices(
        for: LocalWork(branch: "main", remote: "origin", ahead: 0, uncommitted: true, summary: "")
      ).map(\.start), [.localWithChanges, .origin], "no commits to include on their own")
    XCTAssertEqual(
      CreationPanePresentation.startChoices(
        for: LocalWork(branch: "main", remote: "origin", ahead: 1, uncommitted: false, summary: "")
      ).map(\.start), [.local, .origin], "no changes to copy")
    // Behind origin, the choice says what including the work leaves out instead.
    let note =
      "Your main is also 2 commits behind origin, so including your work starts from your older copy."
    XCTAssertTrue(
      CreationPanePresentation.startChoiceMessage(
        for: LocalWork(
          branch: "main", remote: "origin", ahead: 0, uncommitted: true, behind: 2, summary: "",
          behindNote: note)
      ).contains(note), "the choice doesn't say the local branch is behind")

    store.pendingStartChoice = nil
    await store.chooseStart(.localWithChanges, for: run)

    // It then stops on the setup script, keeping the start for Approve's create.
    let waiting = try XCTUnwrap(store.creationRuns[run.id])
    XCTAssertEqual(waiting.outcome, .scriptNotTrusted(UntrustedSetupCLI.script))
    XCTAssertEqual(waiting.start, .localWithChanges)
    await store.approveSetupScript(waiting)
    XCTAssertEqual(fake.starts, [.ask, .localWithChanges, .localWithChanges])
    let created = try XCTUnwrap(store.creationRuns[run.id])
    XCTAssertEqual(created.outcome, .succeeded)
    XCTAssertEqual(created.steps.first { $0.id == "changes" }?.state, .done)
  }

  /// Value: protects=the "Copy your changes" row shows only for a create copying them;
  /// fails_when=it shows on every local create; no_claim=the step's events (the Go tests)
  func testTheChangesRowIsOnlyForACreateCopyingThem() {
    let plain = CreationRun(
      project: emptyProject, kind: .local, splitAnchor: nil, previousSelection: nil)
    XCTAssertFalse(plain.steps.contains { $0.id == "changes" })
    let copying = CreationRun(
      project: emptyProject, kind: .local, splitAnchor: nil, previousSelection: nil,
      start: .localWithChanges)
    XCTAssertEqual(
      copying.steps.map(\.id).prefix(3), ["fetch", "worktree", "changes"])
  }

  /// Value: protects=Cancel Creation on the start choice ends the create, and a choice left over
  /// from a run since replaced does nothing; fails_when=the create waits on, or a stale choice
  /// creates again or closes the create that replaced it; no_claim=the dialog
  func testCancelOrAStaleChoiceOnTheStartChoice() async throws {
    let fake = UntrustedSetupCLI(
      projectPath: projectPath, untrusted: false, localWork: UntrustedSetupCLI.work)
    let store = makeStore(fake)
    store.projects = [project(["anchor"])]
    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first)

    await store.retryCreation(run)  // asks again, as a new run
    let retry = try XCTUnwrap(store.creationRuns[run.id])
    let pane = try XCTUnwrap(store.selectedTargetID)
    await store.chooseStart(.local, for: run)
    store.cancelStartChoice(run)
    XCTAssertTrue(store.creationRuns[run.id] === retry, "a stale choice acted on the new create")
    XCTAssertEqual(store.selectedTargetID, pane)
    XCTAssertEqual(fake.starts, [.ask, .ask])

    store.cancelStartChoice(retry)
    XCTAssertTrue(store.creationRuns.isEmpty, "Cancel Creation left the create")
  }

  /// Value: protects=a remote create says what local work it leaves out, after it lands, since a
  /// host clones from GitHub; fails_when=no notice, or it stops to ask as a local create does;
  /// no_claim=trust status itself (the Go tests)
  func testARemoteCreateSaysWhatLocalWorkItLeavesOut() async throws {
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    var services = services(driver: FakeDriver(), daemon: daemon)
    services.trustStatus = { _, _, _ in
      TrustStatus(trusted: true, scripts: [], localWork: UntrustedSetupCLI.work)
    }
    store.remoteCreateServices = services
    store.closesFinishedCreations = { false }

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertNil(store.pendingStartChoice)
    let notice = try XCTUnwrap(store.notifications.items.first?.body)
    XCTAssertTrue(
      notice.hasPrefix(
        UntrustedSetupCLI.work.summary + ". Remote workrooms can only start from what you've pushed"
      ),
      notice)
  }

  /// Value: protects=Cancel Creation (or Escape) on the setup script's sheet ends the create and its
  /// pane, and a sheet left over from a run since replaced cancels nothing; fails_when=the run
  /// stays waiting with no sheet, or a stale sheet closes the create that replaced it; no_claim=the
  /// sheet's drawing
  func testCancelCreationOnTheSetupSheetEndsTheCreate() async throws {
    let store = makeStore(UntrustedSetupCLI(projectPath: projectPath))
    store.projects = [project(["anchor"])]
    await store.createWorkroom(in: emptyProject)
    let run = try XCTUnwrap(store.creationRuns.values.first)
    let staleCancel = try XCTUnwrap(store.errorCancel)

    // Review Script… shows it again; a run replaced since leaves the first sheet's Cancel stale.
    await store.retryCreation(run)
    let retry = try XCTUnwrap(store.creationRuns[run.id])
    XCTAssertFalse(retry === run)
    let pane = try XCTUnwrap(store.selectedTargetID)
    staleCancel.run()
    XCTAssertTrue(store.creationRuns[run.id] === retry, "a stale sheet cancelled the new create")
    XCTAssertEqual(store.selectedTargetID, pane, "a stale sheet took the new create's pane away")

    store.clearError()
    store.presentSetupApproval(retry)
    let cancel = try XCTUnwrap(store.errorCancel, "Review Script… showed no sheet")
    store.clearError()
    cancel.run()
    XCTAssertTrue(store.creationRuns.isEmpty, "Cancel Creation left the create")
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

    var daemonSocket: String { "/home/boxd/.workroom/workroomd.sock" }
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
      metadata: [(key: String, value: String)], runCommand: String?
    ) throws -> String { "" }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }
    func lastAttach(of session: UUID, on host: HostID) -> LastAttach { .finished }
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
    driver: any HostTerminalDriver, daemon: FakeDaemon?, setup: (any RemoteSetup)? = nil,
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
        guard let daemon else { throw HostDriverError.provisioning("no host") }
        let socket = daemon.socketPath
        return RemoteCreateHost(
          key: .boxd(org: "acme", account: "u"), driver: driver,
          environment: RemoteProvisioning.Environment(
            driver: driver, daemonSocket: driver.daemonSocket, gitHubToken: gitHubToken,
            grantRepository: grantRepository,
            connect: { host in try await DaemonVCSConnection.connect(host: host, socketPath: socket)
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

  /// Value: protects=#363, a remote create whose setup script this Mac has not approved stops before
  /// any machine is made, waiting on Approve; fails_when=a host is asked for (a paid machine) or
  /// the refusal reads as a failure; no_claim=`trust status` itself (the Go tests)
  func testAnUnapprovedSetupScriptStopsARemoteCreateBeforeAnyMachine() async throws {
    let hosts = Counter()
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    var services = services(driver: FakeDriver(), daemon: nil, hosts: hosts)
    services.trustStatus = { _, _, _ in
      TrustStatus(trusted: false, scripts: [UntrustedSetupCLI.script])
    }
    store.remoteCreateServices = services

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.outcome, .scriptNotTrusted(UntrustedSetupCLI.script))
    XCTAssertEqual(hosts.count, 0, "a machine was asked for")
    XCTAssertEqual(run.steps.first { $0.id == "repository" }?.state, .done)
  }

  /// Value: protects=a repository the provider refuses fails the repository row, not the account
  /// row the checklist had moved on to; fails_when=the failure lands on account or image;
  /// no_claim=a real provider (a fake grant refuses)
  func testARefusedRepositoryGrantFailsTheRepositoryRow() async throws {
    let daemon = try FakeDaemon(version: 4)
    defer { daemon.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(
      driver: FakeDriver(), daemon: daemon,
      grantRepository: { _ in throw HostDriverError.provisioning("o/r is not shared") })

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.steps.first { $0.id == "repository" }?.state, .failed)
    XCTAssertEqual(run.steps.first { $0.id == "account" }?.state, .done)
  }

  /// Value: protects=AC 10 and O2 solo, a remote create failing in `clone` keeps its pane, the git
  /// error in the clone row's log, and Try Again, with its machine rolled back; fails_when=the
  /// reload prunes the pane, the log is lost, or the machine stays; no_claim=a real host (a fake
  /// driver and FakeDaemon stand in)
  func testARemoteCreateFailingInCloneKeepsItsPaneAndLog() async throws {
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitFails)
    defer { daemon.stop() }
    let cli = RemoteFakeCLI(projectPath: projectPath)
    let driver = FakeDriver()
    let store = remoteStore(cli)
    store.remoteCreateServices = services(driver: driver, daemon: daemon)

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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitFails)
    defer { daemon.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(), daemon: daemon)
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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitFails)
    defer { daemon.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(destroyFails: true), daemon: daemon)

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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(driver: FakeDriver(), daemon: daemon)
    // The run waits for Done: a create against the fake daemon ends within one poll of the
    // run's start, so watching `creationRuns` for it mid-flight is a race.
    store.closesFinishedCreations = { false }
    store.setRunConfig(RunConfig(command: "bin/dev", autoRun: true), forProject: projectPath)

    await store.createRemoteWorkroom(in: emptyProject, place: .boxd)
    let run = try XCTUnwrap(store.creationRuns.values.first, "the run waits for Done")

    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertNotNil(
      store.runStates[TerminalTarget.workroomID(project: projectPath, name: "calm-river")],
      "auto-run was armed for the workroom's first terminal, and runs on its host (#522)")
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
  /// deleted, or its lines miss the row; no_claim=a real host (RemoteScriptTests runs the daemon)
  func testARemoteCreateRunsItsSetupScriptBeforeItCanBeDeleted() async throws {
    let project = try projectWithASetupScript()
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let store = makeStore(RemoteFakeCLI(projectPath: project.path))
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let call = ScriptCall()
    var services = services(driver: FakeDriver(), daemon: daemon)
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

  /// Value: protects=Continue Without Script on a remote create: past the check that stopped it,
  /// onto a machine, with the setup script neither judged nor run and its row saying so;
  /// fails_when=the retry stops on the same check again, or the script runs; no_claim=a real host
  func testContinueWithoutScriptMakesARemoteWorkroomWithoutRunningIt() async throws {
    let project = try projectWithASetupScript()
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let store = makeStore(RemoteFakeCLI(projectPath: project.path))
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let scripts = Counter()
    var services = services(driver: FakeDriver(), daemon: daemon)
    services.trustStatus = { _, _, _ in
      TrustStatus(trusted: false, scripts: [UntrustedSetupCLI.script])
    }
    services.script = { _ in
      scripts.add()
      return .passed
    }
    store.remoteCreateServices = services
    store.closesFinishedCreations = { false }
    await store.createRemoteWorkroom(in: project, place: .boxd)
    let run = try XCTUnwrap(store.creationRuns.values.first)

    await store.skipSetupScript(run)

    let retry = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(retry.outcome, .succeeded)
    XCTAssertEqual(scripts.count, 0, "the setup script ran")
    XCTAssertEqual(
      retry.steps.first { $0.id == "script" }?.state,
      .skipped(reason: AppStore.setupSkippedReason))
  }

  /// Value: protects=a remote setup that fails ends the create as a local one does
  /// (`.setupScriptFailed`, Open Anyway or Delete), with the workroom and its machine kept;
  /// fails_when=the machine is destroyed, the record forgotten, or the outcome is a remote failure;
  /// no_claim=a real host
  func testARemoteSetupFailureKeepsTheWorkroomAndItsMachine() async throws {
    let project = try projectWithASetupScript()
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let cli = RemoteFakeCLI(projectPath: project.path)
    let driver = FakeDriver()
    let store = makeStore(cli)
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let why =
      "setup script failed: /home/boxd/r/scripts/workroom_setup returned a non-zero exit code"
    var services = services(driver: driver, daemon: daemon)
    services.script = { request in
      request.onStart()
      return .failed(why)
    }
    store.remoteCreateServices = services
    store.setRunConfig(RunConfig(command: "bin/dev", autoRun: true), forProject: project.path)

    await store.createRemoteWorkroom(in: project, place: .boxd)

    let run = try XCTUnwrap(store.creationRuns.values.first)
    XCTAssertEqual(run.outcome, .setupScriptFailed(message: why))
    XCTAssertEqual(run.steps.first { $0.id == "script" }?.state, .failed)
    XCTAssertEqual(driver.destroys, 0, "the machine was taken down")
    XCTAssertFalse(cli.calls.contains("delete calm-river"), "the record was forgotten")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "and Delete is allowed")
    XCTAssertNil(
      store.runStates[TerminalTarget.workroomID(project: project.path, name: "calm-river")],
      "Open Anyway must not start the run against a half-set-up tree (issue #7)")
  }

  /// Value: protects=a setup that fails before its script starts (the connect, its check, the
  /// root's copy) fails the "Run setup script" row, not the checkout before it; fails_when=the
  /// checkout row is marked failed and the script row skipped; no_claim=which failures those are
  /// (RemoteScriptTests)
  func testARemoteSetupThatFailsBeforeItsScriptStartsFailsItsOwnRow() async throws {
    let project = try projectWithASetupScript()
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let store = makeStore(RemoteFakeCLI(projectPath: project.path))
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    var services = services(driver: FakeDriver(), daemon: daemon)
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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let driver = FakeDriver()
    let store = makeStore(RemoteFakeCLI(projectPath: dir.path))
    let project = Project(path: dir.path, vcs: "git", workrooms: [])
    store.projects = [project]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    store.remoteCreateServices = services(driver: driver, daemon: daemon)
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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let plans = Counter()
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(
      driver: FakeDriver(), daemon: daemon, setup: FakeSetup(), plans: plans)

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
      driver: FakeDriver(), daemon: nil, setup: FakeSetup(), hosts: hosts)

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
    store.remoteCreateServices = services(driver: FakeDriver(), daemon: nil, setup: FakeSetup())

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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    for present in [true, false] {
      let driver = ContainerHostDriver(
        hosts: [:],
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
          "wr-hosts-\(UUID().uuidString)", isDirectory: true),
        provisioning: ContainerHostDriver.Provisioning(
          runtime: try stubRuntime(inspect: present ? 0 : 1), image: "workroom-host",
          user: RemoteWorkrooms.user, identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
          daemonSocket: RemoteWorkrooms.daemonSocket, labels: ["workroom.provisioner=test"]))
      let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
      store.remoteCreateServices = services(driver: driver, daemon: daemon)

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
    let daemon = try FakeDaemon(version: 4, execResult: Self.gitSucceeds)
    defer { daemon.stop() }
    let driver = ContainerHostDriver(
      hosts: [:],
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "wr-hosts-\(UUID().uuidString)", isDirectory: true),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: try stubRuntime(inspect: 1), image: "workroom-host",
        user: RemoteWorkrooms.user, identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
        daemonSocket: RemoteWorkrooms.daemonSocket, labels: ["workroom.provisioner=test"]))
    let store = remoteStore(RemoteFakeCLI(projectPath: projectPath))
    store.remoteCreateServices = services(
      driver: driver, daemon: daemon, gitHubToken: { throw RemoteWorkrooms.Failure.signedOut })

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
        driver: FakeDriver(), daemon: nil, setup: FakeSetup(), hosts: hosts)

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
