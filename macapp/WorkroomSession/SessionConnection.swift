import Darwin
import WorkroomSessionProtocol

/// One socket to a session helper, from the client side.
///
/// `attachedSession` and `closesAfterFlush` used to live here and are gone: both were written and
/// read only by the daemon, which tracked which session a connection was serving and whether to
/// close it once its outbox drained. The attach client has exactly one connection and one session,
/// so it never needed either.
final class SessionConnection {
  let descriptor: Int32
  var decoder = SessionFrameDecoder()

  private var outbox = SessionByteQueue()

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  var pendingByteCount: Int { outbox.pendingByteCount }
  var hasPendingOutput: Bool { outbox.hasPendingOutput }

  func enqueue(_ frame: SessionFrame) {
    outbox.enqueue(frame.encoded())
  }

  /// A hard write failure leaves the outbox untouched — this connection is about to be discarded
  /// entirely by the caller, so there's nothing left to clear it for.
  func flush() -> Bool {
    if case .failed = outbox.drain(to: descriptor) { return false }
    return true
  }
}
