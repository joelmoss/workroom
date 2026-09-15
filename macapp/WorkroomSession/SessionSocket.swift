import Darwin
import WorkroomSessionProtocol

enum SessionSocket {

  static func connect(path: String, timeoutMilliseconds: Int32 = 1000) -> Int32? {
    guard let address = makeAddress(path: path) else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    SessionIO.setCloseOnExec(descriptor)
    SessionIO.setNonBlocking(descriptor)

    var storage = address
    let connected = withUnsafePointer(to: &storage) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.connect(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected == 0 { return descriptor }
    guard errno == EINPROGRESS else {
      SessionIO.close(descriptor)
      return nil
    }
    var pollfd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&pollfd, 1, timeoutMilliseconds)
    guard ready > 0 else {
      SessionIO.close(descriptor)
      return nil
    }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    let result = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
    guard result == 0, error == 0 else {
      SessionIO.close(descriptor)
      return nil
    }
    return descriptor
  }

  private static func makeAddress(path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        for (index, byte) in bytes.enumerated() {
          destination[index] = CChar(bitPattern: byte)
        }
        destination[bytes.count] = 0
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }
}
