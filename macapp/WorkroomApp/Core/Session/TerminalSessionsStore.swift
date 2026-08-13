import Foundation
import WorkroomSessionProtocol

/// Live daemon sessions filtered to those no tab owns, keyed by workroom. Multiple status bars
/// (split panes, multiple windows on different workrooms) share this one instance, so the list
/// must stay per-workroom rather than a single flat array — otherwise whichever workroom's button
/// refreshed last overwrites what every OTHER workroom's button renders.
@MainActor
final class TerminalSessionsStore: ObservableObject {
  static let shared = TerminalSessionsStore()

  @Published private(set) var detachedByWorkroom: [String: [SessionDescriptor]] = [:]

  private init() {}

  func detached(for workroomID: String) -> [SessionDescriptor] {
    detachedByWorkroom[workroomID] ?? []
  }

  func refresh(workroomID: String, ownedSessionIDs: Set<UUID>) async {
    let sessions = await PersistentSessionService.shared.liveSessions()
    detachedByWorkroom[workroomID] = sessions.filter { session in
      session.value(forMetadataKey: SessionMetadataKey.workroom) == workroomID
        && (session.identifier.uuid.map { !ownedSessionIDs.contains($0) } ?? true)
    }
  }
}
