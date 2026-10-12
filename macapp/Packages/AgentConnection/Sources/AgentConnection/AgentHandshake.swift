import Foundation

/// The greeting `wr-agent` and its clients exchange before any envelope, and the protocol versions
/// that greeting negotiates. Shared by the control-plane client (`AgentControlClient`, in the app)
/// and the service connection (`AgentVCSConnection`); cut out of `AgentControlClient`, whose session
/// plumbing stays in the app.
public enum AgentHandshake {
  /// Matches `PROTOCOL_VERSION` in the agent's `wr_protocol::envelope`. Bumped together. `negotiate`
  /// on the agent side takes the lower of the two sides' versions for Terminal/Control, so
  /// advertising a newer version here never breaks talking to an older agent left running.
  public static let protocolVersion: UInt16 = 7
  /// `MIN_VCS_VERSION` and `MIN_FILE_VERSION` in the agent's `wr_protocol::envelope`: the first peer
  /// versions that understand `Service::Vcs` and `Service::File`. Each is checked against a peer's RAW
  /// greeting version before that service's first envelope — never folded into the negotiated minimum,
  /// which would refuse Terminal traffic to an older agent that is still running someone's shell.
  public static let minVCSVersion: UInt16 = 2
  public static let minFileVersion: UInt16 = 3
  /// `MIN_FORWARD_VERSION`: the first peer version that answers `Service::Forward` (issue #208). A
  /// protocol-4 agent drops a Forward envelope without answering, so it is never sent one.
  public static let minForwardVersion: UInt16 = 5
  /// `MIN_LAYOUT_VERSION`: the first peer version that answers `Service::Layout` (#255). A
  /// protocol-6 agent drops a Layout envelope without answering, so it is never sent one.
  public static let minLayoutVersion: UInt16 = 7
  public static let magic: [UInt8] = Array("WRA1".utf8)

  public static func encodeHello(build: String) -> [UInt8] {
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
  public static func decodeHello(_ bytes: [UInt8]) throws -> (version: UInt16, consumed: Int)? {
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

  public enum AgentProtocolError: Error {
    case notAnAgent
    case versionTooOld(UInt16)
  }
}
