import Foundation
import WorkroomDomain

/// Workroom creation (issues #116, #163, #167): local and remote creates, their progress and
/// landing, and the dialog state that tracks them, plus the `WorkroomCreation`,
/// `CreationWarningBox` and `CreationLandingBox` types they use. Moved out of `AppStore.swift` as
/// is. Its stored state stays on `AppStore` (`creations`, `pendingCreation`, `imagePulls`,
/// `createSteps`), because an extension cannot store and views observe it through the store. Other
/// coupling points left on `AppStore`: `cli`, `projects`, `selectedTargetID`, `terminals`,
/// `beginBusy`/`endBusy`, `present(_:)` and `errorText(_:)`; `remoteRecorder(project:)` is also
/// called by the delete paths that stay there.
extension AppStore {
  /// `splitAnchor` (issue #163) opens the new workroom BESIDE that one instead of replacing it —
  /// ⌥⌘N and ⌥⏎ in the New picker pass the selection as it stood when the project was picked.
  /// A parameter rather than store state, so each landing closure captures its own — nothing
  /// serializes overlapping creates, and every create's state is its own (issue #167).
  func createWorkroom(in project: Project, splitAnchor: SidebarID? = nil) async {
    // A picker opened before Delete Project still holds the project (#287).
    guard !deletingProjects.contains(project.path) else {
      errorTitle = "Can't create a workroom in \(project.displayName)"
      errorMessage = "\(project.displayName) is being deleted."
      return
    }
    beginBusy(project.path)

    let session = ScriptLogSession(
      title: "Setting up new workroom in \(project.displayName)", phase: "setup")
    // Claim the pre-name loader slot immediately, so a create started from the empty state shows
    // progress in the window from the first click rather than only in the sidebar (issue #116). With
    // a workroom already on screen it stays a chip + row spinner instead — see `focusedCreation`.
    // Once the workroom exists the landing moves this create into `creations[id]`, keyed on its own
    // target, and — for a setup script — the loader gives way to that target's dialog.
    pendingCreation = WorkroomCreation(session: session, project: project)
    selectedProjectID = project.id

    // The landing runs on the main actor and `await reload()`s before it records anything, so it can
    // still be in flight when `cli.create` returns — while EVERYTHING below keys on what it recorded
    // (the box's `landedID`). So hold its task and await it rather than racing it: when the ready→exit
    // gap was short enough (a fast setup script; the fake CLI in the tests) the flow saw no landing,
    // re-landed with `setup: false`, and then cleared the dialog — losing the setup log, which is the
    // whole point of a setup script. The `catch` awaits it too, so a setup *failure* can't lose its
    // dialog the same way.
    let landing = CreationLandingBox()
    // The create's fetch warning, from the "created" event, so a failed setup keeps it.
    let warning = CreationWarningBox()
    // ONE release point per create, and all three are keyed on THIS create's own target — never on
    // which dialog happens to be on screen (issue #167, defect 1). A create superseded in the
    // presentation slot still lifts its own deletion protection here, and a stale landing can never
    // lift another create's.
    defer {
      landing.close()
      if let id = landing.landedID {
        // Setup (if any) has finished, so the worktree is no longer being written — allow deletion
        // again (issue #116), release the cross-window withholding, and probe the tree now that it
        // has settled. The probe names THIS create's own target: `scheduleSelectedStatusRefresh` reads
        // `selectedTargetID`, and with two overlapping creates the second one owns the selection by
        // the time the first finishes — so a selection-scoped refresh probed the wrong workroom and
        // left this one's dirty dot reading its pre-setup value (its own final `reload()` skipped it
        // too, since the guard above was still set). The selection-scoped call stays for the watcher.
        creatingWorkrooms.remove(id)
        settingUpWorkrooms.remove(id)
        if let sid = Self.sidebarID(forTargetID: id, in: projects) { refreshLocalStatus(for: sid) }
        scheduleSelectedStatusRefresh()
      } else {
        // Never landed → the sidebar spinner is still ours to clear (the landing clears it otherwise,
        // the moment the workroom exists). Exactly one decrement per create, which is why
        // `busyProjects` can be a count: two creates in one project each keep their own spinner.
        endBusy(project.path)
      }
    }

    do {
      let created = try await cli.create(
        project: project.path,
        onLog: { text in
          DispatchQueue.main.async { session.append(text) }
        },
        onReady: { name, _, setup in
          // The workroom now exists: land on it (the provisional chip becomes the real named chip, and
          // the detail moves from the loader to the new workroom's slot). A setup script shows its
          // dialog there; a no-setup workroom keeps the loader until the create completes.
          //
          // Registered SYNCHRONOUSLY — no `DispatchQueue.main.async` wrapper, since `Task { @MainActor }`
          // already hops to the main actor. That extra hop meant the task might not be *registered* yet
          // when `create` returned, so there was nothing for the `await` below to wait on.
          landing.set(
            Task { @MainActor in
              await self.landOnCreatedWorkroom(
                name: name, project: project, setup: setup, session: session,
                splitAnchor: splitAnchor, landing: landing)
            })
        },
        onWarning: { warning.value = $0 }
      )
      await landing.finish()
      session.finish()
      // Land now if the early "created" event never arrived (older CLI) — no setup flag to read.
      if landing.landedID == nil {
        await landOnCreatedWorkroom(
          name: created.name, project: project, setup: false, session: session,
          splitAnchor: splitAnchor, landing: landing)
      } else {
        await reload()  // reflect the finished setup script's tree
      }
      // No setup script → there was never a dialog, just the loader: clear this create so the loader
      // gives way to the new workroom's terminal (issue #116). A setup script instead keeps its dialog
      // up (with a Dismiss button) until the user closes it — dismissing is what mounts the withheld
      // terminal. Auto-run is NOT triggered here: it fires from `ensureInitialTerminal` when the
      // terminal pane first mounts, which for a setup script is after dismissal (issue #7).
      if let id = landing.landedID, creations[id]?.hasSetup != true { creations[id] = nil }
      if let id = landing.landedID, let text = warning.value ?? created.warning, !text.isEmpty {
        noticeStaleStart(of: id, text)
      }
      clearPendingCreation(session)
    } catch {
      await landing.finish()  // as above: read the landing's state, don't race it
      // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
      await reload()
      if let id = landing.landedID, let name = creations[id]?.name {
        // The workroom exists but setup failed. Disarm the auto-run armed in `onReady` (before setup
        // ran) so dismissing the failure doesn't launch the command against a half-set-up tree —
        // auto-run is a success-path action (issue #7, review finding). Force `hasSetup` so the detail
        // shows the setup dialog (with a Dismiss button + the failure message), not the loader, until
        // it's closed. Re-assert selection (idempotent with `onReady`) so the failure is on screen even
        // if the `onReady` land lost the race to this catch.
        if case .armed = runStates[id] { runStates[id] = nil }
        creations[id]?.hasSetup = true
        selectedProjectID = project.id
        selectedTargetID = .workroom(project: project.path, name: name)
        session.finish(failure: errorText(error))
        // Offline, the fetch and a networked setup script fail together: say both.
        if let text = warning.value { noticeStaleStart(of: id, text) }
      } else {
        // Failed before the workroom existed — no tab/slot target; surface it.
        present(error)
      }
      clearPendingCreation(session)
    }
  }

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

  /// The workroom a remote create made its own row for, once it has a name.
  @MainActor final class RemoteCreateRow {
    var workroom: SidebarID?
  }

  struct CreateStep: Equatable {
    let fraction: Double
    let label: String
  }

  /// `step` of a remote provider's create, as the row shows it.
  nonisolated static func createStep(_ step: RemoteProvisioning.Step) -> CreateStep {
    let steps = RemoteProvisioning.Step.allCases
    let index = steps.firstIndex(of: step) ?? 0
    return CreateStep(
      fraction: Double(index) / Double(steps.count),
      label: "\(step.rawValue) (step \(index + 1) of \(steps.count))")
  }

  /// Why no workroom can be created in `project` right now, as the New Workroom menu shows it beside
  /// an entry (#309), or nil when one can: another create holds the project, or it is being deleted.
  func createBlockedReason(in project: Project) -> String? {
    if deletingProjects.contains(project.path) { return "the project is being deleted" }
    if isBusyProject(project.path) { return "a workroom is already being created" }
    return nil
  }

  /// Whether creating a container workroom is on for `project`: not while another create holds it
  /// busy. A remote create holds it only until its workroom has a name.
  func canCreateRemoteWorkroom(in project: Project) -> Bool {
    !isBusyProject(project.path) && !deletingProjects.contains(project.path)
  }

  /// Moves a remote create's progress from its project's row to its new workroom's, once the
  /// workroom has a name: the row shows it, disabled, and the project is free for another create.
  func handOffRemoteCreate(named name: String, in path: String, to row: RemoteCreateRow) async {
    let sid = SidebarID.workroom(project: path, name: name)
    let id = TerminalTarget.workroomID(project: path, name: name)
    // Before the reload, so the row arrives undeletable and with its progress.
    creatingWorkrooms.insert(id)
    createSteps[sid] = createSteps.removeValue(forKey: .project(path))
    await reload()
    // A reload that failed leaves `projects` without this workroom, so its row could not show the
    // progress. The project stays locked, with the progress, until this create ends.
    guard Self.sidebarID(forTargetID: id, in: projects) != nil else {
      creatingWorkrooms.remove(id)
      createSteps[.project(path)] = createSteps.removeValue(forKey: sid)
      return
    }
    imagePulls[path] = nil
    row.workroom = sid
    endBusy(path)
  }

  /// Shows `step` of a remote create on the row that has it now, or nowhere once the create ended.
  func showRemoteCreateStep(_ step: CreateStep, in path: String, row: RemoteCreateRow) {
    if let sid = row.workroom {
      guard case .workroom(_, let name) = sid,
        creatingWorkrooms.contains(TerminalTarget.workroomID(project: path, name: name))
      else { return }
      createSteps[sid] = step
    } else if isBusyProject(path) {
      createSteps[.project(path)] = step
    }
  }

  /// Ends a remote create's progress, on whichever row has it.
  func endRemoteCreate(in path: String, row: RemoteCreateRow) {
    if let sid = row.workroom, case .workroom(_, let name) = sid {
      creatingWorkrooms.remove(TerminalTarget.workroomID(project: path, name: name))
      createSteps[sid] = nil
      // Its status probes skipped it while it was being made, as `createWorkroom`'s do: the create
      // reloaded and selected it while it still was.
      refreshLocalStatus(for: sid)
      scheduleSelectedStatusRefresh()
    } else {
      imagePulls[path] = nil
      createSteps[.project(path)] = nil
      endBusy(path)
    }
  }

  /// Creates a remote workroom for `project` at `place` (#253, #309, #356): a container on this Mac,
  /// or a boxd machine or exe.dev VM, each with its own clone, then selects it, which opens its
  /// first pane on the far side. `splitAnchor` lands it beside that workroom instead, as
  /// `createWorkroom`.
  func createRemoteWorkroom(
    in project: Project, place: RemoteWorkrooms.Place = .container(.docker),
    splitAnchor: SidebarID? = nil
  ) async {
    // As it is now, not as a menu or the picker caught it: its base branch may have changed.
    let project = projects.first { $0.path == project.path } ?? project
    guard canCreateRemoteWorkroom(in: project) else { return }
    beginBusy(project.path)
    let row = RemoteCreateRow()
    defer { endRemoteCreate(in: project.path, row: row) }
    do {
      let key = try await RemoteHosts.shared.key(for: place)
      let (driver, environment) = try RemoteHosts.shared.environment(key)
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
      let cloneURL = RemoteWorkrooms.cloneURL(
        for: repository, origin: await resolver.originURL(in: project.path))
      let path = project.path
      let stepped: @Sendable (RemoteProvisioning.Step) -> Void = { [weak self] step in
        Task { @MainActor in
          self?.showRemoteCreateStep(Self.createStep(step), in: path, row: row)
        }
      }
      let report: @Sendable (Double?) -> Void = { [weak self] fraction in
        Task { @MainActor in
          // A report that arrives after the create ended shows nothing.
          guard let self, self.isBusyProject(path) else { return }
          self.imagePulls[path] = fraction
        }
      }
      // Once the workroom has a name, its own row shows the rest of the create.
      var recorder = remoteRecorder(project: path)
      let reserve = recorder.reserve
      recorder.reserve = { [weak self] hostPath, descriptor in
        let name = try await reserve(hostPath, descriptor)
        await self?.handOffRemoteCreate(named: name, in: path, to: row)
        return name
      }
      // Only a remote provider's create reports steps: a container's are quick, bar its image pull.
      let created = try await RemoteProvisioning.$reportStep.withValue(
        key.isRemoteProvider ? stepped : nil
      ) {
        try await ContainerHostDriver.$pullProgress.withValue(report) {
          // Before the workroom has a name: once it does, its row has the create's progress, and
          // a download's percentage shows only on the project's.
          try await (driver as? ContainerHostDriver)?.ensureHostImage()
          return try await RemoteWorkrooms.create(
            repository: repository, cloneURL: cloneURL,
            startBranch: startBranch, key: key, driver: driver, environment: environment,
            recorder: recorder)
        }
      }
      // Its panes attach through their own ssh; Changes and the rest connect for themselves.
      await created.instance.connection.close()
      await reload()
      selectedProjectID = project.id
      let sid = SidebarID.workroom(project: project.path, name: created.name)
      if let defaultNotUsed {
        noticeStaleStart(
          of: TerminalTarget.workroomID(project: project.path, name: created.name),
          "The default base branch \(defaultNotUsed) can't be used on a remote machine here, so the "
            + "workroom starts from origin's default branch.")
      }
      let landedInSplit =
        splitAnchor.map {
          insertWorkroomSplit(
            sid, beside: $0, edge: .right, destinationRect: workroomPaneRect(for: $0))
        } ?? false
      if !landedInSplit { selectedTargetID = sid }
    } catch {
      await reload()
      present(error)
    }
  }

  /// Drop the pre-name loader, but only if this create still owns it — a later create may have taken
  /// the slot (presentation is newest-wins), and clearing it then would blank that one's loader.
  private func clearPendingCreation(_ session: ScriptLogSession) {
    if pendingCreation?.session.id == session.id { pendingCreation = nil }
  }

  /// Lands on a just-created workroom once it exists (issue #116). Reloads FIRST so the workroom
  /// resolves against `projects` (its real tab chip takes over from the provisional one), then — in one
  /// synchronous step, no `await` in between — records its creation state under its OWN target id, arms
  /// auto-run, and selects it. Idempotent via `landing.claim`: the `onReady` path and the older-CLI
  /// fallback can both call it, and only the first lands. The detail then shows the new workroom's
  /// slot: its setup dialog (script) or, once the create clears its entry, its terminal (no script).
  // `internal` (not `private`) only so `@testable` can drive the closed-box bail path directly. Not
  // called from outside `AppStore`.
  func landOnCreatedWorkroom(
    name: String, project: Project, setup: Bool, session: ScriptLogSession,
    splitAnchor: SidebarID? = nil, landing: CreationLandingBox
  ) async {
    // Claim BEFORE the `creatingWorkrooms` insert below: a create that has already finished (its box
    // closed) must not insert a guard nobody is left to remove — that strands the workroom
    // undeletable, with its status probes suppressed, until relaunch (issue #167, defect 1).
    let id = TerminalTarget.workroomID(project: project.path, name: name)
    guard landing.claim(id) else { return }
    // Drop the project row's creating spinner the moment the workroom exists (issue #116) — the
    // creating slot (its loader, then a setup script's dialog) now carries the progress, so the
    // sidebar indicator is redundant. `created` fires as setup begins, so this is the earlier of the
    // two; `createWorkroom`'s defer covers the case where the workroom never came to exist.
    endBusy(project.path)
    // Mark the workroom "creating" BEFORE the first reload (create-time FSEvents storm fix). The
    // reload's status sweep — and any watch/selection work it triggers — must all observe
    // `isCreating`, or they'd probe/watch the worktree the setup script is actively writing (~70
    // FSEvents callbacks/sec → a git probe storm). Also blocks deletion while setup runs against
    // the worktree (issue #116); `createWorkroom`'s defer clears it when THIS create ends.
    creatingWorkrooms.insert(id)
    // Withhold the terminal in EVERY window for as long as the script runs, and do it BEFORE the
    // reload below publishes the workroom — otherwise the window between `projects` gaining it and
    // `creations[id]` landing (a `list` subprocess wide) is one where any window could mount a shell
    // into the worktree mid-setup (issue #167).
    if setup { settingUpWorkrooms.insert(id) }
    await reload()
    creations[id] = WorkroomCreation(
      session: session, project: project, name: name, targetID: id, hasSetup: setup)
    // Hand the pre-name loader slot over in the SAME synchronous step the entry lands in — not when
    // the whole create ends. The slot is one-at-a-time and newest-wins, so holding it through a setup
    // script would keep this create's provisional "Creating…" chip up (`WorkroomTabBar` prefers
    // `pendingCreation` too) beside the real named chip it just resolved into, and would deny the
    // slot to a second create that has nothing else to show. Clearing it any earlier would blank the
    // detail for the length of the reload above, which is when nothing is selected yet.
    clearPendingCreation(session)
    // Arm auto-run so the workroom's first terminal runs the project command as tab #1 (issue #7). It
    // fires from `ensureInitialTerminal` when the pane mounts — after the setup dialog is dismissed for
    // a setup script, or as soon as the loader clears for a no-setup create — so it runs post-setup.
    let cfg = runConfig(forProject: project.path)
    if cfg.autoRun, cfg.hasCommand { armAutoRun(forWorkroom: id) }
    selectedProjectID = project.id
    let sid = SidebarID.workroom(project: project.path, name: name)
    // Create-as-split (issue #163): land the new workroom BESIDE the anchor the user was on when
    // they picked the project, rather than replacing it. `insertWorkroomSplit` focuses the new
    // member itself, so a successful insert needs no `selectedTargetID` assignment. It returns
    // false — and we fall back to the plain landing — if the anchor was deleted while the create
    // ran, or if the anchor pane can't hold two halves.
    // The new member's pane renders its OWN create (`TargetTerminalDetail` reads
    // `creations[target.id]`) — its own log, its own Dismiss — and since issue #171 that holds for
    // the FOCUSED member too: `focusedCreation` no longer claims the detail for a create that has a
    // target, so the split is on screen from the moment it is in the model (#163 §2c). The new
    // member's title bar drops its Run control for the duration (it reads `creatingWorkrooms`, the
    // set `startRunCommand` itself guards on), because a button that silently does nothing is worse
    // than no button.
    let landedInSplit =
      splitAnchor.map {
        insertWorkroomSplit(
          sid, beside: $0, edge: .right, destinationRect: workroomPaneRect(for: $0))
      } ?? false
    if !landedInSplit { selectedTargetID = sid }
  }

  /// The create that owns the whole detail right now (issue #116), if any — and since issue #171
  /// that is **only** the pre-name loader, shown only when nothing else is selected.
  ///
  /// A create with a target no longer takes the detail: its workroom exists, so it has a pane, and a
  /// pane renders its own create (`TargetTerminalDetail` reads `creations[target.id]` — its own log,
  /// its own Dismiss, under its own title bar). Routing the FOCUSED one full-frame as well unmounted
  /// whatever it was created beside, which is exactly what ⌥⌘N's create-as-split exists to avoid
  /// (#163 §2c): the split was in the model the whole time, just not on screen.
  ///
  /// What is left is the case this was written for: a create still in its PRE-NAME phase has no
  /// target, so there is no pane to draw it in and full-frame is the only option. Scoped to "nothing
  /// selected" because full-frame is a window-wide blackout, and a create is not a reason to take the
  /// window away from a workroom already on screen (issue #167) — with one selected, the sidebar
  /// spinner and the provisional "Creating…" chip carry the progress instead.
  var focusedCreation: WorkroomCreation? {
    // A create whose workroom RESOLVES has a pane, and the pane draws it — nothing goes full-frame.
    guard selectedTarget == nil else { return nil }
    // A failed reload can leave a landed create unresolved. The provisional chip opens this
    // fallback by target id, keeping its setup log reachable until a successful reload.
    if let sid = Self.targetIDString(for: selectedTargetID), let creation = creations[sid] {
      return creation
    }
    return pendingCreation
  }

  /// Whether the detail pane belongs to a create rather than to a terminal — see `focusedCreation`.
  var isCreationFocused: Bool { focusedCreation != nil }

  /// Whether the given target's terminal must stay withheld while its workroom is being created
  /// (issue #116). Keyed on the OPERATION, not on which dialog is on screen: a create superseded in
  /// the presentation slot still withholds its own terminal, so a second create can't let the first's
  /// pane mount over a half-built tree and fire its armed auto-run (issue #167, defect 3).
  ///
  /// A NO-setup create withholds too, for the length of its loader (issue #171). It used to be exempt
  /// — its dialog-less create was over in a moment and its pane wasn't mounted anyway, because the
  /// focused create owned the whole detail. Now that every landed create renders inside its pane, that
  /// pane mounts the instant the workroom exists, which is still inside `createWorkroom` —
  /// `creatingWorkrooms` holds the id until the `defer`, so `ensureInitialTerminal` would consume the
  /// armed auto-run (issue #7) and hand it to a `startRunCommand` that bails on exactly that guard.
  /// Silently losing the auto-run. The entry clears one synchronous step before the `defer` does, so
  /// withholding until then costs nothing and closes that window.
  ///
  /// Two sources, because the operation outlives this window's record of it:
  /// - `settingUpWorkrooms` (SHARED) covers the script's actual run, in EVERY window — including the
  ///   ones that never started it, and including the window between the landing's `reload()`
  ///   publishing the workroom and this window's own entry landing a line later.
  /// - `creations` (per-window) then keeps it withheld past the script, until THIS window's dialog is
  ///   dismissed — that part is per-window by definition, since the dialog is.
  func isCreationBlocking(_ targetID: TerminalTarget.ID) -> Bool {
    settingUpWorkrooms.contains(targetID) || creations[targetID] != nil
  }

  /// Whether a run must NOT be started for this target right now — the single predicate the
  /// chokepoint (`startRunCommand`) and every Run affordance read, so an offered button and a
  /// refused action can never disagree (issue #171).
  ///
  /// The union is load-bearing; neither half covers the other. `creatingWorkrooms` clears in
  /// `createWorkroom`'s `defer`, which fires the moment the CLI returns — but a setup script's
  /// dialog stays up until the user dismisses it, and that window is arbitrarily long. A run
  /// started there launches against a pane whose terminal is still withheld, and worse, it
  /// overwrites the ARMED auto-run: `ensureInitialTerminal` then sees a non-empty tab list, skips
  /// `addTab`, and the workroom lands with a run tab and no shell at all, silently breaking issue
  /// #7's "backgrounded run as tab #1, focused shell as tab #2" contract. `isCreationBlocking`
  /// alone is not enough either — during the landing's `reload()` a no-setup create holds
  /// `creatingWorkrooms` while neither `settingUpWorkrooms` nor `creations` is set yet.
  func isRunBlocked(_ targetID: TerminalTarget.ID) -> Bool {
    creatingWorkrooms.contains(targetID) || isCreationBlocking(targetID)
  }

  /// Whether `workroom` has an in-flight create (its setup is running) — the delete affordances
  /// disable while this holds so it can't be torn down mid-setup (issue #116). Shared across windows.
  func isCreatingWorkroom(_ workroom: Workroom, in project: Project) -> Bool {
    creatingWorkrooms.contains(
      TerminalTarget.workroomID(project: project.path, name: workroom.name))
      // A remote create (#253) is in this set from just after its workroom has a name; until then,
      // its project busy says so. One a crash left at `creating` is deletable.
      || (workroom.host?.state == "creating" && isBusyProject(project.path))
  }

  /// Dismiss ONE workroom's setup dialog after its setup script (or its failure) — the user clicked
  /// that dialog's Dismiss. Clearing its entry drops the dialog and lets its withheld terminal mount
  /// (issue #116). Takes the target so a co-displayed pane's Dismiss clears its own create, never a
  /// concurrent one's (issue #167, defect 4).
  func dismissCreation(_ targetID: TerminalTarget.ID) {
    creations[targetID] = nil
  }
}

/// Tracks a create-in-progress for the initiating window (issue #116). `session` streams setup
/// output into that create's OWN dialog; `name`/`targetID` are nil only in the pre-name slot
/// (`AppStore.pendingCreation`) and set for every entry in `AppStore.creations`, which is keyed on
/// that same id; `hasSetup` gates the dialog's dismissal contract — a setup script keeps the Dismiss
/// button and withholds the terminal, while a no-setup create auto-dismisses. A value type: mutating
/// a field republishes the map it lives in.
struct WorkroomCreation {
  let session: ScriptLogSession
  let project: Project
  /// The CLI-generated workroom name, once the "created" event arrives (nil while still creating).
  var name: String?
  /// The mounted target id, once known — added to the workroom-tab active set so the real chip shows
  /// during setup, and matched by `isCreationBlocking` to withhold its terminal.
  var targetID: TerminalTarget.ID?
  /// Whether a setup script is (or was) running — set from the "created" event, and forced true on a
  /// post-create failure so the dialog stays up with a Dismiss button.
  var hasSetup = false
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
/// workroom" task from `createWorkroom`'s `onReady` closure back to `createWorkroom` itself, so the
/// flow can await the landing instead of racing it, and it carries the landed target id — the single
/// answer to "which workroom is THIS create's", which every release point keys on rather than reading
/// whichever create currently owns the presentation slot.
///
/// A box is needed because `onReady` is a *synchronous* callback the CLI invokes from whichever thread
/// it is parsing on — it can start the task but cannot await it. Locked rather than actor-isolated so
/// `set`/`claim` stay synchronous: registration has to be complete when `onReady` returns.
final class CreationLandingBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var landed: TerminalTarget.ID?
  private var isClosed = false

  /// The target this create landed on, or nil if it never got that far (a failure before the workroom
  /// existed). `createWorkroom`'s release points key on this.
  var landedID: TerminalTarget.ID? {
    lock.lock()
    defer { lock.unlock() }
    return landed
  }

  /// Take ownership of `id` for this create, once. False when the create has already landed (the
  /// `onReady` path and the older-CLI fallback both call the landing) or has already ended — the
  /// caller must then record nothing, since nobody is left to undo it.
  func claim(_ id: TerminalTarget.ID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, landed == nil else { return false }
    landed = id
    return true
  }

  /// The create has ended — refuse any further landing. Separate from `finish()`, which the flow calls
  /// BEFORE its older-CLI fallback landing.
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

  /// Await the registered landing. A no-op when the CLI never fired its "created" event (an older CLI,
  /// or a failure before the workroom existed) — `createWorkroom`'s own fallback covers that case.
  func finish() async {
    let pending = lock.withLock { task }
    await pending?.value
  }
}
