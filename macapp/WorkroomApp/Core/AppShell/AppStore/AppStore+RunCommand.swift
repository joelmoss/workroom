import AppKit
import Defaults
import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire

/// The run command (issue #7): starting, restarting and respawning a workroom's run command under
/// its supervisor, applying the supervisor's status, the run toast list and native banner (issue
/// #67), and the selection-scoped Run, Stop and Restart actions. These read the window (projects,
/// selection, host layout, `modals`, `services.notifier`), so they stay here. The run state itself,
/// the toast dismissal, the supervisor's pid and session handling and the graceful teardown live in
/// `RunCommandController`, which the store owns as `runCommand`; the run config and what spans
/// windows live in the app's `RunCommands`, which it holds as `runCommands`.
extension AppStore {
  // MARK: Run command (issue #7)

  /// The run toasts to show right now. Derived each access: a target contributes a toast when it has a
  /// run state with a tab, the user hasn't dismissed it, and its run tab isn't currently on screen
  /// (you don't need a toast for what you're looking at — split-aware via `visibleTabIDs`).
  var runToastItems: [RunToastItem] {
    runCommand.runStates.compactMap { targetID, state -> RunToastItem? in
      guard let tabID = state.tab else { return nil }  // .armed has no tab → no toast
      guard !runCommand.dismissedRunToasts.contains(targetID) else { return nil }
      // Map state → toast status. A user-initiated stop (Stop/Restart/Ctrl-C → `.stoppedByUser`, or
      // a stop with no recorded outcome) shows NO toast at all (issue #79): the toast only ever marks
      // a self-exit (success or failure) or a failed start.
      let status: RunToastItem.Status
      switch state {
      case .armed: return nil
      case .running(_, true): status = .stopping
      case .running(_, false): status = .running
      case .restarting: status = .restarting
      case .stopped:
        switch runCommand.runOutcomes[targetID] {
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
      // then auto-dismiss, independent of `runCommand.runningToastAutoHidden`.
      if !status.isTerminal {
        guard let target = selectedTarget, target.id == targetID,
          !terminals.visibleTabIDs(for: target).contains(tabID),
          !runCommand.runningToastAutoHidden.contains(targetID)
        else { return nil }
      }
      let command =
        project(forTargetID: targetID).map {
          runCommands.runConfig(forProject: $0.path).command.trimmingCharacters(
            in: .whitespacesAndNewlines)
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
    guard let tabID = runCommand.runStates[targetID]?.tab else { return }
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
      if await services.notifier.ensureAuthorized() { services.notifier.post(note) }
    }
  }

  /// The owning project of a listed root or workroom, or nil once it is gone (and for a create's
  /// pane and the Quick Terminal).
  ///
  /// Compares **ids only**. Materialising `rootTarget` here would `stat` every project directory on
  /// the render path (`TerminalStatusBar.body` → `branchLabel` → `validatedSelection`), which is
  /// what hung the app in WORKROOM-3D. A lookup never needs the `isMissing`/`title` a target carries.
  func project(forTargetID id: TerminalTarget.ID) -> Project? {
    guard let project = projectStore.projects.first(where: { $0.path == id.projectPath }) else {
      return nil
    }
    if case .workroom(_, let name) = id, !project.workrooms.contains(where: { $0.id == name }) {
      return nil
    }
    return project
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
  ///
  /// A remote or container workroom whose panes open here runs too (#522): its run runs on its
  /// host, so the gate is whether a pane can open, not whether its path is on this Mac.
  func canRunCommand(for target: TerminalTarget, inProject projectPath: String) -> Bool {
    target.opensTerminals && !lifecycle.isRunBlocked(target.id)
      && runCommands.hasRunCommand(forProject: projectPath)
  }

  // MARK: Run command — actions (issue #7)

  /// Apply one status line from the supervisor to `RunState`/`RunOutcome` (issues #7, #522): the
  /// AUTHORITATIVE run state, as the run session's daemon publishes it (`TerminalSessions` raises
  /// `.runStatus`). A line repeated changes nothing. The first line of a run reattached from a saved
  /// session (`runCommand.restoredRuns`) is how the run is now, not something the user just did: a running
  /// one shows no "Running" toast (Q13), and a failure never starts an agent to diagnose it (Q7).
  func applyRunStatus(_ line: String, for target: TerminalTarget) {
    guard let tab = runCommand.runStates[target.id]?.tab,
      runCommand.lastRunStatus[target.id] != line
    else { return }
    runCommand.lastRunStatus[target.id] = line
    let restored = runCommand.restoredRuns.remove(target.id) != nil
    let parts = line.split(separator: " ")
    switch parts.first.map(String.init) ?? "" {
    case "starting", "running":
      // A first/delayed running report cannot acknowledge a Stop that is already in flight.
      let stopping = runCommand.runStates[target.id]?.isStopping == true
      runCommand.runStates[target.id] = .running(tab: tab, interrupted: stopping)
      runCommand.runOutcomes[target.id] = nil
      runCommand.setRunStoppedAwaitingClose(false, tab: tab, target: target.id)
      guard !restored else {
        runCommand.runningToastAutoHidden.insert(target.id)
        return
      }
      // Every fresh "running" edge (initial start, or a restart completing) re-arms the live toast,
      // even if a prior run already auto-hid it.
      runCommand.runningToastAutoHidden.remove(target.id)
      runCommand.scheduleRunningToastAutoHide(for: target.id)
    case "stopping":
      break  // keep the in-flight state (running(interrupted) for a stop, restarting for a restart)
    case "stopped":
      runCommand.runStates[target.id] = .stopped(tab: tab)
      runCommand.runOutcomes[target.id] = .stoppedByUser
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      runCommand.setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
    case "exited", "failed":
      let code = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0
      runCommand.runStates[target.id] = .stopped(tab: tab)
      runCommand.setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
      // 130 = SIGINT (typed Ctrl-C / our group stop), 143 = SIGTERM (quit): user-initiated, not a crash.
      if code == 0 {
        runCommand.runOutcomes[target.id] = .exited(code: 0)
      } else if code == 130 || code == 143 {
        runCommand.runOutcomes[target.id] = .stoppedByUser
      } else {
        runCommand.runOutcomes[target.id] = .exited(code: code)
      }
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      if RunCommandController.runOutcomeIsBannerWorthy(runCommand.runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed", body: "exited with code \(code)")
        if !restored { diagnoseRunFailure(target: target, tab: tab, exitCode: code) }
      }
    default:
      break
    }
  }

  /// A run tab came back from a saved session (#522): it is the target's run, reattached rather
  /// than started, so it is recorded as the run and waits for its daemon to say how the run is. If
  /// its host's daemon has already said, that is applied now.
  func adoptRestoredRun(tab tabID: TerminalTab.ID, targetID: TerminalTarget.ID) {
    guard let target = terminalTarget(forID: targetID), runCommand.runStates[targetID]?.tab == nil
    else {
      return
    }
    runCommand.runStates[targetID] = .running(tab: tabID, interrupted: false)
    runCommand.runOutcomes[targetID] = nil
    runCommand.lastRunStatus[targetID] = nil
    runCommand.restoredRuns.insert(targetID)
    // Reattached, not started: no "Running" toast (Q13), now or when its state arrives.
    runCommand.runningToastAutoHidden.insert(targetID)
    terminals.reportRunStatus(tab: tabID, target: target)
  }

  /// A run tab's session is not on its daemon any more. For a run reattached from a saved session
  /// that has not reported yet, it ended while Workroom was closed (a reboot, a daemon that died):
  /// its tab stays, stopped, saying so, and Run starts it again; nothing starts by itself (Q8). A
  /// run that was going whose remote pane is reattaching after its link dropped (its host
  /// restarted, say) stops the same way: its pane holds on the daemon's ended notice, so the
  /// session's end never reaches `markRunExited`. Any other run that was going ends through its
  /// tab's own process, which says how, so nothing is done here.
  func runSessionGone(tab tabID: TerminalTab.ID, targetID: TerminalTarget.ID) {
    guard runCommand.runStates[targetID]?.tab == tabID else { return }
    let view = terminals.view(forTab: tabID, inTarget: targetID)
    let notice: String
    if runCommand.restoredRuns.remove(targetID) != nil {
      notice = Self.runEndedWhileClosed
    } else if runCommand.runStates[targetID]?.isRunning == true,
      view?.isReattachingAfterLinkLoss == true
    {
      notice = Self.runEndedWhileReconnecting
    } else {
      return
    }
    runCommand.runStates[targetID] = .stopped(tab: tabID)
    runCommand.runOutcomes[targetID] = .stoppedByUser
    runCommand.runningToastAutoHidden.insert(targetID)
    view?.showPaneNotice(notice)
  }

  /// What a run tab says when its run ended while Workroom was closed (Q8).
  static let runEndedWhileClosed =
    "This run ended while Workroom was closed. Press Run to start it again."

  /// What a run tab says when its run ended while Workroom was reconnecting to its host.
  static let runEndedWhileReconnecting =
    "This run ended while Workroom was reconnecting to its host. Press Run to start it again."

  /// A stop, restart or quit its daemon could not confirm (R9): the run may or may not have been
  /// told, so nothing is started in its place, and its pane says what happened.
  func runSignalUnconfirmed(targetID: TerminalTarget.ID, reason: String) {
    guard let tab = runCommand.runStates[targetID]?.tab else { return }
    terminals.view(forTab: tab, inTarget: targetID)?.showPaneNotice(
      "Workroom couldn't reach this run's supervisor, so it may still be running. \(reason)")
  }

  /// Diagnose a failed Run command with the inline agent (issue #49, A1 + X3). Run tabs `exec` over
  /// the shell so they emit no OSC 133 marks — capture the whole surface instead, and only once the
  /// supervisor's in-band exit trailer has rendered (so the snapshot includes the last output lines,
  /// not whatever had painted when the out-of-band `.status` file landed).
  private func diagnoseRunFailure(target: TerminalTarget, tab: TerminalTab.ID, exitCode: Int32) {
    guard terminals.codingAgentManager.isEnabled,
      case .terminal(let s)? = terminals.tab(tab, for: target)?.content
    else { return }
    let view = s.view
    let command = project(forTargetID: target.id).map {
      runCommands.runConfig(forProject: $0.path).command
    }
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
        isRemote: target.remoteHost != nil)
      terminals.codingAgentManager.commandFinished(tab: tab, target: target.id, failure: failure)
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
    guard target.opensTerminals, let project = project(forTargetID: target.id) else { return }
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
    guard !lifecycle.isRunBlocked(target.id) else { return }
    let config = runCommands.runConfig(forProject: project.path)
    guard config.hasCommand else { return }
    if let existing = runCommand.runStates[target.id]?.tab {
      // issue #67: a plain start never steals focus — only the auto-run-only-tab case passes focus.
      if focus { terminals.focus(existing, for: target) }
      return
    }
    let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let host = target.remoteHost else {
      return openRunTab(for: target, command: command, focus: focus)
    }
    // A remote workroom's run is one per workroom on its host, whichever Mac started it (D7): ask
    // the host first, and show a run that is already going rather than start a second server.
    guard runCommand.pendingRunStarts.insert(target.id).inserted else { return }
    Task { @MainActor [weak self] in
      let runs = await RunCommands.liveRunSessions(
        on: .remote(host), workroom: target.sessionWorkroomKey)
      guard let self else { return }
      self.runCommand.pendingRunStarts.remove(target.id)
      guard self.runCommand.runStates[target.id]?.tab == nil else { return }
      if await HostConnectionManager.shared.runsRunSessions(on: .remote(host)) == false {
        self.present(RunUnavailable.olderHostDaemon)
        return
      }
      self.openRunTab(for: target, command: command, focus: focus, adopting: runs.first)
    }
  }

  /// Why Run can't start here, as an error the store presents.
  enum RunUnavailable: LocalizedError {
    case olderHostDaemon
    var errorDescription: String? {
      "This workroom's host runs an older Workroom daemon that can't run the run command."
    }
    var recoverySuggestion: String? {
      "Open the workroom again after updating Workroom on every Mac that uses this host."
    }
  }

  /// Opens the target's run tab: a new run session for `command`, or, `adopting`, the run session
  /// another Mac started on the workroom's host, reattached as a restored one.
  private func openRunTab(
    for target: TerminalTarget, command: String, focus: Bool, adopting session: UUID? = nil
  ) {
    let tab: TerminalTab
    if let session {
      tab = terminals.addRestoredRunTab(
        for: target, command: command, sessionID: session, focus: focus)
      runCommand.restoredRuns.insert(target.id)
      runCommand.runningToastAutoHidden.insert(target.id)
    } else {
      tab = terminals.addRunTab(
        for: target, command: command, cwd: target.path, focus: focus, runSession: true)
      // A new run always gets a fresh toast (clear dismiss + timer).
      runCommand.resetRunToast(for: target.id)
    }
    runCommand.runOutcomes[target.id] = nil  // a fresh run clears the prior outcome (issue #67)
    runCommand.lastRunStatus[target.id] = nil
    // Background start spawns the surface off-window (`addRunTab(focus:false)`); if that failed, or
    // no daemon could take the run (D5), nothing runs: say so rather than show a lying "running"
    // toast. (Foreground starts spawn on mount, so the surface is legitimately nil here — the exit
    // of the pane's notice says it then, through `markRunExited`.)
    if !focus, tab.surface?.didSpawnFail == true || tab.surface?.refusedRun == true {
      runCommand.runOutcomes[target.id] = .failedToStart
      runCommand.runStates[target.id] = .stopped(tab: tab.id)
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start", body: command)
      return
    }
    runCommand.runStates[target.id] = .running(tab: tab.id, interrupted: false)
    if session != nil { terminals.reportRunStatus(tab: tab.id, target: target) }
  }

  /// A tab's own process exited (`TerminalSessions.Event.childExited`), raised by the sessions that
  /// hold the tab now, so a tab that moved here from another window (#444) reports here. For the
  /// target's run tab the process is its session's attach, so its exit means the run session is
  /// over (a quit, a kill), not a user-command stop, which the run's status reports. Matching the
  /// run's own tab is what keeps a window's replaced run, still stopping, from ending the run that
  /// moved in over it (#444 Q12). An Investigate tab's exit ends its session (#146).
  func tabProcessExited(tab tabID: TerminalTab.ID, of target: TerminalTarget, exitCode: UInt32) {
    runCommand.investigateTabs.removeValue(forKey: tabID)
    guard runCommand.runStates[target.id]?.tab == tabID else { return }
    markRunExited(for: target, exitCode: exitCode)
  }

  /// Start an interactive Investigate session (issue #49) seeded with the failure captured in
  /// `bannerState`. `surface` is the pane's live terminal surface (if any), used to derive cwd —
  /// takes the surface rather than a pre-computed `cwd: String` so both call sites share one cwd
  /// derivation instead of each re-deriving `?? target.path` themselves (the same drift shape issue
  /// #146 fixed for the command). The one caller of `addRunTab` for Investigate (issue #146) —
  /// tracks the tab in `runCommand.investigateTabs` so it isn't invisible to quit/close teardown.
  @discardableResult
  func startInvestigate(
    bannerState: CodingAgentBannerState, target: TerminalTarget, surface: GhosttySurfaceView?,
    codingAgentSetting: String = Defaults[.terminalCodingAgentBackend]
  ) -> TerminalTab {
    let cwd = surface?.lastKnownCwd ?? target.path
    let agent = CodingAgentBackend.forInvestigate(
      setting: codingAgentSetting, claudeMissing: bannerState.claudeMissing)
    let command = CodingAgentPrompt.investigateCommandLine(for: bannerState, agent: agent)
    let tab = terminals.addRunTab(for: target, command: command, cwd: cwd)
    runCommand.investigateTabs[tab.id] = target.id
    return tab
  }

  /// Respawn the run command in place of `oldTab` (issue #40): the replacement takes the old run tab's
  /// exact slot, so restarting a run command that lives in a split keeps it in the split instead of
  /// pulling it out as a solo pane. Mirrors `startRunCommand`'s state wiring; `respawnRunTab` closes
  /// `oldTab` first so its port frees (SIGHUP) before the new instance binds — the graceful-restart
  /// ordering.
  private func respawnRunCommand(replacing oldTab: TerminalTab.ID, for target: TerminalTarget) {
    guard target.opensTerminals, let project = project(forTargetID: target.id) else {
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
    runCommand.runStates[target.id] = .stopped(tab: oldTab)
    guard runCommands.hasRunCommand(forProject: project.path) else {
      // #127 follow-up: the command was cleared while a stopped-but-open run pane sat waiting for
      // this restart. Mirror the `.armed`/`.none` branch's warning instead of silently closing the
      // pane — closing it here used to look exactly like ⌘R had done nothing, with no way to tell
      // "there's no command" from "the restart itself failed". Leaving the pane open (not closing
      // `oldTab`) also sidesteps issue #67's focus-preservation semantics entirely: nothing about
      // focus changes until the user actually configures a command and restarts again.
      modals.pendingProjectSettings = PendingProjectSettings(
        project: project, showsRunWarning: true)
      return
    }
    let command = runCommands.runConfig(forProject: project.path).command.trimmingCharacters(
      in: .whitespacesAndNewlines)
    // Issue #67: a restart PRESERVES focus rather than always backgrounding — if the user was viewing
    // the run tab, the replacement stays focused; if it was already backgrounded, it stays so. Capture
    // this BEFORE `respawnRunTab` closes the old tab (which would move focus to a successor).
    let wasFocused = terminals.focusedTab(for: target)?.id == oldTab
    let tab = terminals.respawnRunTab(
      replacing: oldTab, for: target, command: command, cwd: target.path, focus: wasFocused,
      runSession: true)
    runCommand.runOutcomes[target.id] = nil  // a fresh run clears the prior outcome (issue #67)
    runCommand.resetRunToast(for: target.id)  // restart re-arms the toast + cancels a stale timer
    runCommand.lastRunStatus[target.id] = nil
    if !wasFocused, tab.surface?.didSpawnFail == true || tab.surface?.refusedRun == true {
      runCommand.runOutcomes[target.id] = .failedToStart
      runCommand.runStates[target.id] = .stopped(tab: tab.id)
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start", body: command)
      return
    }
    runCommand.runStates[target.id] = .running(tab: tab.id, interrupted: false)
  }

  /// Toggle a specific target's run command from the sidebar: running → stop; otherwise start (or
  /// re-run a stopped-but-open tab). Acts on the given target (not the selection). Issue #67: a start
  /// runs in the background and does NOT navigate to the target — the run toast is the feedback.
  func toggleRunCommand(for target: TerminalTarget) {
    if runCommand.isRunCommandRunning(for: target.id) {
      runCommand.stopRunCommand(for: target)
    } else {
      // Issue #67: starting from the sidebar no longer navigates to the workroom — the run goes to the
      // background and the toast is the feedback. Open it from the toast / ⌘R / Room ▸ Go to Run
      // Terminal.
      restartRunCommand(for: target)  // no run tab → start in background; stopped-but-open → re-run
    }
  }

  /// True while the user is typing in a text field (e.g. the Project Settings command field). The
  /// ambient ⌘R / ⇧⌘R / ⌥⌘R act on the sidebar *selection*, so they must not fire behind an editor —
  /// otherwise a run starts on the background workroom while you're editing settings (review #8). A
  /// focused NSTextField makes the window's field editor (an `NSTextView`, an `NSText`) first responder;
  /// the terminal surface is a plain `NSView`, so this stays false when a terminal is focused.
  private var isEditingTextField: Bool { NSApp.keyWindow?.firstResponder is NSText }

  /// ⌘R / Room ▸ Run ="ensure running" (OV-B), acting on the current **selection**. The state
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
      let sid = sidebarID(for: target.id)
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
  ///        │ hasRunCommand?    │──NO───▶  pendingProjectSettings = ⟨project, warning:true⟩
  ///        └───────┬──────────┘
  ///                │yes
  ///                ▼
  ///          startRunCommand(for: target)
  /// ```
  func runOrFocusRunCommand(for target: TerminalTarget) {
    guard target.opensTerminals else { return }
    focusTargetPane(target)
    switch runCommand.runStates[target.id] {
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
      if let owner = runCommands.runOwner(for: target.id, excluding: runCommand) {
        owner.revealRun?(target.id)
      } else if let project = project(forTargetID: target.id),
        !runCommands.hasRunCommand(forProject: project.path)
      {
        // Issue #127: ⌘R on a target with no run command configured used to silently no-op inside
        // `startRunCommand`'s guard. Open the project's settings with a warning instead.
        //
        // Reached by BOTH ⌘R and a click now: the workroom pane header's Run button is always shown for a
        // present target (issue #139 follow-up) precisely so this branch can teach you how to configure a
        // command. It was written when every Run button hid itself behind `canRunCommand` and only the
        // keyboard could get here — so this is a widening of an existing path, not a new one. (The
        // sidebar's per-row buttons still hide.)
        modals.pendingProjectSettings = PendingProjectSettings(
          project: project, showsRunWarning: true)
      } else {
        startRunCommand(for: target)
      }
    }
  }

  /// ⇧⌘R / Stop menu: stop the selected target's run command if it's running. No-op otherwise.
  func stopSelectedRunCommand() {
    guard !isEditingTextField, let target = selectedTarget,
      runCommand.isRunCommandRunning(for: target.id)
    else { return }
    runCommand.stopRunCommand(for: target)
  }

  /// ⌥⌘R / Restart menu: restart the selected target's run command if it's running. No-op otherwise.
  func restartSelectedRunCommand() {
    guard !isEditingTextField, let target = selectedTarget,
      runCommand.isRunCommandRunning(for: target.id)
    else { return }
    restartRunCommand(for: target)
  }

  /// Room ▸ Go to Run Terminal: jump to a run terminal if one exists — select its target and focus
  /// the run tab. Prefers the selected target's run terminal, else any. Pure navigation; never
  /// starts a command (issue #7).
  func revealRunTerminal() {
    let targetID =
      selectedTarget.flatMap { runCommand.runStates[$0.id]?.tab != nil ? $0.id : nil }
      ?? runCommand.runStates.first { $0.value.tab != nil }?.key
    guard let targetID, let runTab = runCommand.runStates[targetID]?.tab,
      let sid = sidebarID(for: targetID),
      let target = target(for: sid)
    else { return }
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
    terminals.focus(runTab, for: target)
  }

  /// Restart the run command (issue #7): tell the SUPERVISOR (USR1) to stop the child, wait for it to
  /// fully exit, then relaunch — all serialized inside the supervisor, so the session/tab/split slot
  /// are untouched and the new instance can't boot into the old one's still-held port/pidfile. Works
  /// from running, in-flight, OR a parked-but-stopped pane; only if the supervisor itself is gone
  /// (quit/crash) do we respawn a fresh session.
  ///
  /// The supervisor is asked through its daemon (#522), so the answer can be slow or lost: the tab
  /// shows "Restarting…" at once, a fresh run session replaces it only when its daemon holds no
  /// such session (`.gone`), and an unconfirmed restart starts nothing (R9) and says so.
  func restartRunCommand(for target: TerminalTarget) {
    switch runCommand.runStates[target.id] {
    case .running(let tab, _), .restarting(let tab), .stopped(let tab):
      let before = runCommand.runStates[target.id]
      runCommand.runStates[target.id] = .restarting(tab: tab)  // status: stopping → running
      // Show "Restarting…" even if the prior run auto-hid.
      runCommand.runningToastAutoHidden.remove(target.id)
      runCommand.signalSupervisor(.restart, for: target.id) { [weak self] outcome in
        guard let self, self.runCommand.runStates[target.id]?.tab == tab else { return }
        switch outcome {
        case .delivered:
          // Its next status is a fresh run's: let the same line apply again.
          self.runCommand.lastRunStatus[target.id] = nil
        case .gone:
          self.respawnRunCommand(replacing: tab, for: target)  // supervisor gone → fresh session
        case .unknown(let reason):
          if case .restarting = self.runCommand.runStates[target.id] {
            self.runCommand.runStates[target.id] = before
          }
          self.runSignalUnconfirmed(targetID: target.id, reason: reason)
        }
      }
    case .armed, .none:
      startRunCommand(for: target)
    }
  }

  /// The run tab's own process exited. For a run session that is its attach, so the run session is
  /// over (a quit or kill, or the supervisor crashed), not a user-command stop (those come with
  /// the run's status). Mark terminal; the pane stays open. If the run's status already recorded an
  /// outcome (the usual case — the supervisor wrote `exited <code>` before exiting), keep it;
  /// otherwise fall back to the process's code. What the run left behind, its daemon ends (R8).
  ///
  /// Not a run's end when the pane is about to attach again: a remote pane whose link dropped
  /// reattaches (`GhosttySurfaceView.reconnectIfTheLinkDropped`) and its run carries on.
  private func markRunExited(for target: TerminalTarget, exitCode: UInt32) {
    guard let tab = runCommand.runStates[target.id]?.tab else { return }
    let view = terminals.view(forTab: tab, inTarget: target.id)
    guard view?.pendingReconnect == nil else { return }
    runCommand.restoredRuns.remove(target.id)
    if view?.refusedRun == true {
      // No daemon took the run (D5): the pane said why, and nothing ran.
      runCommand.runStates[target.id] = .stopped(tab: tab)
      runCommand.runOutcomes[target.id] = .failedToStart
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      return
    }
    // The run's last status, which may have come in after the last one applied.
    if runCommand.runOutcomes[target.id] == nil, let sessionID = view?.persistentSessionID,
      let line = terminals.programStatus.run(for: sessionID)
    {
      applyRunStatus(line, for: target)
    }
    runCommand.runStates[target.id] = .stopped(tab: tab)
    if runCommand.runOutcomes[target.id] == nil {
      runCommand.runOutcomes[target.id] = .exited(code: Int32(truncatingIfNeeded: exitCode))
      runCommand.scheduleRunToastAutoDismiss(for: target.id)
      if RunCommandController.runOutcomeIsBannerWorthy(runCommand.runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed",
          body: "exited with code \(exitCode)")
      }
    }
    runCommand.forgetRun(for: target.id)
  }

  /// Arm auto-run so the workroom's first terminal runs the project command as tab #1 (issue #7).
  /// It fires when the pane mounts, which is once the create is over. A remote create arms it at
  /// the same point, once its workroom has a name (#522): its run runs on its host.
  func armAutoRunIfConfigured(_ id: TerminalTarget.ID, in project: Project) {
    let cfg = runCommands.runConfig(forProject: project.path)
    if cfg.autoRun, cfg.hasCommand { runCommand.armAutoRun(forWorkroom: id) }
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
    // A delete drops the target first, and a failed create's pane still runs this as it leaves: the
    // terminal would be freed moments later, mid-attach, which is the #547 freeze.
    guard sidebarID(for: target.id) != nil else { return }
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
    if case .armed = runCommand.runStates[target.id] { isArmed = true } else { isArmed = false }
    if isArmed {
      runCommand.runStates[target.id] = nil
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
