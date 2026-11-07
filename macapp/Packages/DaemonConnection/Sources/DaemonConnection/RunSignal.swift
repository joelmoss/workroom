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
    controlFrame(kind: Self.frameKind, payload: sessionBytes(session) + [rawValue])
  }
}

/// A Control frame `WorkroomWire` predates: kind, big-endian payload length, payload.
func controlFrame(kind: UInt8, payload: [UInt8]) -> [UInt8] {
  let length = UInt32(payload.count)
  return [kind] + [24, 16, 8, 0].map { UInt8((length >> UInt32($0)) & 0xFF) } + payload
}

/// A session id as a frame carries it: its 16 bytes.
func sessionBytes(_ session: UUID) -> [UInt8] {
  withUnsafeBytes(of: session.uuid) { Array($0) }
}

/// How a daemon answered a `Signal` frame.
public enum RunSignalReply: Equatable, Sendable {
  /// The supervisor was sent the signal.
  case delivered
  /// The daemon holds no such session: the run is gone, and starting it again cannot double it.
  case noSuchSession
  /// Refused for another reason (not a run session, an unknown signal), with the daemon's words.
  case refused(String)

  /// The reply one frame carries, or nil when it is not a reply to a signal. A Control envelope's
  /// payload is read with `DaemonControl.firstFrame(of:)`.
  public init?(frame: SessionFrame) {
    switch frame.kind {
    case .acknowledged: self = .delivered
    case .failure:
      let reason = String(decoding: frame.payload, as: UTF8.self)
      self = reason.hasPrefix("no session ") ? .noSuchSession : .refused(reason)
    default: return nil
    }
  }
}
