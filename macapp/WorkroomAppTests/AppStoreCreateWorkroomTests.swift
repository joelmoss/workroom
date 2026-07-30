import Foundation
import XCTest

@testable import Workroom

/// A fake CLI that drives `createWorkroom` deterministically (issue #116): it streams optional log
/// lines, fires `onReady` with a controlled name + `hasSetup`, then sleeps briefly to model the
/// workspace/setup work running after the "created" event — so the main-queue `onReady` effects have
/// applied by the time `create` returns, mirroring a real subprocess. `list` returns a project set
/// that already contains the created workroom, so the post-create reload resolves the selection.
private final class CreatingFakeCLI: WorkroomCLIProtocol {
  let projectPath: String
  let workroomName: String
  let hasSetup: Bool
  let logLines: [String]
  let failAfterReady: Bool

  init(
    projectPath: String, workroomName: String, hasSetup: Bool, logLines: [String] = [],
    failAfterReady: Bool = false
  ) {
    self.projectPath = projectPath
    self.workroomName = workroomName
    self.hasSetup = hasSetup
    self.logLines = logLines
    self.failAfterReady = failAfterReady
  }

  private var workroomAbsPath: String { "\(projectPath)/.workrooms/\(workroomName)" }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    let workroom = Workroom(
      name: workroomName, path: workroomAbsPath, vcsName: "git", warnings: [])
    return ListResponse(
      projects: [Project(path: projectPath, vcs: "git", workrooms: [workroom])],
      workroomsDir: nil, configPath: nil)
  }

  func addProject(_ path: String, create: Bool) async throws -> String { projectPath }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    for line in logLines { onLog?(line) }
    onReady?(workroomName, workroomAbsPath, hasSetup)
    // Returns IMMEDIATELY after the ready event — the worst case for the create flow, and the whole
    // point of this fake. There used to be a 40ms sleep here "to let the main-queue onReady work
    // settle", which papered over a real ordering hazard: the landing is async, so a create whose
    // ready→exit gap is short read `creation?.targetID == nil`, re-landed with `setup: false` and
    // cleared the dialog. 40ms only made that rare (it still flaked ~1 run in 6). `createWorkroom`
    // now awaits the landing, so no sleep is needed and this gap is a deterministic assertion.
    if failAfterReady { throw WorkroomCLIError.timedOut }
    return CreateResponse(
      name: workroomName, path: workroomAbsPath, vcs: "git", project: project)
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
    return store
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

  // MARK: - Async create flow

  /// With NO setup script there's no dialog — just the loader — and the create clears itself when it
  /// completes: `creation` ends nil and the new workroom is selected so its terminal drops in (#116).
  func testNoSetupCreateClearsAndSelects() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertNil(store.creation, "a no-setup create must clear itself when done")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-otter"))
    XCTAssertFalse(store.isCreationFocused)
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "the create guard lifts when done (issue #116)")
  }

  /// With a setup script the dialog stays up (blocking) after creation completes — the terminal is
  /// withheld until the user dismisses it — and the new workroom's slot is the focused detail (#116).
  func testSetupCreateKeepsDialogBlocking() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "brave-fox", hasSetup: true,
      logLines: ["installing deps", "done"])
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "brave-fox")
    XCTAssertNotNil(store.creation, "a setup create must keep the dialog up until dismissed")
    XCTAssertEqual(store.creation?.hasSetup, true)
    XCTAssertEqual(store.creation?.targetID, wrID)
    XCTAssertTrue(store.isCreationBlocking(wrID), "the terminal must stay withheld during setup")
    XCTAssertTrue(store.isCreationFocused, "the new workroom's slot owns the detail")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "brave-fox"))
    XCTAssertEqual(store.creation?.session.isFinished, true)
    XCTAssertNil(store.creation?.session.failureMessage)
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "setup finished → the workroom is deletable again (#116)")

    // Dismissing clears the dialog (which lets the withheld terminal mount).
    store.dismissCreation()
    XCTAssertNil(store.creation)
    XCTAssertFalse(store.isCreationBlocking(wrID))
    XCTAssertFalse(store.isCreationFocused)
  }

  /// A setup failure keeps the dialog up as a blocking failure (with its message) so the user sees
  /// why — `hasSetup` is forced true even if the failure preceded the setup flag being read.
  func testSetupFailureKeepsDialogWithMessage() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "lost-cat", hasSetup: true, logLines: ["boom"],
      failAfterReady: true)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "lost-cat")
    XCTAssertNotNil(store.creation, "a failed setup must keep the dialog up")
    XCTAssertEqual(store.creation?.hasSetup, true)
    XCTAssertTrue(store.isCreationBlocking(wrID))
    XCTAssertNotNil(
      store.creation?.session.failureMessage, "the failure must be shown in the dialog")
  }

  // MARK: - Synchronous state semantics

  /// `isCreationBlocking` is true only for the in-progress creation's target AND only when a setup
  /// script is running — a no-setup create never withholds the terminal.
  func testIsCreationBlockingSemantics() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")
    let session = ScriptLogSession(title: "t", phase: "setup")
    let proj = Project(path: projectPath, vcs: "git", workrooms: [])

    XCTAssertFalse(store.isCreationBlocking(wrID), "no creation → never blocking")

    store.creation = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: false)
    XCTAssertFalse(store.isCreationBlocking(wrID), "a no-setup create never blocks")

    store.creation = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: true)
    XCTAssertTrue(store.isCreationBlocking(wrID))
    XCTAssertFalse(
      store.isCreationBlocking(TerminalTarget.workroomID(project: projectPath, name: "other")),
      "only the creation's own target is withheld")
  }

  /// `isCreationFocused` owns the detail unconditionally pre-name (the loader phase), then follows
  /// selection once named so a setup script blocks ONLY the new workroom — selecting another workroom
  /// un-focuses it and reveals that workroom while the create keeps running (issue #116).
  func testIsCreationFocusedFollowsSelection() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let session = ScriptLogSession(title: "t", phase: "setup")
    let proj = Project(path: projectPath, vcs: "git", workrooms: [])

    // Pre-name: the loader owns the detail regardless of any prior selection.
    store.creation = WorkroomCreation(session: session, project: proj)
    store.selectedTargetID = .root(project: projectPath)
    XCTAssertTrue(store.isCreationFocused, "pre-name the loader owns the detail")

    // Named: focused only when the new workroom's own tab is selected.
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")
    store.creation = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: true)
    store.selectedTargetID = .root(project: projectPath)
    XCTAssertFalse(store.isCreationFocused, "another workroom stays visible while setup runs")
    store.selectedTargetID = .workroom(project: projectPath, name: "wr")
    XCTAssertTrue(store.isCreationFocused)
  }

  /// The in-progress creation's target shows as a workroom tab even before its terminal exists — so
  /// the chip is present through setup (issue #116) — and disappears once the dialog is dismissed.
  func testCreationTargetAppearsAsTab() async {
    let fake = FakeWorkroomCLI(canonical: projectPath, projects: [project(withWorkroom: "tab-wr")])
    let store = makeStore(fake)
    await store.reload()  // land the workroom in `projects` so its target resolves

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "tab-wr")
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "no tab before creation (the workroom has no live terminal)")

    store.creation = WorkroomCreation(
      session: ScriptLogSession(title: "t", phase: "setup"),
      project: project(withWorkroom: "tab-wr"), name: "tab-wr", targetID: wrID, hasSetup: true)
    XCTAssertTrue(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the creation target must show as a tab during setup")

    store.dismissCreation()
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the tab falls back to terminal-presence once the dialog is dismissed")
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
  /// burst may probe its worktree — that per-burst git/jj probing (~70/sec under an `npm install`)
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
    try? await Task.sleep(nanoseconds: 500_000_000)

    // A probe ran and resolved a status: wrPath isn't a real repo, so it's `.notRepository`.
    XCTAssertEqual(
      store.workroomStatuses[sid]?.failure, .notRepository,
      "once setup completes the worktree must be probed again")
  }

  /// A late `onReady` echo lands in `landOnCreatedWorkroom` with `creation == nil`. The early
  /// `creatingWorkrooms.insert` MUST be undone on that bail, or the workroom is permanently
  /// suppressed (its dirty dot / Changes panel never updates again). Reachable only by calling the
  /// method directly — `onReady` is non-escaping, so a fake CLI can't reproduce the timing.
  func testLateEchoLandingRemovesCreatingFlag() async {
    let fake = FakeWorkroomCLI(canonical: projectPath, projects: [project(withWorkroom: "wr")])
    let store = makeStore(fake)
    store.creation = nil  // the create already finished + cleared creation; this is the late echo
    await store.landOnCreatedWorkroom(
      name: "wr", project: project(withWorkroom: "wr"), setup: false)
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty,
      "a late onReady echo (no active creation) must not leave a leaked creating flag")
  }
}
