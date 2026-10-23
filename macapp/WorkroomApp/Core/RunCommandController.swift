import AppKit
import DaemonConnection
import Foundation
import WorkroomDomain
import WorkroomSystem

typealias RunSignalOutcome = PersistentSessionService.RunSignalOutcome

/// What a run session's daemon lists it under (`workroomd`'s `crate::run`): `kind` is `run`.
enum RunSessionKey {
  static let kind = "kind"
}

/// A window's run commands (issue #7): each target's run state and outcome, the run toast's
/// dismissal bookkeeping, signalling the run's supervisor through its daemon (#522), and the
/// graceful teardown. Owned by `AppStore` as `runCommand`. What needs the rest of the store stays
/// in `AppStore+RunCommand.swift`: starting and respawning a run (project, run config, host
/// layout, the settings sheet), applying the supervisor's status (the failure banner and
/// diagnosis), the derived toast list (selection), and the selection-scoped menu actions.
///
/// A run is a daemon session (a run session) whose supervisor the daemon runs, on this Mac or on
/// the workroom's host (`workroomd run-supervisor`). It survives the app quitting; its state comes
/// with the session's program status, and stop, restart and quit are signals the daemon sends it.
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

  /// Test seam: answer a supervisor signal without a daemon, synchronously. Production asks the
  /// run session's daemon (`PersistentSessionService.signalRun`).
  var signalSupervisorForTesting: ((RunSignal, TerminalTarget.ID) -> RunSignalOutcome)?

  /// Last status line applied per target, so a repeated report changes nothing (and doesn't re-fire
  /// the auto-dismiss timer). Cleared in `forgetRun`.
  var lastRunStatus: [TerminalTarget.ID: String] = [:]

  /// Runs reattached from a saved session (#522) that have not reported yet. Their first status is
  /// how the run is NOW, not a change the user caused: a running one gets no "Running" toast
  /// (Q13), and a failure it reports (it crashed while the app was closed) never starts an agent
  /// to diagnose it (Q7). Gone before it reports means it ended while the app was closed (Q8).
  var restoredRuns: Set<TerminalTarget.ID> = []

  /// Remote starts asking their host for a run already going (D7), so a second press while it
  /// answers starts nothing more.
  var pendingRunStarts: Set<TerminalTarget.ID> = []

  // MARK: Hand-over between windows (#444)

  /// One target's run bookkeeping, carried with its workroom to another window. The run tab's
  /// process moves with its surface; this is everything this window knew about it.
  struct HandOff {
    var state: RunState?
    var outcome: RunOutcome?
    var restored = false
    var lastStatus: String?
    var toastDismissed = false
    var toastAutoHidden = false
    /// A toast timer was still to fire: the destination starts its own.
    var toastTimerPending = false
    var investigateTabs: [TerminalTab.ID] = []
  }

  /// Lift `targetID`'s run bookkeeping out of this window. A pending toast timer is cancelled, since
  /// it would act on this window's toast, and the destination starts its own.
  func takeHandOff(for targetID: TerminalTarget.ID) -> HandOff {
    let timer = runToastDismissWork.removeValue(forKey: targetID)
    timer?.cancel()
    let investigate = investigateTabs.filter { $0.value == targetID }.map(\.key)
    for tab in investigate { investigateTabs[tab] = nil }
    return HandOff(
      state: runStates.removeValue(forKey: targetID),
      outcome: runOutcomes.removeValue(forKey: targetID),
      restored: restoredRuns.remove(targetID) != nil,
      lastStatus: lastRunStatus.removeValue(forKey: targetID),
      toastDismissed: dismissedRunToasts.remove(targetID) != nil,
      toastAutoHidden: runningToastAutoHidden.remove(targetID) != nil,
      toastTimerPending: timer != nil, investigateTabs: investigate)
  }

  /// The other half of `takeHandOff`, in the window the workroom moved to. A hand-off with no run
  /// leaves this window's own run for the target as it is.
  func adopt(_ handOff: HandOff, for targetID: TerminalTarget.ID) {
    for tab in handOff.investigateTabs { investigateTabs[tab] = targetID }
    guard let state = handOff.state else { return }
    // This window's own toast state was its replaced run's: the moved run's starts from its own.
    resetRunToast(for: targetID)
    runStates[targetID] = state
    runOutcomes[targetID] = handOff.outcome
    if handOff.restored { restoredRuns.insert(targetID) }
    lastRunStatus[targetID] = handOff.lastStatus
    if handOff.toastDismissed { dismissedRunToasts.insert(targetID) }
    if handOff.toastAutoHidden { runningToastAutoHidden.insert(targetID) }
    // Afresh rather than for what was left of it: a toast lingers a little longer, never forever.
    guard handOff.toastTimerPending else { return }
    if state.isRunning {
      scheduleRunningToastAutoHide(for: targetID)
    } else {
      scheduleRunToastAutoDismiss(for: targetID)
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

  /// Forget what the window knew of a target's run once it has gone (exited, closed, reaped).
  func forgetRun(for targetID: TerminalTarget.ID) {
    lastRunStatus[targetID] = nil
    restoredRuns.remove(targetID)
  }

  // MARK: Run command — supervisor control (issues #7, #522)
  //
  // The run command runs under a long-lived SUPERVISOR (`workroomd run-supervisor`) as the pty child
  // of a daemon session, on this Mac or on the workroom's host. The app asks the daemon to signal
  // it, and reads the run's STATE from the session's program status, which carries what the
  // supervisor writes. Start, stop and restart are serialized inside the supervisor, so the
  // session is never replaced for a restart, and a relaunch happens only once the previous child
  // has fully exited (no "A server is already running").

  /// The run session of the target's run tab, or nil when it has none (no daemon took it).
  private func runSessionID(for targetID: TerminalTarget.ID) -> UUID? {
    guard let tab = runStates[targetID]?.tab else { return nil }
    return terminals.view(forTab: tab, inTarget: targetID)?.persistentSessionID
  }

  /// Asks the target's run supervisor, through its daemon, to restart, stop or quit, and hands the
  /// outcome to `then` on the main actor: `.gone` when its daemon holds no such session (or the tab
  /// never got one), so nothing runs and starting it again cannot double it; `.unknown` when the
  /// daemon could not be asked or refused, which must never be read as gone (R9).
  func signalSupervisor(
    _ signal: RunSignal, for targetID: TerminalTarget.ID,
    then: @escaping (RunSignalOutcome) -> Void = { _ in }
  ) {
    if let signalSupervisorForTesting {
      then(signalSupervisorForTesting(signal, targetID))
      return
    }
    guard let session = runSessionID(for: targetID) else {
      then(.gone)
      return
    }
    Task { @MainActor in
      then(await PersistentSessionService.shared.signalRun(sessionID: session, signal))
    }
  }

  /// Flip the run surface's "stopped — press any key to close" flag (issue #7): while stopped (the
  /// supervisor is parked, processHasExited is false), a key in the run pane closes the tab; cleared
  /// on a (re)start.
  func setRunStoppedAwaitingClose(
    _ value: Bool, tab: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    terminals.view(forTab: tab, inTarget: target)?.runStoppedAwaitingClose = value
  }

  /// Whether any run terminal exists (running or stopped-but-open) — gates Room ▸ Go to Run
  /// Terminal.
  var hasAnyRunTerminal: Bool { runStates.values.contains { $0.tab != nil } }

  /// Told when a signal could not be confirmed (`.unknown`), with the target and why, so the run's
  /// pane can say so. Set by `AppStore`.
  var onSignalUnconfirmed: ((TerminalTarget.ID, String) -> Void)?

  /// Stop the run command (issue #7): one press tells the SUPERVISOR to stop the child gracefully and
  /// keep the pane (USR2 — it SIGINTs the child's foreground group, waits for it to fully exit, and
  /// SIGKILLs on a 6s timeout for a process that ignores SIGINT). No second-press hard-kill / surface
  /// free — the supervisor owns the teardown. State flips to `.running(interrupted)` (stop in flight),
  /// then the run's status drives it to `.stopped`. A run whose session has gone is stopped already.
  func stopRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab):
      runStates[target.id] = .running(tab: tab, interrupted: true)
      signalSupervisor(.stop, for: target.id) { [weak self] outcome in
        guard let self, self.runStates[target.id]?.tab == tab else { return }
        switch outcome {
        case .delivered: break
        case .gone:
          self.runStates[target.id] = .stopped(tab: tab)
          self.runOutcomes[target.id] = .stoppedByUser
        case .unknown(let reason):
          self.onSignalUnconfirmed?(target.id, reason)
        }
      }
    case .armed, .stopped, .none:
      break  // nothing executing to stop
    }
  }

  // MARK: Run command — graceful teardown (issue #7, Option B)

  /// The target's run surface if its run is going and a process is still alive in it, else nil.
  /// Used by the teardown paths to decide whether a stop + wait is needed before freeing it. A
  /// stopped run's pane can hold a live process (the parked supervisor, or the relay showing that
  /// its session is gone) that no stop would end (#522).
  private func liveRunView(for targetID: TerminalTarget.ID) -> GhosttySurfaceView? {
    guard let state = runStates[targetID], state.isRunning, let tabID = state.tab,
      let view = terminals.view(forTab: tabID, inTarget: targetID),
      view.hasLiveProcess
    else { return nil }
    return view
  }

  /// Whether any run command still has a live process — gates the quit handler's graceful wait.
  /// Also true for a live Investigate session (issue #146), even though it has no `RunState` and
  /// no supervisor to gracefully stop — see `investigateTabs`.
  /// Whether a run command (not an Investigate tab) is going: what a quit may keep or stop (#522).
  var hasLiveRun: Bool { runStates.keys.contains { liveRunView(for: $0) != nil } }

  var hasLiveRunCommand: Bool {
    runStates.keys.contains { liveRunView(for: $0) != nil }
      || investigateTabs.contains { tabID, targetID in
        terminals.view(forTab: tabID, inTarget: targetID)?.hasLiveProcess ?? false
      }
  }

  /// Tell each target's SUPERVISOR to quit (TERM — it stops the child gracefully, waits for it,
  /// SIGKILLs on a 6s timeout, then exits, which ends its session), and run `then` once every run
  /// surface's child has actually exited, or after `timeout` (the fallback, as for a host that does
  /// not answer). Polls `hasLiveProcess` on the main runloop; NEVER frees a surface itself, so it
  /// can't race libghostty's teardown. What the run left outside its supervisor's tree, the daemon
  /// ends as the session does (R8).
  func gracefullyStopRuns(
    _ targetIDs: [TerminalTarget.ID], timeout: TimeInterval = 6, then: @escaping () -> Void
  ) {
    var views: [GhosttySurfaceView] = []
    for id in targetIDs {
      guard let view = liveRunView(for: id) else { continue }
      signalSupervisor(.quit, for: id)  // supervisor stops the child, then exits → session ends
      views.append(view)
    }
    guard !views.isEmpty else {
      then()
      return
    }
    pollUntilExited(views, deadline: Date().addingTimeInterval(timeout), then: then)
  }

  /// Wait until the surfaces' children have exited, then run `then`; at `deadline`, run it anyway.
  /// With `views` empty this completes synchronously, so callers must already be off any libghostty
  /// callback stack.
  func pollUntilExited(
    _ views: [GhosttySurfaceView], deadline: Date, then: @escaping () -> Void
  ) {
    if views.allSatisfy({ !$0.hasLiveProcess }) || Date() >= deadline {
      then()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.pollUntilExited(views, deadline: deadline, then: then)
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

  /// Stop all live run commands and wait for them to exit (bounded) before `completion`. Called by a
  /// quit that is to stop dev servers (the quit setting, #522); a quit that keeps them signals
  /// nothing. Never frees a surface.
  func gracefullyStopAllRunCommands(timeout: TimeInterval = 6, completion: @escaping () -> Void) {
    gracefullyStopRuns(Array(runStates.keys), timeout: timeout, then: completion)
  }

  /// Arm a just-created workroom to auto-run its project's command as its first terminal (issue #7).
  /// Called from `createWorkroom`; the run fires from `ensureInitialTerminal` when the pane mounts.
  func armAutoRun(forWorkroom targetID: TerminalTarget.ID) {
    runStates[targetID] = .armed
  }
}
