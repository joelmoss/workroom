import Darwin
import Foundation
import OSLog
import WorkroomSystem
import WorkroomVCS
import WorkroomWire

/// A persistent, negotiated service channel — VCS and File share one connection per host. Terminal
/// relays keep their existing connections.
/// Blocking socket work runs on GCD. Closing shuts down the descriptor; only deinit closes it,
/// so an in-flight reader/writer can never act on a recycled descriptor.
public final class DaemonVCSConnection: @unchecked Sendable {
  public let host: HostID
  public let disconnection: AsyncStream<Void>
  private let disconnected: AsyncStream<Void>.Continuation
  private let descriptor: Int32
  private let lock = NSLock()
  private let writes = DispatchQueue(label: "workroom.daemon.vcs.write")
  private var closed = false
  /// One counter serves BOTH services, on purpose: the daemon keys its chunked-request reassembly by
  /// stream alone, so a VCS request and a File request that shared a number could merge their buffers.
  private var nextStream: UInt32 = 1
  private struct Pending {
    let continuation: CheckedContinuation<Data, Error>
    /// The service the request went out on. A Control reply completes only a Control request: the
    /// stream counter is shared by every service, so a stream id alone does not say whose reply it is.
    let service: UInt8
    var bytes = Data()
  }
  private var pending: [UInt32: Pending] = [:]
  /// When the envelope `send` now running on `writes` started, or nil between sends. One envelope is
  /// at most `maxEnvelopePayload`, so a send still running after half a request's timeout means the
  /// peer is connected but not reading: the transport is wedged. See the deadline in `request`.
  private var sendStarted: ContinuousClock.Instant?
  /// Counts sends, so a request send's own stall watchdog knows whether it is still that send.
  private var sendCount: UInt64 = 0
  /// Bytes read from the host so far: anything arriving proves the link is alive.
  private var received: UInt64 = 0
  public var bytesReceived: UInt64 { lock.withLock { received } }
  /// Live watch subscriptions, keyed by the client-chosen id the daemon echoes in every event. Read by
  /// `receive()` for each event and cleared by `fail()`, so both hold `lock`.
  private var watchHandlers: [UInt64: @Sendable (FileWatchEvent) -> Void] = [:]
  /// The program-status subscriber; one per connection, since the daemon keeps one subscription per
  /// connection. Held under `lock` like `watchHandlers`.
  private var programStatusHandler: (@Sendable (ProgramStatusEvent) -> Void)?
  /// Set once the first undecodable program-status event or dropped record is logged.
  private var loggedProgramStatusDecode = false
  private var nextSubscription: UInt64 = 1
  /// The peer's raw greeting version. Kept (not just compared once in `connect()`) because the File
  /// service is gated on it separately from VCS: see `DaemonHandshake.minFileVersion`.
  public let helloVersion: UInt16
  /// How the File service negotiation ended. Never a failed CONNECTION: VCS works regardless, and
  /// the daemon is kept alive because it may own terminals. The three outcomes are different facts
  /// with different answers, and folding them together was a bug:
  /// - `unsupported`: the peer's greeting predates the service (or speaks another File version).
  ///   `files(context:)` reports `VCSError.backendVersion` and the router falls back to native reads.
  ///   Permanent for that daemon.
  /// - `failed`: the peer says it has the service and the probe did not come back (timeout, lost
  ///   budget, garbled reply). Transient, so it must NOT read as an old daemon and silently select
  ///   native access for the connection's whole life; `files(context:)` retires the connection so the
  ///   next acquisition reconnects and probes again.
  /// - `ready`.
  public enum FileNegotiation: Sendable { case unsupported, failed, ready }
  private var _fileNegotiation: FileNegotiation = .unsupported
  /// How the File service negotiation ended; read under the lock (`files(context:)`, in the app).
  public var fileNegotiation: FileNegotiation { lock.withLock { _fileNegotiation } }
  /// Streams this connection gave up waiting on (request timeout) but whose reply may still
  /// arrive. Tracked so a late reply drains harmlessly instead of `receive()` treating an unknown
  /// stream id as a protocol violation and tearing down every OTHER in-flight request too.
  private var abandoned: [UInt32: UInt8] = [:]
  /// Negotiated once in `connect()`, before this connection is shared with any other caller.
  /// `exec` is absent on a still-running pre-upgrade daemon that answers `reads` but has no VCS
  /// write service at all — `writer(context:reader:)` treats that as `VCSError.backendVersion`,
  /// the same signal `RepositoryRouter` already falls back to native writes on.
  private var _capabilities: DaemonVCSCapabilities?
  public var capabilities: DaemonVCSCapabilities? { lock.withLock { _capabilities } }
  /// The exec wire version this client speaks. `DaemonExecRequest.version` carries the same number on
  /// the wire and is declared separately, so this is a claim the compiler does not check — asserted
  /// in `DaemonVCSProtocolTests` instead.
  public static let execVersion = 1
  /// The first exec service version that reassembles chunked requests. Separate from `execVersion`
  /// because it gates a FRAMING capability, not the request body: a version-1 daemon speaks the same
  /// `DaemonExecRequest` and is fully usable, it just cannot be sent one in pieces.
  private static let chunkedRequestVersion = 2
  /// The first exec service version a remote host's writes can use: it takes `host_environment`
  /// and answers `stat`.
  public static let remoteWriteVersion = 3
  /// `MAX_ENVELOPE_PAYLOAD` in `wr-protocol/src/envelope.rs`.
  private static let maxEnvelopePayload = 1 << 20
  /// `MAX_REQUEST` in `rpc.rs` — the reassembled ceiling, mirroring the reply side's.
  private static let maxRequest = 16 * 1024 * 1024
  /// Marks a chunked request envelope. A whole request is JSON and starts `{`, so the two are
  /// unambiguous — see `REQUEST_CHUNK_MARKER`.
  private static let requestChunkMarker: UInt8 = 0x02
  /// `Service::Vcs`, `Service::File`, `Service::Status` and `Service::Forward` in the daemon's
  /// envelope. Status is retired (#382) and never asked, but a daemon from before then may still
  /// send on it, which is dropped rather than failing the connection.
  private static let vcsService: UInt8 = 2
  public static let fileService: UInt8 = 3
  private static let statusService: UInt8 = 4
  private static let forwardService: UInt8 = 5
  /// `Service::Layout` (#255): JSON like the others, and chunked like VCS, since a layout can be
  /// larger than one envelope.
  public static let layoutService: UInt8 = 6
  /// `Service::ProgramStatus` (#358): requests on their own streams, events on stream 0.
  public static let programStatusService: UInt8 = 7
  /// `Service::Control`: the session list a terminal helper answers (#239). Its payloads are
  /// `SessionFrame`s, not a chunk flag and JSON.
  private static let controlService: UInt8 = 0
  /// Live forwarded streams, keyed by the multiplex stream id the daemon echoes on every envelope.
  /// Every access holds `lock`: the insert in `reserveForward`, the remove in `releaseForward`, the
  /// read in `receive()` and the clear in `fail()`.
  private var forwardHandlers: [UInt32: @Sendable (UInt8, Data) -> Void] = [:]
  /// Forwarded connections held on this connection, across every listener: the daemon's
  /// `MAX_FORWARDS` is per multiplex connection, so a per-listener count let several rows together
  /// send OPENs it would certainly refuse.
  private var forwardsHeld = 0
  /// The local process carrying a driver's stream (`ssh host workroomd relay`), or nil for a local
  /// daemon's socket. Ended when the connection fails, so a closed connection leaves no ssh behind.
  private let carrier: HostStream?

  private init(host: HostID, descriptor: Int32, helloVersion: UInt16, carrier: HostStream?) {
    self.host = host
    self.descriptor = descriptor
    self.helloVersion = helloVersion
    self.carrier = carrier
    (disconnection, disconnected) = AsyncStream<Void>.makeStream()
  }

  deinit { Darwin.close(descriptor) }

  public static func connect(host: HostID, socketPath: String) async throws -> DaemonVCSConnection {
    let fd = try await runBlocking {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw HostConnectionError.connectionLost }
      noSignalOnWrite(fd)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let path = Array(socketPath.utf8)
      guard !path.contains(0), path.count < MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(fd)
        throw VCSError.io("Daemon socket path is invalid.")
      }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else {
        Darwin.close(fd)
        throw HostConnectionError.connectionLost
      }
      return fd
    }
    return try await negotiate(host: host, descriptor: fd, carrier: nil, handshakeTimeout: 2)
  }

  /// Over a driver's stream (`HostDriver.openStream`), which this connection now owns: its
  /// descriptor is closed and its process ended with the connection, including when this throws.
  ///
  /// A handshake the stream never answered is `serviceUnavailable` with what the carrier said, not
  /// `connectionLost`. There is nothing to respawn on a remote host, and "Host key verification
  /// failed." or the relay's "no daemon listening" is the whole diagnosis.
  public static func connect(host: HostID, stream: HostStream) async throws -> DaemonVCSConnection {
    do {
      return try await negotiate(
        host: host, descriptor: stream.handOff(), carrier: stream,
        handshakeTimeout: stream.handshakeTimeout)
    } catch HostConnectionError.connectionLost {
      throw HostConnectionError.serviceUnavailable(await stream.failure())
    } catch DaemonHandshake.DaemonProtocolError.notADaemon {
      // Commonly a shell startup file on the host that prints to stdout ahead of the relay. Not
      // `failure()`: the carrier answered, and saying it did not would contradict this.
      throw HostConnectionError.serviceUnavailable(
        "The host sent something other than a daemon's greeting (does a shell startup file print?)."
      )
    }
  }

  /// `SO_NOSIGPIPE`, set as soon as the socket exists: a write to a peer that has hung up then
  /// fails with `EPIPE` rather than killing the app. Not later: once the peer has gone, `setsockopt`
  /// itself fails, and a peer that greets and hangs up before the first write left the flag unset
  /// and the hello's `send` raising SIGPIPE.
  public static func noSignalOnWrite(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  private static func negotiate(
    host: HostID, descriptor fd: Int32, carrier: HostStream?, handshakeTimeout: TimeInterval
  ) async throws -> DaemonVCSConnection {
    // `SO_NOSIGPIPE` is already set: by `connect(host:socketPath:)` or `HostStream.spawn`, when
    // the socket was made (see `noSignalOnWrite`).
    let connection = try await runBlocking {
      do {
        var timeout = timeval(tv_sec: max(1, Int(handshakeTimeout.rounded(.up))), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try send(fd, Data(DaemonHandshake.encodeHello(build: "Workroom VCS")))
        var hello: [UInt8] = []
        var helloVersion: UInt16 = 0
        let deadline = Date().addingTimeInterval(handshakeTimeout)
        while true {
          if let greeting = try DaemonHandshake.decodeHello(hello) {
            helloVersion = greeting.version
            // Checked against the peer's raw greeting, not the negotiated Terminal/Control
            // minimum: a still-running pre-upgrade daemon (kept alive because it may own
            // terminals) truthfully reports its own lower version here, and its `dispatch` has no
            // VCS handling at all — it would silently drop the capabilities request that follows,
            // stalling this connect for the full capabilities timeout instead of failing now.
            // Matches `MIN_VCS_VERSION` in the daemon's `wr_protocol::envelope`.
            guard greeting.version >= DaemonHandshake.minVCSVersion else {
              throw VCSError.backendVersion("Daemon predates VCS support.")
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
        // The handshake bound must not linger onto ordinary request sends — a legitimately busy
        // daemon (mid VCS request on another thread) can leave the socket buffer full past it with
        // no fault of its own; a lingering SO_SNDTIMEO would then report that as connection loss.
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return DaemonVCSConnection(
          host: host, descriptor: fd, helloVersion: helloVersion, carrier: carrier)
      } catch {
        Darwin.close(fd)
        carrier?.end()
        throw error
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { connection.receive() }
    do {
      let reply = try await connection.request(
        DaemonVCSRequest(method: "capabilities"), timeout: handshakeTimeout)
      let capabilities = try DaemonVCSReply<DaemonVCSCapabilities>.decode(reply)
      // `backendVersion`, not `serviceUnavailable`: a daemon that answers but speaks different reads
      // (a newer one left running across an app rollback — it outlives the app and may own
      // terminals) is not transient, and `backendVersion` is what the router serves natively on.
      guard capabilities.version == 1, capabilities.reads == 9 else {
        throw VCSError.backendVersion("Daemon does not support these VCS reads.")
      }
      // Not yet shared with any other caller, so a plain lock-guarded write is enough — no
      // concurrent reader can observe a half-set value.
      connection.lock.withLock { connection._capabilities = capabilities }
      await connection.negotiateFiles(timeout: handshakeTimeout)
      return connection
    } catch HostConnectionError.connectionLost, HostConnectionError.notDispatched {
      // `notDispatched` too: `request` refuses with it once the connection is closed, and a fresh
      // connection is only closed before its first request if the peer already hung up.
      //
      // Rethrown as `connectionLost`, not wrapped. `LocalDaemonVCS` catches exactly this case to
      // spawn workroomd and retry, and flattening it into `serviceUnavailable` routed a dropped
      // handshake around that recovery entirely — leaving the VCS service dead until the app was
      // restarted, over a stale socket, which is the common case rather than an exotic one (the
      // daemon leaves `session.sock` behind on any `pkill`).
      //
      // Only this case. A handshake that times out against a HUNG daemon (`.requestTimedOut` — which
      // is the reason that case exists; it used to arrive here as `.connectionLost` and take the
      // respawn path) is still `serviceUnavailable`: a respawn cannot fix it, since the second
      // candidate exits without binding while the first holds the single-instance flock. A daemon
      // that answers `capabilities` as incompatible is `backendVersion` (below), served natively.
      await connection.close()
      throw HostConnectionError.connectionLost
    } catch VCSError.backendVersion(let detail) {
      await connection.close()
      throw VCSError.backendVersion(detail)
    } catch {
      await connection.close()
      throw HostConnectionError.serviceUnavailable("VCS negotiation failed: \(error)")
    }
  }

  /// Probe the File service, if the peer's greeting says it exists. Runs once in `connect()`, before
  /// this connection is shared, and NEVER fails it: a daemon that predates the service, or one whose
  /// probe is unanswered or unreadable, leaves VCS fully working and just has no file service —
  /// reported later as `VCSError.backendVersion`, which the router already falls back to native on.
  /// (The alternative — failing `connect()` — would take VCS down with it, and the daemon is kept
  /// alive precisely because it may own terminals, so that is not a state the user can fix.)
  ///
  /// Probed on `Service::File` itself, never through the VCS `capabilities` reply, whose `reads`
  /// count is compared for equality by every existing client.
  private func negotiateFiles(timeout: TimeInterval) async {
    // Against the peer's RAW greeting, before any File envelope: a protocol-2 daemon silently drops
    // them, so the probe would otherwise wait out its whole timeout.
    guard helloVersion >= DaemonHandshake.minFileVersion else { return }
    let outcome: FileNegotiation
    do {
      let reply = try await request(
        DaemonFileRequest(method: "capabilities"), timeout: timeout, service: Self.fileService)
      let capabilities = try DaemonFileReply<DaemonFileCapabilities>.decode(reply)
      outcome = capabilities.version == 1 ? .ready : .unsupported
    } catch {
      outcome = .failed
    }
    lock.withLock { _fileNegotiation = outcome }
  }

  /// The working directory of terminal `session` on this connection's host, or nil when the daemon
  /// holds no such session or could not read it (#239).
  ///
  /// The daemon reads it from the session's foreground process each time it is asked, never from a
  /// cache, and a remote pane has no other source: libghostty drops an OSC 7 report whose host is
  /// not this Mac. It is the session list the daemon has answered since protocol 1, so there is no
  /// version to check.
  ///
  /// The default timeout, not a short one: half a request's timeout is how long ANY send in flight
  /// on the connection may take before `request` declares the transport wedged and fails it, so a
  /// 5s query behind a large commit or file save on a slow link would take VCS, File and every
  /// forward down with it.
  ///
  /// ponytail: the daemon builds this List under its session-store lock, which a client's reattach
  /// repaint also holds, and on this connection's read thread, so a List that lands mid-repaint holds
  /// up the connection's other requests for up to that repaint. A per-session cwd request would not;
  /// add one if footer queries are ever seen to stall VCS.
  public func workingDirectory(of session: UUID) async throws -> String? {
    let identifier = SessionIdentifier(uuidString: session.uuidString)
    let directory = try await sessions().first { $0.identifier == identifier }?.workingDirectory
    return directory?.isEmpty == false ? directory : nil
  }

  /// The host's session list: the same `List` frame the local control client sends.
  public func sessions() async throws -> [SessionDescriptor] {
    let reply = try await request(
      bytes: Data(SessionFrame(kind: .list).encoded()), timeout: 30,
      service: Self.controlService)
    var frames = SessionFrameDecoder()
    frames.push(Array(reply))
    guard let frame = try frames.next() else {
      throw HostConnectionError.serviceUnavailable("Incomplete session list.")
    }
    guard frame.kind == .sessions else {
      // `.failure` carries the daemon's reason: a list over the frame cap, for one.
      let reason = String(decoding: frame.payload, as: UTF8.self)
      throw HostConnectionError.serviceUnavailable("No session list: \(reason)")
    }
    return try SessionDescriptor.decodeList(frame.payload)
  }

  /// The same `Kill` frame the local control client sends, on this connection's Control service.
  public func endSession(_ session: UUID) async throws -> Bool {
    guard let identifier = SessionIdentifier(uuidString: session.uuidString) else { return true }
    let reply = try await request(
      bytes: Data(
        SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier)).encoded()),
      timeout: 30, service: Self.controlService)
    var frames = SessionFrameDecoder()
    frames.push(Array(reply))
    guard let frame = try frames.next() else {
      throw HostConnectionError.serviceUnavailable("Incomplete kill reply.")
    }
    return frame.kind == .acknowledged
  }

  /// Asks a run session's supervisor to restart, stop or quit (#522), on this connection's Control
  /// service. Throws when the daemon could not be asked or did not answer: the signal may or may
  /// not have been sent, which a caller must not read as the run being gone.
  public func signalSession(_ session: UUID, _ signal: RunSignal) async throws -> RunSignalReply {
    guard helloVersion >= DaemonHandshake.minRunVersion else {
      throw HostConnectionError.serviceUnavailable("This host's workroomd predates run sessions.")
    }
    let reply = try await request(
      bytes: Data(signal.frame(session: session)), timeout: 10, service: Self.controlService)
    guard let answer = RunSignalReply.decode(Array(reply)) else {
      throw HostConnectionError.serviceUnavailable("No reply to a run signal.")
    }
    return answer
  }

  /// Whether this connection has ended: a forward that outlives it (`PortForward`'s `reconnect`)
  /// makes a new one before it opens a stream.
  public var isClosed: Bool { lock.withLock { closed } }

  /// One of the daemon's `MAX_FORWARDS` slots, or nil when this connection holds them all. Released
  /// when the returned value is dropped.
  public func reserveForwardSlot() -> ForwardSlot? {
    let reserved = lock.withLock { () -> Bool in
      guard forwardsHeld < ForwardSlot.maxPerConnection else { return false }
      forwardsHeld += 1
      return true
    }
    guard reserved else { return nil }
    return ForwardSlot { [weak self] in self?.lock.withLock { self?.forwardsHeld -= 1 } }
  }

  /// Reserve a Forward stream and register its handler. Nothing is sent: the caller sends OPEN with
  /// `sendForward` once the id is somewhere the handler can read it, so a REPLY can never arrive
  /// before the handler knows which stream it belongs to.
  ///
  /// The id comes from the SAME counter every request uses, and is never handed out twice.
  /// `forward.rs` frees a stream id only once its CLOSE has been seen, and its module doc says a
  /// monotonic counter is how a client gets that rule for free — this is that counter.
  public func reserveForward(onOpcode: @escaping @Sendable (UInt8, Data) -> Void) throws -> UInt32 {
    try lock.withLock {
      guard !closed else { throw HostConnectionError.connectionLost }
      guard nextStream < UInt32.max else { throw HostConnectionError.notDispatched }
      let stream = nextStream
      nextStream += 1
      forwardHandlers[stream] = onOpcode
      return stream
    }
  }

  /// One Forward envelope: the opcode byte, then the body. Best effort — a forward whose connection
  /// has gone is told so by `fail()`, which is the only signal it needs. `then` runs once the
  /// envelope has left this process, or once it is certain never to: a forward's flow control and
  /// its open timer both need "on the wire", which the enqueue is not.
  public func sendForward(
    stream: UInt32, opcode: UInt8, body: Data, then: (@Sendable () -> Void)? = nil
  ) {
    let payload = Data([opcode]) + body
    writes.async { [self] in
      defer { then?() }
      guard lock.withLock({ !closed }) else { return }
      do {
        try sendOnWrites(
          Self.envelope(service: Self.forwardService, stream: stream, payload: payload))
      } catch {
        fail(error)
      }
    }
  }

  /// Stop listening on a forward stream. Anything that still arrives for it is dropped by
  /// `receive()`, which is the normal end of a stream the client closed itself.
  public func releaseForward(_ stream: UInt32) {
    lock.withLock { _ = forwardHandlers.removeValue(forKey: stream) }
  }

  /// A File request: one envelope, never chunked (the daemon does not reassemble them).
  ///
  /// 45s, not the VCS default of 30: a generous margin over the listing's own 10s
  /// (`FileListing.timeout`), so the client never gives up on a listing the daemon is still running
  /// and leaves its shared request slot busy while the caller starts another.
  public func fileRequest(_ request: DaemonFileRequest, timeout: TimeInterval = 45) async throws
    -> Data
  {
    try await self.request(request, timeout: timeout, service: Self.fileService)
  }

  /// Subscribe to filesystem changes under `root`. The handler is registered BEFORE the request is
  /// sent: events follow the acknowledgement on the same socket, and one that arrived while this
  /// method was still resuming from its `await` would find no handler and be lost.
  public func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void)
    async throws
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
        DaemonFileRequest(method: "watch", root: root, subscription: id))
      _ = try DaemonFileReply<DaemonFileSubscription>.decode(reply)
    } catch {
      lock.withLock { _ = watchHandlers.removeValue(forKey: id) }
      // The request may have left before it failed here (a cancellation or a timeout after the send),
      // in which case the daemon is holding a watcher nobody will ever unsubscribe. `unwatch` is
      // idempotent on the daemon, so asking is harmless when it never registered.
      Task.detached { [weak self] in await self?.sendUnwatch(id) }
      throw error
    }
    // Detached, so a CANCELLED caller still sends the unwatch: `request` starts with
    // `Task.checkCancellation()`, and a `stop()` cancels the very task that then runs this. Without
    // the detach every stop/start cycle would leak a daemon-side watcher until the connection ended,
    // and rapid workroom switching would walk into the per-connection subscription cap.
    return FileWatchHandle { [weak self] in
      await Task.detached { await self?.unwatch(id) }.value
    }
  }

  /// Handler first, then the request: from this line on a late event for `id` is dropped by
  /// `receive()` rather than delivered to a caller that has stopped listening. Best effort after that —
  /// if the connection is gone the daemon has already torn the subscription down with it.
  private func unwatch(_ id: UInt64) async {
    let known = lock.withLock { watchHandlers.removeValue(forKey: id) != nil }
    guard known else { return }
    await sendUnwatch(id)
  }

  private func sendUnwatch(_ id: UInt64) async {
    _ = try? await fileRequest(DaemonFileRequest(method: "unwatch", subscription: id), timeout: 5)
  }

  /// Subscribe to the host's program status (#358). The handler is registered BEFORE the request,
  /// as `watch` does: the snapshot follows the acknowledgement on the same socket. It stays
  /// registered for the connection's life; a new connection subscribes again and gets a new snapshot.
  public func subscribeProgramStatus(
    onEvent: @escaping @Sendable (ProgramStatusEvent) -> Void
  ) async throws -> ProgramStatusAvailability {
    // Against the raw greeting: an older daemon drops the envelope unanswered.
    guard helloVersion >= DaemonHandshake.minProgramStatusVersion else { return .unsupported }
    try lock.withLock {
      guard !closed else { throw HostConnectionError.connectionLost }
      programStatusHandler = onEvent
    }
    do {
      let result = try await programStatusRequest(DaemonProgramStatusRequest(method: "subscribe"))
      if result["available"] as? Bool == false {
        lock.withLock { programStatusHandler = nil }
        return .unavailable(result["reason"] as? String ?? "")
      }
      return .available
    } catch {
      lock.withLock { programStatusHandler = nil }
      throw error
    }
  }

  /// The user has seen `session`'s finished and failed records up to `revision`; `states` narrows
  /// which (nil means both).
  public func programStatusSeen(session: UUID, revision: UInt64, states: [String]? = nil)
    async throws
  {
    _ = try await programStatusRequest(
      DaemonProgramStatusRequest(
        method: "seen", session: session, revision: revision, states: states))
  }

  /// Clear status: removes every record of `session`.
  public func programStatusClear(session: UUID) async throws {
    _ = try await programStatusRequest(
      DaemonProgramStatusRequest(method: "clear", session: session))
  }

  /// One Program Status request; its `result` object, or the daemon's `error` thrown.
  private func programStatusRequest(_ request: DaemonProgramStatusRequest) async throws
    -> [String: Any]
  {
    guard helloVersion >= DaemonHandshake.minProgramStatusVersion else {
      throw VCSError.backendVersion("Daemon does not support program status.")
    }
    let encoder = JSONEncoder()
    let reply = try await self.request(
      bytes: encoder.encode(request), timeout: 15, service: Self.programStatusService)
    let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    if let error = object?["error"] {
      throw HostConnectionError.serviceUnavailable("Program status: \(error)")
    }
    guard let result = object?["result"] as? [String: Any] else {
      throw HostConnectionError.serviceUnavailable("Program status: unreadable reply.")
    }
    return result
  }

  /// Hand one program-status event to the subscriber. An event this build cannot read is dropped,
  /// never fatal to the connection, and the first such drop is logged.
  private func deliver(programStatus payload: Data) {
    let decoded = try? ProgramStatusEvent.decode(payload)
    if decoded == nil || decoded?.droppedRecords ?? 0 > 0 {
      let first = lock.withLock { () -> Bool in
        defer { loggedProgramStatusDecode = true }
        return !loggedProgramStatusDecode
      }
      if first {
        let host = String(describing: host)
        let what = decoded == nil ? "an undecodable event" : "unreadable records"
        Self.logger.error(
          "program status from \(host, privacy: .public): dropped \(what, privacy: .public)")
      }
    }
    guard let event = decoded?.event else { return }
    let handler = lock.withLock { programStatusHandler }
    handler?(event)
  }

  private static let logger = Logger(subsystem: "com.developwithstyle.workroom", category: "daemon")

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
  /// Each chunk is `[marker][isFinal][bytes]`, so the daemon knows both that this is a chunked
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

  public func close() async { fail(HostConnectionError.connectionLost) }

  public func request<Request: Encodable>(
    _ request: Request, timeout: TimeInterval = 30, service: UInt8 = 2
  ) async throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try await self.request(
      bytes: encoder.encode(request), timeout: timeout, service: service)
  }

  /// `request`'s transport, for a payload that is already encoded: JSON for the four services that
  /// speak it, a `SessionFrame` for Control.
  private func request(bytes: Data, timeout: TimeInterval, service: UInt8) async throws -> Data {
    try Task.checkCancellation()
    // A request larger than the protocol's per-envelope ceiling (`MAX_ENVELOPE_PAYLOAD`) is split
    // across envelopes on one stream — the mirror of how replies have always been chunked. What
    // makes this reachable at all is `CLIVCSWriter`'s NUL-separated pathspec, sent as an
    // `DaemonExecRequest` stdin payload: "select all and commit" in a large repository produced a
    // payload that worked natively (stdin exists precisely to sidestep `E2BIG`) and failed through
    // the daemon, which is a plain regression against the path it replaced.
    //
    // Gated on the daemon's own exec version, because the framing is a wire change: a pre-chunking
    // daemon would read the marker byte as the start of a JSON document and answer with a parse
    // error. Below the ceiling nothing changes — the envelope is byte-identical to what shipped
    // before, so the common path pays nothing for this.
    // Layout requests chunk too: every daemon with the service reassembles them (`layout.rs`).
    let chunkable = service == Self.vcsService || service == Self.layoutService
    let chunked = chunkable && bytes.count > Self.maxEnvelopePayload
    if !chunkable && bytes.count > Self.maxEnvelopePayload {
      throw FileServiceError.failed("Daemon request is too large.")
    }
    if chunked {
      if service == Self.vcsService {
        guard let exec = capabilities?.exec, exec >= Self.chunkedRequestVersion else {
          throw VCSError.partialData("VCS request is too large for this daemon.")
        }
      }
      guard bytes.count <= Self.maxRequest else {
        throw VCSError.partialData("VCS request is too large.")
      }
    }
    let cancellation = RequestCancellationBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Both refusals happen before a byte reaches the socket, so both are `.notDispatched`: a
        // WRITE caller must be able to say "this definitely did not run" (`DaemonCommandRunner`),
        // and a closed connection reported as `.connectionLost` read as "may have completed".
        // `connect()` still turns a closed fresh connection back into `.connectionLost`, which
        // `LocalDaemonVCS` catches to spawn the daemon and retry.
        let refusal: (stream: UInt32?, error: HostConnectionError) = lock.withLock {
          if closed { return (nil, .notDispatched) }
          // ponytail: one 32-slot pool shared by every read AND write on this connection, app-wide.
          // A write can now legitimately hold a slot for minutes (`commitTimeout` = 600s), where only
          // reads (seconds at most) used to compete for these slots. Split reads and writes onto
          // separate pools/connections if this is ever observed in practice.
          //
          // `.notDispatched` rather than `.connectionLost`: backpressure is not a lost connection,
          // and a WRITE caller can say "this definitely did not run" — the difference between a safe
          // retry and one that double-applies a commit or a push. See `DaemonCommandRunner.neverRan`.
          guard nextStream < UInt32.max, pending.count < 32 else { return (nil, .notDispatched) }
          let stream = nextStream
          nextStream += 1
          pending[stream] = Pending(continuation: continuation, service: service)
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
          // Not sent once its caller has been answered: a request cancelled or timed out while it
          // queued behind another send would have the daemon do the work for nobody, ahead of every
          // request queued after it. A caller told "cancelled" already assumes it may have run
          // (`DaemonCommandRunner`), so not running it is never the worse outcome. Its abandoned
          // entry goes too, since no reply can come.
          let send = lock.withLock { () -> Bool in
            guard !closed else { return false }
            if pending[stream] != nil { return true }
            abandoned.removeValue(forKey: stream)
            return false
          }
          guard send else { return }
          do {
            for payload in Self.payloads(for: bytes, chunked: chunked) {
              try sendOnWrites(
                Self.envelope(service: service, stream: stream, payload: payload),
                stallAfter: timeout / 2)
            }
          } catch {
            fail(error)
          }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
          guard let self else { return }
          // The send timeout is off after the handshake (see `connect`), so a peer that stops
          // reading leaves `send` blocked for good on the serial `writes` queue, and every later
          // write queues behind it. Failing only this stream would leave that connection in use
          // forever; failing the connection shuts the socket down, which unblocks the send, and the
          // next acquisition reconnects. Judged by the send in progress, not by whether this
          // stream's own bytes went out: a request merely queued behind a send that is still
          // making progress (a large chunked exec) is a slow queue, not a wedged transport.
          // ponytail: half the timeout is a heuristic stall bound; a remote host on a slow link
          // might need a per-host floor.
          //
          // Only for a request still pending: one that already completed says nothing about a send
          // some other request has in flight. A request cancelled mid-send is covered by its send's
          // own watchdog (`sendOnWrites`). Monotonic, so a clock change cannot fake a stall.
          let (pending, stalled) = lock.withLock {
            (
              self.pending[stream] != nil,
              self.sendStarted.map { ContinuousClock.now - $0 >= .seconds(timeout / 2) } ?? false
            )
          }
          guard pending else { return }
          if stalled {
            fail(HostConnectionError.connectionLost)
          } else {
            // A deadline, not a lost connection: `connect()` sends `.connectionLost` down the
            // respawn path, which cannot fix a daemon that is alive but not answering.
            timeoutStream(stream, error: HostConnectionError.requestTimedOut)
          }
        }
      }
    } onCancel: {
      cancellation.fire()
    }
  }

  /// `Self.send` on the connection's descriptor, for the `writes` queue only, recording when it
  /// started so a request deadline can tell a stalled send from a slow queue.
  ///
  /// `stallAfter` arms a watchdog on THIS send: still running then, the transport is wedged and the
  /// connection fails. A request's deadline cannot cover it alone — a request cancelled mid-send,
  /// or one whose send only began late in its window, has no deadline left to notice its bytes
  /// stuck.
  private func sendOnWrites(_ data: Data, stallAfter: Double? = nil) throws {
    let count = lock.withLock {
      sendStarted = ContinuousClock.now
      sendCount += 1
      return sendCount
    }
    defer { lock.withLock { sendStarted = nil } }
    if let stallAfter {
      DispatchQueue.global().asyncAfter(deadline: .now() + stallAfter) { [weak self] in
        guard let self, lock.withLock({ self.sendStarted != nil && self.sendCount == count })
        else { return }
        fail(HostConnectionError.connectionLost)
      }
    }
    try Self.send(descriptor, data)
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
          // Stream 0 is the daemon's own: File watch events and, from a daemon before #382, the
          // Status service's verdict changes, never a reply. On the VCS service it has always been a
          // violation and still is.
          // `forward.rs` carries nothing there today and documents a stream-0 envelope as DROPPED,
          // so it is admitted here and dropped by `deliver(forward:)`: a future daemon that adds a
          // stream-0 Forward notification must not fail every shipped client's whole connection.
          // Control on stream 0 is admitted and dropped by `deliver(control:)` for the reason
          // Forward's is: no reply is ever sent there, and a newer daemon that sends something must
          // not fail a shipped client's connection.
          let streamIsValid =
            stream > 0 || service == Self.fileService || service == Self.statusService
            || service == Self.forwardService || service == Self.controlService
            || service == Self.programStatusService
          // Layout replies are JSON chunks like VCS's, never on stream 0 (#255).
          guard
            service == Self.vcsService || service == Self.fileService
              || service == Self.statusService || service == Self.forwardService
              || service == Self.controlService || service == Self.layoutService
              || service == Self.programStatusService, streamIsValid,
            length > 0, length <= 1 << 20
          else {
            throw HostConnectionError.serviceUnavailable("Invalid daemon envelope.")
          }
          guard buffer.count >= 9 + length else { break }
          let payload = Data(buffer.dropFirst(9).prefix(length))
          buffer = Data(buffer.dropFirst(9 + length))
          // A Forward payload is one OPCODE byte then raw connection bytes, NOT a chunk flag then
          // JSON, so it is routed before the chunk guard every other service's payload satisfies.
          // Three of the five opcodes (DATA, EOF, CLOSE) are neither 0 nor 1, so leaving this below
          // the guard would tear the connection down on the first half-close.
          if service == Self.forwardService {
            deliver(forward: payload, stream: stream)
            continue
          }
          // A Control reply is one whole `SessionFrame` with no chunk flag, so it is routed before
          // the chunk guard too.
          if service == Self.controlService {
            deliver(control: payload, stream: stream)
            continue
          }
          guard payload.first == 0 || payload.first == 1 else {
            throw HostConnectionError.serviceUnavailable("Invalid daemon chunk.")
          }
          if stream == 0 {
            // An event is always ONE final envelope; the daemon never chunks one, so a continuation
            // here means the two sides disagree about the protocol.
            guard payload.first == 1 else {
              throw HostConnectionError.serviceUnavailable("Invalid daemon event chunk.")
            }
            // Branched on the SERVICE, not decoded twice: the two events share nothing but their
            // stream, and decoding a verdict change as an `DaemonFileEvent` would fail and drop it
            // silently — a bug every existing test stays green through.
            deliver(event: payload.dropFirst(), service: service)
            continue
          }
          var completed: Pending?
          let valid = lock.withLock {
            if abandoned[stream] != nil {
              // Nobody is waiting on this any more (it timed out) — drain it and never surface it
              // as unexpected, so a slow-but-eventually-answered request never disturbs the
              // connection every OTHER in-flight request is sharing.
              if payload.first == 1 { abandoned.removeValue(forKey: stream) }
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
        lock.withLock { received += UInt64(count) }
        buffer.append(contentsOf: chunk.prefix(count))
      }
    } catch { fail(error) }
  }

  /// Hand one Control reply to the request waiting on its stream.
  ///
  /// The daemon answers a `list` in ONE envelope, so the first one completes the request. A reply for
  /// a stream no Control request is waiting on (it timed out, a VCS or File request holds that
  /// stream, or a newer daemon sent something unasked) is dropped rather than failing the connection,
  /// and never completes another service's request.
  private func deliver(control payload: Data, stream: UInt32) {
    let completed: Pending? = lock.withLock {
      if abandoned[stream] == Self.controlService {
        abandoned.removeValue(forKey: stream)
        return nil
      }
      guard pending[stream]?.service == Self.controlService else { return nil }
      return pending.removeValue(forKey: stream)
    }
    completed?.continuation.resume(returning: payload)
  }

  /// Hand one Forward envelope to the stream it names.
  ///
  /// An envelope for a stream this client has already released — a CLOSE that raced the client's
  /// own, or DATA for a forward that has just ended — is DROPPED, exactly as `forward.rs` drops
  /// client traffic for a stream it has forgotten. Treating it as a protocol violation would fail
  /// the whole connection, taking VCS, File and every other forward down over the normal
  /// shape of a race.
  private func deliver(forward payload: Data, stream: UInt32) {
    guard stream > 0, let opcode = payload.first else { return }
    let handler = lock.withLock { forwardHandlers[stream] }
    // Copied out of the slice: the handler hands the body to a socket write on another queue, and a
    // `Data` slice carries its parent's whole buffer with it.
    handler?(opcode, Data(payload.dropFirst()))
  }

  /// Hand one daemon-initiated event to the subscription it names. An unknown id — an unsubscribe
  /// racing an event already in flight — is dropped: it is the normal shape of that race, not a
  /// protocol violation, and treating it as one would fail every other request on the connection. An
  /// undecodable or unrecognized event is dropped too, for forward compatibility.
  private func deliver(event payload: Data, service: UInt8) {
    // A daemon from before #382 pushes verdicts only to a connection that asked, which this build
    // never does; one that arrives anyway is dropped.
    if service == Self.statusService { return }
    if service == Self.programStatusService {
      deliver(programStatus: payload)
      return
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let wire = try? decoder.decode(DaemonFileEvent.self, from: payload),
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
      abandoned[stream] = entry.service
      return entry.continuation
    }
    continuation?.resume(throwing: error)
  }

  private func fail(_ error: Error) {
    let failed:
      (
        pending: [Pending], watchers: [@Sendable (FileWatchEvent) -> Void],
        forwards: [@Sendable (UInt8, Data) -> Void],
        programStatus: (@Sendable (ProgramStatusEvent) -> Void)?
      )? =
        lock.withLock {
          guard !closed else { return nil }
          closed = true
          let values = Array(pending.values)
          let watchers = Array(watchHandlers.values)
          let forwards = Array(forwardHandlers.values)
          pending.removeAll()
          abandoned.removeAll()
          let programStatus = programStatusHandler
          watchHandlers.removeAll()
          programStatusHandler = nil
          forwardHandlers.removeAll()
          shutdown(descriptor, SHUT_RDWR)
          return (values, watchers, forwards, programStatus)
        }
    guard let failed else { return }
    carrier?.end()
    for operation in failed.pending { operation.continuation.resume(throwing: error) }
    // Outside the lock: a handler is caller code. Every subscription learns its watch is gone, so it
    // can resubscribe on the next generation and refresh whatever it was showing.
    for watcher in failed.watchers { watcher(.lost) }
    failed.programStatus?(.lost)
    // Every live forward hears exactly what the daemon would have said, because it is true: the daemon
    // closes every socket a departing connection opened. Each one closes the socket it owns.
    for forward in failed.forwards { forward(ForwardOpcode.close, Data()) }
    disconnected.finish()
  }
}

public struct DaemonVCSCapabilities: Decodable {
  public let version: Int
  public let reads: Int
  /// The exec service's wire version, or nil on a still-running pre-upgrade daemon that predates the
  /// service entirely.
  ///
  /// Replaces a `writes` COUNT, which counted methods on `LocalVCSWriting` — a protocol that exists
  /// only in this process. workroomd implements one generic exec service and never had eight write
  /// methods to report, so the number described nothing on the answering side and nothing could keep
  /// it true: adding a ninth method here, a change the passthrough fully supports, made the equality
  /// check below fail against a completely capable daemon and silently dropped every user to native
  /// writes with no log line.
  public let exec: Int?

  public init(version: Int, reads: Int, exec: Int?) {
    self.version = version
    self.reads = reads
    self.exec = exec
  }
}

/// `StatRequest` in `vcs.rs`, which rejects unknown fields.
public struct DaemonStatRequest: Encodable, Sendable {
  public var version = 1
  public var kind = "stat"
  public let paths: [String]
  public let read: [String]

  public init(paths: [String], read: [String]) {
    self.paths = paths
    self.read = read
  }
}

public struct DaemonStatReply: Decodable {
  public struct Entry: Decodable {
    public let path: String
    public let exists: Bool
    public let isDir: Bool
    public let modifiedAt: Double?
    public let text: String?

    public init(path: String, exists: Bool, isDir: Bool, modifiedAt: Double?, text: String?) {
      self.path = path
      self.exists = exists
      self.isDir = isDir
      self.modifiedAt = modifiedAt
      self.text = text
    }
  }
  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }
}

public struct DaemonVCSRequest: Encodable, Sendable {
  public var version = 1
  public var root: String?
  // ponytail: `shared_root` and `backend` are jj-era wire fields (#266). The daemon ignores the first
  // and still requires the second ("git") on every read. Prune both with a protocol bump once no
  // supported daemon predates #266.
  public var sharedRoot: String?
  public var backend: String?
  public let method: String
  public var limit: Int?
  public var revision: String?
  public var path: String?
  public var base: String?

  public init(
    root: String? = nil, sharedRoot: String? = nil, backend: String? = nil, method: String,
    limit: Int? = nil, revision: String? = nil, path: String? = nil, base: String? = nil
  ) {
    self.root = root
    self.sharedRoot = sharedRoot
    self.backend = backend
    self.method = method
    self.limit = limit
    self.revision = revision
    self.path = path
    self.base = base
  }
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
