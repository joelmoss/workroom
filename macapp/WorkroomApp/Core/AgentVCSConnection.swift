import Darwin
import Foundation

/// A persistent, negotiated VCS channel. Terminal relays keep their existing connections.
/// Blocking socket work runs on GCD. Closing shuts down the descriptor; only deinit closes it,
/// so an in-flight reader/writer can never act on a recycled descriptor.
final class AgentVCSConnection: HostServiceConnection, @unchecked Sendable {
  let host: HostID
  let disconnection: AsyncStream<Void>
  private let disconnected: AsyncStream<Void>.Continuation
  private let descriptor: Int32
  private let lock = NSLock()
  private let writes = DispatchQueue(label: "workroom.agent.vcs.write")
  private var closed = false
  private var nextStream: UInt32 = 1
  private struct Pending {
    let continuation: CheckedContinuation<Data, Error>
    var bytes = Data()
  }
  private var pending: [UInt32: Pending] = [:]
  /// Streams this connection gave up waiting on (request timeout) but whose reply may still
  /// arrive. Tracked so a late reply drains harmlessly instead of `receive()` treating an unknown
  /// stream id as a protocol violation and tearing down every OTHER in-flight request too.
  private var abandoned: Set<UInt32> = []
  /// Negotiated once in `connect()`, before this connection is shared with any other caller.
  /// `writes` is absent on a still-running pre-upgrade agent that answers `reads` but has no VCS
  /// write service at all — `writer(context:reader:)` treats that as `VCSError.backendVersion`,
  /// the same signal `RepositoryRouter` already falls back to native writes on.
  private var _capabilities: AgentVCSCapabilities?
  private var capabilities: AgentVCSCapabilities? { lock.withLock { _capabilities } }
  /// The write methods `LocalVCSWriting` declares — matches wr-agent's `"writes"` capability count
  /// (`vcs.rs`'s `capabilities` reply). Kept as one literal so a protocol change updates both ends
  /// deliberately rather than by coincidence.
  private static let writeMethodCount = 8

  private init(host: HostID, descriptor: Int32) {
    self.host = host
    self.descriptor = descriptor
    (disconnection, disconnected) = AsyncStream<Void>.makeStream()
  }

  deinit { Darwin.close(descriptor) }

  static func connect(host: HostID, socketPath: String) async throws -> AgentVCSConnection {
    let connection = try await runBlocking {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw HostConnectionError.connectionLost }
      do {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard !path.contains(0), path.count < MemoryLayout.size(ofValue: address.sun_path) else {
          throw VCSError.io("Agent socket path is invalid.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        }
        guard connected == 0 else { throw HostConnectionError.connectionLost }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try send(fd, Data(AgentControlClient.encodeHello(build: "Workroom VCS")))
        var hello: [UInt8] = []
        let deadline = Date().addingTimeInterval(2)
        while true {
          if let greeting = try AgentControlClient.decodeHello(hello) {
            // Checked against the peer's raw greeting, not the negotiated Terminal/Control
            // minimum: a still-running pre-upgrade agent (kept alive because it may own
            // terminals) truthfully reports its own lower version here, and its `dispatch` has no
            // VCS handling at all — it would silently drop the capabilities request that follows,
            // stalling this connect for the full capabilities timeout instead of failing now.
            // Matches `MIN_VCS_VERSION` in the agent's `protocol::envelope`.
            guard greeting.version >= 2 else {
              throw VCSError.backendVersion("Agent predates VCS support.")
            }
            break
          }
          guard Date() < deadline else { throw HostConnectionError.connectionLost }
          var byte: UInt8 = 0
          guard recv(fd, &byte, 1, 0) == 1 else { throw HostConnectionError.connectionLost }
          hello.append(byte)
        }
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // The 2s handshake bound must not linger onto ordinary request sends — a legitimately busy
        // agent (mid VCS request on another thread) can leave the socket buffer full past 2s with
        // no fault of its own; a lingering SO_SNDTIMEO would then report that as connection loss.
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return AgentVCSConnection(host: host, descriptor: fd)
      } catch {
        Darwin.close(fd)
        throw error
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { connection.receive() }
    do {
      let reply = try await connection.request(
        AgentVCSRequest(method: "capabilities"), timeout: 2)
      let capabilities = try AgentVCSReply<AgentVCSCapabilities>.decode(reply)
      guard capabilities.version == 1, capabilities.reads == 9 else {
        throw HostConnectionError.serviceUnavailable("Agent does not support these VCS reads.")
      }
      // Not yet shared with any other caller, so a plain lock-guarded write is enough — no
      // concurrent reader can observe a half-set value.
      connection.lock.withLock { connection._capabilities = capabilities }
      return connection
    } catch {
      await connection.close()
      throw HostConnectionError.serviceUnavailable("VCS negotiation failed: \(error)")
    }
  }

  func reader(context: RepositoryContext) throws -> VCSProviding {
    guard context.location.host == host else { throw HostConnectionError.mismatchedContext }
    guard lock.withLock({ !closed }) else { throw HostConnectionError.connectionLost }
    return AgentVCSReader(context: context, connection: self)
  }

  /// `reader` is the SAME agent-routed `VCSProviding` `HostConnectionManager.writer(context:)` just
  /// built — threaded through rather than reconstructed so `CLIVCSWriter.remoteState`'s `currentRef`
  /// read goes through the agent too (`AgentCurrentRefProvider`), not a fresh native process. A
  /// still-running pre-upgrade agent has no write service at all; that is reported the same way an
  /// unsupported read version is, so `RepositoryRouter` falls back to native writes rather than
  /// leaving the repository unwritable.
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    guard context.location.host == host else { throw HostConnectionError.mismatchedContext }
    guard lock.withLock({ !closed }) else { throw HostConnectionError.connectionLost }
    guard capabilities?.writes == Self.writeMethodCount else {
      throw VCSError.backendVersion("Agent does not support VCS writes.")
    }
    let engine = CLIVCSWriter(
      vcs: context.backend.rawValue, runner: AgentCommandRunner(connection: self),
      makeProvider: { _ in AgentCurrentRefProvider(reader: reader) }, gate: .shared)
    return try BoundLocalWriter(context: context, reader: reader, writer: engine)
  }

  func close() async { fail(HostConnectionError.connectionLost) }

  func request<Request: Encodable>(_ request: Request, timeout: TimeInterval = 30) async throws
    -> Data
  {
    try Task.checkCancellation()
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let bytes = try encoder.encode(request)
    // Matches the protocol's own per-envelope ceiling (`MAX_ENVELOPE_PAYLOAD` in
    // `protocol/envelope.rs`) — requests are sent as ONE envelope, never chunked the way replies
    // are, so raising this alone would only trade a typed `.partialData` failure here for a raw
    // protocol violation there. A commit selecting many thousands of long paths (an `AgentExecRequest`
    // stdin payload, `CLIVCSWriter`'s NUL-separated pathspec) could in principle exceed this; that
    // would need real request chunking to lift, and is accepted as a known limit for now.
    guard bytes.count <= 1 << 20 else { throw VCSError.partialData("VCS request is too large.") }
    let cancellation = RequestCancellationBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let stream: UInt32? = lock.withLock {
          // ponytail: one 32-slot pool shared by every read AND write on this connection, app-wide.
          // A write can now legitimately hold a slot for minutes (`commitTimeout` = 600s), where only
          // reads (seconds at most) used to compete for these slots. Exhausting the pool degrades to
          // `.connectionLost` for the next caller rather than a distinct backpressure signal. Split
          // reads and writes onto separate pools/connections if this is ever observed in practice.
          guard !closed, nextStream < UInt32.max, pending.count < 32 else { return nil }
          let stream = nextStream
          nextStream += 1
          pending[stream] = Pending(continuation: continuation)
          return stream
        }
        guard let stream else {
          continuation.resume(throwing: HostConnectionError.connectionLost)
          return
        }
        // Registered only after `stream` is in `pending`, so an already-cancelled caller (Swift
        // may run `onCancel` before this closure even starts) fails THIS stream the instant it
        // exists instead of occupying one of the 32 slots until its 30s timeout — a cancelled
        // status-sweep read must free its slot immediately, not squat on it.
        cancellation.attach { [weak self] in
          self?.timeoutStream(stream, error: CancellationError())
        }
        writes.async { [self] in
          guard lock.withLock({ !closed }) else { return }
          var envelope = Data([2])
          for value in [stream, UInt32(bytes.count)] {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
          }
          envelope.append(bytes)
          do { try Self.send(descriptor, envelope) } catch { fail(error) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
          self?.timeoutStream(stream, error: HostConnectionError.connectionLost)
        }
      }
    } onCancel: {
      cancellation.fire()
    }
  }

  private static func send(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw HostConnectionError.connectionLost }
        sent += count
      }
    }
  }

  private func receive() {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    do {
      while true {
        while buffer.count >= 9 {
          let header = Array(buffer.prefix(9))
          let stream = header[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
          let length = header[5..<9].reduce(0) { ($0 << 8) | Int($1) }
          guard header[0] == 2, stream > 0, length > 0, length <= 1 << 20 else {
            throw HostConnectionError.serviceUnavailable("Invalid VCS envelope.")
          }
          guard buffer.count >= 9 + length else { break }
          let payload = Data(buffer.dropFirst(9).prefix(length))
          buffer = Data(buffer.dropFirst(9 + length))
          guard payload.first == 0 || payload.first == 1 else {
            throw HostConnectionError.serviceUnavailable("Invalid VCS chunk.")
          }
          var completed: Pending?
          let valid = lock.withLock {
            if abandoned.contains(stream) {
              // Nobody is waiting on this any more (it timed out) — drain it and never surface it
              // as unexpected, so a slow-but-eventually-answered request never disturbs the
              // connection every OTHER in-flight request is sharing.
              if payload.first == 1 { abandoned.remove(stream) }
              return true
            }
            guard var operation = pending[stream],
              operation.bytes.count + payload.count - 1 <= 16 * 1024 * 1024
            else { return false }
            operation.bytes.append(payload.dropFirst())
            if payload.first == 1 {
              pending.removeValue(forKey: stream)
              completed = operation
            } else {
              pending[stream] = operation
            }
            return true
          }
          guard valid else {
            throw HostConnectionError.serviceUnavailable("Unexpected or oversized VCS reply.")
          }
          if let completed { completed.continuation.resume(returning: completed.bytes) }
        }
        let count = chunk.withUnsafeMutableBytes {
          recv(descriptor, $0.baseAddress!, $0.count, 0)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw HostConnectionError.connectionLost }
        buffer.append(contentsOf: chunk.prefix(count))
      }
    } catch { fail(error) }
  }

  /// Only this request's reply is overdue — every other in-flight request and the connection
  /// itself stay usable. Matches the design's own "never replay any request" rule: this fails the
  /// wait, not the underlying operation, so a reply that does eventually arrive is drained, never
  /// delivered to a second caller.
  private func timeoutStream(_ stream: UInt32, error: Error) {
    let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
      guard let entry = pending.removeValue(forKey: stream) else { return nil }
      abandoned.insert(stream)
      return entry.continuation
    }
    continuation?.resume(throwing: error)
  }

  private func fail(_ error: Error) {
    let failed: [Pending]? = lock.withLock {
      guard !closed else { return nil }
      closed = true
      let values = Array(pending.values)
      pending.removeAll()
      abandoned.removeAll()
      shutdown(descriptor, SHUT_RDWR)
      return values
    }
    guard let failed else { return }
    for operation in failed { operation.continuation.resume(throwing: error) }
    disconnected.finish()
  }
}

struct AgentVCSCapabilities: Decodable {
  let version: Int
  let reads: Int
  /// Absent on a still-running pre-upgrade agent that predates the VCS write service.
  let writes: Int?
}

struct AgentVCSRequest: Encodable, Sendable {
  var version = 1
  var root: String?
  var sharedRoot: String?
  var backend: String?
  let method: String
  var limit: Int?
  var revision: String?
  var path: String?
  var base: String?
}

/// Bridges `withTaskCancellationHandler`'s `onCancel` — which Swift may invoke BEFORE `request`'s
/// continuation closure even starts (a task already cancelled at the call site), concurrently with
/// it, or not at all — to failing that request's stream. Same shape as `Timeout.swift`'s
/// `TimeoutCancelBox`: `onCancel` runs synchronously on whichever thread calls `.cancel()`, so both
/// sides are lock-guarded rather than assuming an ordering.
private final class RequestCancellationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (() -> Void)?
  private var firedEarly = false

  func attach(_ action: @escaping () -> Void) {
    lock.lock()
    let already = firedEarly
    if !already { self.action = action }
    lock.unlock()
    if already { action() }
  }

  func fire() {
    lock.lock()
    firedEarly = true
    let action = self.action
    self.action = nil
    lock.unlock()
    action?()
  }
}
