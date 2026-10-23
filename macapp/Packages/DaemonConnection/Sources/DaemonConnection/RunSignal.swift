import Foundation
import WorkroomWire

/// What the daemon's `Signal` frame asks a run session's supervisor to do (#522), as
/// `wr_protocol::frame::RunSignal` numbers it. A Control frame `WorkroomWire` predates, so it is
/// encoded here, as the hand-off frame is.
public enum RunSignal: UInt8, Sendable {
  /// Stop the command and run it again in place (SIGUSR1).
  case restart = 1
  /// Stop the command and keep the pane (SIGUSR2).
  case stop = 2
  /// Stop the command, then end the session (SIGTERM).
  case quit = 3

  /// `FrameKind::Signal`.
  public static let frameKind: UInt8 = 0x26

  /// The frame: kind, big-endian payload length, the session's 16 bytes, then this signal.
  public func frame(session: UUID) -> [UInt8] {
    var payload = withUnsafeBytes(of: session.uuid) { Array($0) }
    payload.append(rawValue)
    let length = UInt32(payload.count)
    return [Self.frameKind]
      + [24, 16, 8, 0].map { UInt8((length >> UInt32($0)) & 0xFF) } + payload
  }
}

/// How a daemon answered a `Signal` frame.
public enum RunSignalReply: Equatable, Sendable {
  /// The supervisor was sent the signal.
  case delivered
  /// The daemon holds no such session: the run is gone, and starting it again cannot double it.
  case noSuchSession
  /// Refused for another reason (not a run session, an unknown signal), with the daemon's words.
  case refused(String)

  /// The reply in a Control envelope's payload, or nil when it is not a reply to a signal.
  public static func decode(_ payload: [UInt8]) -> RunSignalReply? {
    var frames = SessionFrameDecoder()
    frames.push(payload)
    guard let frame = try? frames.next() else { return nil }
    switch frame.kind {
    case .acknowledged: return .delivered
    case .failure:
      let reason = String(decoding: frame.payload, as: UTF8.self)
      return reason.hasPrefix("no session ") ? .noSuchSession : .refused(reason)
    default: return nil
    }
  }
}
