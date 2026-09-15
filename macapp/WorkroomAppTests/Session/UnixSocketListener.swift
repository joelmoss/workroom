import Darwin
import Foundation
import XCTest

/// A bound, listening unix socket that nothing ever services.
///
/// Three session test files needed this and each grew its own copy, which drifted: one forgot
/// `sun_len`, one wrote the path with `copyBytes` and one byte by byte, and each threw its own error
/// domain. They are the same socket, so they are one function now.
///
/// The point of it is the case a client cannot tell apart from a healthy peer without waiting: the
/// `connect` succeeds, so there is something there, and then nothing answers. That is what a wedged
/// helper looks like from the app, and it is what every timeout in the session layer is for.
enum UnixSocketListener {
  /// Returns the listening descriptor; the caller closes it and removes the path.
  static func listen(at socketPath: String, file: StaticString = #filePath, line: UInt = #line)
    throws -> Int32
  {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure.socket(errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(descriptor)
      throw Failure.pathTooLong(socketPath)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self) { destination in
        for (index, byte) in pathBytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
      }
    }
    // BSD sockets carry their own length. macOS tolerates a zero here, but every other consumer of
    // this struct in the tree sets it, and a half-initialized sockaddr is not worth the saving.
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.bind(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
      let reason = errno
      close(descriptor)
      throw Failure.bind(reason)
    }
    return descriptor
  }

  enum Failure: LocalizedError {
    case socket(Int32)
    case pathTooLong(String)
    case bind(Int32)

    var errorDescription: String? {
      switch self {
      case .socket(let code): return "socket() failed: \(code)"
      case .pathTooLong(let path): return "socket path too long for sun_path: \(path)"
      case .bind(let code): return "bind/listen failed: \(code)"
      }
    }
  }
}
