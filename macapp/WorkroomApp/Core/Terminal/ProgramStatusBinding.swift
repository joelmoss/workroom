import DaemonConnection
import Foundation
import WorkroomDomain

/// Binds one window's terminal tabs to the program status their sessions report (#358,
/// `docs/program-status.md`): puts the monitor's rollup on every tab attached to a session that
/// changed, marks finished and failed records seen as focus moves, and tells the sessions' owner
/// what each run tab's session says (#522). `TerminalPanes` follows a host here when it makes or
/// adopts a daemon-backed tab, and hands it each surface's focus changes.
@MainActor
final class ProgramStatusBinding {
  private let access: TerminalTabAccess

  /// Where pane indicators read program status from. Tests swap in their own.
  var monitor: ProgramStatusMonitor = .shared
  /// The sessions' `PersistentSessionService`, kept in step by `TerminalPanes`.
  var sessionService: PersistentSessionService
  private var listener: UUID?
  /// Tabs where a `done` arrived while they had focus: it is marked seen when focus leaves, so a
  /// finish the user watched happen leaves no checkmark behind.
  private var watchedDone: Set<TerminalTab.ID> = []

  init(access: TerminalTabAccess, sessionService: PersistentSessionService) {
    self.access = access
    self.sessionService = sessionService
  }

  /// Forget a tab that left the window (close, reap, hand-off): a finish it watched is not marked
  /// seen by a focus change it will not get here.
  func forget(_ tabID: TerminalTab.ID) {
    watchedDone.remove(tabID)
  }

  /// Hear the monitor's changes (once per window) and have it watch `host`.
  func follow(_ host: HostID) {
    if listener == nil {
      listener = monitor.addListener { [weak self] change in
        self?.applyProgramStatus(change.sessions)
        self?.applyRunStatus(change)
      }
    }
    monitor.watch(host)
  }

  /// Tells `AppStore` what each run tab's session on `change.host` now says (#522): its run's state
  /// when the daemon has one, or that the session is gone. Gone is known only from what the host
  /// said, a snapshot that did not name the session or an `ended` for it, never from a monitor that
  /// has not heard from the host yet.
  func applyRunStatus(_ change: ProgramStatusMonitor.Change) {
    for (targetID, tabID, state) in access.terminals() {
      guard state.launch.isRunSession, let sessionID = state.sessionID,
        (sessionService.remoteHost(of: sessionID) ?? .local) == change.host,
        change.isSnapshot || change.sessions.contains(sessionID)
      else { continue }
      reportRunStatus(of: sessionID, tab: tabID, target: targetID, gone: true)
    }
  }

  /// What the monitor already knows about a run tab that has just appeared (a restore, after its
  /// host's snapshot may have come): its state, or that it is gone once the host has answered.
  func reportRunStatus(tab tabID: TerminalTab.ID, target: TerminalTarget) {
    guard let state = access.state(tabID, target.id), state.launch.isRunSession,
      let sessionID = state.sessionID
    else { return }
    reportRunStatus(
      of: sessionID, tab: tabID, target: target.id,
      gone: monitor.hasSnapshot(of: target.remoteHost.map(HostID.remote) ?? .local))
  }

  /// `gone`: whether a session the monitor does not hold may be reported as gone.
  private func reportRunStatus(
    of sessionID: UUID, tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID, gone: Bool
  ) {
    if let run = monitor.run(for: sessionID) {
      access.raise(.runStatus(targetID, tabID, run))
    } else if gone, !monitor.hasSession(sessionID) {
      access.raise(.runSessionGone(targetID, tabID))
    }
  }

  /// Puts the monitor's rollup on every tab attached to `sessions`.
  func applyProgramStatus(_ sessions: Set<UUID>) {
    for (targetID, tabID, state) in access.terminals() {
      guard let sessionID = state.sessionID, sessions.contains(sessionID) else { continue }
      let rollup = monitor.rollup(for: sessionID)
      guard rollup != state.programStatus else { continue }
      if access.surface(tabID)?.isEffectivelyFocused == true, rollup?.done != nil,
        state.programStatus?.done == nil
      {
        watchedDone.insert(tabID)
      }
      access.mutate(tabID, targetID) { $0.programStatus = rollup }
    }
  }

  /// A tab pointed at another session (Detached sessions > Active tab) shows that session's
  /// status at once, not the old one's until the new session next changes.
  func refreshProgramStatus(tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID) {
    guard let sessionID = access.state(tabID, targetID)?.sessionID else { return }
    watchedDone.remove(tabID)
    let rollup = monitor.rollup(for: sessionID)
    access.mutate(tabID, targetID) { $0.programStatus = rollup }
  }

  /// Focus moving into a pane marks its finished and failed records seen; a finish watched while
  /// focused is marked seen when focus leaves. A status arriving in an already focused pane is not.
  func focusChanged(_ focused: Bool, tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID)
  {
    if focused { access.raise(.terminalSeen(targetID, tabID)) }
    guard let state = access.state(tabID, targetID), let sessionID = state.sessionID else {
      return
    }
    if focused {
      watchedDone.remove(tabID)
      if let status = state.programStatus, status.done != nil || status.error != nil {
        monitor.seen(sessionID)
      }
    } else if watchedDone.remove(tabID) != nil {
      monitor.seen(sessionID, states: ["done"])
    }
  }

  /// Every tab attached to `session`, and whether the user is looking at it now.
  func attachments(of session: UUID) -> [(
    target: TerminalTarget.ID, tab: TerminalTab.ID, focused: Bool
  )] {
    access.terminals().compactMap { targetID, tabID, state in
      guard state.sessionID == session else { return nil }
      return (targetID, tabID, access.surface(tabID)?.isEffectivelyFocused == true)
    }
  }

  /// Clear status (the tab's and the sidebar row's context menu): the escape hatch for a program
  /// that left a stale request behind.
  func clearProgramStatus(tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID) {
    guard let sessionID = access.state(tabID, targetID)?.sessionID else { return }
    monitor.clear(sessionID)
  }

  /// The UI-test fixture's seam (`UITestFixture.seedProgramStatus`): a fixture pane has no session
  /// (`TerminalPersistentSessionPolicy`), so give it one and seed its records straight into the
  /// monitor, which then reaches the tab as a real status event would.
  func seedForFixture(
    tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID, host: HostID,
    records: [ProgramStatusRecord], stale: Bool
  ) {
    let session = UUID()
    access.mutate(tabID, targetID) { $0.sessionID = session }
    follow(host)
    monitor.seed(session, host: host, records: records, stale: stale)
  }
}
