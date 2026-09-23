import Darwin
import Foundation

/// A persistent, negotiated service channel — VCS and File share one connection per host. Terminal
/// relays keep their existing connections.
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
  /// One counter serves BOTH services, on purpose: the agent keys its chunked-request reassembly by
  /// stream alone, so a VCS request and a File request that shared a number could merge their buffers.
  private var nextStream: UInt32 = 1
  private struct Pending {
    let continuation: CheckedContinuation<Data, Error>
    var bytes = Data()
  }
  private var pending: [UInt32: Pending] = [:]
  /// Live watch subscriptions, keyed by the client-chosen id the agent echoes in every event. Read by
  /// `receive()` for each event and cleared by `fail()`, so both hold `lock`.
  private var watchHandlers: [UInt64: @Sendable (FileWatchEvent) -> Void] = [:]
  private var nextSubscription: UInt64 = 1
  /// The peer's raw greeting version. Kept (not just compared once in `connect()`) because the File
  /// service is gated on it separately from VCS: see `AgentControlClient.minFileVersion`.
  private let helloVersion: UInt16
  /// How the File service negotiation ended. Never a failed CONNECTION: VCS works regardless, and
  /// the agent is kept alive because it may own terminals. The three outcomes are different facts
  /// with different answers, and folding them together was a bug:
  /// - `unsupported`: the peer's greeting predates the service (or speaks another File version).
  ///   `files(context:)` reports `VCSError.backendVersion` and the router falls back to native reads.
  ///   Permanent for that agent.
  /// - `failed`: the peer says it has the service and the probe did not come back (timeout, lost
  ///   budget, garbled reply). Transient, so it must NOT read as an old agent and silently select
  ///   native access for the connection's whole life; `files(context:)` retires the connection so the
  ///   next acquisition reconnects and probes again.
  /// - `ready`.
  private enum FileNegotiation { case unsupported, failed, ready }
  private var _fileNegotiation: FileNegotiation = .unsupported
  /// Streams this connection gave up waiting on (request timeout) but whose reply may still
  /// arrive. Tracked so a late reply drains harmlessly instead of `receive()` treating an unknown
  /// stream id as a protocol violation and tearing down every OTHER in-flight request too.
  private var abandoned: Set<UInt32> = []
  /// Negotiated once in `connect()`, before this connection is shared with any other caller.
  /// `exec` is absent on a still-running pre-upgrade agent that answers `reads` but has no VCS
  /// write service at all — `writer(context:reader:)` treats that as `VCSError.backendVersion`,
  /// the same signal `RepositoryRouter` already falls back to native writes on.
  private var _capabilities: AgentVCSCapabilities?
  private var capabilities: AgentVCSCapabilities? { lock.withLock { _capabilities } }
  /// The exec wire version this client speaks. `AgentExecRequest.version` carries the same number on
  /// the wire and is declared separately, so this is a claim the compiler does not check — asserted
  /// in `AgentVCSProtocolTests` instead.
  private static let execVersion = 1
  /// The first exec service version that reassembles chunked requests. Separate from `execVersion`
  /// because it gates a FRAMING capability, not the request body: a version-1 agent speaks the same
  /// `AgentExecRequest` and is fully usable, it just cannot be sent one in pieces.
  private static let chunkedRequestVersion = 2
  /// `MAX_ENVELOPE_PAYLOAD` in `protocol/envelope.rs`.
  private static let maxEnvelopePayload = 1 << 20
  /// `MAX_REQUEST` in `vcs.rs` — the reassembled ceiling, mirroring the reply side's.
  private static let maxRequest = 16 * 1024 * 1024
  /// Marks a chunked request envelope. A whole request is JSON and starts `{`, so the two are
  /// unambiguous — see `REQUEST_CHUNK_MARKER`.
  private static let requestChunkMarker: UInt8 = 0x02
  /// `Service::Vcs`, `Service::File` and `Service::Status` in the agent's envelope.
  private static let vcsService: UInt8 = 2
  private static let fileService: UInt8 = 3
  private static let statusService: UInt8 = 4
  /// The ceiling prompt, delivered to whoever is watching. One stream per connection: the verdict is
  /// per box, so there is nothing to key subscriptions by.
  let ceilingPrompts: AsyncStream<AgentCeilingPrompt>
  private let ceilingPrompt: AsyncStream<AgentCeilingPrompt>.Continuation

  private init(host: HostID, descriptor: Int32, helloVersion: UInt16) {
    self.host = host
    self.descriptor = descriptor
    self.helloVersion = helloVersion
    (disconnection, disconnected) = AsyncStream<Void>.makeStream()
    // Newest-only: a prompt the app never got round to reading is superseded by the next one, and
    // the deadline in a stale one has passed by definition.
    (ceilingPrompts, ceilingPrompt) = AsyncStream<AgentCeilingPrompt>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
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
        var helloVersion: UInt16 = 0
        let deadline = Date().addingTimeInterval(2)
        while true {
          if let greeting = try AgentControlClient.decodeHello(hello) {
            helloVersion = greeting.version
            // Checked against the peer's raw greeting, not the negotiated Terminal/Control
            // minimum: a still-running pre-upgrade agent (kept alive because it may own
            // terminals) truthfully reports its own lower version here, and its `dispatch` has no
            // VCS handling at all — it would silently drop the capabilities request that follows,
            // stalling this connect for the full capabilities timeout instead of failing now.
            // Matches `MIN_VCS_VERSION` in the agent's `protocol::envelope`.
            guard greeting.version >= AgentControlClient.minVCSVersion else {
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
        return AgentVCSConnection(host: host, descriptor: fd, helloVersion: helloVersion)
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
      await connection.negotiateFiles()
      return connection
    } catch HostConnectionError.connectionLost {
      // Rethrown UNCHANGED, not wrapped. `LocalAgentVCS` catches exactly this case to spawn wr-agent
      // and retry, and flattening it into `serviceUnavailable` routed a dropped handshake around
      // that recovery entirely — leaving the VCS service dead until the app was restarted, over a
      // stale socket, which is the common case rather than an exotic one (the daemon leaves
      // `session.sock` behind on any `pkill`).
      //
      // Only this case. A `capabilities` reply that arrives and says the agent is incompatible, and a
      // handshake that times out against a HUNG agent (`.requestTimedOut` — which is the reason that
      // case exists; it used to arrive here as `.connectionLost` and take the respawn path), are both
      // still `serviceUnavailable`: a respawn cannot fix either, since the second candidate exits
      // without binding while the first holds the single-instance flock.
      await connection.close()
      throw HostConnectionError.connectionLost
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
    // Presence and version of the SERVICE, not a count of the caller's own methods. `>=` rather
    // than `==` so an agent that gains a version 3 does not refuse a client speaking 1 — the agent
    // is what decides whether it still accepts this request, and it answers that on the request
    // itself (`exec`'s version guard), which is the only place that can know.
    //
    // KNOWN GAP in that reasoning: a per-request refusal does NOT reach the native fallback. A
    // `BackendVersion` error arriving in a REPLY is decoded in `AgentCommandRunner.exec`, throws,
    // and becomes `neverRan`/`launchFailed` — not the `VCSError.backendVersion` that
    // `RepositoryRouter.writer(for:)` falls back on. So a future agent that DROPS version 1 would
    // fail every write as "launch failed" rather than writing natively. Nothing can hit this today
    // (no such agent exists, and 2 still accepts 1), but the `>=` is justified by a mechanism that
    // is not wired up, and that is worth knowing before the first version that drops one.
    guard let exec = capabilities?.exec, exec >= Self.execVersion else {
      throw VCSError.backendVersion("Agent does not support VCS writes.")
    }
    let engine = CLIVCSWriter(
      vcs: context.backend.rawValue, runner: AgentCommandRunner(connection: self),
      makeProvider: { _ in AgentCurrentRefProvider(reader: reader) }, gate: .shared)
    return try BoundLocalWriter(context: context, reader: reader, writer: engine)
  }

  /// Probe the File service, if the peer's greeting says it exists. Runs once in `connect()`, before
  /// this connection is shared, and NEVER fails it: an agent that predates the service, or one whose
  /// probe is unanswered or unreadable, leaves VCS fully working and just has no file service —
  /// reported later as `VCSError.backendVersion`, which the router already falls back to native on.
  /// (The alternative — failing `connect()` — would take VCS down with it, and the agent is kept
  /// alive precisely because it may own terminals, so that is not a state the user can fix.)
  ///
  /// Probed on `Service::File` itself, never through the VCS `capabilities` reply, whose `reads`
  /// count is compared for equality by every existing client.
  private func negotiateFiles() async {
    // Against the peer's RAW greeting, before any File envelope: a protocol-2 agent silently drops
    // them, so the probe would otherwise wait out its whole timeout.
    guard helloVersion >= AgentControlClient.minFileVersion else { return }
    let outcome: FileNegotiation
    do {
      let reply = try await request(
        AgentFileRequest(method: "capabilities"), timeout: 2, service: Self.fileService)
      let capabilities = try AgentFileReply<AgentFileCapabilities>.decode(reply)
      outcome = capabilities.version == 1 ? .ready : .unsupported
    } catch {
      outcome = .failed
    }
    lock.withLock { _fileNegotiation = outcome }
  }

  func files(context: FileContext) throws -> FileProviding {
    guard context.location.host == host else { throw HostConnectionError.mismatchedContext }
    guard lock.withLock({ !closed }) else { throw HostConnectionError.connectionLost }
    switch lock.withLock({ _fileNegotiation }) {
    case .ready:
      return AgentFileProvider(context: context, connection: self)
    case .unsupported:
      throw VCSError.backendVersion("Agent does not support the file service.")
    case .failed:
      Task { await close() }
      throw HostConnectionError.serviceUnavailable("File service negotiation failed; reconnecting.")
    }
  }

  /// The wakefulness service on this connection, or `VCSError.backendVersion` when the peer predates
  /// it.
  ///
  /// Gated on the greeting version alone — there is no connect-time probe, unlike the File service.
  /// The version IS the contract (`MIN_STATUS_VERSION`: a protocol-4 agent answers Status), and a
  /// probe added a failure mode with no data to show for it: one reply slower than its timeout, on an
  /// agent under exactly the load that makes wakefulness matter, left the badge and every ceiling
  /// prompt off for the life of the connection. The number the probe used to keep, the agent's prompt
  /// timeout, is in every `status` reply; the watch reads it from its first.
  func wakefulness() throws -> AgentWakefulnessService {
    try lock.withLock {
      guard !closed else { throw HostConnectionError.connectionLost }
      guard helloVersion >= AgentControlClient.minStatusVersion else {
        throw VCSError.backendVersion("Agent does not support the status service.")
      }
    }
    return AgentWakefulnessService(connection: self)
  }

  /// A Status request: one envelope, never chunked. 5s — `status` and `keep` both read a mutex the
  /// service thread holds for microseconds, so anything slower is a wedged agent, and this runs on a
  /// poll that will simply ask again.
  func statusRequest(_ request: AgentStatusRequest) async throws -> Data {
    try await self.request(request, timeout: 5, service: Self.statusService)
  }

  /// A File request: one envelope, never chunked (the agent does not reassemble them).
  ///
  /// 45s, not the VCS default of 30: a jj listing can legitimately spend 30s waiting for the
  /// working-copy lock and then up to 10s running, and a client that gives up first leaves the agent
  /// thread (and its shared request slot) queued on the lock while the caller starts another.
  func fileRequest(_ request: AgentFileRequest, timeout: TimeInterval = 45) async throws -> Data {
    try await self.request(request, timeout: timeout, service: Self.fileService)
  }

  /// Subscribe to filesystem changes under `root`. The handler is registered BEFORE the request is
  /// sent: events follow the acknowledgement on the same socket, and one that arrived while this
  /// method was still resuming from its `await` would find no handler and be lost.
  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle
  {
    let id: UInt64 = try lock.withLock {
      guard !closed else { throw HostConnectionError.connectionLost }
      let id = nextSubscription
      nextSubscription += 1
      watchHandlers[id] = onEvent
      return id
    }
    do {
      let reply = try await fileRequest(
        AgentFileRequest(method: "watch", root: root, subscription: id))
      _ = try AgentFileReply<AgentFileSubscription>.decode(reply)
    } catch {
      lock.withLock { _ = watchHandlers.removeValue(forKey: id) }
      // The request may have left before it failed here (a cancellation or a timeout after the send),
      // in which case the agent is holding a watcher nobody will ever unsubscribe. `unwatch` is
      // idempotent on the agent, so asking is harmless when it never registered.
      Task.detached { [weak self] in await self?.sendUnwatch(id) }
      throw error
    }
    // Detached, so a CANCELLED caller still sends the unwatch: `request` starts with
    // `Task.checkCancellation()`, and a `stop()` cancels the very task that then runs this. Without
    // the detach every stop/start cycle would leak an agent-side watcher until the connection ended,
    // and rapid workroom switching would walk into the per-connection subscription cap.
    return FileWatchHandle { [weak self] in
      await Task.detached { await self?.unwatch(id) }.value
    }
  }

  /// Handler first, then the request: from this line on a late event for `id` is dropped by
  /// `receive()` rather than delivered to a caller that has stopped listening. Best effort after that —
  /// if the connection is gone the agent has already torn the subscription down with it.
  private func unwatch(_ id: UInt64) async {
    let known = lock.withLock { watchHandlers.removeValue(forKey: id) != nil }
    guard known else { return }
    await sendUnwatch(id)
  }

  private func sendUnwatch(_ id: UInt64) async {
    _ = try? await fileRequest(AgentFileRequest(method: "unwatch", subscription: id), timeout: 5)
  }

  /// One envelope: the service byte, the stream, the payload length, then the payload.
  private static func envelope(service: UInt8 = vcsService, stream: UInt32, payload: Data) -> Data {
    var envelope = Data([service])
    for value in [stream, UInt32(payload.count)] {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
    }
    envelope.append(payload)
    return envelope
  }

  /// The payloads to send for one request: exactly one, byte-identical to what shipped before, or a
  /// marker-framed sequence when the body exceeds one envelope.
  ///
  /// Each chunk is `[marker][isFinal][bytes]`, so the agent knows both that this is a chunked
  /// request and when it has all of it, without a length header it would have to trust.
  private static func payloads(for bytes: Data, chunked: Bool) -> [Data] {
    guard chunked else { return [bytes] }
    let limit = maxEnvelopePayload - 2
    var payloads: [Data] = []
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let end = bytes.index(index, offsetBy: limit, limitedBy: bytes.endIndex) ?? bytes.endIndex
      var payload = Data([requestChunkMarker, end == bytes.endIndex ? 1 : 0])
      payload.append(bytes[index..<end])
      payloads.append(payload)
      index = end
    }
    return payloads
  }

  func close() async { fail(HostConnectionError.connectionLost) }

  func request<Request: Encodable>(
    _ request: Request, timeout: TimeInterval = 30, service: UInt8 = 2
  ) async throws -> Data {
    try Task.checkCancellation()
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let bytes = try encoder.encode(request)
    // A request larger than the protocol's per-envelope ceiling (`MAX_ENVELOPE_PAYLOAD`) is split
    // across envelopes on one stream — the mirror of how replies have always been chunked. What
    // makes this reachable at all is `CLIVCSWriter`'s NUL-separated pathspec, sent as an
    // `AgentExecRequest` stdin payload: "select all and commit" in a large repository produced a
    // payload that worked natively (stdin exists precisely to sidestep `E2BIG`) and failed through
    // the agent, which is a plain regression against the path it replaced.
    //
    // Gated on the agent's own exec version, because the framing is a wire change: a pre-chunking
    // agent would read the marker byte as the start of a JSON document and answer with a parse
    // error. Below the ceiling nothing changes — the envelope is byte-identical to what shipped
    // before, so the common path pays nothing for this.
    let chunked = service == Self.vcsService && bytes.count > Self.maxEnvelopePayload
    if service != Self.vcsService && bytes.count > Self.maxEnvelopePayload {
      throw FileServiceError.failed("Agent request is too large.")
    }
    if chunked {
      guard let exec = capabilities?.exec, exec >= Self.chunkedRequestVersion else {
        throw VCSError.partialData("VCS request is too large for this agent.")
      }
      guard bytes.count <= Self.maxRequest else {
        throw VCSError.partialData("VCS request is too large.")
      }
    }
    let cancellation = RequestCancellationBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Two refusals, two errors. Both happen before a byte reaches the socket, but they must
        // NOT collapse: `connect()` issues its own `capabilities` request through here, and
        // `LocalAgentVCS` catches exactly `.connectionLost` from it to spawn the agent and retry —
        // the stale-`session.sock` case, which is common, not exotic. Reporting a closed connection
        // as anything else would silently stop the agent ever being started.
        let refusal: (stream: UInt32?, error: HostConnectionError) = lock.withLock {
          if closed { return (nil, .connectionLost) }
          // ponytail: one 32-slot pool shared by every read AND write on this connection, app-wide.
          // A write can now legitimately hold a slot for minutes (`commitTimeout` = 600s), where only
          // reads (seconds at most) used to compete for these slots. Split reads and writes onto
          // separate pools/connections if this is ever observed in practice.
          //
          // `.notDispatched` rather than `.connectionLost`: backpressure is not a lost connection,
          // and a WRITE caller can say "this definitely did not run" — the difference between a safe
          // retry and one that double-applies a commit or a push. See `AgentCommandRunner.neverRan`.
          guard nextStream < UInt32.max, pending.count < 32 else { return (nil, .notDispatched) }
          let stream = nextStream
          nextStream += 1
          pending[stream] = Pending(continuation: continuation)
          return (stream, .notDispatched)
        }
        guard let stream = refusal.stream else {
          continuation.resume(throwing: refusal.error)
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
          do {
            for payload in Self.payloads(for: bytes, chunked: chunked) {
              try Self.send(
                descriptor, Self.envelope(service: service, stream: stream, payload: payload))
            }
          } catch {
            fail(error)
          }
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
          let service = header[0]
          // Stream 0 is the agent's own: File watch events and the Status service's ceiling prompt,
          // never a reply. On the VCS service it has always been a violation and still is.
          let streamIsValid =
            stream > 0 || service == Self.fileService || service == Self.statusService
          guard
            service == Self.vcsService || service == Self.fileService
              || service == Self.statusService, streamIsValid, length > 0, length <= 1 << 20
          else {
            throw HostConnectionError.serviceUnavailable("Invalid agent envelope.")
          }
          guard buffer.count >= 9 + length else { break }
          let payload = Data(buffer.dropFirst(9).prefix(length))
          buffer = Data(buffer.dropFirst(9 + length))
          guard payload.first == 0 || payload.first == 1 else {
            throw HostConnectionError.serviceUnavailable("Invalid agent chunk.")
          }
          if stream == 0 {
            // An event is always ONE final envelope; the agent never chunks one, so a continuation
            // here means the two sides disagree about the protocol.
            guard payload.first == 1 else {
              throw HostConnectionError.serviceUnavailable("Invalid agent event chunk.")
            }
            // Branched on the SERVICE, not decoded twice: the two events share nothing but their
            // stream, and decoding a ceiling prompt as an `AgentFileEvent` would fail and drop it
            // silently — a bug every existing test stays green through.
            deliver(event: payload.dropFirst(), service: service)
            continue
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

  /// Hand one agent-initiated event to the subscription it names. An unknown id — an unsubscribe
  /// racing an event already in flight — is dropped: it is the normal shape of that race, not a
  /// protocol violation, and treating it as one would fail every other request on the connection. An
  /// undecodable or unrecognized event is dropped too, for forward compatibility.
  private func deliver(event payload: Data, service: UInt8) {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    if service == Self.statusService {
      // Only the one event kind exists; anything else a newer agent adds is dropped, exactly as an
      // unknown file event is — and so is a version this build does not speak, as a reply's would be.
      guard let wire = try? decoder.decode(AgentStatusEvent.self, from: payload),
        wire.version == 1, wire.event == "awake_ceiling_prompt", let awake = wire.awakeSeconds,
        let deadline = wire.promptDeadline
      else { return }
      ceilingPrompt.yield(
        AgentCeilingPrompt(awakeSeconds: awake, promptDeadline: deadline))
      return
    }
    guard let wire = try? decoder.decode(AgentFileEvent.self, from: payload),
      let event = wire.model
    else { return }
    let handler = lock.withLock { watchHandlers[wire.subscription] }
    handler?(event)
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
    let failed: (pending: [Pending], watchers: [@Sendable (FileWatchEvent) -> Void])? =
      lock.withLock {
        guard !closed else { return nil }
        closed = true
        let values = Array(pending.values)
        let watchers = Array(watchHandlers.values)
        pending.removeAll()
        abandoned.removeAll()
        watchHandlers.removeAll()
        shutdown(descriptor, SHUT_RDWR)
        return (values, watchers)
      }
    guard let failed else { return }
    ceilingPrompt.finish()
    for operation in failed.pending { operation.continuation.resume(throwing: error) }
    // Outside the lock: a handler is caller code. Every subscription learns its watch is gone, so it
    // can resubscribe on the next generation and refresh whatever it was showing.
    for watcher in failed.watchers { watcher(.lost) }
    disconnected.finish()
  }
}

struct AgentVCSCapabilities: Decodable {
  let version: Int
  let reads: Int
  /// The exec service's wire version, or nil on a still-running pre-upgrade agent that predates the
  /// service entirely.
  ///
  /// Replaces a `writes` COUNT, which counted methods on `LocalVCSWriting` — a protocol that exists
  /// only in this process. wr-agent implements one generic exec service and never had eight write
  /// methods to report, so the number described nothing on the answering side and nothing could keep
  /// it true: adding a ninth method here, a change the passthrough fully supports, made the equality
  /// check below fail against a completely capable agent and silently dropped every user to native
  /// writes with no log line.
  let exec: Int?
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
