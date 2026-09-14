import Darwin
import Foundation
import WorkroomSessionProtocol

/// What a daemon said about a session it was asked to account for.
///
/// Three states rather than a `Bool`, because "the daemon does not hold this" and "the daemon did
/// not answer" demand opposite routing decisions and a `Bool` cannot tell them apart. See
/// `PersistentSessionControlClient.ownership(identifier:)`.
enum SessionOwnership {
  case owned
  case notOwned
  /// No readable reply: unreachable, wedged, timed out, or answering something we cannot parse.
  case unreachable
}

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

  /// Whether the daemon holds this session — **distinguishing "it said no" from "it never
  /// answered"**, which `info` cannot.
  ///
  /// `transact` returns nil for a connect failure, a write failure, an EOF, a 2-second timeout AND
  /// a reply that simply names no session. Folding all of those into "not owned" is what let a
  /// slow daemon route one of its own live sessions to the agent, which creates on first attach —
  /// so the user's running shell was orphaned and the pane showed a fresh one.
  ///
  /// Implemented on top of `transact` unchanged: the closure never returns nil for an answer it
  /// could read, so a nil result can only mean no readable reply arrived. A malformed reply counts
  /// as no reply — a frame we cannot parse is no better evidence than silence.
  func ownership(identifier: SessionIdentifier) -> SessionOwnership {
    let outcome = exchange(
      SessionFrame(kind: .info, payload: SessionIdentifierPayload.encode(identifier))
    ) { frame -> SessionOwnership? in
      guard frame.kind == .sessions,
        let descriptors = try? SessionDescriptor.decodeList(frame.payload)
      else { return nil }
      return descriptors.isEmpty ? .notOwned : .owned
    }
    switch outcome {
    // A failed CONNECT is a definitive "nobody is holding this", not ambiguity — and reading it as
    // ambiguity was a live bug. The daemon installs no SIGTERM handler and unlinks its socket only
    // on the graceful path (`SessionDaemon.swift:167`), so any `pkill` — which is what
    // `make app-run` does — leaves `session.sock` behind. `existingSocketPath` then finds the file
    // and we ask; `connect` gets ECONNREFUSED. Folding that into `unreachable` pinned EVERY
    // session to a daemon that was not running.
    case .noListener: return .notOwned
    case .answered(let ownership): return ownership ?? .unreachable
    case .silent: return .unreachable
    }
  }

  /// What a round trip produced, distinguishing "nobody is listening" from "listening but silent".
  ///
  /// Read by `ownership` alone; `transact` flattens it back to `T?` for the callers that only ever
  /// wanted an answer or nothing. The distinction lives HERE rather than in a second `connect(2)`
  /// from the caller: a probe that opens its own connection first consumes one accept, which is
  /// invisible against the real daemon (it accepts in a loop) and breaks anything that accepts
  /// once — including this project's own test fakes.
  private enum Exchange<T> {
    /// Connected and got a frame. The payload is what `parse` made of it, which may be nil.
    case answered(T?)
    /// `connect(2)` failed: no listener, or a stale socket file.
    case noListener
    /// Connected, then no readable reply before the deadline (or an EOF, or a write failure).
    case silent
  }

  /// The `sockaddr_un` for a path, or nil when the path cannot fit one.
  ///
  /// Shared by `canConnect` and `transact` so the length rule — bytes EXCLUDING the NUL, matching
  /// `SessionSocket.makeAddress` and `PersistentSessionPaths.resolveSocketPath` — is written once.
  /// It was got wrong here before by one byte, which let a 103-byte path attach fine while every
  /// list/kill/cleanup through this client silently failed.
  private static func address(for socketPath: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    guard path.count - 1 < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { dest in
        for (index, byte) in path.enumerated() { dest[index] = byte }
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
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
    if case .answered(let value) = exchange(frame, parse: parse) { return value }
    return nil
  }

  private func exchange<T>(_ frame: SessionFrame, parse: (SessionFrame) -> T?) -> Exchange<T> {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return .silent }
    defer { close(descriptor) }

    guard var address = Self.address(for: socketPath) else { return .noListener }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.connect(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return .noListener }

    var bytes = frame.encoded()
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { pointer -> Int in
        Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      guard written > 0 else { return .silent }
      offset += written
    }

    var decoder = SessionFrameDecoder()
    let deadline = Date().addingTimeInterval(2)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while Date() < deadline {
      var pollfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pollfd, 1, 100)
      // This socket is blocking (never put in non-blocking mode), so `read` MUST be gated on
      // poll actually reporting the descriptor readable — otherwise a wedged or unresponsive
      // daemon on the other end makes `read` block indefinitely, bypassing the 2-second deadline
      // entirely (the deadline is only re-checked BETWEEN iterations, never inside a blocking
      // call). Callers await this from `reap()`, which now gates workroom/project deletion on it
      // completing — a hang here would silently stall deletion forever, not just this one call.
      guard ready > 0, pollfd.revents & Int16(POLLIN) != 0 else { continue }
      let capacity = buffer.count
      let count = buffer.withUnsafeMutableBytes { pointer in
        Darwin.read(descriptor, pointer.baseAddress, capacity)
      }
      if count > 0 {
        decoder.push(Array(buffer.prefix(count)))
        if let reply = try? decoder.next() { return .answered(parse(reply)) }
      } else if count == 0 {
        return .silent
      }
    }
    return .silent
  }
}
