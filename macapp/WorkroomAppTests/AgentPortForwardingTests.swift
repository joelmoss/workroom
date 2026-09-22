import Darwin
import XCTest

@testable import Workroom

/// `Service::Forward` from the app's side (issue #208): the version gate, the opcode framing, and
/// every way a forwarded connection can end.
///
/// Split deliberately. The **real agent** (`AgentHarness`) proves the framing against the shipped
/// Rust and carries real bytes through a real socket — the one thing the Rust tests structurally
/// cannot cover, because they have no Swift client. The **`FakeAgent`** covers what the real agent
/// cannot be asked: which opcodes and stream ids the client sent, what a refused OPEN does, and what
/// a peer that predates the service must never receive.
final class AgentPortForwardingTests: XCTestCase {
  private var agents: [AgentHarness] = []
  private var fakes: [FakeAgent] = []
  private var connections: [AgentVCSConnection] = []
  private var forwards: [PortForward] = []
  private var echoes: [EchoServer] = []
  private var clients: [TCPClient] = []

  override func tearDown() {
    for client in clients { client.close() }
    for forward in forwards { forward.stop() }
    for echo in echoes { echo.stop() }
    for agent in agents { agent.stop() }
    for fake in fakes { fake.stop() }
    clients = []
    forwards = []
    echoes = []
    agents = []
    fakes = []
    connections = []
    super.tearDown()
  }

  // MARK: Fixtures

  private func fake(_ agent: FakeAgent) async throws -> AgentVCSConnection {
    fakes.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    connections.append(connection)
    return connection
  }

  private func realAgent() async throws -> AgentVCSConnection {
    let agent = try AgentHarness.start(environment: ProcessInfo.processInfo.environment)
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    connections.append(connection)
    return connection
  }

  private func echo() throws -> EchoServer {
    let server = try EchoServer()
    echoes.append(server)
    return server
  }

  /// A listener whose refusals are collected rather than dropped, so a test can assert on them.
  private func listen(
    _ connection: AgentVCSConnection, to remotePort: UInt16, failures: Failures,
    openTimeout: TimeInterval = PortForward.openTimeout
  ) throws -> PortForward {
    let forward = try connection.forwarding().listen(
      remotePort: remotePort, openTimeout: openTimeout
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

  /// A protocol-4 agent silently DROPS a Forward envelope, so none is sent — otherwise every
  /// forwarded connection would hang until the client's own timeout against an agent that can never
  /// answer. Checked against the peer's RAW greeting, exactly as File and Status are.
  func testAProtocol4AgentIsNeverSentAForwardEnvelope() async throws {
    let agent = try FakeAgent(version: 4, status: true, forward: true)
    let connection = try await fake(agent)
    XCTAssertThrowsError(try connection.forwarding()) { error in
      guard case VCSError.backendVersion = error else {
        return XCTFail("expected backendVersion, got \(error)")
      }
    }
    // The refusal above is the gate; this is the other half of it — that nothing SENDS a Forward
    // envelope either. Unlike Status, this service has no connect-time probe (its only request opens
    // a real socket), so `connect()` must stay silent on service 5 against every peer, not merely
    // against an old one. The fake would answer a Forward envelope; it never receives one.
    // `testEachConnectionGetsAFreshStreamIdAndIdsAreNeverReused` is the positive control.
    XCTAssertFalse(
      agent.receivedServices.contains(5), "a pre-Forward peer must never see a Forward envelope")
  }

  // MARK: Behaviour, against a scripted agent

  /// Two connections through one forward, and the stream ids they get. `forward.rs` frees an id only
  /// once its CLOSE has been seen and its module doc recommends never re-using one at all; the
  /// client takes the second option, off the same monotonic counter every request uses.
  func testEachConnectionGetsAFreshStreamIdAndIdsAreNeverReused() async throws {
    let agent = try FakeAgent(version: 5, forward: true)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())

    for index in 0..<3 {
      let client = try connect(to: forward)
      let payload = Data("hello \(index)".utf8)
      try client.write(payload)
      XCTAssertEqual(try client.read(payload.count), payload, "bytes did not round-trip")
      client.close()
      eventually("OPEN \(index + 1) never arrived") {
        agent.forwards(opcode: 0x01).count == index + 1
      }
    }
    let ids = agent.forwards(opcode: 0x01)
    XCTAssertEqual(ids.count, 3)
    XCTAssertEqual(Set(ids).count, 3, "a stream id was re-used: \(ids)")
    XCTAssertEqual(ids, ids.sorted(), "stream ids are monotonic: \(ids)")
  }

  /// The local client going away ends the stream toward the agent, so the agent stops holding a
  /// socket nobody will read. The fake mirrors EOF the way a peer whose input has ended does, so
  /// both halves finish and CLOSE follows.
  func testAClientThatClosesItsSocketSendsEOFThenCLOSE() async throws {
    let agent = try FakeAgent(version: 5, forward: true)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)
    try client.write(Data("ping".utf8))
    XCTAssertEqual(try client.read(4), Data("ping".utf8))
    client.shutdownWrite()

    eventually("no EOF reached the agent") { !agent.forwards(opcode: 0x04).isEmpty }
    eventually("no CLOSE reached the agent") { !agent.forwards(opcode: 0x05).isEmpty }
    let stream = try XCTUnwrap(agent.forwards(opcode: 0x01).first)
    XCTAssertEqual(agent.forwards(opcode: 0x04), [stream])
    XCTAssertEqual(agent.forwards(opcode: 0x05), [stream])
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
    let agent = try FakeAgent(version: 5, forward: true, forwardEpilogue: epilogue)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)

    try client.write(Data("request".utf8))
    XCTAssertEqual(try client.read(7), Data("request".utf8))
    client.shutdownWrite()

    eventually("the forward did not finish toward the agent", within: 10) {
      !agent.forwards(opcode: 0x05).isEmpty
    }
    let response = try client.read(epilogue, timeout: 20)
    XCTAssertEqual(response.count, epilogue, "got \(response.count) of \(epilogue) bytes")
    XCTAssertTrue(response.allSatisfy { $0 == 0xAB })
    // And a clean EOF behind it, not a hang.
    XCTAssertEqual(try client.read(1, timeout: 10), Data())
  }

  /// Ending a forward drains what the agent had already sent before the local client sees EOF.
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
    let agent = try FakeAgent(
      version: 5, forward: true, forwardEpilogue: epilogue, forwardEpilogueOnData: true)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)

    try client.write(Data("request".utf8))
    // Not reading. Once the agent has the request, the whole response crosses the unix socket in
    // milliseconds and sits queued on the forward: ~800 KB in the kernel's buffers, the rest on
    // its write queue behind a parked `send`.
    eventually("the request never reached the agent") { !agent.forwards(opcode: 0x03).isEmpty }
    try await Task.sleep(for: .milliseconds(300))

    forward.stop()

    let response = try client.read(epilogue, timeout: 20)
    XCTAssertEqual(
      response.count, epilogue,
      "the response was truncated by the teardown: got \(response.count) of \(epilogue) bytes")
    XCTAssertTrue(response.allSatisfy { $0 == 0xAB })
    XCTAssertEqual(try client.read(1, timeout: 10), Data(), "then EOF, not a hang")
    eventually("no CLOSE reached the agent") { !agent.forwards(opcode: 0x05).isEmpty }
  }

  /// The mirror of the agent's `MAX_QUEUED_BYTES`: a local client that has stopped reading is cut
  /// off with a reason once its unread response passes the budget, rather than buffered without
  /// limit for as long as the peer keeps sending.
  func testAClientThatStopsReadingIsCutOffAtTheBudget() async throws {
    let agent = try FakeAgent(version: 5, forward: true, forwardEpilogue: 8_000_000)
    let connection = try await fake(agent)
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
    eventually("no CLOSE reached the agent") { !agent.forwards(opcode: 0x05).isEmpty }
  }

  /// Removing a forward closes its listener AND every connection still running through it, each with
  /// a CLOSE — the agent is told rather than left to discover it when the whole multiplex connection
  /// eventually ends.
  func testRemovingAForwardClosesTheListenerAndEveryLiveStream() async throws {
    let agent = try FakeAgent(version: 5, forward: true)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let first = try connect(to: forward)
    let second = try connect(to: forward)
    for client in [first, second] {
      try client.write(Data("x".utf8))
      XCTAssertEqual(try client.read(1), Data("x".utf8))
    }
    let opened = agent.forwards(opcode: 0x01)
    XCTAssertEqual(opened.count, 2)

    forward.stop()

    eventually("the live streams were not closed") { Set(agent.forwards(opcode: 0x05)).count == 2 }
    XCTAssertEqual(Set(agent.forwards(opcode: 0x05)), Set(opened))
    // CLOSE is the LAST word on each stream. The shutdown that unblocks the socket reader reads as a
    // clean EOF to it, so without a finished-check there the reader answers it with a stray EOF
    // envelope for a stream this client has already released.
    try await Task.sleep(for: .milliseconds(200))
    for stream in opened {
      let opcodes = agent.receivedForwards.filter { $0.stream == stream }.map(\.opcode)
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
    let agent = try FakeAgent(
      version: 5, forward: true, forwardRefusal: "Connection refused (os error 61)")
    let connection = try await fake(agent)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1), Data(), "the accepted socket must be closed")
    eventually("the refusal never surfaced") { !failures.all.isEmpty }
    XCTAssertEqual(failures.all.first, "Could not connect: Connection refused (os error 61)")
    // The CLOSE that follows a refusal lands on a stream the client has already released. It must be
    // DROPPED, not treated as a protocol violation — the connection is shared with VCS and File.
    let reply = try await connection.request(AgentVCSRequest(method: "capabilities"), timeout: 2)
    XCTAssertNoThrow(try AgentVCSReply<AgentVCSCapabilities>.decode(reply))
  }

  /// Losing the host connection closes every accepted socket, and the listener stops carrying: the
  /// agent drops every socket a departing client opened, so a forward that kept accepting would be
  /// promising an address that answers nothing.
  func testLosingTheConnectionClosesEveryAcceptedSocket() async throws {
    let agent = try FakeAgent(version: 5, forward: true)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)
    try client.write(Data("x".utf8))
    XCTAssertEqual(try client.read(1), Data("x".utf8))

    await connection.close()

    XCTAssertEqual(try client.read(1), Data(), "the accepted socket outlived the connection")
    // A connection made after the loss is closed at once rather than left hanging on a stream the
    // agent will never hear about.
    let orphan = try connect(to: forward)
    XCTAssertEqual(try orphan.read(1), Data())
  }

  /// Exactly one REPLY starts exactly one pump. A peer that answers OPEN twice must not get a second
  /// reader on the same socket — two would split one write across two DATA envelopes at arbitrary
  /// boundaries, and each would hold a thread for the connection's life.
  func testASecondReplyDoesNotStartASecondPump() async throws {
    let agent = try FakeAgent(version: 5, forward: true, forwardReplies: 2)
    let connection = try await fake(agent)
    let forward = try listen(connection, to: 5173, failures: Failures())
    let client = try connect(to: forward)

    // Let both replies land before the first byte is written, so a second pump would be running.
    eventually("no OPEN reached the agent") { !agent.forwards(opcode: 0x01).isEmpty }
    try await Task.sleep(for: .milliseconds(100))
    try client.write(Data("abc".utf8))
    XCTAssertEqual(try client.read(3), Data("abc".utf8))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(agent.forwards(opcode: 0x03).count, 1, "one write, one DATA, one pump")
  }

  /// An agent that never answers OPEN is given up on: the accepted socket closes, the reason is
  /// reported, and the stream is closed toward the agent so an id is never left half-open.
  func testAnAgentThatNeverAnswersOpenIsGivenUpOn() async throws {
    let agent = try FakeAgent(version: 5, forward: true, forwardReplies: 0)
    let connection = try await fake(agent)
    let failures = Failures()
    let forward = try listen(connection, to: 5173, failures: failures, openTimeout: 0.3)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1, timeout: 5), Data(), "the accepted socket must be closed")
    eventually("the timeout never surfaced") { !failures.all.isEmpty }
    XCTAssertEqual(failures.all.first, "The agent did not answer the forward request.")
    eventually("no CLOSE reached the agent") { !agent.forwards(opcode: 0x05).isEmpty }
  }

  /// A REPLY this build cannot read is a refusal, never a success: a client that pumped bytes into
  /// a socket the agent may not have made would be worse than one that reports.
  func testAnUnreadableReplyIsARefusal() async throws {
    for body in [Data("not json".utf8), Data(#"{"version":2,"result":{"opened":true}}"#.utf8)] {
      let agent = try FakeAgent(version: 5, forward: true, forwardReplyBody: body)
      let connection = try await fake(agent)
      let failures = Failures()
      let forward = try listen(connection, to: 5173, failures: failures)
      let client = try connect(to: forward)

      XCTAssertEqual(try client.read(1), Data(), "the accepted socket must be closed")
      eventually("the refusal never surfaced") { !failures.all.isEmpty }
      XCTAssertEqual(failures.all.first, "The agent sent an unreadable forward reply.")
    }
  }

  /// A Forward envelope on stream 0 is dropped, as `forward.rs` documents for its own side — not
  /// treated as a protocol violation that fails the whole shared connection. A future agent that
  /// adds a stream-0 notification must not take VCS, File and Status down on every shipped client.
  func testAStreamZeroForwardEnvelopeIsDropped() async throws {
    let agent = try FakeAgent(version: 5, forward: true)
    let connection = try await fake(agent)
    agent.pushForward(stream: 0, opcode: 0x03, body: Data("stray".utf8))
    try await Task.sleep(for: .milliseconds(100))
    let reply = try await connection.request(AgentVCSRequest(method: "capabilities"), timeout: 2)
    XCTAssertNoThrow(try AgentVCSReply<AgentVCSCapabilities>.decode(reply))
  }

  // MARK: The shipped agent

  /// The whole path against the binary that ships: the Swift opcode framing, the agent's
  /// `Service::Forward`, and a real loopback socket on the other side. The payload is larger than one
  /// envelope, so the client's chunking is exercised rather than assumed.
  func testTheRealAgentForwardsBytesBothWaysThroughARealSocket() async throws {
    let server = try echo()
    let connection = try await realAgent()
    let forward = try listen(connection, to: server.port, failures: Failures())
    XCTAssertNotEqual(forward.localPort, server.port, "the local port must be ephemeral")
    let client = try connect(to: forward)

    // 1.5 MB: past `MAX_ENVELOPE_PAYLOAD` (1 MiB) and far past the 64 KiB read size, so this crosses
    // many DATA envelopes rather than assuming the chunking works. Written on another queue while
    // this thread reads, because an echo of this size fills both directions' socket buffers long
    // before the write finishes. Comfortably under the agent's 2 MiB per-forward queue budget, which
    // an echo server that reads eagerly never approaches anyway.
    let pattern = Data((0..<1024).map { UInt8($0 % 251) })
    var payload = Data()
    payload.reserveCapacity(1024 * 1500)
    for _ in 0..<1500 { payload.append(pattern) }
    let sent = payload
    DispatchQueue.global().async { try? client.write(sent) }
    XCTAssertEqual(try client.read(payload.count, timeout: 30), payload, "the echo did not match")

    // The peer's EOF reaches the local socket as an EOF, not a reset: the echo server half-closes
    // once its input ends, which is the whole reason the contract has EOF as well as CLOSE.
    client.shutdownWrite()
    XCTAssertEqual(try client.read(1, timeout: 10), Data())
  }

  /// A dead port: the agent's `connect` refusal carries the OS's own text, and the accepted socket
  /// closes rather than waiting for a forward that will never open.
  func testTheRealAgentReportsAConnectionRefusedForADeadPort() async throws {
    // Bound then released, so nothing is listening on it and the kernel is unlikely to hand it out
    // again within the test.
    let dead = try EchoServer()
    let port = dead.port
    dead.stop()

    let connection = try await realAgent()
    let failures = Failures()
    let forward = try listen(connection, to: port, failures: failures)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1, timeout: 10), Data(), "the accepted socket must be closed")
    eventually("the agent's refusal never surfaced") { !failures.all.isEmpty }
    let detail = try XCTUnwrap(failures.all.first)
    XCTAssertTrue(
      detail.lowercased().contains("refused"), "expected a connect refusal, got \(detail)")
  }
}

/// The model behind the Ports row, against a scripted agent and a connection stream the test
/// drives. Everything a live agent would do is behind `Transport`, the way `WakefulnessModel` is
/// tested.
@MainActor
final class PortForwardingModelTests: XCTestCase {
  private var fakes: [FakeAgent] = []
  private var connections: [AgentVCSConnection] = []
  private var continuation: AsyncStream<HostConnectionManager.Snapshot>.Continuation?

  override func tearDown() {
    continuation?.finish()
    for fake in fakes { fake.stop() }
    fakes = []
    connections = []
    super.tearDown()
  }

  private func lease() -> HostConnectionManager.Lease {
    HostConnectionManager.Lease(host: .local, generation: UUID())
  }

  /// A model whose `forwarding` answers with a service on a fresh scripted agent under `lease`, and
  /// whose connection stream is whatever the test yields.
  private func model(
    lease: HostConnectionManager.Lease,
    forwarding: (@Sendable () async throws -> (HostConnectionManager.Lease, AgentForwardService))? =
      nil,
    refusal: String? = nil, refusals: Int = .max
  ) async throws -> PortForwardingModel {
    let agent = try FakeAgent(
      version: 5, forward: true, forwardRefusal: refusal, forwardRefusals: refusals)
    fakes.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    connections.append(connection)
    let service = try connection.forwarding()
    let (stream, continuation) = AsyncStream<HostConnectionManager.Snapshot>.makeStream()
    self.continuation = continuation
    continuation.yield(HostConnectionManager.Snapshot(lease: lease, status: .connected))
    return PortForwardingModel(
      transport: .init(
        forwarding: forwarding ?? { (lease, service) },
        updates: { stream }))
  }

  private func settle(
    _ message: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), message, file: file, line: line)
  }

  func testAnInvalidDraftIsRefusedWithoutAListener() async throws {
    let model = try await model(lease: lease())
    for draft in ["", "0", "65536", "abc", "-1"] {
      model.draft = draft
      await model.add()
      XCTAssertEqual(model.message, "Enter a port between 1 and 65535.", "draft \(draft)")
      XCTAssertTrue(model.forwards.isEmpty)
    }
  }

  func testAddingBindsAListenerAndRemovingUnbindsIt() async throws {
    let model = try await model(lease: lease())
    model.draft = " 5173 "
    await model.add()
    XCTAssertNil(model.message)
    XCTAssertEqual(model.draft, "", "the draft is consumed")
    let entry = try XCTUnwrap(model.forwards.first)
    XCTAssertEqual(entry.remotePort, 5173)
    XCTAssertNotEqual(entry.localPort, 0)
    let client = try TCPClient(port: entry.localPort)
    try client.write(Data("x".utf8))
    XCTAssertEqual(try client.read(1), Data("x".utf8))
    client.close()

    model.remove(entry.id)
    XCTAssertTrue(model.forwards.isEmpty)
    await settle("the listener must be gone") { listenerIsGone(entry.localPort) }
  }

  /// The listener's descriptor is closed by its source's cancel handler, a moment after `stop()`
  /// returns; a connection accepted in that moment is dropped, so "gone" is polled, not asserted.
  private func listenerIsGone(_ port: UInt16) -> Bool {
    guard let client = try? TCPClient(port: port) else { return true }
    client.close()
    return false
  }

  /// A new connected generation takes the forwards made under the old one with it, and only those:
  /// the agent closes every socket a departing connection opened, so a listener left bound would
  /// accept connections it could never carry. A snapshot naming the same lease changes nothing.
  func testAForwardIsDroppedWhenItsLeaseIsNoLongerTheConnectedOne() async throws {
    let first = lease()
    let model = try await model(lease: first)
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)
    await settle("the watch did not see the connection") { model.connected }

    continuation?.yield(HostConnectionManager.Snapshot(lease: first, status: .connected))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.forwards.count, 1, "the same lease is not a loss")

    continuation?.yield(HostConnectionManager.Snapshot(lease: lease(), status: .connected))
    await settle("the forward outlived its connection") { model.forwards.isEmpty }
    XCTAssertEqual(model.message, "The agent connection ended; forwards were closed.")
    await settle("the listener must be gone") { listenerIsGone(entry.localPort) }
    XCTAssertTrue(model.connected, "a new generation is still a connection")
  }

  func testADisconnectDropsEveryForwardAndClearsTheCaptionState() async throws {
    let current = lease()
    let model = try await model(lease: current)
    model.draft = "5173"
    await model.add()
    model.draft = "3000"
    await model.add()
    XCTAssertEqual(model.forwards.count, 2)

    continuation?.yield(HostConnectionManager.Snapshot(lease: current, status: .disconnected))
    await settle("the forwards outlived the connection") { model.forwards.isEmpty }
    XCTAssertFalse(model.connected)
  }

  /// The commonest refusal — no agent — is said in this row's words, and a `VCSError` is never
  /// shown as its Swift case.
  func testAddFailuresAreDescribedForTheRow() async throws {
    let unavailable = try await model(
      lease: lease(), forwarding: { throw RepositoryRoutingError.unavailable(.local) })
    unavailable.draft = "5173"
    await unavailable.add()
    XCTAssertEqual(
      unavailable.message, "No agent is running on this Mac. Open a workroom to start one.")

    let old = try await model(
      lease: lease(),
      forwarding: { throw VCSError.backendVersion("Agent does not support port forwarding.") })
    old.draft = "5173"
    await old.add()
    XCTAssertEqual(old.message, "Agent does not support port forwarding.")
  }

  /// A refusal on a row is a fact about one connection — the dev server was not up yet — and the
  /// next connection that opens clears it, so the row is never pinned to a stale failure.
  func testARowsFailureClearsWhenALaterConnectionOpens() async throws {
    let model = try await model(
      lease: lease(), refusal: "Connection refused (os error 61)", refusals: 1)
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)

    let refused = try TCPClient(port: entry.localPort)
    XCTAssertEqual(try refused.read(1), Data())
    refused.close()
    await settle("the refusal never reached the row") { model.forwards.first?.failure != nil }
    XCTAssertEqual(
      model.forwards.first?.failure, "Could not connect: Connection refused (os error 61)")

    let opened = try TCPClient(port: entry.localPort)
    try opened.write(Data("x".utf8))
    XCTAssertEqual(try opened.read(1), Data("x".utf8))
    opened.close()
    await settle("the open never cleared the row") { model.forwards.first?.failure == nil }
  }
}

// MARK: - Helpers

/// Refusals collected off the forward's event callback, which fires on whichever thread noticed.
final class Failures: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  private var openedCount = 0
  func add(_ event: PortForward.Event) {
    lock.withLock {
      switch event {
      case .opened: openedCount += 1
      case .failed(let detail): values.append(detail)
      }
    }
  }
  var all: [String] { lock.withLock { values } }
  var opened: Int { lock.withLock { openedCount } }
}

/// A loopback TCP echo server: echoes until its peer half-closes, then half-closes back.
final class EchoServer: @unchecked Sendable {
  let port: UInt16
  private let listener: Int32

  init() throws {
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
    guard bound == 0, Darwin.listen(listener, 8) == 0 else {
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
    DispatchQueue.global().async {
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
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
  }

  func stop() { Darwin.close(listener) }
}

/// A loopback TCP client for the tests, with timeouts so a broken forward fails rather than hangs.
final class TCPClient: @unchecked Sendable {
  private let descriptor: Int32
  private let lock = NSLock()
  private var closed = false

  init(port: UInt16, receiveBuffer: Int? = nil) throws {
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

  func write(_ data: Data) throws {
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
  func read(_ count: Int, timeout: TimeInterval = 5) throws -> Data {
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

  func shutdownWrite() { _ = Darwin.shutdown(descriptor, SHUT_WR) }

  func close() {
    let already = lock.withLock { () -> Bool in
      if closed { return true }
      closed = true
      return false
    }
    guard !already else { return }
    Darwin.close(descriptor)
  }
}
