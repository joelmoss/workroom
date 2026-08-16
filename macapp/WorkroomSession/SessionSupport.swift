import Darwin

/// Monotonic clock, unaffected by wall-clock jumps (NTP, user changing the date) — used for
/// short-lived deadlines (poll timeouts, settle windows) where a `Date()`-based one could stall
/// or fire early.
enum SessionClock {
  static func monotonicSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
  }
}

enum SessionReadOutcome {
  case bytes([UInt8])
  case wouldBlock
  case endOfFile
  case failed
}

enum SessionWriteOutcome {
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
struct SessionByteQueue {
  private var buffer: [UInt8] = []
  private var offset = 0

  var pendingByteCount: Int { buffer.count - offset }
  var hasPendingOutput: Bool { pendingByteCount > 0 }

  mutating func enqueue(_ bytes: [UInt8]) {
    buffer.append(contentsOf: bytes)
  }

  /// Write until the buffer drains, a write would block, or one fails. On drain or wouldBlock the
  /// buffer is left correctly positioned for the next call (fully reset, or compacted once the
  /// consumed prefix crosses the 1<<16 threshold) — `.failed` leaves it untouched; only the caller
  /// knows whether a hard failure means "discard everything" (PTYSession does) or "the whole
  /// connection is about to be torn down anyway" (SessionConnection does).
  @discardableResult
  mutating func drain(to descriptor: Int32) -> SessionWriteOutcome {
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
  mutating func clear() {
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

enum SessionIO {
  static let chunkSize = 64 * 1024

  static func setNonBlocking(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0 else { return }
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
  }

  static func setCloseOnExec(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFD, 0)
    guard flags >= 0 else { return }
    _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
  }

  static func read(_ descriptor: Int32, limit: Int = chunkSize) -> SessionReadOutcome {
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

  static func write(_ descriptor: Int32, _ bytes: [UInt8], from offset: Int) -> SessionWriteOutcome
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
  static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
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

  static func close(_ descriptor: Int32) {
    guard descriptor >= 0 else { return }
    _ = Darwin.close(descriptor)
  }
}

final class SessionSignalPipe {
  nonisolated(unsafe) private static var writeDescriptor: Int32 = -1

  let readDescriptor: Int32

  init?(signals: [Int32]) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { return nil }
    readDescriptor = descriptors[0]
    Self.writeDescriptor = descriptors[1]
    SessionIO.setNonBlocking(readDescriptor)
    SessionIO.setNonBlocking(Self.writeDescriptor)
    SessionIO.setCloseOnExec(readDescriptor)
    SessionIO.setCloseOnExec(Self.writeDescriptor)
    for number in signals {
      signal(number) { _ in
        let saved = errno
        var token: UInt8 = 1
        _ = Darwin.write(SessionSignalPipe.writeDescriptor, &token, 1)
        errno = saved
      }
    }
  }

  func drain() {
    while case .bytes = SessionIO.read(readDescriptor, limit: 64) {}
  }
}

final class SessionCStringArray {
  private let storage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let count: Int

  init(_ values: [String]) {
    count = values.count
    storage = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
    for (index, value) in values.enumerated() {
      storage[index] = strdup(value)
    }
    storage[count] = nil
  }

  var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> { storage }

  deinit {
    for index in 0..<count { free(storage[index]) }
    storage.deallocate()
  }
}

enum SessionLog {
  static func write(_ message: String) {
    SessionIO.writeAll(STDERR_FILENO, Array((message + "\n").utf8))
  }
}

enum SessionProcessEnvironment {
  static func current() -> [(key: String, value: String)] {
    var result: [(key: String, value: String)] = []
    var cursor = environ
    while let entry = cursor.pointee {
      let text = String(cString: entry)
      if let separator = text.firstIndex(of: "=") {
        let key = String(text[text.startIndex..<separator])
        let value = String(text[text.index(after: separator)...])
        result.append((key: key, value: value))
      }
      cursor = cursor.advanced(by: 1)
    }
    return result
  }

  static func value(_ key: String) -> String? {
    guard let raw = getenv(key) else { return nil }
    let value = String(cString: raw)
    return value.isEmpty ? nil : value
  }
}
