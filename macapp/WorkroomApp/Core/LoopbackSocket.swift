import Darwin
import Foundation

/// An ephemeral TCP listener on 127.0.0.1, close-on-exec: nothing off this Mac can reach it, and no
/// process this app spawns inherits it. Shared by the port forwards and the broker sign-in.
enum LoopbackSocket {
  /// The listening descriptor and the port it was given, or nil with `errno` set (nothing left
  /// open).
  static func listen(backlog: Int32) -> (descriptor: Int32, port: UInt16)? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, backlog) == 0
          && getsockname(descriptor, $0, &length) == 0
      }
    }
    guard bound else {
      let saved = errno
      close(descriptor)
      errno = saved
      return nil
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
  }

  /// A blocking TCP connection to `127.0.0.1:<port>`, close-on-exec, or nil with `errno` set.
  /// Bounded by `timeout`: a closed port is refused at once on loopback, but a listener whose
  /// backlog is full leaves the SYN unanswered, and a plain `connect` would wait for the kernel's
  /// own minute and more.
  static func connect(port: UInt16, timeout: TimeInterval) -> Int32? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(descriptor, F_GETFL)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let fail = { () -> Int32? in
      let saved = errno
      close(descriptor)
      errno = saved
      return nil
    }
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return fail() }
    let started = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if started != 0 {
      guard errno == EINPROGRESS else { return fail() }
      var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      guard poll(&ready, 1, Int32(timeout * 1000)) == 1 else {
        errno = ETIMEDOUT
        return fail()
      }
      var error: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
        errno = error == 0 ? errno : error
        return fail()
      }
    }
    guard fcntl(descriptor, F_SETFL, flags) == 0 else { return fail() }
    return descriptor
  }
}
