import Darwin
import Foundation

/// `Service::Forward` (`0x05`) on a wr-agent connection: a loopback TCP port on the agent's box,
/// reachable at `127.0.0.1:<local port>` on this Mac (issue #208). Everything here is the wire
/// contract of `vcs/crates/wr-agent/src/forward.rs`.
///
/// **A forward only carries while the app is attached.** Every forwarded socket is owned by the
/// multiplex connection that opened it and the agent closes it with that connection, so nothing here
/// is persisted across launches: a forward restored at launch would promise a socket the design
/// cannot keep.
///
/// **The local port is ephemeral.** Forwarding port N binds whatever loopback port the kernel hands
/// out, never N — so forwarding the local box's own port 5173 cannot collide with the dev server
/// already sitting on it. The bound port is what the UI shows and what the user connects to.
///
/// **The listener is reachable by every process and every user account on this Mac.** `127.0.0.1`
/// is not uid-scoped, so a forward grants all of them unauthenticated access to the target — the
/// same property `ssh -L` ships with. Zero amplification while the agent is this same box; at Phase
/// 3 it becomes a real boundary, recorded in `docs/designs/remote-workrooms.md`.
enum ForwardOpcode {
  static let open: UInt8 = 0x01
  static let reply: UInt8 = 0x02
  static let data: UInt8 = 0x03
  static let eof: UInt8 = 0x04
  static let close: UInt8 = 0x05
}

/// The port-forwarding service on one host's connection. Concrete rather than behind a protocol, for
/// the reason `AgentWakefulnessService` is: only a wr-agent has one, and a second implementer would
/// be a second agent.
struct AgentForwardService: Sendable {
  let connection: AgentVCSConnection

  /// Bind a listener on `127.0.0.1` and forward everything accepted on it to `remotePort` on the
  /// agent's box. `openTimeout` is how long one accepted connection waits for the agent's REPLY.
  func listen(
    remotePort: UInt16, openTimeout: TimeInterval = PortForward.openTimeout,
    onEvent: @escaping @Sendable (PortForward.Event) -> Void
  ) throws -> PortForward {
    try PortForward(
      remotePort: remotePort, connection: connection, openTimeout: openTimeout, onEvent: onEvent)
  }
}

/// The `open` request, which the agent parses with `deny_unknown_fields` — so these three keys
/// exactly. `host` is `localhost`, which the agent maps to `127.0.0.1` and `::1` itself and tries in
/// that order under one connect deadline (it never resolves anything): a dev server bound only to
/// `::1` is reachable that way and unreachable by the IPv4 literal, and one on `127.0.0.1` costs
/// nothing extra because it is tried first.
private struct ForwardOpenRequest: Encodable {
  let method = "open"
  let host = "localhost"
  let port: UInt16
}

/// `{"version":1,"result":{"opened":true}}` or `{"version":1,"error":{"<kind>":"<detail>"}}`.
private struct ForwardReply: Decodable {
  struct Opened: Decodable { let opened: Bool }
  let version: Int
  var result: Opened?
  var error: [String: String]?

  /// A REPLY is one small JSON object; anything past this is not one, whatever it decodes as.
  static let maxBody = 4096
  /// The agent abbreviates what it echoes at 256 characters (`forward.rs` `ECHOED_MESSAGE`); this
  /// is the client's own bound, since that one is the agent's promise and not the wire's.
  static let maxText = 200

  /// The refusal's detail, or nil when the forward opened. An unreadable reply counts as a refusal:
  /// a client that treated it as success would pump bytes into a socket the agent never made.
  static func failure(in body: Data) -> String? {
    guard body.count <= maxBody,
      let reply = try? JSONDecoder().decode(Self.self, from: body), reply.version == 1
    else {
      return "The agent sent an unreadable forward reply."
    }
    if let failure = reply.error, let (kind, detail) = failure.first {
      // `connect` details are already the OS's own text ("Connection refused (os error 61)"), which
      // is the useful half; the kind is what distinguishes it from a refusal the agent made itself.
      return kind == "connect"
        ? "Could not connect: \(sanitized(detail))"
        : "\(sanitized(kind)): \(sanitized(detail))"
    }
    return reply.result?.opened == true ? nil : "The agent did not open the forward."
  }

  /// Agent text lands in a one-line caption in the inspector. Control characters (a newline most
  /// of all) and unbounded length are the two ways it can wreck that row.
  static func sanitized(_ text: String) -> String {
    let clean = String(
      String.UnicodeScalarView(
        text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    return clean.count > maxText ? clean.prefix(maxText) + "…" : clean
  }
}

/// One listener on `127.0.0.1`, forwarding every connection accepted on it to one port on the
/// agent's box over its own multiplex stream.
final class PortForward: @unchecked Sendable {
  /// What a forward reports about the connections through it. `opened` clears an earlier failure:
  /// a dev server that was not running when the page first loaded is a fact about then, not about
  /// the forward.
  enum Event: Sendable, Equatable {
    case opened
    case failed(String)
    /// The listener itself is gone. The row must go with it: a row that outlived its listener would
    /// advertise an address that never answers.
    case stopped(String)
  }

  /// The agent bounds its own connect at 3s (`CONNECT_TIMEOUT`) and its module doc warns that a
  /// client which gives up first leaves the id held. This waits longer than that, and the id is
  /// never handed out again either way.
  static let openTimeout: TimeInterval = 5
  /// The agent's `MAX_FORWARDS`: what it holds per multiplex connection before refusing. Mirrored
  /// here per listener so a burst of local connects never sends OPENs the agent will certainly
  /// refuse — each refusal is two more envelopes through the writer VCS, File and Status share.
  static let maxConnections = 64
  /// Out of descriptors: how long the accept queue pauses before the backlog is tried again.
  private static let acceptBackoff: TimeInterval = 0.1

  let remotePort: UInt16
  /// The ephemeral port the kernel bound. This is the address the user connects to.
  let localPort: UInt16
  private let listener: Int32
  private let connection: AgentVCSConnection
  private let openTimeout: TimeInterval
  private let onEvent: @Sendable (Event) -> Void
  private let lock = NSLock()
  private var live: [UUID: ForwardedConnection] = [:]
  private var stopped = false
  /// Accepts are event-driven, not a thread parked in `accept`: the source fires on this serial
  /// queue when the backlog has something, `accept` never blocks (the listener is non-blocking),
  /// and the source's cancel handler is the ONE place the descriptor is closed — after any accept
  /// in flight on this queue has returned, so the number can never be recycled under one. That is
  /// the discipline `ForwardedConnection` keeps for its socket, and it costs no app-wide pool
  /// worker per listener.
  private let accepts = DispatchQueue(label: "workroom.agent.forward.listen")
  private let source: DispatchSourceRead

  init(
    remotePort: UInt16, connection: AgentVCSConnection, openTimeout: TimeInterval,
    onEvent: @escaping @Sendable (Event) -> Void
  ) throws {
    self.remotePort = remotePort
    self.connection = connection
    self.openTimeout = openTimeout
    self.onEvent = onEvent
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else {
      throw HostConnectionError.serviceUnavailable("Could not create a listening socket.")
    }
    do {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      // Port 0 is the ephemeral request, and the address is loopback so nothing off this Mac can
      // reach a forward: the agent's own allowlist is loopback-only and this is its mirror.
      address.sin_port = 0
      address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard bound == 0, Darwin.listen(listener, 16) == 0,
        fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) == 0
      else {
        throw HostConnectionError.serviceUnavailable(
          "Could not listen on a loopback port: \(String(cString: strerror(errno)))")
      }
      var actual = sockaddr_in()
      var size = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
      }
      guard named == 0 else {
        throw HostConnectionError.serviceUnavailable("Could not read the bound port.")
      }
      self.localPort = UInt16(bigEndian: actual.sin_port)
    } catch {
      Darwin.close(listener)
      throw error
    }
    self.listener = listener
    source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: accepts)
    source.setEventHandler { [weak self] in self?.acceptPending() }
    source.setCancelHandler { Darwin.close(listener) }
    source.activate()
  }

  deinit { stop() }

  /// Close the listener and every connection still running through it. Each live stream is told
  /// CLOSE, so the agent drops the socket it is holding rather than waiting for the whole multiplex
  /// connection to end.
  func stop() {
    let connections: [ForwardedConnection]? = lock.withLock {
      guard !stopped else { return nil }
      stopped = true
      let values = Array(live.values)
      live.removeAll()
      return values
    }
    guard let connections else { return }
    source.cancel()
    for connection in connections { connection.finish(tellAgent: true) }
  }

  /// Everything the backlog holds, on the accept queue. A non-blocking `accept` ends with
  /// `EWOULDBLOCK` when it is empty, which is the normal end of one firing, not an error.
  private func acceptPending() {
    while true {
      if lock.withLock({ stopped }) { return }
      let client = accept(listener, nil, nil)
      if client >= 0 {
        begin(client)
        continue
      }
      switch errno {
      case EWOULDBLOCK: return
      case EINTR, ECONNABORTED: continue
      case EMFILE, ENFILE, ENOBUFS, ENOMEM:
        // Out of descriptors, or the kernel is: the connection stays in the backlog, and the
        // source would fire again at once. A short pause on this private queue (nothing else runs
        // on it) turns that spin into a retry, and the listener survives the pressure.
        Thread.sleep(forTimeInterval: Self.acceptBackoff)
        return
      default:
        // The listener itself is broken. Ending here silently would leave a row advertising an
        // address that never answers; the owner is told to take the row down.
        onEvent(.stopped("The listener stopped: \(String(cString: strerror(errno)))"))
        stop()
        return
      }
    }
  }

  private func begin(_ client: Int32) {
    let admitted = lock.withLock { !stopped && live.count < Self.maxConnections }
    guard admitted else {
      // Closed at once, before an OPEN the agent would refuse. A browser sees a reset on its 65th
      // connection and retries; the row says why.
      Darwin.close(client)
      onEvent(.failed("Too many connections through this forward; one was refused."))
      return
    }
    // BSD semantics: an accepted socket inherits the listener's `O_NONBLOCK`, and the pump's
    // blocking `read` is the whole design.
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
    var enabled: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    // What a forward carries is small writes in both directions (chunked HTTP, HMR frames, a wire
    // protocol); Nagle plus delayed ACK on a loopback hop is latency for nothing.
    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    let id = UUID()
    let forwarded = ForwardedConnection(
      socket: client, remotePort: remotePort, connection: connection, openTimeout: openTimeout,
      onEvent: onEvent, onFinished: { [weak self] in self?.forget(id) })
    let accepted = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      live[id] = forwarded
      return true
    }
    // Dropped rather than closed by hand: nothing has been sent for it, and its `deinit` owns the
    // descriptor.
    guard accepted else { return }
    forwarded.start()
  }

  private func forget(_ id: UUID) { lock.withLock { _ = live.removeValue(forKey: id) } }
}

/// One accepted TCP connection, pumped over one multiplex stream.
///
/// The two halves close independently, exactly as `forward.rs` does it: EOF is a half-close and
/// CLOSE ends the whole stream, so CLOSE is sent only once BOTH directions are done — sending it
/// after our own EOF would discard bytes the remote peer was still sending, which is the entire
/// reason the contract has two opcodes.
///
/// **Every envelope this client writes on its stream is enqueued under `lock`, and `finish` enqueues
/// CLOSE under the same lock.** That is what makes CLOSE provably this client's last word on the
/// stream, and OPEN provably absent after it: a `stop()` that lands between the accept and the OPEN
/// used to put `[CLOSE, OPEN]` on the wire, and the agent — which drops a CLOSE for a stream it does
/// not know and then honours the OPEN — held a socket and one of its 64 slots until the whole
/// connection ended. Enqueueing is `writes.async` on the connection, never a socket write, so the
/// lock is never held across I/O.
private final class ForwardedConnection: @unchecked Sendable {
  private let socket: Int32
  private let remotePort: UInt16
  private let connection: AgentVCSConnection
  private let openTimeout: TimeInterval
  private let onEvent: @Sendable (PortForward.Event) -> Void
  private let onFinished: @Sendable () -> Void
  /// Agent bytes reach the accepted socket HERE, never on the connection's reader thread: writing
  /// straight from `receive()` would stall every VCS, File and Status request sharing that
  /// connection behind one slow local client.
  private let writes = DispatchQueue(label: "workroom.agent.forward")
  private let lock = NSLock()
  /// Set before OPEN is sent, so no envelope for this stream can arrive before its handler can name
  /// it. Nil only if the stream could never be reserved.
  private var stream: UInt32?
  private var opened = false
  private var finished = false
  /// A `write` did not deliver: the local client is gone or has stopped reading. Every write still
  /// queued behind it is skipped, so the drain ends at one failure rather than paying `sendTimeout`
  /// per queued envelope — with 32 of them queued that was a quarter of an hour.
  private var deliveryFailed = false
  /// Set by `finish`: the whole drain, not each `send`, ends here. `SO_SNDTIMEO` is a no-progress
  /// bound reset by every partial transfer, so on its own a client trickling one byte at a time
  /// would hold the descriptor for as long as it liked — the same misreading of a per-call bound
  /// as a total budget that `WRITE_TIMEOUT` once suffered on the agent.
  private var drainDeadline: Date?
  /// Agent → client bytes accepted off the reader thread and not yet written to the socket.
  private var queuedToSocket = 0
  /// Client → agent bytes handed to the connection's writer and not yet on the wire. The pump
  /// waits on `credit` while this is over budget, so a stalled agent or a suspended one backs up
  /// the local socket instead of the shared writer every VCS, File and Status request uses.
  private var queuedToAgent = 0
  private let credit = NSCondition()

  /// Well under the 1 MiB - 1 envelope body cap, and the same size `forward.rs` reads with.
  private static let readBuffer = 64 * 1024
  /// The client-side mirror of the agent's `MAX_QUEUED_BYTES` (`forward.rs`): the multiplex has no
  /// per-stream window to credit, so the choice per direction is buffering without limit, blocking
  /// a thread shared with other streams, or ending one stalled connection. Both directions take the
  /// third: agent → client, a local client that has stopped reading is cut off with a reported
  /// reason; client → agent, the pump simply stops reading the socket until the writer catches up,
  /// which is the backpressure TCP then applies to the local client.
  static let queueBudget = 2 * (1 << 20)
  /// The agent's `MESSAGE_OVERHEAD`: what one queued envelope costs beyond its bytes, so a flood of
  /// tiny ones is not free against the budget.
  static let messageOverhead = 64
  /// A `send` parked on a full socket buffer is a local client that has stopped reading. Per call:
  /// what makes a parked `send` return at all, so `write` gets to check `drainDeadline`, which is
  /// the bound on the drain as a whole.
  static let sendTimeout: TimeInterval = 30
  /// How long past `finish` the queued writes may keep draining to a client that is still reading.
  static let drainTimeout: TimeInterval = 30

  init(
    socket: Int32, remotePort: UInt16, connection: AgentVCSConnection, openTimeout: TimeInterval,
    onEvent: @escaping @Sendable (PortForward.Event) -> Void,
    onFinished: @escaping @Sendable () -> Void
  ) {
    self.socket = socket
    self.remotePort = remotePort
    self.connection = connection
    self.openTimeout = openTimeout
    self.onEvent = onEvent
    self.onFinished = onFinished
    var timeout = timeval(
      tv_sec: Int(Self.sendTimeout), tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  /// Only here, never in `finish`: the pump thread may still be parked in `read` on this
  /// descriptor, and closing it there could hand the number to another thread's socket. `finish`
  /// shuts it down instead, which unblocks the reader without freeing the number — the same
  /// discipline `AgentVCSConnection` keeps for its own.
  deinit { Darwin.close(socket) }

  func start() {
    // Encoded before anything is reserved: a refusal here has nothing to release.
    guard let request = try? JSONEncoder().encode(ForwardOpenRequest(port: remotePort)) else {
      onEvent(.failed("Could not encode the forward request."))
      finish(tellAgent: false)
      return
    }
    let id: UInt32
    do {
      id = try connection.reserveForward { [weak self] opcode, body in
        self?.handle(opcode, body)
      }
    } catch {
      onEvent(.failed("\(error)"))
      finish(tellAgent: false)
      return
    }
    // The mirror of the agent's own "a CLOSE that lands during a forward's connect must not be
    // lost": `stop()` can finish this connection between the accept and here, and it had no stream
    // to release or close when it did. Nothing has been sent, so there is nothing to tell the agent
    // — the handler is simply given back, and no OPEN is left behind for a forward nobody wants.
    // The stream is published and the OPEN enqueued under one lock hold, so nothing can finish
    // this connection between the two.
    let abandoned: Bool = lock.withLock {
      if finished { return true }
      stream = id
      // Two clocks. The agent's runs from the moment OPEN is on the wire: behind a busy shared
      // writer that can be seconds after this enqueue, and a timeout measured from here would blame
      // the agent for a delay this client caused. The writer's runs from here, at the send bound:
      // a wedged connection never runs the completion, and without this an accepted socket would
      // wait forever with no reason on the row.
      connection.sendForward(stream: id, opcode: ForwardOpcode.open, body: request) { [weak self] in
        self?.giveUpOnOpen(
          after: self?.openTimeout ?? 0, "The agent did not answer the forward request.")
      }
      giveUpOnOpen(after: Self.sendTimeout, "The agent connection is not sending.")
      return false
    }
    if abandoned { connection.releaseForward(id) }
  }

  private func giveUpOnOpen(after delay: TimeInterval, _ reason: String) {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.lock.withLock({ !self.opened && !self.finished }) else { return }
      self.onEvent(.failed(reason))
      self.finish(tellAgent: true)
    }
  }

  /// One Forward envelope for this stream, on the connection's reader thread. Nothing here blocks.
  private func handle(_ opcode: UInt8, _ body: Data) {
    switch opcode {
    case ForwardOpcode.reply:
      guard let detail = ForwardReply.failure(in: body) else {
        // Exactly one REPLY starts exactly one pump. A second one — a peer that is not the agent
        // this build was written against — must not start a second reader on the same socket,
        // which would interleave the forwarded bytes at arbitrary boundaries.
        let first: Bool = lock.withLock {
          guard !finished, !opened else { return false }
          opened = true
          return true
        }
        guard first else { return }
        onEvent(.opened)
        // A dedicated thread, not a global-queue worker: this parks in `read` for the whole life of
        // the connection (minutes for an idle keep-alive, indefinitely for a websocket), and the
        // global pool it would otherwise hold is the one the connection's own reader and every
        // native VCS read are scheduled on.
        let thread = Thread { [self] in pump() }
        thread.name = "workroom.agent.forward.pump"
        thread.start()
        return
      }
      // A refusal before the pump started. After it, there is no REPLY in the contract: one that
      // arrives anyway is dropped like a second success, not allowed to end a working forward with
      // `tellAgent: false` — which is right only here, where the agent's own CLOSE follows.
      guard lock.withLock({ !finished && !opened }) else { return }
      onEvent(.failed(detail))
      // Releasing the stream here means `receive()` drops that CLOSE, which is what it does for any
      // stream this client no longer holds.
      finish(tellAgent: false)
    case ForwardOpcode.data:
      guard !body.isEmpty else { return }
      let cost = body.count + Self.messageOverhead
      // Admitted and enqueued under one lock hold: `finish` enqueues the half-close under the same
      // lock, so an admitted body can never land behind it and fail.
      let admitted: Bool = lock.withLock {
        guard opened, !finished else { return false }
        queuedToSocket += cost
        guard queuedToSocket <= Self.queueBudget else { return false }
        writes.async { [self] in
          write(body)
          lock.withLock { queuedToSocket -= cost }
        }
        return true
      }
      guard admitted else {
        // Over budget only when the local client has stopped reading: `write` is parked on a full
        // socket buffer and everything behind it is this queue. The agent makes the same call for
        // a client that falls too far behind.
        if lock.withLock({ opened && !finished }) {
          onEvent(.failed("A connection stopped reading and was closed."))
          finish(tellAgent: true)
        }
        return
      }
    case ForwardOpcode.eof:
      // The remote peer closed its write half. Queued, not immediate, so it lands AFTER the DATA
      // already waiting — a half-close that overtook the bytes before it would truncate the reply.
      // Nothing more is done here: once the local client half-closes too, the agent has both halves
      // and sends CLOSE, and the stream ends on that. Sending our own CLOSE at that point would make
      // the agent kill the socket with our last DATA still queued in its writer.
      lock.withLock {
        guard opened, !finished else { return }
        writes.async { [self] in _ = Darwin.shutdown(socket, SHUT_WR) }
      }
    case ForwardOpcode.close:
      finish(tellAgent: false)
    default:
      // An opcode this build does not know, dropped the way every other unknown agent frame is.
      break
    }
  }

  /// The accepted socket → DATA envelopes, until the local client stops. On its own thread.
  private func pump() {
    var buffer = [UInt8](repeating: 0, count: Self.readBuffer)
    while true {
      let count = buffer.withUnsafeMutableBytes { raw in
        Darwin.read(socket, raw.baseAddress, raw.count)
      }
      if count < 0 && errno == EINTR { continue }
      if count == 0 {
        // The local client half-closed — or `finish` shut this socket's read half down to unblock
        // exactly this read, which `send` tells apart: a finished stream takes nothing. EOF, not
        // CLOSE: the client may still be reading the reply, and the CLOSE is the agent's to send
        // once it has both halves.
        _ = send(ForwardOpcode.eof, Data())
        return
      }
      guard count > 0 else {
        // A reset. The stream is over.
        finish(tellAgent: true)
        return
      }
      // Backpressure toward the local client: the read above is not repeated until the writer has
      // put enough of what it was already given on the wire.
      credit.lock()
      while queuedToAgentIsOverBudget() && !isFinished() { credit.wait() }
      credit.unlock()
      let body = Data(buffer[0..<count])
      let cost = body.count + Self.messageOverhead
      // Charged before the enqueue, so a completion can never run ahead of its charge.
      lock.withLock { queuedToAgent += cost }
      guard send(ForwardOpcode.data, body, then: { [weak self] in self?.returnCredit(cost) })
      else {
        lock.withLock { queuedToAgent -= cost }
        return
      }
    }
  }

  private func queuedToAgentIsOverBudget() -> Bool {
    lock.withLock { queuedToAgent > Self.queueBudget }
  }

  private func isFinished() -> Bool { lock.withLock { finished } }

  private func returnCredit(_ count: Int) {
    lock.withLock { queuedToAgent -= count }
    credit.lock()
    credit.broadcast()
    credit.unlock()
  }

  /// Enqueue one envelope on this stream, or refuse it because the stream is finished. Under `lock`
  /// with the `finished` check, so nothing can be enqueued after `finish` enqueued CLOSE.
  private func send(_ opcode: UInt8, _ body: Data, then: (@Sendable () -> Void)? = nil) -> Bool {
    lock.withLock {
      guard !finished, let stream else { return false }
      connection.sendForward(stream: stream, opcode: opcode, body: body, then: then)
      return true
    }
  }

  private func write(_ body: Data) {
    // A write that already failed makes every queued one behind it pointless, and a drain past its
    // deadline is over whatever the client is still doing.
    guard lock.withLock({ !deliveryFailed }) else { return }
    let delivered = body.withUnsafeBytes { bytes -> Bool in
      var sent = 0
      while sent < bytes.count {
        if let deadline = lock.withLock({ drainDeadline }), Date() >= deadline { return false }
        let count = Darwin.send(
          socket, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        sent += count
      }
      return true
    }
    guard !delivered else { return }
    // The local client is gone mid-transfer, has not read for `sendTimeout`, or has outlived the
    // drain: nothing behind this write can arrive either, and the agent is told so it stops holding
    // a socket whose bytes nobody will read.
    lock.withLock { deliveryFailed = true }
    if lock.withLock({ !finished }) {
      onEvent(.failed("A connection stopped reading and was closed."))
    }
    finish(tellAgent: true)
  }

  /// Idempotent from any thread. `tellAgent` is false when the agent already knows — it sent the
  /// CLOSE, or refused the open and will send one — or when no OPEN was ever sent for this stream.
  func finish(tellAgent: Bool) {
    let alreadyFinished: Bool = lock.withLock {
      guard !finished else { return true }
      finished = true
      if let stream {
        if tellAgent {
          connection.sendForward(stream: stream, opcode: ForwardOpcode.close, body: Data())
        }
        connection.releaseForward(stream)
      }
      // The read half now, the write half behind the DATA still queued — enqueued under this lock,
      // as every DATA is, so nothing admitted can land behind it. Shutting both down here at once
      // was measured to lose the response tail: a `stop()` with 1.5 MB of a server's response still
      // queued failed every one of those `send`s with EPIPE, and the local client got a clean EOF
      // after a quarter of it. (The half-close-then-read shape never showed it, and never could on
      // macOS: XNU answers `shutdown(SHUT_RDWR)` with `ENOTCONN` once the peer's FIN has shut the
      // read side, so the old teardown was a no-op exactly where the earlier test looked.)
      // `SHUT_RD` alone unblocks the pump's `read` (it returns 0, and a finished stream sends
      // nothing for it); the queued `SHUT_WR` runs once the writes ahead of it have run, which
      // `drainDeadline` bounds as a whole. The descriptor is freed by `deinit`, once the pump and
      // the last queued write have let go.
      drainDeadline = Date().addingTimeInterval(Self.drainTimeout)
      _ = Darwin.shutdown(socket, SHUT_RD)
      writes.async { [self] in _ = Darwin.shutdown(socket, SHUT_WR) }
      return false
    }
    guard !alreadyFinished else { return }
    // The pump may be parked on the budget; it wakes, sees `finished`, and returns.
    credit.lock()
    credit.broadcast()
    credit.unlock()
    onFinished()
  }
}

/// The forwards the user has asked for on the local box, and the listeners serving them.
///
/// One list, not one per host: only the local host has an agent today, and `wakefulness()` is shared
/// the same way. Forwards are per HOST rather than per workroom, so two workrooms on this box see
/// the same list.
@MainActor
final class PortForwardingModel: ObservableObject {
  static let shared = PortForwardingModel()

  /// How the model reaches the agent, so a test can hand it a scripted agent and a connection
  /// stream it controls — the shape `WakefulnessModel.Transport` set.
  struct Transport {
    /// The service and the lease of the connection it runs on. Never spawns an agent; the reasoning
    /// is on `LocalAgentVCS.forwarding()`, the decision point.
    var forwarding: @Sendable () async throws -> (HostConnectionManager.Lease, AgentForwardService)
    var updates: @Sendable () async -> AsyncStream<HostConnectionManager.Snapshot>

    static let live = Transport(
      forwarding: { try await LocalAgentVCS.shared.forwarding() },
      updates: { await HostConnectionManager.shared.updates(for: .local) })
  }

  struct Entry: Identifiable, Equatable {
    let id: UUID
    let remotePort: UInt16
    let localPort: UInt16
    /// The connection this forward's streams run on. The agent closes every socket a departing
    /// connection opened, so a forward outlives its lease as a listener that accepts connections it
    /// can never carry — which is why a lease that is no longer the connected one drops the row.
    let lease: HostConnectionManager.Lease
    /// The last refusal any connection through this forward hit — `connection refused` and friends.
    /// Kept on the row rather than raised as a toast because it is a property of the forward, and it
    /// arrives when someone connects, not when the forward is added. Cleared by the next connection
    /// that opens.
    var failure: String?
  }

  @Published private(set) var forwards: [Entry] = []
  /// What went wrong adding one, or why the last forwards went away. Cleared by the next attempt.
  @Published private(set) var message: String?
  /// Whether the local agent connection is up, for the row's caption: the controls are useless
  /// without one, and a caption says so before the user finds out from `+`.
  @Published private(set) var connected = false
  @Published var draft = ""

  private let transport: Transport
  private var listeners: [UUID: PortForward] = [:]
  private var watching = false
  private var adding = false
  /// The connected lease as of the last snapshot, and how many snapshots the watch has consumed.
  /// `add()` suspends while the service is acquired; a watch that consumed a disconnect in that
  /// window has nothing to drop yet, and would never see another snapshot to drop it by.
  private var latest: HostConnectionManager.Lease?
  private(set) var snapshotsSeen = 0

  init(transport: Transport = .live) {
    self.transport = transport
  }

  /// Add a forward for `draft`. The listener binds before the entry appears, so a row is only ever
  /// shown for a port that really is reachable at the address it names.
  func add() async {
    // Two clicks in quick succession (or a click and a Return) read the same draft; the second one
    // must not make a second listener for the same port.
    guard !adding else { return }
    adding = true
    defer { adding = false }
    message = nil
    guard let remote = UInt16(draft.trimmingCharacters(in: .whitespaces)), remote > 0 else {
      message = "Enter a port between 1 and 65535."
      return
    }
    do {
      let (lease, service) = try await transport.forwarding()
      let id = UUID()
      let forward = try service.listen(remotePort: remote) { [weak self] event in
        Task { @MainActor in self?.record(event, for: id) }
      }
      listeners[id] = forward
      forwards.append(
        Entry(id: id, remotePort: remote, localPort: forward.localPort, lease: lease))
      draft = ""
      watch()
      // Reconciled against what the watch has already seen, since it will not see it again.
      if snapshotsSeen > 0 { drop { $0.lease != latest } }
    } catch {
      message = Self.describe(error)
    }
  }

  /// The two expected refusals in the words of this row, and never a raw enum case for the rest:
  /// `VCSError` is not `LocalizedError`, so interpolating it prints its Swift case.
  static func describe(_ error: Error) -> String {
    switch error {
    case RepositoryRoutingError.unavailable:
      return "No agent is running on this Mac. Open a workroom to start one."
    case VCSError.backendVersion(let detail):
      return detail
    default:
      return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  func remove(_ id: UUID) {
    listeners.removeValue(forKey: id)?.stop()
    forwards.removeAll { $0.id == id }
  }

  private func record(_ event: PortForward.Event, for id: UUID) {
    guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
    switch event {
    case .opened: forwards[index].failure = nil
    case .failed(let detail): forwards[index].failure = detail
    case .stopped(let detail):
      remove(id)
      message = detail
    }
  }

  /// Follow the host connection: the caption, and the forwards a connection takes with it when it
  /// goes. Each entry carries the lease it was made under, so a snapshot drops exactly the entries
  /// whose connection is not the connected one — a drop, a new generation under a coalesced
  /// `connected` snapshot (the stream buffers newest-only), or a forward that was added against a
  /// connection some other caller had already replaced. Idempotent; the row starts it on appear
  /// and `add()` starts it in case the row never appeared.
  func watch() {
    guard !watching else { return }
    watching = true
    Task { [weak self, transport] in
      for await snapshot in await transport.updates() {
        guard let self else { return }
        let live = snapshot.status == .connected ? snapshot.lease : nil
        latest = live
        snapshotsSeen += 1
        connected = live != nil
        drop { $0.lease != live }
      }
    }
  }

  private func drop(where lost: (Entry) -> Bool) {
    let gone = forwards.filter(lost)
    guard !gone.isEmpty else { return }
    for entry in gone { listeners.removeValue(forKey: entry.id)?.stop() }
    forwards.removeAll(where: lost)
    message = "The agent connection ended; forwards were closed."
  }
}
