import Foundation
import WorkroomWire

/// Live sessions filtered to those no tab owns, keyed by workroom. Multiple status bars (split
/// panes, multiple windows on different workrooms) share this one instance, so the list must stay
/// per-workroom rather than a single flat array — otherwise whichever workroom's button refreshed
/// last overwrites what every OTHER workroom's button renders.
///
/// Read where the workroom's sessions run (#584): a local workroom's from this Mac's helpers, a
/// remote one's from its host's daemon. Each is keyed, and matched, by what its sessions are
/// tagged with (`TerminalTarget.sessionWorkroomKey`): a remote workroom's own id, which is not
/// `target.id` (#255).
@MainActor
final class DetachedSessionList: ObservableObject {
  static let shared = DetachedSessionList()

  @Published private(set) var detachedByWorkroom: [String: [SessionDescriptor]] = [:]

  /// Where a local session is ended, and where a remote one a pane attached to is registered.
  private let service: PersistentSessionService
  /// Where a remote workroom's host is asked, over the connection already there.
  private let connections: HostConnectionManager
  /// This Mac's helpers' sessions.
  private let localSessions: () async -> [SessionDescriptor]

  init(
    service: PersistentSessionService = .shared,
    connections: HostConnectionManager = .shared,
    localSessions: (() async -> [SessionDescriptor])? = nil
  ) {
    self.service = service
    self.connections = connections
    self.localSessions = localSessions ?? { await service.liveSessions() }
  }

  func detached(for target: TerminalTarget) -> [SessionDescriptor] {
    detachedByWorkroom[target.sessionWorkroomKey] ?? []
  }

  /// Keeps `target`'s list while the caller runs (a footer's `.task`): read once for a local
  /// workroom, and for a remote one each time its host connects, since a pane's footer mounts
  /// before the pane's own attach has brought the host up. Never connects: a host this app isn't
  /// connected to (unreachable, asleep, stopped, still connecting) lists nothing until it is.
  func follow(_ target: TerminalTarget, ownedSessionIDs: () -> Set<UUID>) async {
    guard target.remoteHost != nil else {
      return await refresh(target, ownedSessionIDs: ownedSessionIDs())
    }
    var listed: HostConnectionManager.Lease?
    for await snapshot in await connections.updates(for: target.hostID) {
      switch snapshot.status {
      // Once per connection: the manager publishes each change of state, not each request.
      case .connected where snapshot.lease != listed:
        listed = snapshot.lease
        await refresh(target, ownedSessionIDs: ownedSessionIDs())
      case .disconnected:
        listed = nil
        detachedByWorkroom[target.sessionWorkroomKey] = nil
      case .connected, .connecting: break
      }
    }
  }

  func refresh(_ target: TerminalTarget, ownedSessionIDs: Set<UUID>) async {
    let key = target.sessionWorkroomKey
    let sessions: [SessionDescriptor]
    if target.remoteHost != nil {
      // Over the connection already there, never a new one: a footer is no reason to reach a
      // host, or to wake one (`docs/remote-host-states.md`). A host that can't answer lists none.
      sessions = (try? await connections.sessions(on: target.hostID)) ?? []
    } else {
      sessions = await localSessions()
    }
    detachedByWorkroom[key] = sessions.filter { session in
      session.value(forMetadataKey: SessionMetadataKey.workroom) == key
        && (session.identifier.uuid.map { !ownedSessionIDs.contains($0) } ?? true)
    }
  }

  /// Ends a session the list shows, where it runs, then reads the list again.
  func stop(_ sessionID: UUID, in target: TerminalTarget, ownedSessionIDs: Set<UUID>) async {
    if target.remoteHost == nil || service.isRemote(sessionID) {
      // A remote session a pane here attached to is registered, and its kill retries.
      await service.endSession(sessionID: sessionID)
    } else {
      // One this app never attached to: its host ends it. The local helpers never held it.
      _ = try? await connections.endSession(sessionID, on: target.hostID)
    }
    await refresh(target, ownedSessionIDs: ownedSessionIDs)
  }
}
