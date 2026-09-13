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

  /// One socket path per backend. They deliberately differ, so these must never be conflated —
  /// the daemon's sessions and the agent's are reached through different files.
  private var resolvedSocketPaths: [SessionBackend: String] = [:]
  /// Where new sessions go. Cached because resolving it runs the agent to check it works, and
  /// that answer does not change within a launch.
  private var cachedPreferred: SessionBackend?
  /// Which helper owns each session, resolved once. See `backend(forSession:)` for why one answer
  /// per session rather than one per call — a pane asks twice and the two must agree.
  private var owners: [UUID: SessionBackend] = [:]
  private var descriptors: [UUID: SessionDescriptor] = [:]

  private init() {}

  /// Where a NEW session would be created. Existing sessions are resolved individually — see
  /// `backend(forSession:)`, which is what makes the migration invisible.
  var backend: SessionBackend {
    if let cachedPreferred { return cachedPreferred }
    let resolved = SessionBackend.preferred()
    cachedPreferred = resolved
    return resolved
  }

  /// Which helper owns an EXISTING session, or where a new one should go.
  ///
  /// This is the whole migration. A session the Swift daemon is already holding stays with the
  /// daemon — it owns that pty and cannot hand it over — so it keeps running until the user closes
  /// it. Everything new goes to the agent. Nobody has to choose, and nothing is taken away
  /// mid-use.
  ///
  /// **Resolved once per session and remembered.** It used to re-probe on every call, and one pane
  /// asks twice — `attachCommand` for the binary, `launchEnvironment` for the socket. A daemon that
  /// answered the first inside its 2-second deadline and missed the second handed libghostty
  /// `workroom-session attach` pointed at `agent.sock`: the Swift daemon then binds the agent's
  /// socket, which `SessionBackend` says cannot happen by construction, and every agent session
  /// becomes unlistable. One answer per session is what makes the pair consistent.
  ///
  /// An answer cached from an `unreachable` probe pins that session to the daemon for the rest of
  /// the launch. That is the deliberate direction — see `daemonOwnership`.
  func backend(forSession sessionID: UUID) -> SessionBackend {
    if let known = owners[sessionID] { return known }
    let resolved = resolveOwner(sessionID)
    owners[sessionID] = resolved
    return resolved
  }

  private func resolveOwner(_ sessionID: UUID) -> SessionBackend {
    // No round trip when it cannot change the answer: if new sessions go to the daemon too, then
    // owned or not, this session's helper is the daemon. Skips a 2-second main-actor block on
    // every pane of a build with no working agent.
    guard backend != .swiftDaemon else { return .swiftDaemon }
    return Self.owner(preferred: backend, daemon: daemonOwnership(sessionID))
  }

  /// Which helper a session belongs to, given where new sessions go and what the daemon said.
  ///
  /// Pure, and separate from the probe, because the interesting part is the RULE and the probe is
  /// a socket round-trip no unit test should need. Note the asymmetry in the `unreachable` case —
  /// it is the whole point and it is not a coin flip:
  ///
  /// - Wrong toward the daemon fails **loudly**: `workroom-session attach` finds no such session
  ///   and the pane says so.
  /// - Wrong toward the agent fails **silently and destructively**: the agent creates on first
  ///   attach, so it forks a SECOND pty under the same id. The user's running shell is orphaned
  ///   where no pane can reach it, and the new pane shows a fresh prompt as though nothing was
  ///   lost.
  ///
  /// So an unanswered probe resolves to the daemon. Guessing wrong there costs an error message;
  /// guessing wrong the other way costs the user their work.
  /// `nonisolated` because it touches no state — the probe is the caller's job, and a pure rule
  /// should not need the main actor to evaluate.
  nonisolated static func owner(preferred: SessionBackend, daemon: SessionOwnership)
    -> SessionBackend
  {
    switch daemon {
    case .owned: return .swiftDaemon
    case .notOwned: return preferred
    case .unreachable: return .swiftDaemon
    }
  }

  /// What the shipped daemon says about this session.
  ///
  /// `notOwned` — not merely "no answer" — when there is no daemon socket at all: that is the
  /// steady state once the migration has drained, and it must not push every session at a daemon
  /// that is not running.
  private func daemonOwnership(_ sessionID: UUID) -> SessionOwnership {
    guard
      let identifier = SessionIdentifier(uuidString: sessionID.uuidString),
      let socketPath = existingSocketPath(for: .swiftDaemon)
    else { return .notOwned }
    return PersistentSessionControlClient(socketPath: socketPath).ownership(identifier: identifier)
  }

  func socketPath(for backend: SessionBackend) -> String? {
    if let cached = resolvedSocketPaths[backend] { return cached }
    do {
      let path = try PersistentSessionPaths.resolveSocketPath(backend: backend)
      resolvedSocketPaths[backend] = path
      return path
    } catch {
      logger.error("unable to resolve the session socket path: \(String(describing: error))")
      return nil
    }
  }

  var socketPath: String? { socketPath(for: backend) }

  func existingSocketPath(for backend: SessionBackend) -> String? {
    let candidates = [
      try? PersistentSessionPaths.preferredSocketPath(backend: backend),
      try? PersistentSessionPaths.fallbackSocketPath(backend: backend),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
  }

  var existingSocketPath: String? { existingSocketPath(for: backend) }

  func binaryPath(for backend: SessionBackend) -> String? {
    PersistentSessionPaths.binaryURL(for: backend)?.path
  }

  var binaryPath: String? { binaryPath(for: backend) }

  var isAvailable: Bool { socketPath != nil && binaryPath != nil }

  /// The command libghostty forks for this session, from the helper that owns it.
  func attachCommand(forSession sessionID: UUID) -> String? {
    guard let path = binaryPath(for: backend(forSession: sessionID)) else { return nil }
    return path.replacingOccurrences(of: " ", with: "\\ ") + " attach"
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
    // Socket and binary must both come from the helper that owns THIS session, or the relay is
    // pointed at one implementation while being told to use the other's socket.
    let backend = backend(forSession: sessionID)
    guard
      let socketPath = socketPath(for: backend),
      let binaryPath = binaryPath(for: backend)
    else { return [] }
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
    let variables = Dictionary(
      uniqueKeysWithValues: SessionMetadataKey.environmentVariables)
    for entry in metadata {
      guard let variable = variables[entry.key], !entry.value.isEmpty else { continue }
      entries.append((variable, entry.value))
    }
    return entries
  }

  private func controlPlane(
    socketPath: String, backend: SessionBackend
  ) -> any SessionControlPlane & Sendable {
    switch backend {
    case .swiftDaemon: return PersistentSessionControlClient(socketPath: socketPath)
    case .rustAgent: return AgentControlClient(socketPath: socketPath)
    }
  }

  /// A client for each helper that is actually running.
  ///
  /// Used wherever an operation spans every session rather than one — listing, and killing
  /// everything — because during the migration sessions genuinely live in both, and a caller that
  /// saw only one would orphan whatever it could not see.
  private func liveControlPlanes() -> [any SessionControlPlane & Sendable] {
    SessionBackend.allCases.compactMap { backend in
      guard let socketPath = existingSocketPath(for: backend) else { return nil }
      return controlPlane(socketPath: socketPath, backend: backend)
    }
  }

  /// The client for whichever helper owns this session.
  private func controlPlane(forSession sessionID: UUID) -> (any SessionControlPlane & Sendable)? {
    let backend = backend(forSession: sessionID)
    guard let socketPath = existingSocketPath(for: backend) else { return nil }
    return controlPlane(socketPath: socketPath, backend: backend)
  }

  /// Every live session, from both helpers.
  ///
  /// Merged rather than taken from one: during the migration the daemon still holds the sessions
  /// it created and the agent holds the new ones, and a caller deciding what to tear down must see
  /// all of them or it will orphan whatever it could not see.
  func liveSessions() async -> [SessionDescriptor] {
    let clients = liveControlPlanes()
    guard !clients.isEmpty else { return [] }
    return await Task.detached(priority: .utility) {
      clients.flatMap { $0.list() }
    }.value
  }

  func lookup(sessionID: UUID) async -> PersistentSessionLookup {
    // Routed by OWNER, with no gate on the preferred backend's socket. That gate was left over
    // from before per-session routing and inverted the drain: with the agent preferred but no
    // `agent.sock` yet, every session the daemon still owned reported `.unreachable` — and the
    // close, delete and quit paths built on this then returned without killing them.
    // `controlPlane(forSession:)` already resolves an EXISTING socket for the owning backend.
    guard let identifier = SessionIdentifier(uuidString: sessionID.uuidString),
      let client = controlPlane(forSession: sessionID)
    else { return .unreachable }
    return await Task.detached(priority: .utility) {
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
    guard let identifier = SessionIdentifier(uuidString: sessionID.uuidString),
      let client = controlPlane(forSession: sessionID)
    else {
      owners.removeValue(forKey: sessionID)
      return true
    }
    // Resolved above, via `controlPlane(forSession:)`, then forgotten: this session is over, and
    // holding its owner would outlive the thing it describes.
    defer { owners.removeValue(forKey: sessionID) }
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
      // Every helper, and NOT gated on the preferred backend's socket: during the migration the
      // daemon may still hold sessions the agent knows nothing about, and "stop everything" has to
      // mean everything. `liveControlPlanes()` is already the enumeration of what is running.
      let clients = liveControlPlanes()
      _ = await Task.detached(priority: .utility) { clients.map { $0.killAll() } }.value
      return
    }
    let sessions = await liveSessions()
    for session in sessions {
      guard let uuid = session.identifier.uuid, !attachedSessionIDs.contains(uuid) else { continue }
      await endSession(sessionID: uuid)
    }
  }
}
