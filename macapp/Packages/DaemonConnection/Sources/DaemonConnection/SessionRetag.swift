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
    let payload = withUnsafeBytes(of: session.uuid) { Array($0) } + Array(workroom.utf8)
    let length = UInt32(payload.count)
    return [frameKind] + [24, 16, 8, 0].map { UInt8((length >> UInt32($0)) & 0xFF) } + payload
  }

  /// How the daemon answered, from a Control envelope's payload: true retagged, false refused (no
  /// such session, or a bad request), nil when it is no reply to a retag.
  public static func decode(_ payload: [UInt8]) -> Bool? {
    var frames = SessionFrameDecoder()
    frames.push(payload)
    guard let frame = try? frames.next() else { return nil }
    switch frame.kind {
    case .acknowledged: return true
    case .failure: return false
    default: return nil
    }
  }
}
