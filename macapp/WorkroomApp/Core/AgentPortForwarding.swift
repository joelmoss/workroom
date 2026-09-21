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
  /// agent's box.
  func listen(remotePort: UInt16, onError: @escaping @Sendable (String) -> Void) throws
    -> PortForward
  {
    try PortForward(remotePort: remotePort, connection: connection, onError: onError)
  }
}

/// The `open` request, which the agent parses with `deny_unknown_fields` — so these three keys
/// exactly. `host` is always `127.0.0.1`: the agent matches loopback by literal and never resolves,
/// and the app has no reason to ask for `::1` when `localhost` would reach both anyway.
private struct ForwardOpenRequest: Encodable {
  let method = "open"
  let host = "127.0.0.1"
  let port: UInt16
}

/// `{"version":1,"result":{"opened":true}}` or `{"version":1,"error":{"<kind>":"<detail>"}}`.
private struct ForwardReply: Decodable {
  struct Opened: Decodable { let opened: Bool }
  let version: Int
  var result: Opened?
  var error: [String: String]?

  /// The refusal's detail, or nil when the forward opened. An unreadable reply counts as a refusal:
  /// a client that treated it as success would pump bytes into a socket the agent never made.
  static func failure(in body: Data) -> String? {
    guard let reply = try? JSONDecoder().decode(Self.self, from: body), reply.version == 1 else {
      return "The agent sent an unreadable forward reply."
    }
    if let failure = reply.error, let (kind, detail) = failure.first {
      // `connect` details are already the OS's own text ("Connection refused (os error 61)"), which
      // is the useful half; the kind is what distinguishes it from a refusal the agent made itself.
      return kind == "connect" ? detail : "\(kind): \(detail)"
    }
    return reply.result?.opened == true ? nil : "The agent did not open the forward."
  }
}

/// One listener on `127.0.0.1`, forwarding every connection accepted on it to one port on the
/// agent's box over its own multiplex stream.
final class PortForward: @unchecked Sendable {
  let remotePort: UInt16
  /// The ephemeral port the kernel bound. This is the address the user connects to.
  let localPort: UInt16
  private let listener: Int32
  private let connection: AgentVCSConnection
  private let onError: @Sendable (String) -> Void
  private let lock = NSLock()
  private var live: [UUID: ForwardedConnection] = [:]
  private var stopped = false

  init(
    remotePort: UInt16, connection: AgentVCSConnection,
    onError: @escaping @Sendable (String) -> Void
  ) throws {
    self.remotePort = remotePort
    self.connection = connection
    self.onError = onError
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
      guard bound == 0, Darwin.listen(listener, 16) == 0 else {
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        guard let self else {
          if client >= 0 { Darwin.close(client) }
          return
        }
        if client < 0 {
          // What wakes this thread is `stop()` closing the listener, and on Darwin that surfaces as
          // ECONNABORTED — measured, not assumed — which is the SAME errno a peer that resets
          // between SYN and accept produces. So the flag decides whether the loop is over, not the
          // errno: retrying on ECONNABORTED alone would spin forever on a closed descriptor after
          // every removal, and returning on it would end the listener over one cancelled
          // speculative connection.
          if self.lock.withLock({ self.stopped }) { return }
          guard errno == EINTR || errno == ECONNABORTED else { return }
          continue
        }
        self.begin(client)
      }
    }
  }

  deinit { stop() }

  /// Close the listener and every connection still running through it. Each live stream is told
  /// CLOSE, so the agent drops the socket it is holding rather than waiting for the whole multiplex
  /// connection to end.
  func stop() {
    var connections: [ForwardedConnection] = []
    var wasRunning = false
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      wasRunning = true
      connections = Array(live.values)
      live.removeAll()
    }
    guard wasRunning else { return }
    Darwin.close(listener)
    for connection in connections { connection.finish(tellAgent: true) }
  }

  private func begin(_ client: Int32) {
    var enabled: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    let id = UUID()
    let forwarded = ForwardedConnection(
      socket: client, remotePort: remotePort, connection: connection, onError: onError,
      onFinished: { [weak self] in self?.forget(id) })
    var accepted = false
    lock.withLock {
      guard !stopped else { return }
      live[id] = forwarded
      accepted = true
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
private final class ForwardedConnection: @unchecked Sendable {
  private let socket: Int32
  private let remotePort: UInt16
  private let connection: AgentVCSConnection
  private let onError: @Sendable (String) -> Void
  private let onFinished: @Sendable () -> Void
  /// Agent bytes reach the accepted socket HERE, never on the connection's reader thread: writing
  /// straight from `receive()` would stall every VCS, File and Status request sharing that
  /// connection behind one slow local client.
  ///
  /// ponytail: unbounded, the client-side mirror of the agent's `MAX_QUEUED_BYTES` argument — the
  /// multiplex has no per-stream window to credit, so there is nothing to push back with and a local
  /// client that stops reading buffers here. Per-stream flow control is the upgrade path.
  private let writes = DispatchQueue(label: "workroom.agent.forward")
  private let lock = NSLock()
  /// Set before OPEN is sent, so no envelope for this stream can arrive before its handler can name
  /// it. Nil only if the stream could never be reserved.
  private var stream: UInt32?
  private var opened = false
  /// Our read half is done: the local client half-closed and the agent has been told.
  private var sentEOF = false
  /// The agent's read half is done: the remote peer half-closed.
  private var sawEOF = false
  private var finished = false

  /// Well under the 1 MiB - 1 envelope body cap, and the same size `forward.rs` reads with.
  private static let readBuffer = 64 * 1024

  init(
    socket: Int32, remotePort: UInt16, connection: AgentVCSConnection,
    onError: @escaping @Sendable (String) -> Void, onFinished: @escaping @Sendable () -> Void
  ) {
    self.socket = socket
    self.remotePort = remotePort
    self.connection = connection
    self.onError = onError
    self.onFinished = onFinished
  }

  /// Only here, never in `finish`: the reading thread may still be parked in `read` on this
  /// descriptor, and closing it there could hand the number to another thread's socket. `finish`
  /// shuts it down instead, which unblocks the reader without freeing the number — the same
  /// discipline `AgentVCSConnection` keeps for its own.
  deinit { Darwin.close(socket) }

  func start() {
    let id: UInt32
    do {
      id = try connection.reserveForward { [weak self] opcode, body in
        self?.handle(opcode, body)
      }
    } catch {
      onError("\(error)")
      finish(tellAgent: false)
      return
    }
    // The mirror of the agent's own "a CLOSE that lands during a forward's connect must not be
    // lost": `stop()` can finish this connection between the accept and here, and it had no stream
    // to release or close when it did. Nothing has been sent, so there is nothing to tell the agent
    // — the handler is simply given back, and no OPEN is left behind for a forward nobody wants.
    var abandoned = false
    lock.withLock {
      if finished { abandoned = true } else { stream = id }
    }
    if abandoned {
      connection.releaseForward(id)
      return
    }
    guard let request = try? JSONEncoder().encode(ForwardOpenRequest(port: remotePort)) else {
      finish(tellAgent: false)
      return
    }
    connection.sendForward(stream: id, opcode: ForwardOpcode.open, body: request)
    // The agent bounds its own connect at 3s (`CONNECT_TIMEOUT`) and its module doc warns that a
    // client which gives up first leaves the id held. This waits longer than that, and the id is
    // never handed out again either way.
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, self.lock.withLock({ !self.opened && !self.finished }) else { return }
      self.onError("The agent did not answer the forward request.")
      self.finish(tellAgent: true)
    }
  }

  /// One Forward envelope for this stream, on the connection's reader thread. Nothing here blocks.
  private func handle(_ opcode: UInt8, _ body: Data) {
    // Already over — a REPLY that lost the race with the open timeout, or anything at all after a
    // `stop()`. Acting on it would start a reader on a socket that has been shut down and pump
    // bytes onto a stream this client has released.
    guard !lock.withLock({ finished }) else { return }
    switch opcode {
    case ForwardOpcode.reply:
      guard let detail = ForwardReply.failure(in: body) else {
        lock.withLock { opened = true }
        DispatchQueue.global(qos: .userInitiated).async { [self] in pump() }
        return
      }
      onError(detail)
      // The agent sends CLOSE straight after an error reply; releasing the stream here means
      // `receive()` drops it, which is what it does for any stream this client no longer holds.
      finish(tellAgent: false)
    case ForwardOpcode.data:
      guard !body.isEmpty else { return }
      writes.async { [self] in write(body) }
    case ForwardOpcode.eof:
      // The remote peer closed its write half. Queued, not immediate, so it lands AFTER the DATA
      // already waiting — a half-close that overtook the bytes before it would truncate the reply.
      writes.async { [self] in _ = Darwin.shutdown(socket, SHUT_WR) }
      lock.withLock { sawEOF = true }
      finishIfBothHalvesAreDone()
    case ForwardOpcode.close:
      finish(tellAgent: false)
    default:
      // An opcode this build does not know, dropped the way every other unknown agent frame is.
      break
    }
  }

  /// The accepted socket → DATA envelopes, until the local client stops.
  private func pump() {
    var buffer = [UInt8](repeating: 0, count: Self.readBuffer)
    while true {
      let count = buffer.withUnsafeMutableBytes { raw in
        Darwin.read(socket, raw.baseAddress, raw.count)
      }
      if count < 0 && errno == EINTR { continue }
      // A `finish` on another thread shut this socket down to unblock exactly this read, and that
      // reads as a clean EOF. Bailing here is what stops a stray EOF envelope being sent on a stream
      // this client has already released and closed.
      let live: UInt32? = lock.withLock { finished ? nil : stream }
      guard let stream = live else { return }
      if count == 0 {
        // The local client half-closed. EOF, not CLOSE: it may still be reading the reply.
        connection.sendForward(stream: stream, opcode: ForwardOpcode.eof, body: Data())
        lock.withLock { sentEOF = true }
        finishIfBothHalvesAreDone()
        return
      }
      guard count > 0 else {
        // A reset, or the shutdown `finish` performed. Either way the stream is over.
        finish(tellAgent: true)
        return
      }
      connection.sendForward(
        stream: stream, opcode: ForwardOpcode.data, body: Data(buffer[0..<count]))
    }
  }

  private func write(_ body: Data) {
    let delivered = body.withUnsafeBytes { bytes -> Bool in
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.send(
          socket, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        sent += count
      }
      return true
    }
    // The local client is gone mid-transfer: the agent is told so it stops holding a socket whose
    // bytes nobody will read.
    if !delivered { finish(tellAgent: true) }
  }

  private func finishIfBothHalvesAreDone() {
    guard lock.withLock({ sentEOF && sawEOF && !finished }) else { return }
    finish(tellAgent: true)
  }

  /// Idempotent from any thread. `tellAgent` is false only when the agent already knows — it sent
  /// the CLOSE, or refused the open and will send one.
  func finish(tellAgent: Bool) {
    var target: UInt32?
    var alreadyFinished = true
    lock.withLock {
      guard !finished else { return }
      finished = true
      alreadyFinished = false
      target = stream
    }
    guard !alreadyFinished else { return }
    if let target {
      if tellAgent {
        connection.sendForward(stream: target, opcode: ForwardOpcode.close, body: Data())
      }
      connection.releaseForward(target)
    }
    // BOTH halves, now, synchronously — deliberately, and not the obvious alternative.
    //
    // The tempting change is to queue the write half behind whatever DATA is still on `writes`, the
    // way the EOF case queues its own half-close, so a teardown cannot cut a response short. It was
    // tried and rejected on measurement: `shutdown(SHUT_RD)` does NOT unblock a `send` already
    // parked on a full socket buffer, so a queued `SHUT_WR` sitting behind that parked write never
    // runs against a client that has stopped reading. The socket, the descriptor and this object
    // then live forever — a certain leak on the commonest teardown path, traded for a truncation
    // that could not be reproduced: with this shutdown in place, a 1 MB response queued behind it
    // still delivered in full (`testTheResponseSurvivesTheHalfCloseThatEndsTheForward`).
    //
    // What remains is a real but narrow cost, stated rather than hidden: bytes still held by a
    // `send` that is parked at the moment of teardown are lost. That is the same trade `forward.rs`
    // makes when it kills an over-budget forward — a bounded ending beats an unbounded wait.
    //
    // It does not free the descriptor; `deinit` does, once the last thread has let go — see there.
    _ = Darwin.shutdown(socket, SHUT_RDWR)
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

  struct Entry: Identifiable, Equatable {
    let id: UUID
    let remotePort: UInt16
    let localPort: UInt16
    /// The last refusal any connection through this forward hit — `connection refused` and friends.
    /// Kept on the row rather than raised as a toast because it is a property of the forward, and it
    /// arrives when someone connects, not when the forward is added.
    var failure: String?
  }

  @Published private(set) var forwards: [Entry] = []
  /// What went wrong adding one. Cleared by the next attempt.
  @Published private(set) var message: String?
  @Published var draft = ""

  private var listeners: [UUID: PortForward] = [:]
  private var watching = false

  /// Add a forward for `draft`. The listener binds before the entry appears, so a row is only ever
  /// shown for a port that really is reachable at the address it names.
  func add() async {
    message = nil
    guard let remote = UInt16(draft.trimmingCharacters(in: .whitespaces)), remote > 0 else {
      message = "Enter a port between 1 and 65535."
      return
    }
    do {
      let service = try await LocalAgentVCS.shared.forwarding()
      let id = UUID()
      let forward = try service.listen(remotePort: remote) { [weak self] failure in
        Task { @MainActor in self?.record(failure, for: id) }
      }
      listeners[id] = forward
      forwards.append(Entry(id: id, remotePort: remote, localPort: forward.localPort))
      draft = ""
      watchConnection()
    } catch {
      message = "\(error)"
    }
  }

  func remove(_ id: UUID) {
    listeners.removeValue(forKey: id)?.stop()
    forwards.removeAll { $0.id == id }
  }

  private func record(_ failure: String, for id: UUID) {
    guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
    forwards[index].failure = failure
  }

  /// Losing the host connection takes every forward with it: the agent closes the sockets it holds
  /// when the multiplex connection ends, so a listener left bound would accept connections it could
  /// never carry. Started with the first forward, because nothing else in this model cares.
  ///
  /// A GENERATION change counts as a loss even when the status never leaves `.connected`: the
  /// snapshot stream buffers newest-only, so a reconnect can coalesce into one `connected` update
  /// carrying a different lease, and the forwards on the old connection are just as gone.
  private func watchConnection() {
    guard !watching else { return }
    watching = true
    Task { [weak self] in
      var current: HostConnectionManager.Lease?
      // `updates` yields the CURRENT snapshot first, which is the connection the forward that
      // started this watch is running on — a baseline, not a change.
      var started = false
      for await snapshot in await HostConnectionManager.shared.updates(for: .local) {
        let live = snapshot.status == .connected ? snapshot.lease : nil
        let lost = live == nil || (started && live != current)
        if lost { await self?.dropAll() }
        current = live
        // Re-baseline after a loss rather than carrying the dropped lease forward. Without this the
        // NEXT connected snapshot still differs from `current` and drops again — which is harmless
        // while the list is empty and is not harmless against a forward added in between, since
        // `add()` is what brings the new connection up and then appends to that same list.
        started = !lost
      }
    }
  }

  private func dropAll() {
    guard !forwards.isEmpty else { return }
    for listener in listeners.values { listener.stop() }
    listeners.removeAll()
    forwards.removeAll()
    message = "The agent connection ended; forwards were closed."
  }
}
