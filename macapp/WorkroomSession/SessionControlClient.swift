import Darwin
import WorkroomSessionProtocol

/// One-shot control-channel client for list / info / kill over the daemon socket.
enum SessionControlClient {
  static func list(socketPath: String) -> [SessionDescriptor]? {
    transact(socketPath: socketPath, frame: SessionFrame(kind: .list)) { frame in
      guard frame.kind == .sessions else { return nil }
      return try? SessionDescriptor.decodeList(frame.payload)
    }
  }

  static func info(socketPath: String, identifier: SessionIdentifier) -> SessionDescriptor? {
    let request = SessionFrame(
      kind: .info, payload: SessionIdentifierPayload.encode(identifier))
    return transact(socketPath: socketPath, frame: request) { frame in
      guard frame.kind == .sessions,
        let descriptors = try? SessionDescriptor.decodeList(frame.payload)
      else { return nil }
      return descriptors.first
    }
  }

  static func kill(socketPath: String, identifier: SessionIdentifier) -> Bool {
    let request = SessionFrame(
      kind: .kill, payload: SessionIdentifierPayload.encode(identifier))
    return transact(socketPath: socketPath, frame: request) { $0.kind == .acknowledged } ?? false
  }

  static func killAll(socketPath: String) -> Bool {
    transact(socketPath: socketPath, frame: SessionFrame(kind: .killAll)) {
      $0.kind == .acknowledged
    } ?? false
  }

  private static func transact<T>(
    socketPath: String,
    frame: SessionFrame,
    parse: (SessionFrame) -> T?
  ) -> T? {
    guard let descriptor = SessionSocket.connect(path: socketPath) else { return nil }
    defer { SessionIO.close(descriptor) }
    SessionIO.setNonBlocking(descriptor)
    let connection = SessionConnection(descriptor: descriptor)
    connection.enqueue(frame)
    guard connection.flush() else { return nil }

    var deadline = timespec()
    clock_gettime(CLOCK_MONOTONIC, &deadline)
    let timeoutNs: Int64 = 2_000_000_000

    var decoder = SessionFrameDecoder()
    let start = monotonicNanos()
    while monotonicNanos() - start < timeoutNs {
      var pollfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pollfd, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        return nil
      }
      switch SessionIO.read(descriptor) {
      case .bytes(let bytes):
        decoder.push(bytes)
        do {
          if let reply = try decoder.next() { return parse(reply) }
        } catch {
          return nil
        }
      case .wouldBlock:
        continue
      case .endOfFile, .failed:
        return nil
      }
    }
    return nil
  }

  private static func monotonicNanos() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
  }
}
