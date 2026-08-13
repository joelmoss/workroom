import Darwin
import Foundation
import WorkroomSessionProtocol

/// One-shot list/info/kill client for the session daemon. Used by the app; the helper
/// binary has its own copy for `workroom-session list` / `kill`.
struct PersistentSessionControlClient {
  let socketPath: String

  func list() -> [SessionDescriptor] {
    transact(SessionFrame(kind: .list)) { frame in
      guard frame.kind == .sessions else { return nil }
      return try? SessionDescriptor.decodeList(frame.payload)
    } ?? []
  }

  func info(identifier: SessionIdentifier) -> SessionDescriptor? {
    transact(
      SessionFrame(kind: .info, payload: SessionIdentifierPayload.encode(identifier))
    ) { frame in
      guard frame.kind == .sessions,
        let descriptors = try? SessionDescriptor.decodeList(frame.payload)
      else { return nil }
      return descriptors.first
    }
  }

  func kill(identifier: SessionIdentifier) -> Bool {
    transact(
      SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier))
    ) { $0.kind == .acknowledged } ?? false
  }

  func killAll() -> Bool {
    transact(SessionFrame(kind: .killAll)) { $0.kind == .acknowledged } ?? false
  }

  private func transact<T>(_ frame: SessionFrame, parse: (SessionFrame) -> T?) -> T? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { dest in
        for (index, byte) in path.enumerated() { dest[index] = byte }
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.connect(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return nil }

    var bytes = frame.encoded()
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { pointer -> Int in
        Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      guard written > 0 else { return nil }
      offset += written
    }

    var decoder = SessionFrameDecoder()
    let deadline = Date().addingTimeInterval(2)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while Date() < deadline {
      var pollfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      _ = poll(&pollfd, 1, 100)
      let capacity = buffer.count
      let count = buffer.withUnsafeMutableBytes { pointer in
        Darwin.read(descriptor, pointer.baseAddress, capacity)
      }
      if count > 0 {
        decoder.push(Array(buffer.prefix(count)))
        if let reply = try? decoder.next() { return parse(reply) }
      } else if count == 0 {
        return nil
      }
    }
    return nil
  }
}
