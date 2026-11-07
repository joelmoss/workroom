import Foundation
import WorkroomWire

/// The daemon's services, as `wr_protocol::envelope::Service` numbers them: the first byte of every
/// envelope.
public enum DaemonService: UInt8, Sendable {
  /// The session list, kill, signal and retag (`DaemonControl`). Its payloads are `SessionFrame`s,
  /// not a chunk flag and JSON.
  case control = 0x00
  case terminal = 0x01
  case vcs = 0x02
  case file = 0x03
  /// Retired (#382) and never asked, but a daemon from before then may still send on it, which is
  /// dropped rather than failing the connection.
  case status = 0x04
  case forward = 0x05
  /// JSON like the others, and chunked like VCS, since a layout can be larger than one envelope
  /// (#255).
  case layout = 0x06
  /// Requests on their own streams, events on stream 0 (#358).
  case programStatus = 0x07
}

/// One envelope: the service byte, the stream and the payload length (both big-endian `UInt32`),
/// then the payload. Every service travels in one, so both of the app's daemon clients frame with
/// this: the blocking control client in the app and `DaemonClient`.
public enum DaemonEnvelope {
  public static let headerSize = 9

  /// What the first `headerSize` bytes say. `service` is the raw byte, since a reader must be able
  /// to see, and refuse, one it does not know.
  public struct Header: Equatable, Sendable {
    public let service: UInt8
    public let stream: UInt32
    public let length: Int

    public init(service: UInt8, stream: UInt32, length: Int) {
      self.service = service
      self.stream = stream
      self.length = length
    }
  }

  public static func encode(service: DaemonService, stream: UInt32, payload: [UInt8]) -> [UInt8] {
    envelope(service: service, stream: stream, payload: payload)
  }

  /// `encode` for a payload that is already `Data`, without copying it through an array first.
  public static func encode(service: DaemonService, stream: UInt32, payload: Data) -> Data {
    envelope(service: service, stream: stream, payload: payload)
  }

  /// The header at the start of `bytes`, or nil until all of it has arrived. The payload length is
  /// read, not checked: what is too long is the reader's call.
  public static func header(of bytes: Data) -> Header? {
    header(of: Array(bytes.prefix(headerSize)))
  }

  /// The first whole envelope in `bytes`, and how many bytes it took; nil while it is incomplete.
  public static func decode(_ bytes: [UInt8]) -> (
    header: Header, payload: [UInt8], consumed: Int
  )? {
    guard let header = header(of: bytes) else { return nil }
    let end = headerSize + header.length
    guard bytes.count >= end else { return nil }
    return (header, Array(bytes[headerSize..<end]), end)
  }

  /// The header, then `payload`, into one buffer sized for both.
  private static func envelope<Bytes: RangeReplaceableCollection>(
    service: DaemonService, stream: UInt32, payload: Bytes
  ) -> Bytes where Bytes.Element == UInt8 {
    var bytes = Bytes()
    bytes.reserveCapacity(headerSize + payload.count)
    bytes.append(service.rawValue)
    withUnsafeBytes(of: stream.bigEndian) { bytes.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { bytes.append(contentsOf: $0) }
    bytes.append(contentsOf: payload)
    return bytes
  }

  private static func header(of bytes: [UInt8]) -> Header? {
    guard bytes.count >= headerSize else { return nil }
    let stream = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let length = bytes[5..<9].reduce(0) { ($0 << 8) | Int($1) }
    return Header(service: bytes[0], stream: stream, length: length)
  }
}

/// The Control service's verbs: the frames a control request carries, and how a reply frame is
/// read. One codec for both clients: this Mac's daemon is asked over a short blocking socket
/// (`DaemonControlClient`, in the app), a remote host's over its `DaemonClient` (`sessions`,
/// `endSession`, `signalSession`).
public enum DaemonControl {
  /// Every session the daemon holds.
  public static func list() -> [UInt8] { SessionFrame(kind: .list).encoded() }

  /// End `identifier`'s session.
  public static func kill(_ identifier: SessionIdentifier) -> [UInt8] {
    SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier)).encoded()
  }

  /// Ask a run session's supervisor to restart, stop or quit (#522).
  public static func signal(_ signal: RunSignal, session: UUID) -> [UInt8] {
    signal.frame(session: session)
  }

  /// Tag `session` with `workroom` from now on.
  public static func retag(session: UUID, workroom: String) -> [UInt8] {
    SessionRetag.frame(session: session, workroom: workroom)
  }

  /// The sessions a reply lists. Throws when the frame is not a session list (a `.failure` carries
  /// the daemon's reason: a list over the frame cap, for one) or its list does not decode.
  public static func sessionList(in frame: SessionFrame) throws -> [SessionDescriptor] {
    guard frame.kind == .sessions else {
      let reason = String(decoding: frame.payload, as: UTF8.self)
      throw HostConnectionError.serviceUnavailable("No session list: \(reason)")
    }
    return try SessionDescriptor.decodeList(frame.payload)
  }

  /// Whether a reply to a kill says the session was ended.
  public static func killed(_ frame: SessionFrame) -> Bool { frame.kind == .acknowledged }

  /// The first frame of a reply's payload: the daemon answers a Control request with one frame in
  /// one envelope. Nil when it is incomplete; throws when it is not a frame.
  public static func firstFrame(of payload: Data) throws -> SessionFrame? {
    var frames = SessionFrameDecoder()
    frames.push(Array(payload))
    return try frames.next()
  }
}
