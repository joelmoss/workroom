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

final class PTYSession {
  let identifier: SessionIdentifier
  let processID: pid_t
  let ttyDevice: UInt64
  let workingDirectory: String

  var masterDescriptor: Int32
  var replay: SessionReplayBuffer
  var clientDescriptor: Int32?
  var metadata: [SessionEnvironmentEntry] = []

  private var pendingInput = SessionByteQueue()

  init(
    identifier: SessionIdentifier,
    process: SessionProcess,
    workingDirectory: String,
    replayCapacity: Int
  ) {
    self.identifier = identifier
    processID = process.processID
    ttyDevice = process.ttyDevice
    masterDescriptor = process.masterDescriptor
    self.workingDirectory = workingDirectory
    replay = SessionReplayBuffer(capacity: replayCapacity)
  }

  var hasPendingInput: Bool { pendingInput.hasPendingOutput }

  var descriptor: SessionDescriptor {
    SessionDescriptor(
      identifier: identifier,
      shellProcessID: processID,
      ttyDevice: ttyDevice,
      workingDirectory: workingDirectory,
      isAttached: clientDescriptor != nil,
      metadata: metadata)
  }

  func appendInput(_ bytes: [UInt8], limit: Int) {
    guard pendingInput.pendingByteCount + bytes.count <= limit else {
      SessionLog.write(
        "dropped \(bytes.count) input byte(s): the session is not draining its terminal")
      return
    }
    pendingInput.enqueue(bytes)
  }

  /// A hard write failure clears the pending input outright, unlike `SessionConnection.flush` —
  /// the pty itself (not this session's bookkeeping) is what's in an unknown state, so there's
  /// nothing to usefully retry.
  func flushInput() {
    guard masterDescriptor >= 0 else { return }
    if case .failed = pendingInput.drain(to: masterDescriptor) { pendingInput.clear() }
  }
}
