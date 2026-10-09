import CryptoKit
import Darwin
import XCTest

@testable import Workroom

/// The reverse direction of `Service::Forward` from the app's side, against the real agent: a port
/// on the agent's box carried back to this Mac (`ReverseForward`), the Debug registry that keeps one
/// open per remote workroom (`BrokerReverseForwards`), and a Debug enrolment through it end to end.
///
/// The agent runs on this Mac here, so "the agent's box" and "this Mac" share a loopback: a
/// connection to the listener's port is what a process on a remote host would make, and the
/// target is a server only the app's side of the forward knows about. No Codaset is involved: the
/// broker is `StubBroker`, an HTTP responder on loopback.
final class ReverseForwardTests: XCTestCase {
  private var agents: [AgentHarness] = []
  private var connections: [AgentVCSConnection] = []
  private var reverses: [ReverseForward] = []
  private var echoes: [EchoServer] = []
  private var clients: [TCPClient] = []
  private var directories: [URL] = []

  override func tearDown() {
    for client in clients { client.close() }
    for reverse in reverses { reverse.stop() }
    for echo in echoes { echo.stop() }
    for agent in agents { agent.stop() }
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    clients = []
    reverses = []
    echoes = []
    agents = []
    connections = []
    directories = []
    super.tearDown()
  }

  // MARK: Fixtures

  private func agent() throws -> AgentHarness {
    let agent = try AgentHarness.start(environment: ProcessInfo.processInfo.environment)
    agents.append(agent)
    return agent
  }

  private func connection(to agent: AgentHarness) async throws -> AgentVCSConnection {
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

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reverse-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    directories.append(directory)
    return directory
  }

  /// A reverse forward to `target`, started, and the port the agent bound.
  private func listening(
    _ connection: AgentVCSConnection, target: UInt16, remotePort: UInt16 = 0,
    events: ReverseEvents
  ) async throws -> (ReverseForward, UInt16) {
    let reverse = try connection.forwarding().reverse(remotePort: remotePort, target: target) {
      events.add($0)
    }
    reverses.append(reverse)
    reverse.start()
    let port = try await events.listening()
    return (reverse, port)
  }

  // MARK: ReverseForward

  func testAConnectionOnTheAgentsBoxReachesTheTargetOnThisMac() async throws {
    let target = try echo()
    let events = ReverseEvents()
    let (_, port) = try await listening(
      try await connection(to: try agent()), target: target.port, events: events)

    let client = try TCPClient(port: port)
    clients.append(client)
    try client.write(Data("ping".utf8))
    XCTAssertEqual(try client.read(4), Data("ping".utf8))

    // Larger than one envelope, both ways.
    let big = Data((0..<300_000).map { UInt8($0 % 251) })
    try client.write(big)
    XCTAssertEqual(try client.read(big.count), big)
    XCTAssertTrue(events.failures.isEmpty, "\(events.failures)")
  }

  /// The process that connected learns at once, not at the agent's 5 s expiry.
  func testAnUnreachableTargetEndsTheConnectionAtOnce() async throws {
    let closed = try echo()
    let unreachable = closed.port
    closed.stop()
    let events = ReverseEvents()
    let (_, port) = try await listening(
      try await connection(to: try agent()), target: unreachable, events: events)

    let started = ContinuousClock.now
    let client = try TCPClient(port: port)
    clients.append(client)
    XCTAssertEqual(try client.read(1, timeout: 4), Data(), "the connection was not ended")
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    try await events.waitForFailure()
    XCTAssertTrue(
      events.failures.contains { $0.hasPrefix("Could not reach 127.0.0.1:\(unreachable)") },
      "\(events.failures)")
  }

  func testStoppingReleasesTheAgentsPort() async throws {
    let target = try echo()
    let events = ReverseEvents()
    let (reverse, port) = try await listening(
      try await connection(to: try agent()), target: target.port, events: events)

    reverse.stop()

    let deadline = ContinuousClock.now + .seconds(5)
    while (try? TCPClient(port: port)).map({ $0.close() }) != nil {
      guard ContinuousClock.now < deadline else { return XCTFail("the agent kept listening") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  func testATakenPortStopsTheListenerWithTheReason() async throws {
    let taken = try echo()
    let events = ReverseEvents()
    let reverse = try await connection(to: try agent()).forwarding().reverse(
      remotePort: taken.port, target: taken.port
    ) { events.add($0) }
    reverses.append(reverse)
    reverse.start()

    do {
      _ = try await events.listening()
      XCTFail("the agent listened on a taken port")
    } catch let refusal as ReverseForward.Refusal {
      XCTAssertTrue(refusal.detail.hasPrefix("bind:"), refusal.detail)
    }
  }

  // MARK: BrokerReverseForwards

  func testTheAgentsPortIsStablePerWorkroomAndClearOfTheEphemeralRange() {
    let workroom = UUID()
    let port = BrokerReverseForwards.port(for: workroom)
    XCTAssertEqual(port, BrokerReverseForwards.port(for: workroom))
    XCTAssertTrue((40_000..<50_000).contains(port), "\(port)")
    XCTAssertEqual(
      BrokerReverseForwards.agentURL(for: workroom).absoluteString, "http://127.0.0.1:\(port)")
    XCTAssertTrue(BrokerEndpoint.allows(BrokerReverseForwards.agentURL(for: workroom)))
  }

  /// The listener goes with its connection, and the next connection to the host gets it back on the
  /// same port: the URL in the agent's `broker.json` must survive a reattach.
  @MainActor
  func testTheRegistryReopensTheListenerOnTheSamePortAfterAReconnect() async throws {
    let target = try echo()
    let agent = try agent()
    let host = HostID.remote(UUID())
    let current = Current(
      lease: .init(host: host, generation: UUID()), connection: try await connection(to: agent))
    let (updates, announce) = AsyncStream.makeStream(of: HostConnectionManager.Snapshot.self)
    let registry = BrokerReverseForwards(
      transport: .init(
        forwarding: { _ in
          let (lease, connection) = current.get()
          return (lease, try connection.forwarding())
        },
        updates: { _ in updates }),
      target: { target.port })
    let workroom = UUID()

    let url = try await registry.open(workroom: workroom, host: host)
    XCTAssertEqual(url, BrokerReverseForwards.agentURL(for: workroom))
    let port = BrokerReverseForwards.port(for: workroom)
    try roundTrip(port)

    // A new connection replaces the old one, which takes the agent's listener with it.
    let first = current.get().connection
    let second = HostConnectionManager.Lease(host: host, generation: UUID())
    current.set(second, try await connection(to: agent))
    await first.close()
    announce.yield(.init(lease: second, status: .connected))

    let deadline = ContinuousClock.now + .seconds(5)
    while !registry.isOpen(workroom, on: second) {
      guard ContinuousClock.now < deadline else { return XCTFail("the listener was not reopened") }
      try await Task.sleep(for: .milliseconds(50))
    }
    try roundTrip(port)
    registry.close(workroom: workroom)
  }

  /// The port on this Mac can move on the same connection (the credential relay listening again,
  /// #309): the next open carries the workroom's listener to the new one rather than keeping the
  /// old, which nothing answers any more.
  @MainActor
  func testAnOpenAfterTheTargetMovesCarriesToTheNewTarget() async throws {
    let first = try echo()
    let second = try echo()
    let agent = try agent()
    let host = HostID.remote(UUID())
    let current = Current(
      lease: .init(host: host, generation: UUID()), connection: try await connection(to: agent))
    let target = Target(first.port)
    let registry = ReverseForwardRegistry(
      transport: .init(
        forwarding: { _ in
          let (lease, connection) = current.get()
          return (lease, try connection.forwarding())
        },
        updates: { _ in AsyncStream { _ in } }),
      port: { BrokerReverseForwards.port(for: $0) }, target: { target.get() },
      failure: { HostDriverError.provisioning($0) })
    let workroom = UUID()
    let port = BrokerReverseForwards.port(for: workroom)
    try await registry.open(workroom: workroom, host: host)
    try roundTrip(port)

    target.set(second.port)
    first.stop()
    try await registry.open(workroom: workroom, host: host)
    try roundTrip(port)
    registry.close(workroom: workroom)
  }

  /// A link lost without a goodbye: the old connection's listener still holds the port when the new
  /// connection asks, for longer than a bind is retried. The registry keeps trying on the new
  /// connection, and gets the port once the old one lets it go.
  @MainActor
  func testAReconnectWhileTheOldListenerHoldsThePortReopensOnceItLetsGo() async throws {
    let target = try echo()
    let agent = try agent()
    let host = HostID.remote(UUID())
    let current = Current(
      lease: .init(host: host, generation: UUID()), connection: try await connection(to: agent))
    let (updates, announce) = AsyncStream.makeStream(of: HostConnectionManager.Snapshot.self)
    let registry = BrokerReverseForwards(
      transport: .init(
        forwarding: { _ in
          let (lease, connection) = current.get()
          return (lease, try connection.forwarding())
        },
        updates: { _ in updates }),
      target: { target.port }, reopenRetry: .milliseconds(300))
    let workroom = UUID()
    _ = try await registry.open(workroom: workroom, host: host)

    // A listener the registry does not own holds the port, as the old connection's does when the
    // link died without a goodbye: no CLOSE from this side can reach it.
    let port = BrokerReverseForwards.port(for: workroom)
    let stale = current.get().connection
    await stale.close()
    let holder = try await connection(to: agent)
    var held: ReverseForward?
    let deadlineToHold = ContinuousClock.now + .seconds(5)
    while held == nil {
      // The agent releases the closed connection's listener within its accept poll.
      guard ContinuousClock.now < deadlineToHold else { return XCTFail("could not hold the port") }
      let attempt = ReverseEvents()
      let forward = try holder.forwarding().reverse(remotePort: port, target: target.port) {
        attempt.add($0)
      }
      forward.start()
      reverses.append(forward)
      if (try? await attempt.listening()) != nil { held = forward } else { forward.stop() }
    }
    let second = HostConnectionManager.Lease(host: host, generation: UUID())
    current.set(second, try await connection(to: agent))
    announce.yield(.init(lease: second, status: .connected))
    // Longer than the bind retries (10 × 200 ms), so only the registry's own retry can recover.
    try await Task.sleep(for: .seconds(3))
    XCTAssertFalse(registry.isOpen(workroom, on: second), "the port was never contended")

    held?.stop()
    let deadline = ContinuousClock.now + .seconds(5)
    while !registry.isOpen(workroom, on: second) {
      guard ContinuousClock.now < deadline else { return XCTFail("never reopened") }
      try await Task.sleep(for: .milliseconds(50))
    }
    try roundTrip(port)
    registry.close(workroom: workroom)
  }

  private func roundTrip(_ port: UInt16) throws {
    let client = try TCPClient(port: port)
    clients.append(client)
    try client.write(Data("hello".utf8))
    XCTAssertEqual(try client.read(5), Data("hello".utf8))
  }

  // MARK: Enrolment, end to end

  /// A Debug enrolment hands the agent its own loopback, never this Mac's URL, and the agent's
  /// request reaches the broker on this Mac through the reverse forward, with its proof bound to the
  /// URL the agent was given.
  @MainActor
  func testADebugEnrolmentReachesTheBrokerOnThisMacThroughTheAgentsOwnLoopback() async throws {
    let broker = try StubBroker()
    defer { broker.stop() }
    let agent = try agent()
    let host = HostID.remote(UUID())
    let lease = HostConnectionManager.Lease(host: host, generation: UUID())
    let connection = try await connection(to: agent)
    let registry = BrokerReverseForwards(
      transport: .init(
        forwarding: { _ in (lease, try connection.forwarding()) },
        updates: { _ in AsyncStream { $0.yield(.init(lease: lease, status: .connected)) } }),
      target: { broker.port })
    // The agent writes `broker.json` beside its own binary and runs `git config --global`, so it
    // runs as a copy, under a throwaway HOME.
    let home = try temporaryDirectory()
    let binary = home.appendingPathComponent("wr-agent")
    try FileManager.default.copyItem(at: try AgentHarness.binaryURL(), to: binary)
    BrokerStub.reset([
      .init(
        status: 201,
        body: #"{"grant_id":"g1","enrolment_code":"one-time","repository_id":1,"expires_at":"x"}"#)
    ])
    let client = BrokerClient(
      baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey()),
      session: BrokerStub.session)
    let workroom = UUID()

    let grant = try await AgentEnrolment.enrol(
      client: client, driver: ShellDriver(home: home), host: host, agentBinary: binary.path,
      workroomID: workroom, repository: "o/r",
      agentBroker: .init(
        url: { _, workroom, host in try await registry.open(workroom: workroom, host: host) },
        release: { workroom in await registry.close(workroom: workroom) }))

    XCTAssertEqual(grant, "g1")
    let url = BrokerReverseForwards.agentURL(for: workroom).absoluteString
    let request = try XCTUnwrap(broker.requests.first)
    XCTAssertEqual(request.line, "POST /broker/enrolments HTTP/1.1")
    XCTAssertEqual(request.header("host"), url.replacingOccurrences(of: "http://", with: ""))
    let proof = try XCTUnwrap(request.header("dpop"))
    XCTAssertEqual(jwtClaims(proof)["htu"] as? String, url + "/broker/enrolments")
    let state =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: home.appendingPathComponent("broker.json"))) as? [String: Any]
    XCTAssertEqual(state?["broker"] as? String, url)
    XCTAssertEqual(state?["enrolled"] as? Bool, true)
    registry.close(workroom: workroom)
  }

  private func jwtClaims(_ token: String) -> [String: Any] {
    let part = String(token.split(separator: ".")[1])
    var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let data = Data(base64Encoded: base64) ?? Data()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}

/// The connection a registry's transport hands out, switched by the test to simulate a reconnect.
private final class Current: @unchecked Sendable {
  private let lock = NSLock()
  private var lease: HostConnectionManager.Lease
  private var connection: AgentVCSConnection
  init(lease: HostConnectionManager.Lease, connection: AgentVCSConnection) {
    self.lease = lease
    self.connection = connection
  }
  func get() -> (lease: HostConnectionManager.Lease, connection: AgentVCSConnection) {
    lock.withLock { (lease, connection) }
  }
  func set(_ lease: HostConnectionManager.Lease, _ connection: AgentVCSConnection) {
    lock.withLock {
      self.lease = lease
      self.connection = connection
    }
  }
}

private final class Target: @unchecked Sendable {
  private let lock = NSLock()
  private var port: UInt16
  init(_ port: UInt16) { self.port = port }
  func get() -> UInt16 { lock.withLock { port } }
  func set(_ port: UInt16) { lock.withLock { self.port = port } }
}

/// A reverse forward's events, with the first answer to its `listen` awaitable.
final class ReverseEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ReverseForward.Event] = []

  func add(_ event: ReverseForward.Event) { lock.withLock { values.append(event) } }

  var failures: [String] {
    lock.withLock {
      values.compactMap { if case .failed(let detail) = $0 { detail } else { nil } }
    }
  }

  /// The bound port, or the refusal the listener stopped with.
  func listening(timeout: Duration = .seconds(5)) async throws -> UInt16 {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      for event in lock.withLock({ values }) {
        switch event {
        case .listening(let port): return port
        case .stopped(let detail): throw ReverseForward.Refusal(detail)
        case .failed: continue
        }
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw ReverseForward.Refusal("no answer to listen")
  }

  func waitForFailure(timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while failures.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// Runs every exec on this Mac with `/bin/sh`, under `home`, as the remote host's shell would.
private final class ShellDriver: HostDriver, @unchecked Sendable {
  let traits = HostDriverTraits(
    transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
    durableDisk: false, maxLifetime: nil)
  let home: URL
  init(home: URL) { self.home = home }

  func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
  func deriveFromBase(_ base: HostID) async throws -> HostID {
    throw HostDriverError.notImplemented("derive")
  }
  func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
  func openStream(to host: HostID) async throws -> HostStream {
    throw HostDriverError.notImplemented("openStream")
  }
  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", command],
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], handshakeTimeout: 5,
      purpose: .exchange)
  }
}

/// A broker on this Mac's loopback: answers every request with an enrolment, and records each
/// request's line and headers.
final class StubBroker: @unchecked Sendable {
  struct Request {
    let line: String
    let headers: [String: String]
    func header(_ name: String) -> String? { headers[name.lowercased()] }
  }

  let port: UInt16
  private let listener: Int32
  private let lock = NSLock()
  private var seen: [Request] = []

  var requests: [Request] { lock.withLock { seen } }

  init() throws {
    guard let (listener, port) = LoopbackSocket.listen() else {
      throw NSError(domain: "StubBroker", code: Int(errno))
    }
    self.listener = listener
    self.port = port
    DispatchQueue.global().async { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        DispatchQueue.global().async { self?.serve(client) }
      }
    }
  }

  func stop() { Darwin.close(listener) }

  private func serve(_ client: Int32) {
    defer { Darwin.close(client) }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    // Headers, then as much body as Content-Length says.
    while true {
      if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let line = lines.removeFirst()
        var headers: [String: String] = [:]
        for header in lines {
          let parts = header.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
          }
          if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while bytes.count - end.upperBound < length {
          let count = buffer.withUnsafeMutableBytes {
            Darwin.read(client, $0.baseAddress, $0.count)
          }
          guard count > 0 else { return }
          bytes.append(contentsOf: buffer[0..<count])
        }
        lock.withLock { seen.append(Request(line: line, headers: headers)) }
        let body = #"{"grant_id":"g1"}"#
        let response =
          "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"
          + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { Darwin.send(client, $0, strlen($0), 0) }
        return
      }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress, $0.count) }
      guard count > 0 else { return }
      bytes.append(contentsOf: buffer[0..<count])
    }
  }
}

/// Where a Debug build carries its agents' broker requests (#253): the port Caddy routes the
/// broker's host to, since `bin/dev` gives Puma a free port each start.
final class DevelopmentCodasetTests: XCTestCase {
  /// The shape Caddy's admin API answers with (`/config/apps/http/servers`), trimmed from a real
  /// one: other apps' routes first, a route matching a longer name of the same suffix, and the
  /// upstream nested in a subroute.
  private static let servers = Data(
    """
    {"srv0": {"listen": [":443"], "routes": [
      {"match": [{"host": ["bert.localhost", "*.bert.localhost"]}],
       "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": ":55849"}]}]},
      {"match": [{"host": ["sc-cooled-fermion-858a-codaset.localhost"]}],
       "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": ":62886"}]}]},
      {"match": [{"host": ["codaset.localhost", "*.codaset.localhost"]}],
       "handle": [{"handler": "subroute", "routes": [{"handle": [
         {"handler": "reverse_proxy", "upstreams": [{"dial": "localhost:61938"}]}]}]}]}
    ]}}
    """.utf8)

  func testTheBrokersHostResolvesToItsOwnUpstreamPort() {
    XCTAssertEqual(
      DevelopmentCodaset.upstreamPort(for: "codaset.localhost", inServers: Self.servers), 61938)
    XCTAssertEqual(
      DevelopmentCodaset.upstreamPort(for: "bert.localhost", inServers: Self.servers), 55849)
  }

  func testAHostCaddyDoesNotRouteHasNoPort() {
    XCTAssertNil(DevelopmentCodaset.upstreamPort(for: "nope.localhost", inServers: Self.servers))
    XCTAssertNil(
      DevelopmentCodaset.upstreamPort(for: "codaset.localhost", inServers: Data("[]".utf8)))
  }
}
