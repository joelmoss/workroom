import Darwin

/// Reads one variable from another process's environment, as workroomd does for a daemon-backed
/// pane (`vcs/crates/workroomd/src/terminal/process.rs`). The Quick Terminal's shell is the app's own child,
/// not a daemon session, so it asks here instead (#480's Claude profile).
enum ProcessEnvironment {
  /// `key`'s value in `pid`'s exec-time environment; nil when unset or unreadable (another user's
  /// process, or one that has exited).
  static func value(_ key: String, pid: pid_t) -> String? {
    guard pid > 0, let buffer = procargs2(pid) else { return nil }
    return value(key, inProcargs: buffer)
  }

  /// `key`'s value in a `KERN_PROCARGS2` buffer. Layout: `argc` (Int32), the exec path, NUL
  /// padding, `argc` NUL-terminated argv strings, then the environment as NUL-terminated
  /// `KEY=value` strings with no count of its own; padding after the last one never matches.
  static func value(_ key: String, inProcargs buffer: [UInt8]) -> String? {
    guard buffer.count > 4 else { return nil }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0 else { return nil }
    var offset = 4
    // Skip the exec path, then the NUL padding after it, to land on argv[0].
    while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
    while offset < buffer.count, buffer[offset] == 0 { offset += 1 }
    for _ in 0..<argc where offset < buffer.count {
      while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
      offset += 1
    }
    guard offset < buffer.count else { return nil }
    let prefix = Array(key.utf8) + [UInt8(ascii: "=")]
    for entry in buffer[offset...].split(separator: 0, omittingEmptySubsequences: true)
    where entry.starts(with: prefix) {
      return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
    }
    return nil
  }

  private static func procargs2(_ pid: pid_t) -> [UInt8]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    // Size query first: the buffer is as long as the process's argv and environment.
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return Array(buffer.prefix(size))
  }
}
