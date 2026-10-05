import Foundation
import WorkroomSessionProtocol

/// A window's state for the remote workrooms whose layouts their hosts keep (#255,
/// `docs/designs/oq8-cross-machine-reattach.md`).
struct HostLayoutState {
  /// Asked its host, not answered yet: no fresh pane opens meanwhile (D4).
  var fetching: Set<TerminalTarget.ID> = []
  /// Answered, or given up on, this launch: never asked again until the next.
  var fetched: Set<TerminalTarget.ID> = []
  /// Showing on screen while its host was asked: opens its first pane once it has answered.
  var waitingForFirstTab: Set<TerminalTarget.ID> = []
  /// The host revision this window last read or wrote.
  var revisions: [TerminalTarget.ID: UInt64] = [:]
  /// This window's layout has not reached the host (`TargetSession.hostLayoutStale`).
  var stale: Set<TerminalTarget.ID> = []
  /// The host's layout is from a newer build: never written over (D5).
  var readOnly: Set<TerminalTarget.ID> = []
  /// The layout as the host last had it, encoded, so an unchanged one is never written again.
  var written: [TerminalTarget.ID: String] = [:]
}

/// Which window on this Mac keeps each remote workroom's layout on its host (D10). Two windows can
/// show one workroom; only the first to show it this launch restores the host's layout and writes
/// it, so they never take turns overwriting it. Ownership passes on when that window closes or has
/// no tabs left for the workroom.
@MainActor
final class HostLayoutOwners {
  static let shared = HostLayoutOwners()

  private struct Owner {
    weak var store: AppStore?
    let targetID: TerminalTarget.ID
  }
  private var owners: [UUID: Owner] = [:]

  /// Whether `store` keeps `workroom`'s layout, claiming it if nobody else holds it.
  func claim(_ workroom: UUID, targetID: TerminalTarget.ID, by store: AppStore) -> Bool {
    if let owner = owners[workroom], let current = owner.store, current !== store,
      current.hostLayouts.fetching.contains(owner.targetID)
        || current.terminals.tabCount(forTargetID: owner.targetID) > 0
    {
      return false
    }
    owners[workroom] = Owner(store: store, targetID: targetID)
    return true
  }

  func owns(_ workroom: UUID, _ store: AppStore) -> Bool { owners[workroom]?.store === store }
}

extension AppStore {
  /// How long a remote workroom waits for its host's layout before restoring this Mac's own copy
  /// (D4). The connect is inside it, so a host that is slow to answer never blanks the workroom.
  static let hostLayoutTimeout: TimeInterval = 5

  /// Asks `target`'s host for its layout and sessions, unless this launch has already asked or
  /// another window keeps the workroom's layout, and says whether `target` is now waiting on that
  /// answer: if so, the caller opens no pane, and `applyHostLayout` restores what was chosen.
  ///
  /// Only for a reachable remote workroom with its own id: one recorded before workroom ids has no
  /// key a host could keep its layout under, and restores from this Mac alone.
  @discardableResult
  func fetchHostLayoutIfNeeded(for target: TerminalTarget) -> Bool {
    guard let host = target.remoteHost, let workroom = target.remoteWorkroomID else { return false }
    if hostLayouts.fetching.contains(target.id) { return true }
    guard !hostLayouts.fetched.contains(target.id),
      terminals.tabCount(forTargetID: target.id) == 0,
      HostLayoutOwners.shared.claim(workroom, targetID: target.id, by: self)
    else { return false }
    hostLayouts.fetching.insert(target.id)
    let held = deferredTargetSessions[target.id]
    let key = workroom.uuidString
    let targetID = target.id
    Task { [weak self] in
      let outcome = try? await withTimeout(seconds: Self.hostLayoutTimeout) {
        () -> (HostLayoutResolution, [SessionDescriptor]) in
        try await RemoteHosts.shared.ensureConnected(.remote(host))
        let store = try await HostConnectionManager.shared.layouts(host: .remote(host))
        let resolution = try await HostLayoutSync.resolve(
          held: held, key: key, targetID: targetID, store: store)
        let sessions = (try? await HostConnectionManager.shared.sessions(on: .remote(host))) ?? []
        return (resolution, sessions)
      }
      self?.applyHostLayout(outcome, for: targetID, held: held, key: key)
    }
    return true
  }

  /// Restores what `fetchHostLayoutIfNeeded` chose, or this Mac's own copy when the host did not
  /// answer in time, has no Layout service, or keeps no layouts.
  private func applyHostLayout(
    _ outcome: (HostLayoutResolution, [SessionDescriptor])?, for targetID: TerminalTarget.ID,
    held: TargetSession?, key: String
  ) {
    hostLayouts.fetching.remove(targetID)
    hostLayouts.fetched.insert(targetID)
    guard let target = terminalTarget(forID: targetID) else { return }
    deferredTargetSessions.removeValue(forKey: targetID)
    var session = held
    if let (resolution, sessions) = outcome {
      hostLayouts.revisions[targetID] = resolution.revision
      if resolution.stale {
        hostLayouts.stale.insert(targetID)
      } else {
        hostLayouts.stale.remove(targetID)
      }
      if resolution.readOnly { hostLayouts.readOnly.insert(targetID) }
      // What the host now holds, as written: an unchanged layout is never written back.
      if !resolution.stale {
        hostLayouts.written[targetID] = resolution.session.flatMap {
          try? HostLayout.encode($0, key: key)
        }
      }
      // A session the layout does not name comes back as a tab (premise 3); the append is an
      // ordinary change, written through with the next save.
      session = HostLayoutSync.appending(
        sessions, key: key, to: resolution.session, targetID: targetID)
    } else {
      hostLayouts.revisions[targetID] = held?.hostRevision
      if held?.hostLayoutStale == true { hostLayouts.stale.insert(targetID) }
    }
    if let session, terminals.tabCount(forTargetID: targetID) == 0 {
      terminals.restore(session, for: target)
      refreshSelectionHasTabs()
    }
    markSessionDirty()
    if hostLayouts.waitingForFirstTab.remove(targetID) != nil {
      ensureInitialTerminal(for: target)
      terminals.reconcileOcclusion(for: target)
    }
  }

  /// `captured` with this window's record of its host's copy, for `session.json`.
  func withHostLayoutState(_ captured: TargetSession) -> TargetSession {
    var target = captured
    target.hostRevision = hostLayouts.revisions[captured.targetID]
    target.hostLayoutStale = hostLayouts.stale.contains(captured.targetID) ? true : nil
    return target
  }
}
