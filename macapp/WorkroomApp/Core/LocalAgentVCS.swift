import Foundation

/// One local service connection across windows. Acquisition may establish a new generation;
/// operations themselves are never retried. An older running agent is negotiated with, never
/// replaced (it may own terminals). Unsupported VCS service is an explicit availability error.
actor LocalAgentVCS {
  static let shared = LocalAgentVCS()
  private let manager: HostConnectionManager
  private let resolveSocketPath: @Sendable () throws -> String
  private let binaryURL: @Sendable () -> URL?
  private struct Attempt {
    let id: UUID
    let task: Task<HostConnectionManager.Lease, Error>
  }
  private var connecting: Attempt?

  init(
    manager: HostConnectionManager = .shared,
    resolveSocketPath: @escaping @Sendable () throws -> String = {
      try PersistentSessionPaths.resolveSocketPath(backend: .rustAgent)
    },
    binaryURL: @escaping @Sendable () -> URL? = {
      PersistentSessionPaths.binaryURL(for: .rustAgent)
    }
  ) {
    self.manager = manager
    self.resolveSocketPath = resolveSocketPath
    self.binaryURL = binaryURL
  }

  func reader(context: RepositoryContext) async throws -> VCSProviding {
    try await ensureConnected(host: context.location.host)
    return try await manager.reader(context: context)
  }

  func writer(context: RepositoryContext) async throws -> VCSWriting {
    try await ensureConnected(host: context.location.host)
    return try await manager.writer(context: context)
  }

  /// How long a failed acquisition makes the FILE service fail fast. A file operation that falls back
  /// to native anyway should not pay a spawn-and-handshake wait (a few seconds) on every call while
  /// the agent is persistently down. Scoped to files on purpose: a VCS read or write that finds the
  /// agent back a moment after it failed should still get to try.
  static let filesRetryCooldown: Duration = .seconds(5)
  private var filesFailedAt: ContinuousClock.Instant?

  func files(context: FileContext) async throws -> FileProviding {
    if let failedAt = filesFailedAt, ContinuousClock.now - failedAt < Self.filesRetryCooldown {
      throw RepositoryRoutingError.unavailable(.local)
    }
    do {
      try await ensureConnected(host: context.location.host)
      let files = try await manager.files(context: context)
      filesFailedAt = nil
      return files
    } catch {
      // A cancelled caller and an old agent are not "the agent is down": the first says nothing about
      // it, the second is answered instantly and permanently by the negotiated version.
      if !(error is CancellationError), !isBackendVersion(error) {
        filesFailedAt = ContinuousClock.now
      }
      throw error
    }
  }

  /// What `wakefulness(connecting:)` may do about a connection that is not there.
  enum Connecting: Sendable {
    /// Fail. A poll: no agent, no badge — starting a whole agent so a badge can say IDLE would be
    /// the tail wagging the dog.
    case never
    /// Connect to an agent that is listening; never start one. The prompt watch: its whole job is
    /// to be subscribed, and a watch that waited for an unrelated VCS read to reconnect it was off
    /// after every drop.
    case reconnect
    /// `ensureConnected`: connect, or start an agent and connect. A user's "Keep awake": a deliberate
    /// click on a box the agent said was about to sleep, and a dropped connection is not a reason
    /// to let it.
    case spawn
  }

  /// The local box's wakefulness service (issue #208).
  func wakefulness(connecting: Connecting) async throws -> AgentWakefulnessService {
    switch connecting {
    case .never:
      guard await manager.snapshot(for: .local).status == .connected else {
        throw RepositoryRoutingError.unavailable(.local)
      }
    case .reconnect:
      try await reconnect()
    case .spawn:
      try await ensureConnected(host: .local)
    }
    return try await manager.wakefulness(host: .local)
  }

  /// `ensureConnected` without the spawn. Not routed through `connecting`, whose one attempt is
  /// shared by every caller: a spawning caller that joined a non-spawning attempt would inherit a
  /// refusal it did not ask for. Instead this fills a gap and nothing else: the manager decides in
  /// one step whether there is a gap (`.connecting` — the next retry finds it connected), so an
  /// attempt some other caller is waiting on is never replaced by this one. A spawning attempt that
  /// starts a moment later replaces this generation, which fails this call and succeeds theirs.
  private func reconnect() async throws {
    let resolveSocketPath = self.resolveSocketPath
    _ = try await manager.connectIfDisconnected(host: .local) {
      let path = try await runBlocking { try resolveSocketPath() }
      return try await AgentVCSConnection.connect(host: .local, socketPath: path)
    }
  }

  /// The local box's port-forwarding service (issue #208). Mirrors `wakefulness(connecting: .never)`,
  /// including NOT spawning an agent: adding a forward is a deliberate user action, so spawning
  /// would be defensible, but a forward only carries while a client is attached — so the honest
  /// answer to "no agent is running" is that there is nothing to forward through yet, not a whole
  /// agent started on a port's behalf.
  func forwarding() async throws -> AgentForwardService {
    guard await manager.snapshot(for: .local).status == .connected else {
      throw RepositoryRoutingError.unavailable(.local)
    }
    return try await manager.forwarding(host: .local)
  }

  private func isBackendVersion(_ error: Error) -> Bool {
    if case VCSError.backendVersion = error { return true }
    return false
  }

  private func ensureConnected(host: HostID) async throws {
    guard host == .local else { throw HostConnectionError.mismatchedContext }
    try Task.checkCancellation()
    // Captured as local lets: plain Sendable values, so the nested closures below (some running on
    // `HostConnectionManager`, not this actor) can read them with no actor hop.
    let resolveSocketPath = self.resolveSocketPath
    let binaryURL = self.binaryURL
    if await manager.snapshot(for: .local).status != .connected {
      let task: Task<HostConnectionManager.Lease, Error>
      let id: UUID
      if let connecting {
        task = connecting.task
        id = connecting.id
      } else {
        id = UUID()
        task = Task {
          // A previous acquisition may have completed while this caller awaited its snapshot.
          let snapshot = await manager.snapshot(for: .local)
          if snapshot.status == .connected, let lease = snapshot.lease { return lease }
          return try await manager.connect(host: .local) {
            let path = try await runBlocking { try resolveSocketPath() }
            do {
              return try await AgentVCSConnection.connect(host: .local, socketPath: path)
            } catch HostConnectionError.connectionLost {
              // The agent owns the single-instance flock. Starting a second candidate is harmless
              // if the first is alive; it exits without binding or touching any existing terminal.
              try await runBlocking {
                guard let binary = binaryURL() else {
                  throw RepositoryRoutingError.unavailable(.local)
                }
                let process = Process()
                process.executableURL = binary
                // The wakefulness preferences are flags, so they are fixed for this agent's whole
                // life. This is not the only thing that starts an agent: `wr-agent attach` spawns
                // `serve --socket <path>` itself (`serve::spawn_agent`) with no flags, and whichever
                // candidate wins the single-instance flock decides. That path gets the same values
                // from the environment (`AgentWakefulnessSettings.serveEnvironment`, appended by
                // `PersistentSessionService.launchEnvironment`), which the agent reads as a fallback.
                process.arguments = AgentWakefulnessSettings.current.serveArguments(socket: path)
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ShellEnvironment.path()
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
              }
              let deadline = ContinuousClock.now + .seconds(2)
              while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                do {
                  return try await AgentVCSConnection.connect(host: .local, socketPath: path)
                } catch HostConnectionError.connectionLost { continue }
              }
              throw RepositoryRoutingError.unavailable(.local)
            }
          }
        }
        connecting = Attempt(id: id, task: task)
      }
      do {
        _ = try await task.value
        if connecting?.id == id { connecting = nil }
      } catch {
        if connecting?.id == id { connecting = nil }
        throw error
      }
    }
    try Task.checkCancellation()
  }
}
