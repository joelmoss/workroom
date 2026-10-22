import Foundation

/// A held `MAX_FORWARDS` slot on one daemon connection; dropping it gives the slot back.
public final class ForwardSlot: @unchecked Sendable {
  /// The daemon's `MAX_FORWARDS`: what it holds per multiplex connection before refusing. Mirrored
  /// on the connection (`DaemonVCSConnection.reserveForwardSlot`), across every listener on it, so a
  /// burst of local connects never sends OPENs the daemon will certainly refuse — each refusal is
  /// two more envelopes through the writer VCS and File share.
  public static let maxPerConnection = 64

  private let release: @Sendable () -> Void
  public init(release: @escaping @Sendable () -> Void) { self.release = release }
  deinit { release() }
}
