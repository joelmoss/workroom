import AppKit
import Defaults
import Foundation
import WorkroomDomain

/// The run command (issue #7): starting, restarting and stopping a workroom's run command under
/// its supervisor, the run toast and native banner (issue #67), and the graceful teardown. Moved
/// out of `AppStore.swift` as is. Its stored state (`runStates`, `runOutcomes`, the toast sets,
/// `runPidFiles`, `runSessions` and the rest) stays on `AppStore`: an extension cannot store, and
/// views observe that state through the store until it moves into a type of its own. Other coupling
/// points left on `AppStore`: `terminals`, `cli`, `present(_:)` and `project(forTargetID:)`; and
/// `AppStore` calls back into `resetRunToast`, `clearRunPidFile` and `closingRunTab` from here.
extension AppStore {
  // MARK: Run command (issue #7)

  /// The lifecycle of a target's run command (issue #7), one value per target. A single state machine
  /// replaces the former parallel sets/maps — every transition is explicit, so the stale-bookkeeping
  /// family of bugs (an orphaned "pending restart" respawning a later run; a "Ctrl-C already sent"
  /// flag hard-killing a fresh run's first Stop) is unrepresentable. Process-based (child-exit), NOT
  /// OSC-9;4 — arbitrary run commands (npm run dev) emit no progress.
  enum RunState: Equatable {
    /// Auto-run queued for a just-created workroom; its pane hasn't mounted, so there's no tab yet.
    /// While armed, `ensureInitialTerminal` starts the run as a backgrounded tab #1, with the always-on
    /// shell opened as the focused tab #2.
    case armed
    /// Process alive in `tab`. `interrupted` = a Ctrl-C was already sent this stop cycle, so the next
    /// Stop escalates to a hard kill (OV-D).
    case running(tab: TerminalTab.ID, interrupted: Bool)
    /// Process alive in `tab`, Ctrl-C sent, awaiting child-exit to close + respawn (graceful restart, C1).
    case restarting(tab: TerminalTab.ID)
    /// Process exited but the pane stays open (`wait_after_command`); `tab` is still present.
    case stopped(tab: TerminalTab.ID)

    /// The run tab id, for any state that has one (everything but `.armed`).
    var tab: TerminalTab.ID? {
      switch self {
      case .running(let tab, _), .restarting(let tab), .stopped(let tab): return tab
      case .armed: return nil
      }
    }
    /// Whether the process is executing (drives the toolbar Run↔Stop/Restart toggle + sidebar dot).
    var isRunning: Bool {
      switch self {
      case .running, .restarting: return true
      case .armed, .stopped: return false
      }
    }
  }

  /// How a run ended — the bit `RunState` doesn't carry (issue #67). The run toast derives its final
  /// status from this: a clean exit reads "Exited", a non-zero exit reads "Failed (exit N)", a
  /// user-initiated Stop reads "Stopped" (you did it — not an error), and a surface that never spawned
  /// reads "Failed to start". Kept as a small side-table next to `runStates` rather than bloating
  /// `RunState.stopped`'s associated values (which the heavily-tested state machine pattern-matches in
  /// many places). `.stoppedByUser` vs `.exited` is decided by the `interrupted` flag the state machine
  /// already tracks. `nil` = the run hasn't ended (starting/running/restarting) — no outcome yet.
  enum RunOutcome: Equatable {
    case exited(code: Int32)  // process exited on its own; code 0 = clean, != 0 = failure
    case stoppedByUser  // a Stop/Restart Ctrl-C drove the exit
    case failedToStart  // the surface never spawned (ghostty_surface_new returned nil)

    /// Whether this outcome is a failure — the single source of truth that drives the red run icon
    /// (issue #79), the native banner, and the toast's failed glyph. A non-zero self-exit or a
    /// failed start; never a clean exit or a user-initiated Stop/Restart/Ctrl-C.
    var isFailure: Bool {
      switch self {
      case .exited(let code): return code != 0
      case .failedToStart: return true
      case .stoppedByUser: return false
      }
    }
  }

  // MARK: Run toast (issue #67) — DERIVED view-model, dismissal, native banner

  /// A live run-status toast, DERIVED from `runStates` + `runOutcomes` (no parallel stored array, so it
  /// can't drift). The bottom-right toast surface renders these above the notification toasts.
  struct RunToastItem: Identifiable, Equatable {
    var id: TerminalTarget.ID { targetID }
    let targetID: TerminalTarget.ID
    let tabID: TerminalTab.ID
    let source: String  // "platform / fix-auth"
    let command: String  // the configured run command, e.g. "npm run dev"
    let status: Status
    enum Status: Equatable {
      case running  // spinner (covers .running(interrupted:) too — still alive)
      case restarting  // spinner, graceful restart in flight
      case exited  // clean exit, code 0
      case failed(code: Int32)  // non-zero exit (a crash)
      case failedToStart  // the surface never spawned
      // Note: a user-initiated stop (Stop/Restart/Ctrl-C) produces NO toast (issue #79), so there's
      // deliberately no `.stopped` case — `runToastItems` returns nil for `.stoppedByUser`.
      var isTerminal: Bool {
        switch self {
        case .running, .restarting: return false
        case .exited, .failed, .failedToStart: return true
        }
      }
    }
  }

  /// How long a terminal-state run toast lingers before auto-dismissing.
  private static let runToastLinger: TimeInterval = 6
  /// How long the LIVE (running/restarting) toast shows before auto-hiding — longer than the terminal
  /// linger since it's informational, not a final result; other always-on indicators (sidebar run
  /// button, tab-bar dot, tab chip icon) keep conveying "still running" after it fades.
  private static let runningToastLinger: TimeInterval = 10

  /// Whether a finished run warrants a native banner: only genuine failures (a non-zero exit or a
  /// failed start), never a clean exit or a user-initiated Stop (Arch #7, issue #67). Pure so the
  /// policy is unit-testable without `NSApp`/`SystemNotifier`; the app-active gate is the (already
  /// tested) `NotificationGate`.
  static func runOutcomeIsBannerWorthy(_ outcome: RunOutcome?) -> Bool {
    outcome?.isFailure ?? false
  }

  /// Whether this target's last run ended in failure — drives the red run icon on the tab chip and
  /// the workroom tab-bar dot (issue #79). Derived from `RunOutcome.isFailure`, the same predicate
  /// the banner uses, so "is a failure" has one definition. Cleared on a fresh start and on close.
  func runFailed(for targetID: TerminalTarget.ID) -> Bool {
    runOutcomes[targetID]?.isFailure ?? false
  }

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

  /// ✕ on the run toast: a real dismiss — it won't reappear for this run (until the next start).
  func dismissRunToast(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    runToastDismissWork[targetID] = nil
    dismissedRunToasts.insert(targetID)
  }

  /// "Open terminal" on the run toast: jump to the run terminal. The toast then hides because its tab
  /// is on screen (visibility rule) — NOT dismissed, so it reappears if you navigate away.
  func openRunToast(for targetID: TerminalTarget.ID) {
    guard let tabID = runStates[targetID]?.tab else { return }
    openTerminal(targetID: targetID, tabID: tabID)
  }

  /// Clear toast dismissal + cancel any pending auto-dismiss for a target — called when a fresh run
  /// starts (so the new run always gets a toast) and when the run goes away (close/reap/delete).
  func resetRunToast(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    runToastDismissWork[targetID] = nil
    dismissedRunToasts.remove(targetID)
    runningToastAutoHidden.remove(targetID)
  }

  /// After a run reaches a terminal state, auto-dismiss its toast once the linger elapses (unless the
  /// user already dismissed/opened it, or a restart cancelled the timer).
  private func scheduleRunToastAutoDismiss(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    let work = scheduleRunToastDismiss(Self.runToastLinger) { [weak self] in
      guard let self else { return }
      self.dismissedRunToasts.insert(targetID)
      self.runToastDismissWork[targetID] = nil
    }
    runToastDismissWork[targetID] = work
  }

  /// While a run stays alive, auto-hide its LIVE toast once the (longer) running linger elapses —
  /// unlike `scheduleRunToastAutoDismiss`, this only marks `runningToastAutoHidden`, so a later
  /// terminal toast (the run crashes) isn't swallowed by an earlier "still running" auto-hide.
  private func scheduleRunningToastAutoHide(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    let work = scheduleRunToastDismiss(Self.runningToastLinger) { [weak self] in
      guard let self else { return }
      self.runningToastAutoHidden.insert(targetID)
      self.runToastDismissWork[targetID] = nil
    }
    runToastDismissWork[targetID] = work
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

  /// Whether the target's run command is currently running. Drives the toolbar Run↔Stop/Restart
  /// toggle and the sidebar run dot.
  func isRunCommandRunning(for targetID: TerminalTarget.ID) -> Bool {
    runStates[targetID]?.isRunning ?? false
  }

  /// The target's run terminal tab id (running or stopped-but-open), if any.
  func runTabID(for targetID: TerminalTarget.ID) -> TerminalTab.ID? { runStates[targetID]?.tab }

  /// The run config for a project path (empty if none set). Single read path for the toolbar, menu,
  /// settings sheet, and auto-run. Stored app-side in `Defaults` (GUI-only — the CLI can't hold a
  /// long-running process, so it's deliberately out of the `--json` contract, like branch labels).
  func runConfig(forProject projectPath: String) -> RunConfig {
    Defaults[.runCommands][projectPath] ?? .empty
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
  /// doesn't accrue dead keys. `objectWillChange` fires so the toolbar/menu re-render `hasRunCommand`
  /// the moment Save commits (those consumers observe this store — issue #7 reactivity, OV-A).
  func setRunConfig(_ config: RunConfig, forProject projectPath: String) {
    objectWillChange.send()
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

  /// The bundled run supervisor (issue #7) — the long-lived shell that owns each run command's
  /// process tree inside its terminal (start/stop/restart serialized there, controlled by signals +
  /// a status file). Resolved from `Bundle.main`; the fallback keeps tests (no bundled resource)
  /// building — they assert the invocation's shape, not a real path.
  static func supervisorScriptPath() -> String {
    Bundle.main.resourceURL?.appendingPathComponent("run-supervisor/supervisor.sh").path
      ?? "run-supervisor/supervisor.sh"
  }

  /// The supervisor's status file (it writes `running`/`stopped`/`exited <code>` etc. here, atomically;
  /// the app watches it). Derived from the per-run control-file path so they share one lifecycle.
  static func supervisorStatusPath(forPidPath pidPath: String) -> String {
    (pidPath as NSString).deletingPathExtension + ".status"
  }

  /// Build the libghostty `command` string (A3): launch the run SUPERVISOR as the surface's PTY child
  /// (set once, never replaced). The supervisor owns the user command — it runs it in the user's
  /// login+interactive shell (so it inherits PATH/aliases/version-manager shims), in the tty
  /// FOREGROUND so interactive servers can read the keyboard, and the app drives stop/restart by
  /// signalling the supervisor (its pid lands in `pidPath`) and reading the status file. POSIX `$SHELL`
  /// (zsh/bash/sh/dash/ksh) gets `-lic`; a non-POSIX `$SHELL` (fish/nu/csh) falls back to a login
  /// `/bin/sh -lc`, whose interactive rc won't load — a documented limitation (issue #7, fold #7).
  /// libghostty runs this whole string via `sh -c`, which execs `/bin/sh <supervisor> …`, so the
  /// supervisor becomes the session-leader PTY child (its `kill -INT 0` group-stop stays scoped to the
  /// run's own session).
  private func runCommandLine(_ raw: String, pidPath: String) -> String {
    let q = CommandLineInstaller.shellQuoted
    // The child the supervisor runs: the user's login-interactive shell, which `exec`s the command
    // through the runner with `-c` (so compound commands — `cd web && npm run dev`, `FOO=bar rails s`,
    // pipes — work, and the exec keeps the pid stable so the supervisor's `$!` is the live server).
    // The POSIX-vs-fallback decision lives in `ShellEnvironment.loginShellInvocation`, shared with
    // the environment probe so the two can't drift; `commandString` is the form libghostty needs.
    let runner = ShellEnvironment.loginShellExecutable()
    let innerScript = "exec \(q(runner)) -c \(q(raw))"
    let childOuter = ShellEnvironment.loginShellInvocation(script: innerScript).commandString
    // config.command = /bin/sh <supervisor> <controlFile> <statusFile> <childArgv…>
    let sup = q(Self.supervisorScriptPath())
    let ctl = q(pidPath)
    let status = q(Self.supervisorStatusPath(forPidPath: pidPath))
    return "/bin/sh \(sup) \(ctl) \(status) \(childOuter)"
  }

  /// A fresh per-run pid-file path. Does NOT store it — the caller assigns `runPidFiles[target]`
  /// AFTER the tab is (re)created, because `respawnRunTab` closes the old tab first and that fires
  /// `.tabsRemoved` → `clearRunPidFile`, which would otherwise wipe a path stored too early (the
  /// re-run-can't-be-stopped bug, issue #7).
  private func makeRunPidPath() -> String {
    (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("workroom-run-\(UUID().uuidString).pid")
  }

  /// The supervisor's pid (it `echo $$`s into the control file). Used to signal it (stop/restart/quit).
  private func runPid(for targetID: TerminalTarget.ID) -> pid_t? {
    guard let path = runPidFiles[targetID],
      let raw = try? String(contentsOfFile: path, encoding: .utf8),
      let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    else { return nil }
    return pid
  }

  /// Poll the just-spawned run wrapper's pid file and record its session id while it's still alive, so
  /// a later Stop / child-exit can SIGINT the whole session (issue #7). The launcher lives through the
  /// server's boot, so a brief poll always catches it.
  private func captureRunSession(
    for targetID: TerminalTarget.ID, pidPath: String, attempt: Int = 0
  ) {
    if let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
      let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    {
      let sid = getsid(pid)
      if sid > 1 { runSessions[targetID] = sid }
      return
    }
    guard attempt < 30 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.captureRunSession(for: targetID, pidPath: pidPath, attempt: attempt + 1)
    }
  }

  /// Live pids belonging to run session `sid`. macOS `pkill` has no `-s` (session) flag, so we
  /// enumerate every pid (`proc_listallpids`) and keep those whose `getsid` matches — the generic way
  /// to find everything a run command spawned, whatever process group its launcher forked the leaf
  /// server into (issue #7). Returns empty for the app's own session, so a reap can never hit the app
  /// itself or another terminal. Now used only by the forked-free backstop (a leaf that outlived the
  /// supervisor); the supervisor itself owns the normal stop/restart.
  private func runSessionMembers(_ sid: pid_t) -> [pid_t] {
    guard sid > 1, sid != getsid(0) else { return [] }  // never our own (the app's) session
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let bytes = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return [] }
    var members: [pid_t] = []
    for i in 0..<min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count) where pids[i] > 1 {
      if getsid(pids[i]) == sid { members.append(pids[i]) }
    }
    return members
  }

  /// Send `sig` to every process in run session `sid` — a session-scoped signal: SIGINT is a Ctrl-C
  /// (graceful), SIGKILL the last-resort reap when graceful didn't take in time. Guarded (via
  /// `runSessionMembers`) to a run command's own isolated `login` session.
  private func signalRunSession(_ sid: pid_t, _ sig: Int32) {
    for pid in runSessionMembers(sid) { _ = kill(pid, sig) }
  }

  /// Forget (and delete) a target's captured pid file + group once its run has exited/closed, so a
  /// later reuse of that pid/group can't be signalled.
  func clearRunPidFile(for targetID: TerminalTarget.ID) {
    runSessions[targetID] = nil
    lastRunStatus[targetID] = nil
    if let path = runPidFiles.removeValue(forKey: targetID) {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: Self.supervisorStatusPath(forPidPath: path))
    }
  }

  // MARK: Run command — supervisor control (issue #7)
  //
  // The run command runs under a long-lived SUPERVISOR (Resources/run-supervisor/supervisor.sh) that
  // is the surface's PTY child. The app controls it by signalling the supervisor's pid (in the
  // control file) and reads run STATE from the status file it writes — start/stop/restart are
  // serialized inside the terminal, so the surface is never freed/respawned for a restart and a
  // relaunch only happens after the previous child fully exits (no "A server is already running").

  /// Send `sig` to the target's run supervisor (USR1 = restart, USR2 = stop/keep-pane, TERM = quit →
  /// supervisor exits → surface frees). Returns false when there's no live supervisor to signal, so a
  /// caller can fall back to respawning the surface.
  @discardableResult
  private func signalSupervisor(_ sig: Int32, for targetID: TerminalTarget.ID) -> Bool {
    if let signalSupervisorForTesting { return signalSupervisorForTesting(sig, targetID) }
    guard let pid = runPid(for: targetID) else { return false }
    return kill(pid, sig) == 0
  }

  /// Poll the supervisor's status file — the AUTHORITATIVE run state (issue #7) — while the run pane is
  /// open, applying each change. Replaces inferring state from child-exit + an `interrupted` flag (which
  /// caused the Stop-then-Run swallow). Self-terminates once the run tab is gone.
  private func pollRunStatus(for target: TerminalTarget) {
    guard runStates[target.id]?.tab != nil, let ctl = runPidFiles[target.id] else { return }
    let statusPath = Self.supervisorStatusPath(forPidPath: ctl)
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
  /// Flip the run surface's "stopped — press any key to close" flag (issue #7): while stopped (the
  /// supervisor is parked, processHasExited is false), a key in the run pane closes the tab; cleared
  /// on a (re)start.
  private func setRunStoppedAwaitingClose(
    _ value: Bool, tab: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    terminals.view(forTab: tab, inTarget: target)?.runStoppedAwaitingClose = value
  }

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
      scheduleRunningToastAutoHide(for: target.id)
      setRunStoppedAwaitingClose(false, tab: tab, target: target.id)
    case "stopping":
      break  // keep the in-flight state (running(interrupted) for a stop, restarting for a restart)
    case "stopped":
      runStates[target.id] = .stopped(tab: tab)
      runOutcomes[target.id] = .stoppedByUser
      scheduleRunToastAutoDismiss(for: target.id)
      setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
    case "exited", "failed":
      let code = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0
      runStates[target.id] = .stopped(tab: tab)
      setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
      // 130 = SIGINT (typed Ctrl-C / our group stop), 143 = SIGTERM (quit): user-initiated, not a crash.
      if code == 0 {
        runOutcomes[target.id] = .exited(code: 0)
      } else if code == 130 || code == 143 {
        runOutcomes[target.id] = .stoppedByUser
      } else {
        runOutcomes[target.id] = .exited(code: code)
      }
      scheduleRunToastAutoDismiss(for: target.id)
      if Self.runOutcomeIsBannerWorthy(runOutcomes[target.id]) {
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
    // `ensureInitialTerminal` once the pane mounts, which withholding defers — and a build or dev
    // server started against half-installed dependencies is the exact failure issue #7's disarm
    // exists to prevent. Guarded HERE because it's the one place the pane header, the sidebar rows
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
    let pidPath = makeRunPidPath()
    let line = runCommandLine(
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
      scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start",
        body: config.command.trimmingCharacters(in: .whitespacesAndNewlines))
      return
    }
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after the tab exists, so cleanup can't wipe it
    lastRunStatus[target.id] = nil
    // record the session for the forked-free backstop
    captureRunSession(for: target.id, pidPath: pidPath)
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
    let pidPath = makeRunPidPath()
    let line = runCommandLine(
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
      scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start",
        body: config.command.trimmingCharacters(in: .whitespacesAndNewlines))
      return
    }
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after respawnRunTab's closeTab cleanup, so it survives
    lastRunStatus[target.id] = nil
    captureRunSession(for: target.id, pidPath: pidPath)
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

  /// Whether any run terminal exists (running or stopped-but-open) — gates Go ▸ Run Terminal.
  var hasAnyRunTerminal: Bool { runStates.values.contains { $0.tab != nil } }

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

  /// Stop the run command (issue #7): one press tells the SUPERVISOR to stop the child gracefully and
  /// keep the pane (SIGUSR2 — it SIGINTs the child's foreground group, waits for it to fully exit, and
  /// SIGKILLs on a 6s timeout for a process that ignores SIGINT). No second-press hard-kill / surface
  /// free — the supervisor owns the teardown. State flips to `.running(interrupted)` (stop in flight),
  /// then the status file drives it to `.stopped`.
  func stopRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab):
      signalSupervisor(SIGUSR2, for: target.id)
      runStates[target.id] = .running(tab: tab, interrupted: true)
    case .armed, .stopped, .none:
      break  // nothing executing to stop
    }
  }

  /// Restart the run command (issue #7): tell the SUPERVISOR (SIGUSR1) to stop the child, wait for it to
  /// fully exit, then relaunch — all serialized inside the terminal, so the surface/tab/split slot are
  /// untouched and the new instance can't boot into the old one's still-held port/pidfile. Works from
  /// running, in-flight, OR a parked-but-stopped pane; only if the supervisor itself is gone (quit/crash)
  /// do we respawn a fresh surface.
  func restartRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab), .stopped(let tab):
      if signalSupervisor(SIGUSR1, for: target.id) {
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
        contentsOfFile: Self.supervisorStatusPath(forPidPath: ctl), encoding: .utf8)
    {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !line.isEmpty { applyRunStatus(line, for: target) }
    }
    runStates[target.id] = .stopped(tab: tab)
    if runOutcomes[target.id] == nil {
      runOutcomes[target.id] = .exited(code: Int32(truncatingIfNeeded: exitCode))
      scheduleRunToastAutoDismiss(for: target.id)
      if Self.runOutcomeIsBannerWorthy(runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed",
          body: "exited with code \(exitCode)")
      }
    }
    clearRunPidFile(for: target.id)
    // Backstop: a forked-free leaf (bin/dev/foreman in another pgroup) can outlive the supervisor —
    // SIGKILL the captured session so it can't linger on the port. No surfaces to poll here, so
    // `views` is empty — this is `pollUntilExited`'s sessions-only, synchronous-empty-set path.
    pollUntilExited([], sessions: sid > 1 ? [sid] : [], deadline: Date().addingTimeInterval(6)) {}
  }

  // MARK: Run command — graceful teardown (issue #7, Option B)

  /// The target's run surface if a child process is still alive in it, else nil. Used by the
  /// teardown paths to decide whether a Ctrl-C + wait is needed before freeing it.
  private func liveRunView(for targetID: TerminalTarget.ID) -> GhosttySurfaceView? {
    guard let tabID = runStates[targetID]?.tab,
      let view = terminals.view(forTab: tabID, inTarget: targetID),
      view.hasLiveProcess
    else { return nil }
    return view
  }

  /// Whether any run command still has a live process — gates the quit handler's graceful wait.
  /// Also true for a live Investigate session (issue #146), even though it has no `RunState` and
  /// no supervisor to gracefully stop — see `investigateTabs`.
  var hasLiveRunCommand: Bool {
    runStates.keys.contains { liveRunView(for: $0) != nil }
      || investigateTabs.contains { tabID, targetID in
        terminals.view(forTab: tabID, inTarget: targetID)?.hasLiveProcess ?? false
      }
  }

  /// Tell each target's SUPERVISOR to quit (SIGTERM — it stops the child gracefully, waits for it,
  /// SIGKILLs on a 6s timeout, then exits), and run `then` once every run surface's child (the
  /// supervisor) has actually exited — or after `timeout` (fallback). Polls `hasLiveProcess` on the
  /// main runloop; NEVER frees a surface itself, so it can't race libghostty's teardown. The session
  /// SIGKILL in `pollUntilExited` is the backstop for a forked-free leaf that outlived the supervisor.
  func gracefullyStopRuns(
    _ targetIDs: [TerminalTarget.ID], timeout: TimeInterval = 6, then: @escaping () -> Void
  ) {
    var views: [GhosttySurfaceView] = []
    var sids: [pid_t] = []
    for id in targetIDs {
      guard let view = liveRunView(for: id) else { continue }
      signalSupervisor(SIGTERM, for: id)  // supervisor stops the child, then exits → surface frees
      views.append(view)
      if let sid = runSessions[id], sid > 1 { sids.append(sid) }
    }
    guard !views.isEmpty else {
      then()
      return
    }
    pollUntilExited(views, sessions: sids, deadline: Date().addingTimeInterval(timeout), then: then)
  }

  /// Wait until both the surfaces' PTY children have exited AND every run session has drained (no live
  /// member), then run `then`. On `deadline` (a graceful Ctrl-C didn't take in time) SIGKILL whatever
  /// remains in those sessions, so a forked-free server is guaranteed dead before the caller frees the
  /// surface / quits — what makes teardown reliable for ANY run command, not just SIGINT-honouring ones
  /// (issue #7). Polling the surface (not just the session) keeps it unit-testable without a real PTY.
  ///
  /// Generalizes what used to be a separate `waitForSessionsExit(sids:deadline:then:)` (deleted): with
  /// `views` empty, `surfacesDone` is vacuously true, reducing this to exactly a sessions-only wait —
  /// the empty-set case still completes synchronously, so callers must already be off any libghostty
  /// callback stack, same contract as before. The deadline branch signals every id in `sids` rather
  /// than pre-filtering to only the still-live ones — behaviorally identical, since
  /// `signalRunSession`/`runSessionMembers` already no-op for a session with no live members.
  private func pollUntilExited(
    _ views: [GhosttySurfaceView], sessions sids: [pid_t], deadline: Date,
    then: @escaping () -> Void
  ) {
    let surfacesDone = views.allSatisfy { !$0.hasLiveProcess }
    let sessionsDone = sids.allSatisfy { runSessionMembers($0).isEmpty }
    if surfacesDone && sessionsDone {
      then()
      return
    }
    if Date() >= deadline {
      // Last resort — guarantee death before the caller frees the surface.
      for sid in sids { signalRunSession(sid, SIGKILL) }
      then()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.pollUntilExited(views, sessions: sids, deadline: deadline, then: then)
    }
  }

  /// If `tabID` is the target's run command with a live process, Ctrl-C it and wait for it to exit
  /// before running `proceed` (the actual close/teardown); otherwise run `proceed` now. Ordinary
  /// shell tabs (which don't exit on Ctrl-C) and already-exited run tabs fall straight through, so
  /// only a live dev server pays the wait.
  func closingRunTab(
    _ tabID: TerminalTab.ID, for targetID: TerminalTarget.ID, then proceed: @escaping () -> Void
  ) {
    let isRunTab = runStates[targetID]?.tab == tabID
    let live = liveRunView(for: targetID) != nil
    guard isRunTab, live else {
      proceed()  // not a live run tab → free directly (no supervisor to gracefully stop)
      return
    }
    gracefullyStopRuns([targetID], then: proceed)
  }

  /// SIGINT all live run commands and wait for them to exit (bounded) before `completion`. Called from
  /// the quit handler so dev servers clean up instead of being orphaned by the OS hangup on exit
  /// (SIGHUP). Signals the captured pids directly — never frees a surface.
  func gracefullyStopAllRunCommands(timeout: TimeInterval = 6, completion: @escaping () -> Void) {
    gracefullyStopRuns(Array(runStates.keys), timeout: timeout, then: completion)
  }

  /// Arm a just-created workroom to auto-run its project's command as its first terminal (issue #7).
  /// Called from `createWorkroom`; the run fires from `ensureInitialTerminal` when the pane mounts.
  func armAutoRun(forWorkroom targetID: TerminalTarget.ID) {
    runStates[targetID] = .armed
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
