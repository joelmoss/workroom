import DaemonConnection
import Foundation
import WorkroomSystem
import WorkroomVCS
import WorkroomWire

/// A negotiated service connection, separate from the terminal attach relays. Factories must
/// return a fresh connection for each attempt. Blocking transport work belongs off the actor.
protocol HostServiceConnection: Sendable {
  /// A single-consumer stream. Yield or finish when the transport is lost.
  var disconnection: AsyncStream<Void> { get }
  func reader(context: RepositoryContext) throws -> VCSProviding
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting
  /// The file service on this connection. Throws `VCSError.backendVersion` when the peer predates it,
  /// which the router answers by falling back to native reads for a LOCAL host.
  func files(context: FileContext) throws -> FileProviding
  /// The port-forwarding service on this connection (issue #208). Concrete rather than behind a
  /// protocol of its own: only a workroomd has one, and a second implementer would be a second daemon
  /// — at which point the protocol can be extracted with a caller to justify it. Throws
  /// `VCSError.backendVersion` when the peer predates the service.
  func forwarding() throws -> DaemonForwardService
  /// The working directory of terminal `session` on this host, or nil when the host holds no such
  /// session (#239). Concrete for the same reason `forwarding()` is.
  func workingDirectory(of session: UUID) async throws -> String?
  /// Ends terminal `session` on this host (#283): true once the host's daemon confirms the kill,
  /// which it also does for a session it no longer holds.
  func endSession(_ session: UUID) async throws -> Bool
  /// Every terminal session the host's daemon holds, with what the app said about each (#255).
  func sessions() async throws -> [SessionDescriptor]
  /// Returns once the daemon answers anything, its cheapest question (`dropUnlessAnswering`).
  func ping() async throws
  /// Each remote workroom's pane layout, kept on its host (#255). Throws `VCSError.backendVersion`
  /// when the peer predates the service.
  func layouts() throws -> DaemonLayoutService
  /// Program status (#358): subscribe to every session's records on this host.
  func subscribeProgramStatus(
    onEvent: @escaping @Sendable (ProgramStatusEvent) -> Void
  ) async throws -> ProgramStatusAvailability
  func programStatusSeen(session: UUID, revision: UInt64, states: [String]?) async throws
  func programStatusClear(session: UUID) async throws
  func close() async
}

extension HostServiceConnection {
  /// A connection with no file service, so existing conformers (tests, future transports) keep
  /// compiling and report the honest answer.
  func files(context: FileContext) throws -> FileProviding {
    throw HostConnectionError.serviceUnavailable("Host has no file service.")
  }

  func forwarding() throws -> DaemonForwardService {
    throw HostConnectionError.serviceUnavailable("Host has no port-forwarding service.")
  }

  func workingDirectory(of session: UUID) async throws -> String? {
    throw HostConnectionError.serviceUnavailable("Host has no terminal sessions.")
  }

  func endSession(_ session: UUID) async throws -> Bool {
    throw HostConnectionError.serviceUnavailable("Host has no terminal sessions.")
  }

  func sessions() async throws -> [SessionDescriptor] {
    throw HostConnectionError.serviceUnavailable("Host has no terminal sessions.")
  }

  func ping() async throws {
    throw HostConnectionError.serviceUnavailable("Host cannot be pinged.")
  }

  func layouts() throws -> DaemonLayoutService {
    throw VCSError.backendVersion("Host has no layout service.")
  }

  func subscribeProgramStatus(
    onEvent: @escaping @Sendable (ProgramStatusEvent) -> Void
  ) async throws -> ProgramStatusAvailability { .unsupported }

  func programStatusSeen(session: UUID, revision: UInt64, states: [String]?) async throws {
    throw VCSError.backendVersion("Host has no program status service.")
  }

  func programStatusClear(session: UUID) async throws {
    throw VCSError.backendVersion("Host has no program status service.")
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

  /// `connect`, unless a connection is already there (returned as is) or one is being made (an
  /// error: the next retry finds it). One actor step from the check to the `invalidate` that
  /// `connect` opens with, so a caller that only wants to fill a gap can never replace an attempt
  /// some other caller is waiting on — which a snapshot read across a suspension could.
  func connectIfDisconnected(
    host: HostID,
    using factory: @escaping @Sendable () async throws -> any HostServiceConnection
  ) async throws -> Lease {
    if let slot = slots[host] {
      switch slot.status {
      case .connected: return slot.lease
      case .connecting: throw RepositoryRoutingError.unavailable(host)
      case .disconnected: break
      }
    }
    return try await connect(host: host, using: factory)
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

  func files(context: FileContext) throws -> FileProviding {
    let (lease, connection) = try connected(context.location.host)
    let service = try connection.files(context: context)
    guard service.context == context else { throw HostConnectionError.mismatchedContext }
    return HostFileProvider(context: context, service: service, manager: self, lease: lease)
  }

  /// Not wrapped in a lease-tracking proxy the way `reader`/`files` are: a forward has no repository
  /// context to go stale.
  /// The lease is returned with the service because the one failure that matters — the connection
  /// ending — reaches every live stream through the connection itself but not the LISTENER, which
  /// its owner drops by comparing this lease against `updates(for:)`.
  func forwarding(host: HostID) throws -> (Lease, DaemonForwardService) {
    let (lease, connection) = try connected(host)
    return (lease, try connection.forwarding())
  }

  /// Not lease-tracked either: the answer is one path, read once, with no context to go stale.
  /// Throws `RepositoryRoutingError.unavailable` while `host` has no connection, and never connects
  /// one: a remote pane's footer is not a reason to reach its host.
  func workingDirectory(of session: UUID, on host: HostID) async throws -> String? {
    try await connected(host).1.workingDirectory(of: session)
  }

  /// Not lease-tracked either: one request with no context to go stale. Like `workingDirectory`,
  /// never connects; a caller that must reach the host connects first.
  func endSession(_ session: UUID, on host: HostID) async throws -> Bool {
    try await connected(host).1.endSession(session)
  }

  /// Not lease-tracked either, and never connects, like `endSession`.
  func sessions(on host: HostID) async throws -> [SessionDescriptor] {
    try await connected(host).1.sessions()
  }

  /// Not lease-tracked either: a layout is read once, and a write names the revision it read, so a
  /// later connection cannot apply a stale one. Never connects.
  func layouts(host: HostID) throws -> DaemonLayoutService {
    try connected(host).1.layouts()
  }

  /// The connection program status subscribes on (#358). Never connects: `ProgramStatusMonitor`
  /// acquires through `LocalDaemonVCS` or `RemoteWorkrooms` first.
  func programStatus(host: HostID) throws -> any HostServiceConnection {
    try connected(host).1
  }

  /// Whether `host`'s link answers a ping within `seconds`, asked after a wake or a network change
  /// (`RemoteLinkMonitor`). One that doesn't is dropped: ssh would take about a minute to notice it
  /// is dead. A host with no link can't be asked, and is false; one whose link is connecting is
  /// true, and left to connect. A ping that throws got no answer:
  /// silence, a link that failed under it, or one never sent. A daemon's error reply is still a
  /// reply, which `ping` returns rather than throws.
  func dropUnlessAnswering(_ host: HostID, within seconds: TimeInterval) async -> Bool {
    // A connect under way is as good as an answer: a pane's attach starts one, so after an earlier
    // check dropped the link, its panes are already new.
    if slots[host]?.status == .connecting { return true }
    guard let (lease, connection) = try? connected(host) else { return false }
    do {
      try await withTimeout(seconds: seconds) { try await connection.ping() }
    } catch {
      disconnect(lease)
      return false
    }
    return slots[host]?.lease == lease && slots[host]?.status == .connected
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
