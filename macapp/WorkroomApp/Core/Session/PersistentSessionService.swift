import Foundation
import WorkroomSessionProtocol
import os

enum PersistentSessionLookup {
  case live(SessionDescriptor)
  case missing
  case unreachable
}

@MainActor
final class PersistentSessionService {
  static let shared = PersistentSessionService()

  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  private var resolvedSocketPath: String?
  private var descriptors: [UUID: SessionDescriptor] = [:]

  private init() {}

  var socketPath: String? {
    if let resolvedSocketPath { return resolvedSocketPath }
    do {
      let path = try PersistentSessionPaths.resolveSocketPath()
      resolvedSocketPath = path
      return path
    } catch {
      logger.error("unable to resolve the session socket path: \(String(describing: error))")
      return nil
    }
  }

  var existingSocketPath: String? {
    let candidates = [
      try? PersistentSessionPaths.preferredSocketPath(),
      try? PersistentSessionPaths.fallbackSocketPath(),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
  }

  var binaryPath: String? { PersistentSessionPaths.binaryURL()?.path }

  var isAvailable: Bool { socketPath != nil && binaryPath != nil }

  func attachCommand() -> String? {
    guard let binaryPath else { return nil }
    return binaryPath.replacingOccurrences(of: " ", with: "\\ ") + " attach"
  }

  func launchEnvironment(
    sessionID: UUID,
    workingDirectory: String,
    metadata: [(key: String, value: String)] = [],
    shell: String = ProcessInfo.processInfo.environment["SHELL"]
      ?? SessionShellIntegration
      .defaultShell,
    resourcesDirectory: String? = GhosttyResources.bundledURL?.path
  ) -> [(key: String, value: String)] {
    guard let socketPath, let binaryPath else { return [] }
    var entries: [(key: String, value: String)] = [
      ("WORKROOM_SESSION_ID", sessionID.uuidString),
      ("WORKROOM_SESSION_SOCKET", socketPath),
      ("WORKROOM_SESSION_BINARY", binaryPath),
      ("WORKROOM_SESSION_SHELL", shell),
      ("WORKROOM_SESSION_CWD", workingDirectory),
      ("WORKROOM_SESSION_COMMAND", ""),
    ]
    if let resourcesDirectory {
      entries.append(("WORKROOM_SESSION_RESOURCES", resourcesDirectory))
    }
    let variables: [String: String] = [
      SessionMetadataKey.project: "WORKROOM_SESSION_PROJECT",
      SessionMetadataKey.workroom: "WORKROOM_SESSION_WORKROOM",
      SessionMetadataKey.tab: "WORKROOM_SESSION_TAB",
      SessionMetadataKey.title: "WORKROOM_SESSION_TITLE",
    ]
    for entry in metadata {
      guard let variable = variables[entry.key], !entry.value.isEmpty else { continue }
      entries.append((variable, entry.value))
    }
    return entries
  }

  func liveSessions() async -> [SessionDescriptor] {
    guard let socketPath = existingSocketPath else { return [] }
    let client = PersistentSessionControlClient(socketPath: socketPath)
    return await Task.detached(priority: .utility) { client.list() }.value
  }

  func lookup(sessionID: UUID) async -> PersistentSessionLookup {
    guard let socketPath = existingSocketPath,
      let identifier = SessionIdentifier(uuidString: sessionID.uuidString)
    else { return .unreachable }
    let client = PersistentSessionControlClient(socketPath: socketPath)
    return await Task.detached(priority: .utility) {
      guard FileManager.default.fileExists(atPath: socketPath) else { return .unreachable }
      if let descriptor = client.info(identifier: identifier) { return .live(descriptor) }
      return .missing
    }.value
  }

  func isLive(sessionID: UUID) async -> Bool {
    if case .live = await lookup(sessionID: sessionID) { return true }
    return false
  }

  @discardableResult
  func endSession(sessionID: UUID) async -> Bool {
    descriptors.removeValue(forKey: sessionID)
    guard let socketPath = existingSocketPath,
      let identifier = SessionIdentifier(uuidString: sessionID.uuidString)
    else { return true }
    let client = PersistentSessionControlClient(socketPath: socketPath)
    let killed = await Task.detached(priority: .utility) { client.kill(identifier: identifier) }
      .value
    if !killed {
      logger.error("failed to kill persistent session \(sessionID.uuidString, privacy: .public)")
    }
    return killed
  }

  /// Awaits every kill before returning so a caller can safely delete the workroom's directory
  /// afterward — a persisted shell that's still exiting must not be racing the teardown (issue #7).
  func endSessions(matchingWorkroom workroomID: String) async {
    let sessions = await liveSessions()
    for session in sessions
    where session.value(forMetadataKey: SessionMetadataKey.workroom) == workroomID {
      if let uuid = session.identifier.uuid { await endSession(sessionID: uuid) }
    }
  }

  /// Kills every live daemon session except those in `attachedSessionIDs` — a session still owned
  /// by an open tab in some window is left running rather than yanked out from under whoever is
  /// looking at it right now. Pass an empty set (the default) to kill everything.
  func endAllSessions(excluding attachedSessionIDs: Set<UUID> = []) async {
    guard !attachedSessionIDs.isEmpty else {
      descriptors.removeAll()
      guard let socketPath = existingSocketPath else { return }
      let client = PersistentSessionControlClient(socketPath: socketPath)
      _ = await Task.detached(priority: .utility) { client.killAll() }.value
      return
    }
    let sessions = await liveSessions()
    for session in sessions {
      guard let uuid = session.identifier.uuid, !attachedSessionIDs.contains(uuid) else { continue }
      await endSession(sessionID: uuid)
    }
  }
}
