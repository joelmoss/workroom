import Darwin
import WorkroomSessionProtocol

/// The terminal geometry of a descriptor.
///
/// All that survives of `SessionPTY`, which was deleted with the daemon: this is the one thing the
/// attach client needed from it, and the only part that was never about owning a pty. Everything
/// else there — `spawn`, `terminate`, the foreground-pgid and `/proc`-equivalent introspection —
/// existed to RUN sessions, which this build no longer does.
enum SessionTerminalSize {
  static func of(descriptor: Int32) -> (columns: UInt16, rows: UInt16)? {
    var size = winsize()
    guard ioctl(descriptor, TIOCGWINSZ, &size) == 0 else { return nil }
    return (size.ws_col, size.ws_row)
  }
}

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
