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
  private func listen(_ connection: AgentVCSConnection, to remotePort: UInt16, failures: Failures)
    throws -> PortForward
  {
    let forward = try connection.forwarding().listen(remotePort: remotePort) { failures.add($0) }
    forwards.append(forward)
    return forward
  }

  private func connect(to forward: PortForward) throws -> TCPClient {
    let client = try TCPClient(port: forward.localPort)
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
    // The fake WOULD answer a Forward envelope — it just never gets one, which is the whole point:
    // a real protocol-4 agent would drop it in silence and hang the forward.
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
    XCTAssertEqual(failures.all.first, "Connection refused (os error 61)")
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

// MARK: - Helpers

/// Refusals collected off the forward's error callback, which fires on whichever thread noticed.
final class Failures: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
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

  init(port: UInt16) throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: "TCPClient", code: Int(errno)) }
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
