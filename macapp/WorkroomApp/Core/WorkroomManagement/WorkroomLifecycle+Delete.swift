import Foundation
import WorkroomDomain
import WorkroomVCS

/// Deleting workrooms and projects (issues #7, #70, #116, #253, #287): each asked from one window
/// (its `LifecycleWindow`), which asks the questions and shows the alerts, and taken out of every
/// window at once (`removeFromWindows`, `stopRuns`, `reap`) before its teardown runs.
extension WorkroomLifecycle {
  // MARK: Workrooms

  /// Removes the workroom from the sidebar immediately, then runs its teardown (script +
  /// workspace removal) in the background. On success the optimistic removal already
  /// matches reality; on failure we reload (so it reappears if it still exists) and
  /// surface the error in `window`.
  /// `skipTeardown` runs no teardown script: Delete Anyway, after the script failed.
  func deleteWorkroom(
    _ workroom: Workroom, in project: Project, skipTeardown: Bool = false,
    from window: any LifecycleWindow
  ) {
    let sid = SidebarID.workroom(project: project.path, name: workroom.name)
    let targetID = TargetID.workroom(project: project.path, name: workroom.name)
    // Don't delete a workroom whose create is still in flight (issue #116) — its setup script is
    // running against the worktree, so tearing it down now would race the script. The delete
    // affordances are disabled while creating; this is the chokepoint that guarantees it.
    guard !isCreatingWorkroom(workroom, in: project) else { return }
    // A remote workroom's delete takes its host down (#253): what that needs is checked before the
    // optimistic removal below forgets its label. A host its provider says is gone (`GoneHosts`,
    // #629) runs no teardown there, and is forgotten only once its provider's destroy confirms it
    // (`RemoteWorkrooms.delete`'s `hostGone`); a provider that can't be asked is logged, and that
    // delete keeps the workroom, saying why.
    let hostGone = GoneHosts.shared.contains(workroom.host?.id)
    var remote: RemoteProvisioning.Environment?
    if let host = workroom.host {
      do {
        remote = try RemoteHosts.shared.registry.environment(
          toDelete: [host], gone: hostGone ? Set([host.id].compactMap { $0 }) : []
        )?.environment(for: host)
      } catch {
        window.present(error)
        window.modals.errorTitle = "Can't delete \(workroom.displayName)"
        return
      }
    }
    // Was the deleted workroom the one selected in the asking window? Captured before
    // `removeFromWindows` mutates selection, so the issue #80 fallback below can re-point only when
    // the delete left it with nothing selected (a solo selected workroom — a split member yields to
    // its survivor).
    let wasSelectedHere = window.selectedTargetID == sid
    // Optimistic shared-model removal, visible in every window: drop it from the project list and its
    // shared VCS/CI status now (snappy UI). Terminals stay alive for the graceful stop; the reap +
    // VCS teardown follow once the process exits, so a dev server isn't orphaned against a deleted dir.
    // Tombstone it first so a concurrent reload's stale `list` snapshot can't resurrect it (the
    // create/delete race) — `apply` filters tombstoned workrooms until the teardown completes.
    deletingWorkrooms.insert(targetID)
    window.removeWorkroomLocally(workroom, in: project)
    vcsStatus.workroomStatuses[sid] = nil
    // Out of EVERY window's split + selection, with its create's run (issue #70, OV #7).
    removeFromWindows([sid])
    // If deleting the selected workroom left the asking window with no selection (the solo case — a
    // split member already yielded to its survivor, so selection is non-nil and we skip), land on the
    // rightmost remaining tab rather than the bare launch state — the same fallback closing the last
    // panel uses (issue #80). `displayedWorkroomTargets` already excludes the just-removed workroom.
    window.reselectAfterWorkroomDetached(wasSelectedHere: wasSelectedHere)
    // Ctrl-C the run command and reap the surfaces in every window that held this workroom, then run
    // the VCS teardown once — no dev server in any window left running against the deleted directory
    // (issue #7/#70). No live run command anywhere → immediate.
    // The asking window is held until the teardown starts, as the old `affectedStores` capture did.
    stopRuns([targetID]) {
      await self.reap([targetID])
      self.startWorkroomTeardown(
        workroom, in: project, remote: remote, skipTeardown: skipTeardown, hostGone: hostGone,
        from: window)
    }
  }

  /// Run the VCS teardown (worktree/workspace removal) in the background, surfacing any failure with
  /// its captured output in an alert. Split out of `deleteWorkroom` so the run command can stop first
  /// (issue #7) — the worktree must not be deleted while its dev server still holds the directory.
  private func startWorkroomTeardown(
    _ workroom: Workroom, in project: Project, remote: RemoteProvisioning.Environment?,
    skipTeardown: Bool, hostGone: Bool, from window: any LifecycleWindow
  ) {
    let targetID = TargetID.workroom(project: project.path, name: workroom.name)
    Task {
      let log = ScriptLogSession(title: "Tearing down \(workroom.name)", phase: "teardown")
      do {
        if let host = workroom.host {
          try await RemoteWorkrooms.delete(
            workroom.name, host: host, environment: remote,
            recorder: remoteRecorder(project: project.path, cli: window.services.cli),
            teardown: Self.remoteTeardown(
              of: workroom, in: project, log: log, skip: skipTeardown, cli: window.services.cli),
            hostGone: hostGone, onForgotten: Self.forgetRemote)
        } else {
          try await window.services.cli.delete(
            name: workroom.name, project: project.path, skipTeardown: skipTeardown
          ) { text in
            DispatchQueue.main.async { log.append(text) }
          }
        }
        // Teardown persisted (the workroom is gone from config). Reload BEFORE lifting the
        // tombstone: a read issued before config dropped the workroom could otherwise publish it
        // once the tombstone is gone (#295). This newer read supersedes it. Quiet: a failed `list`
        // must not report a delete that succeeded as an error.
        await window.load(warnings: "fast", surfaceErrors: false)
        deletingWorkrooms.remove(targetID)
        await runHeldHostSweep(from: window)
      } catch {
        // Teardown failed → the workroom still exists. Clear the tombstone BEFORE reloading so the
        // reload's `apply` doesn't filter it out — it must reappear in the sidebar.
        deletingWorkrooms.remove(targetID)
        await window.reload()
        presentTeardownFailure(workroom, in: project, error: error, log: log, from: window)
      }
    }
  }

  /// A remote workroom's teardown script, run on its host before the host goes, its output into
  /// `log`: the checkout's copy, else the project root's.
  nonisolated static func remoteTeardown(
    of workroom: Workroom, in project: Project, log: ScriptLogSession?, skip: Bool,
    cli: any WorkroomCLIProtocol
  ) -> RemoteWorkrooms.Teardown {
    RemoteWorkrooms.Teardown(
      path: workroom.path,
      rootScript: URL(fileURLWithPath: project.path + "/scripts/workroom_teardown"), skip: skip,
      judge: judge(.teardown, in: project.path, cli: cli),
      onLine: { line in DispatchQueue.main.async { log?.append(line) } })
  }

  /// What a remote delete let go of, forgotten by the app's models of it too, at the step the
  /// delete let it go: a gone host's port forwards and program status; an SSH workroom's own port
  /// forwards; an SSH host's program status once its last workroom is gone.
  static func forgetRemote(_ forgotten: RemoteWorkrooms.Forgotten) {
    switch forgotten {
    case .host(let host):
      PortForwardingModel.forgetHost(host)
      ProgramStatusMonitor.shared.forget(host)
    case .workroom(let workroom, let host):
      PortForwardingModel.forgetWorkroom(workroom, on: host)
    case .lastWorkroom(let host):
      ProgramStatusMonitor.shared.forget(host)
    }
  }

  /// Teardown failed (it ran in the background): the error sheet says why (which script, and that it
  /// exited non-zero), with what the script printed in a scrolling box beneath.
  private func presentTeardownFailure(
    _ workroom: Workroom, in project: Project, error: Error, log: ScriptLogSession,
    from window: any LifecycleWindow
  ) {
    let modals = window.modals
    window.present(error)
    modals.errorTitle = "Teardown of ‘\(workroom.name)’ failed"
    modals.errorLog = Self.scriptOutput(log)
    if workroom.isSSH {
      modals.errorDetails =
        (modals.errorDetails ?? "") + "\nDelete Anyway removes this workroom from Workroom. "
        + "The folder \(workroom.path) on \(workroom.host?.sshDestination ?? "its SSH host") may remain."
    } else {
      guard Self.isTeardownFailure(error) else { return }
    }
    let name = workroom.name
    let path = project.path
    // As it is now, after the failure's reload, not as it was when the delete began.
    let deleteAgain = { [weak window] (skipTeardown: Bool) in
      guard let window, let project = self.projectStore.project(at: path),
        let workroom = project.workrooms.first(where: { $0.name == name })
      else { return }
      self.deleteWorkroom(workroom, in: project, skipTeardown: skipTeardown, from: window)
    }
    let deleteAnyway = ErrorAction(label: "Delete Anyway") { deleteAgain(true) }
    modals.errorAction = deleteAnyway
    guard let script = Self.untrustedTeardown(error) else { return }
    // The CLI's own message tells a terminal what to type: say why the delete stopped, in the app's
    // terms. A new message drops what was set after it, so the rest goes back after.
    let details = modals.errorDetails
    modals.errorMessage = Self.teardownApprovalMessage(
      script, workroom: workroom.displayName, project: project)
    modals.errorDetails = details
    modals.errorAction = deleteAnyway
    // The script never ran, so it printed nothing: its text is what to read before approving it.
    modals.errorTitle = "Approve the teardown script?"
    modals.errorLog = script.visibleText
    modals.errorScriptName = script.name
    let cli = window.services.cli
    modals.errorApproval = ErrorAction(label: "Approve") { [weak window] in
      Task {
        do {
          try await cli.trustScript(script.name, text: script.approvalBytes, project: path)
          deleteAgain(false)
        } catch {
          window?.present(error)
          window?.modals.errorTitle = "Couldn't approve the teardown script"
        }
      }
    }
  }

  /// Why a delete stopped on a teardown script this Mac has not approved (#363), which workroom of
  /// which project, and the ways on, as the creation pane words its setup script.
  nonisolated static func teardownApprovalMessage(
    _ script: ScriptTrust, workroom: String, project: Project
  ) -> String {
    "Deleting ‘\(workroom)’ in \(project.displayName) runs scripts/\(script.name) "
      + "\(script.originLabel) first, and it is new, or changed since it was approved on this Mac. "
      + "Read it, then approve it to run it and delete the workroom, or delete without running it."
  }

  /// The teardown script a delete refused, when this Mac has not approved it (#363).
  nonisolated static func untrustedTeardown(_ error: Error) -> ScriptTrust? {
    if case RemoteWorkrooms.Failure.teardownScriptNotTrusted(let script) = error { return script }
    return WorkroomCLIError.untrustedScript(error)
  }

  /// Whether a delete failed in its teardown script, so Delete Anyway (no script) can get it
  /// through: the script failed or couldn't start, ran out of time, its host couldn't be reached,
  /// or this Mac has not approved it. A failure elsewhere (git, config) would fail the same way
  /// without the script.
  nonisolated static func isTeardownFailure(_ error: Error) -> Bool {
    // ScriptNotTrusted without its script: one Workroom won't read (a device, over 1 MiB).
    if case WorkroomCLIError.cli(let kind, _) = error {
      return kind == "TeardownScriptFailed" || kind == "ScriptNotTrusted"
    }
    if case WorkroomCLIError.timedOut = error { return true }
    if case RemoteWorkrooms.Failure.teardownScriptFailed = error { return true }
    return untrustedTeardown(error) != nil
  }

  /// A run's captured script output, or nil when it printed nothing.
  private static func scriptOutput(_ log: ScriptLogSession?) -> String? {
    let output = (log?.lines.map(\.text).joined(separator: "\n") ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
  }

  /// Runs the remote-host sweep a reload held back while a delete was in flight (#296), once the
  /// last tombstone lifts, through `window`'s load. It reads config afresh rather than trusting
  /// `projects`, which can still hide a failed sibling delete's hosts when that delete's own reload
  /// failed. A failed delete's reload does this itself, and `apply` holds the sweep again if another
  /// delete has begun.
  private func runHeldHostSweep(from window: any LifecycleWindow) async {
    guard deletingProjects.isEmpty, deletingWorkrooms.isEmpty,
      RemoteHosts.shared.registry.sweepHeld
    else { return }
    await window.load(warnings: "fast", surfaceErrors: false)
  }

  // MARK: Projects

  /// Removes a project from the sidebar immediately, then runs the chosen `scope` in the
  /// background. Mirrors `deleteWorkroom`: optimistic removal + scoped selection/split/status
  /// cleanup, then graceful run-stop → in-app reap → CLI.
  ///
  /// - `.configOnly`: drop from config only; nothing on disk is touched.
  /// - `.workrooms`: also hard-delete every workroom's worktree dir (branches kept) — unchanged.
  /// - `.fromDisk`: the CLI runs teardowns + drops config and returns the directories
  ///   (project root + workrooms); the app then moves them to the **Bin** (issue #108).
  ///
  /// Failure handling differs by phase: if the CLI throws (teardown/guard failure, or a
  /// config-only/workrooms delete failure) the config was NOT changed, so we `reload()` (the
  /// project reappears if it still exists) and surface the error in `window`. For `.fromDisk`, once
  /// the CLI returns the config is already dropped — a subsequent Trash failure leaves the project
  /// removed and is reported on its own (we do NOT restore it), listing the dirs left behind.
  /// `skipTeardown` runs no workroom's teardown script: Delete Anyway, after one failed.
  func deleteProject(
    _ project: Project, scope: DeleteProjectScope, skipTeardown: Bool = false,
    from window: any LifecycleWindow
  ) {
    // Refuse while anything is being created in this project (issue #167). `deleteWorkroom` has
    // guarded its own target since issue #116, but nothing guarded the PROJECT — so a project could
    // be torn down (`--from-disk` trashes the project root itself) while a setup script was writing a
    // worktree underneath it, and the in-flight landing would then resume and record creation state
    // for a project that no longer exists. Unlike `deleteWorkroom`'s silent `return`, this one speaks:
    // the user just typed the project name to confirm, so a no-op would read as a broken button.
    // O1 (#483): any running create, named or not. Before it has a name, nothing else says so.
    let creatingHere = creatingWorkrooms.contains {
      projectStore.sidebarID(for: $0)?.belongsToProject(project.path) == true
    }
    guard !hasRunningCreation(inProject: project.path), !creatingHere else {
      window.modals.errorTitle = "Can't delete \(project.displayName)"
      window.modals.errorMessage =
        "A workroom is still being created in this project. Wait for it to finish, then try again."
      return
    }
    // Another window's confirm dialog can outlive the first delete (#287).
    guard !deletingProjects.contains(project.path) else {
      window.modals.errorTitle = "Can't delete \(project.displayName)"
      window.modals.errorMessage = "\(project.displayName) is already being deleted."
      return
    }
    // Every scope takes the project's remote workrooms and its base down (#253), even config-only:
    // with its record dropped, a box would be left to the next launch's sweep.
    // What that needs is checked here, before the local cleanup below kills this project's shells
    // and forgets its labels.
    let remoteWorkrooms = project.workrooms.filter(\.isRemote)
    // Those whose provider says their host is gone: no teardown runs there (#629).
    let goneHosts = Set(remoteWorkrooms.compactMap(\.host?.id).filter(GoneHosts.shared.contains))
    // An older build's bases that launch has not retired yet (its provider signed out, say).
    let bases = BaseRetirement.bases(of: project.host)
    let remote: HostDriverRegistry.Deletion?
    do {
      // A gone host's provider can't stop the delete, as in Remove Workroom (`deleteWorkroom`).
      remote = try RemoteHosts.shared.registry.environment(
        toDelete: remoteWorkrooms.compactMap(\.host) + bases, gone: goneHosts)
    } catch {
      window.present(error)
      window.modals.errorTitle = "Can't delete \(project.displayName)"
      return
    }
    // Tombstone it so a reload while the teardown runs can't republish it (#287), the project-level
    // twin of `deleteWorkroom`'s. Lifted once config has dropped it, or before the failure reload.
    deletingProjects.insert(project.path)
    let targetIDs = window.removeProjectLocally(project)
    // Clear the project's targets (root + each workroom) from every other window's split + selection
    // too — `removeProjectLocally` only cleaned up the asking window, which has none of them left to
    // clear (issue #70, OV #7).
    removeFromWindows(
      [SidebarID.root(project: project.path)]
        + project.workrooms.map { SidebarID.workroom(project: project.path, name: $0.name) })

    // ALWAYS stop runs in every window BEFORE any disk teardown so no dev server holds a deleted dir
    // (issue #7/#70), then reap each target in every window, then run the CLI teardown once.
    // The asking window is held until the teardown ends, as the old `affectedStores` capture did.
    stopRuns(targetIDs) {
      await self.reap(targetIDs)
      // Every scope destroys remote workrooms' machines, each after its teardown, so any delete
      // with one keeps a log; config-only runs no local teardown.
      let log =
        scope == .configOnly && remoteWorkrooms.isEmpty
        ? nil : ScriptLogSession(title: "Deleting \(project.displayName)", phase: "teardown")
      do {
        // The CLI refuses a project with remote entries in every mode, and `--from-disk` would
        // hand a remote path to the Bin, so they go first: the workrooms, then the base, since
        // config keeps a project with a base when its last workroom is removed.
        let recorder = self.remoteRecorder(project: project.path, cli: window.services.cli)
        for workroom in remoteWorkrooms {
          guard let host = workroom.host else { continue }
          try await RemoteWorkrooms.delete(
            workroom.name, host: host, environment: remote?.environment(for: host),
            recorder: recorder,
            teardown: Self.remoteTeardown(
              of: workroom, in: project, log: log, skip: skipTeardown, cli: window.services.cli),
            hostGone: host.id.map(goneHosts.contains) ?? false, onForgotten: Self.forgetRemote)
        }
        // Each base on its own runtime and context (#309). Config keeps the ones still to go, so
        // a failure part-way leaves what is live recorded for the next delete.
        let cli = window.services.cli
        var effects = BaseRetirement.live(cli: cli)
        effects.destroy = { base in
          guard let id = base.id, let environment = remote?.environment(for: base) else {
            throw RemoteWorkrooms.Failure.signedOut
          }
          try await RemoteProvisioning.tearDown(host: .remote(id), in: environment)
        }
        _ = try await BaseRetirement.retireBases(of: project, effects: effects)
        // What that leaves can't be told apart (no id) or is another build's and not live (a live
        // one was refused above): the record goes with the project.
        if bases.contains(where: { $0.id == nil || !RemoteWorkrooms.ownsHost($0) }) {
          try await cli.setHost(project: project.path, workroom: nil, descriptor: nil)
        }
        let trashPaths = try await window.services.cli.deleteProject(
          project.path,
          withWorkrooms: scope == .workrooms,
          fromDisk: scope == .fromDisk, skipTeardown: skipTeardown
        ) { text in DispatchQueue.main.async { log?.append(text) } }
        if scope == .fromDisk {
          // CLI already ran teardowns + dropped config; move the returned dirs to the Bin.
          // Before the reload below suspends, so nothing can re-register them in between.
          let failed = self.trashToBin(trashPaths, from: window)
          if !failed.isEmpty {
            self.presentTrashFailure(project, failedPaths: failed, in: window.modals)
          }
        }
        // Reload BEFORE lifting the tombstone: a read issued before config dropped the project
        // could otherwise publish it once the tombstone is gone. This newer read supersedes it.
        // Quiet: a failed `list` must not report a delete that succeeded as an error.
        await window.load(warnings: "fast", surfaceErrors: false)
        self.deletingProjects.remove(project.path)
        await self.runHeldHostSweep(from: window)
      } catch {
        // Before the reload, so the project (still in config) reappears.
        self.deletingProjects.remove(project.path)
        await window.reload()
        self.presentDeleteProjectFailure(
          project, scope: scope, error: error, log: log, from: window)
      }
    }
  }

  /// Moves each path to the Bin via `window`'s injected `services.trasher`, returning the URLs that
  /// could NOT be moved so the caller can tell the user exactly what was left behind. The project is
  /// already out of config by this point (the CLI dropped it), so a partial failure does not restore
  /// it. Internal (not private) so the from-disk trash orchestration is unit-testable with a fake.
  func trashToBin(_ urls: [URL], from window: any LifecycleWindow) -> [URL] {
    var failed: [URL] = []
    for url in urls {
      do { try window.services.trasher.trash(url) } catch { failed.append(url) }
    }
    return failed
  }

  /// A from-disk delete dropped the project from config but some directories could not be moved to
  /// the Bin. Report which ones, in the window whose `modals` these are, so the user can move them
  /// manually (they are not lost).
  func presentTrashFailure(_ project: Project, failedPaths: [URL], in modals: ModalState) {
    let list = failedPaths.map(\.path).joined(separator: "\n")
    modals.errorTitle = "Some files of ‘\(project.displayName)’ could not be moved to the Bin"
    modals.errorMessage =
      "‘\(project.displayName)’ was removed from Workroom, but these could not be moved to the "
      + "Bin — move them manually:\n\(list)"
  }

  /// Project deletion failed in the background: the error sheet says why, with any captured cascade
  /// teardown output in a scrolling box beneath. `log` is nil for a config-only delete (no teardown
  /// ran), which shows the error alone.
  private func presentDeleteProjectFailure(
    _ project: Project, scope: DeleteProjectScope, error: Error, log: ScriptLogSession?,
    from window: any LifecycleWindow
  ) {
    let modals = window.modals
    window.present(error)
    modals.errorTitle = "Delete of ‘\(project.displayName)’ failed"
    modals.errorLog = Self.scriptOutput(log)
    let ssh = project.workrooms.filter(\.isSSH)
    guard Self.isTeardownFailure(error) || !ssh.isEmpty else { return }
    if !ssh.isEmpty {
      modals.errorDetails =
        (modals.errorDetails ?? "") + "\nFolders that can't be removed will stay on their hosts:\n"
        + ssh.map { "\($0.path) on \($0.host?.sshDestination ?? "its SSH host")" }.joined(
          separator: "\n")
    }
    let path = project.path
    // Says what it does: every remaining workroom's teardown is skipped, not only the one that
    // failed, as the CLI's `delete-project --skip-teardown` does.
    modals.errorAction = ErrorAction(label: "Delete Without Teardowns") {
      [weak window] in
      // As it is now: a remote workroom taken down before the failure is gone from it (C4).
      guard let window, let project = self.projectStore.project(at: path) else { return }
      self.deleteProject(project, scope: scope, skipTeardown: true, from: window)
    }
  }
}
