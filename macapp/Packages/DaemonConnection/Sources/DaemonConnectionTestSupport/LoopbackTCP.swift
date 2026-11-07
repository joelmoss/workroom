import Darwin
import Foundation

/// A loopback TCP echo server: echoes until its peer half-closes, then half-closes back.
public final class EchoServer: @unchecked Sendable {
  public let port: UInt16
  public let listener: Int32
  private let lock = NSLock()
  private var stopped = false
  private let source: DispatchSourceRead
  private let closed = DispatchSemaphore(value: 0)

  public init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw NSError(domain: "EchoServer", code: Int(errno)) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var reuse: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(listener, 8) == 0,
      fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) == 0
    else {
      Darwin.close(listener)
      throw NSError(domain: "EchoServer", code: Int(errno))
    }
    var actual = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
    }
    self.port = UInt16(bigEndian: actual.sin_port)
    self.listener = listener
    // A read source, as `PortForward` does it, not a blocking `accept` on a thread of its own. A
    // test that stops the server at once could close the listener before that thread reached
    // `accept`, which then accepted on whatever reused the number: the next test's FakeDaemon, whose
    // client got its own hello and request echoed back ("Invalid daemon chunk", Nightly 2026-10-19).
    // The cancel handler runs after any accept in flight, so the number is closed once nothing can
    // reach it.
    // At the QoS of the test thread that waits in `stop()` for its cancel handler.
    let accepts = DispatchQueue(label: "EchoServer.accept", qos: .userInteractive)
    source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: accepts)
    source.setEventHandler {
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        // An accepted socket inherits the listener's `O_NONBLOCK`; the echo below blocks.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        DispatchQueue.global().async {
          var buffer = [UInt8](repeating: 0, count: 64 * 1024)
          while true {
            let count = buffer.withUnsafeMutableBytes {
              Darwin.read(client, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            var written = 0
            while written < count {
              let sent = buffer.withUnsafeBytes {
                Darwin.send(client, $0.baseAddress!.advanced(by: written), count - written, 0)
              }
              if sent <= 0 { break }
              written += sent
            }
            if written < count { break }
          }
          Darwin.shutdown(client, SHUT_WR)
          Darwin.close(client)
        }
      }
    }
    let closed = self.closed
    source.setCancelHandler {
      Darwin.close(listener)
      closed.signal()
    }
    source.activate()
  }

  /// Idempotent, like `TCPClient.close()`. A test that stops its server by hand is stopped again by
  /// `tearDown`, and a second `close` lands on whatever reused the number since. In
  /// `ReverseForwardTests` that was `DaemonHarness`'s `daemon.err` file handle (measured), which
  /// closes the number again when it deallocates, whoever holds it by then. Stray closes like that
  /// are the suspected cause of the guarded-descriptor `EXC_GUARD` kills in later tests.
  public func stop() {
    let already = lock.withLock { () -> Bool in
      if stopped { return true }
      stopped = true
      return false
    }
    guard !already else { return }
    source.cancel()
    // Waited for: callers rely on the port and the number being free once this returns (the
    // dead-port test, and the reuse check in the double-stop test).
    _ = closed.wait(timeout: .now() + 5)
  }
}

/// A loopback TCP client for the tests, with timeouts so a broken forward fails rather than hangs.
public final class TCPClient: @unchecked Sendable {
  private let descriptor: Int32
  private let lock = NSLock()
  private var closed = false

  public init(port: UInt16, receiveBuffer: Int? = nil) throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: "TCPClient", code: Int(errno)) }
    if var receiveBuffer {
      // Before `connect`: the window is negotiated then, and a small one keeps the peer's writes
      // parked instead of absorbed.
      setsockopt(
        descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int>.size))
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      Darwin.close(descriptor)
      throw NSError(domain: "TCPClient", code: Int(errno))
    }
    var enabled: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    self.descriptor = descriptor
  }

  public func write(_ data: Data) throws {
    let delivered = data.withUnsafeBytes { bytes -> Bool in
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.send(
          descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        sent += count
      }
      return true
    }
    guard delivered else { throw NSError(domain: "TCPClient", code: Int(errno)) }
  }

  /// Reads up to `count` bytes, stopping early on EOF — so an empty result means "the peer closed",
  /// which is what most of these assertions are about.
  public func read(_ count: Int, timeout: TimeInterval = 5) throws -> Data {
    var value = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while received.count < count {
      let wanted = min(buffer.count, count - received.count)
      let read = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
      if read < 0 && errno == EINTR { continue }
      guard read > 0 else { break }
      received.append(contentsOf: buffer[0..<read])
    }
    return received
  }

  public func shutdownWrite() { _ = Darwin.shutdown(descriptor, SHUT_WR) }

  public func close() {
    let already = lock.withLock { () -> Bool in
      if closed { return true }
      closed = true
      return false
    }
    guard !already else { return }
    Darwin.close(descriptor)
  }
}
