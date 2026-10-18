import Foundation
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// The NDJSON events `create --json` streams (#483), as the fakes below send them: the real
/// sequence, so the app's step mapping is driven the way the CLI drives it.
enum CreateEvents {
  static func step(_ id: String, _ state: String, _ detail: String? = nil) -> StreamEvent {
    StreamEvent(
      type: "step", phase: nil, text: nil, name: nil, path: nil, setup: nil, id: id, state: state,
      detail: detail)
  }

  static func log(_ text: String, step: String?) -> StreamEvent {
    StreamEvent(
      type: "log", phase: "setup", text: text, name: nil, path: nil, setup: nil, step: step)
  }

  static func created(name: String, path: String, setup: Bool, warning: String? = nil)
    -> StreamEvent
  {
    StreamEvent(
      type: "created", phase: nil, text: nil, name: name, path: path, setup: setup,
      warning: warning ?? "")
  }

  /// The fetch (skipped: no remote) and the worktree, up to "created".
  static func untilCreated(
    name: String, path: String, setup: Bool, warning: String? = nil,
    _ send: (StreamEvent) -> Void
  ) {
    send(step("fetch", "skipped", "No remote to fetch from"))
    send(step("worktree", "running"))
    send(log("$ git worktree add -b workroom/\(name) \(path)", step: "worktree"))
    send(step("worktree", "done"))
    send(created(name: name, path: path, setup: setup, warning: warning))
    if !setup { send(step("script", "skipped", "No setup script")) }
  }
}

/// A fake CLI that drives `createWorkroom` deterministically (issue #116): it streams the create's
/// step events and optional setup-script lines, reports the workroom with a controlled name and
/// `hasSetup`, and returns. `list` returns a project set that already contains the created
/// workroom, so the post-create reload resolves the selection.
private final class CreatingFakeCLI: WorkroomCLIProtocol {
  let projectPath: String
  let workroomName: String
  let hasSetup: Bool
  let logLines: [String]
  let failAfterReady: Bool
  /// Workrooms that already exist in the project and must SURVIVE the post-create reload. Without
  /// them `list` returns only the new workroom, so a split anchor stops resolving the moment the
  /// landing reloads — and the split is (correctly) refused for the wrong reason.
  let existingWorkrooms: [String]
  /// The create's warning, as the CLI reports a failed fetch.
  let warning: String?
  /// The app-wide base branch `list` reports.
  var globalBase: String?
  /// The project's own base branch `list` reports.
  var projectBase: String?
  /// What `setBaseBranch` was asked to store, in order.
  private(set) var baseBranches: [String?] = []

  init(
    projectPath: String, workroomName: String, hasSetup: Bool, logLines: [String] = [],
    failAfterReady: Bool = false, existingWorkrooms: [String] = [], warning: String? = nil
  ) {
    self.projectPath = projectPath
    self.workroomName = workroomName
    self.hasSetup = hasSetup
    self.logLines = logLines
    self.failAfterReady = failAfterReady
    self.existingWorkrooms = existingWorkrooms
    self.warning = warning
  }

  func setBaseBranch(project: String, branch: String?) async throws {
    baseBranches.append(branch)
  }

  private var workroomAbsPath: String { "\(projectPath)/.workrooms/\(workroomName)" }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    let workrooms = (existingWorkrooms + [workroomName]).map {
      Workroom(
        name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
    }
    return ListResponse(
      projects: [
        Project(path: projectPath, vcs: "git", workrooms: workrooms, baseBranch: projectBase)
      ],
      workroomsDir: nil, configPath: nil, baseBranch: globalBase)
  }

  func addProject(_ path: String, create: Bool) async throws -> String { projectPath }

  /// As the CLI does: the warning rides the "created" event, before setup runs. Returns
  /// IMMEDIATELY after the last event — the worst case for the create flow, which must await its
  /// landing rather than race it.
  func create(project: String, onEvent: @escaping @Sendable (StreamEvent) -> Void) async throws
    -> CreateResponse
  {
    CreateEvents.untilCreated(
      name: workroomName, path: workroomAbsPath, setup: hasSetup, warning: warning, onEvent)
    if hasSetup {
      onEvent(CreateEvents.step("script", "running"))
      for line in logLines { onEvent(CreateEvents.log(line, step: "script")) }
      if failAfterReady {
        onEvent(CreateEvents.step("script", "failed", "setup script failed"))
        throw WorkroomCLIError.timedOut
      }
      onEvent(CreateEvents.step("script", "done"))
    } else if failAfterReady {
      throw WorkroomCLIError.timedOut
    }
    return CreateResponse(
      name: workroomName, path: workroomAbsPath, vcs: "git", project: project, warning: warning)
  }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    throw WorkroomCLIError.timedOut  // the app drives `create(project:onEvent:)`
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

/// Records banners instead of posting them, so no test raises the real permission prompt.
private final class SilentNotifier: SystemNotifying {
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) {}
}

/// A fake CLI that lets a test control the INTERLEAVING of real `createWorkroom` calls (issue
/// #167). `create` hands out the next name in `names`, and suspends on a continuation — either just
/// before it reports the workroom (`.beforeReady`, so the create stays unnamed) or just after
/// (`.afterReady`, so the workroom exists and its setup script is "running") — until the test
/// calls `release(name)`. That's what makes two creates genuinely overlap inside their own real
/// `createWorkroom` bodies, which is where every defect in #167 lived.
///
/// `list` reports `existing` plus every workroom reported so far, so each landing's reload
/// resolves. With `holdsFirstListAfterReady`, the first `list` after a workroom exists waits for
/// `releaseList()`: the landing's reload, held open between the name arriving and the landing.
final class GatedFakeCLI: WorkroomCLIProtocol, @unchecked Sendable {
  enum Gate {
    case beforeReady
    case afterReady
  }

  let projectPath: String
  let hasSetup: Bool
  /// Names whose `create` throws once released — a setup script that failed after the workroom existed.
  let failing: Set<String>
  let existing: [String]
  let holdsFirstListAfterReady: Bool
  /// Where each name stops, if at all. Defaults to `gate` for every name; pass `gates` to hold two
  /// creates at DIFFERENT points. A name absent from this map never stops.
  private let gates: [String: Gate]
  private let names: [String]
  private let lock = NSLock()
  private var callIndex = 0
  private var ready: [String] = []
  private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
  private var released: Set<String> = []
  private var listHold: CheckedContinuation<Void, Never>?
  private var listHeld = false
  private var listReleased = false

  init(
    projectPath: String, names: [String], hasSetup: Bool, gate: Gate = .afterReady,
    failing: Set<String> = [], gates: [String: Gate]? = nil, existing: [String] = [],
    holdsFirstListAfterReady: Bool = false
  ) {
    self.projectPath = projectPath
    self.names = names
    self.hasSetup = hasSetup
    self.failing = failing
    self.existing = existing
    self.holdsFirstListAfterReady = holdsFirstListAfterReady
    self.gates = gates ?? Dictionary(uniqueKeysWithValues: names.map { ($0, gate) })
  }

  /// Let the named create past its gate (idempotent, and safe to call before it reaches the gate).
  func release(_ name: String) {
    lock.lock()
    released.insert(name)
    let pending = waiting.removeValue(forKey: name)
    lock.unlock()
    pending?.resume()
  }

  /// Whether the held `list` is waiting.
  var isListHeld: Bool { lock.withLock { listHold != nil } }

  func releaseList() {
    lock.lock()
    listReleased = true
    let pending = listHold
    listHold = nil
    lock.unlock()
    pending?.resume()
  }

  /// How many creates have taken a name. `create` is nonisolated, so two `createWorkroom` tasks
  /// reach it in whatever order the executor picks — a test that needs task A to own `names[0]` must
  /// wait for this to reach 1 before starting B, or A and B can swap gates and the test deadlocks.
  var assignedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callIndex
  }

  private func path(_ name: String) -> String { "\(projectPath)/.workrooms/\(name)" }

  private func hold(_ name: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if released.contains(name) {
        lock.unlock()
        continuation.resume()
        return
      }
      waiting[name] = continuation
      lock.unlock()
    }
  }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    let shouldHold = lock.withLock {
      guard holdsFirstListAfterReady, !ready.isEmpty, !listHeld else { return false }
      listHeld = true
      return true
    }
    if shouldHold {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        if listReleased {
          lock.unlock()
          continuation.resume()
          return
        }
        listHold = continuation
        lock.unlock()
      }
    }
    lock.lock()
    let names = existing + ready
    lock.unlock()
    return ListResponse(
      projects: [
        Project(
          path: projectPath, vcs: "git",
          workrooms: names.map {
            Workroom(name: $0, path: path($0), vcsName: "git", warnings: [])
          })
      ],
      workroomsDir: nil, configPath: nil)
  }

  func addProject(_ path: String, create: Bool) async throws -> String { projectPath }

  func create(project: String, onEvent: @escaping @Sendable (StreamEvent) -> Void) async throws
    -> CreateResponse
  {
    lock.lock()
    let name = names[min(callIndex, names.count - 1)]
    callIndex += 1
    lock.unlock()

    let stop = gates[name]
    if stop == .beforeReady { await hold(name) }
    lock.lock()
    ready.append(name)
    lock.unlock()
    CreateEvents.untilCreated(name: name, path: path(name), setup: hasSetup, onEvent)
    if hasSetup { onEvent(CreateEvents.step("script", "running")) }
    if stop == .afterReady { await hold(name) }
    if failing.contains(name) {
      if hasSetup { onEvent(CreateEvents.step("script", "failed", "setup script failed")) }
      throw WorkroomCLIError.timedOut
    }
    if hasSetup { onEvent(CreateEvents.step("script", "done")) }
    return CreateResponse(name: name, path: path(name), vcs: "git", project: project)
  }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    throw WorkroomCLIError.timedOut  // the app drives `create(project:onEvent:)`
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

@MainActor
final class AppStoreCreateWorkroomTests: XCTestCase {
  private let projectPath = "/private/var/tmp/wr-create-project"

  private func makeStore(_ fake: WorkroomCLIProtocol) -> AppStore {
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.creationSuccessHold = .zero
    store.closesFinishedCreations = { true }
    return store
  }

  /// A run holding `name`'s pane, as a create that has landed leaves it.
  @discardableResult
  /// Value: protects=a create shows its tab chip from the click, before its name lands, as the
  /// "Creating…" chip did before #483; fails_when=the chip waits for the name; no_claim=the chip's
  /// drawing
  func testAnUnnamedCreationAppearsAsTab() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let run = CreationRun(
      project: emptyProject, kind: .local, splitAnchor: nil, previousSelection: nil)
    store.register(run)

    XCTAssertEqual(
      store.orderedWorkroomTargets().map(\.sid), [.creation(project: projectPath, id: run.id)])
  }

  /// Value: protects=a create whose name has landed but not yet reloaded shows one chip, not two
  /// with one identity; fails_when=both of its ids give a chip; no_claim=the chip's drawing
  func testANamedCreationBeforeItsReloadAppearsAsOneTab() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let run = CreationRun(
      project: emptyProject, kind: .local, splitAnchor: nil, previousSelection: nil)
    store.register(run)
    run.setName("wr")
    store.creationRunForTarget[TerminalTarget.workroomID(project: projectPath, name: "wr")] = run.id

    XCTAssertEqual(
      store.orderedWorkroomTargets().map(\.sid), [.creation(project: projectPath, id: run.id)])
  }

  private func seedRun(
    _ store: AppStore, holding name: String, outcome: CreationOutcome = .running
  ) -> CreationRun {
    let run = CreationRun(
      project: emptyProject, kind: .local, splitAnchor: nil, previousSelection: nil)
    run.setName(name)
    if case .setupScriptFailed = outcome { run.fail(outcome) }
    store.creationRuns[run.id] = run
    store.creationRunForTarget[TerminalTarget.workroomID(project: projectPath, name: name)] =
      run.id
    return run
  }

  private func project(withWorkroom name: String) -> Project {
    Project(
      path: projectPath, vcs: "git",
      workrooms: [
        Workroom(
          name: name, path: "\(projectPath)/.workrooms/\(name)", vcsName: "git", warnings: [])
      ])
  }

  /// A project + workroom backed by REAL on-disk dirs. `resolveLocal` short-circuits with
  /// `.missingPath` before ever touching the (faked) runner when the path doesn't exist, so the
  /// probe-suppression tests need real directories to observe whether the runner was invoked. Caller
  /// removes `root` (via `defer`).
  private func makeRealProject(workroom name: String) -> (
    project: Project, root: String, wrPath: String
  ) {
    let root = NSTemporaryDirectory() + "wr-storm-\(UUID().uuidString)"
    let wrPath = "\(root)/.workrooms/\(name)"
    try? FileManager.default.createDirectory(atPath: wrPath, withIntermediateDirectories: true)
    let project = Project(
      path: root, vcs: "git",
      workrooms: [Workroom(name: name, path: wrPath, vcsName: "git", warnings: [])])
    return (project, root, wrPath)
  }

  /// Poll a condition on the main actor instead of a fixed sleep, so a slow/contended machine still
  /// passes once the awaited effect lands (bounded so a genuinely broken condition still fails).
  private func waitUntil(
    _ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<250 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms; up to ~500ms total
    }
    XCTFail(message, file: file, line: line)
  }

  // MARK: - Async create flow

  /// A create whose fetch failed tells the user, in a notification on the new workroom.
  func testAFetchWarningBecomesANotificationOnTheNewWorkroom() async {
    let warning =
      "Could not fetch origin. The workroom starts from origin/main, which may be out of date."
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false, warning: warning)
    let store = makeStore(fake)
    store.systemNotifier = SilentNotifier()

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertEqual(store.notifications.items.map(\.body), [warning])
    XCTAssertEqual(store.notifications.items.first?.targetID, store.selectedTarget?.id)
  }

  /// Offline, the fetch and a networked setup script fail together: the setup failure must not
  /// swallow the warning.
  func testAFetchWarningSurvivesAFailedSetup() async {
    let warning =
      "Could not fetch origin. The workroom starts from origin/main, which may be out of date."
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: true, failAfterReady: true,
      warning: warning)
    let store = makeStore(fake)
    store.systemNotifier = SilentNotifier()

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertEqual(store.notifications.items.map(\.body), [warning])
  }

  /// A create that fetched raises nothing.
  func testACreateWithoutAWarningRaisesNoNotification() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let store = makeStore(fake)
    store.systemNotifier = SilentNotifier()

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertTrue(store.notifications.items.isEmpty)
  }

  /// A project's own base wins; without one the app-wide base from `list` applies.
  func testEffectiveBaseBranchPrefersTheProjectsOwn() async {
    let fake = CreatingFakeCLI(projectPath: projectPath, workroomName: "x", hasSetup: false)
    fake.globalBase = "upstream/main"
    let store = makeStore(fake)
    await store.reload()

    XCTAssertEqual(
      store.effectiveBaseBranch(for: Project(path: projectPath, vcs: "git", workrooms: [])),
      "upstream/main")
    XCTAssertEqual(
      store.effectiveBaseBranch(
        for: Project(path: projectPath, vcs: "git", workrooms: [], baseBranch: "develop")),
      "develop")
  }

  /// A workroom label makes every reload rebuild the project; its base branch must survive that, or
  /// Project Settings shows it empty and a remote create ignores it.
  func testALabelledReloadKeepsTheProjectsBaseBranch() async {
    let fake = CreatingFakeCLI(projectPath: projectPath, workroomName: "x", hasSetup: false)
    fake.projectBase = "develop"
    let store = makeStore(fake)
    await store.reload()
    guard let project = store.projects.first, let workroom = project.workrooms.first else {
      return XCTFail("no project")
    }
    store.setWorkroomLabel(workroom, in: project, to: "Labelled")
    await store.reload()

    XCTAssertEqual(store.projects.first?.baseBranch, "develop")
  }

  /// Project Settings stores a trimmed branch, and a blank one clears it.
  func testSetBaseBranchTrimsAndClearsThroughTheCLI() async {
    let fake = CreatingFakeCLI(projectPath: projectPath, workroomName: "x", hasSetup: false)
    let store = makeStore(fake)

    await store.setBaseBranch("  develop ", forProject: projectPath)
    await store.setBaseBranch("   ", forProject: projectPath)

    XCTAssertEqual(fake.baseBranches, ["develop", nil])
  }

  /// With NO setup script the create clears itself when it completes: no run survives, and the new
  /// workroom is selected so its terminal drops in (#116).
  func testNoSetupCreateClearsAndSelects() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "calm-otter")
    XCTAssertTrue(store.creationRuns.isEmpty, "a no-setup create must clear itself when done")
    XCTAssertTrue(store.creationRunForTarget.isEmpty, "and leave no pane id behind")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-otter"))
    XCTAssertFalse(store.isCreationBlocking(wrID))
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "the create guard lifts when done (issue #116)")
  }

  /// REWRITTEN (#483, R3): a setup script that succeeds no longer waits for Dismiss. Its output was
  /// the script row's log while it ran; once it ends, the run goes and the terminal mounts.
  /// Value: protects=a successful setup script hands over to the terminal with no click (AC 7) and
  /// its lines land on the script row; fails_when=the run outlives success or the log is lost;
  /// no_claim=the 0.6 s hold (zeroed here; CreationFlowTests covers it)
  func testASuccessfulSetupScriptNeedsNoDismiss() async throws {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["brave-fox"], hasSetup: true)
    let store = makeStore(fake)
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "brave-fox")

    let task = await startAndLand(store, "brave-fox", project: emptyProject)
    let run = try XCTUnwrap(store.creationRun(forTargetID: wrID))
    await waitUntil({ run.runningStep?.id == "script" }, "the script is the running row")
    XCTAssertTrue(store.isCreationBlocking(wrID), "the terminal is withheld while it runs")

    fake.release("brave-fox")
    await task.value

    XCTAssertTrue(store.creationRuns.isEmpty, "a finished create needs no Dismiss")
    XCTAssertFalse(store.isCreationBlocking(wrID))
    XCTAssertEqual(run.outcome, .succeeded)
    XCTAssertEqual(
      run.steps.map(\.state), [.skipped(reason: "No remote to fetch from"), .done, .done])
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "brave-fox"))
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "setup finished → the workroom is deletable again (#116)")
  }

  /// REWRITTEN (#483, R3): a setup failure keeps the run, failed on its script row with its output,
  /// so the pane shows why and offers Open Anyway and Delete Workroom (AC 9).
  /// Value: protects=a failed setup script keeps its pane, its log and its terminal withheld, and
  /// releases deletion protection; fails_when=the run goes, the script row isn't failed, or the
  /// workroom stays undeletable; no_claim=the buttons' drawing
  func testSetupFailureKeepsTheRunWithItsLog() async throws {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "lost-cat", hasSetup: true, logLines: ["boom"],
      failAfterReady: true)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "lost-cat")
    let run = try XCTUnwrap(store.creationRun(forTargetID: wrID), "a failed setup keeps its run")
    guard case .setupScriptFailed(let message) = run.outcome else {
      return XCTFail("expected a setup-script failure, got \(run.outcome)")
    }
    XCTAssertFalse(message.isEmpty, "the failure must say why")
    XCTAssertEqual(run.steps.last?.state, .failed)
    XCTAssertEqual(run.steps.last?.log, ["boom"])
    XCTAssertTrue(store.isCreationBlocking(wrID))
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "lost-cat"))
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "a failed setup releases its own deletion protection")

    // Open Anyway: the terminal mounts.
    store.openCreatedWorkroomAnyway(run)
    XCTAssertFalse(store.isCreationBlocking(wrID))
    XCTAssertTrue(store.creationRuns.isEmpty)
  }

  // MARK: - Synchronous state semantics

  /// `isCreationBlocking` is true for the in-progress creation's own target and no other — with or
  /// without a setup script.
  ///
  /// The no-setup case became load-bearing in issue #171. Its pane used to be unmounted anyway (the
  /// focused create owned the whole detail), so exempting it cost nothing; now the pane mounts the
  /// instant the workroom exists, which is still inside `createWorkroom` with `creatingWorkrooms`
  /// set — so an un-withheld pane would run `ensureInitialTerminal`, consume the armed auto-run and
  /// feed it to a `startRunCommand` that refuses a creating workroom. The run would vanish.
  func testIsCreationBlockingSemantics() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")

    XCTAssertFalse(store.isCreationBlocking(wrID), "no creation → never blocking")

    seedRun(store, holding: "wr")
    XCTAssertTrue(store.isCreationBlocking(wrID), "a create withholds its own target")
    XCTAssertFalse(
      store.isCreationBlocking(TerminalTarget.workroomID(project: projectPath, name: "other")),
      "only the creation's own target is withheld")
  }

  /// REWRITTEN (#483, R3, AC 1): the pane opens on the click, whatever is on screen. The old
  /// full-frame loader is gone: a create's `.creation` pane takes the selection before the CLI has
  /// said anything, with a workroom already selected or not.
  /// Value: protects=AC 1, the creation pane is selected before the create's first await returns;
  /// fails_when=the pane appears only once the workroom has a name, or not when a workroom is on
  /// screen; no_claim=the split variant (testFocusedCreateInASplitRendersBothPanes)
  func testThePaneOpensOnTheClickWhateverIsOnScreen() async {
    for selected in [nil, SidebarID.workroom(project: projectPath, name: "live")] {
      let fake = GatedFakeCLI(
        projectPath: projectPath, names: ["wr"], hasSetup: false, gate: .beforeReady,
        existing: ["live"])
      let store = makeStore(fake)
      store.projects = [project(withWorkroom: "live")]
      store.selectedTargetID = selected

      let task = Task { await store.createWorkroom(in: emptyProject) }
      await waitUntil({ fake.assignedCount == 1 }, "the create never reached the CLI")
      guard case .creation(let path, let id) = store.selectedTargetID else {
        fake.release("wr")
        await task.value
        return XCTFail(
          "the creation pane must be selected from the click (selected: \(selected as Any))")
      }
      XCTAssertEqual(path, projectPath)
      XCTAssertEqual(store.selectedTarget?.unavailability, .creating, "it resolves to its run")
      XCTAssertEqual(store.creationRuns[id]?.previousSelection, selected, "Close goes back here")
      // The project has no scripts/workroom_setup, so no setup script row.
      XCTAssertEqual(
        store.creationRuns[id]?.steps.map(\.id), ["fetch", "worktree"],
        "the whole plan, from the first frame")

      fake.release("wr")
      await task.value
      XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "wr"))
    }
  }

  /// The post-script, pre-Dismiss window: the CLI has returned (so `createWorkroom`'s `defer` has
  /// already cleared BOTH shared guard sets) but the setup dialog is still up and the terminal is
  /// still withheld. `creatingWorkrooms` alone therefore says "go" while the pane says "wait".
  ///
  /// Offering Run there is not merely a silent no-op — it is worse than the bug issue #171 set out
  /// to fix. The run starts against an unmounted pane AND overwrites the armed auto-run, so when the
  /// user finally dismisses, `ensureInitialTerminal` sees a non-empty tab list, skips `addTab`, and
  /// the workroom lands with a run tab and NO shell — issue #7's contract, broken silently.
  func testRunIsRefusedWhileTheSetupDialogStillCoversThePane() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let proj = project(withWorkroom: "wr")
    store.projects = [proj]
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: true), forProject: projectPath)
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")
    let target = proj.workrooms[0].target(inProject: projectPath)

    let run = seedRun(store, holding: "wr", outcome: .setupScriptFailed(message: "exit 1"))
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "precondition: the create's process already ended")
    store.armAutoRun(forWorkroom: id)

    XCTAssertTrue(store.isRunBlocked(id), "the run still owns this pane")
    XCTAssertFalse(
      store.canRunCommand(for: target, inProject: projectPath),
      "so no Run affordance may be offered")
    store.startRunCommand(for: target)
    XCTAssertNil(store.runTabID(for: id), "and the chokepoint refuses it even if one is")

    // Open Anyway mounts the pane, and the auto-run is still armed to do its job.
    store.openCreatedWorkroomAnyway(run)
    store.ensureInitialTerminal(for: target)
    XCTAssertEqual(
      store.terminals.tabCount(forTargetID: id), 2,
      "the workroom gets its backgrounded run AND its always-on shell (issue #7)")
  }

  /// `isRunBlocked` needs BOTH halves; neither covers the other. `creatingWorkrooms` clears too
  /// early (the case above), and `isCreationBlocking` starts too late — during the landing's
  /// `reload()` a no-setup create holds `creatingWorkrooms` with no `creations` entry yet.
  func testRunBlockedNeedsBothHalves() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")

    XCTAssertFalse(store.isRunBlocked(id), "idle → nothing blocks")
    store.creatingWorkrooms.insert(id)
    XCTAssertFalse(store.isCreationBlocking(id), "the landing's reload window: no entry yet")
    XCTAssertTrue(store.isRunBlocked(id), "but the run must still be refused")
    store.creatingWorkrooms.remove(id)
    seedRun(store, holding: "wr")
    XCTAssertTrue(store.isRunBlocked(id), "and again once only the run is left")
  }

  /// A landed create whose workroom does not resolve in `projects` still has somewhere to render.
  /// `apply` assigns `projects` with no ordering guard, so an out-of-order `list` can revert it to a
  /// snapshot predating a landed workroom. Its pane resolves through its run instead (#483), so its
  /// log, its failure and its actions stay reachable.
  /// Value: protects=a create's pane keeps its checklist when a reload stops listing its
  /// workroom; fails_when=the pane's target goes nil, losing the run's actions; no_claim=the
  /// pane's drawing
  func testALandedCreateWhoseTargetStoppedResolvingStillRenders() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let id = TerminalTarget.workroomID(project: projectPath, name: "wr")
    let sid = SidebarID.workroom(project: projectPath, name: "wr")
    let run = seedRun(store, holding: "wr")

    store.projects = [project(withWorkroom: "wr")]
    store.selectedTargetID = sid
    XCTAssertTrue(store.creationRun(forTargetID: id) === run, "its own pane draws its run")

    // The stale snapshot lands: the workroom is gone from `projects` but the create is still live.
    store.projects = []
    XCTAssertEqual(
      store.selectedTarget?.id, id,
      "it still resolves, through its run — otherwise the log and its failure are unreachable")
    XCTAssertEqual(store.selectedTarget?.unavailability, .creating)
    XCTAssertTrue(store.creationRun(forTargetID: id) === run, "and the pane still draws its run")
  }

  /// The routing decision for ⌥⌘N, end to end (issue #171 / #163 §2c): a create landed BESIDE an
  /// anchor focuses the new member, and the detail must then render the split — both panes — rather
  /// than hand the window to a full-frame create. `visibleWorkroomLayout` is what `workroomSplitBody`
  /// lays out, so asserting on it is asserting on what is drawn.
  func testFocusedCreateInASplitRendersBothPanes() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["brave-fox"], hasSetup: true, existing: ["anchor-wr"])
    let (store, anchor) = anchoredStore(fake, anchor: "anchor-wr")

    let task = Task {
      await store.createWorkroom(
        in: Project(path: projectPath, vcs: "git", workrooms: []), splitAnchor: anchor)
    }
    defer { fake.release("brave-fox") }
    let created = SidebarID.workroom(project: projectPath, name: "brave-fox")
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "brave-fox")
    await waitUntil({ store.selectedTargetID == created }, "the new member never landed")

    XCTAssertEqual(store.selectedTargetID, created, "the insert focuses the new member")
    XCTAssertEqual(
      Set(store.visibleWorkroomLayout(for: created).tabIDs), [anchor, created],
      "the split is what gets rendered — the anchor pane stays on screen through the create")
    XCTAssertTrue(
      store.isCreationBlocking(wrID), "the new member's own pane is what withholds its terminal")

    fake.release("brave-fox")
    await task.value
  }

  /// REWRITTEN (#483, R3): a create's named target shows as a workroom tab while its run lasts,
  /// even before its terminal exists — so the chip is present through setup (issue #116) — and
  /// goes once the run does.
  /// Value: protects=a landed create keeps its tab chip until its run ends; fails_when=the chip
  /// waits for a terminal or outlives the run; no_claim=the provisional (unnamed) pane
  /// (testAnUnnamedCreationAppearsAsTab)
  func testCreationTargetAppearsAsTab() async {
    let fake = FakeWorkroomCLI(canonical: projectPath, projects: [project(withWorkroom: "tab-wr")])
    let store = makeStore(fake)
    await store.reload()  // land the workroom in `projects` so its target resolves

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "tab-wr")
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "no tab before creation (the workroom has no live terminal)")

    let run = seedRun(store, holding: "tab-wr")
    XCTAssertTrue(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the creation target must show as a tab during setup")

    store.discardCreationRun(run)
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the tab falls back to terminal-presence once the run ends")
  }

  // MARK: - Create-time FSEvents storm suppression (create-gate)

  func testIsCreatingHelper() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")
    XCTAssertFalse(store.isCreating(.workroom(project: projectPath, name: "wr")))
    store.creatingWorkrooms.insert(wrID)
    XCTAssertTrue(store.isCreating(.workroom(project: projectPath, name: "wr")))
    XCTAssertFalse(
      store.isCreating(.workroom(project: projectPath, name: "other")),
      "a different workroom isn't creating")
    XCTAssertFalse(store.isCreating(.root(project: projectPath)), "a root row is never creating")
  }

  /// REGRESSION: while a workroom's setup is in flight, NEITHER the status sweep NOR a file-change
  /// burst may probe its worktree — that per-burst git probing (~70/sec under an `npm install`)
  /// was the CPU storm behind the reported spike. Drives the real ordering: flag set before reload,
  /// then selection (didSet probe), then a burst — all must be suppressed for the creating worktree.
  // Probing is observed via the OUTCOME, not a mock runner: git status is now read through
  // GitProvider/SwiftGitX (in-process, no command runner to record). `makeRealProject` makes a plain
  // directory (not a git repo), so a probe RESOLVES a status with `.notRepository`; a suppressed
  // worktree records no local status at all.
  func testNoProbeAgainstWorktreeWhileCreating() async {
    let (proj, root, wrPath) = makeRealProject(workroom: "wr")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    let sid = SidebarID.workroom(project: root, name: "wr")
    let wrID = TerminalTarget.workroomID(project: root, name: "wr")

    store.creatingWorkrooms.insert(wrID)  // setup in flight, BEFORE any reload/selection
    await store.reload()  // the sweep must SKIP the creating workroom
    // Selecting fires the didSet probe; the file-change burst is the storm — both must be suppressed.
    store.selectedTargetID = sid
    store.handleWorkroomFileChange(["\(wrPath)/node_modules/pkg/index.js"])
    // > selectionDebounce (0.3s), so a live probe WOULD have fired by now if it weren't suppressed.
    try? await Task.sleep(nanoseconds: 500_000_000)

    XCTAssertNil(
      store.workroomStatuses[sid]?.failure,
      "no VCS probe may run against a worktree whose setup is in flight")
  }

  /// Once setup completes (the flag lifts), the worktree is probed again — the suppression is scoped
  /// to the create window, not permanent.
  func testWorktreeProbedOnceCreatingClears() async {
    let (proj, root, wrPath) = makeRealProject(workroom: "wr")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    let sid = SidebarID.workroom(project: root, name: "wr")
    let wrID = TerminalTarget.workroomID(project: root, name: "wr")

    store.creatingWorkrooms.insert(wrID)
    await store.reload()
    store.selectedTargetID = sid
    store.creatingWorkrooms.remove(wrID)  // setup finished
    store.handleWorkroomFileChange(["\(wrPath)/src/main.swift"])

    // A probe ran and resolved a status: wrPath isn't a real repo, so it's `.notRepository`.
    await waitUntil(
      { store.workroomStatuses[sid]?.failure == .notRepository },
      "once setup completes the worktree must be probed again")
  }

  /// The `.jj` churn guard, both sides of it. A colocated repo left from jj can still have `jj` run in
  /// it, which writes under `.jj/` — Workroom never does — so a burst that touched ONLY jj-internal
  /// paths is ignored. But an `overflow` batch says its path list is incomplete, so the same paths
  /// must NOT be ignored then, or a refresh after an overflowed burst (or a reconnect's synthetic
  /// refresh) would be silently dropped. Observed through `watchRefreshTask`, which only a started
  /// probe sets.
  func testAJJInternalOnlyBurstIsIgnoredUnlessItOverflowed() async {
    let root = NSTemporaryDirectory() + "wr-jj-\(UUID().uuidString)"
    let wrPath = "\(root)/.workrooms/wr"
    try? makeGitCheckout(atPath: root)
    try? makeGitCheckout(atPath: wrPath)
    try? FileManager.default.createDirectory(
      atPath: "\(wrPath)/.jj", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let proj = Project(
      path: root, vcs: "git",
      workrooms: [Workroom(name: "wr", path: wrPath, vcsName: "workroom/wr", warnings: [])])
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    await store.reload()
    store.selectedTargetID = SidebarID.workroom(project: root, name: "wr")
    let internalOnly = ["\(wrPath)/.jj/working_copy/checkout"]
    func reset() {
      store.watchRefreshTask?.cancel()
      store.watchRefreshTask = nil
    }

    reset()
    store.handleWorkroomFileChange(internalOnly, overflow: false)
    XCTAssertNil(store.watchRefreshTask, "a jj-internal-only burst is jj's own write")

    reset()
    store.handleWorkroomFileChange(internalOnly, overflow: true)
    XCTAssertNotNil(store.watchRefreshTask, "an overflowed batch cannot be trusted to be internal")

    reset()
    store.handleWorkroomFileChange([], overflow: true)
    XCTAssertNotNil(store.watchRefreshTask, "the synthetic refresh after a gap carries no paths")

    reset()
    store.handleWorkroomFileChange(["\(wrPath)/src/main.swift"], overflow: false)
    XCTAssertNotNil(store.watchRefreshTask, "a working-tree edit always refreshes")
    reset()
  }

  /// A landing that arrives after its create has ended (a late `onReady` echo) must record NOTHING:
  /// its create's release points have already run, so a `creatingWorkrooms` insert here would strand
  /// the workroom undeletable — with its status probes suppressed — until relaunch. Reachable only by
  /// calling the method directly with a closed box; the real CLI drains stderr before `create`
  /// returns, so `onReady` can't actually fire this late.
  func testLandingAfterTheCreateEndedRecordsNothing() async {
    let fake = FakeWorkroomCLI(canonical: projectPath, projects: [project(withWorkroom: "wr")])
    let store = makeStore(fake)
    let landing = CreationLandingBox()
    landing.close()  // the create already finished; this is the late echo
    let run = CreationRun(
      project: project(withWorkroom: "wr"), kind: .local, splitAnchor: nil, previousSelection: nil)
    await store.landOnCreatedWorkroom(name: "wr", run: run, setup: false, landing: landing)
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty,
      "a landing past the end of its create must not leave a leaked creating flag")
    XCTAssertTrue(store.creationRunForTarget.isEmpty, "nor a creation entry nobody will clear")
  }

  // MARK: - Create as a split (issue #163)

  /// A project + anchor workroom the new one can land beside. The anchor must RESOLVE for
  /// `insertWorkroomSplit` to accept it, so it goes into the seeded project list.
  private func anchoredStore(_ fake: WorkroomCLIProtocol, anchor: String) -> (AppStore, SidebarID) {
    let store = makeStore(fake)
    store.projects = [project(withWorkroom: anchor)]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let sid = SidebarID.workroom(project: projectPath, name: anchor)
    store.selectedTargetID = sid
    return (store, sid)
  }

  func testCreateWithAnAnchorLandsTheNewWorkroomInASplit() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false,
      existingWorkrooms: ["anchor-wr"])
    let (store, anchor) = anchoredStore(fake, anchor: "anchor-wr")
    let created = SidebarID.workroom(project: projectPath, name: "calm-otter")

    await store.createWorkroom(
      in: Project(path: projectPath, vcs: "git", workrooms: []), splitAnchor: anchor)

    // Order matters: `.right` must place the anchor first and the new workroom second.
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [anchor, created])
    XCTAssertEqual(store.selectedTargetID, created, "focus lands on the new member")
  }

  func testCreateWithNoAnchorStillLandsSolo() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let (store, _) = anchoredStore(fake, anchor: "anchor-wr")

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertTrue(store.workroomSplits.isEmpty, "no anchor ⇒ today's behaviour, unchanged")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-otter"))
  }

  /// The anchor is captured when the project is picked, but the create is async — so by landing
  /// time the anchor may be gone. `insertWorkroomSplit`'s own resolve guard returns false and the
  /// plain landing stands; the new workroom must never be lost.
  func testAnAnchorDeletedMidCreateDegradesToAPlainLanding() async {
    // The fake's `list` deliberately omits the anchor, so the post-create reload drops it —
    // exactly what a real delete during a slow setup script does.
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let (store, _) = anchoredStore(fake, anchor: "anchor-wr")
    let vanished = SidebarID.workroom(project: projectPath, name: "anchor-wr")

    await store.createWorkroom(
      in: Project(path: projectPath, vcs: "git", workrooms: []), splitAnchor: vanished)

    XCTAssertTrue(store.workroomSplits.isEmpty)
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-otter"))
  }

  /// Selecting elsewhere while the create runs must NOT retarget the split: the anchor is a
  /// captured parameter, and its pane rect is derived from its own layout rather than from a cache
  /// that only ever holds the current selection's.
  func testSelectingElsewhereMidCreateStillSplitsBesideTheOriginalAnchor() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false,
      existingWorkrooms: ["anchor-wr", "elsewhere"])
    let store = makeStore(fake)
    store.projects = [
      Project(
        path: projectPath, vcs: "git",
        workrooms: ["anchor-wr", "elsewhere"].map {
          Workroom(
            name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
        })
    ]
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let anchor = SidebarID.workroom(project: projectPath, name: "anchor-wr")
    store.selectedTargetID = .workroom(project: projectPath, name: "elsewhere")

    await store.createWorkroom(
      in: Project(path: projectPath, vcs: "git", workrooms: []), splitAnchor: anchor)

    let created = SidebarID.workroom(project: projectPath, name: "calm-otter")
    XCTAssertEqual(
      store.workroomSplits.first?.tabIDs, [anchor, created],
      "the split pairs the ORIGINAL anchor, not whatever was selected at landing")
  }

  // MARK: - Two concurrent creates (issue #167)

  /// Start a gated create and wait until it has landed (its workroom exists and its setup is running).
  private func startAndLand(
    _ store: AppStore, _ name: String, project: Project
  ) async -> Task<Void, Never> {
    let task = Task { await store.createWorkroom(in: project) }
    let sid = SidebarID.workroom(project: projectPath, name: name)
    await waitUntil(
      { store.creationRun(for: sid).map { store.paneID(of: $0) == sid } ?? false },
      "\(name) never landed")
    return task
  }

  private var emptyProject: Project { Project(path: projectPath, vcs: "git", workrooms: []) }

  /// DEFECT 1. A create superseded by a second one still releases its OWN deletion protection.
  /// Before #167 the release was keyed on whoever held the single presentation slot, so B taking the
  /// slot during A's final `await reload()` skipped A's cleanup — and nothing else ever removed it:
  /// A stayed undeletable (silently — `deleteWorkroom` just returns), with a permanent sidebar
  /// spinner and its status probes suppressed, until the app was relaunched.
  func testASupersededCreateStillReleasesItsOwnDeletionProtection() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true)
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    let b = await startAndLand(store, "wr-b", project: emptyProject)
    XCTAssertTrue(store.creatingWorkrooms.contains(idA), "A's setup is still running")

    fake.release("wr-a")
    await a.value
    XCTAssertFalse(
      store.creatingWorkrooms.contains(idA),
      "A's create ended, so A's deletion protection must lift — even though B owns the newest state"
    )

    fake.release("wr-b")
    await b.value
    XCTAssertTrue(store.creatingWorkrooms.isEmpty)
  }

  /// DEFECT 2. B's landing is a STALE landing as far as A is concerned. It must not release A's
  /// deletion protection while A's subprocess is still writing A's worktree — `deleteWorkroom` would
  /// then run a full teardown (worktree removal included) against a directory a setup script is
  /// actively writing to.
  func testAStaleLandingCannotReleaseAnotherCreatesProtection() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true)
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    let b = await startAndLand(store, "wr-b", project: emptyProject)

    XCTAssertTrue(
      store.creatingWorkrooms.contains(idA),
      "B landing must not lift the guard on A, whose subprocess is still running")
    // The chokepoint itself: a delete of A is refused outright while that holds.
    let projectNow = store.projects.first { $0.path == projectPath }
    let workroomA = projectNow?.workrooms.first { $0.name == "wr-a" }
    XCTAssertNotNil(workroomA)
    store.deleteWorkroom(workroomA!, in: projectNow!)
    XCTAssertTrue(
      store.projects.first { $0.path == projectPath }?.workrooms.contains { $0.name == "wr-a" }
        ?? false,
      "a workroom mid-setup must not be torn down")

    fake.release("wr-a")
    fake.release("wr-b")
    await a.value
    await b.value
  }

  /// DEFECT 3. Terminal withholding and the armed auto-run follow the WORKROOM, not the presentation
  /// slot. Before #167, B taking the slot made `isCreationBlocking(A)` false: A's pane mounted, its
  /// `.task` ran `ensureInitialTerminal`, and the auto-run armed by A's own landing fired the project
  /// command into a half-built tree — exactly what issue #7's failure-path disarm exists to prevent.
  ///
  /// Arms directly rather than through `setRunConfig`: that writes `Defaults[.runCommands]`, which a
  /// parallel worker running `RunCommandTests` wipes wholesale in its own setUp/tearDown.
  func testWithholdingAndAutoRunSurviveASecondCreate() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true)
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    store.armAutoRun(forWorkroom: idA)  // as A's own landing does when its project has auto-run on
    let b = await startAndLand(store, "wr-b", project: emptyProject)
    // Release on EVERY exit: the `guard case .armed` below returns early on failure, and an
    // unreleased gate parks both `createWorkroom` tasks on their continuations for the life of the
    // test process instead of failing cleanly.
    defer {
      fake.release("wr-a")
      fake.release("wr-b")
    }

    XCTAssertTrue(
      store.isCreationBlocking(idA), "A's terminal stays withheld while A's setup script runs")
    guard case .armed = store.runStates[idA] else {
      return XCTFail("A's auto-run must stay armed until A's own pane mounts")
    }

    fake.release("wr-a")
    fake.release("wr-b")
    await a.value
    await b.value
  }

  /// DEFECT 3, failure half. A superseded create that then FAILS must still run its own failure path:
  /// disarm its auto-run (the command must never launch against a half-set-up tree), keep its run
  /// up with the failure, and release its own deletion protection. Before #167 all three sat inside a
  /// branch gated on owning the presentation slot, so B taking it skipped them.
  func testASupersededCreateThatFailsStillDisarmsAndReleases() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true, failing: ["wr-a"])
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    store.armAutoRun(forWorkroom: idA)
    let b = await startAndLand(store, "wr-b", project: emptyProject)

    fake.release("wr-a")
    await a.value

    XCTAssertNil(store.runStates[idA], "a failed setup must disarm its own auto-run (issue #7)")
    guard case .setupScriptFailed(let message) = store.creationRun(forTargetID: idA)?.outcome else {
      fake.release("wr-b")
      await b.value
      return XCTFail("its run stays up to show the failure")
    }
    XCTAssertFalse(message.isEmpty)
    XCTAssertFalse(
      store.creatingWorkrooms.contains(idA), "and it releases its own deletion protection")

    fake.release("wr-b")
    await b.value
  }

  /// DEFECT 4. Each create keeps its own run, and one create ending clears only its own target —
  /// what a co-displayed create-as-split pane renders (`TargetTerminalDetail`). Ported (#483): the
  /// Dismiss that ended a run is gone, so B's run must outlive A's end instead.
  func testEachCreateKeepsItsOwnSessionAndDismissal() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true)
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")
    let idB = TerminalTarget.workroomID(project: projectPath, name: "wr-b")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    store.selectedTargetID = .workroom(project: projectPath, name: "wr-a")
    XCTAssertEqual(
      store.creationRun(forTargetID: idA)?.name, "wr-a", "A's pane draws A's own run")

    let b = await startAndLand(store, "wr-b", project: emptyProject)

    XCTAssertFalse(
      store.creationRun(forTargetID: idA) === store.creationRun(forTargetID: idB),
      "two concurrent creates must not share one run")
    XCTAssertEqual(store.creationRun(forTargetID: idA)?.name, "wr-a")
    XCTAssertEqual(store.creationRun(forTargetID: idB)?.name, "wr-b")

    fake.release("wr-a")
    await a.value

    XCTAssertNil(store.creationRun(forTargetID: idA))
    XCTAssertNotNil(store.creationRun(forTargetID: idB), "A ending must not clear B's run")
    XCTAssertTrue(store.isCreationBlocking(idB), "nor mount B's withheld terminal")

    fake.release("wr-b")
    await b.value
  }

  /// REWRITTEN (#483, R3, AC 12): two creates in one project both run to completion, each in its
  /// own pane. Nothing holds the project busy any more.
  /// Value: protects=back-to-back creates in one project each get their own pane and both finish;
  /// fails_when=the second is refused or shares the first's pane, or a run or guard is stranded;
  /// no_claim=two creates drawing the same random name (the CLI's worktree add fails the second)
  func testTwoCreatesInOneProjectBothRunToCompletion() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: false, gate: .beforeReady)
    let store = makeStore(fake)

    // `create` is nonisolated, so the two tasks reach it in executor order, not declaration order.
    // Wait for A to take its name before starting B — otherwise B can take "wr-a", and releasing
    // "wr-a" then awaiting `a.value` deadlocks on a gate this test only opens afterwards.
    let a = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 1 }, "A never reached the CLI")
    let paneA = store.selectedTargetID
    let b = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 2 }, "B must not be refused")
    XCTAssertEqual(store.creationRuns.count, 2, "each create has its own run")
    XCTAssertNotEqual(paneA, store.selectedTargetID, "and its own pane")

    fake.release("wr-a")
    await a.value
    XCTAssertEqual(store.creationRuns.count, 1, "A finishing must not end B")

    fake.release("wr-b")
    await b.value
    XCTAssertTrue(store.creationRuns.isEmpty, "both done")
    XCTAssertEqual(store.projects.first?.workrooms.map(\.name), ["wr-a", "wr-b"])
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "and neither create stranded its own guard")
  }

  /// A CLI whose `create` throws BEFORE it ever reports the workroom — a create that failed before
  /// the workroom existed.
  private final class FailsBeforeReadyCLI: WorkroomCLIProtocol {
    func list(warnings: String, project: String?) async throws -> ListResponse {
      ListResponse(projects: [], workroomsDir: nil, configPath: nil)
    }
    func addProject(_ path: String, create: Bool) async throws -> String { path }
    func create(
      project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
    ) async throws -> CreateResponse {
      throw WorkroomCLIError.timedOut  // onReady never fires
    }
    func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}
    func deleteProject(
      _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
    ) async throws -> [URL] { [] }
  }

  /// A create that dies before the workroom exists must leave nothing half-registered behind and
  /// must say so. Ported (#483): it says so in its own pane, which stays (failed) for Try Again
  /// and Close, rather than in an error sheet.
  func testCreateFailingBeforeTheWorkroomExistsClearsEverything() async {
    let store = makeStore(FailsBeforeReadyCLI())

    await store.createWorkroom(in: emptyProject)

    XCTAssertEqual(store.creationRuns.count, 1, "its pane stays, failed")
    XCTAssertEqual(
      Array(store.creationRunForTarget.keys).filter { $0.hasPrefix("wr|") }, [],
      "there was never a workroom target to key an entry on")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty)
    let run = store.creationRuns.values.first
    guard case .failedBeforeWorkroom(let message) = run?.outcome else {
      return XCTFail("the failure must be surfaced, not swallowed")
    }
    XCTAssertFalse(message.isEmpty)
    XCTAssertEqual(run?.steps.first?.state, .failed, "a failure before any step marks the first")
  }

  /// Both in-flight creates get their own tab chip at once. A regression collapsing it back to
  /// "most recent only" passes every single-create test. REWRITTEN (#483, R3): the chips come from
  /// the runs' named targets.
  func testBothConcurrentCreatesAppearAsTabsAtOnce() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true)
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")
    let idB = TerminalTarget.workroomID(project: projectPath, name: "wr-b")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    let b = await startAndLand(store, "wr-b", project: emptyProject)
    defer {
      fake.release("wr-a")
      fake.release("wr-b")
    }

    let ids = Set(store.orderedWorkroomTargets().map(\.target.id))
    XCTAssertTrue(ids.contains(idA), "A's chip must survive B landing")
    XCTAssertTrue(ids.contains(idB))

    fake.release("wr-a")
    fake.release("wr-b")
    await a.value
    await b.value
  }

  /// The withholding is SHARED, so a second window can't mount a terminal into a worktree whose
  /// setup script is running: the runs live on the shared `ProjectStore`. Ported (#483): once the
  /// script succeeds the run ends, so neither window withholds; there is no Dismiss to wait on.
  func testWithholdingIsSharedAcrossWindows() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a"], hasSetup: true)
    let store = makeStore(fake)
    // A second window: its own AppStore (own selection), the SAME shared ProjectStore — exactly how
    // `WorkroomApp` builds a ⌘N window.
    let other = AppStore(projectStore: store.projectStore, cli: fake)
    other.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    XCTAssertTrue(store.isCreationBlocking(idA), "the creating window withholds")
    XCTAssertTrue(
      other.isCreationBlocking(idA),
      "so does a window that never started it — the script writes the same worktree")

    fake.release("wr-a")
    await a.value
    XCTAssertFalse(other.isCreationBlocking(idA), "the create is over in every window")
    XCTAssertFalse(store.isCreationBlocking(idA))
  }

  /// R3 (#483): the name arrives, and before the landing finishes another window reloads and
  /// lists the workroom. Its terminal must stay withheld in BOTH windows: the run's target is
  /// recorded before anything publishes the workroom.
  /// Value: protects=no window mounts a shell into a worktree between its name arriving and the
  /// landing; fails_when=the target is recorded after the landing's reload; no_claim=the view's
  /// mount itself (`TargetTerminalDetail` keys on `isCreationBlocking`)
  func testASecondWindowReloadingMidLandingStillWithholds() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a"], hasSetup: true, holdsFirstListAfterReady: true)
    let store = makeStore(fake)
    let other = AppStore(projectStore: store.projectStore, cli: fake)
    other.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.isListHeld }, "the landing's reload never started")
    await other.reload()

    XCTAssertEqual(
      other.target(for: .workroom(project: projectPath, name: "wr-a"))?.opensTerminals, true,
      "precondition: the other window lists the workroom, ready to mount")
    XCTAssertTrue(other.isCreationBlocking(idA), "but withholds its terminal")
    XCTAssertTrue(store.isCreationBlocking(idA))

    fake.releaseList()
    fake.release("wr-a")
    await a.value
  }

  /// Run must not launch the project command against a worktree still being set up (issue #7's
  /// disarm exists for the same reason). Guarded in `startRunCommand`, the one place the toolbar,
  /// sidebar and menu all route through. Ported (#483): once the script succeeds the run is over,
  /// so Run works at once; the Dismiss step is gone.
  func testRunIsRefusedWhileTheWorkroomIsStillBeingCreated() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a"], hasSetup: true)
    let store = AppStore(cli: fake)
    store.creationSuccessHold = .zero
    store.closesFinishedCreations = { true }
    // Never spawn a real PTY: this test only cares whether a run TAB was opened.
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    defer { fake.release("wr-a") }
    guard let target = store.target(for: .workroom(project: projectPath, name: "wr-a")) else {
      return XCTFail("the created workroom must resolve")
    }
    // Configured immediately before the call, and cleared right after: `Defaults[.runCommands]` is
    // one domain shared with every parallel test worker, and `RunCommandTests` wipes it wholesale.
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: projectPath)
    store.startRunCommand(for: target)
    XCTAssertNil(store.runStates[idA]?.tab, "no run terminal may open against a half-built tree")

    fake.release("wr-a")
    await a.value

    // Positive control: with the create over the SAME call starts a run, so the assertion above
    // failed on a guard rather than on a missing command.
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: projectPath)
    store.startRunCommand(for: target)
    XCTAssertNotNil(store.runStates[idA]?.tab, "once the create is fully over, Run works normally")
    store.setRunConfig(.empty, forProject: projectPath)
  }

  /// REWRITTEN (#483, R3): a create that finishes while ANOTHER create is still unnamed must not be
  /// buried by it: its run ends and its pane can mount, while the other's pane keeps the selection
  /// it took on the click.
  /// Value: protects=a finished create's terminal mounts even while another create runs;
  /// fails_when=A's run or withholding outlives A, or B's pane loses the selection;
  /// no_claim=the panes' drawing
  func testACompletedCreateIsNotBuriedByAnotherCreatesPreNameLoader() async {
    // A lands first and holds mid-create; B then starts and parks BEFORE its ready event, so B is
    // unnamed at the moment A finishes underneath it.
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: false,
      gates: ["wr-a": .afterReady, "wr-b": .beforeReady])
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    let b = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 2 }, "B never reached the CLI")
    guard case .creation = store.selectedTargetID else {
      fake.release("wr-a")
      fake.release("wr-b")
      return XCTFail("B's pane took the selection on the click")
    }
    let paneB = store.selectedTargetID

    fake.release("wr-a")
    await a.value

    XCTAssertEqual(store.selectedTargetID, paneB, "B's unnamed pane keeps the selection")
    XCTAssertNil(store.creationRun(forTargetID: idA), "A's run ended with its create")
    XCTAssertFalse(
      store.isCreationBlocking(idA),
      "so nothing covers A's pane — it can mount, open its terminal and take its tab")

    fake.release("wr-b")
    await b.value
  }

  /// Local status merges are ordered on when the read FINISHED, not on when the result lands. Five
  /// lanes probe the same row and none is ordered against the others, so a slow probe routinely lands
  /// after a faster one that saw the tree later — and landing order says nothing about which tree
  /// each result saw. Getting this backwards discards the FRESH result and leaves the dirty dot
  /// stale, which is the failure the post-create probe exists to prevent.
  func testALocalStatusMergeIsOrderedOnItsReadNotOnWhenItLands() async {
    let (proj, root, _) = makeRealProject(workroom: "wr")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    // Seeded directly rather than via `reload()`: that forks the status sweep, which probes this same
    // row on its own lane. This test drives the lanes by hand, so it must be the only one running.
    store.projects = [proj]
    let sid = SidebarID.workroom(project: root, name: "wr")

    let early = Date()
    let late = early.addingTimeInterval(1)
    var fresh = WorkroomStatus.unresolved
    fresh.dirty = true
    fresh.localReadAt = late
    var stale = WorkroomStatus.unresolved
    stale.dirty = false
    stale.localReadAt = early

    // The later read lands FIRST — the fast lane.
    store.mergeLocalStatus(fresh, into: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, true)

    // Then the earlier read lands, from a lane that saw an older tree but resolved slower. It must be
    // dropped even though it is the newer WRITE.
    store.mergeLocalStatus(stale, into: sid)
    XCTAssertEqual(
      store.workroomStatuses[sid]?.dirty, true,
      "a result read earlier must not overwrite one that saw the tree later")

    // Ordering never blocks genuine progress: a later read still lands.
    var newest = WorkroomStatus.unresolved
    newest.dirty = false
    newest.localReadAt = late.addingTimeInterval(1)
    store.mergeLocalStatus(newest, into: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, false, "a genuinely later read must win")

    // And an unstamped status (hand-built, as several tests do) can't be ordered, so it merges.
    store.mergeLocalStatus(WorkroomStatus(dirty: true), into: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, true, "an unstamped result still merges")
  }

  /// A probe that found nothing new redraws nothing, yet keeps its clocks (#503). Every status view
  /// observes the whole `workroomStatuses`, and a fresh `lastChecked` used to make each write look new.
  /// Value: protects=an unchanged merge notifies no reader while the TTL gate and the read ordering
  /// still see its clocks; fails_when=a clock compares by time, a write bypasses AppStore's
  /// whole-value proxy, or the write is skipped and the clocks go stale; no_claim=the redraw time saved
  func testAnUnchangedLocalStatusMergeNotifiesNoOneButKeepsItsClocks() async {
    let (proj, root, _) = makeRealProject(workroom: "wr")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    store.projects = [proj]
    let sid = SidebarID.workroom(project: root, name: "wr")
    let early = Date()
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: true, lastChecked: .distantPast, localReadAt: early)

    var same = WorkroomStatus.unresolved
    same.dirty = true
    same.localReadAt = early.addingTimeInterval(2)
    var notified = false
    withObservationTracking {
      _ = store.workroomStatuses
    } onChange: {
      notified = true
    }
    store.mergeLocalStatus(same, into: sid)
    XCTAssertFalse(notified, "a probe that changed nothing on screen must not redraw")
    XCTAssertEqual(store.workroomStatuses[sid]?.localReadAt, same.localReadAt)
    XCTAssertGreaterThan(
      store.workroomStatuses[sid]?.lastChecked ?? .distantPast, .distantPast,
      "the TTL gate must see this check")

    // The silently stored read still orders: one that read the tree before it is dropped.
    var stale = WorkroomStatus.unresolved
    stale.dirty = false
    stale.localReadAt = early.addingTimeInterval(1)
    store.mergeLocalStatus(stale, into: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, true, "an older read must not win")

    // A first check with nothing else new still redraws: "Checking…" has to clear.
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: true, localReadAt: early.addingTimeInterval(3))
    notified = false
    withObservationTracking {
      _ = store.workroomStatuses
    } onChange: {
      notified = true
    }
    var firstCheck = WorkroomStatus.unresolved
    firstCheck.dirty = true
    firstCheck.localReadAt = early.addingTimeInterval(4)
    store.mergeLocalStatus(firstCheck, into: sid)
    XCTAssertTrue(notified, "a clock that appears must redraw")
  }

  /// The resolver stamps the read itself, and the post-create probe goes through that same shared
  /// ordering — it is one of the five lanes, not a special case with its own guard.
  func testThePostCreateProbeMergesThroughTheSharedOrdering() async {
    let (proj, root, _) = makeRealProject(workroom: "wr")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    store.projects = [proj]
    let sid = SidebarID.workroom(project: root, name: "wr")

    // With nothing recorded the probe merges: `makeRealProject` is a plain directory, so a probe that
    // actually runs resolves `.notRepository` — and carries the resolver's own read stamp.
    store.refreshLocalStatus(for: sid)
    await waitUntil(
      { store.workroomStatuses[sid]?.failure == .notRepository }, "the probe must merge normally")
    XCTAssertNotNil(
      store.workroomStatuses[sid]?.localReadAt, "the resolver must stamp the read it performed")

    // A result already recorded from a LATER read wins over the probe's own older one.
    var fresher = WorkroomStatus.unresolved
    fresher.dirty = true
    fresher.localReadAt = Date().addingTimeInterval(60)
    store.workroomStatuses[sid] = fresher

    store.refreshLocalStatus(for: sid)
    try? await Task.sleep(nanoseconds: 400_000_000)  // > the probe's own resolve time

    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, true, "the later read must survive")
    XCTAssertNil(
      store.workroomStatuses[sid]?.failure, "the older read must not have merged over it")
  }

}
