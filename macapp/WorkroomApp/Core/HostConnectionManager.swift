import Foundation

/// A negotiated service connection, separate from the terminal attach relays. Factories must
/// return a fresh connection for each attempt. Blocking transport work belongs off the actor.
protocol HostServiceConnection: Sendable {
  /// A single-consumer stream. Yield or finish when the transport is lost.
  var disconnection: AsyncStream<Void> { get }
  func reader(context: RepositoryContext) throws -> VCSProviding
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting
  func close() async
}

enum HostConnectionError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
  case connectionLost
  /// Refused locally, before a single byte reached the socket — the connection was already closed,
  /// the stream counter is exhausted, or the 32-slot request pool is full. Distinct from
  /// `connectionLost` because the caller can say "this definitely did not run", which for a WRITE
  /// is the difference between a safe retry and one that double-applies a commit or a push.
  case notDispatched
  /// The request was sent and its deadline passed with no reply. Distinct from `connectionLost`
  /// because the connection is fine — the PEER is not answering — and the two want opposite
  /// recoveries: `LocalAgentVCS` catches `connectionLost` to spawn wr-agent and retry, which is
  /// right for a dead agent and useless against a hung one, since the second candidate exits
  /// without binding while the first still holds the single-instance flock.
  ///
  /// Like `connectionLost` and unlike `notDispatched`, the request DID leave this process, so a
  /// write that fails this way has an unknown outcome.
  case requestTimedOut
  case staleGeneration
  case mismatchedContext
  case serviceUnavailable(String)

  var description: String { errorDescription ?? "Host service unavailable." }

  var errorDescription: String? {
    switch self {
    case .connectionLost:
      return "Host connection lost. An operation may have completed; refresh before retrying."
    case .notDispatched:
      return "Host service is busy; the request was not sent."
    case .requestTimedOut:
      return "Host service did not answer in time. An operation may have completed; refresh before "
        + "retrying."
    case .staleGeneration:
      return "Host connection changed. Refresh repository data before retrying."
    case .mismatchedContext:
      return "Host service returned a different repository context."
    case .serviceUnavailable(let detail):
      return "Host service unavailable: \(detail)"
    }
  }
}

/// App-wide ownership, shared across windows. A generation is a lease, never a reconnect recipe.
/// Disconnecting fails waiters immediately, even if native/remote work ignores cancellation.
/// Completion is then discarded, not replayed. In particular a failed write can have taken effect.
actor HostConnectionManager {
  static let shared = HostConnectionManager()

  struct Lease: Hashable, Sendable {
    let host: HostID
    let generation: UUID
  }

  struct Snapshot: Equatable, Sendable {
    enum Status: Sendable { case disconnected, connecting, connected }
    let lease: Lease?
    let status: Status
  }

  private struct Pending {
    let task: Task<Void, Never>
    let fail: (Error) -> Void
  }

  private struct Slot {
    let lease: Lease
    var connection: (any HostServiceConnection)?
    var status: Snapshot.Status = .connecting
    var pending: [UUID: Pending] = [:]
    var monitor: Task<Void, Never>?
  }

  private var slots: [HostID: Slot] = [:]
  private var observers: [HostID: [UUID: AsyncStream<Snapshot>.Continuation]] = [:]

  func snapshot(for host: HostID) -> Snapshot {
    guard let slot = slots[host] else { return Snapshot(lease: nil, status: .disconnected) }
    return Snapshot(lease: slot.lease, status: slot.status)
  }

  /// Subscribers receive the current state immediately. On a new connected generation they must
  /// reacquire services, refresh mutable state, and recreate transport subscriptions. Buffering the
  /// latest snapshot bounds slow windows without hiding a generation change.
  func updates(for host: HostID) -> AsyncStream<Snapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Snapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    observers[host, default: [:]][id] = continuation
    continuation.yield(snapshot(for: host))
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(host: host, id: id) }
    }
    return stream
  }

  /// Explicit connection attempts replace earlier attempts. A late successful handshake is closed
  /// rather than installed over its successor. There is no automatic reconnect or write retry.
  func connect(
    host: HostID,
    using factory: @escaping @Sendable () async throws -> any HostServiceConnection
  ) async throws -> Lease {
    try Task.checkCancellation()
    invalidate(host: host, error: HostConnectionError.staleGeneration)
    let lease = Lease(host: host, generation: UUID())
    slots[host] = Slot(lease: lease)
    publish(host)
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          invalidate(host: host, error: CancellationError())
          continuation.resume(throwing: CancellationError())
          return
        }
        let task = Task {
          do {
            try Task.checkCancellation()
            let connection = try await factory()
            self.accept(connection, lease: lease, id: id, continuation: continuation)
          } catch {
            if self.slots[host]?.lease == lease { self.invalidate(host: host, error: error) }
          }
        }
        slots[host]?.pending[id] = Pending(task: task, fail: { continuation.resume(throwing: $0) })
      }
    } onCancel: {
      Task { await self.cancelConnect(lease) }
    }
  }

  /// An old transport's disconnect notification must never tear down its replacement.
  func disconnect(_ lease: Lease) {
    guard slots[lease.host]?.lease == lease else { return }
    invalidate(host: lease.host, error: HostConnectionError.connectionLost)
  }

  func perform<Value: Sendable>(
    on lease: Lease, operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      guard let slot = slots[lease.host], slot.lease == lease, slot.connection != nil else {
        throw HostConnectionError.staleGeneration
      }
      return try await withCheckedThrowingContinuation { continuation in
        let task = Task {
          let result: Result<Value, Error>
          do {
            try Task.checkCancellation()
            result = .success(try await operation())
          } catch { result = .failure(error) }
          self.finish(lease: lease, id: id, result: result, continuation: continuation)
        }
        slots[lease.host]?.pending[id] = Pending(
          task: task, fail: { continuation.resume(throwing: $0) })
      }
    } onCancel: {
      Task { await self.cancelOperation(lease: lease, id: id) }
    }
  }

  func reader(context: RepositoryContext) throws -> VCSProviding {
    let (lease, connection) = try connected(context.location.host)
    let service = try connection.reader(context: context)
    guard service.context == context else { throw HostConnectionError.mismatchedContext }
    return HostRepositoryReader(context: context, service: service, manager: self, lease: lease)
  }

  func writer(context: RepositoryContext) throws -> VCSWriting {
    _ = try context.requireOwnership()
    let (lease, connection) = try connected(context.location.host)
    let reader = try connection.reader(context: context)
    guard reader.context == context else { throw HostConnectionError.mismatchedContext }
    let writer = try connection.writer(context: context, reader: reader)
    guard writer.context == context, writer.reader.context == context
    else {
      throw HostConnectionError.mismatchedContext
    }
    return HostRepositoryWriter(
      context: context,
      reader: HostRepositoryReader(context: context, service: reader, manager: self, lease: lease),
      service: writer, manager: self, lease: lease)
  }

  private func connected(_ host: HostID) throws -> (Lease, any HostServiceConnection) {
    guard let slot = slots[host], let connection = slot.connection else {
      throw RepositoryRoutingError.unavailable(host)
    }
    return (slot.lease, connection)
  }

  private func accept(
    _ connection: any HostServiceConnection, lease: Lease, id: UUID,
    continuation: CheckedContinuation<Lease, Error>
  ) {
    guard slots[lease.host]?.lease == lease,
      slots[lease.host]?.pending.removeValue(forKey: id) != nil
    else {
      Task { await connection.close() }
      return
    }
    slots[lease.host]?.connection = connection
    slots[lease.host]?.status = .connected
    slots[lease.host]?.monitor = Task { [weak self] in
      for await _ in connection.disconnection { break }
      guard !Task.isCancelled else { return }
      await self?.disconnect(lease)
    }
    publish(lease.host)
    continuation.resume(returning: lease)
  }

  private func finish<Value: Sendable>(
    lease: Lease, id: UUID, result: Result<Value, Error>,
    continuation: CheckedContinuation<Value, Error>
  ) {
    guard slots[lease.host]?.lease == lease,
      slots[lease.host]?.pending.removeValue(forKey: id) != nil
    else { return }
    continuation.resume(with: result)
  }

  private func cancelOperation(lease: Lease, id: UUID) {
    guard slots[lease.host]?.lease == lease,
      let pending = slots[lease.host]?.pending.removeValue(forKey: id)
    else { return }
    pending.task.cancel()
    pending.fail(CancellationError())
  }

  private func cancelConnect(_ lease: Lease) {
    guard slots[lease.host]?.lease == lease, slots[lease.host]?.status == .connecting else {
      return
    }
    invalidate(host: lease.host, error: CancellationError())
  }

  private func invalidate(host: HostID, error: Error) {
    guard let old = slots[host] else { return }
    slots[host]?.connection = nil
    slots[host]?.pending = [:]
    slots[host]?.monitor = nil
    slots[host]?.status = .disconnected
    old.monitor?.cancel()
    for pending in old.pending.values {
      pending.task.cancel()
      pending.fail(error)
    }
    if let connection = old.connection { Task { await connection.close() } }
    publish(host)
  }

  private func publish(_ host: HostID) {
    for observer in observers[host]?.values ?? [:].values { observer.yield(snapshot(for: host)) }
  }

  private func removeObserver(host: HostID, id: UUID) {
    observers[host]?.removeValue(forKey: id)
    if observers[host]?.isEmpty == true { observers.removeValue(forKey: host) }
  }
}
