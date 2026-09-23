import Darwin
import Foundation
import WorkroomSessionProtocol

/// The control-plane client for `wr-agent`, which wraps the same `SessionFrame`s the Swift daemon
/// uses inside a versioned envelope.
///
/// Two differences from `PersistentSessionControlClient`, and only two — the frames and their
/// payloads are identical, which is the point of having the agent emit the descriptor format the
/// app already decodes:
///
/// 1. **A greeting is exchanged first.** Both sides send `Hello` and take the lower protocol
///    version. That is what lets a newer app talk to an agent left running on a machine that has
///    been asleep, rather than replacing it and killing the terminals it is holding.
/// 2. **Every frame travels inside an envelope** carrying a service and a stream id, because one
///    connection will later carry VCS, file and status traffic alongside the terminal.
/// What the app needs from a session helper's control plane, regardless of which one is running.
///
/// Both backends answer with the same `SessionDescriptor` payloads — the agent emits the wire
/// format the app already decodes — so only the framing differs and callers never branch.
protocol SessionControlPlane {
  func list() -> [SessionDescriptor]
  func info(identifier: SessionIdentifier) -> SessionDescriptor?
  /// Whether this helper holds the session, **distinguishing "it said no" from "it never
  /// answered"** — which `info` cannot, because it returns nil for both.
  ///
  /// On the protocol rather than on one client because BOTH helpers create-on-attach: the daemon's
  /// `handleAttach` ends in `create(request:connection:)` and the agent's is guarded only by
  /// `sessions.contains(id)` (`serve.rs`). Asking only the daemon closed the substitution hole on
  /// the backend being retired and left it open on the one that owns every new session.
  func ownership(identifier: SessionIdentifier) -> SessionOwnership
  func kill(identifier: SessionIdentifier) -> Bool
  func killAll() -> Bool
}

extension PersistentSessionControlClient: SessionControlPlane {}

struct AgentControlClient: SessionControlPlane {
  let socketPath: String

  /// Matches `PROTOCOL_VERSION` in the agent's `protocol::envelope`. Bumped together. `negotiate`
  /// on the agent side takes the lower of the two sides' versions for Terminal/Control, so
  /// advertising a newer version here never breaks talking to an older agent left running.
  static let protocolVersion: UInt16 = 4
  /// `MIN_VCS_VERSION` and `MIN_FILE_VERSION` in the agent's `protocol::envelope`: the first peer
  /// versions that understand `Service::Vcs` and `Service::File`. Each is checked against a peer's RAW
  /// greeting version before that service's first envelope — never folded into the negotiated minimum,
  /// which would refuse Terminal traffic to an older agent that is still running someone's shell.
  static let minVCSVersion: UInt16 = 2
  static let minFileVersion: UInt16 = 3
  /// `MIN_STATUS_VERSION`: the first peer version that answers `Service::Status` (issue #208). A
  /// protocol-3 agent drops a Status envelope without answering, so it is never sent one.
  static let minStatusVersion: UInt16 = 4
  static let magic: [UInt8] = Array("WRA1".utf8)

  enum Service: UInt8 {
    case control = 0x00
    case terminal = 0x01
  }

  func list() -> [SessionDescriptor] {
    transact(SessionFrame(kind: .list)) { frame in
      guard frame.kind == .sessions else { return nil }
      return try? SessionDescriptor.decodeList(frame.payload)
    } ?? []
  }

  /// Served by filtering `list()` rather than by its own frame: the agent's session count is the
  /// number of open panes, so the extra work is negligible and it is one less wire case to keep
  /// in step between two languages.
  func info(identifier: SessionIdentifier) -> SessionDescriptor? {
    list().first { $0.identifier == identifier }
  }

  /// `list()` collapses "no reply" into an empty array, which is why this cannot be written on top
  /// of it: an agent that is wedged and an agent holding nothing would be indistinguishable, and
  /// answering `.notOwned` for the first would throw away a live session. Going through `transact`
  /// directly keeps nil meaning "nothing readable came back".
  func ownership(identifier: SessionIdentifier) -> SessionOwnership {
    let sessions = transact(SessionFrame(kind: .list)) { frame -> [SessionDescriptor]? in
      guard frame.kind == .sessions else { return nil }
      return try? SessionDescriptor.decodeList(frame.payload)
    }
    guard let sessions else { return .unreachable }
    return sessions.contains { $0.identifier == identifier } ? .owned : .notOwned
  }

  func kill(identifier: SessionIdentifier) -> Bool {
    transact(
      SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier))
    ) { $0.kind == .acknowledged } ?? false
  }

  func killAll() -> Bool {
    transact(SessionFrame(kind: .killAll)) { $0.kind == .acknowledged } ?? false
  }

  // MARK: - Wire

  static func encodeHello(build: String) -> [UInt8] {
    var bytes = magic
    bytes.append(UInt8(protocolVersion >> 8))
    bytes.append(UInt8(protocolVersion & 0xFF))
    let buildBytes = Array(build.utf8.prefix(255))
    bytes.append(UInt8(buildBytes.count))
    bytes.append(contentsOf: buildBytes)
    return bytes
  }

  /// `nil` means "not enough bytes yet". Throws only when the peer is definitely not an agent, so
  /// a login banner or MOTD on the stream fails immediately rather than hanging until a timeout.
  static func decodeHello(_ bytes: [UInt8]) throws -> (version: UInt16, consumed: Int)? {
    let headerSize = magic.count + 3
    if bytes.count < headerSize {
      let seen = min(bytes.count, magic.count)
      guard Array(bytes.prefix(seen)) == Array(magic.prefix(seen)) else {
        throw AgentProtocolError.notAnAgent
      }
      return nil
    }
    guard Array(bytes.prefix(magic.count)) == magic else { throw AgentProtocolError.notAnAgent }
    let version = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
    let buildLength = Int(bytes[6])
    let end = headerSize + buildLength
    guard bytes.count >= end else { return nil }
    return (version, end)
  }

  static func encodeEnvelope(service: Service, stream: UInt32, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = [service.rawValue]
    for shift in [24, 16, 8, 0] { bytes.append(UInt8((stream >> UInt32(shift)) & 0xFF)) }
    let length = UInt32(payload.count)
    for shift in [24, 16, 8, 0] { bytes.append(UInt8((length >> UInt32(shift)) & 0xFF)) }
    bytes.append(contentsOf: payload)
    return bytes
  }

  static let envelopeHeaderSize = 9

  /// `nil` when the envelope is not yet complete.
  static func decodeEnvelope(_ bytes: [UInt8]) -> (payload: [UInt8], consumed: Int)? {
    guard bytes.count >= envelopeHeaderSize else { return nil }
    var length = 0
    for index in 5..<9 { length = length << 8 | Int(bytes[index]) }
    let end = envelopeHeaderSize + length
    guard bytes.count >= end else { return nil }
    return (Array(bytes[envelopeHeaderSize..<end]), end)
  }

  enum AgentProtocolError: Error {
    case notAnAgent
    case versionTooOld(UInt16)
  }

  private func transact<T>(_ frame: SessionFrame, parse: (SessionFrame) -> T?) -> T? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    // `sun_path` is 104 bytes and must stay NUL-terminated, so the longest usable path is 103.
    // Truncating would connect to a DIFFERENT socket rather than fail, so refuse instead.
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: pathBytes)
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
        Darwin.connect(descriptor, rebound, size)
      }
    }
    guard connected == 0 else { return nil }

    // A short timeout on both directions: this runs on a control path the UI awaits, and an agent
    // that has wedged must not take the Settings pane or the quit alert down with it.
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    guard send(descriptor, Self.encodeHello(build: "Workroom")) else { return nil }

    var buffer: [UInt8] = []
    guard let greeting = readUntil(descriptor, buffer: &buffer, { try Self.decodeHello($0) })
    else { return nil }
    guard greeting.version >= 1 else { return nil }
    buffer.removeFirst(greeting.consumed)

    let envelope = Self.encodeEnvelope(service: .control, stream: 0, payload: frame.encoded())
    guard send(descriptor, envelope) else { return nil }

    // Loop rather than parse once: the agent may send an unrelated envelope first, and a control
    // client that gave up on the first non-matching frame would be racy rather than wrong.
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let decoded = Self.decodeEnvelope(buffer) {
        buffer.removeFirst(decoded.consumed)
        var frames = SessionFrameDecoder()
        frames.push(decoded.payload)
        // `try?` on a throwing function that already returns an Optional flattens to ONE level, so
        // this ends on both "no more frames" and "the decoder failed" — which is what we want:
        // a failed frame decoder is sticky and will never produce another frame.
        while let next = try? frames.next() {
          if let value = parse(next) { return value }
        }
        continue
      }
      guard receive(descriptor, into: &buffer) else { return nil }
    }
    return nil
  }

  private func send(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0
    while sent < bytes.count {
      let written = bytes.withUnsafeBytes { raw -> Int in
        Darwin.send(descriptor, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
      }
      if written <= 0 {
        if errno == EINTR { continue }
        return false
      }
      sent += written
    }
    return true
  }

  private func receive(_ descriptor: Int32, into buffer: inout [UInt8]) -> Bool {
    var chunk = [UInt8](repeating: 0, count: 4096)
    let read = chunk.withUnsafeMutableBytes { raw -> Int in
      Darwin.recv(descriptor, raw.baseAddress!, raw.count, 0)
    }
    if read > 0 {
      buffer.append(contentsOf: chunk[0..<read])
      return true
    }
    if read < 0 && errno == EINTR { return true }
    return false
  }

  /// Reads until `parse` yields a value, the deadline passes, or the peer proves it is not an
  /// agent.
  ///
  /// `do`/`catch` rather than `try?`: the three outcomes are "got it", "need more bytes" and "this
  /// is not an agent", and `try?` collapses the last two into `nil`. Collapsing them would make a
  /// login banner on the stream wait out the full timeout instead of failing at its second byte.
  private func readUntil<T>(
    _ descriptor: Int32, buffer: inout [UInt8], _ parse: ([UInt8]) throws -> T?
  ) -> T? {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      do {
        if let value = try parse(buffer) { return value }
      } catch {
        return nil
      }
      guard receive(descriptor, into: &buffer) else { return nil }
    }
    return nil
  }
}
