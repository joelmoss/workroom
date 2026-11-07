import Defaults
import Foundation
import WorkroomDomain
import WorkroomVCS
import WorkroomWire

/// The app's run commands (issue #7), one for the whole app: each project's run config, which
/// window runs a workroom's command (#70), a run's hand-over between windows (#444), the quit and
/// delete checks that span every window, and the host's own runs for a remote workroom (D7).
///
/// What is known of a run is its run tab's (`TabRun`), kept beside the tab in the app's
/// `TerminalTabs`, so it stays put when the tab moves between windows. Which tab is a target's run
/// is the window's: two windows can show one workroom with tabs of their own (#444 Q12), and each
/// can hold a run for it (at most one running, #70), so each window's `RunCommandController` keeps,
/// per target, the pointer to its run tab and its own toast timers. Each window's controller is
/// registered here while the window is up (`WindowRegistry.register`). The Quick Terminal never
/// registers, as it never joins `WindowRegistry` (ADR 0064); its tabs' bookkeeping is in the same
/// registry, so an Investigate pane it hands to a window is still one there.
///
/// Production builds every window's store with `.shared`; tests build an isolated `AppStore()` with
/// its own, as they do `ProjectStore`.
@MainActor
@Observable
// `ObservableObject` only so views can take it as an `@EnvironmentObject`, as they take the store;
// Observation tracks the reads.
final class RunCommands: ObservableObject {
  static let shared = RunCommands()

  // MARK: Run config

  /// Bumped by `setRunConfig` and read by `runConfig(forProject:)`, so every window's run controls
  /// re-render when a run command is saved, from any window or Settings: the config lives in
  /// `Defaults`, which Observation cannot see.
  private(set) var runConfigRevision = 0

  /// The run config for a project path (empty if none set). Single read path for the toolbar, menu,
  /// Settings ▸ Projects, and auto-run. Stored app-side in `Defaults` (GUI-only — the CLI can't hold a
  /// long-running process, so it's deliberately out of the `--json` contract, like branch labels).
  func runConfig(forProject projectPath: String) -> RunConfig {
    _ = runConfigRevision  // a read Observation tracks: `Defaults` is not observable
    return Defaults[.runCommands][projectPath] ?? .empty
  }

  /// Whether a project has a non-blank run command configured.
  func hasRunCommand(forProject projectPath: String) -> Bool {
    runConfig(forProject: projectPath).hasCommand
  }

  /// Persist a project's run config (issue #7). A blank command with auto-run off removes the entry
  /// so the map doesn't accrue dead keys.
  func setRunConfig(_ config: RunConfig, forProject projectPath: String) {
    var map = Defaults[.runCommands]
    if config.hasCommand || config.autoRun {
      map[projectPath] = RunConfig(
        command: config.command.trimmingCharacters(in: .whitespacesAndNewlines),
        autoRun: config.autoRun)
    } else {
      map[projectPath] = nil
    }
    Defaults[.runCommands] = map
    runConfigRevision += 1
  }

  // MARK: Windows

  /// The registered windows' run controllers, in the order their windows registered.
  @ObservationIgnored private var registered = WeakList<RunCommandController>()

  /// Count `runs`' window in the checks that span every window. Idempotent, as window registration is.
  func register(_ runs: RunCommandController) {
    registered.insert(runs)
  }

  /// Its window has gone.
  func unregister(_ runs: RunCommandController) {
    registered.remove(runs)
  }

  private var windows: [RunCommandController] { registered.elements }

  /// The other window already running `target`'s run command, if any. Derived from each window's live
  /// `runStates` (no separate map to drift): a second window's Run focuses this owner instead of
  /// forking a duplicate dev server on the same port (issue #70 / issue #7).
  func runOwner(
    for target: TerminalTarget.ID, excluding: RunCommandController
  ) -> RunCommandController? {
    windows.first { $0 !== excluding && ($0.runStates[target]?.isRunning ?? false) }
  }

  /// Whether any window has a live Investigate session (issue #146) for any of `targetIDs` — used
  /// to warn before `deleteWorkroom`/`deleteProject` reap those targets' surfaces. Both delete flows
  /// stop and reap unconditionally (even `.configOnly`, which keeps files but still tears down live
  /// terminals), and neither goes through `hasLiveRunCommand`/`gracefullyStopRuns` (which only know
  /// about `runStates`) — so without this check, deleting silently kills a live agent session with
  /// no wait or warning, and for `.workrooms`/`.fromDisk` also deletes the directory out from under it.
  func hasLiveInvestigateSession(for targetIDs: [TerminalTarget.ID]) -> Bool {
    let ids = Set(targetIDs)
    return windows.contains { $0.hasLiveInvestigateSession(for: ids) }
  }

  // MARK: Quit

  /// Set by a quit that stops dev servers, before it saves: their run tabs are left out of every
  /// window's layout, here and on hosts, so they don't come back (#522, owner).
  @ObservationIgnored var quitStopsRuns = false

  /// Whether any window's run command (not an Investigate tab) is going: what quitting may keep
  /// running or stop (#522).
  var hasAnyLiveRun: Bool { windows.contains(where: \.hasLiveRun) }

  /// Ctrl-C every window's live run commands and let them exit before the process dies, so dev
  /// servers release their ports/pidfiles instead of being orphaned by the OS hangup (issue #7).
  /// Calls `completion` once all windows have stopped (or each one's timeout elapses).
  func gracefullyStopAllWindows(timeout: TimeInterval, completion: @escaping () -> Void) {
    let live = windows.filter(\.stopsRunsBeforeClosing)
    guard !live.isEmpty else {
      completion()
      return
    }
    let group = DispatchGroup()
    for runs in live {
      group.enter()
      runs.gracefullyStopAllRunCommands(timeout: timeout) { group.leave() }
    }
    group.notify(queue: .main) { completion() }
  }

  // MARK: A run tab's bookkeeping

  /// What is known of one run tab's run, or that a tab is an Investigate session (#146). It is the
  /// tab's, not a window's: it lives beside the tab in `TerminalTabs`, is read only by the window
  /// holding the tab, and goes when the tab closes or is reaped, never when the tab moves to another
  /// window (#444, ADR 0069). Each cell is observed on its own, so a write to one run redraws only
  /// what reads that run. Windows reach it through `RunCommandController`'s per-target facades.
  @MainActor
  @Observable
  final class TabRun {
    /// How the run ended, nil while it has not (issue #67).
    var outcome: RunCommandController.RunOutcome?
    /// The last status line applied, so a repeated report changes nothing.
    var lastStatus: String?
    /// Reattached from a saved session and not reported yet (#522).
    var restored = false
    /// Its toast was dismissed, by hand or after lingering.
    var toastDismissed = false
    /// Its live toast auto-hid after lingering.
    var toastAutoHidden = false
    /// The tab is an Investigate session (#146), not a run command.
    var investigate = false
  }

  // MARK: Hand-over between windows (#444)

  /// Which run is a target's in the window a workroom leaves, carried to the window it joins
  /// (`RunCommandController.takeHandOff` and `adopt`): the window's pointer to its run tab, and
  /// whether the window's toast timer for it was still to fire, so the destination starts its own.
  /// Everything else known of the run is the run tab's (`TabRun`), which stays where it is.
  struct HandOff {
    var state: RunCommandController.RunState?
    var toastTimerPending = false
  }

  // MARK: A remote workroom's runs (D7)

  /// The live run sessions `host`'s daemon holds for `workroom` (D7), or none when it can't say.
  /// Connects first, as no pane of the workroom may have yet: the user asked for the run, so its
  /// host is activated (a stopped container is started) and woken (`docs/remote-host-states.md`).
  static func liveRunSessions(on host: HostID, workroom: String) async -> [UUID] {
    RemoteHosts.shared.reachability.activate(host)
    try? await RemoteHosts.shared.reachability.ensureConnected(host, wake: true)
    guard
      let sessions = try? await HostConnectionManager.shared.sessions(on: host)
    else { return [] }
    return runSessions(in: sessions, workroom: workroom)
  }

  /// The run sessions among `sessions` that are `workroom`'s.
  static func runSessions(in sessions: [SessionDescriptor], workroom: String) -> [UUID] {
    sessions.compactMap { descriptor in
      guard descriptor.value(forMetadataKey: SessionMetadataKey.workroom) == workroom,
        descriptor.value(forMetadataKey: RunSessionKey.kind) == RunSessionKey.run
      else { return nil }
      return descriptor.identifier.uuid
    }
  }
}
