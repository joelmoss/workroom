import Darwin

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
}
