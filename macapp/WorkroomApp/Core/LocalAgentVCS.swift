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
    guard context.location.host == .local else { throw HostConnectionError.mismatchedContext }
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
                process.arguments = ["serve", "--socket", path]
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
    return try await manager.reader(context: context)
  }
}
