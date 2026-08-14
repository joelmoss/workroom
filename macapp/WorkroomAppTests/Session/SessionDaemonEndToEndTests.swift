import Darwin
import XCTest

@testable import WorkroomSessionProtocol

final class SessionDaemonEndToEndTests: XCTestCase {
  func testAttachListKillAndReplay() throws {
    let harness = try SessionDaemonHarness.start()
    defer { harness.stop() }

    let identifier = SessionIdentifier(UUID())
    var client = try SessionTestClient.connect(socketPath: harness.socketPath)
    let attach = SessionAttachRequest(
      identifier: identifier,
      columns: 80,
      rows: 24,
      workingDirectory: FileManager.default.temporaryDirectory.path,
      command: "/bin/sh -c 'printf ready; exec cat'",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [
        SessionEnvironmentEntry(key: "TERM", value: "dumb"),
        SessionEnvironmentEntry(key: "PATH", value: "/bin:/usr/bin"),
      ],
      metadata: [SessionEnvironmentEntry(key: SessionMetadataKey.title, value: "e2e")])
    try client.send(SessionFrame(kind: .attach, payload: attach.encoded()))
    let attached = try client.wait(for: .attached, timeout: 3)
    let accepted = try SessionAttachAccepted.decode(attached.payload)
    XCTAssertTrue(accepted.created)
    XCTAssertGreaterThan(accepted.shellProcessID, 1)

    let ready = try client.wait(for: .output, timeout: 3)
    XCTAssertTrue(String(bytes: ready.payload, encoding: .utf8)?.contains("ready") == true)

    try client.send(SessionFrame(kind: .input, payload: Array("hello\n".utf8)))
    let echoed = try client.wait(for: .output, timeout: 3)
    XCTAssertTrue(String(bytes: echoed.payload, encoding: .utf8)?.contains("hello") == true)

    client.closeConnection()

    var lister = try SessionTestClient.connect(socketPath: harness.socketPath)
    try lister.send(SessionFrame(kind: .list))
    let listed = try lister.wait(for: .sessions, timeout: 2)
    let descriptors = try SessionDescriptor.decodeList(listed.payload)
    XCTAssertEqual(descriptors.count, 1)
    XCTAssertEqual(descriptors[0].identifier, identifier)
    XCTAssertFalse(descriptors[0].isAttached)
    lister.closeConnection()

    var reattach = try SessionTestClient.connect(socketPath: harness.socketPath)
    try reattach.send(SessionFrame(kind: .attach, payload: attach.encoded()))
    let reattached = try reattach.wait(for: .attached, timeout: 3)
    XCTAssertFalse(try SessionAttachAccepted.decode(reattached.payload).created)
    let replay = try reattach.wait(for: .output, timeout: 3)
    let replayText = String(bytes: replay.payload, encoding: .utf8) ?? ""
    XCTAssertTrue(replayText.contains("ready") || replayText.contains("hello"), replayText)
    reattach.closeConnection()

    var killer = try SessionTestClient.connect(socketPath: harness.socketPath)
    try killer.send(
      SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier)))
    let ack = try killer.wait(for: .acknowledged, timeout: 3)
    XCTAssertEqual(ack.kind, .acknowledged)
    killer.closeConnection()

    var empty = try SessionTestClient.connect(socketPath: harness.socketPath)
    try empty.send(SessionFrame(kind: .list))
    let after = try SessionDescriptor.decodeList(try empty.wait(for: .sessions, timeout: 2).payload)
    XCTAssertTrue(after.isEmpty)
    empty.closeConnection()
  }

  /// Regression test for the "ack before execve" finding: `forkpty` returning a pid only proves
  /// `fork` succeeded, not that the child ever reached its shell. A nonexistent `shell` path makes
  /// our own `execve` fail deterministically, and the daemon must report that as a `.failure`
  /// up front rather than acking `.attached` and then closing moments later.
  func testExecFailureReportsFailureNotSilentExit() throws {
    let harness = try SessionDaemonHarness.start()
    defer { harness.stop() }

    let identifier = SessionIdentifier(UUID())
    var client = try SessionTestClient.connect(socketPath: harness.socketPath)
    let attach = SessionAttachRequest(
      identifier: identifier,
      columns: 80,
      rows: 24,
      workingDirectory: FileManager.default.temporaryDirectory.path,
      command: "",
      shell: "/definitely/does-not-exist-\(UUID().uuidString)",
      resourcesDirectory: "",
      environment: [
        SessionEnvironmentEntry(key: "TERM", value: "dumb"),
        SessionEnvironmentEntry(key: "PATH", value: "/bin:/usr/bin"),
      ])
    try client.send(SessionFrame(kind: .attach, payload: attach.encoded()))
    let failure = try client.wait(for: .failure, timeout: 3)
    let message = try SessionTextPayload.decode(failure.payload)
    XCTAssertTrue(message.contains("failed to start"), message)
    client.closeConnection()
  }

  /// Regression test for the "no reply-queue bound" finding: a same-UID client that keeps sending
  /// requests without ever reading its socket must not be able to grow the daemon's memory without
  /// bound. Every `list` reply here is large (the session's metadata carries a bulky title), so a
  /// handful of un-drained replies is enough to cross `connectionOutboxLimit`; the daemon should
  /// drop the misbehaving connection rather than keep queuing.
  func testMisbehavingClientReplyQueueIsCapped() throws {
    signal(SIGPIPE, SIG_IGN)
    let harness = try SessionDaemonHarness.start()
    defer { harness.stop() }

    let identifier = SessionIdentifier(UUID())
    var client = try SessionTestClient.connect(socketPath: harness.socketPath)
    let bulkyTitle = String(repeating: "x", count: 200_000)
    let attach = SessionAttachRequest(
      identifier: identifier,
      columns: 80,
      rows: 24,
      workingDirectory: FileManager.default.temporaryDirectory.path,
      command: "/bin/sh -c 'exec cat'",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [
        SessionEnvironmentEntry(key: "TERM", value: "dumb"),
        SessionEnvironmentEntry(key: "PATH", value: "/bin:/usr/bin"),
      ],
      metadata: [SessionEnvironmentEntry(key: SessionMetadataKey.title, value: bulkyTitle)])
    try client.send(SessionFrame(kind: .attach, payload: attach.encoded()))
    _ = try client.wait(for: .attached, timeout: 3)

    // Each `list` request is a handful of bytes, so a tight send loop races ahead of the daemon's
    // poll loop without ever giving it a scheduling slice to read the requests, generate the
    // (large) replies, and notice its outbox has grown past the cap. Spread the sends out instead.
    var closed = false
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      do {
        try client.send(SessionFrame(kind: .list))
      } catch {
        closed = true
        break
      }
      usleep(2000)
    }
    XCTAssertTrue(closed, "daemon should drop a connection whose reply queue grows without bound")
    client.closeConnection()
  }

  func testVersionMismatchIsRefused() throws {
    let harness = try SessionDaemonHarness.start()
    defer { harness.stop() }

    var client = try SessionTestClient.connect(socketPath: harness.socketPath)
    let identifier = SessionIdentifier(UUID())
    let request = SessionAttachRequest(
      version: SessionProtocolVersion.current + 1,
      identifier: identifier,
      columns: 80,
      rows: 24,
      workingDirectory: "/",
      command: "",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [])
    try client.send(SessionFrame(kind: .attach, payload: request.encoded()))
    let failure = try client.wait(for: .failure, timeout: 2)
    let message = try SessionTextPayload.decode(failure.payload)
    XCTAssertTrue(message.contains("different version"), message)
    client.closeConnection()
  }
}

/// Minimal unix-socket client for protocol tests.
private struct SessionTestClient {
  let descriptor: Int32
  var decoder = SessionFrameDecoder()

  static func connect(socketPath: String) throws -> SessionTestClient {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw XCTSkip("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(descriptor)
      throw NSError(domain: "SessionTestClient", code: 1)
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { dest in
        for (i, byte) in path.enumerated() { dest[i] = byte }
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.connect(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(descriptor)
      throw NSError(
        domain: "SessionTestClient", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "connect failed: \(errno)"])
    }
    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    return SessionTestClient(descriptor: descriptor)
  }

  mutating func send(_ frame: SessionFrame) throws {
    var bytes = frame.encoded()
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { pointer -> Int in
        Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      if written > 0 {
        offset += written
        continue
      }
      if errno == EAGAIN || errno == EINTR {
        var pollfd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        _ = poll(&pollfd, 1, 1000)
        continue
      }
      throw NSError(domain: "SessionTestClient", code: 3)
    }
  }

  mutating func wait(for kind: SessionFrameKind, timeout: TimeInterval) throws -> SessionFrame {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let frame = try decoder.next() {
        if frame.kind == kind { return frame }
        continue
      }
      var pollfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining = deadline.timeIntervalSinceNow
      let ready = poll(&pollfd, 1, Int32(max(remaining, 0) * 1000))
      if ready <= 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      let capacity = buffer.count
      let count = buffer.withUnsafeMutableBytes { pointer in
        Darwin.read(descriptor, pointer.baseAddress, capacity)
      }
      if count > 0 {
        decoder.push(Array(buffer.prefix(count)))
      } else if count == 0 {
        throw NSError(
          domain: "SessionTestClient", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "eof waiting for \(kind)"])
      }
    }
    throw NSError(
      domain: "SessionTestClient", code: 5,
      userInfo: [NSLocalizedDescriptionKey: "timeout waiting for \(kind)"])
  }

  func closeConnection() {
    Darwin.close(descriptor)
  }
}
