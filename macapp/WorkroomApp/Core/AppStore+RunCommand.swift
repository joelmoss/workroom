import AppKit
import Defaults
import Foundation
import WorkroomDomain
import WorkroomSystem

/// The run command (issue #7): starting, restarting and respawning a workroom's run command under
/// its supervisor, applying the supervisor's status, the run toast list and native banner (issue
/// #67), and the selection-scoped Run, Stop and Restart actions. These read the store (projects,
/// run config, selection, host layout, `pendingProjectSettings`, `systemNotifier`), so they stay
/// here. The run state itself, the toast dismissal, the supervisor's pid and session handling and
/// the graceful teardown live in `RunCommandController`, which the store owns as `runCommand`.
extension AppStore {
  // MARK: Run command (issue #7)

  /// The run toasts to show right now. Derived each access: a target contributes a toast when it has a
  /// run state with a tab, the user hasn't dismissed it, and its run tab isn't currently on screen
  /// (you don't need a toast for what you're looking at — split-aware via `visibleTabIDs`).
  var runToastItems: [RunToastItem] {
    runStates.compactMap { targetID, state -> RunToastItem? in
      guard let tabID = state.tab else { return nil }  // .armed has no tab → no toast
      guard !dismissedRunToasts.contains(targetID) else { return nil }
      // Map state → toast status. A user-initiated stop (Stop/Restart/Ctrl-C → `.stoppedByUser`, or
      // a stop with no recorded outcome) shows NO toast at all (issue #79): the toast only ever marks
      // a self-exit (success or failure) or a failed start.
      let status: RunToastItem.Status
      switch state {
      case .armed: return nil
      case .running: status = .running
      case .restarting: status = .restarting
      case .stopped:
        switch runOutcomes[targetID] {
        case .exited(let code): status = code == 0 ? .exited : .failed(code: code)
        case .failedToStart: status = .failedToStart
        case .stoppedByUser, .none: return nil  // user-initiated stop/restart/Ctrl-C → no toast
        }
      }
      // Live status (running/restarting) shows ONLY for the SELECTED workroom's backgrounded run:
      // you don't need a "still running" reminder for workrooms you aren't even looking at (issue
      // #73 — one live toast for the run you're in, not one per open workroom with a run), nor for
      // the run tab you're currently watching (split-aware via `visibleTabIDs`), nor once it's
      // auto-hidden after lingering a while (a server never reaches a terminal state, so without
      // this it would show forever — sidebar/tab-bar indicators keep conveying "still running").
      // Terminal statuses (a success or failure exit) ALWAYS show — even for a background workroom,
      // so you learn it finished/crashed (issue #79: "show a success/failure toast"); they linger
      // then auto-dismiss, independent of `runningToastAutoHidden`.
      if !status.isTerminal {
        guard let target = selectedTarget, target.id == targetID,
          !terminals.visibleTabIDs(for: target).contains(tabID),
          !runningToastAutoHidden.contains(targetID)
        else { return nil }
      }
      let command =
        project(forTargetID: targetID).map {
          runConfig(forProject: $0.path).command.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
      return RunToastItem(
        targetID: targetID, tabID: tabID, source: notificationSource(forTargetID: targetID),
        command: command, status: status)
    }
    .sorted { $0.targetID < $1.targetID }  // stable order across renders
  }

  /// "Open terminal" on the run toast: jump to the run terminal. The toast then hides because its tab
  /// is on screen (visibility rule) — NOT dismissed, so it reappears if you navigate away.
  func openRunToast(for targetID: TerminalTarget.ID) {
    guard let tabID = runStates[targetID]?.tab else { return }
    openTerminal(targetID: targetID, tabID: tabID)
  }

  /// Post a native banner for a backgrounded run that FAILED, but only while the app isn't frontmost —
  /// the in-app toast is invisible then (Arch #7, issue #67). Reuses `NotificationGate` +
  /// `SystemNotifier`; the synthesized notification is NOT added to the inspector history (run status
  /// is transient). A click routes through `openTerminal` via the payload's `userInfo`.
  private func postRunFailureBannerIfBackgrounded(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, title: String, body: String
  ) {
    guard NotificationGate.shouldPostBanner(recorded: true, appActive: NSApp.isActive) else {
      return
    }
    let note = WorkroomNotification(
      id: UUID(), targetID: targetID, tabID: tabID,
      source: notificationSource(forTargetID: targetID), title: title, body: body, date: Date(),
      count: 1)
    Task { @MainActor in
      if await systemNotifier.ensureAuthorized() { systemNotifier.post(note) }
    }
  }

  /// The owning project of a target by id (mirrors `notificationSource`'s scan) — for the run toast's
  /// command label.
  func project(forTargetID id: TerminalTarget.ID) -> Project? {
    projects.first { p in
      TerminalTarget.rootID(project: p.path) == id
        || p.workrooms.contains { TerminalTarget.workroomID(project: p.path, name: $0.name) == id }
    }
  }

  /// The run config for a project path (empty if none set). Single read path for the toolbar, menu,
  /// settings sheet, and auto-run. Stored app-side in `Defaults` (GUI-only — the CLI can't hold a
  /// long-running process, so it's deliberately out of the `--json` contract, like branch labels).
  func runConfig(forProject projectPath: String) -> RunConfig {
    _ = runConfigRevision  // a read Observation tracks: `Defaults` itself is not observable
    return Defaults[.runCommands][projectPath] ?? .empty
  }

  /// Whether a project has a non-blank run command configured.
  func hasRunCommand(forProject projectPath: String) -> Bool {
    runConfig(forProject: projectPath).hasCommand
  }

  /// Whether to surface run controls for a target: its project has a command configured AND
  /// `startRunCommand` would actually start one (`isRunBlocked`). One gate for the sidebar run
  /// buttons and the ⌘R menu item, so a new condition lands in a single place (review #9/#14).
  ///
  /// The non-config clauses mirror that function's own guards, which is the point — a Run button
  /// offered where pressing it silently returns is worse than no button. A missing directory was
  /// always one; a workroom still being created became one in issue #167 and went unreflected here
  /// (issue #171). The pane title bar's Run shares `isRunBlocked` but not this predicate, since it
  /// deliberately shows for a target with no command configured (issue #139).
  func canRunCommand(for target: TerminalTarget, inProject projectPath: String) -> Bool {
    !target.isMissing && !isRunBlocked(target.id) && hasRunCommand(forProject: projectPath)
  }

  /// The app-wide base branch for projects that name none; nil means origin's default branch.
  var globalBaseBranch: String? { projectStore.globalBaseBranch }

  /// The base branch `project`'s new workrooms start from: its own, else the app-wide one, else nil
  /// for origin's default branch. The CLI applies the same rule to a local create.
  func effectiveBaseBranch(for project: Project) -> String? {
    project.baseBranch ?? globalBaseBranch
  }

  /// Set the branch a project's new workrooms start from (nil or blank: origin's default branch),
  /// through the CLI, which owns it so `workroom create` in a terminal agrees.
  func setBaseBranch(_ branch: String?, forProject projectPath: String) async {
    let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try await cli.setBaseBranch(
        project: projectPath, branch: trimmed?.isEmpty == false ? trimmed : nil)
    } catch {
      present(error)
    }
    await reload()
  }

  /// Persist a project's run config. A blank command with auto-run off removes the entry so the map
  /// doesn't accrue dead keys. Bumps `runConfigRevision` so the toolbar/menu re-render
  /// `hasRunCommand` the moment Save commits (those consumers observe this store — issue #7
  /// reactivity, OV-A).
  func setRunConfig(_ config: RunConfig, forProject projectPath: String) {
    runConfigRevision += 1
    var map = Defaults[.runCommands]
    if config.hasCommand || config.autoRun {
      map[projectPath] = RunConfig(
        command: config.command.trimmingCharacters(in: .whitespacesAndNewlines),
        autoRun: config.autoRun)
    } else {
      map[projectPath] = nil
    }
    Defaults[.runCommands] = map
  }

  // MARK: Run command — actions (issue #7)

  /// The owning project of a terminal target (root or workroom), by matching the live project list.
  ///
  /// Compares **ids only** — same as `sidebarID(forTarget:)` below. Materialising `rootTarget`
  /// here would `stat` every project directory on the render path (`TerminalStatusBar.body` →
  /// `branchLabel` → here), which is what hung the app in WORKROOM-3D. A lookup never needs the
  /// `isMissing`/`title` a target carries.
  private func project(forTarget target: TerminalTarget) -> Project? {
    projects.first { p in
      TerminalTarget.rootID(project: p.path) == target.id
        || p.workrooms.contains {
          TerminalTarget.workroomID(project: p.path, name: $0.name) == target.id
        }
    }
  }

  /// The current branch label for a terminal target, for the detail-panel status bar (issue
  /// #49). Reuses the already-resolved sidebar caches — the per-workroom local status (`branchForCI`)
  /// and the project root's `RootRef` — so it adds no new VCS calls. Nil until those resolve, or when
  /// no branch is resolvable (the status bar then just omits the segment).
  func branchLabel(for target: TerminalTarget) -> String? {
    guard let sid = sidebarID(forTarget: target) else { return nil }
    return branchName(for: sid)
  }

  /// The `SidebarID` a terminal target belongs to, or nil when the target no longer resolves.
  func sidebarID(forTarget target: TerminalTarget) -> SidebarID? {
    guard let project = project(forTarget: target) else { return nil }
    if TerminalTarget.rootID(project: project.path) == target.id {
      return .root(project: project.path)
    }
    if let workroom = project.workrooms.first(where: {
      TerminalTarget.workroomID(project: project.path, name: $0.name) == target.id
    }) {
      return .workroom(project: project.path, name: workroom.name)
    }
    return nil
  }

  /// **The** answer to "what branch is this?", for every surface that shows one: the status
  /// bar (`branchLabel(for:)`), the Changes panel header, the sidebar's project root row, and the VCS
  /// toolbar. Four surfaces previously each derived it, which meant they could disagree on screen.
  ///
  /// **Reads only caches — never calls a VCS provider, and must stay that way.** Every source here is
  /// already resolved by something else on its own schedule. This is load-bearing, not incidental: the
  /// sidebar and status bar render this for every row, and the recorded pitfall
  /// `history-eager-focus-is-a-full-vcs-read` is exactly what happens when a per-row read turns out to
  /// open a repo. `BranchLabelTests` pins it with a counting stub that fails if a provider is touched.
  ///
  /// Source order, freshest first:
  /// 1. `resolvedBranchNames` — the VCS toolbar's remote-state read, which is force-refreshed the
  ///    moment anything changes it, so it leads whenever it has an answer.
  /// 2. `branchForCI` from the per-workroom status sweep (15s TTL).
  /// 3. The project root's `RootRef`, resolved by `BranchResolver`.
  func branchName(for sid: SidebarID) -> String? {
    if let resolved = resolvedBranchNames[sid], !resolved.isEmpty { return resolved }
    let status = workroomStatuses[sid]
    if let branch = status?.branchForCI, !branch.isEmpty { return branch }
    if case .root(let project) = sid {
      let label = RootPresentation.make(rootRefs[project] ?? .unresolved).label
      return label.isEmpty ? nil : label
    }
    return nil
  }

  /// Poll the supervisor's status file — the AUTHORITATIVE run state (issue #7) — while the run pane is
  /// open, applying each change. Replaces inferring state from child-exit + an `interrupted` flag (which
  /// caused the Stop-then-Run swallow). Self-terminates once the run tab is gone.
  private func pollRunStatus(for target: TerminalTarget) {
    guard runStates[target.id]?.tab != nil, let ctl = runPidFiles[target.id] else { return }
    let statusPath = RunCommandController.supervisorStatusPath(forPidPath: ctl)
    if let raw = try? String(contentsOfFile: statusPath, encoding: .utf8) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !line.isEmpty, lastRunStatus[target.id] != line {
        lastRunStatus[target.id] = line
        applyRunStatus(line, for: target)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.pollRunStatus(for: target)
    }
  }

  /// Test seam: production schedules the status poll on the main queue; tests drive transitions by
  /// calling `applyRunStatus` directly, so they never start the poller.
  /// Apply one status line from the supervisor to `RunState`/`RunOutcome` (issue #7).
  func applyRunStatus(_ line: String, for target: TerminalTarget) {
    guard let tab = runStates[target.id]?.tab else { return }
    let parts = line.split(separator: " ")
    switch parts.first.map(String.init) ?? "" {
    case "starting", "running":
      runStates[target.id] = .running(tab: tab, interrupted: false)
      runOutcomes[target.id] = nil
      // Every fresh "running" edge (initial start, or a restart completing) re-arms the live toast,
      // even if a prior run already auto-hid it.
      runningToastAutoHidden.remove(target.id)
      runCommand.scheduleRunningToastAutoHide(for: target.id)
      runCommand.setRunStoppedAwaitingClose(false, tab: tab, target: target.id)
    case "stopping":
      break  // keep the in-flight state (running(interrupted) for a stop, restarting for a restart)
    case "stopped":
      runStates[target.id] = .stopped(tab: tab)
      runOutcomes[target.id] = .stoppedByUser
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      runCommand.setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
    case "exited", "failed":
      let code = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0
      runStates[target.id] = .stopped(tab: tab)
      runCommand.setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
      // 130 = SIGINT (typed Ctrl-C / our group stop), 143 = SIGTERM (quit): user-initiated, not a crash.
      if code == 0 {
        runOutcomes[target.id] = .exited(code: 0)
      } else if code == 130 || code == 143 {
        runOutcomes[target.id] = .stoppedByUser
      } else {
        runOutcomes[target.id] = .exited(code: code)
      }
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      if RunCommandController.runOutcomeIsBannerWorthy(runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed", body: "exited with code \(code)")
        diagnoseRunFailure(target: target, tab: tab, exitCode: code)
      }
    default:
      break
    }
  }

  /// Diagnose a failed Run command with the inline agent (issue #49, A1 + X3). Run tabs `exec` over
  /// the shell so they emit no OSC 133 marks — capture the whole surface instead, and only once the
  /// supervisor's in-band exit trailer has rendered (so the snapshot includes the last output lines,
  /// not whatever had painted when the out-of-band `.status` file landed).
  private func diagnoseRunFailure(target: TerminalTarget, tab: TerminalTab.ID, exitCode: Int32) {
    guard terminals.agentManager.isEnabled,
      case .terminal(let s)? = terminals.tab(tab, for: target)?.content
    else { return }
    let view = s.view
    let command = project(forTarget: target).map { runConfig(forProject: $0.path).command }
    let shell = (ShellEnvironment.loginShell() as NSString).lastPathComponent

    Task { @MainActor in
      var surfaceText = view.readFullSurface() ?? ""
      var tries = 0
      while !RunCaptureSupport.hasRenderedTrailer(surfaceText) && tries < 20 {
        try? await Task.sleep(nanoseconds: 50_000_000)  // up to ~1s for the trailer to render
        surfaceText = view.readFullSurface() ?? ""
        tries += 1
      }
      let failure = FailedCommand(
        command: command,
        cwd: view.lastKnownCwd ?? target.path,
        exitCode: exitCode,
        shell: shell,
        output: RunCaptureSupport.extractOutput(fromSurface: surfaceText) ?? "",
        isRunTab: true,
        isRemote: false)
      terminals.agentManager.commandFinished(tab: tab, target: target.id, failure: failure)
    }
  }

  /// Start the project's run command in `target`'s directory, in a dedicated run terminal. No-op
  /// without a configured command or for a missing target. One run terminal per target (a second start
  /// is a no-op, not a duplicate).
  ///
  /// Issue #67: the run starts in the BACKGROUND by default — `focus` is false, so it doesn't steal the
  /// foreground tab; a toast surfaces its status. `focus: true` is only for auto-run on a freshly
  /// created workroom where the run would be the sole tab (Arch #5) — there we DO show it.
  func startRunCommand(for target: TerminalTarget, focus: Bool = false) {
    guard !target.isMissing, let project = project(forTarget: target) else { return }
    if hostLayouts.fetching.contains(target.id) {
      return whenHostLayoutRestored(target) { [weak self] target in
        self?.startRunCommand(for: target, focus: focus)
      }
    }
    // Never launch the project command against a worktree that is still being built (issue #167),
    // and never over a create's own dialog (issue #171). Auto-run already waits — it fires from
    // `ensureInitialTerminal` once the create succeeds (#483) — and a build or dev server started
    // against half-installed dependencies is the exact failure issue #7's disarm exists to prevent. Guarded HERE because it's the one place the pane header, the sidebar rows
    // and the ⌘R menu item all route through; each of those hides or disables itself on `isRunBlocked`
    // too, so the button and the action agree, but this guard is what makes that safe to rely on.
    guard !isRunBlocked(target.id) else { return }
    let config = runConfig(forProject: project.path)
    guard config.hasCommand else { return }
    if let existing = runStates[target.id]?.tab {
      // issue #67: a plain start never steals focus — only the auto-run-only-tab case passes focus.
      if focus { terminals.focus(existing, for: target) }
      return
    }
    let pidPath = runCommand.makeRunPidPath()
    let line = runCommand.runCommandLine(
      config.command.trimmingCharacters(in: .whitespacesAndNewlines), pidPath: pidPath)
    let tab = terminals.addRunTab(for: target, command: line, cwd: target.path, focus: focus)
    runOutcomes[target.id] = nil  // a fresh run clears the prior outcome (issue #67)
    resetRunToast(for: target.id)  // a new run always gets a fresh toast (clear dismiss + timer)
    // Background start spawns the surface off-window (`addRunTab(focus:false)`); if that failed there's
    // no process — surface the failure rather than a lying "running" toast. (Foreground starts spawn on
    // mount, so the surface is legitimately nil here — skip the check.)
    if !focus, tab.surface?.didSpawnFail == true {
      runOutcomes[target.id] = .failedToStart
      runStates[target.id] = .stopped(tab: tab.id)
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start",
        body: config.command.trimmingCharacters(in: .whitespacesAndNewlines))
      return
    }
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after the tab exists, so cleanup can't wipe it
    lastRunStatus[target.id] = nil
    // record the session for the forked-free backstop
    runCommand.captureRunSession(for: target.id, pidPath: pidPath)
    pollRunStatus(for: target)  // status file drives state from here (issue #7)
    // The surface child here is the SUPERVISOR; its exit means the whole run is over (quit/crash), not
    // a user-command stop. State during run/stop/restart is driven by the status file (above).
    tab.surface?.onChildExited = { [weak self] code in
      self?.markRunExited(for: target, exitCode: code)
    }
    wireRunClose(tab.id, for: target)
  }

  /// Start an interactive Investigate session (issue #49) seeded with the failure captured in
  /// `bannerState`. `surface` is the pane's live terminal surface (if any), used to derive cwd —
  /// takes the surface rather than a pre-computed `cwd: String` so both call sites share one cwd
  /// derivation instead of each re-deriving `?? target.path` themselves (the same drift shape issue
  /// #146 fixed for the command). The one caller of `addRunTab` for Investigate (issue #146) —
  /// tracks the tab in `investigateTabs` so it isn't invisible to quit/close teardown.
  @discardableResult
  func startInvestigate(
    bannerState: CodingAgentBannerState, target: TerminalTarget, surface: GhosttySurfaceView?
  ) -> TerminalTab {
    let cwd = surface?.lastKnownCwd ?? target.path
    let command = CodingAgentPrompt.investigateCommandLine(for: bannerState)
    let tab = terminals.addRunTab(for: target, command: command, cwd: cwd)
    investigateTabs[tab.id] = target.id
    let tabID = tab.id
    tab.surface?.onChildExited = { [weak self] _ in
      self?.investigateTabs.removeValue(forKey: tabID)
    }
    return tab
  }

  /// A run that came here with its workroom from another window (#444): its surface's exit and close
  /// now report to this window, and this window takes over polling the supervisor's status, which the
  /// origin's poll stopped doing the moment it lost the run.
  func resumeAdoptedRun(for target: TerminalTarget) {
    for (tabID, targetID) in investigateTabs where targetID == target.id {
      terminals.tab(tabID, for: target)?.surface?.onChildExited = { [weak self] _ in
        self?.investigateTabs.removeValue(forKey: tabID)
      }
    }
    guard let tabID = runStates[target.id]?.tab, let tab = terminals.tab(tabID, for: target)
    else { return }
    tab.surface?.onChildExited = { [weak self] code in
      self?.markRunExited(for: target, exitCode: code)
    }
    wireRunClose(tabID, for: target)
    pollRunStatus(for: target)
  }

  /// The "press any key to close" / wait_after_command close for a run tab MUST go through the graceful
  /// stop (SIGTERM the supervisor + wait for it to fully exit) BEFORE freeing the surface — a raw
  /// `closeTab` frees the surface, which PTY-hangs-up (SIGHUP) the supervisor and can orphan a
  /// still-draining server on its port ("A server is already running" next start; issue #7).
  private func wireRunClose(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    terminals.tab(tabID, for: target)?.surface?.onCloseRequested = { [weak self] in
      guard let self else { return }
      self.closingRunTab(tabID, for: target.id) { [weak self] in
        self?.terminals.closeTab(tabID, for: target)
      }
    }
  }

  /// Respawn the run command in place of `oldTab` (issue #40): the replacement takes the old run tab's
  /// exact slot, so restarting a run command that lives in a split keeps it in the split instead of
  /// pulling it out as a solo pane. Mirrors `startRunCommand`'s state wiring; `respawnRunTab` closes
  /// `oldTab` first so its port frees (SIGHUP) before the new instance binds — the graceful-restart
  /// ordering.
  private func respawnRunCommand(replacing oldTab: TerminalTab.ID, for target: TerminalTarget) {
    guard !target.isMissing, let project = project(forTarget: target) else {
      terminals.closeTab(oldTab, for: target)
      return
    }
    // Reached only after `restartRunCommand`'s `signalSupervisor` call already confirmed the
    // supervisor is gone — true regardless of which `RunState` the caller entered with
    // (`.running`/`.restarting`/`.stopped`, per `restartRunCommand`'s shared branch). Normalize to
    // `.stopped` up front so every exit below (including the no-command warning) reflects that
    // confirmed-dead reality; a real respawn overwrites this again a few lines down with its own
    // fresh `.running`/`.stopped` result. Without this, entering from `.running`/`.restarting` with
    // the command cleared left the toast/sidebar dot reporting "running" against a pid that no
    // longer exists.
    runStates[target.id] = .stopped(tab: oldTab)
    guard hasRunCommand(forProject: project.path) else {
      // #127 follow-up: the command was cleared while a stopped-but-open run pane sat waiting for
      // this restart. Mirror the `.armed`/`.none` branch's warning (same non-clobber guard) instead
      // of silently closing the pane — closing it here used to look exactly like ⌘R had done
      // nothing, with no way to tell "there's no command" from "the restart itself failed". Leaving
      // the pane open (not closing `oldTab`) also sidesteps issue #67's focus-preservation semantics
      // entirely: nothing about focus changes until the user actually configures a command and
      // restarts again.
      if pendingProjectSettings == nil {
        pendingProjectSettings = PendingProjectSettings(project: project, showsRunWarning: true)
      }
      return
    }
    let config = runConfig(forProject: project.path)
    let pidPath = runCommand.makeRunPidPath()
    let line = runCommand.runCommandLine(
      config.command.trimmingCharacters(in: .whitespacesAndNewlines), pidPath: pidPath)
    // Issue #67: a restart PRESERVES focus rather than always backgrounding — if the user was viewing
    // the run tab, the replacement stays focused; if it was already backgrounded, it stays so. Capture
    // this BEFORE `respawnRunTab` closes the old tab (which would move focus to a successor).
    let wasFocused = terminals.focusedTab(for: target)?.id == oldTab
    let tab = terminals.respawnRunTab(
      replacing: oldTab, for: target, command: line, cwd: target.path, focus: wasFocused)
    runOutcomes[target.id] = nil  // a fresh run clears the prior outcome (issue #67)
    resetRunToast(for: target.id)  // restart re-arms the toast + cancels a stale timer
    if !wasFocused, tab.surface?.didSpawnFail == true {
      runOutcomes[target.id] = .failedToStart
      runStates[target.id] = .stopped(tab: tab.id)
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start",
        body: config.command.trimmingCharacters(in: .whitespacesAndNewlines))
      return
    }
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after respawnRunTab's closeTab cleanup, so it survives
    lastRunStatus[target.id] = nil
    runCommand.captureRunSession(for: target.id, pidPath: pidPath)
    pollRunStatus(for: target)
    tab.surface?.onChildExited = { [weak self] code in
      self?.markRunExited(for: target, exitCode: code)
    }
    wireRunClose(tab.id, for: target)
  }

  /// Toggle a specific target's run command from the sidebar: running → stop; otherwise start (or
  /// re-run a stopped-but-open tab). Acts on the given target (not the selection). Issue #67: a start
  /// runs in the background and does NOT navigate to the target — the run toast is the feedback.
  func toggleRunCommand(for target: TerminalTarget) {
    if isRunCommandRunning(for: target.id) {
      stopRunCommand(for: target)
    } else {
      // Issue #67: starting from the sidebar no longer navigates to the workroom — the run goes to the
      // background and the toast is the feedback. Open it from the toast / ⌘R / Go ▸ Run Terminal.
      restartRunCommand(for: target)  // no run tab → start in background; stopped-but-open → re-run
    }
  }

  /// True while the user is typing in a text field (e.g. the Project Settings command field). The
  /// ambient ⌘R / ⇧⌘R / ⌥⌘R act on the sidebar *selection*, so they must not fire behind an editor —
  /// otherwise a run starts on the background workroom while you're editing settings (review #8). A
  /// focused NSTextField makes the window's field editor (an `NSTextView`, an `NSText`) first responder;
  /// the terminal surface is a plain `NSView`, so this stays false when a terminal is focused.
  private var isEditingTextField: Bool { NSApp.keyWindow?.firstResponder is NSText }

  /// ⌘R / the Run menu = "ensure running" (OV-B), acting on the current **selection**. The state
  /// machine itself lives in the per-target overload below; this is the selection-scoped door, and the
  /// only one that consults `isEditingTextField` — the ambient shortcut must not fire behind an
  /// editor, but a deliberate button *click* must (issue #139).
  func runOrFocusRunCommand() {
    guard !isEditingTextField, let target = selectedTarget else { return }
    runOrFocusRunCommand(for: target)
  }

  /// Raise `target`'s pane so a run started from it is actually visible. A workroom's own Run button
  /// (issue #139) can be pressed on a co-displayed but NON-focused split member, which renders
  /// `surfaceActive: false` and is dimmed — so focusing a tab inside it, or spawning a run tab in it,
  /// would otherwise look like nothing happened. A no-op for the selection-scoped path, where
  /// `target` already *is* the selection.
  private func focusTargetPane(_ target: TerminalTarget) {
    guard selectedTarget?.id != target.id,
      let sid = Self.sidebarID(forTargetID: target.id, in: projects)
    else { return }
    focusWorkroomMember(sid)
  }

  /// "Ensure running" for an **explicit** target: running → focus it; stopped-but-open → re-run;
  /// none → start. A workroom's own Run button calls this with ITS target, so in a split each member
  /// runs its own command rather than the selected workroom's (issue #139). Carries no
  /// `isEditingTextField` guard — that belongs to the ambient shortcut, not to a click.
  ///
  /// ```
  /// runOrFocusRunCommand(for:) — per-target run-state machine (issue #127 adds the middle branch)
  ///
  ///         ┌───────────────────┐
  ///         │ .running(_, true) │──restart──▶ respawn (Stop-then-Run: don't just focus a dying
  ///         └───────────────────┘             server)
  ///         ┌───────────────────────────────┐
  ///         │ .running(_,false)/.restarting │──focus tab──▶ (already visible/running)
  ///         └───────────────────────────────┘
  ///         ┌───────────┐
  ///         │ .stopped  │──restart──▶ respawn (re-run a stopped-but-open pane)
  ///         └───────────┘
  ///         ┌──────────────┐
  ///         │ .armed/.none │
  ///         └──────┬───────┘
  ///                │
  ///        ┌───────┴────────┐
  ///        │ owner elsewhere?│──yes──▶ focus owner's window + reveal (single-owner across windows)
  ///        └───────┬────────┘
  ///                │no
  ///        ┌───────┴──────────┐
  ///        │ hasRunCommand?    │──NO───▶  pendingProjectSettings = ⟨project, warning:true⟩  [NEW]
  ///        └───────┬──────────┘          (only if no sheet is already open — see guard below)
  ///                │yes
  ///                ▼
  ///          startRunCommand(for: target)
  /// ```
  func runOrFocusRunCommand(for target: TerminalTarget) {
    guard !target.isMissing else { return }
    focusTargetPane(target)
    switch runStates[target.id] {
    case .running(_, true):
      // Stop-then-Run (issue #7): the user stopped it (a Ctrl-C is in flight, the server is draining)
      // and is now asking for it again. Don't just focus a dying server — restart it, which waits out
      // the stop and respawns a fresh run. Otherwise the start is silently swallowed (the pane just
      // focuses) and the user is left with nothing running after a quick Stop→Run.
      restartRunCommand(for: target)
    case .running(let tab, false), .restarting(let tab):
      terminals.focus(tab, for: target)
    case .stopped:
      restartRunCommand(for: target)  // re-run a stopped-but-open tab (close + respawn)
    case .armed, .none:
      // Single-owner across windows (issue #70, OV-2): if another window already runs this
      // workroom's command, focus its run terminal rather than forking a second server on the same
      // port (which the app's own pid/process-group lifecycle would then fight over).
      if let owner = WindowRegistry.shared.runOwner(for: target.id, excluding: self) {
        // Same reason as the notification route: the run terminal may be a detached pane (#172).
        owner.window(forTab: owner.runStates[target.id]?.tab)?.makeKeyAndOrderFront(nil)
        owner.revealRunTerminal()
      } else if let project = project(forTarget: target), !hasRunCommand(forProject: project.path) {
        // Issue #127: ⌘R on a target with no run command configured used to silently no-op inside
        // `startRunCommand`'s guard. Surface the settings sheet with a warning instead of doing nothing.
        //
        // Reached by BOTH ⌘R and a click now: the workroom pane header's Run button is always shown for a
        // present target (issue #139 follow-up) precisely so this branch can teach you how to configure a
        // command. It was written when every Run button hid itself behind `canRunCommand` and only the
        // keyboard could get here — so this is a widening of an existing path, not a new one. (The
        // sidebar's per-row buttons still hide.)
        if pendingProjectSettings == nil {
          pendingProjectSettings = PendingProjectSettings(project: project, showsRunWarning: true)
        }
        // else: a settings sheet is already open (any reason, any project) — intentionally do
        // nothing further, rather than clobber it. This is deliberate and self-contained (issue
        // #127-eng-4, adversarial review): a second ⌘R for a DIFFERENT no-command target while a
        // sheet is already presented would otherwise silently overwrite the pending item, discarding
        // any unsaved typing with no confirmation — and there's genuine, unverified uncertainty about
        // whether SwiftUI's `.sheet(item:)` even refreshes the banner correctly when the identity is
        // unchanged. (Previously this fell through to `startRunCommand`'s own unrelated no-command
        // guard, which happened to produce the same no-op — but only by coincidence, not by design.)
      } else {
        startRunCommand(for: target)
      }
    }
  }

  /// ⇧⌘R / Stop menu: stop the selected target's run command if it's running. No-op otherwise.
  func stopSelectedRunCommand() {
    guard !isEditingTextField, let target = selectedTarget,
      isRunCommandRunning(for: target.id)
    else { return }
    stopRunCommand(for: target)
  }

  /// ⌥⌘R / Restart menu: restart the selected target's run command if it's running. No-op otherwise.
  func restartSelectedRunCommand() {
    guard !isEditingTextField, let target = selectedTarget,
      isRunCommandRunning(for: target.id)
    else { return }
    restartRunCommand(for: target)
  }

  /// Go ▸ Run Terminal: jump to a run terminal if one exists — select its target and focus the run
  /// tab. Prefers the selected target's run terminal, else any. Pure navigation; never starts a
  /// command (issue #7).
  func revealRunTerminal() {
    let targetID =
      selectedTarget.flatMap { runStates[$0.id]?.tab != nil ? $0.id : nil }
      ?? runStates.first { $0.value.tab != nil }?.key
    guard let targetID, let runTab = runStates[targetID]?.tab,
      let sid = Self.sidebarID(forTargetID: targetID, in: projects), let target = target(for: sid)
    else { return }
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
    terminals.focus(runTab, for: target)
  }

  /// Restart the run command (issue #7): tell the SUPERVISOR (SIGUSR1) to stop the child, wait for it to
  /// fully exit, then relaunch — all serialized inside the terminal, so the surface/tab/split slot are
  /// untouched and the new instance can't boot into the old one's still-held port/pidfile. Works from
  /// running, in-flight, OR a parked-but-stopped pane; only if the supervisor itself is gone (quit/crash)
  /// do we respawn a fresh surface.
  func restartRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab), .stopped(let tab):
      if runCommand.signalSupervisor(SIGUSR1, for: target.id) {
        runStates[target.id] = .restarting(tab: tab)  // status: stopping → running
        runningToastAutoHidden.remove(target.id)  // show "Restarting…" even if prior run auto-hid
      } else {
        respawnRunCommand(replacing: tab, for: target)  // supervisor gone → fresh surface
      }
    case .armed, .none:
      startRunCommand(for: target)
    }
  }

  /// The surface's PTY child exited — under the supervisor model that's the SUPERVISOR itself, so the
  /// whole run is over (a quit/teardown, or a supervisor crash), not a user-command stop (those are
  /// driven by the status file). Mark terminal; the pane stays open (`wait_after_command`). If the
  /// status file already recorded an outcome (the usual case — the supervisor wrote `exited <code>`
  /// before exiting), keep it; otherwise fall back to libghostty's code. The forked-free backstop
  /// (SIGKILL the captured session) guards against a leaf that outlived the supervisor.
  private func markRunExited(for target: TerminalTarget, exitCode: UInt32) {
    guard let tab = runStates[target.id]?.tab else { return }
    let sid = runSessions[target.id] ?? -1
    // Prefer the supervisor's final status line (authoritative — it wrote `stopped`/`exited <code>`
    // just before exiting) over libghostty's unreliable exit code, in case the poller hadn't read it
    // yet when this child-exit callback fired.
    if runOutcomes[target.id] == nil, let ctl = runPidFiles[target.id],
      let raw = try? String(
        contentsOfFile: RunCommandController.supervisorStatusPath(forPidPath: ctl), encoding: .utf8)
    {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !line.isEmpty { applyRunStatus(line, for: target) }
    }
    runStates[target.id] = .stopped(tab: tab)
    if runOutcomes[target.id] == nil {
      runOutcomes[target.id] = .exited(code: Int32(truncatingIfNeeded: exitCode))
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      if RunCommandController.runOutcomeIsBannerWorthy(runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed",
          body: "exited with code \(exitCode)")
      }
    }
    clearRunPidFile(for: target.id)
    // Backstop: a forked-free leaf (bin/dev/foreman in another pgroup) can outlive the supervisor —
    // SIGKILL the captured session so it can't linger on the port. No surfaces to poll here, so
    // `views` is empty — this is `pollUntilExited`'s sessions-only, synchronous-empty-set path.
    runCommand.pollUntilExited(
      [], sessions: sid > 1 ? [sid] : [], deadline: Date().addingTimeInterval(6)
    ) {}
  }

  /// Ensure a target's terminal pane lands the user in a live terminal when it first appears (called by
  /// the terminals view's `.task`). Two cases, both covered here:
  ///
  ///   1. Auto-run (issue #7): a just-created workroom that armed its project's run command starts it
  ///      as a backgrounded tab #1 (a toast surfaces it), with the always-on shell (below) as the
  ///      focused tab #2. The pane only mounts once any blocking setup dialog is dismissed, so the
  ///      command runs post-setup, as intended.
  ///   2. Always open a terminal: a newly created workroom always opens a shell, and selecting an
  ///      *existing* workroom/root with no open terminals opens one too. `.task(id:)` fires per target
  ///      appearance and `tabCount` is 0 only when the target has no live tabs, so this is idempotent
  ///      across re-mounts (navigating away and back) once a terminal exists.
  ///
  /// Falls back to a plain shell if the armed command can't start (e.g. config cleared between arming
  /// and mount) — the shell below opens regardless.
  func ensureInitialTerminal(for target: TerminalTarget) {
    // A remote workroom whose host keeps its layout waits for it rather than open a fresh pane
    // (#255, D4): `applyHostLayout` comes back here once the host has answered, or not in time.
    if fetchHostLayoutIfNeeded(for: target) {
      hostLayouts.waitingForFirstTab.insert(target.id)
      return
    }
    restoreDeferredSession(for: target)
    // Consume the armed intent up front so a later re-mount can't re-fire it, then let startRunCommand
    // (re-)derive the state: it becomes `.running` as a backgrounded tab #1, or a no-op if the config
    // was cleared between arming and mount.
    let isArmed: Bool
    if case .armed = runStates[target.id] { isArmed = true } else { isArmed = false }
    if isArmed {
      runStates[target.id] = nil
      // Background the auto-run (issue #67): the shell below is the focused tab the user lands on.
      startRunCommand(for: target, focus: false)
    }

    // Always land in a shell. When armed, this is the focused tab #2 beside the backgrounded run; for a
    // created or freshly-selected workroom/root with no tabs, it's the only one. `addTab` focuses it.
    if isArmed || terminals.tabCount(forTargetID: target.id) == 0 {
      terminals.addTab(for: target)
    }
  }
}
