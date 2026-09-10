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
  /// Workrooms that already exist in the project and must SURVIVE the post-create reload. Without
  /// them `list` returns only the new workroom, so a split anchor stops resolving the moment
  /// `landOnCreatedWorkroom` reloads — and the split is (correctly) refused for the wrong reason.
  let existingWorkrooms: [String]

  init(
    projectPath: String, workroomName: String, hasSetup: Bool, logLines: [String] = [],
    failAfterReady: Bool = false, existingWorkrooms: [String] = []
  ) {
    self.projectPath = projectPath
    self.workroomName = workroomName
    self.hasSetup = hasSetup
    self.logLines = logLines
    self.failAfterReady = failAfterReady
    self.existingWorkrooms = existingWorkrooms
  }

  private var workroomAbsPath: String { "\(projectPath)/.workrooms/\(workroomName)" }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    let workrooms = (existingWorkrooms + [workroomName]).map {
      Workroom(
        name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
    }
    return ListResponse(
      projects: [Project(path: projectPath, vcs: "git", workrooms: workrooms)],
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
    // ready→exit gap is short saw no landing yet, re-landed with `setup: false` and
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

/// A fake CLI that lets a test control the INTERLEAVING of two real `createWorkroom` calls (issue
/// #167). `create` hands out the next name in `names`, and suspends on a continuation — either just
/// before it fires `onReady` (`.beforeReady`, so the create stays in its pre-name phase) or just
/// after (`.afterReady`, so the workroom exists and its setup script is "running") — until the test
/// calls `release(name)`. That's what makes two creates genuinely overlap inside their own real
/// `createWorkroom` bodies, which is where every defect in #167 lived; hand-assigning store state and
/// calling `landOnCreatedWorkroom` proves an isolated guard and nothing about the flow.
///
/// `list` reports every workroom that has fired `onReady` so far, so each landing's reload resolves.
private final class GatedFakeCLI: WorkroomCLIProtocol, @unchecked Sendable {
  enum Gate {
    case beforeReady
    case afterReady
  }

  let projectPath: String
  let hasSetup: Bool
  /// Names whose `create` throws once released — a setup script that failed after the workroom existed.
  let failing: Set<String>
  /// Where each name stops, if at all. Defaults to `gate` for every name; pass `gates` to hold two
  /// creates at DIFFERENT points — the only way to model one create finishing underneath another
  /// create's pre-name loader. A name absent from this map never stops.
  private let gates: [String: Gate]
  private let names: [String]
  private let lock = NSLock()
  private var callIndex = 0
  private var ready: [String] = []
  private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
  private var released: Set<String> = []

  init(
    projectPath: String, names: [String], hasSetup: Bool, gate: Gate = .afterReady,
    failing: Set<String> = [], gates: [String: Gate]? = nil
  ) {
    self.projectPath = projectPath
    self.names = names
    self.hasSetup = hasSetup
    self.failing = failing
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
    lock.lock()
    let names = ready
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

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    lock.lock()
    let name = names[min(callIndex, names.count - 1)]
    callIndex += 1
    lock.unlock()

    let stop = gates[name]
    if stop == .beforeReady { await hold(name) }
    lock.lock()
    ready.append(name)
    lock.unlock()
    onReady?(name, path(name), hasSetup)
    if stop == .afterReady { await hold(name) }
    if failing.contains(name) { throw WorkroomCLIError.timedOut }
    return CreateResponse(name: name, path: path(name), vcs: "git", project: project)
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

  /// With NO setup script there's no dialog — just the loader — and the create clears itself when it
  /// completes: no `creations` entry survives, `pendingCreation` clears, and the new workroom is
  /// selected so its terminal drops in (#116).
  func testNoSetupCreateClearsAndSelects() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertTrue(store.creations.isEmpty, "a no-setup create must clear itself when done")
    XCTAssertNil(store.pendingCreation)
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
    XCTAssertNotNil(store.creations[wrID], "a setup create must keep the dialog up until dismissed")
    XCTAssertEqual(store.creations[wrID]?.hasSetup, true)
    XCTAssertEqual(store.creations[wrID]?.targetID, wrID)
    XCTAssertNil(store.pendingCreation, "the pre-name slot clears once the create ends")
    XCTAssertTrue(store.isCreationBlocking(wrID), "the terminal must stay withheld during setup")
    XCTAssertTrue(store.isCreationFocused, "the new workroom's slot owns the detail")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "brave-fox"))
    XCTAssertEqual(store.creations[wrID]?.session.isFinished, true)
    XCTAssertNil(store.creations[wrID]?.session.failureMessage)
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "setup finished → the workroom is deletable again (#116)")

    // Dismissing clears the dialog (which lets the withheld terminal mount).
    store.dismissCreation(wrID)
    XCTAssertTrue(store.creations.isEmpty)
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
    XCTAssertNotNil(store.creations[wrID], "a failed setup must keep the dialog up")
    XCTAssertEqual(store.creations[wrID]?.hasSetup, true)
    XCTAssertTrue(store.isCreationBlocking(wrID))
    XCTAssertNotNil(
      store.creations[wrID]?.session.failureMessage, "the failure must be shown in the dialog")
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "a failed setup releases its own deletion protection")
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

    store.creations[wrID] = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: false)
    XCTAssertFalse(store.isCreationBlocking(wrID), "a no-setup create never blocks")

    store.creations[wrID] = WorkroomCreation(
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

    // Pre-name with nothing on screen: the loader owns the detail — the case it exists for.
    store.pendingCreation = WorkroomCreation(session: session, project: proj)
    store.selectedTargetID = nil
    XCTAssertTrue(store.isCreationFocused, "pre-name with nothing selected, the loader owns it")

    // Pre-name with a LIVE target selected: it must NOT take the window (issue #167). Full-frame is
    // a blackout — it blanked a concurrent create's streaming dialog and every split pane.
    store.projects = [self.project(withWorkroom: "live")]
    store.selectedTargetID = .workroom(project: projectPath, name: "live")
    XCTAssertFalse(
      store.isCreationFocused, "a pre-name create must not blank the workroom already on screen")
    XCTAssertNotNil(store.pendingCreation, "the create is still running — it just isn't full-frame")

    // Named: focused only when the new workroom's own tab is selected.
    store.pendingCreation = nil
    store.projects = []
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")
    store.creations[wrID] = WorkroomCreation(
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

    store.creations[wrID] = WorkroomCreation(
      session: ScriptLogSession(title: "t", phase: "setup"),
      project: project(withWorkroom: "tab-wr"), name: "tab-wr", targetID: wrID, hasSetup: true)
    XCTAssertTrue(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the creation target must show as a tab during setup")

    store.dismissCreation(wrID)
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

    // A probe ran and resolved a status: wrPath isn't a real repo, so it's `.notRepository`.
    await waitUntil(
      { store.workroomStatuses[sid]?.failure == .notRepository },
      "once setup completes the worktree must be probed again")
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
    await store.landOnCreatedWorkroom(
      name: "wr", project: project(withWorkroom: "wr"), setup: false,
      session: ScriptLogSession(title: "t", phase: "setup"), landing: landing)
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty,
      "a landing past the end of its create must not leave a leaked creating flag")
    XCTAssertTrue(store.creations.isEmpty, "nor a creation entry nobody will clear")
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
    await waitUntil(
      { store.creations[TerminalTarget.workroomID(project: self.projectPath, name: name)] != nil },
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
  /// disarm its auto-run (the command must never launch against a half-set-up tree), keep its dialog
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
    XCTAssertEqual(
      store.creations[idA]?.hasSetup, true, "its dialog stays up to show the failure")
    XCTAssertNotNil(store.creations[idA]?.session.failureMessage)
    XCTAssertFalse(
      store.creatingWorkrooms.contains(idA), "and it releases its own deletion protection")

    fake.release("wr-b")
    await b.value
  }

  /// DEFECT 4. Each create keeps its own setup log, and each pane's Dismiss clears only its own
  /// target — what a co-displayed create-as-split pane renders (`TargetTerminalDetail`).
  func testEachCreateKeepsItsOwnSessionAndDismissal() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: true)
    let store = makeStore(fake)
    let idA = TerminalTarget.workroomID(project: projectPath, name: "wr-a")
    let idB = TerminalTarget.workroomID(project: projectPath, name: "wr-b")

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    // The moment a create lands it stops being pre-name, so the detail must show ITS dialog — not
    // the loader the pre-name slot draws (which has no target, so it can only be full-frame).
    store.selectedTargetID = .workroom(project: projectPath, name: "wr-a")
    XCTAssertNil(store.pendingCreation, "a landed create must give up the pre-name loader slot")
    XCTAssertEqual(
      store.focusedCreation?.targetID, idA, "the focused detail is A's own setup dialog")

    let b = await startAndLand(store, "wr-b", project: emptyProject)

    XCTAssertNotEqual(
      store.creations[idA]?.session.id, store.creations[idB]?.session.id,
      "two concurrent creates must not share one setup log")
    XCTAssertEqual(store.creations[idA]?.name, "wr-a")
    XCTAssertEqual(store.creations[idB]?.name, "wr-b")

    fake.release("wr-a")
    fake.release("wr-b")
    await a.value
    await b.value

    store.dismissCreation(idA)
    XCTAssertNil(store.creations[idA])
    XCTAssertNotNil(store.creations[idB], "one pane's Dismiss must not clear the other's dialog")
    XCTAssertTrue(store.isCreationBlocking(idB), "nor mount the other's withheld terminal")
  }

  /// DEFECT 5. Two creates in one project each keep their own spinner: `busyProjects` is a count, so
  /// the first to finish can't clear the other's. Gated BEFORE the ready event, which is the window
  /// the spinner covers (the landing drops it the moment the workroom exists).
  func testTwoCreatesInOneProjectEachKeepTheirOwnSpinner() async {
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: false, gate: .beforeReady)
    let store = makeStore(fake)

    // `create` is nonisolated, so the two tasks reach it in executor order, not declaration order.
    // Wait for A to take its name before starting B — otherwise B can take "wr-a", and releasing
    // "wr-a" then awaiting `a.value` deadlocks on a gate this test only opens afterwards.
    let a = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ fake.assignedCount == 1 }, "A never reached the CLI")
    let b = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil(
      { (store.busyProjects[self.projectPath] ?? 0) == 2 }, "both creates must be busy")

    fake.release("wr-a")
    await a.value
    XCTAssertTrue(
      store.isBusyProject(projectPath), "A finishing must not clear B's spinner")

    fake.release("wr-b")
    await b.value
    XCTAssertFalse(store.isBusyProject(projectPath), "both done ⇒ no spinner")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "and neither create stranded its own guard")
  }

  /// A CLI whose `create` throws BEFORE it ever fires `onReady` — a create that failed before the
  /// workroom existed. No gated fake can express this (they all report ready first), and it is the
  /// one `createWorkroom` branch with no coverage: the `else` that surfaces the error, plus the
  /// unconditional `clearPendingCreation` that stops the pre-name loader outliving a dead create.
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

  /// A create that dies before the workroom exists must leave NOTHING behind — no loader stuck on
  /// screen, no half-registered target — and must say so.
  func testCreateFailingBeforeTheWorkroomExistsClearsEverything() async {
    let store = makeStore(FailsBeforeReadyCLI())

    await store.createWorkroom(in: emptyProject)

    XCTAssertNil(store.pendingCreation, "a pre-landing failure must clear the loader slot")
    XCTAssertTrue(store.creations.isEmpty, "there was never a target to key an entry on")
    XCTAssertTrue(store.creatingWorkrooms.isEmpty)
    XCTAssertFalse(store.isCreationFocused, "the detail must fall back to the terminal")
    XCTAssertFalse(store.isBusyProject(projectPath), "and the row's spinner must stop")
    XCTAssertNotNil(store.errorMessage, "the failure must be surfaced, not swallowed")
  }

  /// Both in-flight creates get their own tab chip at once — the `formUnion(creations.keys)` that
  /// replaced a single-slot insert. A regression collapsing it back to "most recent only" passes
  /// every single-create test.
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
  /// setup script is running — `creations` is per-window, `settingUpWorkrooms` is not. A no-setup
  /// create still never withholds.
  func testWithholdingIsSharedAcrossWindows() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a"], hasSetup: true)
    let store = makeStore(fake)
    // A second window: its own AppStore (own selection, own `creations`), the SAME shared
    // ProjectStore — exactly how `WorkroomApp` builds a ⌘N window.
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
    XCTAssertFalse(
      other.isCreationBlocking(idA), "the other window has no dialog, so it stops withholding")
    XCTAssertTrue(
      store.isCreationBlocking(idA), "the creating window keeps it until ITS dialog is dismissed")
  }

  /// Run must not launch the project command against a worktree still being set up (issue #7's
  /// disarm exists for the same reason). Guarded in `startRunCommand`, the one place the toolbar,
  /// sidebar and menu all route through.
  func testRunIsRefusedWhileTheWorkroomIsStillBeingCreated() async {
    let fake = GatedFakeCLI(projectPath: projectPath, names: ["wr-a"], hasSetup: true)
    let store = AppStore(cli: fake)
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

    // Positive control: with the create finished the SAME call starts a run, so the assertion above
    // failed on the guard rather than on a missing command.
    store.startRunCommand(for: target)
    XCTAssertNotNil(store.runStates[idA]?.tab, "once setup is done, Run works normally")
    store.setRunConfig(.empty, forProject: projectPath)
  }

  /// A no-setup create that finishes while ANOTHER create's pre-name loader is up must not be buried
  /// by it: its pane has to become mountable the moment its own entry clears, or it never opens a
  /// terminal, never gains a tab chip, and leaves its auto-run armed until the user hunts it down in
  /// the sidebar. Before `focusedCreation` yielded to a live selected target, B's full-frame loader
  /// kept covering A for as long as the CLI took to name B.
  func testACompletedCreateIsNotBuriedByAnotherCreatesPreNameLoader() async {
    // A lands first and holds mid-create; B then starts and parks BEFORE its ready event, so B owns
    // the pre-name slot at the moment A finishes underneath it.
    let fake = GatedFakeCLI(
      projectPath: projectPath, names: ["wr-a", "wr-b"], hasSetup: false,
      gates: ["wr-a": .afterReady, "wr-b": .beforeReady])
    let store = makeStore(fake)

    let a = await startAndLand(store, "wr-a", project: emptyProject)
    let b = Task { await store.createWorkroom(in: emptyProject) }
    await waitUntil({ store.pendingCreation != nil }, "B never claimed the pre-name slot")

    fake.release("wr-a")
    await a.value

    XCTAssertNotNil(store.pendingCreation, "B is still pre-name and still owns the slot")
    XCTAssertEqual(
      store.selectedTargetID, .workroom(project: projectPath, name: "wr-a"),
      "A's landing selected A")
    XCTAssertTrue(
      store.creations.isEmpty, "A had no setup script, so its entry cleared when it ended")
    XCTAssertNil(
      store.focusedCreation,
      "so nothing covers A's pane — it can mount, open its terminal and take its tab")
    XCTAssertFalse(store.isCreationFocused)

    fake.release("wr-b")
    await b.value
  }

  /// The post-create probe is a FOURTH unordered lane onto the same row, and `mergeLocalStatus` has
  /// no freshness check — so it must yield to whatever arrived while it was running. Without this a
  /// setup script finishing (exactly when the file-watcher lane is busiest) could land a pre-edit
  /// read on top of a newer one and leave the dirty dot stale until the next refresh.
  func testThePostCreateProbeYieldsToANewerResult() async {
    let (proj, root, _) = makeRealProject(workroom: "wr")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = makeStore(FakeWorkroomCLI(canonical: root, projects: [proj]))
    await store.reload()
    let sid = SidebarID.workroom(project: root, name: "wr")

    // Positive control first: with nothing newer recorded, the probe DOES merge. `makeRealProject`
    // is a plain directory, so a probe that runs resolves `.notRepository`.
    store.refreshLocalStatus(for: sid)
    await waitUntil(
      { store.workroomStatuses[sid]?.failure == .notRepository }, "the probe must merge normally")

    // Now stamp a result newer than the probe's start and re-probe: the stale answer must be dropped.
    var newer = WorkroomStatus.unresolved
    newer.dirty = true
    newer.lastChecked = Date().addingTimeInterval(60)
    store.workroomStatuses[sid] = newer

    store.refreshLocalStatus(for: sid)
    try? await Task.sleep(nanoseconds: 400_000_000)  // > the probe's own resolve time

    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, true, "the newer result must survive")
    XCTAssertNil(
      store.workroomStatuses[sid]?.failure, "the stale probe must not have merged over it")
  }

}
