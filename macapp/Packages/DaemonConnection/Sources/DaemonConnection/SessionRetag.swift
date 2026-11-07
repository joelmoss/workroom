import Foundation
import WorkroomWire

/// The daemon's `Retag` frame: tag a live session with another workroom, for a Quick Terminal pane
/// that moved into one. A Control frame `WorkroomWire` predates, so it is encoded here, as `Signal`
/// is (`RunSignal`).
public enum SessionRetag {
  /// `FrameKind::Retag`.
  public static let frameKind: UInt8 = 0x27

  /// The frame: kind, big-endian payload length, the session's 16 bytes, then the workroom in UTF-8.
  public static func frame(session: UUID, workroom: String) -> [UInt8] {
    controlFrame(kind: frameKind, payload: sessionBytes(session) + Array(workroom.utf8))
  }

  /// How the daemon answered, in one reply frame: true retagged, false refused (no such session, or
  /// a bad request), nil when it is no reply to a retag. Answered as a `Signal` is.
  public static func reply(to frame: SessionFrame) -> Bool? {
    RunSignalReply(frame: frame).map { $0 == .delivered }
  }
}
