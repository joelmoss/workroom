import Foundation
import os

/// Listeners on remote hosts that carry each connection back to a port on this Mac, one per
/// workroom, kept open across reconnects (`ReverseForward`). For the Debug builds' route to this
/// Mac's development Codaset (`BrokerReverseForwards`), and for the git credential relay of a local
/// container workroom that never enrolled (`CredentialRelay`, #309).
///
/// **The listener lives only as long as the connection to the host** (every forward does), so this
/// reopens it on each new connection, on the same port: what the agent saved (its broker URL, its
/// relay's port) must keep working after a reattach.
@MainActor
final class ReverseForwardRegistry {

  /// How the registry reaches a host's connection, so a test can hand it a real agent without
  /// `HostConnectionManager`: the shape `PortForwardingModel.Transport` set.
  struct Transport {
    var forwarding:
      @Sendable (HostID) async throws -> (HostConnectionManager.Lease, AgentForwardService)
    var updates: @Sendable (HostID) async -> AsyncStream<HostConnectionManager.Snapshot>

    static let live = Transport(
      forwarding: { try await HostConnectionManager.shared.forwarding(host: $0) },
      updates: { await HostConnectionManager.shared.updates(for: $0) })
  }

  /// How long the agent may take to answer a `listen`.
  static let listenTimeout: Duration = .seconds(5)
  /// A bind that lost the race with the old connection's teardown is retried this often, this
  /// many times: the agent notices a departed connection within its 200 ms accept poll.
  static let bindRetries = 10
  static let bindRetryDelay: Duration = .milliseconds(200)
  /// How many times a connection's listener is tried, `reopenRetry` apart, before the registry
  /// waits for the next connection: five minutes at the default.
  static let reopenAttempts = 60

  private let transport: Transport
  /// The agent's port for a workroom: the same on every connection and every launch.
  private let port: @Sendable (UUID) -> UInt16
  /// The port on this Mac each connection is carried to, asked again for each listener.
  private let target: @Sendable () async -> UInt16
  /// The error a listener the agent refuses becomes, from the agent's reason.
  private let failure: @Sendable (String) -> Error
  private let reopenRetry: Duration
  private let log = Logger(subsystem: "com.developwithstyle.workroom", category: "broker")

  private struct Entry {
    let host: HostID
    /// The connection the listener is open on, once it is.
    var lease: HostConnectionManager.Lease?
    var forward: ReverseForward?
    var watch: Task<Void, Never>?
    /// An open in flight, which a second caller waits on rather than opening a second listener.
    /// The id is how the task, finishing, clears only itself.
    var opening: (id: UUID, task: Task<Void, Error>)?
  }
  private var entries: [UUID: Entry] = [:]

  init(
    transport: Transport = .live, port: @escaping @Sendable (UUID) -> UInt16,
    target: @escaping @Sendable () async -> UInt16,
    failure: @escaping @Sendable (String) -> Error, reopenRetry: Duration = .seconds(5)
  ) {
    self.transport = transport
    self.port = port
    self.target = target
    self.failure = failure
    self.reopenRetry = reopenRetry
  }

  /// Open the listener for `workroom` on `host` and keep it open on every later connection. Throws
  /// when the agent does not listen now.
  func open(workroom: UUID, host: HostID) async throws {
    if entries[workroom] == nil {
      entries[workroom] = Entry(host: host)
      watch(workroom)
    }
    try await listen(workroom)
  }

  /// Stop carrying `workroom`'s connections: the workroom is gone, or no longer needs them.
  func close(workroom: UUID) {
    guard let entry = entries.removeValue(forKey: workroom) else { return }
    entry.watch?.cancel()
    entry.opening?.task.cancel()
    entry.forward?.stop()
  }

  /// Whether `workroom`'s listener is open on `lease`, for the tests.
  func isOpen(_ workroom: UUID, on lease: HostConnectionManager.Lease) -> Bool {
    entries[workroom]?.lease == lease && entries[workroom]?.forward != nil
  }

  private func listen(_ workroom: UUID) async throws {
    // An open in flight is waited out, then this caller runs its own: the one in flight may be
    // for an earlier connection than the caller's, and `reopen` does nothing when the current
    // connection already has a listener.
    while let opening = entries[workroom]?.opening { _ = try? await opening.task.value }
    guard entries[workroom] != nil else { throw CancellationError() }
    let id = UUID()
    // The task clears its own entry as its last step, on this actor, BEFORE it completes: a
    // waiter above resumes only after that, so it never sees a finished open still recorded
    // (awaiting a finished task does not suspend, and it would spin on this actor forever).
    let task = Task {
      defer {
        if self.entries[workroom]?.opening?.id == id { self.entries[workroom]?.opening = nil }
      }
      try await self.reopen(workroom)
    }
    entries[workroom]?.opening = (id, task)
    try await task.value
  }

  /// A listener on the host's current connection, unless one is already open there.
  private func reopen(_ workroom: UUID) async throws {
    guard let host = entries[workroom]?.host else { return }
    let (lease, service) = try await transport.forwarding(host)
    guard var entry = entries[workroom] else { return }
    if entry.lease == lease, entry.forward != nil { return }
    entry.forward?.stop()
    entry.forward = nil
    entries[workroom] = entry

    // A bind can lose a race on a reconnect: the agent releases the old connection's port only
    // once it notices that connection ended, which can be just after the new one asks. The
    // port is this workroom's alone, so a bind failure is retried for a moment, not reported.
    var attempt = 0
    var outcome = await listen(service, port: port(workroom), workroom, lease)
    while case .failure(let refusal) = outcome, refusal.detail.hasPrefix("bind:"),
      attempt < Self.bindRetries
    {
      attempt += 1
      try await Task.sleep(for: Self.bindRetryDelay)
      outcome = await listen(service, port: port(workroom), workroom, lease)
    }
    let forward: ReverseForward
    switch outcome {
    case .success(let listening): forward = listening
    case .failure(let refusal):
      throw failure(refusal.detail)
    }
    // Closed meanwhile, or another connection took over: this listener is nobody's.
    guard entries[workroom] != nil else {
      forward.stop()
      throw CancellationError()
    }
    entries[workroom]?.lease = lease
    entries[workroom]?.forward = forward
  }

  /// One `listen`, answered or timed out. A refused listener is stopped before it is returned.
  private func listen(
    _ service: AgentForwardService, port: UInt16, _ workroom: UUID,
    _ lease: HostConnectionManager.Lease
  ) async -> Result<ReverseForward, ReverseForward.Refusal> {
    let ready = ListenOutcome()
    let forward = service.reverse(remotePort: port, target: await target()) {
      [weak self, log] event in
      switch event {
      case .listening:
        ready.resolve(nil)
      case .failed(let detail):
        log.info("reverse forward: \(detail, privacy: .public)")
      case .stopped(let detail):
        ready.resolve(detail)
        Task { @MainActor in self?.lost(workroom, on: lease) }
      }
    }
    forward.start()
    if let refusal = await ready.wait(Self.listenTimeout) {
      forward.stop()
      return .failure(.init(refusal))
    }
    return .success(forward)
  }

  /// The listener ended. With its connection, the next connection opens a new one; on its own
  /// (the agent's listener broke while the connection lives), no new connection is coming, so it
  /// is reopened here.
  private func lost(_ workroom: UUID, on lease: HostConnectionManager.Lease) {
    guard entries[workroom]?.lease == lease else { return }
    entries[workroom]?.lease = nil
    entries[workroom]?.forward = nil
    Task { await keepTrying(workroom) }
  }

  /// Listen until it works, the workroom is closed, or the attempts run out. A link lost without
  /// a goodbye leaves the old connection's listener holding the port until the agent notices it
  /// has gone, which can take as long as ssh's keepalives, so a bind that keeps failing is tried
  /// again every `reopenRetry` rather than given up on until the next connection.
  private func keepTrying(_ workroom: UUID) async {
    for attempt in 1...Self.reopenAttempts {
      guard entries[workroom] != nil, !Task.isCancelled else { return }
      do {
        try await listen(workroom)
        return
      } catch {
        if attempt == 1 || attempt == Self.reopenAttempts {
          log.error(
            "reverse forward did not reopen (attempt \(attempt)): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      try? await Task.sleep(for: reopenRetry)
    }
  }

  /// Reopen on every new connection to the host.
  private func watch(_ workroom: UUID) {
    guard let host = entries[workroom]?.host else { return }
    entries[workroom]?.watch = Task { [weak self, transport] in
      for await snapshot in await transport.updates(host) {
        guard let self, !Task.isCancelled else { return }
        guard snapshot.status == .connected, let lease = snapshot.lease,
          self.entries[workroom]?.lease != lease
        else { continue }
        await self.keepTrying(workroom)
      }
    }
  }
}

/// The first answer to a `listen`, waited on with a deadline: nil once the agent listens, the
/// reason when it will not.
private final class ListenOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome: String??
  private var waiter: CheckedContinuation<String?, Never>?

  func resolve(_ refusal: String?) {
    let waiter: CheckedContinuation<String?, Never>? = lock.withLock {
      guard outcome == nil else { return nil }
      outcome = .some(refusal)
      defer { self.waiter = nil }
      return self.waiter
    }
    waiter?.resume(returning: refusal)
  }

  func wait(_ timeout: Duration) async -> String? {
    let timer = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.resolve("the agent did not answer the listen request")
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { continuation in
      let settled: String?? = lock.withLock {
        if let outcome { return outcome }
        waiter = continuation
        return nil
      }
      if let settled { continuation.resume(returning: settled) }
    }
  }
}
