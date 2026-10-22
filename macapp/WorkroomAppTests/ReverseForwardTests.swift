import DaemonConnection
import Darwin
import HostDrivers
import WorkroomVCS
import XCTest

@testable import Workroom

/// The reverse direction of `Service::Forward` from the app's side, against the real daemon: a port
/// on the daemon's box carried back to this Mac (`ReverseForward`), and the registry that keeps one
/// open per workroom across reconnects (`ReverseForwardRegistry`), which the credential relay
/// rides (#309).
///
/// The daemon runs on this Mac here, so "the daemon's box" and "this Mac" share a loopback: a
/// connection to the listener's port is what a process on a remote host would make, and the
/// target is a server only the app's side of the forward knows about.
final class ReverseForwardTests: XCTestCase {
  private var daemons: [DaemonHarness] = []
  private var connections: [DaemonVCSConnection] = []
  private var reverses: [ReverseForward] = []
  private var echoes: [EchoServer] = []
  private var clients: [TCPClient] = []
  private var directories: [URL] = []

  override func tearDown() {
    for client in clients { client.close() }
    for reverse in reverses { reverse.stop() }
    for echo in echoes { echo.stop() }
    for daemon in daemons { daemon.stop() }
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    clients = []
    reverses = []
    echoes = []
    daemons = []
    connections = []
    directories = []
    super.tearDown()
  }

  // MARK: Fixtures

  private func daemon() throws -> DaemonHarness {
    let daemon = try DaemonHarness.start(environment: ProcessInfo.processInfo.environment)
    daemons.append(daemon)
    return daemon
  }

  private func connection(to daemon: DaemonHarness) async throws -> DaemonVCSConnection {
    let connection = try await DaemonVCSConnection.connect(
      host: .local, socketPath: daemon.socketPath)
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

  /// A reverse forward to `target`, started, and the port the daemon bound.
  private func listening(
    _ connection: DaemonVCSConnection, target: UInt16, remotePort: UInt16 = 0,
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

  func testAConnectionOnTheDaemonsBoxReachesTheTargetOnThisMac() async throws {
    let target = try echo()
    let events = ReverseEvents()
    let (_, port) = try await listening(
      try await connection(to: try daemon()), target: target.port, events: events)

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

  /// The process that connected learns at once, not at the daemon's 5 s expiry.
  func testAnUnreachableTargetEndsTheConnectionAtOnce() async throws {
    let closed = try echo()
    let unreachable = closed.port
    closed.stop()
    let events = ReverseEvents()
    let (_, port) = try await listening(
      try await connection(to: try daemon()), target: unreachable, events: events)

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

  func testStoppingReleasesTheDaemonsPort() async throws {
    let target = try echo()
    let events = ReverseEvents()
    let (reverse, port) = try await listening(
      try await connection(to: try daemon()), target: target.port, events: events)

    reverse.stop()

    let deadline = ContinuousClock.now + .seconds(5)
    while (try? TCPClient(port: port)).map({ $0.close() }) != nil {
      guard ContinuousClock.now < deadline else { return XCTFail("the daemon kept listening") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  func testATakenPortStopsTheListenerWithTheReason() async throws {
    let taken = try echo()
    let events = ReverseEvents()
    let reverse = try await connection(to: try daemon()).forwarding().reverse(
      remotePort: taken.port, target: taken.port
    ) { events.add($0) }
    reverses.append(reverse)
    reverse.start()

    do {
      _ = try await events.listening()
      XCTFail("the daemon listened on a taken port")
    } catch let refusal as ReverseForward.Refusal {
      XCTAssertTrue(refusal.detail.hasPrefix("bind:"), refusal.detail)
    }
  }

  // MARK: ReverseForwardRegistry

  /// A registry over `current`'s connection, its updates from `updates`, carrying to `target`.
  @MainActor
  private func makeRegistry(
    _ current: Current, updates: AsyncStream<HostConnectionManager.Snapshot>,
    target: @escaping @Sendable () -> UInt16, reopenRetry: Duration = .seconds(5)
  ) -> ReverseForwardRegistry {
    ReverseForwardRegistry(
      transport: .init(
        forwarding: { _ in
          let (lease, connection) = current.get()
          return (lease, try connection.forwarding())
        },
        updates: { _ in updates }),
      port: { CredentialRelay.port(for: $0) }, target: target,
      failure: { HostDriverError.provisioning($0) }, reopenRetry: reopenRetry)
  }

  /// The listener goes with its connection, and the next connection to the host gets it back on the
  /// same port: the port in the daemon's `relay.json` must survive a reattach.
  @MainActor
  func testTheRegistryReopensTheListenerOnTheSamePortAfterAReconnect() async throws {
    let target = try echo()
    let daemon = try daemon()
    let host = HostID.remote(UUID())
    let current = Current(
      lease: .init(host: host, generation: UUID()), connection: try await connection(to: daemon))
    let (updates, announce) = AsyncStream.makeStream(of: HostConnectionManager.Snapshot.self)
    let registry = makeRegistry(current, updates: updates, target: { target.port })
    let workroom = UUID()

    try await registry.open(workroom: workroom, host: host)
    let port = CredentialRelay.port(for: workroom)
    try roundTrip(port)

    // A new connection replaces the old one, which takes the daemon's listener with it.
    let first = current.get().connection
    let second = HostConnectionManager.Lease(host: host, generation: UUID())
    current.set(second, try await connection(to: daemon))
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
    let daemon = try daemon()
    let host = HostID.remote(UUID())
    let current = Current(
      lease: .init(host: host, generation: UUID()), connection: try await connection(to: daemon))
    let target = Target(first.port)
    let registry = makeRegistry(current, updates: AsyncStream { _ in }, target: { target.get() })
    let workroom = UUID()
    let port = CredentialRelay.port(for: workroom)
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
    let daemon = try daemon()
    let host = HostID.remote(UUID())
    let current = Current(
      lease: .init(host: host, generation: UUID()), connection: try await connection(to: daemon))
    let (updates, announce) = AsyncStream.makeStream(of: HostConnectionManager.Snapshot.self)
    let registry = makeRegistry(
      current, updates: updates, target: { target.port }, reopenRetry: .milliseconds(300))
    let workroom = UUID()
    try await registry.open(workroom: workroom, host: host)

    // A listener the registry does not own holds the port, as the old connection's does when the
    // link died without a goodbye: no CLOSE from this side can reach it.
    let port = CredentialRelay.port(for: workroom)
    let stale = current.get().connection
    await stale.close()
    let holder = try await connection(to: daemon)
    var held: ReverseForward?
    let deadlineToHold = ContinuousClock.now + .seconds(5)
    while held == nil {
      // The daemon releases the closed connection's listener within its accept poll.
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
    current.set(second, try await connection(to: daemon))
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
}

/// The connection a registry's transport hands out, switched by the test to simulate a reconnect.
private final class Current: @unchecked Sendable {
  private let lock = NSLock()
  private var lease: HostConnectionManager.Lease
  private var connection: DaemonVCSConnection
  init(lease: HostConnectionManager.Lease, connection: DaemonVCSConnection) {
    self.lease = lease
    self.connection = connection
  }
  func get() -> (lease: HostConnectionManager.Lease, connection: DaemonVCSConnection) {
    lock.withLock { (lease, connection) }
  }
  func set(_ lease: HostConnectionManager.Lease, _ connection: DaemonVCSConnection) {
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
