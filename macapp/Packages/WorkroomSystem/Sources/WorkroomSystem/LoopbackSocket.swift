import Darwin
import Foundation

/// A TCP listener on 127.0.0.1, close-on-exec: nothing off this Mac can reach it, and no process
/// this app spawns inherits it. Shared by the port forwards, the credential relay and the container
/// port probe.
public enum LoopbackSocket {
  /// The listening descriptor and the port it was given, or nil with `errno` set (nothing left
  /// open). `port` 0 takes an ephemeral port; any other is that port or nothing (`EADDRINUSE` when
  /// another listener holds it).
  ///
  /// The accept queue is always `SOMAXCONN` (128; the `kern.ipc.somaxconn` sysctl caps what takes
  /// effect). Connections wait there while the owner's accept loop is behind, and on loopback macOS
  /// resets connections once the queue overflows (`ECONNRESET`), measured: new ones and ones
  /// already waiting in it. Short queues reset real clients: the credential relay's 8 (#322) and the
  /// port forwards' 16 under a browser's burst (#328); the sign-in redirect's 4 could the same way.
  /// A connection waiting in the queue holds kernel socket state only, no descriptor of this
  /// process and no owner's slot: each owner still caps what it takes. A burst past the cap is still
  /// reset. A deep queue is also a long line: an owner must not serve it one slow client at a time
  /// (`LoopbackListener.callback` reads them all at once).
  public static func listen(port: UInt16 = 0) -> (descriptor: Int32, port: UInt16)? {
    bindListener(port: port, ipv6: false, reuseAddress: false)
  }

  /// `listen(port:)` on `::1` instead (IPv6 only), for a listener that must also answer what a
  /// browser asking for `localhost` tries first.
  public static func listenIPv6(port: UInt16) -> (descriptor: Int32, port: UInt16)? {
    bindListener(port: port, ipv6: true, reuseAddress: false)
  }

  /// `listen(port:)` (or `listenIPv6(port:)`) for a fixed port, which also takes one that only
  /// finished connections hold. A connection this side closed first sits in `TIME_WAIT` on the port
  /// for about 30 s, measured, and refuses a plain bind: quitting with a browser's connection open
  /// through a forward, then relaunching, would otherwise move the forward to another port.
  /// `SO_REUSEADDR` alone won't do: it also lets the bind in over another process's `0.0.0.0` or
  /// `[::]` listener (measured), whose connections it would then take. So it is used only when
  /// nothing answers on the port (`answers`).
  public static func listen(reclaiming port: UInt16, ipv6: Bool = false) -> (
    descriptor: Int32, port: UInt16
  )? {
    if let made = bindListener(port: port, ipv6: ipv6, reuseAddress: false) { return made }
    guard errno == EADDRINUSE else { return nil }
    guard !answers(port: port, ipv6: ipv6) else {
      errno = EADDRINUSE
      return nil
    }
    return bindListener(port: port, ipv6: ipv6, reuseAddress: true)
  }

  /// Whether something accepts a connection to `port` on 127.0.0.1, or on `::1` with `ipv6`: a
  /// listener there, whatever address it bound (a v4, v6 or dual-stack wildcard included). Only a
  /// refusal says nothing listens; connections in `TIME_WAIT` refuse. A loopback connect is answered
  /// at once, accepted, refused, or reset when the listener's queue is full, which counts as one.
  public static func answers(port: UInt16, ipv6: Bool) -> Bool {
    let descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var noSignal: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var storage = loopbackAddress(port: port, ipv6: ipv6)
    let connected = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t($0.pointee.sa_len)) == 0
      }
    }
    return connected || errno != ECONNREFUSED
  }

  private static func loopbackAddress(port: UInt16, ipv6: Bool) -> sockaddr_storage {
    var storage = sockaddr_storage()
    withUnsafeMutablePointer(to: &storage) { pointer in
      if ipv6 {
        pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          $0.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
          $0.pointee.sin6_family = sa_family_t(AF_INET6)
          $0.pointee.sin6_port = port.bigEndian
          $0.pointee.sin6_addr = in6addr_loopback
        }
      } else {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          $0.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          $0.pointee.sin_family = sa_family_t(AF_INET)
          $0.pointee.sin_port = port.bigEndian
          $0.pointee.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        }
      }
    }
    return storage
  }

  private static func bindListener(port: UInt16, ipv6: Bool, reuseAddress: Bool) -> (
    descriptor: Int32, port: UInt16
  )? {
    let descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    var enabled: Int32 = 1
    if reuseAddress {
      setsockopt(
        descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    // `::1` only: never a dual-stack socket, which would also take IPv4 traffic.
    if ipv6 {
      setsockopt(
        descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    var storage = loopbackAddress(port: port, ipv6: ipv6)
    var length = socklen_t(storage.ss_len)
    let bound = withUnsafeMutablePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, SOMAXCONN) == 0
          && getsockname(descriptor, $0, &length) == 0
      }
    }
    guard bound else {
      let saved = errno
      close(descriptor)
      errno = saved
      return nil
    }
    let bigEndianPort = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
    }
    return (descriptor, UInt16(bigEndian: bigEndianPort))
  }

  /// A blocking TCP connection to `127.0.0.1:<port>`, close-on-exec and `SO_NOSIGPIPE`, or nil
  /// with `errno` set. Bounded by `timeout`, for a listener that never answers. A closed port is
  /// refused at once on loopback. A listener whose accept queue overflows doesn't leave the SYN
  /// unanswered either: macOS resets connections (`ECONNRESET`), measured, both the new one and
  /// ones already waiting in the queue, so a connection made here can still be reset afterwards.
  ///
  /// `SO_NOSIGPIPE` from the start: a write to a peer that has reset would otherwise raise SIGPIPE
  /// and end the process. Set before `connect`, so it holds even for a peer that resets at once,
  /// when setting it afterwards fails (`PortForward.prepare`).
  public static func connect(port: UInt16, timeout: TimeInterval) -> Int32? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let fail = { () -> Int32? in
      let saved = errno
      close(descriptor)
      errno = saved
      return nil
    }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return fail() }
    let flags = fcntl(descriptor, F_GETFL)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return fail() }
    let started = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if started != 0 {
      guard errno == EINPROGRESS else { return fail() }
      var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      // A signal interrupts `poll`; that is not the deadline, so it waits out what is left.
      let deadline = Date().addingTimeInterval(timeout)
      var answered: Int32
      repeat {
        answered = poll(&ready, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000))
      } while answered < 0 && errno == EINTR
      guard answered == 1 else {
        errno = answered == 0 ? ETIMEDOUT : errno
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
