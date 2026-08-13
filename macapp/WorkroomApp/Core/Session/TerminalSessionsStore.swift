import Foundation
import WorkroomSessionProtocol

/// Live daemon sessions for the current workroom, filtered to those no tab owns.
@MainActor
final class TerminalSessionsStore: ObservableObject {
  static let shared = TerminalSessionsStore()

  @Published private(set) var detached: [SessionDescriptor] = []

  private init() {}

  func refresh(workroomID: String, ownedSessionIDs: Set<UUID>) async {
    let sessions = await PersistentSessionService.shared.liveSessions()
    detached = sessions.filter { session in
      session.value(forMetadataKey: SessionMetadataKey.workroom) == workroomID
        && (session.identifier.uuid.map { !ownedSessionIDs.contains($0) } ?? true)
    }
  }
}
