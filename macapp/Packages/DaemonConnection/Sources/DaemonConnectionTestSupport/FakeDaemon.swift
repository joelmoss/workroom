import Foundation

/// A stand-in for a pre-File daemon: greets with `version`, answers the VCS `capabilities` probe so
/// `connect()` succeeds, and records the service byte of every envelope it receives.
///
/// `forward: true` answers `Service::Forward` (`0x05`) — **scripted, not socket-backed**: it replies
/// to OPEN, echoes DATA straight back and mirrors EOF, and it records the stream id and opcode of
/// every Forward envelope it receives. The real socket semantics are covered end to end against the
/// shipped binary in `DaemonPortForwardingTests`; this exists for what that structurally cannot show —
/// which opcodes, and which stream ids, the client actually sent. `forwardRefusal` makes every OPEN
/// fail with that `connect` detail instead.
public final class FakeDaemon: @unchecked Sendable {
  public let socketPath: String
  private let listener: Int32
  private let directory: URL
  private let lock = NSLock()
  private var services: [UInt8] = []
  private var clients: [Int32] = []
  private var forwardTraffic: [(stream: UInt32, opcode: UInt8)] = []

  public var receivedServices: [UInt8] { lock.withLock { services } }

  /// Every Forward envelope received, in arrival order.
  public var receivedForwards: [(stream: UInt32, opcode: UInt8)] {
    lock.withLock { forwardTraffic }
  }

  public func forwards(opcode: UInt8) -> [UInt32] {
    receivedForwards.filter { $0.opcode == opcode }.map(\.stream)
  }

  /// Pushes one envelope nobody asked for, to every client.
  public func push(service: UInt8, stream: UInt32, payload: Data) {
    var envelope = Data([service])
    for value in [stream, UInt32(payload.count)] {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
    }
    envelope.append(payload)
    lock.withLock {
      for client in clients {
        _ = envelope.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
      }
    }
  }

  /// The VCS `capabilities` reply body.
  private let capabilities: Data
  /// The `result` of the reply to every exec request, e.g. a successful git; nil leaves them
  /// unanswered.
  private let execResult: String?
  private var execs: [String] = []
  /// The `result` of the reply to every `Service::ProgramStatus` request; nil leaves them unanswered.
  private let programStatusResult: String?
  private var programStatusRequests: [String] = []
  /// Every program-status request received, as the JSON the client sent, in arrival order.
  public var receivedProgramStatusRequests: [String] { lock.withLock { programStatusRequests } }
  /// Every exec request received, as the JSON the client sent, in arrival order.
  public var receivedExecs: [String] { lock.withLock { execs } }
  /// Stop reading the client's socket (without closing it) once `capabilities` is answered.
  private let stallAfterCapabilities: Bool
  private let forward: Bool
  private let forwardRefusal: String?
  private let forwardEpilogue: Int
  /// How many REPLY envelopes answer one OPEN: 0 is a daemon that never answers, 2 is a peer that
  /// is not the daemon this client was written against.
  private let forwardReplies: Int
  /// A REPLY body to send instead of the well-formed one.
  private let forwardReplyBody: Data?
  /// How many OPENs `forwardRefusal` applies to; the rest open. A dev server that came up late.
  private var forwardRefusals: Int
  /// Send the epilogue in answer to the first DATA rather than to EOF: the shape of a server that
  /// answers a request and closes, while the client's write half is still open. That distinction
  /// is load-bearing on macOS — see `testStoppingAForwardDrainsTheResponseAlreadyReceived`.
  private let forwardEpilogueOnData: Bool
  /// Answer the File-service `capabilities` probe `connect()` sends to a protocol-3+ peer. Off, the
  /// probe waits out its whole handshake timeout (2s), which only the tests of that case want.
  private let files: Bool

  public init(
    version: UInt16, forward: Bool = false, forwardRefusal: String? = nil,
    forwardEpilogue: Int = 0, forwardReplies: Int = 1, forwardReplyBody: Data? = nil,
    forwardRefusals: Int = .max, forwardEpilogueOnData: Bool = false,
    capabilities: String = #"{"version":1,"result":{"version":1,"reads":9,"exec":2}}"#,
    stallAfterCapabilities: Bool = false, execResult: String? = nil,
    programStatusResult: String? = nil, files: Bool = true
  ) throws {
    self.programStatusResult = programStatusResult
    self.files = files
    self.capabilities = Data(capabilities.utf8)
    self.execResult = execResult.map { #"{"version":1,"result":\#($0)}"# }
    self.stallAfterCapabilities = stallAfterCapabilities
    self.forward = forward
    self.forwardRefusal = forwardRefusal
    self.forwardEpilogue = forwardEpilogue
    self.forwardReplies = forwardReplies
    self.forwardReplyBody = forwardReplyBody
    self.forwardRefusals = forwardRefusals
    self.forwardEpilogueOnData = forwardEpilogueOnData
    directory = URL(fileURLWithPath: "/tmp/wra-fake-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    socketPath = directory.appendingPathComponent("a.sock").path
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listener, 4) == 0 else {
      throw NSError(domain: "FakeDaemon", code: Int(errno))
    }
    let listenerFD = self.listener
    DispatchQueue.global().async { [weak self] in
      while true {
        let client = accept(listenerFD, nil, nil)
        guard client >= 0 else { return }
        self?.lock.withLock { self?.clients.append(client) }
        DispatchQueue.global().async { [weak self] in self?.serve(client, version: version) }
      }
    }
  }

  public func stop() {
    close(listener)
    lock.withLock { for client in clients { close(client) } }
    try? FileManager.default.removeItem(at: directory)
  }

  private func serve(_ client: Int32, version: UInt16) {
    let magic = Array("WRA1".utf8)
    let hello = magic + [UInt8(version >> 8), UInt8(version & 0xFF), 0]
    guard send(client, hello, hello.count, 0) == hello.count else { return }
    var buffer = Data()
    var greeted = false
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(client, &chunk, chunk.count, 0)
      guard count > 0 else { return }
      buffer.append(contentsOf: chunk.prefix(count))
      if !greeted {
        guard buffer.count >= 7 else { continue }
        let end = 7 + Int(buffer[6])
        guard buffer.count >= end else { continue }
        buffer = Data(buffer.dropFirst(end))
        greeted = true
      }
      while buffer.count >= 9 {
        let bytes = Array(buffer.prefix(9))
        let stream = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let length = bytes[5..<9].reduce(0) { ($0 << 8) | Int($1) }
        guard buffer.count >= 9 + length else { break }
        let payload = Data(buffer.dropFirst(9).prefix(length))
        buffer = Data(buffer.dropFirst(9 + length))
        lock.withLock { services.append(bytes[0]) }
        if bytes[0] == 5 && forward {
          handleForward(client, stream: stream, payload: payload)
          continue
        }
        let request = String(decoding: payload, as: UTF8.self)
        if bytes[0] == 7 {
          lock.withLock { programStatusRequests.append(request) }
          guard let programStatusResult else { continue }
          push(
            service: 7, stream: stream,
            payload: Data([1]) + Data(#"{"version":1,"result":\#(programStatusResult)}"#.utf8))
          continue
        }
        let isFileProbe = bytes[0] == 3 && files && request.contains("capabilities")
        guard bytes[0] == 2 || isFileProbe else { continue }
        let isCapabilities = request.contains("capabilities")
        if !isCapabilities { lock.withLock { execs.append(request) } }
        let body: Data
        if isFileProbe {
          body = Data(
            #"{"version":1,"result":{"version":1,"max_read_bytes":1048576,"max_subscriptions":64}}"#
              .utf8)
        } else if isCapabilities {
          body = capabilities
        } else if let execResult {
          body = Data(execResult.utf8)
        } else {
          continue
        }
        var reply = Data([bytes[0]])
        for value in [stream, UInt32(body.count + 1)] {
          var value = value.bigEndian
          withUnsafeBytes(of: &value) { reply.append(contentsOf: $0) }
        }
        reply.append(1)
        reply.append(body)
        _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        if stallAfterCapabilities && bytes[0] == 2 { return }
      }
    }
  }

  /// The daemon half of `Service::Forward`. A Forward payload is an OPCODE byte then a body, never a
  /// chunk flag then JSON, so it is answered here rather than through the reply builder above.
  private func handleForward(_ client: Int32, stream: UInt32, payload: Data) {
    guard let opcode = payload.first else { return }
    lock.withLock { forwardTraffic.append((stream, opcode)) }
    let body = Data(payload.dropFirst())
    switch opcode {
    case 0x01:  // OPEN
      let refuse = lock.withLock { () -> Bool in
        guard forwardRefusals > 0 else { return false }
        forwardRefusals -= 1
        return true
      }
      if let refusal = forwardRefusal, refuse {
        let error = #"{"version":1,"error":{"connect":"\#(refusal)"}}"#
        sendForward(client, stream: stream, opcode: 0x02, body: Data(error.utf8))
        // A refusal is followed immediately by CLOSE, exactly as `forward.rs` does it.
        sendForward(client, stream: stream, opcode: 0x05, body: Data())
      } else {
        let body = forwardReplyBody ?? Data(#"{"version":1,"result":{"opened":true}}"#.utf8)
        for _ in 0..<forwardReplies {
          sendForward(client, stream: stream, opcode: 0x02, body: body)
        }
      }
    case 0x03 where forwardEpilogueOnData:  // DATA — answered like a server that then closes
      sendEpilogue(client, stream: stream)
    case 0x03:  // DATA — echoed, so a round trip needs no socket on this side
      sendForward(client, stream: stream, opcode: 0x03, body: body)
    case 0x04 where forwardEpilogueOnData:
      // The response already went out; with the client's EOF the daemon has both halves, and CLOSE
      // is its last word.
      sendForward(client, stream: stream, opcode: 0x05, body: Data())
    case 0x04:  // EOF
      // With an epilogue, this is the shape a request/response server has: the request body ends,
      // the whole response goes out, and the peer half-closes immediately behind it. DATA and EOF
      // land back to back on the client's reader thread, and CLOSE behind them: both halves are
      // done on the daemon's side, so it sends its last word.
      sendEpilogue(client, stream: stream)
      sendForward(client, stream: stream, opcode: 0x05, body: Data())
    default:
      break  // CLOSE is recorded and needs no answer.
    }
  }

  /// Chunked at 64 KiB, the real daemon's read size (`forward.rs` `READ_BUFFER`): one envelope per
  /// chunk means one queued socket write per chunk on the client, and a teardown that lands between
  /// two of them is the truncation. A single envelope would hide it.
  private func sendEpilogue(_ client: Int32, stream: UInt32) {
    var sent = 0
    while sent < forwardEpilogue {
      let count = min(64 * 1024, forwardEpilogue - sent)
      sendForward(client, stream: stream, opcode: 0x03, body: Data(repeating: 0xAB, count: count))
      sent += count
    }
    sendForward(client, stream: stream, opcode: 0x04, body: Data())
  }

  /// An unsolicited Forward envelope to every connected client — what a future daemon's stream-0
  /// notification, or a misbehaving peer's stray frame, looks like on the wire.
  public func pushForward(stream: UInt32, opcode: UInt8, body: Data = Data()) {
    let clients = lock.withLock { self.clients }
    for client in clients { sendForward(client, stream: stream, opcode: opcode, body: body) }
  }

  /// Deliberately takes no lock: it is called from the per-client serve thread with that client's
  /// descriptor in hand, and `handleForward` is already holding nothing.
  private func sendForward(_ client: Int32, stream: UInt32, opcode: UInt8, body: Data) {
    var envelope = Data([5])
    for value in [stream, UInt32(body.count + 1)] {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
    }
    envelope.append(opcode)
    envelope.append(body)
    _ = envelope.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
  }
}
