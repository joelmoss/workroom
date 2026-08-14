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

  /// Regression test for the "PID reuse after `waitpid` reaps a child" finding: a command that
  /// prints trailing output right before exiting leaves that output sitting in the pty's buffer,
  /// so the daemon's `reapChildren` (SIGCHLD) can observe and reap the exited child BEFORE the
  /// master fd reports EOF (which only happens once the buffered bytes are actually read). That
  /// ordering used to make `closeMaster` send a termination signal to a pid `waitpid` had already
  /// reaped moments earlier in the very same call. This doesn't assert the signal was skipped
  /// directly (nothing in the protocol surfaces that), but it does exercise the exact interleaving
  /// end to end and pins the still-correct outcome: the trailing output is delivered, the real
  /// exit status survives, and the session is cleanly removed.
  func testNaturalExitWithTrailingOutputReapsCleanly() throws {
    let harness = try SessionDaemonHarness.start()
    defer { harness.stop() }

    let identifier = SessionIdentifier(UUID())
    var client = try SessionTestClient.connect(socketPath: harness.socketPath)
    let attach = SessionAttachRequest(
      identifier: identifier,
      columns: 80,
      rows: 24,
      workingDirectory: FileManager.default.temporaryDirectory.path,
      command: "/bin/sh -c 'printf done; exit 7'",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [
        SessionEnvironmentEntry(key: "TERM", value: "dumb"),
        SessionEnvironmentEntry(key: "PATH", value: "/bin:/usr/bin"),
      ])
    try client.send(SessionFrame(kind: .attach, payload: attach.encoded()))
    _ = try client.wait(for: .attached, timeout: 3)

    let output = try client.wait(for: .output, timeout: 3)
    XCTAssertEqual(String(bytes: output.payload, encoding: .utf8), "done")

    let exited = try client.wait(for: .exited, timeout: 3)
    XCTAssertEqual(try SessionExitPayload.decode(exited.payload), 7)

    var lister = try SessionTestClient.connect(socketPath: harness.socketPath)
    try lister.send(SessionFrame(kind: .list))
    let sessionsFrame = try lister.wait(for: .sessions, timeout: 2)
    let listed = try SessionDescriptor.decodeList(sessionsFrame.payload)
    XCTAssertTrue(listed.isEmpty)
    lister.closeConnection()

    client.closeConnection()
  }

  /// Regression test for the "`SessionDescriptor.decodeList`'s wire encoding has no cap relative
  /// to `SessionFrame`'s max frame size" finding: a `list` reply's size grows with both session
  /// count and each session's client-supplied metadata, but unlike `.output` it's sent as a single
  /// frame. Six sessions with a bulky metadata title comfortably clear `SessionFrame
  /// .maximumPayloadSize` in aggregate while each individual `attach` stays well under it. The
  /// daemon must refuse to build that oversized frame — sending it would poison the receiving
  /// client's decoder outright (any reader that sees a declared length past the max permanently
  /// fails), which is a stronger, more immediate failure than a timeout.
  func testOversizedSessionListRepliesWithFailureNotAMalformedFrame() throws {
    let harness = try SessionDaemonHarness.start()
    defer { harness.stop() }

    let bulkyTitle = String(repeating: "x", count: 200_000)
    var clients: [SessionTestClient] = []
    defer { for var client in clients { client.closeConnection() } }
    for _ in 0..<6 {
      let identifier = SessionIdentifier(UUID())
      var client = try SessionTestClient.connect(socketPath: harness.socketPath)
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
      clients.append(client)
    }

    var lister = try SessionTestClient.connect(socketPath: harness.socketPath)
    try lister.send(SessionFrame(kind: .list))
    let reply = try lister.wait(for: .failure, timeout: 3)
    let message = try SessionTextPayload.decode(reply.payload)
    XCTAssertFalse(message.isEmpty)
    lister.closeConnection()
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
