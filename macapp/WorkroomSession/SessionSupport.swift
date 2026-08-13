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
