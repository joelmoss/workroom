import Darwin

public enum SessionReadOutcome {
  case bytes([UInt8])
  case wouldBlock
  case endOfFile
  case failed
}

public enum SessionWriteOutcome: Equatable {
  case wrote(Int)
  case wouldBlock
  case failed
}

/// A byte buffer that drains to a descriptor via a write-then-compact loop — the shared mechanics
/// behind `SessionConnection`'s outbound reply queue and `PTYSession`'s outbound pty input queue.
/// Those were the same shape (append-only buffer, read cursor, threshold-based compaction at
/// 1<<16 bytes) implemented twice, and had already drifted apart on outcome handling. This owns
/// only the mechanics; callers keep their own outcome handling explicit — admission limits on
/// enqueue, whether to clear the buffer on a hard write failure — as caller-side concerns, not a
/// flag on this type.
public struct SessionByteQueue {
  private var buffer: [UInt8] = []
  private var offset = 0

  public init() {}

  public var pendingByteCount: Int { buffer.count - offset }
  public var hasPendingOutput: Bool { pendingByteCount > 0 }

  public mutating func enqueue(_ bytes: [UInt8]) {
    buffer.append(contentsOf: bytes)
  }

  /// Write until the buffer drains, a write would block, or one fails. On drain or wouldBlock the
  /// buffer is left correctly positioned for the next call (fully reset, or compacted once the
  /// consumed prefix crosses the 1<<16 threshold) — `.failed` leaves it untouched; only the caller
  /// knows whether a hard failure means "discard everything" (PTYSession does) or "the whole
  /// connection is about to be torn down anyway" (SessionConnection does).
  @discardableResult
  public mutating func drain(to descriptor: Int32) -> SessionWriteOutcome {
    while offset < buffer.count {
      switch SessionIO.write(descriptor, buffer, from: offset) {
      case .wrote(let count):
        offset += count
      case .wouldBlock:
        compact()
        return .wouldBlock
      case .failed:
        return .failed
      }
    }
    buffer.removeAll(keepingCapacity: true)
    offset = 0
    return .wrote(0)
  }

  /// Discard everything — for a caller that treats a hard write failure as "start clean" rather
  /// than "the buffer's fate no longer matters" (see `drain`'s doc).
  public mutating func clear() {
    buffer.removeAll(keepingCapacity: true)
    offset = 0
  }

  /// Only reachable with `offset < buffer.count` (the `wouldBlock` case above, still inside the
  /// loop) — so `offset == buffer.count` can never happen here; the drained-to-completion path
  /// resets directly in `drain` instead. Compacts once the consumed prefix is large enough to be
  /// worth the `removeFirst` copy, rather than on every partial write.
  private mutating func compact() {
    guard offset >= 1 << 16 else { return }
    buffer.removeFirst(offset)
    offset = 0
  }
}

public enum SessionIO {
  public static let chunkSize = 64 * 1024

  public static func setNonBlocking(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0 else { return }
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
  }

  public static func setCloseOnExec(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFD, 0)
    guard flags >= 0 else { return }
    _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
  }

  public static func read(_ descriptor: Int32, limit: Int = chunkSize) -> SessionReadOutcome {
    var count = 0
    let buffer = [UInt8](unsafeUninitializedCapacity: limit) { pointer, initialized in
      count = Darwin.read(descriptor, pointer.baseAddress, limit)
      initialized = max(count, 0)
    }
    if count > 0 { return .bytes(buffer) }
    if count == 0 { return .endOfFile }
    switch errno {
    case EINTR, EAGAIN:
      return .wouldBlock
    default:
      return .failed
    }
  }

  public static func write(_ descriptor: Int32, _ bytes: [UInt8], from offset: Int)
    -> SessionWriteOutcome
  {
    guard offset < bytes.count else { return .wrote(0) }
    let count = bytes.withUnsafeBytes { pointer -> Int in
      guard let base = pointer.baseAddress else { return -1 }
      return Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
    }
    if count >= 0 { return .wrote(count) }
    switch errno {
    case EINTR, EAGAIN:
      return .wouldBlock
    default:
      return .failed
    }
  }

  @discardableResult
  public static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      switch write(descriptor, bytes, from: offset) {
      case .wrote(let count):
        offset += count
      case .wouldBlock:
        var pollfd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pollfd, 1, 1000)
        if ready < 0, errno != EINTR { return false }
        continue
      case .failed:
        return false
      }
    }
    return true
  }

  public static func close(_ descriptor: Int32) {
    guard descriptor >= 0 else { return }
    _ = Darwin.close(descriptor)
  }
}
