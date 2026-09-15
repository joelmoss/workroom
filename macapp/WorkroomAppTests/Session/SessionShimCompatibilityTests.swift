import Darwin
import Foundation
import WorkroomSessionProtocol
import XCTest

/// The attach-only `workroom-session` against the daemon it actually has to talk to: the one
/// shipped in **v2.0.0**, pinned as a binary fixture.
///
/// **Why a pinned binary and not a fake.** The obvious cheap version of this test is a stub that
/// binds a socket and answers with `SessionFrame`s. It proves nothing. A fake built from
/// `WorkroomSessionProtocol` reads the same source the client does, so a change to that module
/// moves both sides together and the test stays green through exactly the break it was written to
/// catch. The only peer whose behaviour cannot drift with our source tree is a binary that was
/// compiled before it: `Fixtures/workroom-session-v2.0.0`, lifted unmodified from
/// `workroom-macos-app_2.0.0.dmg` (sha256 6f75e6f7…), which is what users in the field are running.
///
/// This is the whole justification for keeping the client half of `macapp/WorkroomSession/` at all.
/// If these fail, a user who updates while holding a terminal from an older build loses it — see
/// `docs/designs/remote-workrooms.md`. **`WorkroomSessionProtocol` is frozen while the shim ships**
/// precisely because this peer can never be recompiled to match a change.
/// Thrown after an `XCTFail` so the test stops without the failure being reported as a skip.
private enum CompatibilityFixtureError: Error {
  case unusable
}

final class SessionShimCompatibilityTests: XCTestCase {
  private var directory: URL!
  private var daemon: Process?

  override func setUpWithError() throws {
    try super.setUpWithError()
    // sun_path is 104 bytes; the per-test temporary directory blows that on its own.
    directory = URL(fileURLWithPath: "/tmp/wr-compat-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let daemon, daemon.isRunning {
      daemon.terminate()
      daemon.waitUntilExit()
    }
    daemon = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  /// The property the shim exists for: a session created by the v2.0.0 daemon, whose creating
  /// client has since gone away, is reattachable by THIS build — and the reattaching client is
  /// handed the output the shell produced before it existed.
  ///
  /// Asserting on the replayed marker rather than on "no error" is deliberate. A client that
  /// connects, fails the handshake and exits quietly would pass a liveness check; only bytes that
  /// originated in the old daemon's pty prove the session was really reached.
  func testReattachesASessionTheShippedDaemonHolds() throws {
    let socketPath = try startShippedDaemon()
    let sessionID = SessionIdentifier(UUID())
    let marker = "SHIM-COMPAT-\(UUID().uuidString.prefix(8))"
    let sentinel = directory.appendingPathComponent("printed").path

    // Created by the SHIPPED client, then detached: `/dev/null` on stdin ends it immediately while
    // the daemon keeps the pty, which is exactly the state a user's machine is left in when they
    // quit an older build of the app.
    let creator = try run(
      Self.shippedBinaryURL, arguments: ["attach"],
      environment: attachEnvironment(
        sessionID: sessionID, socketPath: socketPath,
        command: "sh -c 'echo \(marker); touch \(sentinel); sleep 120'"))
    creator.waitUntilExit()

    // Wait for the marker to be firmly in the PAST before attaching. Without this the new client
    // could be receiving it as live output and the test would pass either way — it would prove the
    // session exists, not that its history was replayed, which is the property a user notices.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !FileManager.default.fileExists(atPath: sentinel) {
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sentinel),
      "the v2.0.0 daemon never ran the session's command; nothing to replay")

    let output = try attachWithCurrentBuild(sessionID: sessionID, socketPath: socketPath)

    XCTAssertTrue(
      output.contains(marker),
      """
      the attach-only client did not receive the v2.0.0 daemon's REPLAY for a session it holds — \
      the marker was already printed before this client connected. A user updating with a terminal \
      open would come back to a blank pane. Got: \(output.suffix(400))
      """)
  }

  /// The version handshake, ported from the deleted `SessionDaemonEndToEndTests` — the only test
  /// anywhere that exercised it, and the one most likely to be broken by an edit to
  /// `WorkroomSessionProtocol` made for the app's own control client.
  ///
  /// Driven straight against the SHIPPED daemon rather than a rebuilt one, so it measures the
  /// agreement that actually matters: what this tree encodes against what v2.0.0 decodes.
  func testTheShippedDaemonRefusesAFutureProtocolVersion() throws {
    let socketPath = try startShippedDaemon()
    var client = try SessionTestClient.connect(socketPath: socketPath)
    defer { client.closeConnection() }

    let request = SessionAttachRequest(
      version: SessionProtocolVersion.current + 1,
      identifier: SessionIdentifier(UUID()),
      columns: 80,
      rows: 24,
      workingDirectory: "/",
      command: "",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [])
    try client.send(SessionFrame(kind: .attach, payload: request.encoded()))

    let failure = try client.wait(for: .failure, timeout: 5)
    let message = try SessionTextPayload.decode(failure.payload)
    XCTAssertTrue(message.contains("different version"), message)
  }

  /// The current version is accepted by the same peer. Without this, the test above passes just as
  /// well when EVERY version is refused — which is what a real encoding break looks like.
  func testTheShippedDaemonAcceptsTheCurrentProtocolVersion() throws {
    let socketPath = try startShippedDaemon()
    var client = try SessionTestClient.connect(socketPath: socketPath)
    defer { client.closeConnection() }

    let request = SessionAttachRequest(
      identifier: SessionIdentifier(UUID()),
      columns: 80,
      rows: 24,
      workingDirectory: directory.path,
      command: "sh -c 'sleep 30'",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [])
    try client.send(SessionFrame(kind: .attach, payload: request.encoded()))

    XCTAssertNoThrow(
      try client.wait(for: .attached, timeout: 5),
      "v2.0.0 refused a request encoded by this tree — WorkroomSessionProtocol has drifted")
  }

  // MARK: - Harness

  /// The pinned fixture, located from the source tree rather than the test bundle: an executable
  /// copied as a bundle resource does not reliably keep its exec bit, and `#filePath` is stable for
  /// every configuration this suite runs in.
  private static let shippedBinaryURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Session/
    .deletingLastPathComponent()  // WorkroomAppTests/
    .appendingPathComponent("Fixtures/workroom-session-v2.0.0")

  /// This build's `workroom-session`, beside the test host in the products directory.
  private static func currentBinaryURL() throws -> URL {
    for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR"] {
      guard let directory = ProcessInfo.processInfo.environment[key] else { continue }
      let url = URL(fileURLWithPath: directory).appendingPathComponent("workroom-session")
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    let embedded = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/MacOS/workroom-session")
    if FileManager.default.isExecutableFile(atPath: embedded.path) { return embedded }
    var candidate = Bundle(for: SessionShimCompatibilityTests.self).bundleURL
    for _ in 0..<6 {
      let url = candidate.appendingPathComponent("workroom-session")
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
      candidate.deleteLastPathComponent()
    }
    // This build's own product, not an optional dependency: if it is missing the target did not
    // build, which is a failure however the suite was invoked.
    XCTFail("this build's workroom-session was not found beside the test bundle")
    throw CompatibilityFixtureError.unusable
  }

  /// **A missing fixture skips; a fixture that will not RUN fails.**
  ///
  /// The difference matters more than it looks. "Not checked out" is an environmental absence. "The
  /// pinned binary is here and cannot start" — a broken signature, quarantine, a future macOS
  /// refusing an old Mach-O — is this test's own subject failing, and reporting that as a skip would
  /// let all three tests in this file stop running indefinitely while the suite stayed green. That
  /// is precisely the wire-compatibility claim the whole change rests on, and `make app-test` does
  /// not print a summary under Xcode 26, so nobody would notice.
  private func startShippedDaemon() throws -> String {
    guard FileManager.default.fileExists(atPath: Self.shippedBinaryURL.path) else {
      throw XCTSkip("v2.0.0 fixture not present at \(Self.shippedBinaryURL.path)")
    }
    guard FileManager.default.isExecutableFile(atPath: Self.shippedBinaryURL.path) else {
      XCTFail("the pinned v2.0.0 fixture is present but not executable — check its mode in git")
      throw CompatibilityFixtureError.unusable
    }
    let socketPath = directory.appendingPathComponent("s.sock").path
    daemon = try run(
      Self.shippedBinaryURL,
      arguments: ["daemon", "--socket", socketPath, "--idle-timeout", "30000"],
      environment: [:])

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) { return socketPath }
      if let daemon, !daemon.isRunning { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    let status = daemon.map { $0.isRunning ? "still running" : "exited \($0.terminationStatus)" }
    XCTFail(
      """
      the pinned v2.0.0 daemon never bound \(socketPath) (\(status ?? "not started")). The fixture \
      is present, so this is the compatibility subject failing, not a missing test dependency — \
      do not downgrade it to a skip.
      """)
    throw CompatibilityFixtureError.unusable
  }

  /// Runs THIS build's attach client against the shipped daemon, holding stdin open with a pipe so
  /// the client stays attached long enough to be served, and returns everything it wrote.
  private func attachWithCurrentBuild(
    sessionID: SessionIdentifier, socketPath: String
  ) throws -> String {
    let process = Process()
    process.executableURL = try Self.currentBinaryURL()
    process.arguments = ["attach"]
    process.environment = attachEnvironment(
      sessionID: sessionID, socketPath: socketPath, command: "")
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = input
    try process.run()

    // Read on a background queue: the client streams until its stdin closes, and reading to EOF on
    // this thread would deadlock against our own write end being open.
    let collected = NSMutableData()
    let lock = NSLock()
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      lock.lock()
      collected.append(data)
      lock.unlock()
    }

    Thread.sleep(forTimeInterval: 3)
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil

    lock.lock()
    defer { lock.unlock() }
    return String(decoding: collected as Data, as: UTF8.self)
  }

  private func attachEnvironment(
    sessionID: SessionIdentifier, socketPath: String, command: String
  ) -> [String: String] {
    [
      "WORKROOM_SESSION_ID": sessionID.uuidString,
      "WORKROOM_SESSION_SOCKET": socketPath,
      "WORKROOM_SESSION_SHELL": "/bin/sh",
      "WORKROOM_SESSION_CWD": directory.path,
      "WORKROOM_SESSION_COMMAND": command,
    ]
  }

  @discardableResult
  private func run(
    _ url: URL, arguments: [String], environment: [String: String]
  ) throws -> Process {
    let process = Process()
    process.executableURL = url
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    if environment["WORKROOM_SESSION_ID"] != nil {
      process.standardInput = FileHandle.nullDevice
    }
    try process.run()
    return process
  }
}

/// Minimal unix-socket client for protocol tests, carried over from the deleted
/// `SessionDaemonEndToEndTests` — the frames it sends are what this tree encodes, which is the
/// half of the comparison under test.
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
