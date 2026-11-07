import DaemonConnectionTestSupport
import Darwin
import Foundation
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import DaemonConnection

/// `Service::Forward` from the app's side (issue #208), against a scripted daemon: the version
/// gate, the opcode framing, and every way a forwarded connection can end.
///
/// The **`FakeDaemon`** covers what the real daemon cannot be asked: which opcodes and stream ids
/// the client sent, what a refused OPEN does, and what a peer that predates the service must never
/// receive. The **real daemon** half, which proves the framing against the shipped Rust and carries
/// real bytes through a real socket, needs the built binary and stays hosted, in the app's
/// `DaemonPortForwardingTests`.
final class DaemonForwardServiceTests: XCTestCase {
  private var fakes: [FakeDaemon] = []
  private var connections: [DaemonClient] = []
  private var forwards: [PortForward] = []
  private var clients: [TCPClient] = []

  override func tearDown() {
    for client in clients { client.close() }
    for forward in forwards { forward.stop() }
    for fake in fakes { fake.stop() }
    clients = []
    forwards = []
    fakes = []
    connections = []
    super.tearDown()
  }

  // MARK: Fixtures

  private func fake(_ daemon: FakeDaemon) async throws -> DaemonClient {
    fakes.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    return connection
  }

  /// A listener whose refusals are collected rather than dropped, so a test can assert on them.
  private func listen(
    _ connection: DaemonClient, to remotePort: UInt16, failures: Failures,
    openTimeout: TimeInterval = PortForward.openTimeout,
    sendTimeout: TimeInterval = PortForward.sendTimeout,
    drainTimeout: TimeInterval = PortForward.drainTimeout
  ) throws -> PortForward {
    let forward = try connection.forwarding().listen(
      remotePort: remotePort, openTimeout: openTimeout, sendTimeout: sendTimeout,
      drainTimeout: drainTimeout
    ) { failures.add($0) }
    forwards.append(forward)
    return forward
  }

  /// `receiveBuffer` shrinks the client's socket buffer so a response of a few hundred KiB is
  /// enough to park the forward's `send`, which is what the teardown and budget tests need.
  private func connect(to forward: PortForward, receiveBuffer: Int? = nil) throws -> TCPClient {
    let client = try TCPClient(port: forward.localPort, receiveBuffer: receiveBuffer)
    clients.append(client)
    return client
  }

  /// Polls rather than sleeps, so a slow machine costs time instead of a failure.
  private func eventually(
    _ message: String, within seconds: TimeInterval = 5, _ condition: () -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return }
      Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertTrue(condition(), message, file: file, line: line)
  }

  // MARK: The version gate

  /// A protocol-4 daemon silently DROPS a Forward envelope, so none is sent — otherwise every
  /// forwarded connection would hang until the client's own timeout against a daemon that can never
  /// answer. Checked against the peer's RAW greeting, exactly as File is.
  func testAProtocol4AgentIsNeverSentAForwardEnvelope() async throws {
    let daemon = try FakeDaemon(version: 4, forward: true)
    let connection = try await fake(daemon)
    XCTAssertThrowsError(try connection.forwarding()) { error in
      guard case VCSError.backendVersion = error else {
        return XCTFail("expected backendVersion, got \(error)")
      }
    }
    // The refusal above is the gate; this is the other half of it — that nothing SENDS a Forward
    // envelope either. Unlike File, this service has no connect-time probe (its only request opens
    // a real socket), so `connect()` must stay silent on service 5 against every peer, not merely
    // against an old one. The fake would answer a Forward envelope; it never receives one.
    // `testEachConnectionGetsAFreshStreamIdAndIdsAreNeverReused` is the positive control.
    XCTAssertFalse(
      daemon.receivedServices.contains(5), "a pre-Forward peer must never see a Forward envelope")
  }

  // MARK: Behaviour, against a scripted daemon

  /// Two connections through one forward, and the stream ids they get. `forward.rs` frees an id only
  /// once its CLOSE has been seen and its module doc recommends never re-using one at all; the
  /// client takes the second option, off the same monotonic counter every request uses.
  func testEachConnectionGetsAFreshStreamIdAndIdsAreNeverReused() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    let forward = try listen(connection, to: 5173, failures: Failures())

    for index in 0..<3 {
      let client = try connect(to: forward)
      let payload = Data("hello \(index)".utf8)
      try client.write(payload)
      XCTAssertEqual(try client.read(payload.count), payload, "bytes did not round-trip")
      client.close()
      eventually("OPEN \(index + 1) never arrived") {
        daemon.forwards(opcode: 0x01).count == index + 1
      }
    }
    let ids = daemon.forwards(opcode: 0x01)
    XCTAssertEqual(ids.count, 3)
    XCTAssertEqual(Set(ids).count, 3, "a stream id was re-used: \(ids)")
    XCTAssertEqual(ids, ids.sorted(), "stream ids are monotonic: \(ids)")
  }

  /// The daemon holds `MAX_FORWARDS` per multiplex CONNECTION, so the client's cap is shared by
  /// every listener on it: 64 connections split across two forwards fill it, and a 65th through
  /// either one is refused locally rather than sent as an OPEN the daemon must refuse.
  func testTheConnectionCapIsSharedAcrossForwards() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    let failures = Failures()
    let first = try listen(connection, to: 5173, failures: failures)
    let second = try listen(connection, to: 3000, failures: failures)
    var clients: [TCPClient] = []
    defer { for client in clients { client.close() } }
    for index in 0..<ForwardSlot.maxPerConnection {
      let client = try connect(to: index.isMultiple(of: 2) ? first : second)
      try client.write(Data("x".utf8))
      XCTAssertEqual(try client.read(1), Data("x".utf8), "connection \(index) did not open")
      clients.append(client)
    }
    let overflow = try connect(to: second)
    clients.append(overflow)
    eventually("the 65th connection was not refused locally") {
      failures.all.contains { $0.contains("Too many connections") }
    }
    XCTAssertEqual(daemon.forwards(opcode: 0x01).count, ForwardSlot.maxPerConnection)
  }

  /// The local client half-closing sends EOF, and only EOF: the CLOSE is the daemon's, once it has
  /// both halves. A client CLOSE there would make the daemon kill the socket with the client's last
  /// DATA still queued in its writer. The fake mirrors EOF the way a peer whose input has ended
  /// does, then sends CLOSE, and the stream ends on that — the accepted socket closes.
  func testAClientThatClosesItsSocketSendsEOFAndWaitsForTheDaemonsCLOSE() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)
    try client.write(Data("ping".utf8))
    XCTAssertEqual(try client.read(4), Data("ping".utf8))
    client.shutdownWrite()

    eventually("no EOF reached the daemon") { !daemon.forwards(opcode: 0x04).isEmpty }
    XCTAssertEqual(try client.read(1, timeout: 5), Data(), "the stream ended on the daemon's CLOSE")
    let stream = try XCTUnwrap(daemon.forwards(opcode: 0x01).first)
    XCTAssertEqual(daemon.forwards(opcode: 0x04), [stream])
    XCTAssertEqual(daemon.forwards(opcode: 0x05), [], "the graceful end is the daemon's to close")
  }

  /// The response survives the teardown that the half-close triggers, and the client sees EOF.
  ///
  /// The shutdown-then-read-the-response shape the contract's EOF exists for: the client sends its
  /// body and half-closes, the peer writes the whole response and half-closes behind it, both
  /// halves are done and the forward finishes with most of the response still queued. Not the
  /// negative control for the drain — on macOS it never was: XNU refuses `shutdown(SHUT_RDWR)`
  /// with `ENOTCONN` once the peer's FIN has shut the read side, so the old synchronous teardown
  /// was a no-op here and this shape delivered in full by accident. The control is
  /// `testStoppingAForwardDrainsTheResponseAlreadyReceived`, where the client's write half is open.
  func testTheResponseSurvivesTheHalfCloseThatEndsTheForward() async throws {
    let epilogue = 2_000_000
    let daemon = try FakeDaemon(version: 5, forward: true, forwardEpilogue: epilogue)
    let connection = try await fake(daemon)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)

    try client.write(Data("request".utf8))
    XCTAssertEqual(try client.read(7), Data("request".utf8))
    client.shutdownWrite()

    // The daemon's CLOSE follows its EOF at once, so the forward has finished long before the first
    // byte of the response is read.
    try await Task.sleep(for: .milliseconds(300))
    let response = try client.read(epilogue, timeout: 20)
    XCTAssertEqual(response.count, epilogue, "got \(response.count) of \(epilogue) bytes")
    XCTAssertTrue(response.allSatisfy { $0 == 0xAB })
    // And a clean EOF behind it, not a hang.
    XCTAssertEqual(try client.read(1, timeout: 10), Data())
  }

  /// Ending a forward drains what the daemon had already sent before the local client sees EOF.
  ///
  /// The server answered and closed while the client's write half was still open — a plain
  /// `Connection: close` response — and the user removes the forward (or the connection changes
  /// generation) before the client has read it. A teardown that shut the socket's write half
  /// synchronously did it underneath the writes still queued: measured, 1.6 MB queued at the
  /// moment of `stop()` and every one of those `send`s failed with EPIPE, so the client got a
  /// clean EOF after a fraction of the response and no error anywhere. The write half is now shut
  /// behind the queued writes; the read half at once.
  func testStoppingAForwardDrainsTheResponseAlreadyReceived() async throws {
    let epilogue = 2_000_000
    let daemon = try FakeDaemon(
      version: 5, forward: true, forwardEpilogue: epilogue, forwardEpilogueOnData: true)
    let connection = try await fake(daemon)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)

    try client.write(Data("request".utf8))
    // Not reading. Once the daemon has the request, the whole response crosses the unix socket in
    // milliseconds and sits queued on the forward: ~800 KB in the kernel's buffers, the rest on
    // its write queue behind a parked `send`.
    eventually("the request never reached the daemon") { !daemon.forwards(opcode: 0x03).isEmpty }
    try await Task.sleep(for: .milliseconds(300))

    forward.stop()

    let response = try client.read(epilogue, timeout: 20)
    XCTAssertEqual(
      response.count, epilogue,
      "the response was truncated by the teardown: got \(response.count) of \(epilogue) bytes")
    XCTAssertTrue(response.allSatisfy { $0 == 0xAB })
    XCTAssertEqual(try client.read(1, timeout: 10), Data(), "then EOF, not a hang")
    eventually("no CLOSE reached the daemon") { !daemon.forwards(opcode: 0x05).isEmpty }
  }

  /// The mirror of the daemon's `MAX_QUEUED_BYTES`: a local client that has stopped reading is cut
  /// off with a reason once its unread response passes the budget, rather than buffered without
  /// limit for as long as the peer keeps sending.
  func testAClientThatStopsReadingIsCutOffAtTheBudget() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true, forwardEpilogue: 8_000_000)
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures)
    let client = try connect(to: forward, receiveBuffer: 8192)

    try client.write(Data("request".utf8))
    XCTAssertEqual(try client.read(7), Data("request".utf8))
    client.shutdownWrite()
    // And never reads again.

    eventually("the stalled connection was not cut off", within: 10) { !failures.all.isEmpty }
    XCTAssertTrue(
      failures.all.first?.contains("stopped reading") == true, "got \(failures.all)")
    eventually("no CLOSE reached the daemon") { !daemon.forwards(opcode: 0x05).isEmpty }
  }

  /// A local client that stops reading while its connection is still open is cut off by the send
  /// timeout, not held forever. The response stays under `queueBudget` even if every chunk queues at
  /// once, so the budget cut-off in the test above cannot be what fires here: the only way out is a
  /// parked `send` returning at the timeout. At the default 30 s this fails. One second, not less:
  /// the same value bounds the OPEN's writer-stall clock, which must not fire first on a slow box.
  func testAClientThatStopsReadingIsCutOffAtTheSendTimeout() async throws {
    let daemon = try FakeDaemon(
      version: 5, forward: true, forwardEpilogue: 2_000_000, forwardEpilogueOnData: true)
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures, sendTimeout: 1)
    let client = try connect(to: forward, receiveBuffer: 8192)

    // The write half stays open, so the daemon never sends CLOSE: the stream is live when the send
    // gives up, and the reason is reported.
    try client.write(Data("request".utf8))

    eventually("the stalled connection was not cut off", within: 5) { !failures.all.isEmpty }
    XCTAssertEqual(failures.all, ["A connection stopped reading and was closed."])
    eventually("no CLOSE reached the daemon") { !daemon.forwards(opcode: 0x05).isEmpty }
  }

  /// Ending a forward drains to a client that is still reading, but only for `drainTimeout`: a
  /// client that trickles keeps every `send` making progress, so the send timeout never fires, and
  /// the deadline is the only thing that ends the drain.
  ///
  /// Ended by the daemon's CLOSE, not by `stop()`: the CLOSE follows every DATA on the same stream, so
  /// the whole response is already queued when the drain starts, and a truncation can only be the
  /// deadline. A `stop()` could land before the reader had taken every envelope, and the ones it
  /// drops would pass this test with no deadline at all. At the default 30 s this fails.
  func testATricklingClientIsCutOffAtTheDrainTimeout() async throws {
    let epilogue = 2_000_000
    let daemon = try FakeDaemon(
      version: 5, forward: true, forwardEpilogue: epilogue, forwardEpilogueOnData: true)
    let connection = try await fake(daemon)
    let forward = try listen(
      connection, to: 5173, failures: Failures(), drainTimeout: 0.3)
    let client = try connect(to: forward, receiveBuffer: 8192)

    try client.write(Data("request".utf8))
    eventually("the request never reached the daemon") { !daemon.forwards(opcode: 0x03).isEmpty }
    // The daemon answers the client's EOF with its CLOSE, behind the whole response.
    client.shutdownWrite()

    // 400 KB/s: the whole response would take five seconds, far past the deadline. `read` returns
    // empty for EOF and for a timeout alike, so the empty read is timed: EOF is prompt.
    var received = 0
    var ended = false
    let started = Date()
    while Date().timeIntervalSince(started) < 20 {
      let asked = Date()
      let chunk = try client.read(8192, timeout: 5)
      if chunk.isEmpty {
        ended = Date().timeIntervalSince(asked) < 4
        break
      }
      received += chunk.count
      // Not `Thread.sleep`, which Swift 6 refuses in an async test.
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(ended, "the drain hung instead of ending in EOF")
    XCTAssertLessThan(received, epilogue, "the drain outlived its deadline: got all \(received)")
  }

  /// Out of descriptors, `accept` fails with `EMFILE` — and XNU has already dequeued and closed the
  /// connection by then, so that one is lost: its client reads EOF and the row says why. What must
  /// survive is the listener. One that treated `EMFILE` as fatal would stop here, take its row down,
  /// and refuse the next connection too.
  func testTheListenerSurvivesRunningOutOfDescriptors() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures)

    // A soft limit just above what the process holds, so filling it takes a few dozen descriptors
    // rather than every one the test host is allowed. Restored whatever happens.
    var original = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
    var held: [Int32] = []
    do {
      defer {
        for descriptor in held { Darwin.close(descriptor) }
        setrlimit(RLIMIT_NOFILE, &original)
      }
      // Earlier tests' connections close their descriptors late (a deinit on a background queue
      // once its reads end), and one freed mid-test hands `accept` the descriptor this test
      // denies it, so the count must hold still before the limit is set from it. Seen on CI once
      // the connects before each test lost their 2s, which used to be that settling time.
      var open = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
      for _ in 0..<50 {
        try await Task.sleep(for: .milliseconds(100))
        let now = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        if now == open { break }
        open = now
      }
      var lowered = original
      lowered.rlim_cur = rlim_t(open + 32)
      // Not merely asserted: without the lowered limit the loop below would fill the host's real one.
      guard setrlimit(RLIMIT_NOFILE, &lowered) == 0 else {
        return XCTFail("could not lower RLIMIT_NOFILE: \(String(cString: strerror(errno)))")
      }
      while true {
        let descriptor = dup(STDERR_FILENO)
        guard descriptor >= 0 else { break }
        held.append(descriptor)
      }
      XCTAssertEqual(errno, EMFILE)
      // One back, for the client's own socket: its connect completes in the kernel, and `accept`
      // then has no descriptor to give it.
      Darwin.close(held.removeLast())
      let lost = try connect(to: forward)
      eventually("the lost connection was not reported") { !failures.all.isEmpty }
      // Timed, because `read` returns empty on a timeout too: a connection left in the backlog would
      // read the same.
      let asked = Date()
      XCTAssertEqual(try lost.read(1, timeout: 5), Data(), "the lost connection was not closed")
      XCTAssertLessThan(Date().timeIntervalSince(asked), 4, "the lost connection was never closed")
    }
    XCTAssertEqual(failures.all, ["Out of file descriptors or memory; a connection was refused."])
    XCTAssertEqual(
      daemon.forwards(opcode: 0x01), [], "an OPEN for a connection that was never accepted")

    let next = try connect(to: forward)
    try next.write(Data("late".utf8))
    XCTAssertEqual(try next.read(4), Data("late".utf8), "the listener did not survive")
    XCTAssertEqual(failures.all.count, 1, "got \(failures.all)")
  }

  /// Removing a forward closes its listener AND every connection still running through it, each with
  /// a CLOSE — the daemon is told rather than left to discover it when the whole multiplex connection
  /// eventually ends.
  func testRemovingAForwardClosesTheListenerAndEveryLiveStream() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let first = try connect(to: forward)
    let second = try connect(to: forward)
    for client in [first, second] {
      try client.write(Data("x".utf8))
      XCTAssertEqual(try client.read(1), Data("x".utf8))
    }
    let opened = daemon.forwards(opcode: 0x01)
    XCTAssertEqual(opened.count, 2)

    forward.stop()

    eventually("the live streams were not closed") { Set(daemon.forwards(opcode: 0x05)).count == 2 }
    XCTAssertEqual(Set(daemon.forwards(opcode: 0x05)), Set(opened))
    // CLOSE is the LAST word on each stream. The shutdown that unblocks the socket reader reads as a
    // clean EOF to it, so without a finished-check there the reader answers it with a stray EOF
    // envelope for a stream this client has already released.
    try await Task.sleep(for: .milliseconds(200))
    for stream in opened {
      let opcodes = daemon.receivedForwards.filter { $0.stream == stream }.map(\.opcode)
      XCTAssertEqual(opcodes.last, 0x05, "stream \(stream) sent \(opcodes) — CLOSE must be last")
    }
    // Both accepted sockets are gone, so a client still reading sees EOF rather than hanging.
    for client in [first, second] { XCTAssertEqual(try client.read(1), Data()) }
    // And the listener no longer answers.
    XCTAssertThrowsError(try TCPClient(port: forward.localPort))
  }

  /// An error REPLY closes the accepted socket and surfaces the refusal's own detail — that string
  /// is the useful half ("connection refused"), and swallowing it would leave the user with a port
  /// that silently does nothing.
  func testAnErrorReplyClosesTheAcceptedSocketAndSurfacesTheDetail() async throws {
    let daemon = try FakeDaemon(
      version: 5, forward: true, forwardRefusal: "Connection refused (os error 61)")
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1), Data(), "the accepted socket must be closed")
    eventually("the refusal never surfaced") { !failures.all.isEmpty }
    XCTAssertEqual(failures.all.first, "Could not connect: Connection refused (os error 61)")
    // The CLOSE that follows a refusal lands on a stream the client has already released. It must be
    // DROPPED, not treated as a protocol violation — the connection is shared with VCS and File.
    let reply = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 2)
    XCTAssertNoThrow(try DaemonVCSReply<DaemonVCSCapabilities>.decode(reply))
  }

  /// Losing the host connection closes every accepted socket, and the listener stops carrying: the
  /// daemon drops every socket a departing client opened, so a forward that kept accepting would be
  /// promising an address that answers nothing.
  func testLosingTheConnectionClosesEveryAcceptedSocket() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)
    try client.write(Data("x".utf8))
    XCTAssertEqual(try client.read(1), Data("x".utf8))

    await connection.close()

    XCTAssertEqual(try client.read(1), Data(), "the accepted socket outlived the connection")
    // A connection made after the loss is closed at once rather than left hanging on a stream the
    // daemon will never hear about.
    let orphan = try connect(to: forward)
    XCTAssertEqual(try orphan.read(1), Data())
  }

  /// Exactly one REPLY starts exactly one pump. A peer that answers OPEN twice must not get a second
  /// reader on the same socket — two would split one write across two DATA envelopes at arbitrary
  /// boundaries, and each would hold a thread for the connection's life.
  func testASecondReplyDoesNotStartASecondPump() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true, forwardReplies: 2)
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures)
    let client = try connect(to: forward)

    // Let both replies land before the first byte is written, so a second pump would be running.
    eventually("no OPEN reached the daemon") { !daemon.forwards(opcode: 0x01).isEmpty }
    try await Task.sleep(for: .milliseconds(100))
    try client.write(Data("abc".utf8))
    XCTAssertEqual(try client.read(3), Data("abc".utf8))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(daemon.forwards(opcode: 0x03).count, 1, "one write, one DATA, one pump")
    // The DATA count alone would pass with two pumps (only one of two readers gets one write);
    // `opened` fires once per REPLY that wins, so this is the assertion the guard is for.
    XCTAssertEqual(failures.opened, 1, "the second REPLY must be dropped, not opened again")
  }

  /// Daemon text into the inspector is bounded and stripped of control characters: a newline or a
  /// megabyte in a refusal detail must not wreck the row.
  func testARefusalDetailIsSanitisedBeforeItReachesTheRow() async throws {
    let long = String(repeating: "x", count: 300)
    let body = Data(#"{"version":1,"error":{"connect":"line one\nline two \#(long)"}}"#.utf8)
    let daemon = try FakeDaemon(version: 5, forward: true, forwardReplyBody: body)
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1), Data())
    eventually("the refusal never surfaced") { !failures.all.isEmpty }
    let detail = try XCTUnwrap(failures.all.first)
    XCTAssertFalse(detail.contains("\n"), "control characters are stripped: \(detail)")
    XCTAssertTrue(detail.hasPrefix("Could not connect: line oneline two x"))
    XCTAssertTrue(detail.hasSuffix("…"), "over-long text is truncated: \(detail.count) chars")
    XCTAssertLessThanOrEqual(detail.count, "Could not connect: ".count + 201)
  }

  /// A daemon that never answers OPEN is given up on: the accepted socket closes, the reason is
  /// reported, and the stream is closed toward the daemon so an id is never left half-open.
  func testADaemonThatNeverAnswersOpenIsGivenUpOn() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true, forwardReplies: 0)
    let connection = try await fake(daemon)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures, openTimeout: 0.3)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1, timeout: 5), Data(), "the accepted socket must be closed")
    eventually("the timeout never surfaced") { !failures.all.isEmpty }
    XCTAssertEqual(failures.all.first, "The daemon did not answer the forward request.")
    eventually("no CLOSE reached the daemon") { !daemon.forwards(opcode: 0x05).isEmpty }
  }

  /// A REPLY this build cannot read is a refusal, never a success: a client that pumped bytes into
  /// a socket the daemon may not have made would be worse than one that reports.
  func testAnUnreadableReplyIsARefusal() async throws {
    for body in [Data("not json".utf8), Data(#"{"version":2,"result":{"opened":true}}"#.utf8)] {
      let daemon = try FakeDaemon(version: 5, forward: true, forwardReplyBody: body)
      let connection = try await fake(daemon)
      let failures = Failures()
      let forward = try listen(connection, to: 5173, failures: failures)
      let client = try connect(to: forward)

      XCTAssertEqual(try client.read(1), Data(), "the accepted socket must be closed")
      eventually("the refusal never surfaced") { !failures.all.isEmpty }
      XCTAssertEqual(failures.all.first, "The daemon sent an unreadable forward reply.")
    }
  }

  /// A Forward envelope on stream 0 is dropped, as `forward.rs` documents for its own side — not
  /// treated as a protocol violation that fails the whole shared connection. A future daemon that
  /// adds a stream-0 notification must not take VCS, File and Status down on every shipped client.
  func testAStreamZeroForwardEnvelopeIsDropped() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    let connection = try await fake(daemon)
    daemon.pushForward(stream: 0, opcode: 0x03, body: Data("stray".utf8))
    try await Task.sleep(for: .milliseconds(100))
    let reply = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 2)
    XCTAssertNoThrow(try DaemonVCSReply<DaemonVCSCapabilities>.decode(reply))
  }

  // MARK: The fixtures

  /// The fixture, not the app: a test that stops an `EchoServer` by hand is stopped again by
  /// `tearDown`, and that second stop must not close the descriptor that has reused the number.
  func testStoppingAnEchoServerTwiceLeavesTheNumberToItsNewOwner() throws {
    // A file of this test's own, so the descriptor parked on the freed number can be told apart from
    // anything another thread opens there.
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("echo-\(UUID())")
    XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: marker) }
    var expected = stat()
    XCTAssertEqual(stat(marker.path, &expected), 0)

    let echo = try EchoServer()
    let number = echo.listener
    echo.stop()
    // The lowest free number, which is almost always the one just released.
    let reused = open(marker.path, O_RDONLY)
    guard reused == number else {
      if reused >= 0 { Darwin.close(reused) }
      throw XCTSkip("another thread took descriptor \(number) first")
    }

    echo.stop()
    var actual = stat()
    let stillOurs =
      fstat(reused, &actual) == 0 && actual.st_dev == expected.st_dev
      && actual.st_ino == expected.st_ino
    // Closed only while it is provably still this test's file. If the second stop closed it, the
    // number may already be another thread's, and closing it here would be the very bug under test.
    if stillOurs { Darwin.close(reused) }
    XCTAssertTrue(stillOurs, "the second stop closed descriptor \(reused)")
  }
}

/// Refusals collected off the forward's event callback, which fires on whichever thread noticed.
/// The app's hosted forward tests keep a copy of their own: it names `PortForward.Event`, so it
/// can't live in `DaemonConnectionTestSupport`, which imports nothing of this package's.
final class Failures: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  private var openedCount = 0
  func add(_ event: PortForward.Event) {
    lock.withLock {
      switch event {
      case .opened: openedCount += 1
      case .failed(let detail), .stopped(let detail): values.append(detail)
      }
    }
  }
  var all: [String] { lock.withLock { values } }
  var opened: Int { lock.withLock { openedCount } }
}
