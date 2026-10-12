import AppKit
import Foundation
import WorkroomDomain

/// A window's run commands (issue #7): each target's run state and outcome, the run toast's
/// dismissal bookkeeping, the supervisor's pid, status and session files, and the graceful
/// teardown. Owned by `AppStore` as `runCommand`. What needs the rest of the store stays in
/// `AppStore+RunCommand.swift`: starting and respawning a run (project, run config, host layout,
/// the settings sheet), applying the supervisor's status (the failure banner and diagnosis), the
/// derived toast list (selection), and the selection-scoped menu actions.
@MainActor
@Observable
final class RunCommandController {
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

  // MARK: State

  /// The window's terminals: run tabs live there, and the teardown reads their surfaces.
  private let terminals: TerminalSessions

  init(terminals: TerminalSessions) {
    self.terminals = terminals
  }

  /// Run-STATE is owned here (not on `TerminalSessions`) so the toolbar, sidebar, menu, and RootView
  /// — which all observe this store — react to start/stop/exit from one `@Published` source (OV-A).
  /// `TerminalSessions` only creates/focuses the tab and reports its removal via `.tabsRemoved`.
  var runStates: [TerminalTarget.ID: RunState] = [:]

  /// Live Investigate sessions (issue #49/#146), tab → target. Kept separate from `runStates` (one
  /// `RunState` per target, modelling a single dev-server-style run): an Investigate session is a
  /// second, independent process that can coexist with a target's real run command, and must NOT be
  /// deduped across windows the way `WindowRegistry.runOwner` dedupes a run command. Only feeds
  /// `hasLiveRunCommand`, so quit/window-close notice a live agent conversation instead of silently
  /// SIGHUP'ing it. Not `@Published` — its only reader, `hasLiveRunCommand`, is read imperatively by
  /// AppKit code at close/quit time (never by a SwiftUI view that needs a re-render), unlike
  /// `runStates`, which the toolbar/sidebar/menu genuinely observe.
  ///
  ///        runStates                    investigateTabs
  ///   [TargetID: RunState]          [TabID: TargetID]
  ///   one slot per target      many tabs allowed per target
  ///   (dev-server run)              (interactive claude)
  ///            │                            │
  ///            └─────────────┬──────────────┘
  ///                          ▼
  ///               hasLiveRunCommand (OR)
  ///                          │
  ///              ┌───────────┴────────────┐
  ///              ▼                        ▼
  ///   windowShouldClose confirm   stopRunCommandsThenTerminate (⌘Q)
  ///   alert — now fires for a     — unaffected in practice: only
  ///   live Investigate session    `runStates` feeds the actual
  ///                                gracefully-stop loop
  var investigateTabs: [TerminalTab.ID: TerminalTarget.ID] = [:]

  /// Per-target end-of-run outcome for the run toast (issue #67). Set on exit / failed start, cleared
  /// when a fresh run starts for that target. Derived-from, not duplicating, `runStates`.
  var runOutcomes: [TerminalTarget.ID: RunOutcome] = [:]

  /// Targets whose run toast was explicitly dismissed (✕) or auto-dismissed after a terminal state.
  /// Cleared when a fresh run starts. Open-terminal does NOT add here — it lets the visibility rule
  /// hide the toast while the run is on screen, so it reappears when you navigate away.
  var dismissedRunToasts: Set<TerminalTarget.ID> = []
  /// Targets whose LIVE (running/restarting) toast auto-hid after lingering a while — separate from
  /// `dismissedRunToasts` so a run that quietly auto-hid its "still running" toast can still surface
  /// a later terminal (exited/failed) toast; only gates the non-terminal branch of `runToastItems`.
  /// Cleared on a fresh "running" edge (start or restart), so the toast reappears each time.
  var runningToastAutoHidden: Set<TerminalTarget.ID> = []
  /// Pending auto-dismiss/auto-hide timers, one per target, cancelled on restart so a stale timer
  /// can't dismiss the next run's toast (review: timer cancellation on restart).
  var runToastDismissWork: [TerminalTarget.ID: DispatchWorkItem] = [:]
  /// Test seam: how a delayed auto-dismiss is scheduled. Production schedules on the main queue; tests
  /// capture the returned `DispatchWorkItem` to fire (or assert cancellation of) it deterministically.
  var scheduleRunToastDismiss: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = {
    delay, body in
    let work = DispatchWorkItem(block: body)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }

  /// Per-target temp file holding the run command's pid (written by the run wrapper, read to resolve
  /// + signal its process group). Generated fresh per start/respawn; cleared when the run exits or
  /// its tab is removed so a reused pid can never be signalled.
  var runPidFiles: [TerminalTarget.ID: String] = [:]

  /// The run command's SESSION id, captured at launch via `getsid`. A process group isn't enough:
  /// bin/dev-style launchers fork the leaf server into a *different* process group than the launcher,
  /// so a captured group can miss it (issue #7). The SESSION is stable across those forks — every
  /// process the run command spawns stays in the one session `login` created for it (unless it
  /// daemonizes via setsid, which dev servers don't — a typed Ctrl-C stops them, proving it). The
  /// session id stays valid after its leader exits, so it reaps a server that outlived the launcher.
  var runSessions: [TerminalTarget.ID: pid_t] = [:]

  /// Test seam: capture supervisor signals (and return whether a live supervisor was "signalled")
  /// without a real process. Production signals the control-file pid via `kill`.
  var signalSupervisorForTesting: ((Int32, TerminalTarget.ID) -> Bool)?

  /// Last status line applied per target, so the poller reacts only to CHANGES (and doesn't re-fire
  /// the auto-dismiss timer each tick). Cleared in `clearRunPidFile`.
  var lastRunStatus: [TerminalTarget.ID: String] = [:]

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

  /// ✕ on the run toast: a real dismiss — it won't reappear for this run (until the next start).
  func dismissRunToast(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    runToastDismissWork[targetID] = nil
    dismissedRunToasts.insert(targetID)
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
  func scheduleRunToastAutoDismiss(for targetID: TerminalTarget.ID) {
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
  func scheduleRunningToastAutoHide(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    let work = scheduleRunToastDismiss(Self.runningToastLinger) { [weak self] in
      guard let self else { return }
      self.runningToastAutoHidden.insert(targetID)
      self.runToastDismissWork[targetID] = nil
    }
    runToastDismissWork[targetID] = work
  }

  /// Whether the target's run command is currently running. Drives the toolbar Run↔Stop/Restart
  /// toggle and the sidebar run dot.
  func isRunCommandRunning(for targetID: TerminalTarget.ID) -> Bool {
    runStates[targetID]?.isRunning ?? false
  }

  /// The target's run terminal tab id (running or stopped-but-open), if any.
  func runTabID(for targetID: TerminalTarget.ID) -> TerminalTab.ID? { runStates[targetID]?.tab }

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
  func runCommandLine(_ raw: String, pidPath: String) -> String {
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
  func makeRunPidPath() -> String {
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
  func captureRunSession(
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
  func signalSupervisor(_ sig: Int32, for targetID: TerminalTarget.ID) -> Bool {
    if let signalSupervisorForTesting { return signalSupervisorForTesting(sig, targetID) }
    guard let pid = runPid(for: targetID) else { return false }
    return kill(pid, sig) == 0
  }

  /// Flip the run surface's "stopped — press any key to close" flag (issue #7): while stopped (the
  /// supervisor is parked, processHasExited is false), a key in the run pane closes the tab; cleared
  /// on a (re)start.
  func setRunStoppedAwaitingClose(
    _ value: Bool, tab: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    terminals.view(forTab: tab, inTarget: target)?.runStoppedAwaitingClose = value
  }

  /// Whether any run terminal exists (running or stopped-but-open) — gates Go ▸ Run Terminal.
  var hasAnyRunTerminal: Bool { runStates.values.contains { $0.tab != nil } }

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
  func pollUntilExited(
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
}
