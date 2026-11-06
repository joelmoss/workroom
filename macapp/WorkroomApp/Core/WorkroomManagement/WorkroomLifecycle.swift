import AppKit
import Defaults
import OSLog
import WorkroomDomain

/// Creating and deleting workrooms, one for the whole app (ADR 0068): every create's run and the
/// pane it holds, the creates and deletes in flight, and what a create or delete does to every
/// window. A window applies those effects itself, as `Event`s it is handed synchronously on the
/// main actor (ADR 0021's style), so no window can miss one and no window's store loops over its
/// siblings. It also watches each project's `.git` once for the app, not once per window.
///
/// The create and delete flows are here too (`WorkroomLifecycle+Create`, `WorkroomLifecycle+Delete`).
/// Each is asked from one window, which it reaches through that window's `LifecycleWindow`: where
/// the pane opens, its questions, sheets and alerts, its auto-run and its reload.
///
/// Production builds every window's store with `.shared`; tests build an isolated `AppStore()` with
/// its own, over its own `VCSStatusService` and `ProjectStore`.
@MainActor
@Observable
// `ObservableObject` only so views can take it as an `@EnvironmentObject`, as they take the store;
// Observation tracks the reads.
final class WorkroomLifecycle: ObservableObject {
  static let shared = WorkroomLifecycle(vcsStatus: .shared)

  /// The status a create holds back (`VCSStatusService.isCreating`) and the root labels the `.git`
  /// watch refreshes.
  @ObservationIgnored let vcsStatus: VCSStatusService
  /// The projects whose workrooms these are.
  var projectStore: ProjectStore { vcsStatus.projectStore }

  init(vcsStatus: VCSStatusService) {
    self.vcsStatus = vcsStatus
    vcsStatus.lifecycle = self
  }

  // MARK: Creates and deletes in flight

  // The `Equatable` collections below are computed over private stored ones so that a write which
  // changes nothing notifies no one (`docs/macapp-perf-facts.md`): `creatingWorkrooms.remove(id)`
  // for an id already gone must not redraw the sidebar.

  /// Target ids of workrooms whose create process is still running: from the moment the workroom
  /// has a name until the CLI or the provisioning returns (issue #116, #483). A workroom here must
  /// not be deleted, from any window: its setup is running against it.
  var creatingWorkrooms: Set<TerminalTarget.ID> {
    get { storedCreatingWorkrooms }
    set { storedCreatingWorkrooms = newValue }
  }
  private var storedCreatingWorkrooms: Set<TerminalTarget.ID> = []

  /// Every create's progress, running or failed, by run id (#483), so every window that shows a
  /// create shows the same checklist.
  var creationRuns: [UUID: CreationRun] = [:]

  /// The run each pane belongs to: its provisional `TargetID.creation`, then its workroom's own id
  /// once it has a name. A target here keeps its terminal withheld in every window until the run
  /// ends (issue #167), which is why the named id goes in before the reload that publishes it.
  var creationRunForTarget: [TerminalTarget.ID: UUID] {
    get { storedCreationRunForTarget }
    set { storedCreationRunForTarget = newValue }
  }
  private var storedCreationRunForTarget: [TerminalTarget.ID: UUID] = [:]

  /// Creates waiting on a provider's setup, one entry per provider, in the order they began waiting
  /// (R2, #483). Only the first has its sheet up, one sheet at a time across every window.
  var remoteSetupWaits: [RemoteSetupWait] = []

  /// Target ids of workrooms with an in-flight optimistic deletion: dropped from the sidebar but
  /// their teardown (worktree/config removal) not yet finished. `AppStore.apply` filters these out of
  /// every incoming CLI `list`, so a stale snapshot taken before the teardown persisted can't
  /// resurrect a just-deleted workroom (the create/delete reload race). Cleared when teardown ends.
  var deletingWorkrooms: Set<TerminalTarget.ID> {
    get { storedDeletingWorkrooms }
    set { storedDeletingWorkrooms = newValue }
  }
  private var storedDeletingWorkrooms: Set<TerminalTarget.ID> = []

  /// Paths of projects with an in-flight Delete Project, the project-level counterpart of
  /// `deletingWorkrooms` (#287). Tearing down a project's remote hosts can take minutes, and a
  /// reload in that window would otherwise republish it with half-destroyed workrooms.
  var deletingProjects: Set<String> {
    get { storedDeletingProjects }
    set { storedDeletingProjects = newValue }
  }
  private var storedDeletingProjects: Set<String> = []

  // MARK: Windows

  /// What a create or delete does to a window, which the window applies to its own selection and
  /// splits.
  enum Event {
    /// The pane is gone: out of the window's split and off its selection. A create's pane takes
    /// the step whose log the window had open with it.
    case targetRemoved(SidebarID)
    /// The first pane is now the second, wherever the window shows it: a create's pane becoming its
    /// workroom's once it has a name, and back again when a failed remote create forgets the name.
    case paneReplaced(SidebarID, with: SidebarID)
    /// The project's `.git` changed: a commit, a fetch, a push or a branch switch in it or in one
    /// of its workrooms.
    case rootBranchChanged(Project.ID)
  }

  private struct Window {
    weak var owner: AnyObject?
    let apply: @MainActor (Event) -> Void
    let stopRuns: @MainActor ([TerminalTarget.ID], @escaping () -> Void) -> Void
    let reap: @MainActor (TerminalTarget.ID) async -> Void
  }

  /// The windows, in the order they registered.
  @ObservationIgnored private var registered: [Window] = []

  /// Hand `owner`'s window every event while it lives (`apply`), and let a delete stop its runs
  /// (`stopRuns`, which calls its completion once they have stopped) and reap its terminals
  /// (`reap`). Idempotent per owner.
  func register(
    _ owner: AnyObject, apply: @escaping @MainActor (Event) -> Void,
    stopRuns: @escaping @MainActor ([TerminalTarget.ID], @escaping () -> Void) -> Void,
    reap: @escaping @MainActor (TerminalTarget.ID) async -> Void
  ) {
    registered.removeAll { $0.owner == nil || $0.owner === owner }
    registered.append(Window(owner: owner, apply: apply, stopRuns: stopRuns, reap: reap))
  }

  private var windows: [Window] { registered.filter { $0.owner != nil } }

  private func send(_ event: Event) {
    for window in windows { window.apply(event) }
  }

  // MARK: Runs

  /// The run whose pane `id` is, while it lasts.
  func creationRun(forTargetID id: TerminalTarget.ID) -> CreationRun? {
    creationRunForTarget[id].flatMap { creationRuns[$0] }
  }

  /// The run whose pane `sid` is, while it lasts.
  func creationRun(for sid: SidebarID) -> CreationRun? {
    sid.targetID.flatMap(creationRun(forTargetID:))
  }

  /// Whether a create is still running in the project, named or not (O1).
  func hasRunningCreation(inProject path: String) -> Bool {
    creationRuns.values.contains { $0.project.path == path && $0.isRunning }
  }

  /// The pane `run` shows in: its provisional one until its name lands, then its workroom's.
  func paneID(of run: CreationRun) -> SidebarID {
    if creationRunForTarget[TargetID.creation(run.id)] != run.id, let name = run.name {
      return .workroom(project: run.project.path, name: name)
    }
    return .creation(project: run.project.path, id: run.id)
  }

  /// Records `run` under its provisional pane.
  func register(_ run: CreationRun) {
    creationRuns[run.id] = run
    creationRunForTarget[TargetID.creation(run.id)] = run.id
  }

  /// Drops `run`, and with it every pane id it held, so its terminal mounts. A `.creation` pane it
  /// leaves in any window goes too. Does nothing for a run another (Try Again) has replaced.
  func discardCreationRun(_ run: CreationRun) {
    guard creationRuns[run.id] === run else { return }
    creationRuns[run.id] = nil
    creationRunForTarget = creationRunForTarget.filter { $0.value != run.id }
    send(.targetRemoved(.creation(project: run.project.path, id: run.id)))
  }

  /// Drops the run whose pane `id` is, if any.
  func discardCreationRun(forTargetID id: TerminalTarget.ID) {
    if let run = creationRun(forTargetID: id) { discardCreationRun(run) }
  }

  /// Try Again: `retry` replaces `run`, in the same pane in every window.
  func replaceCreationRun(_ run: CreationRun, with retry: CreationRun) {
    let pane = paneID(of: run)
    creationRunForTarget = creationRunForTarget.filter { $0.value != run.id }
    register(retry)
    let fresh = SidebarID.creation(project: retry.project.path, id: retry.id)
    if pane != fresh { send(.paneReplaced(pane, with: fresh)) }
  }

  /// The workroom `run` makes has a name: its pane becomes the workroom's in every window, in
  /// place. Its target is recorded BEFORE `publish` lists the workroom, so no window can mount a
  /// terminal into it in between (R3), and it is undeletable until the create's process ends.
  func nameCreationRun(
    _ run: CreationRun, _ name: String, publishing publish: () async -> Void
  ) async {
    let path = run.project.path
    let id = TargetID.workroom(project: path, name: name)
    creatingWorkrooms.insert(id)
    creationRunForTarget[id] = run.id
    run.setName(name)
    await publish()
    send(
      .paneReplaced(
        .creation(project: path, id: run.id), with: .workroom(project: path, name: name)))
    creationRunForTarget[TargetID.creation(run.id)] = nil
  }

  /// O2: a failed remote create's record is gone, so its pane goes back to being the run's in every
  /// window before a reload can prune it, keeping its log and Try Again.
  func returnPaneToRun(_ run: CreationRun, name: String) {
    let path = run.project.path
    let id = TargetID.workroom(project: path, name: name)
    guard creationRunForTarget[id] == run.id else { return }
    creationRunForTarget[TargetID.creation(run.id)] = run.id
    creationRunForTarget[id] = nil
    creatingWorkrooms.remove(id)
    send(
      .paneReplaced(
        .workroom(project: path, name: name), with: .creation(project: path, id: run.id)))
  }

  /// One sidebar row for a create that has no workroom row (R5): before its name lands, or after a
  /// failed remote create dropped its record.
  struct ProvisionalCreationRow: Identifiable {
    let run: CreationRun
    /// "New workroom · <destination>", numbered when two share a destination (design D18).
    let label: String
    var id: SidebarID { .creation(project: run.project.path, id: run.id) }
  }

  /// The provisional rows `path`'s project lists under its workrooms, in the order the creates
  /// started. Selecting a row's `id` shows its pane.
  func provisionalCreationRows(inProject path: String) -> [ProvisionalCreationRow] {
    let runs = creationRuns.values
      .filter { $0.project.path == path && paneID(of: $0) == .creation(project: path, id: $0.id) }
      .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    var seen: [String: Int] = [:]
    return runs.map { run in
      let destination = CreationRun.destination(of: run.kind)
      seen[destination, default: 0] += 1
      let count = seen[destination] ?? 1
      return ProvisionalCreationRow(
        run: run, label: "New workroom · \(destination)" + (count > 1 ? " \(count)" : ""))
    }
  }

  /// Speaks one of a create's three moments (design D17): its provider needing setup, its failure and
  /// its success. Step-by-step progress is never announced. Replaced in tests.
  @ObservationIgnored var announceCreation: (String) -> Void = { message in
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  /// How long a finished create's checklist stays on screen before the workroom's own UI replaces
  /// it, when it closes automatically (design D13). Tests shorten it.
  @ObservationIgnored var creationSuccessHold: Duration = .milliseconds(1500)

  /// Whether a finished create's checklist closes by itself, else it waits for Done. Tests replace it.
  @ObservationIgnored var closesFinishedCreations: () -> Bool = {
    Defaults[.closeCreationPaneWhenDone]
  }

  // MARK: Withholding

  /// Whether the given target's terminal must stay withheld while its workroom is being created
  /// (issue #116): while a run holds it, in every window, from before its workroom is published until
  /// the run ends — success, Open Anyway, Delete or Close (issue #167, #483).
  func isCreationBlocking(_ targetID: TerminalTarget.ID) -> Bool {
    creationRunForTarget[targetID] != nil
  }

  /// Whether a run must NOT be started for this target right now — the single predicate the
  /// chokepoint (`startRunCommand`) and every Run affordance read, so an offered button and a
  /// refused action can never disagree (issue #171). `creatingWorkrooms` clears when the process
  /// ends, while a failed setup script's run outlives it; a run started there would overwrite the
  /// armed auto-run. A create that succeeded and only waits for Done blocks nothing: its workroom is
  /// made, and its auto-run starts then (#483).
  func isRunBlocked(_ targetID: TerminalTarget.ID) -> Bool {
    creatingWorkrooms.contains(targetID)
      || (isCreationBlocking(targetID) && creationRun(forTargetID: targetID)?.outcome != .succeeded)
  }

  /// Whether `workroom` has an in-flight create (its setup is running) — the delete affordances
  /// disable while this holds so it can't be torn down mid-setup (issue #116), from any window.
  func isCreatingWorkroom(_ workroom: Workroom, in project: Project) -> Bool {
    creatingWorkrooms.contains(
      TargetID.workroom(project: project.path, name: workroom.name))
      // A remote create (#253) is in this set from just after its workroom has a name; until then,
      // its run says so. One a crash left at `creating` is deletable.
      || (workroom.host?.lifecycle == .creating && hasRunningCreation(inProject: project.path))
  }

  /// Why no workroom can be created in `project` right now, as the New Workroom menu shows it beside
  /// an entry (#309), or nil when one can. Creates in one project may overlap (#483).
  func createBlockedReason(in project: Project) -> String? {
    deletingProjects.contains(project.path) ? "the project is being deleted" : nil
  }

  /// Whether creating a remote workroom is on for `project`: not while it is being deleted.
  func canCreateRemoteWorkroom(in project: Project) -> Bool {
    !deletingProjects.contains(project.path)
  }

  // MARK: Deletes

  /// `sids` leave every window, and the create run each one's pane belonged to goes (issue #70,
  /// OV #7): another window may have had one open or selected, and "stale-id self-heal" only fixes
  /// model lookup, not live surfaces or processes. A delete's run has ended, and nothing else would
  /// drop it, leaving `isCreationBlocking` true for that project and name, so a regenerated
  /// same-name workroom would mount withheld under a stale checklist (issue #167, #483).
  func removeFromWindows(_ sids: [SidebarID]) {
    for sid in sids {
      send(.targetRemoved(sid))
      if let id = sid.targetID { discardCreationRun(forTargetID: id) }
    }
  }

  /// Gracefully stops `ids`' run commands in every window, then runs `then` once all have stopped
  /// (issue #7/#70), so a teardown never deletes a directory a dev server still holds.
  ///
  /// Every window's store is held until `then` returns, as the delete flows' list of stores once
  /// was: a window closed mid-stop still finishes its stop (its poll holds its controller only
  /// weakly) and is still reaped in `then`, and the teardown still runs.
  func stopRuns(_ ids: [TerminalTarget.ID], then: @escaping @MainActor () async -> Void) {
    let owners = windows.compactMap(\.owner)
    let group = DispatchGroup()
    for window in windows {
      group.enter()
      window.stopRuns(ids) { group.leave() }
    }
    group.notify(queue: .main) {
      Task {
        await then()
        withExtendedLifetime(owners) {}
      }
    }
  }

  /// Reaps `ids`' terminals in every window, one window after the other.
  func reap(_ ids: [TerminalTarget.ID]) async {
    for window in windows {
      for id in ids { await window.reap(id) }
    }
  }

  // MARK: Once a launch

  /// Set once `AppStore.endOrphanedSessionsOnce` has run: it is per process, not per window.
  @ObservationIgnored var sweptOrphanedSessions = false

  @ObservationIgnored private var claimingProvisioned: Task<Void, Never>?
  private static let configLogger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "config")

  /// Once per launch, before a Dev build first lists its projects: takes what it made out of the
  /// config Release and Nightly share, into its own (`WorkroomCLI.configPath`), so they stop
  /// showing its remote workrooms and stop refusing creates over its bases. Never in a test
  /// process, which would move the developer's real entries. A failure is logged and tried again
  /// at the next launch: the move is idempotent.
  func claimProvisionedOnce(
    _ cli: any WorkroomCLIProtocol, bundleID: String? = Bundle.main.bundleIdentifier,
    isTestProcess: Bool = AppEnvironment.current.isTestProcess
  ) async {
    guard !isTestProcess, let bundleID, WorkroomCLI.configPath(bundleID: bundleID) != nil
    else { return }
    let task =
      claimingProvisioned
      ?? Task {
        do {
          try await cli.claimProvisioned(
            from: WorkroomCLI.sharedConfigPath, provisioner: bundleID)
        } catch {
          Self.configLogger.error(
            "claiming this build's remote entries: \(error.localizedDescription, privacy: .public)")
        }
      }
    claimingProvisioned = task
    await task.value
  }

  // MARK: Root branch watch

  /// Live root branch labels: one filesystem watcher per project for the whole app, pointed at its
  /// VCS metadata dir (`.git`). A branch switch in the root terminal updates the sidebar label
  /// immediately, instead of waiting for the throttled on-focus reload, and every window hears of
  /// the change (`Event.rootBranchChanged`) for its History and VCS toolbar. The watch is naturally
  /// quiet — working-tree edits don't touch `.git`, only VCS operations do — and resolution is
  /// read-only + deduped, so it can't loop or churn.
  ///
  /// LOCAL projects only, by design. For a remote clone a worktree's refs live in the same clone as
  /// the workroom, so this watch collapses into each window's workroom watch and there is nothing
  /// separate to port: the local and remote watch layouts differ on purpose (#211). Every project
  /// here is a local one today, so the routing needs no host check yet.
  @ObservationIgnored private var rootBranchWatchers: [Project.ID: HostFileWatcher] = [:]
  /// Per-project re-resolve task (cancel-and-replace) so a burst of metadata writes resolves once.
  @ObservationIgnored private var rootBranchRefreshTasks: [Project.ID: Task<Void, Never>] = [:]
  @ObservationIgnored private let resolver = BranchResolver()

  /// Reconcile the per-project root-branch watchers with the current project list: ensure a watcher
  /// for each project (pointed at its `.git` metadata dir) and tear down watchers for projects
  /// that went away. Called from every window's `apply` so the watch set tracks the live projects.
  /// No-op when the services seed statuses (the fixture's temp-dir paths aren't real repos — match
  /// `AppStore.resolveBranches`, which skips them too).
  func updateRootBranchWatches() {
    guard vcsStatus.probesRepositories else {
      for w in rootBranchWatchers.values { w.stop() }
      rootBranchWatchers.removeAll()
      for t in rootBranchRefreshTasks.values { t.cancel() }
      rootBranchRefreshTasks.removeAll()
      return
    }
    let live = Set(projectStore.projects.map(\.id))
    for id in rootBranchWatchers.keys where !live.contains(id) {
      rootBranchWatchers[id]?.stop()
      rootBranchWatchers[id] = nil
      rootBranchRefreshTasks[id]?.cancel()
      rootBranchRefreshTasks[id] = nil
    }
    for p in projectStore.projects {
      guard let dir = Self.vcsMetadataDir(path: p.path, vcs: p.vcs) else { continue }
      let id = p.id
      let watcher =
        rootBranchWatchers[id]
        ?? HostFileWatcher { [weak self] _, _ in self?.rootBranchDidChange(projectID: id) }
      rootBranchWatchers[id] = watcher
      watcher.start(path: dir)
    }
  }

  /// The VCS metadata directory whose changes signal a root branch move: `.git` for git. Watching
  /// this — not the project root — keeps the watch quiet (working-tree edits don't touch it; only VCS
  /// operations do). nil for an unknown vcs. `nonisolated` (pure) so it's directly unit-testable.
  nonisolated static func vcsMetadataDir(path: String, vcs: String) -> String? {
    vcs == "git" ? (path as NSString).appendingPathComponent(".git") : nil
  }

  /// A change under a project's VCS metadata dir: every window hears of it first (its History and VCS
  /// toolbar repaint whatever the label does: a normal commit usually leaves it unchanged), then
  /// the root branch is re-resolved, writing the label only if it actually changed (so VCS-internal
  /// churn that leaves the branch unchanged doesn't invalidate the sidebar). Cancel-and-replace per
  /// project so a write burst resolves once; `.none` never clobbers a prior label (matches
  /// `AppStore.resolveBranches`).
  func rootBranchDidChange(projectID: Project.ID) {
    guard vcsStatus.probesRepositories,
      let p = projectStore.projects.first(where: { $0.id == projectID })
    else { return }
    send(.rootBranchChanged(projectID))
    let resolver = self.resolver
    rootBranchRefreshTasks[projectID]?.cancel()
    rootBranchRefreshTasks[projectID] = Task { [weak self] in
      let ref = await resolver.resolve(path: p.path, vcs: p.vcs)
      guard let self, !Task.isCancelled else { return }
      // Keep the prior label; an unchanged one is not written, so the store does not churn.
      if ref.kind == .none, self.vcsStatus.rootRefs[projectID] != nil { return }
      if self.vcsStatus.rootRefs[projectID] == ref { return }
      self.vcsStatus.rootRefs[projectID] = ref
    }
  }
}

/// The window a create or delete was asked from, as the lifecycle's flows reach it: only what they
/// need of that one window. What every window shares (the projects, their status, the creates and
/// deletes in flight) they read on the lifecycle itself. A window's `AppStore` is one.
@MainActor
protocol LifecycleWindow: AnyObject, Sendable {
  /// Its CLI, which every create and delete runs through, its remote create services and its Bin.
  var services: AppServices { get }
  /// Where its questions, sheets and alerts go.
  var modals: ModalState { get }
  var selectedTargetID: SidebarID? { get }
  func present(_ error: Error)
  /// Lists the projects afresh and reconciles this window with them.
  func reload() async
  func load(warnings: String, surfaceErrors: Bool) async
  /// Opens a new create's pane before it does any work (AC 1): beside `anchor`, or as the selection.
  func openCreationPane(_ pane: SidebarID, in project: Project, beside anchor: SidebarID?)
  /// Takes a create's pane out of this window: a split collapses to its sibling, a pane on its own
  /// gives way to `previous` if that still exists.
  func closeCreationPane(_ pane: SidebarID, returningTo previous: SidebarID?)
  /// Its runs: a new workroom's auto-run is armed and disarmed here (issue #7).
  var runCommand: RunCommandController { get }
  func armAutoRunIfConfigured(_ id: TerminalTarget.ID, in project: Project)
  func target(for sid: SidebarID) -> TerminalTarget?
  func ensureInitialTerminal(for target: TerminalTarget)
  func sidebarID(for id: TargetID) -> SidebarID?
  func refreshLocalStatus(for sid: SidebarID)
  func scheduleSelectedStatusRefresh()
  func noticeStaleStart(of id: TerminalTarget.ID, _ warning: String)
  func removeWorkroomLocally(_ workroom: Workroom, in project: Project)
  @discardableResult func removeProjectLocally(_ project: Project) -> [TerminalTarget.ID]
  func reselectAfterWorkroomDetached(wasSelectedHere: Bool)
}
