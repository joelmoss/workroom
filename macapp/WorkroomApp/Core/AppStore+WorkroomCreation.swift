import AppKit
import HostDrivers
import WorkroomDomain

/// Workroom creation (issues #116, #163, #167, #483): local and remote creates, each a
/// `CreationRun` whose pane opens on the click and shows its checklist until the workroom's own UI
/// takes over. The runs live on `ProjectStore` (`creationRuns`, `creationRunForTarget`), shared by
/// every window; each window places a run's pane in its own selection or split.
///
/// A run's pane is `.creation(project:id:)` until the workroom has a name, then the workroom's own
/// `.workroom(project:name:)`, swapped in place. While the run lasts, that target's terminal stays
/// withheld in every window (`isCreationBlocking`).
extension AppStore {
  // MARK: Runs

  /// The run whose pane `id` is, while it lasts.
  func creationRun(forTargetID id: TerminalTarget.ID) -> CreationRun? {
    creationRunForTarget[id].flatMap { creationRuns[$0] }
  }

  /// The run whose pane `sid` is, while it lasts.
  func creationRun(for sid: SidebarID) -> CreationRun? {
    Self.targetIDString(for: sid).flatMap(creationRun(forTargetID:))
  }

  /// Whether a create is still running in the project, named or not (O1).
  func hasRunningCreation(inProject path: String) -> Bool {
    creationRuns.values.contains { $0.project.path == path && $0.isRunning }
  }

  /// The pane `run` shows in: its provisional one until its name lands, then its workroom's.
  func paneID(of run: CreationRun) -> SidebarID {
    if creationRunForTarget[TerminalTarget.creationID(run.id)] != run.id, let name = run.name {
      return .workroom(project: run.project.path, name: name)
    }
    return .creation(project: run.project.path, id: run.id)
  }

  /// Records `run` under its provisional pane.
  func register(_ run: CreationRun) {
    creationRuns[run.id] = run
    creationRunForTarget[TerminalTarget.creationID(run.id)] = run.id
  }

  /// Drops `run`, and with it every pane id it held, so its terminal mounts. A `.creation` pane it
  /// leaves in any window goes too. Does nothing for a run another (Try Again) has replaced.
  func discardCreationRun(_ run: CreationRun) {
    guard creationRuns[run.id] === run else { return }
    let pane = SidebarID.creation(project: run.project.path, id: run.id)
    creationRuns[run.id] = nil
    creationRunForTarget = creationRunForTarget.filter { $0.value != run.id }
    for store in affectedStores {
      store.expandedCreationLogs[run.id] = nil
      store.removeWorkroomSplitMember(pane)
      if store.selectedTargetID == pane { store.selectedTargetID = nil }
    }
  }

  /// Drops the run whose pane `id` is, if any.
  func discardCreationRun(forTargetID id: TerminalTarget.ID) {
    if let run = creationRun(forTargetID: id) { discardCreationRun(run) }
  }

  /// Puts `new` wherever `old` is in this window: the selection, or its split member.
  func replacePane(_ old: SidebarID, with new: SidebarID) {
    if selectedTargetID == old { withHistorySuppressed { selectedTargetID = new } }
    workroomSplits = workroomSplits.map { $0.contains(old) ? $0.replacingLeaf(old, with: new) : $0 }
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
      let destination = run.kind.destination
      seen[destination, default: 0] += 1
      let count = seen[destination] ?? 1
      return ProvisionalCreationRow(
        run: run, label: "New workroom · \(destination)" + (count > 1 ? " \(count)" : ""))
    }
  }

  /// Places a new run's pane before the create does any work (AC 1): beside `splitAnchor`, or as
  /// the selection.
  private func startCreationRun(
    project: Project, kind: CreationKind, splitAnchor: SidebarID?
  ) -> CreationRun {
    let run = CreationRun(
      project: project, kind: kind, splitAnchor: splitAnchor, previousSelection: selectedTargetID,
      hasSetupScript: Self.hasSetupScript(project),
      hasIncludeFile: Self.hasIncludeFile(project))
    register(run)
    selectedProjectID = project.id
    let pane = SidebarID.creation(project: project.path, id: run.id)
    let landedInSplit =
      splitAnchor.map {
        insertWorkroomSplit(
          pane, beside: $0, edge: .right, destinationRect: workroomPaneRect(for: $0))
      } ?? false
    if !landedInSplit { selectedTargetID = pane }
    return run
  }

  /// Whether a create of any kind will run a setup script, as the CLI's `findScript` falls back to
  /// the project's own `scripts/workroom_setup` (and a remote create copies that one to its host).
  /// One only the new checkout has puts its row back when it runs (`CreationRun.begin`).
  private static func hasSetupScript(_ project: Project) -> Bool {
    FileManager.default.fileExists(atPath: project.path + "/scripts/workroom_setup")
  }

  /// Whether the root has an include file (#367), so any kind of create copies its included files:
  /// only the root's copy counts, as the CLI's `IncludedFiles` reads it.
  static func hasIncludeFile(_ project: Project) -> Bool {
    FileManager.default.fileExists(atPath: project.path + "/.worktreeinclude")
  }

  /// The workroom `run` makes has a name: its pane becomes the workroom's, in place. Its target is
  /// recorded BEFORE the reload publishes the workroom, so no window can mount a terminal into it in
  /// between (R3), and it is undeletable until the create's process ends.
  private func nameCreationRun(_ run: CreationRun, _ name: String) async {
    let path = run.project.path
    let id = TerminalTarget.workroomID(project: path, name: name)
    creatingWorkrooms.insert(id)
    creationRunForTarget[id] = run.id
    run.setName(name)
    await reload()
    let pane = SidebarID.creation(project: path, id: run.id)
    for store in affectedStores {
      store.replacePane(pane, with: .workroom(project: path, name: name))
    }
    creationRunForTarget[TerminalTarget.creationID(run.id)] = nil
  }

  /// The create's process ended: its workroom can be deleted and probed again (issue #116).
  private func releaseCreatingWorkroom(_ id: TerminalTarget.ID) {
    creatingWorkrooms.remove(id)
    if let sid = Self.sidebarID(forTargetID: id, in: projects) { refreshLocalStatus(for: sid) }
    scheduleSelectedStatusRefresh()
  }

  /// A finished create: its checklist stays, with Done, until the user closes it (`finishCreation`),
  /// or with "Close automatically when done" on, for `creationSuccessHold` (design D13). Then the
  /// workroom's terminal mounts. An armed auto-run (issue #7) doesn't wait for that: it starts now,
  /// backgrounded beside the shell the terminal will open on (owner).
  private func completeCreationRun(_ run: CreationRun) async {
    run.succeed()
    if let name = run.name {
      Self.announceCreation(CreationPanePresentation.successAnnouncement(name: name))
      let id = TerminalTarget.workroomID(project: run.project.path, name: name)
      if case .armed = runStates[id],
        let target = target(for: .workroom(project: run.project.path, name: name))
      {
        ensureInitialTerminal(for: target)
      }
    }
    guard closesFinishedCreations() else { return }
    try? await Task.sleep(for: creationSuccessHold)
    // Unticked in the footer meanwhile: it waits for Done after all.
    if closesFinishedCreations() { finishCreation(run) }
  }

  /// Done on a finished create: the checklist goes and the workroom's terminal mounts.
  func finishCreation(_ run: CreationRun) {
    discardCreationRun(run)
  }

  /// The create failed: its pane shows which step and what to do next, and VoiceOver hears it once
  /// (design D17), from here rather than from each window that shows the pane.
  private func failCreationRun(_ run: CreationRun, _ outcome: CreationOutcome) {
    run.fail(outcome)
    Self.announceCreation(CreationPanePresentation.failureAnnouncement(for: run))
  }

  /// Speaks one of a create's three moments (design D17): its provider needing setup, its failure and
  /// its success. Step-by-step progress is never announced. Replaced in tests.
  static var announceCreation: (String) -> Void = { message in
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  /// The setup script needs approving before anything is made (#363): its row waits, the pane
  /// shows the script with Approve, and VoiceOver hears it once. `startCommit` is the start point it
  /// was asked at, which the answer continues from.
  private func refuseCreation(
    _ run: CreationRun, _ script: ScriptTrust, at startCommit: String? = nil
  ) {
    run.awaitApproval(of: script, at: startCommit)
    Self.announceCreation("\(script.displayFile) needs approving")
    presentSetupApproval(run)
  }

  /// The main checkout has work the create would leave out, before anything is made: the worktree's
  /// row waits, the user is asked where it starts, and VoiceOver hears it once.
  private func refuseCreation(_ run: CreationRun, leaving work: LocalWork, at startCommit: String?)
  {
    run.awaitStartChoice(for: work, at: startCommit)
    Self.announceCreation("\(work.summary). Choose whether the new workroom includes it")
    presentStartChoice(run)
  }

  // MARK: Failure actions

  /// Where a create starts, asked when it found local work: opened when the create stops, and again
  /// by the pane's Choose Start….
  func presentStartChoice(_ run: CreationRun) {
    guard creationRuns[run.id] === run, case .localWorkFound(let work) = run.outcome else { return }
    pendingStartChoice = PendingStartChoice(run: run, work: work)
  }

  /// A start chosen for a create that found local work: it continues, in the same pane, from the
  /// start point it was asked at. A choice left over from a run since replaced does nothing.
  func chooseStart(_ start: CreationStart, for run: CreationRun) async {
    guard creationRuns[run.id] === run, case .localWorkFound = run.outcome else { return }
    await retryCreation(run, start: start, startCommit: run.askedAt)
  }

  /// Cancel Creation on the start choice; stale, it cancels nothing.
  func cancelStartChoice(_ run: CreationRun) {
    guard creationRuns[run.id] === run, case .localWorkFound = run.outcome else { return }
    closeCreation(run)
  }

  /// The setup script's approval sheet, the teardown's (`presentTeardownFailure`) for a create: the
  /// script to read, Continue Without Script… (confirmed), Cancel Creation, and Approve. Opened when
  /// the create stops, and again by the pane's Review Script….
  func presentSetupApproval(_ run: CreationRun) {
    guard creationRuns[run.id] === run, case .scriptNotTrusted(let script) = run.outcome else {
      return
    }
    // The message first: setting it clears what the rest set.
    errorMessage = CreationPanePresentation.setupApprovalMessage(for: run, script: script)
    errorTitle = script.isDevContainer ? "Approve the dev container?" : "Approve the setup script?"
    errorLog = script.visibleText
    errorScriptName = script.name
    let confirmation = CreationPanePresentation.skipConfirmation(for: script)
    errorAction = ErrorAction(
      label: "\(confirmation.button)…", destructive: false, confirmation: confirmation
    ) { [weak self] in Task { await self?.skipSetupScript(run) } }
    // A stale sheet (the run approved or replaced since) cancels nothing.
    errorCancel = ErrorAction(label: "Cancel Creation") { [weak self] in
      guard let self, self.creationRuns[run.id] === run else { return }
      self.closeCreation(run)
    }
    errorApproval = ErrorAction(label: "Approve") { [weak self] in
      Task { await self?.approveSetupScript(run) }
    }
  }

  /// Approve on a create its setup script stopped: the bytes shown are recorded as approved and the
  /// create continues, in the same pane, from the start point the script was judged at.
  func approveSetupScript(_ run: CreationRun) async {
    guard creationRuns[run.id] === run, case .scriptNotTrusted(let script) = run.outcome else {
      return
    }
    do {
      try await cli.trustScript(script.name, text: script.approvalBytes, project: run.project.path)
    } catch {
      failCreationRun(run, .failedBeforeWorkroom(message: errorText(error)))
      return
    }
    await retryCreation(run, startCommit: run.askedAt)
  }

  /// Continue Without Script, once confirmed, on a create its setup script stopped: the create
  /// continues, in the same pane, without that script. For a devcontainer.json it is Continue With
  /// Default Image: the container create continues without the file. Nothing is approved, so the
  /// next create asks again.
  func skipSetupScript(_ run: CreationRun) async {
    guard creationRuns[run.id] === run, case .scriptNotTrusted(let script) = run.outcome else {
      return
    }
    if script.isDevContainer {
      await retryCreation(run, skipsDevContainer: true, startCommit: run.askedAt)
    } else {
      await retryCreation(run, skipsSetup: true, startCommit: run.askedAt)
    }
  }

  /// The setup script row's reason on a create that skipped it, as the CLI words it.
  nonisolated static let setupSkippedReason = "Skipped without approval"

  /// Close on a failed create, or Cancel on its provider setup: the pane goes. A split collapses to
  /// its sibling; a pane on its own gives way to what was selected before, if it still exists.
  func closeCreation(_ run: CreationRun) {
    let pane = paneID(of: run)
    if workroomSplit(containing: pane) != nil {
      removeWorkroomSplitMember(pane)
    } else if selectedTargetID == pane {
      selectedTargetID = run.previousSelection.flatMap { target(for: $0) == nil ? nil : $0 }
    }
    discardCreationRun(run)
  }

  /// Open Anyway on a failed setup script: the workroom's terminal mounts, auto-run left disarmed.
  func openCreatedWorkroomAnyway(_ run: CreationRun) {
    discardCreationRun(run)
  }

  /// Try Again: the same request again, in the same pane, as a new run that replaces `run`. The base
  /// branch is read afresh, as a new create does. It skips the setup script and starts where `run`
  /// did, unless `skipsSetup` or `start` says otherwise. An answer to `run`'s create question passes
  /// `startCommit`, the start point it was asked at: the new run continues from there, fetching
  /// nothing, and keeps `run`'s fetch row (ADR 0059).
  func retryCreation(
    _ run: CreationRun, skipsSetup: Bool? = nil, skipsDevContainer: Bool? = nil,
    start: CreationStart? = nil, startCommit: String? = nil
  ) async {
    // A second click before the pane redraws must not start a second create (or paid machine).
    guard creationRuns[run.id] === run else { return }
    let project = projects.first { $0.path == run.project.path } ?? run.project
    let start = start ?? run.start
    let retry = CreationRun(
      id: run.id, project: project, kind: run.kind, splitAnchor: run.splitAnchor,
      previousSelection: run.previousSelection,
      hasSetupScript: Self.hasSetupScript(project),
      hasIncludeFile: Self.hasIncludeFile(project), skipsSetup: skipsSetup ?? run.skipsSetup,
      skipsDevContainer: skipsDevContainer ?? run.skipsDevContainer, start: start,
      startCommit: startCommit, carriedFetch: startCommit == nil ? nil : run.fetchStep)
    let pane = paneID(of: run)
    creationRunForTarget = creationRunForTarget.filter { $0.value != run.id }
    register(retry)
    let fresh = SidebarID.creation(project: project.path, id: run.id)
    if pane != fresh { for store in affectedStores { store.replacePane(pane, with: fresh) } }
    switch run.kind {
    case .local: await runLocalCreate(retry)
    case .container(let runtime): await runRemoteCreate(retry, place: .container(runtime))
    case .boxd: await runRemoteCreate(retry, place: .boxd)
    case .exeDev: await runRemoteCreate(retry, place: .exeDev)
    }
  }

  // MARK: Local

  /// `splitAnchor` (issue #163) opens the new workroom BESIDE that one instead of replacing it —
  /// ⌥⌘N and ⌥⏎ in the New picker pass the selection as it stood when the project was picked.
  /// Its pane opens on the click (#483) and shows the create's checklist until it succeeds.
  func createWorkroom(in project: Project, splitAnchor: SidebarID? = nil) async {
    // A picker opened before Delete Project still holds the project (#287).
    guard !deletingProjects.contains(project.path) else {
      errorTitle = "Can't create a workroom in \(project.displayName)"
      errorMessage = "\(project.displayName) is being deleted."
      return
    }
    await runLocalCreate(
      startCreationRun(project: project, kind: .local, splitAnchor: splitAnchor))
  }

  private func runLocalCreate(_ run: CreationRun) async {
    let warning = CreationWarningBox()
    // An answer's create fetches nothing, so the try it answers is what said its start may be stale;
    // the create's own warning, when it has one, says it anew.
    warning.value = run.carriedFetchWarning
    guard let landedID = await performLocalCreate(run, warning: warning) else { return }
    await completeCreationRun(run)
    if let text = warning.value, !text.isEmpty { noticeStaleStart(of: landedID, text) }
  }

  /// Runs the CLI's create into `run`. The workroom's id when it succeeded, else nil with `run`
  /// failed. Its deletion protection is released here, when the process ends (F7).
  private func performLocalCreate(_ run: CreationRun, warning: CreationWarningBox) async
    -> TerminalTarget.ID?
  {
    let project = run.project
    // The landing runs on the main actor and `await reload()`s, so it can still be in flight when
    // `cli.create` returns: hold its task and await it rather than race it (issue #167).
    let landing = CreationLandingBox()
    defer {
      landing.close()
      if let id = landing.landedID { releaseCreatingWorkroom(id) }
    }
    do {
      let created = try await cli.create(
        project: project.path, skipSetup: run.skipsSetup, start: run.cliStart,
        startCommit: run.startCommit
      ) { event in
        if event.type == "created", let name = event.name {
          if let text = event.warning, !text.isEmpty { warning.value = text }
          // Registered synchronously, so it is there to await when `create` returns.
          landing.set(
            Task { @MainActor in
              await self.landOnCreatedWorkroom(
                name: name, run: run, setup: event.setup ?? false, landing: landing)
            })
        } else {
          // One queue for every event, so a line is never filed after the next step began.
          DispatchQueue.main.async { MainActor.assumeIsolated { run.apply(event) } }
        }
      }
      await landing.finish()
      await Self.drainMainQueue()
      // Land now if the "created" event never arrived (a fake CLI).
      if landing.landedID == nil {
        await landOnCreatedWorkroom(name: created.name, run: run, setup: false, landing: landing)
      } else {
        await reload()  // reflect the finished setup script's tree
      }
      if let text = created.warning { warning.value = warning.value ?? text }
      return landing.landedID
    } catch {
      await landing.finish()
      await Self.drainMainQueue()
      // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
      await reload()
      if let id = landing.landedID {
        // The workroom exists but setup failed. Disarm the auto-run armed at the landing so Open
        // Anyway doesn't launch the command against a half-set-up tree (issue #7).
        if case .armed = runStates[id] { runStates[id] = nil }
        failCreationRun(run, .setupScriptFailed(message: errorText(error)))
        // Offline, the fetch and a networked setup script fail together: say both.
        if let text = warning.value { noticeStaleStart(of: id, text) }
      } else if let script = WorkroomCLIError.untrustedScript(error) {
        refuseCreation(run, script, at: WorkroomCLIError.startCommit(error))
      } else if let work = WorkroomCLIError.leftOutWork(error) {
        refuseCreation(run, leaving: work, at: WorkroomCLIError.startCommit(error))
      } else if run.startCommit != nil, WorkroomCLIError.isUnusableStartCommit(error) {
        // The start point the answer was about is gone (the base branch changed in between): start
        // over, fetching afresh, and ask again if need be.
        await retryCreation(run)
      } else {
        failCreationRun(run, .failedBeforeWorkroom(message: errorText(error)))
      }
      return nil
    }
  }

  /// Lands on a just-created workroom once it exists (issue #116): its pane becomes the workroom's
  /// and auto-run is armed for its first terminal. Idempotent via `landing.claim`: the "created"
  /// event and the fallback can both call it, and only the first lands.
  // `internal` (not `private`) only so `@testable` can drive the closed-box bail path directly.
  func landOnCreatedWorkroom(
    name: String, run: CreationRun, setup: Bool, landing: CreationLandingBox
  ) async {
    // Claim BEFORE recording anything: a create that has already finished (its box closed) must not
    // insert a guard nobody is left to remove (issue #167, defect 1).
    let id = TerminalTarget.workroomID(project: run.project.path, name: name)
    guard landing.claim(id) else { return }
    await nameCreationRun(run, name)
    armAutoRunIfConfigured(id, in: run.project)
  }

  /// Arm auto-run so the workroom's first terminal runs the project command as tab #1 (issue #7).
  /// It fires when the pane mounts, which is once the create is over. A remote create arms it at
  /// the same point, once its workroom has a name (#522): its run runs on its host.
  func armAutoRunIfConfigured(_ id: TerminalTarget.ID, in project: Project) {
    let cfg = runConfig(forProject: project.path)
    if cfg.autoRun, cfg.hasCommand { armAutoRun(forWorkroom: id) }
  }

  /// Waits until every block already queued on the main queue has run: the CLI's events hop there.
  private static func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  // MARK: Remote

  /// Writes what the remote create and delete sequences record to `path`'s config, through the CLI.
  func remoteRecorder(project path: String) -> RemoteWorkrooms.Recorder {
    let cli = self.cli
    return RemoteWorkrooms.Recorder(
      reserve: { hostPath, descriptor in
        try await cli.createRemote(
          project: path, hostPath: hostPath, descriptor: try JSONEncoder().encode(descriptor)
        ).name
      },
      record: { workroom, descriptor in
        try await cli.setHost(
          project: path, workroom: workroom, descriptor: try JSONEncoder().encode(descriptor))
      },
      forget: { workroom in
        // A destroyed host is the one remote workroom the CLI deletes: there is nothing to take
        // down.
        try await cli.setHost(
          project: path, workroom: workroom,
          descriptor: try JSONEncoder().encode(HostDescriptor(state: "destroyed")))
        try await cli.delete(name: workroom, project: path, onLog: nil)
      })
  }

  /// One row's create progress, as `CreateStepCircle` shows it: complete steps (done, warning and
  /// skipped) over all of them, and the step it is on.
  struct CreateStep: Equatable {
    let fraction: Double
    let label: String
    /// The create failed: its row shows the failed mark instead (5a).
    var failed = false
  }

  /// The progress of the create whose pane `sid` is, or nil when it has none.
  func createStep(for sid: SidebarID) -> CreateStep? {
    creationRun(for: sid).map(CreateStep.init)
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

  /// Creates a remote workroom for `project` at `place` (#253, #309, #356): a container on this Mac,
  /// or a boxd machine or exe.dev VM, each with its own clone. Its pane opens on the click (#483),
  /// beside `splitAnchor` when there is one, and becomes the workroom's once it has a name.
  func createRemoteWorkroom(
    in project: Project, place: RemoteWorkrooms.Place = .container(.docker),
    splitAnchor: SidebarID? = nil
  ) async {
    // As it is now, not as a menu or the picker caught it: its base branch may have changed.
    let project = projects.first { $0.path == project.path } ?? project
    guard canCreateRemoteWorkroom(in: project) else { return }
    await runRemoteCreate(
      startCreationRun(project: project, kind: CreationKind(place), splitAnchor: splitAnchor),
      place: place)
  }

  private func runRemoteCreate(_ run: CreationRun, place: RemoteWorkrooms.Place) async {
    let path = run.project.path
    let services = remoteCreateServices
    var defaultNotUsed: String?
    do {
      run.begin("repository")
      let plan = try await services.plan(self, run.project)
      defaultNotUsed = plan.defaultNotUsed
      // Before any machine is made, so a script this Mac won't run never costs a paid host (#363).
      // A container create judges its devcontainer.json the same way (#308, eng review D4), unless
      // it goes on the default image. A create needing neither judged isn't stopped when that can't
      // be told; it then only goes without the local-work notice.
      let judgesDevContainer: Bool
      if case .container = place {
        judgesDevContainer = !run.skipsDevContainer
      } else {
        judgesDevContainer = false
      }
      let status =
        run.skipsSetup && !judgesDevContainer
        ? (try? await services.trustStatus(self, run.project, plan, false))
          ?? TrustStatus(trusted: true, scripts: [])
        : try await services.trustStatus(self, run.project, plan, judgesDevContainer)
      // The file that decides the image first: it is what the create reads first.
      if judgesDevContainer, let config = status.scripts.first(where: { $0.isDevContainer }),
        !config.trusted
      {
        refuseCreation(run, config)
        return
      }
      if !run.skipsSetup,
        let script = status.scripts.first(where: {
          $0.name == RemoteProvisioning.Script.setup.fileName && !$0.trusted
        })
      {
        refuseCreation(run, script)
        return
      }
      // A remote host clones from GitHub, so local work can't come along: it is only said.
      let leftOut = status.localWork.map {
        "\($0.summary). Remote workrooms can only start from what you've pushed, so this one "
          + "doesn't include that work."
      }
      // After the project's own checks, so nobody signs up or picks a plan for a project the
      // provider can't take.
      if run.steps.contains(where: { $0.id == "account" }) {
        run.begin("account")
        if let setup = await services.setupNeeded(place) {
          guard await waitForRemoteSetup(run, place: place, setup: setup) else {
            run.cancel()
            closeCreation(run)
            return
          }
          run.begin("account")
        }
      }
      let host = try await services.host(place)
      let created = try await provisionRemote(run, plan: plan, host: host)
      await Self.drainMainQueue()  // the last step's lines, before it is marked done
      if run.steps.contains(where: { $0.id == ProvisioningProgress.Step.include.rawValue }) {
        await copyIncluded(run, into: created.instance, driver: host.driver)
      }
      // Its panes attach through their own ssh; Changes and the rest connect for themselves.
      await created.instance.connection.close()
      // Before the setup script: the reload adopts the host, which marks a relayed one so the
      // script's connect puts git's credentials up for it.
      await reload()
      let id = TerminalTarget.workroomID(project: path, name: created.name)
      // Still undeletable while the script runs, as a local create's workroom is (issue #116).
      var setupFailure: String?
      if run.skipsSetup {
        run.begin("script")
        run.finish("script", as: .skipped(reason: Self.setupSkippedReason))
      } else {
        setupFailure = await runRemoteSetup(run, created: created, host: host, services: services)
      }
      releaseCreatingWorkroom(id)
      if let setupFailure {
        // As a local create's: the workroom and its host stay, for Open Anyway or Delete, and the
        // auto-run armed at the reserve is disarmed, so Open Anyway doesn't start the command
        // against a half-set-up tree (issue #7).
        if case .armed = runStates[id] { runStates[id] = nil }
        failCreationRun(run, .setupScriptFailed(message: setupFailure))
      } else {
        await completeCreationRun(run)
      }
      let notices = [
        defaultNotUsed.map {
          "The default base branch \($0) can't be used on a remote machine here, so the workroom "
            + "starts from origin's default branch."
        },
        leftOut,
      ].compactMap { $0 }
      if !notices.isEmpty { noticeStaleStart(of: id, notices.joined(separator: " ")) }
    } catch {
      // A record the rollback forgot has already given its pane back (`provisionRemote`'s
      // `forget`); one still naming a live machine keeps its workroom pane, for Delete.
      var leftBehind = false
      if case RemoteProvisioning.Failure.rollbackIncomplete = error { leftBehind = true }
      await Self.drainMainQueue()  // the failing step's lines and its start
      await reload()
      failCreationRun(run, .remoteFailed(message: errorText(error), leftBehind: leftBehind))
      if let name = run.name {
        let id = TerminalTarget.workroomID(project: path, name: name)
        if case .armed = runStates[id] { runStates[id] = nil }  // as above
        releaseCreatingWorkroom(id)
      }
    }
  }

  /// The machine, clone and checkout of a remote create, reporting each step and its log into
  /// `run`. The workroom's name, once reserved, becomes its pane's; a rollback that forgets it gives
  /// the pane back to the run (O2) before anything reloads.
  private func provisionRemote(
    _ run: CreationRun, plan: RemoteCreatePlan, host: RemoteCreateHost
  ) async throws -> RemoteWorkrooms.Created {
    let path = run.project.path
    // One queue for steps, lines and the pull, so a line is never filed after the next step began.
    let onMain: @Sendable (@escaping @MainActor () -> Void) -> Void = { body in
      DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
    let stepped: @Sendable (ProvisioningProgress.Step) -> Void = { step in
      onMain { run.begin(step.rawValue) }
    }
    let logged: @Sendable (ProvisioningProgress.Step, String) -> Void = { step, line in
      onMain { run.append(line, to: step.rawValue) }
    }
    // Set once the driver reports a pull: still nil after `ensureHostImage`, the image was here.
    let pulled = CreationWarningBox()
    let report: @Sendable (Double?) -> Void = { fraction in
      pulled.value = "pulled"
      onMain { run.pullFraction = fraction }
    }
    var recorder = remoteRecorder(project: path)
    let reserve = recorder.reserve
    recorder.reserve = { [weak self] hostPath, descriptor in
      let name = try await reserve(hostPath, descriptor)
      await self?.nameCreationRun(run, name)
      await self?.armAutoRunIfConfigured(
        TerminalTarget.workroomID(project: path, name: name), in: run.project)
      return name
    }
    let forget = recorder.forget
    recorder.forget = { [weak self] name in
      try await forget(name)
      await self?.returnPaneToRun(run, name: name)
    }
    // The Mac's token (a container's) is part of checking the repository: had while `repository`
    // runs, so a signed-out gh fails that row, before an image pull that can take minutes.
    var environment = host.environment
    if let gitHubToken = environment.gitHubToken {
      let token = try await gitHubToken()
      environment.gitHubToken = { token }
    }
    let container = host.driver as? ContainerHostDriver
    if container != nil { run.begin("image") }
    return try await ProvisioningProgress.$reportStep.withValue(stepped) {
      try await ProvisioningProgress.$log.withValue(logged) {
        try await ContainerHostDriver.$pullProgress.withValue(report) {
          if let container {
            try await container.ensureHostImage()
            await Self.drainMainQueue()
            await MainActor.run {
              if pulled.value == nil {
                run.finish("image", as: .skipped(reason: "Image already downloaded"))
              }
              run.pullFraction = nil
            }
          }
          return try await RemoteWorkrooms.create(
            repository: plan.repository, cloneURL: plan.cloneURL, startBranch: plan.startBranch,
            key: host.key, driver: host.driver, environment: environment, recorder: recorder)
        }
      }
    }
  }

  /// A remote create's "Run setup script" step: the project's setup script on the new host, as a
  /// local create's CLI runs one. nil when it passed or there is none; otherwise why it failed,
  /// worded as the CLI's ("setup script failed: ...").
  private func runRemoteSetup(
    _ run: CreationRun, created: RemoteWorkrooms.Created, host: RemoteCreateHost,
    services: RemoteCreateServices
  ) async -> String? {
    let step = "script"
    // One queue for the start and the lines, so a line is never filed before its row began.
    let onMain: @Sendable (@escaping @MainActor () -> Void) -> Void = { body in
      DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
    let request = RemoteWorkrooms.ScriptRequest(
      script: .setup, workroom: created.name, path: created.instance.path,
      host: created.instance.host, key: host.key, driver: host.driver,
      daemonBinary: host.environment.daemonBinary,
      rootScript: URL(fileURLWithPath: run.project.path + "/scripts/workroom_setup"),
      judge: Self.judge(.setup, in: run.project.path, cli: cli),
      onStart: { onMain { run.begin(step) } },
      onLine: { line in onMain { run.append(line, to: step) } })
    let result = await services.script(request)
    await Self.drainMainQueue()  // the script's last lines, before its row ends
    switch result {
    case .absent, .passed: return nil
    case .failed(let why):
      // A failure before the script started (the connect, its check, the root's copy) is still
      // the script's row's, not the checkout's still running before it.
      run.begin(step)
      return why
    case .notTrusted(let script):
      // The check before the machine passed, so the host's checkout holds other bytes than the
      // ones approved: a base that moved since, perhaps.
      run.begin(step)
      return "setup script failed: scripts/\(script.name) on the host is not the one approved on "
        + "this Mac, so it did not run"
    }
  }

  /// A remote workroom's `script` judged by the CLI against `project`'s approvals (#363).
  nonisolated static func judge(
    _ script: RemoteProvisioning.Script, in project: String, cli: any WorkroomCLIProtocol
  ) -> RemoteProvisioning.ScriptJudge {
    { text in try await cli.judgeScript(script.fileName, text: text, project: project) }
  }

  /// A remote create's "Copy local files" step (#367): the root's included files, into the host's
  /// checkout once it is out. It never fails the create: the step ends as a warning instead.
  private func copyIncluded(
    _ run: CreationRun, into instance: RemoteProvisioning.Instance, driver: any HostDriver
  ) async {
    let step = ProvisioningProgress.Step.include.rawValue
    let cli = self.cli
    let path = run.project.path
    run.begin(step)
    let result = await RemoteProvisioning.copyIncluded(
      into: instance.path, on: instance.host, driver: driver
    ) { file in try await cli.includeArchive(project: path, output: file.path) }
    switch result {
    case .copied(let log):
      for line in log { run.append(line, to: step) }
      run.finish(step, as: .done)
    case .skipped(let reason, let log):
      for line in log { run.append(line, to: step) }
      run.finish(step, as: .skipped(reason: reason))
    case .warning(let text, let log):
      for line in log { run.append(line, to: step) }
      run.warn(step, text)
    }
  }

  /// O2: a failed remote create's record is gone, so its pane goes back to being the run's in every
  /// window before a reload can prune it, keeping its log and Try Again.
  private func returnPaneToRun(_ run: CreationRun, name: String) {
    let path = run.project.path
    let id = TerminalTarget.workroomID(project: path, name: name)
    guard creationRunForTarget[id] == run.id else { return }
    creationRunForTarget[TerminalTarget.creationID(run.id)] = run.id
    creationRunForTarget[id] = nil
    creatingWorkrooms.remove(id)
    for store in affectedStores {
      store.replacePane(
        .workroom(project: path, name: name), with: .creation(project: path, id: run.id))
    }
  }

  /// Holds `run` on its `account` step until the user finishes or cancels the provider's setup
  /// (R2): true to carry on, false when cancelled. A run for a provider whose sheet is already up
  /// or queued joins it; only one sheet is up at a time, across every window.
  private func waitForRemoteSetup(
    _ run: CreationRun, place: RemoteWorkrooms.Place, setup: any RemoteSetup
  ) async -> Bool {
    run.waitForUser("account")
    return await withCheckedContinuation { continuation in
      if let wait = projectStore.remoteSetupWaits.first(where: { $0.place == place }) {
        wait.waiting.append(continuation)
        return
      }
      let wait = RemoteSetupWait(place: place, setup: setup, window: self)
      wait.waiting.append(continuation)
      projectStore.remoteSetupWaits.append(wait)
      if projectStore.remoteSetupWaits.count == 1 { presentRemoteSetup(wait) }
    }
  }

  private func presentRemoteSetup(_ wait: RemoteSetupWait) {
    (wait.window ?? self).pendingRemoteSetup = PendingRemoteSetup(
      place: wait.place, setup: wait.setup)
    Self.announceCreation(CreationPanePresentation.setupAnnouncement(for: wait.place))
  }

  /// The provider setup sheet in this window closed: Create Workroom (`carryOn`) or Cancel. Every
  /// create waiting on that provider carries on or ends, and the next provider's sheet comes up.
  func resolveRemoteSetup(carryOn: Bool) {
    guard let pending = pendingRemoteSetup else { return }
    pendingRemoteSetup = nil
    guard let index = projectStore.remoteSetupWaits.firstIndex(where: { $0.place == pending.place })
    else { return }
    let wait = projectStore.remoteSetupWaits.remove(at: index)
    for continuation in wait.waiting { continuation.resume(returning: carryOn) }
    if let next = projectStore.remoteSetupWaits.first { presentRemoteSetup(next) }
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
  /// disable while this holds so it can't be torn down mid-setup (issue #116). Shared across windows.
  func isCreatingWorkroom(_ workroom: Workroom, in project: Project) -> Bool {
    creatingWorkrooms.contains(
      TerminalTarget.workroomID(project: project.path, name: workroom.name))
      // A remote create (#253) is in this set from just after its workroom has a name; until then,
      // its run says so. One a crash left at `creating` is deletable.
      || (workroom.host?.state == "creating" && hasRunningCreation(inProject: project.path))
  }
}

/// What a remote create needs from the project before it makes anything (the `repository` step).
struct RemoteCreatePlan: Sendable {
  let repository: GitHubRepository
  let cloneURL: String
  /// The branch on origin it starts from, or nil for origin's default.
  let startBranch: String?
  /// The app-wide default base branch, when a remote machine can't use it.
  let defaultNotUsed: String?
}

/// Where a remote create makes its workroom.
struct RemoteCreateHost {
  let key: RemoteHosts.DriverKey
  let driver: any HostTerminalDriver
  let environment: RemoteProvisioning.Environment
}

/// What a remote create reaches beyond the app (#483): GitHub and the project's git, the provider's
/// account, and its hosts. `live` in the app; tests stand in fakes.
struct RemoteCreateServices {
  var plan: @MainActor (AppStore, Project) async throws -> RemoteCreatePlan
  var setupNeeded: @MainActor (RemoteWorkrooms.Place) async -> (any RemoteSetup)?
  var host: @MainActor (RemoteWorkrooms.Place) async throws -> RemoteCreateHost
  /// Runs the setup script on the new workroom's host (`RemoteWorkrooms.runScript`). A test's fakes
  /// have no script unless they say so.
  var script: @MainActor (RemoteWorkrooms.ScriptRequest) async -> RemoteProvisioning.ScriptRun = {
    _ in .absent
  }
  /// The CLI's `trust status` at the origin branch the plan checks out: the setup script a create
  /// would run, judged against this Mac's approvals (#363), and the local work that start leaves
  /// out. Its last argument judges the devcontainer.json a container create would use too (#308).
  /// A test's fakes approve every script and find no local work unless they say.
  var trustStatus:
    @MainActor (AppStore, Project, RemoteCreatePlan, Bool) async throws -> TrustStatus = {
      _, _, _, _ in
      TrustStatus(trusted: true, scripts: [])
    }

  static var live: RemoteCreateServices {
    RemoteCreateServices(
      plan: { store, project in try await store.planRemoteCreate(for: project) },
      // Checked once a launch per provider, so later creates go straight ahead.
      setupNeeded: { place -> (any RemoteSetup)? in
        switch place {
        case .exeDev:
          return await ExeDevSetup.needed(
            driver: ExeDevHostDriver(configuration: .init(), directory: RemoteHosts.hosts))
        case .boxd:
          return await BoxdSetup.needed()
        case .container:
          return nil
        }
      },
      host: { place in
        let key = try await RemoteHosts.shared.key(for: place)
        let (driver, environment) = try RemoteHosts.shared.environment(key)
        return RemoteCreateHost(key: key, driver: driver, environment: environment)
      },
      script: { request in await RemoteWorkrooms.runScript(request) },
      trustStatus: { store, project, plan, devcontainer in
        // origin named, so a branch like `release/1.0` is never read as a remote's.
        let base = plan.startBranch.map { "origin/\($0)" } ?? ""
        return try await store.cli.trustStatus(
          project: project.path, base: base, devcontainer: devcontainer)
      })
  }
}

extension AppStore {
  /// The project's GitHub repository and the branch its remote workroom starts from, or why it
  /// can't have one.
  func planRemoteCreate(for project: Project) async throws -> RemoteCreatePlan {
    // gh first, as it knows which remote is GitHub's; without it (not installed, or signed out,
    // which a remote provider's workroom doesn't need) origin says (#260).
    let resolver = WorkroomStatusResolver()
    var repository: GitHubRepository?
    if case .found(let found) = await resolver.resolveRepository(in: project.path) {
      repository = found
    } else {
      repository = await resolver.originRepository(in: project.path)
    }
    guard let repository else {
      throw RemoteWorkrooms.Failure.notOnGitHub(
        "Its origin remote names no GitHub repository, and gh couldn't say which one it is.")
    }
    guard repository.host == "github.com" else {
      throw RemoteWorkrooms.Failure.notOnGitHub("Its origin is on \(repository.host).")
    }
    // A remote host has only origin, so a base on another remote, or one only this Mac has, would
    // fail its checkout minutes in. Unreachable (nil) is left to the checkout, which says so.
    // A project's own base that can't be used fails; the app-wide default only falls back to
    // origin's default branch, with a notice, as a local create does.
    var startBranch: String?
    var defaultNotUsed: String?
    if let base = effectiveBaseBranch(for: project) {
      let (remote, branch) = RemoteWorkrooms.splitBase(
        base, remotes: await resolver.remoteNames(in: project.path))
      let fromDefault = project.baseBranch == nil
      if remote != "origin" {
        guard fromDefault else { throw RemoteWorkrooms.Failure.baseBranchOnOtherRemote(base) }
        defaultNotUsed = base
      } else if await resolver.originHasBranch(branch, in: project.path) == false {
        guard fromDefault else { throw RemoteWorkrooms.Failure.baseBranchNotOnOrigin(branch) }
        defaultNotUsed = base
      } else {
        startBranch = branch
      }
    }
    return RemoteCreatePlan(
      repository: repository,
      cloneURL: RemoteWorkrooms.cloneURL(
        for: repository, origin: await resolver.originURL(in: project.path)),
      startBranch: startBranch, defaultNotUsed: defaultNotUsed)
  }
}

/// The create's fetch warning, set from the CLI's parsing thread and read on the main actor.
final class CreationWarningBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?
  var value: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}

/// One create's private handle on its own landing (issue #167). It hands the "landed on the created
/// workroom" task from the CLI's "created" event back to the create, so the flow can await the
/// landing instead of racing it, and it carries the landed target id — the single answer to "which
/// workroom is THIS create's", which every release point keys on.
///
/// A box is needed because the CLI's event callback is *synchronous* and runs on whichever thread it
/// is parsing on — it can start the task but cannot await it. Locked rather than actor-isolated so
/// `set`/`claim` stay synchronous: registration has to be complete when the callback returns.
final class CreationLandingBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var landed: TerminalTarget.ID?
  private var isClosed = false

  /// The target this create landed on, or nil if it never got that far (a failure before the workroom
  /// existed). The create's release points key on this.
  var landedID: TerminalTarget.ID? {
    lock.lock()
    defer { lock.unlock() }
    return landed
  }

  /// Take ownership of `id` for this create, once. False when the create has already landed (the
  /// event and the fallback both call the landing) or has already ended — the caller must then record
  /// nothing, since nobody is left to undo it.
  func claim(_ id: TerminalTarget.ID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, landed == nil else { return false }
    landed = id
    return true
  }

  /// The create has ended — refuse any further landing. Separate from `finish()`, which the flow calls
  /// BEFORE its fallback landing.
  func close() {
    lock.lock()
    defer { lock.unlock() }
    isClosed = true
  }

  func set(_ task: Task<Void, Never>) {
    lock.lock()
    defer { lock.unlock() }
    self.task = task
  }

  /// Await the registered landing. A no-op when the CLI never fired its "created" event (a fake, or a
  /// failure before the workroom existed) — the create's own fallback covers that case.
  func finish() async {
    let pending = lock.withLock { task }
    await pending?.value
  }
}

extension AppStore.CreateStep {
  @MainActor init(_ run: CreationRun) {
    let progress = run.progress
    self.init(
      fraction: progress.fraction, label: progress.label,
      failed: !run.isRunning && run.outcome != .succeeded && !run.awaitsApproval)
  }
}
