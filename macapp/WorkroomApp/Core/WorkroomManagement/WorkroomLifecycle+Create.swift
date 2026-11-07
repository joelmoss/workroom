import AppKit
import DevContainer
import HostDrivers
import WorkroomDomain
import WorkroomVCS

/// Workroom creation (issues #116, #163, #167, #483): local and remote creates, each a
/// `CreationRun` whose pane opens on the click and shows its checklist until the workroom's own UI
/// takes over. The runs are the lifecycle's (`creationRuns`, `creationRunForTarget`), shared by every
/// window; the window a create is started from (its `LifecycleWindow`) places its pane, asks its
/// questions and shows its sheets, and every window applies what it does to the panes it shows
/// (`WorkroomLifecycle.Event`).
///
/// A run's pane is `.creation(project:id:)` until the workroom has a name, then the workroom's own
/// `.workroom(project:name:)`, swapped in place in every window. While the run lasts, that target's
/// terminal stays withheld in every window (`WorkroomLifecycle.isCreationBlocking`).
extension WorkroomLifecycle {
  // MARK: Runs

  /// Places a new run's pane in `window` before the create does any work (AC 1): beside
  /// `splitAnchor`, or as the selection.
  private func startCreationRun(
    project: Project, kind: HostKind?, splitAnchor: SidebarID?,
    hostOptions: HostOptions? = nil, from window: any LifecycleWindow
  ) -> CreationRun {
    let run = CreationRun(
      project: project, kind: kind, splitAnchor: splitAnchor,
      previousSelection: window.selectedTargetID, hasSetupScript: Self.hasSetupScript(project),
      hasIncludeFile: Self.hasIncludeFile(project), hostOptions: hostOptions)
    register(run)
    window.openCreationPane(
      .creation(project: project.path, id: run.id), in: project, beside: splitAnchor)
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

  /// The workroom `run` makes has a name: its pane becomes the workroom's in every window, once
  /// `window`'s reload has published it (`nameCreationRun(_:_:publishing:)`).
  private func nameCreationRun(
    _ run: CreationRun, _ name: String, from window: any LifecycleWindow
  ) async {
    await nameCreationRun(run, name) { await window.reload() }
  }

  /// The create's process ended: its workroom can be deleted and probed again (issue #116).
  private func releaseCreatingWorkroom(_ id: TerminalTarget.ID, from window: any LifecycleWindow) {
    creatingWorkrooms.remove(id)
    if let sid = projectStore.sidebarID(for: id) {
      vcsStatus.refreshLocalStatus(for: sid, skippingCreatesAndCommits: true)
    }
    window.scheduleSelectedStatusRefresh()
  }

  /// A finished create: its checklist stays, with Done, until the user closes it (`finishCreation`),
  /// or with "Close automatically when done" on, for `creationSuccessHold` (design D13). Then the
  /// workroom's terminal mounts. An armed auto-run (issue #7) doesn't wait for that: it starts now,
  /// backgrounded beside the shell the terminal will open on (owner).
  private func completeCreationRun(_ run: CreationRun, from window: any LifecycleWindow) async {
    run.succeed()
    if let name = run.name {
      announceCreation(CreationPanePresentation.successAnnouncement(name: name))
      let id = TargetID.workroom(project: run.project.path, name: name)
      if window.runCommand.isAutoRunArmed(id),
        let target = self.target(for: .workroom(project: run.project.path, name: name))
      {
        window.ensureInitialTerminal(for: target)
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
    announceCreation(CreationPanePresentation.failureAnnouncement(for: run))
  }

  /// The setup script needs approving before anything is made (#363): its row waits, the pane
  /// shows the script with Approve, and VoiceOver hears it once. `startCommit` is the start point it
  /// was asked at, which the answer continues from.
  private func refuseCreation(
    _ run: CreationRun, _ script: ScriptTrust, at startCommit: String? = nil,
    from window: any LifecycleWindow
  ) {
    run.awaitApproval(of: script, at: startCommit)
    announceCreation("\(script.displayFile) needs approving")
    presentSetupApproval(run, in: window)
  }

  /// The main checkout has work the create would leave out, before anything is made: the worktree's
  /// row waits, the user is asked where it starts, and VoiceOver hears it once.
  private func refuseCreation(
    _ run: CreationRun, leaving work: LocalWork, at startCommit: String?,
    from window: any LifecycleWindow
  ) {
    run.awaitStartChoice(for: work, at: startCommit)
    announceCreation("\(work.summary). Choose whether the new workroom includes it")
    presentStartChoice(run, in: window.modals)
  }

  // MARK: Failure actions

  /// Where a create starts, asked when it found local work: opened when the create stops, and again
  /// by the pane's Choose Start…, in the window it was asked from.
  func presentStartChoice(_ run: CreationRun, in modals: ModalState) {
    guard creationRuns[run.id] === run, case .localWorkFound(let work) = run.outcome
    else { return }
    modals.pendingStartChoice = PendingStartChoice(run: run, work: work)
  }

  /// A start chosen for a create that found local work: it continues, in the same pane, from the
  /// start point it was asked at. A choice left over from a run since replaced does nothing.
  func chooseStart(
    _ start: CreationStart, for run: CreationRun, from window: any LifecycleWindow
  ) async {
    guard creationRuns[run.id] === run, case .localWorkFound = run.outcome else { return }
    await retryCreation(run, start: start, startCommit: run.askedAt, from: window)
  }

  /// Cancel Creation on the start choice; stale, it cancels nothing.
  func cancelStartChoice(_ run: CreationRun, from window: any LifecycleWindow) {
    guard creationRuns[run.id] === run, case .localWorkFound = run.outcome else { return }
    closeCreation(run, from: window)
  }

  /// The setup script's approval sheet, the teardown's (`presentTeardownFailure`) for a create: the
  /// script to read, Continue Without Script… (confirmed), Cancel Creation, and Approve. Opened when
  /// the create stops, and again by the pane's Review Script…, in `window`.
  func presentSetupApproval(_ run: CreationRun, in window: any LifecycleWindow) {
    guard creationRuns[run.id] === run, case .scriptNotTrusted(let script) = run.outcome
    else {
      return
    }
    let modals = window.modals
    // The message first: setting it clears what the rest set.
    modals.errorMessage = CreationPanePresentation.setupApprovalMessage(for: run, script: script)
    modals.errorTitle =
      script.isDevContainer ? "Approve the dev container?" : "Approve the setup script?"
    modals.errorLog = script.visibleText
    modals.errorScriptName = script.name
    let confirmation = CreationPanePresentation.skipConfirmation(for: script)
    modals.errorAction = ErrorAction(
      label: "\(confirmation.button)…", destructive: false, confirmation: confirmation
    ) { [weak window] in
      Task { if let window { await self.skipSetupScript(run, from: window) } }
    }
    // A stale sheet (the run approved or replaced since) cancels nothing.
    modals.errorCancel = ErrorAction(label: "Cancel Creation") { [weak window] in
      guard let window, self.creationRuns[run.id] === run else { return }
      self.closeCreation(run, from: window)
    }
    modals.errorApproval = ErrorAction(label: "Approve") { [weak window] in
      Task { if let window { await self.approveSetupScript(run, from: window) } }
    }
  }

  /// Approve on a create its setup script stopped: the bytes shown are recorded as approved and the
  /// create continues, in the same pane, from the start point the script was judged at.
  func approveSetupScript(_ run: CreationRun, from window: any LifecycleWindow) async {
    guard creationRuns[run.id] === run, case .scriptNotTrusted(let script) = run.outcome
    else {
      return
    }
    do {
      try await window.services.cli.trustScript(
        script.name, text: script.approvalBytes, project: run.project.path)
    } catch {
      failCreationRun(run, .failedBeforeWorkroom(message: Self.errorText(error)))
      return
    }
    await retryCreation(run, startCommit: run.askedAt, from: window)
  }

  /// Continue Without Script, once confirmed, on a create its setup script stopped: the create
  /// continues, in the same pane, without that script. For a devcontainer.json it is Continue With
  /// Default Image: the container create continues without the file. Nothing is approved, so the
  /// next create asks again.
  func skipSetupScript(_ run: CreationRun, from window: any LifecycleWindow) async {
    guard creationRuns[run.id] === run, case .scriptNotTrusted(let script) = run.outcome
    else {
      return
    }
    if script.isDevContainer {
      await retryCreation(run, skipsDevContainer: true, startCommit: run.askedAt, from: window)
    } else {
      await retryCreation(run, skipsSetup: true, startCommit: run.askedAt, from: window)
    }
  }

  /// The setup script row's reason on a create that skipped it, as the CLI words it.
  nonisolated static let setupSkippedReason = "Skipped without approval"

  /// Close on a failed create, or Cancel on its provider setup: the pane goes. In `window`, a split
  /// collapses to its sibling; a pane on its own gives way to what was selected before, if it still
  /// exists.
  func closeCreation(_ run: CreationRun, from window: any LifecycleWindow) {
    window.closeCreationPane(paneID(of: run), returningTo: run.previousSelection)
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
  ///
  /// `hostOptions` replaces this create's own host options: Try With Provider Defaults passes
  /// Provider default for each (#575), which a later Try Again keeps.
  func retryCreation(
    _ run: CreationRun, skipsSetup: Bool? = nil, skipsDevContainer: Bool? = nil,
    start: CreationStart? = nil, startCommit: String? = nil, hostOptions: HostOptions? = nil,
    from window: any LifecycleWindow
  ) async {
    // A second click before the pane redraws must not start a second create (or paid machine).
    guard creationRuns[run.id] === run else { return }
    let project = projectStore.project(at: run.project.path) ?? run.project
    let start = start ?? run.start
    let retry = CreationRun(
      id: run.id, project: project, kind: run.kind, splitAnchor: run.splitAnchor,
      previousSelection: run.previousSelection,
      hasSetupScript: Self.hasSetupScript(project),
      hasIncludeFile: Self.hasIncludeFile(project), skipsSetup: skipsSetup ?? run.skipsSetup,
      skipsDevContainer: skipsDevContainer ?? run.skipsDevContainer, start: start,
      startCommit: startCommit, carriedFetch: startCommit == nil ? nil : run.fetchStep,
      hostOptions: hostOptions ?? run.hostOptions)
    replaceCreationRun(run, with: retry)
    if let kind = run.kind {
      await runRemoteCreate(retry, place: kind, from: window)
    } else {
      await runLocalCreate(retry, from: window)
    }
  }

  // MARK: Local

  /// `splitAnchor` (issue #163) opens the new workroom BESIDE that one instead of replacing it —
  /// ⌥⌘N and ⌥⏎ in the New picker pass the selection as it stood when the project was picked.
  /// Its pane opens on the click (#483), in `window`, and shows the create's checklist until it
  /// succeeds.
  func createWorkroom(
    in project: Project, splitAnchor: SidebarID? = nil, from window: any LifecycleWindow
  ) async {
    // A picker opened before Delete Project still holds the project (#287).
    guard !deletingProjects.contains(project.path) else {
      window.modals.errorTitle = "Can't create a workroom in \(project.displayName)"
      window.modals.errorMessage = "\(project.displayName) is being deleted."
      return
    }
    await runLocalCreate(
      startCreationRun(project: project, kind: nil, splitAnchor: splitAnchor, from: window),
      from: window)
  }

  private func runLocalCreate(_ run: CreationRun, from window: any LifecycleWindow) async {
    let warning = CreationWarningBox()
    // An answer's create fetches nothing, so the try it answers is what said its start may be stale;
    // the create's own warning, when it has one, says it anew.
    warning.value = run.carriedFetchWarning
    guard let landedID = await performLocalCreate(run, warning: warning, from: window) else {
      return
    }
    await completeCreationRun(run, from: window)
    if let text = warning.value, !text.isEmpty { window.noticeStaleStart(of: landedID, text) }
  }

  /// Runs the CLI's create into `run`. The workroom's id when it succeeded, else nil with `run`
  /// failed. Its deletion protection is released here, when the process ends (F7).
  private func performLocalCreate(
    _ run: CreationRun, warning: CreationWarningBox, from window: any LifecycleWindow
  ) async -> TerminalTarget.ID? {
    let project = run.project
    // The landing runs on the main actor and `await reload()`s, so it can still be in flight when
    // `cli.create` returns: hold its task and await it rather than race it (issue #167).
    let landing = CreationLandingBox()
    defer {
      landing.close()
      if let id = landing.landedID { releaseCreatingWorkroom(id, from: window) }
    }
    do {
      let created = try await window.services.cli.create(
        project: project.path, skipSetup: run.skipsSetup, start: run.cliStart,
        startCommit: run.startCommit
      ) { event in
        if event.type == "created", let name = event.name {
          if let text = event.warning, !text.isEmpty { warning.value = text }
          // Registered synchronously, so it is there to await when `create` returns.
          landing.set(
            Task { @MainActor in
              await self.landOnCreatedWorkroom(
                name: name, run: run, setup: event.setup ?? false, landing: landing, from: window)
            })
        } else {
          Self.onMain { run.apply(event) }
        }
      }
      await landing.finish()
      await Self.drainMainQueue()
      // Land now if the "created" event never arrived (a fake CLI).
      if landing.landedID == nil {
        await landOnCreatedWorkroom(
          name: created.name, run: run, setup: false, landing: landing, from: window)
      } else {
        await window.reload()  // reflect the finished setup script's tree
      }
      if let text = created.warning { warning.value = warning.value ?? text }
      return landing.landedID
    } catch {
      await landing.finish()
      await Self.drainMainQueue()
      // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
      await window.reload()
      if let id = landing.landedID {
        // The workroom exists but setup failed. Disarm the auto-run armed at the landing so Open
        // Anyway doesn't launch the command against a half-set-up tree (issue #7).
        window.runCommand.disarmAutoRun(forWorkroom: id)
        failCreationRun(run, .setupScriptFailed(message: Self.errorText(error)))
        // Offline, the fetch and a networked setup script fail together: say both.
        if let text = warning.value { window.noticeStaleStart(of: id, text) }
      } else if let script = WorkroomCLIError.untrustedScript(error) {
        refuseCreation(run, script, at: WorkroomCLIError.startCommit(error), from: window)
      } else if let work = WorkroomCLIError.leftOutWork(error) {
        refuseCreation(
          run, leaving: work, at: WorkroomCLIError.startCommit(error), from: window)
      } else if run.startCommit != nil, WorkroomCLIError.isUnusableStartCommit(error) {
        // The start point the answer was about is gone (the base branch changed in between): start
        // over, fetching afresh, and ask again if need be.
        await retryCreation(run, from: window)
      } else {
        failCreationRun(run, .failedBeforeWorkroom(message: Self.errorText(error)))
      }
      return nil
    }
  }

  /// Lands on a just-created workroom once it exists (issue #116): its pane becomes the workroom's
  /// and auto-run is armed for its first terminal in `window`. Idempotent via `landing.claim`: the
  /// "created" event and the fallback can both call it, and only the first lands.
  // `internal` (not `private`) only so `@testable` can drive the closed-box bail path directly.
  func landOnCreatedWorkroom(
    name: String, run: CreationRun, setup: Bool, landing: CreationLandingBox,
    from window: any LifecycleWindow
  ) async {
    // Claim BEFORE recording anything: a create that has already finished (its box closed) must not
    // insert a guard nobody is left to remove (issue #167, defect 1).
    let id = TargetID.workroom(project: run.project.path, name: name)
    guard landing.claim(id) else { return }
    await nameCreationRun(run, name, from: window)
    window.armAutoRunIfConfigured(id, in: run.project)
  }

  /// Runs `body` on the main queue, after everything a create's progress callbacks queued before
  /// it. Every step, line and pull update goes through this one FIFO queue, so a line is never
  /// filed after the next step began; `drainMainQueue` waits it out.
  nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
  }

  /// Waits until every block already queued on the main queue has run: the CLI's events hop there.
  private static func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  /// How an error reads in a create's pane and in a window's error sheet.
  nonisolated static func errorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  // MARK: Remote

  /// Writes what the remote create and delete sequences record to `path`'s config, through `cli`.
  func remoteRecorder(
    project path: String, cli: any WorkroomCLIProtocol
  ) -> RemoteWorkrooms.Recorder {
    RemoteWorkrooms.Recorder(
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
          descriptor: try JSONEncoder().encode(
            HostDescriptor(state: HostLifecycle.destroyed.state)))
        try await cli.delete(name: workroom, project: path, onLog: nil)
      },
      reserveInParent: { parent, descriptor in
        try await cli.createRemote(
          project: path, hostParent: parent, descriptor: try JSONEncoder().encode(descriptor)
        ).name
      },
      hasWorkrooms: { id in
        try await cli.list(warnings: "fast", project: nil).projects.contains { project in
          project.workrooms.contains { $0.host?.id == id && $0.host?.isDestroyed == false }
        }
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

  /// Creates a remote workroom for `project` at `place` (#253, #309, #356): a container on this Mac,
  /// or a boxd machine or exe.dev VM, each with its own clone. Its pane opens on the click (#483),
  /// in `window`, beside `splitAnchor` when there is one, and becomes the workroom's once it has a
  /// name. `hostOptions` are this create's own (the Options panel's, #575), over the project's and
  /// Settings'.
  func createRemoteWorkroom(
    in project: Project, place: HostKind = .container(.docker),
    splitAnchor: SidebarID? = nil, hostOptions: HostOptions? = nil,
    from window: any LifecycleWindow
  ) async {
    // As it is now, not as a menu or the picker caught it: its base branch may have changed.
    let project = projectStore.project(at: project.path) ?? project
    guard canCreateRemoteWorkroom(in: project) else { return }
    await runRemoteCreate(
      startCreationRun(
        project: project, kind: place, splitAnchor: splitAnchor, hostOptions: hostOptions,
        from: window),
      place: place, from: window)
  }

  private func runRemoteCreate(
    _ run: CreationRun, place: HostKind, from window: any LifecycleWindow
  ) async {
    let path = run.project.path
    let services = window.services.remoteCreate
    var defaultNotUsed: String?
    do {
      run.begin("repository")
      let plan = try await services.plan(
        run.project, projectStore.effectiveBaseBranch(for: run.project))
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
        ? (try? await services.trustStatus(window.services.cli, run.project, plan, false))
          ?? TrustStatus(trusted: true, scripts: [])
        : try await services.trustStatus(
          window.services.cli, run.project, plan, judgesDevContainer)
      // The file that decides the image first: it is what the create reads first.
      if judgesDevContainer, let config = status.scripts.first(where: { $0.isDevContainer }),
        !config.trusted
      {
        refuseCreation(run, config, from: window)
        return
      }
      if !run.skipsSetup,
        let script = status.scripts.first(where: {
          $0.name == RemoteProvisioning.Script.setup.fileName && !$0.trusted
        })
      {
        refuseCreation(run, script, from: window)
        return
      }
      // The judged bytes, which are what the container is made from (#308).
      let devcontainer = judgesDevContainer ? try ContainerCreate.file(in: status) : nil
      if let devcontainer, devcontainer.config.usesCompose {
        run.awaitDefaultImage(refusing: devcontainer.path)
        announceCreation("\(devcontainer.path) describes Docker Compose services")
        return
      }
      // A remote host clones from GitHub, so local work can't come along: it is only said.
      let leftOut = status.localWork.map {
        "\($0.summary). Remote workrooms can only start from what you've pushed, so this one "
          + "doesn't include that work."
      }
      // After the project's own checks, so nobody signs up or picks a plan for a project the
      // provider can't take.
      var sshSetup: SSHHostSetup?
      if run.steps.contains(where: { $0.id == "account" }) {
        run.begin("account")
        if let proposed = await services.setupNeeded(place) {
          // A second create shares the actual host choice shown in the existing sheet.
          let setup =
            remoteSetupWaits.first(where: { $0.place == place })?.setup
            ?? proposed
          sshSetup = setup as? SSHHostSetup
          guard await waitForRemoteSetup(run, place: place, setup: setup, in: window.modals)
          else {
            run.cancel()
            closeCreation(run, from: window)
            return
          }
          run.begin("account")
        }
      }
      let host: RemoteCreateHost
      if let sshSetup, let driver = sshSetup.driver {
        host = RemoteCreateHost(
          key: .ssh(destination: driver.destination), driver: driver,
          environment: .init(driver: driver, daemonSocket: driver.daemonSocket),
          ssh: (driver, sshSetup.parent))
      } else {
        // Resolved at each try, so a Try Again reads the project and Settings afresh.
        run.madeWith =
          services.hostOptionResolution(
            for: place, in: run.project, create: run.hostOptions)?.options
        host = try await services.host(place, run.madeWith)
      }
      let (created, prepared) = try await provisionRemote(
        run, plan: plan, host: host, start: status.start, devcontainer: devcontainer,
        madeWith: run.madeWith, from: window)
      await Self.drainMainQueue()  // the last step's lines, before it is marked done
      if run.steps.contains(where: { $0.id == ProvisioningProgress.Step.include.rawValue }) {
        await copyIncluded(
          run, into: created.instance, driver: host.driver, cli: window.services.cli)
      }
      // The dev container's lifecycle commands, before the setup script (#308).
      let hookFailure = await runHooks(
        run, prepared?.hooks ?? [], on: created.instance.host, environment: host.environment)
      // Its panes attach through their own ssh; Changes and the rest connect for themselves.
      await created.instance.connection.close()
      // Before the setup script: the reload adopts the host, which marks a relayed one so the
      // script's connect puts git's credentials up for it.
      await window.reload()
      let id = TargetID.workroom(project: path, name: created.name)
      // Still undeletable while the script runs, as a local create's workroom is (issue #116).
      var setupFailure: String?
      if hookFailure != nil {
        // A failed lifecycle command stops the create where it is: the setup script would run on
        // a container half set up.
      } else if run.skipsSetup {
        run.begin("script")
        run.finish("script", as: .skipped(reason: Self.setupSkippedReason))
      } else {
        setupFailure = await runRemoteSetup(
          run, created: created, host: host, services: services,
          environment: prepared?.remoteEnvironment ?? [:], cli: window.services.cli)
      }
      releaseCreatingWorkroom(id, from: window)
      if let hookFailure {
        // As a failed setup script's.
        window.runCommand.disarmAutoRun(forWorkroom: id)
        failCreationRun(run, .hookFailed(message: hookFailure))
      } else if let setupFailure {
        // As a local create's: the workroom and its host stay, for Open Anyway or Delete, and the
        // auto-run armed at the reserve is disarmed, so Open Anyway doesn't start the command
        // against a half-set-up tree (issue #7).
        window.runCommand.disarmAutoRun(forWorkroom: id)
        failCreationRun(run, .setupScriptFailed(message: setupFailure))
      } else {
        await completeCreationRun(run, from: window)
      }
      let notices = [
        defaultNotUsed.map {
          "The default base branch \($0) can't be used on a remote machine here, so the workroom "
            + "starts from origin's default branch."
        },
        leftOut,
      ].compactMap { $0 }
      if !notices.isEmpty { window.noticeStaleStart(of: id, notices.joined(separator: " ")) }
    } catch {
      // A record the rollback forgot has already given its pane back (`provisionRemote`'s
      // `forget`); one still naming a live machine keeps its workroom pane, for Delete.
      var leftBehind = false
      if case RemoteProvisioning.Failure.rollbackIncomplete = error { leftBehind = true }
      await Self.drainMainQueue()  // the failing step's lines and its start
      await window.reload()
      failCreationRun(
        run, .remoteFailed(message: Self.errorText(error), leftBehind: leftBehind))
      if let name = run.name {
        let id = TargetID.workroom(project: path, name: name)
        // As above.
        window.runCommand.disarmAutoRun(forWorkroom: id)
        releaseCreatingWorkroom(id, from: window)
      }
    }
  }

  /// The machine, clone and checkout of a remote create, reporting each step and its log into
  /// `run`. The workroom's name, once reserved, becomes its pane's; a rollback that forgets it gives
  /// the pane back to the run (O2) before anything reloads.
  ///
  /// A container's dev container comes first (#308): `devcontainer`, the judged file or nil for
  /// the default image, is read, built and made into the container's spec (`ContainerCreate`).
  /// `start` is the judged commit the checkout starts at.
  private func provisionRemote(
    _ run: CreationRun, plan: RemoteCreatePlan, host: RemoteCreateHost, start: String?,
    devcontainer: ContainerCreate.File?, madeWith: ResolvedHostOptions?,
    from window: any LifecycleWindow
  ) async throws -> (RemoteWorkrooms.Created, ContainerCreate.Prepared?) {
    let path = run.project.path
    let stepped: @Sendable (ProvisioningProgress.Step) -> Void = { step in
      Self.onMain { run.begin(step.rawValue) }
    }
    let logged: @Sendable (ProvisioningProgress.Step, String) -> Void = { step, line in
      Self.onMain { run.append(line, to: step.rawValue) }
    }
    // Set once the driver reports a pull: still nil after the image step, the image was here.
    let pulled = CreationWarningBox()
    let report: @Sendable (Double?) -> Void = { fraction in
      pulled.value = "pulled"
      Self.onMain { run.pullFraction = fraction }
    }
    // Weak, as the store was when it ran the create itself; the flow's own frames hold the window
    // while these run. Giving the pane back is lifecycle state, so it never waits on the window.
    var recorder = remoteRecorder(project: path, cli: window.services.cli)
    // A reserved name names the run, then arms the workroom's auto-run.
    let reserved: @Sendable (String) async -> Void = { [weak window] name in
      if let window { await self.nameCreationRun(run, name, from: window) }
      await window?.armAutoRunIfConfigured(
        TargetID.workroom(project: path, name: name), in: run.project)
    }
    let reserve = recorder.reserve
    recorder.reserve = { hostPath, descriptor in
      let name = try await reserve(hostPath, descriptor)
      await reserved(name)
      return name
    }
    if let reserveInParent = recorder.reserveInParent {
      recorder.reserveInParent = { parent, descriptor in
        let name = try await reserveInParent(parent, descriptor)
        await reserved(name)
        return name
      }
    }
    let forget = recorder.forget
    recorder.forget = { name in
      try await forget(name)
      await self.returnPaneToRun(run, name: name)
    }
    // The Mac's token (a container's) is part of checking the repository: had while `repository`
    // runs, so a signed-out gh fails that row, before an image pull that can take minutes.
    var environment = host.environment
    if let gitHubToken = environment.gitHubToken {
      let token = try await gitHubToken()
      environment.gitHubToken = { token }
    }
    let container = host.container
    let runtime = host.key.runtime ?? .docker
    let defaultImage = RemoteWorkrooms.defaultImage
    return try await ProvisioningProgress.$reportStep.withValue(stepped) {
      try await ProvisioningProgress.$log.withValue(logged) {
        try await ContainerHostDriver.$pullProgress.withValue(report) {
          var prepared: ContainerCreate.Prepared?
          var environment = environment
          if let container {
            let made = try await ContainerCreate.prepare(
              devcontainer, project: path, repository: plan.repository.name,
              start: start ?? plan.startBranch.map { "origin/\($0)" } ?? "origin/HEAD",
              runtime: runtime, driver: container, defaultImage: defaultImage,
              featureCache: RemoteHosts.directory.appendingPathComponent("feature-cache"))
            prepared = made
            await Self.drainMainQueue()
            await MainActor.run {
              if !made.pulled {
                run.finish("image", as: .skipped(reason: "Built from its Dockerfile"))
              } else if pulled.value == nil {
                run.finish("image", as: .skipped(reason: "Image already downloaded"))
              }
              run.pullFraction = nil
              if !made.warnings.isEmpty {
                run.warn(
                  ProvisioningProgress.Step.config.rawValue,
                  made.warnings.joined(separator: ". ") + ".")
              }
            }
            environment.makeHost = { try await container.create(spec: made.spec) }
          }
          if let (ssh, parent) = host.ssh {
            let cloneURL = RemoteWorkrooms.cloneURL(
              for: plan.repository, origin: plan.origin ?? plan.cloneURL, onSSHHost: true)
            let created = try await RemoteWorkrooms.createSSH(
              repository: plan.repository, cloneURL: cloneURL, startBranch: plan.startBranch,
              startCommit: start, parent: parent, driver: ssh,
              environment: environment, recorder: recorder)
            return (created, nil)
          }
          let created = try await RemoteWorkrooms.create(
            repository: plan.repository, cloneURL: plan.cloneURL, startBranch: plan.startBranch,
            startCommit: start, path: prepared?.workspaceFolder,
            config: prepared.map { ($0.configDigest, $0.configFile) }, key: host.key,
            driver: host.driver, environment: environment, recorder: recorder, madeWith: madeWith)
          return (created, prepared)
        }
      }
    }
  }

  /// A container create's lifecycle commands (#308), each under its own row, in order, stopping at
  /// the first that fails. Nil when every one passed (or there were none); else why.
  private func runHooks(
    _ run: CreationRun, _ hooks: [(hook: DevContainerConfig.Hook, script: String)],
    on host: HostID, environment: RemoteProvisioning.Environment
  ) async -> String? {
    for (hook, script) in hooks {
      let step = hook.step.rawValue
      run.begin(step)
      let failure = await ContainerCreate.runHook(
        hook, script: script, on: host, driver: environment.driver,
        daemonBinary: environment.daemonBinary(on: host),
        onLine: { line in Self.onMain { run.append(line, to: step) } })
      await Self.drainMainQueue()  // its last lines, before its row ends
      if let failure { return failure }
      run.finish(step, as: .done)
    }
    return nil
  }

  /// A remote create's "Run setup script" step: the project's setup script on the new host, as a
  /// local create's CLI runs one. nil when it passed or there is none; otherwise why it failed,
  /// worded as the CLI's ("setup script failed: ..."). `cli` judges the script.
  private func runRemoteSetup(
    _ run: CreationRun, created: RemoteWorkrooms.Created, host: RemoteCreateHost,
    services: RemoteCreateServices, environment: [String: String] = [:],
    cli: any WorkroomCLIProtocol
  ) async -> String? {
    let step = "script"
    let request = RemoteWorkrooms.ScriptRequest(
      script: .setup, workroom: created.name, path: created.instance.path,
      host: created.instance.host, key: host.key, driver: host.driver,
      daemonBinary: host.environment.daemonBinary(on: created.instance.host),
      rootScript: URL(fileURLWithPath: run.project.path + "/scripts/workroom_setup"),
      judge: Self.judge(.setup, in: run.project.path, cli: cli),
      onStart: { Self.onMain { run.begin(step) } },
      onLine: { line in Self.onMain { run.append(line, to: step) } }, environment: environment)
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
  /// checkout once it is out, archived by `cli`. It never fails the create: the step ends as a
  /// warning instead.
  private func copyIncluded(
    _ run: CreationRun, into instance: RemoteProvisioning.Instance, driver: any HostDriver,
    cli: any WorkroomCLIProtocol
  ) async {
    let step = ProvisioningProgress.Step.include.rawValue
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

  /// Holds `run` on its `account` step until the user finishes or cancels the provider's setup
  /// (R2): true to carry on, false when cancelled. A run for a provider whose sheet is already up
  /// or queued joins it; only one sheet is up at a time, across every window. A new one goes up in
  /// `modals`, the window the create was asked from.
  private func waitForRemoteSetup(
    _ run: CreationRun, place: HostKind, setup: any RemoteSetup, in modals: ModalState
  ) async -> Bool {
    run.waitForUser("account")
    return await withCheckedContinuation { continuation in
      if let wait = remoteSetupWaits.first(where: { $0.place == place }) {
        wait.waiting.append(continuation)
        return
      }
      let wait = RemoteSetupWait(place: place, setup: setup, modals: modals)
      wait.waiting.append(continuation)
      remoteSetupWaits.append(wait)
      if remoteSetupWaits.count == 1 { presentRemoteSetup(wait, in: modals) }
    }
  }

  private func presentRemoteSetup(_ wait: RemoteSetupWait, in modals: ModalState) {
    (wait.modals ?? modals).pendingRemoteSetup = PendingRemoteSetup(
      place: wait.place, setup: wait.setup)
    announceCreation(CreationPanePresentation.setupAnnouncement(for: wait.place))
  }

  /// The provider setup sheet in the window whose `modals` these are closed: Create Workroom
  /// (`carryOn`) or Cancel. Every create waiting on that provider carries on or ends, and the next
  /// provider's sheet comes up.
  func resolveRemoteSetup(carryOn: Bool, in modals: ModalState) {
    guard let pending = modals.pendingRemoteSetup else { return }
    modals.pendingRemoteSetup = nil
    guard let index = remoteSetupWaits.firstIndex(where: { $0.place == pending.place })
    else { return }
    let wait = remoteSetupWaits.remove(at: index)
    for continuation in wait.waiting { continuation.resume(returning: carryOn) }
    if let next = remoteSetupWaits.first { presentRemoteSetup(next, in: modals) }
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

extension WorkroomLifecycle.CreateStep {
  @MainActor init(_ run: CreationRun) {
    let progress = run.progress
    self.init(
      fraction: progress.fraction, label: progress.label,
      failed: !run.isRunning && run.outcome != .succeeded && !run.awaitsApproval)
  }
}
