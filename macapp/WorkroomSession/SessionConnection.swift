import Darwin
import WorkroomSessionProtocol

final class SessionConnection {
  let descriptor: Int32
  var decoder = SessionFrameDecoder()
  var attachedSession: SessionIdentifier?
  var closesAfterFlush = false

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
