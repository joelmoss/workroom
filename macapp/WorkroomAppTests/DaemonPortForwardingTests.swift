import DaemonConnection
import DaemonConnectionTestSupport
import Darwin
import DevContainer
import Synchronization
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// `Service::Forward` from the app's side (issue #208), hosted for what needs the app or the built
/// daemon: the **real daemon** (`DaemonHarness`) proves the framing against the shipped Rust and
/// carries real bytes through a real socket — the one thing the Rust tests structurally cannot
/// cover, because they have no Swift client — and the app's connection protocol is shown to reach
/// the package's service.
///
/// The scripted half (the version gate, the opcode framing, and every way a forwarded connection
/// can end, against a `FakeDaemon`) runs under `swift test` in DaemonConnection, as
/// `DaemonForwardServiceTests`.
final class DaemonPortForwardingTests: XCTestCase {
  private var daemons: [DaemonHarness] = []
  private var fakes: [FakeDaemon] = []
  private var connections: [DaemonClient] = []
  private var forwards: [PortForward] = []
  private var echoes: [EchoServer] = []
  private var clients: [TCPClient] = []

  override func tearDown() {
    for client in clients { client.close() }
    for forward in forwards { forward.stop() }
    for echo in echoes { echo.stop() }
    for daemon in daemons { daemon.stop() }
    for fake in fakes { fake.stop() }
    clients = []
    forwards = []
    echoes = []
    daemons = []
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

  private func realDaemon() async throws -> DaemonClient {
    let daemon = try DaemonHarness.start(environment: ProcessInfo.processInfo.environment)
    daemons.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
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

  // MARK: The app's conformance

  /// `forwarding()` lives in DaemonConnection with the service it builds, and the app's
  /// `HostServiceConnection` conformance takes it as the witness. The protocol's own default, which
  /// throws "no port-forwarding service", must not win: every forward the app opens asks through
  /// the protocol (`HostConnectionManager.forwarding(host:)`). Through it, a current daemon carries
  /// bytes and an old one is refused by the version gate, not by the default.
  func testTheProtocolReachesTheDaemonsForwardService() async throws {
    let old: any HostServiceConnection = try await fake(FakeDaemon(version: 4, forward: true))
    XCTAssertThrowsError(try old.forwarding()) { error in
      guard case VCSError.backendVersion = error else {
        return XCTFail("expected backendVersion, got \(error)")
      }
    }
    let current: any HostServiceConnection = try await fake(FakeDaemon(version: 5, forward: true))
    let forward = try current.forwarding().listen(remotePort: 5173) { _ in }
    forwards.append(forward)
    let client = try connect(to: forward)
    try client.write(Data("x".utf8))
    XCTAssertEqual(try client.read(1), Data("x".utf8))
  }

  // MARK: The shipped daemon

  /// The whole path against the binary that ships: the Swift opcode framing, the daemon's
  /// `Service::Forward`, and a real loopback socket on the other side. The payload is larger than one
  /// envelope, so the client's chunking is exercised rather than assumed.
  func testTheRealDaemonForwardsBytesBothWaysThroughARealSocket() async throws {
    let server = try echo()
    let connection = try await realDaemon()
    let forward = try listen(connection, to: server.port, failures: Failures())
    XCTAssertNotEqual(forward.localPort, server.port, "the local port must be ephemeral")
    let client = try connect(to: forward)

    // 1.5 MB: past `MAX_ENVELOPE_PAYLOAD` (1 MiB) and far past the 64 KiB read size, so this crosses
    // many DATA envelopes rather than assuming the chunking works. Written on another queue while
    // this thread reads, because an echo of this size fills both directions' socket buffers long
    // before the write finishes. Comfortably under the daemon's 2 MiB per-forward queue budget, which
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

  /// A dead port: the daemon's `connect` refusal carries the OS's own text, and the accepted socket
  /// closes rather than waiting for a forward that will never open.
  func testTheRealDaemonReportsAConnectionRefusedForADeadPort() async throws {
    // Bound then released, so nothing is listening on it and the kernel is unlikely to hand it out
    // again within the test.
    let dead = try EchoServer()
    let port = dead.port
    dead.stop()

    let connection = try await realDaemon()
    let failures = Failures()
    let forward = try listen(connection, to: port, failures: failures)
    let client = try connect(to: forward)

    XCTAssertEqual(try client.read(1, timeout: 10), Data(), "the accepted socket must be closed")
    eventually("the daemon's refusal never surfaced") { !failures.all.isEmpty }
    let detail = try XCTUnwrap(failures.all.first)
    XCTAssertTrue(
      detail.lowercased().contains("refused"), "expected a connect refusal, got \(detail)")
  }
}

/// The model behind the Ports row, against a scripted daemon and a connection stream the test
/// drives. Everything a live daemon would do is behind `Transport`.
@MainActor
final class PortForwardingModelTests: XCTestCase {
  private var fakes: [FakeDaemon] = []
  private var connections: [DaemonClient] = []
  private var continuation: AsyncStream<HostConnectionManager.Snapshot>.Continuation?
  /// What the manager would answer for the connected lease right now; `publish` keeps it in step
  /// with the stream, and a test can move it ahead of the stream to model a watch that lags.
  private let current = CurrentLease()

  private var models: [PortForwardingModel] = []

  private func publish(_ snapshot: HostConnectionManager.Snapshot) {
    current.set(snapshot.status == .connected ? snapshot.lease : nil)
    continuation?.yield(snapshot)
  }

  override func tearDown() async throws {
    continuation?.finish()
    // Every listener a test left bound is stopped here, not left to ARC.
    for model in models { for entry in model.forwards { model.remove(entry.id) } }
    models = []
    for fake in fakes { fake.stop() }
    fakes = []
    connections = []
    try await super.tearDown()
  }

  private func lease() -> HostConnectionManager.Lease {
    HostConnectionManager.Lease(host: .local, generation: UUID())
  }

  /// A model whose `forwarding` answers with a service on a fresh scripted daemon under `lease`, and
  /// whose connection stream is whatever the test yields.
  private func model(
    lease: HostConnectionManager.Lease,
    forwarding: (
      @Sendable () async throws -> (HostConnectionManager.Lease, DaemonForwardService)
    )? =
      nil,
    refusal: String? = nil, refusals: Int = .max,
    current override: (@Sendable () async -> HostConnectionManager.Lease?)? = nil,
    reconnect: PortForward.Reconnect? = nil, sameLocalPort: Bool = false
  ) async throws -> PortForwardingModel {
    let daemon = try FakeDaemon(
      version: 5, forward: true, forwardRefusal: refusal, forwardRefusals: refusals)
    fakes.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    let service = try connection.forwarding()
    let (stream, continuation) = AsyncStream<HostConnectionManager.Snapshot>.makeStream()
    self.continuation = continuation
    current.set(lease)
    continuation.yield(HostConnectionManager.Snapshot(lease: lease, status: .connected))
    let current = self.current
    let model = PortForwardingModel(
      transport: .init(
        forwarding: forwarding ?? { (lease, service) },
        updates: { stream },
        current: override ?? { current.get() },
        reconnect: reconnect),
      sameLocalPort: sameLocalPort)
    models.append(model)
    return model
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
  /// the daemon closes every socket a departing connection opened, so a listener left bound would
  /// accept connections it could never carry. A snapshot naming the same lease changes nothing.
  func testAForwardIsDroppedWhenItsLeaseIsNoLongerTheConnectedOne() async throws {
    let first = lease()
    let model = try await model(lease: first)
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)
    await settle("the watch did not see the connection") { model.connected }

    publish(HostConnectionManager.Snapshot(lease: first, status: .connected))
    await settle("the second snapshot was not consumed") { model.snapshotsSeen >= 2 }
    XCTAssertEqual(model.forwards.count, 1, "the same lease is not a loss")

    publish(HostConnectionManager.Snapshot(lease: lease(), status: .connected))
    await settle("the forward outlived its connection") { model.forwards.isEmpty }
    XCTAssertEqual(model.message, "The daemon connection ended; forwards were closed.")
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

    publish(HostConnectionManager.Snapshot(lease: current, status: .disconnected))
    await settle("the forwards outlived the connection") { model.forwards.isEmpty }
    XCTAssertFalse(model.connected)
  }

  /// A forward on a remote host (#380) outlives its connection: its row and its
  /// local port stay, the caption says it reconnects on use, and a connection made to it then
  /// reconnects and is carried on the new connection, without the user adding it again.
  func testAForwardThatReconnectsOutlivesItsConnectionAndCarriesOnTheNext() async throws {
    let next = try FakeDaemon(version: 5, forward: true)
    fakes.append(next)
    let reconnects = Counter()
    // Kept off the main actor: the test blocks it in a synchronous read while this runs.
    let made = Made()
    let first = lease()
    let model = try await model(
      lease: first,
      reconnect: {
        reconnects.bump()
        let connection = try? await DaemonClient.connect(
          host: .local, socketPath: next.socketPath)
        made.keep(connection)
        return connection
      })
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)
    XCTAssertTrue(entry.reconnects)
    await settle("the watch did not see the connection") { model.connected }

    // Value: protects=a reconnecting forward uses its connection while it lives and reconnects only once it has
    // ended; fails_when=PortForward.begin reconnects for every client; why_new=the cases below start after the
    // loss, so only they ran the reconnect; seam=none
    let live = try TCPClient(port: entry.localPort)
    try live.write(Data("a".utf8))
    XCTAssertEqual(try live.read(1), Data("a".utf8), "not carried on the live connection")
    live.close()
    XCTAssertEqual(reconnects.count, 0, "a live connection was replaced for a new one")

    await connections[0].close()
    publish(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the watch did not see the disconnect") { !model.connected }
    XCTAssertEqual(model.forwards.map(\.id), [entry.id], "the row went with its connection")
    XCTAssertNil(model.message)
    XCTAssertEqual(reconnects.count, 0, "nothing reconnects before the forward is used")

    let client = try TCPClient(port: entry.localPort)
    defer { client.close() }
    try client.write(Data("x".utf8))
    XCTAssertEqual(try client.read(1), Data("x".utf8), "not carried on the new connection")
    XCTAssertEqual(reconnects.count, 1)
    await made.close()
  }

  // Value: protects=a forward waiting on a reconnect holds at most ForwardSlot.maxPerConnection clients, and stop
  // closes them; fails_when=the waiting cap or stop's close of waiting clients is removed; why_new=no
  // test holds a reconnect open while clients arrive; seam=none
  /// A burst against a forward whose host is reconnecting slowly (a waking box, a hung ssh) holds at
  /// most `ForwardSlot.maxPerConnection` clients: the next is refused at once and the row says why. Removing the
  /// forward closes every client still waiting (#381 review).
  func testClientsWaitingOnAReconnectAreCappedAndClosedOnRemove() async throws {
    let first = lease()
    let model = try await model(
      lease: first,
      reconnect: {
        try? await Task.sleep(for: .seconds(30))
        return nil
      })
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)
    await connections[0].close()
    publish(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the watch did not see the disconnect") { !model.connected }

    var waiting: [TCPClient] = []
    for _ in 0..<ForwardSlot.maxPerConnection {
      waiting.append(try TCPClient(port: entry.localPort))
    }
    defer { for client in waiting { client.close() } }
    let refused = try TCPClient(port: entry.localPort)
    defer { refused.close() }
    XCTAssertEqual(
      try refused.read(1, timeout: 5), Data(), "a client past the cap was kept waiting")
    await settle("the row never said why") { model.forwards.first?.failure != nil }
    XCTAssertEqual(
      model.forwards.first?.failure,
      "Too many connections waiting for the host to reconnect; one was refused.")

    // EOF, not a read timeout, which reads empty too: each must close at once.
    model.remove(entry.id)
    for client in waiting.prefix(3) {
      let started = ContinuousClock.now
      XCTAssertEqual(try client.read(1, timeout: 3), Data())
      XCTAssertLessThan(
        ContinuousClock.now - started, .seconds(2), "a waiting client outlived its forward")
    }
  }

  /// A deleted host's forwards go with it (#381 review): its connection no longer drops them, since a
  /// remote host's forwards outlive their connection.
  func testForgettingAHostForgetsItsForwards() async throws {
    let host = HostID.remote(UUID())
    let model = try await model(lease: lease())
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)
    PortForwardingModel.models[host] = model

    PortForwardingModel.forgetHost(host)
    XCTAssertNil(PortForwardingModel.models[host], "the host's model outlived it")
    XCTAssertTrue(model.forwards.isEmpty, "the host's forwards outlived it")
    await settle("the listener must be gone") { listenerIsGone(entry.localPort) }
  }

  /// A forward whose reconnect finds no host (a container the user stopped, a box that is gone)
  /// refuses the connection and says why.
  func testAForwardWhoseReconnectFailsRefusesTheConnectionAndSaysWhy() async throws {
    let first = lease()
    let model = try await model(lease: first, reconnect: { nil })
    model.draft = "5173"
    await model.add()
    let entry = try XCTUnwrap(model.forwards.first)
    await connections[0].close()
    publish(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the watch did not see the disconnect") { !model.connected }

    let client = try TCPClient(port: entry.localPort)
    defer { client.close() }
    XCTAssertEqual(try client.read(1, timeout: 5), Data(), "a refused connection was left open")
    await settle("the row never said why") { model.forwards.first?.failure != nil }
    XCTAssertEqual(
      model.forwards.first?.failure, "Could not reconnect to the host; a connection was refused.")
  }

  private final class Made: Sendable {
    private let connections = Mutex<[DaemonClient]>([])
    func keep(_ connection: DaemonClient?) {
      guard let connection else { return }
      connections.withLock { $0.append(connection) }
    }
    func close() async {
      for connection in connections.withLock({ $0 }) { await connection.close() }
    }
  }

  private final class Counter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
  }

  /// An `add()` that resumes after the watch consumed a disconnect must not leave a row for a
  /// connection that is already gone: the watch had nothing to drop then, and will see no further
  /// snapshot to drop it by.
  func testAnAddThatOutlivesItsConnectionIsDroppedAtOnce() async throws {
    let first = lease()
    let gate = Gate()
    var captured: (HostConnectionManager.Lease, DaemonForwardService)?
    let model = try await model(lease: first) { [gate] in
      await gate.wait()
      return try await gate.held()
    }
    model.watch()
    await settle("the watch did not see the connection") { model.connected }
    // The transport that `model(lease:forwarding:)` would have used, held behind the gate.
    let daemon = try FakeDaemon(version: 5, forward: true)
    fakes.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    captured = (first, try connection.forwarding())
    await gate.hold(captured!)

    model.draft = "5173"
    let adding = Task { await model.add() }
    try await Task.sleep(for: .milliseconds(50))
    // The connection ends while `add()` is suspended acquiring the service.
    publish(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the disconnect was not consumed") { !model.connected }
    await gate.open()
    await adding.value

    XCTAssertTrue(model.forwards.isEmpty, "a row for a dead connection: \(model.forwards)")
    XCTAssertEqual(model.message, "The daemon connection ended; forwards were closed.")
  }

  /// The reverse race: `add()` resumes on the RECONNECTED lease while the watch still holds the
  /// disconnect. Reconciling against the watch's snapshot dropped a valid row; the manager's
  /// current lease keeps it.
  func testAnAddThatResumesOnAReconnectKeepsItsForward() async throws {
    let first = lease()
    let second = lease()
    let gate = Gate()
    let model = try await model(lease: first) { [gate] in
      await gate.wait()
      return try await gate.held()
    }
    model.watch()
    await settle("the watch did not see the connection") { model.connected }
    let daemon = try FakeDaemon(version: 5, forward: true)
    fakes.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    await gate.hold((second, try connection.forwarding()))

    model.draft = "5173"
    let adding = Task { await model.add() }
    try await Task.sleep(for: .milliseconds(50))
    publish(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the disconnect was not consumed") { !model.connected }
    // Reconnected: the manager knows, the watch has not been told yet.
    current.set(second)
    await gate.open()
    await adding.value

    XCTAssertEqual(model.forwards.map(\.lease), [second], "a valid forward was dropped")
    XCTAssertNil(model.message)
  }

  /// The other order: `add()` finishes on the reconnected lease FIRST, and only then does the watch
  /// receive the old disconnect. That stale snapshot must not drop the new forward.
  func testALateDisconnectDoesNotDropAForwardMadeOnTheReconnectedLease() async throws {
    let first = lease()
    let second = lease()
    let held = try await service(on: second)
    let current = self.current
    let model = try await model(lease: first) {
      // The manager already reconnected when `add()` asked.
      current.set(second)
      return held
    }
    model.watch()
    await settle("the watch did not see the connection") { model.connected }
    model.draft = "5173"
    await model.add()
    XCTAssertEqual(model.forwards.map(\.lease), [second])

    // Delivered late: the disconnect of the connection `add()` never used.
    let seen = model.snapshotsSeen
    continuation?.yield(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the late snapshot was not consumed") { model.snapshotsSeen > seen }
    XCTAssertEqual(model.forwards.map(\.lease), [second], "a stale disconnect dropped it")
    XCTAssertTrue(model.connected)
  }

  /// The watch's read answered "disconnected" before `add()` made a forward on the reconnected
  /// lease, and resumed after it. Judging the new row by that read closed a live forward.
  func testAWatchReadThatPredatesAnAddDoesNotDropItsForward() async throws {
    let first = lease()
    let second = lease()
    let held = try await service(on: second)
    let current = self.current
    let gate = Gate()
    let reads = Reads()
    let model = try await model(
      lease: first,
      forwarding: {
        current.set(second)
        return held
      },
      current: { [gate] in
        // The second read is the watch's, for the disconnect below: hold it across the add.
        guard reads.next() == 2 else { return current.get() }
        await gate.wait()
        return nil
      })
    model.watch()
    await settle("the watch did not see the connection") { model.connected }
    current.set(nil)
    continuation?.yield(HostConnectionManager.Snapshot(lease: first, status: .disconnected))
    await settle("the watch never started its read") { reads.count >= 2 }

    model.draft = "5173"
    await model.add()
    XCTAssertEqual(model.forwards.map(\.lease), [second])

    let seen = model.snapshotsSeen
    await gate.open()
    await settle("the held read never resumed") { model.snapshotsSeen > seen }
    XCTAssertEqual(model.forwards.map(\.lease), [second], "a read older than the row dropped it")
  }

  private func service(on lease: HostConnectionManager.Lease) async throws -> (
    HostConnectionManager.Lease, DaemonForwardService
  ) {
    let daemon = try FakeDaemon(version: 5, forward: true)
    fakes.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    return (lease, try connection.forwarding())
  }

  /// Two adds in flight at once (a click and a Return) make one listener, not two.
  func testASecondAddWhileOneIsInFlightIsIgnored() async throws {
    let first = lease()
    let gate = Gate()
    let model = try await model(lease: first) { [gate] in
      await gate.wait()
      return try await gate.held()
    }
    let daemon = try FakeDaemon(version: 5, forward: true)
    fakes.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    await gate.hold((first, try connection.forwarding()))

    model.draft = "5173"
    let one = Task { await model.add() }
    let two = Task { await model.add() }
    try await Task.sleep(for: .milliseconds(50))
    await gate.open()
    await one.value
    await two.value
    XCTAssertEqual(model.forwards.count, 1)
  }

  /// `describe` never shows a raw Swift case: a `LocalizedError` gives its description, and a
  /// bare error falls back to interpolation.
  func testDescribeFallsBackSensibly() {
    struct Bare: Error {}
    XCTAssertEqual(
      PortForwardingModel.describe(HostConnectionError.connectionLost),
      HostConnectionError.connectionLost.errorDescription)
    XCTAssertEqual(PortForwardingModel.describe(Bare()), "Bare()")
  }

  /// The commonest refusal — the host not connected — is said in this row's words, and a
  /// `VCSError` is never shown as its Swift case.
  func testAddFailuresAreDescribedForTheRow() async throws {
    let old = try await model(
      lease: lease(),
      forwarding: { throw VCSError.backendVersion("Daemon does not support port forwarding.") })
    old.draft = "5173"
    await old.add()
    XCTAssertEqual(old.message, "Daemon does not support port forwarding.")

    let remote = try await model(
      lease: lease(), forwarding: { throw RepositoryRoutingError.unavailable(.remote(UUID())) })
    remote.draft = "5173"
    await remote.add()
    XCTAssertEqual(remote.message, "This workroom's host is not connected.")
  }

  /// One model per host, kept: the Details pane going to another workroom and back finds its
  /// forwards where it left them, and two hosts never share a list (#254).
  func testEachHostHasItsOwnModelForTheLaunch() {
    let host = HostID.remote(UUID())
    let other = HostID.remote(UUID())
    // In a teardown block, so a failed assertion can't leave them in the shared table.
    addTeardownBlock { @MainActor in
      PortForwardingModel.models[host] = nil
      PortForwardingModel.models[other] = nil
    }
    XCTAssertTrue(PortForwardingModel.model(for: host) === PortForwardingModel.model(for: host))
    XCTAssertFalse(PortForwardingModel.model(for: host) === PortForwardingModel.model(for: other))
    XCTAssertEqual(PortForwardingModel.model(for: host).host, host)
  }

  /// A remote host's transport reads that host's connection in the manager and never another's.
  /// With only this Mac connected, a forward on the host is refused as the host's, not served by
  /// the local daemon.
  func testARemoteHostsTransportAsksForThatHostsConnection() async throws {
    let daemon = try FakeDaemon(version: 5, forward: true)
    fakes.append(daemon)
    let manager = HostConnectionManager()
    _ = try await manager.connect(host: .local) {
      try await DaemonClient.connect(host: .local, socketPath: daemon.socketPath)
    }
    let host = HostID.remote(UUID())
    let transport = PortForwardingModel.Transport.on(host, manager: manager)
    do {
      _ = try await transport.forwarding()
      XCTFail("a remote host with no connection was served")
    } catch RepositoryRoutingError.unavailable(let refused) {
      XCTAssertEqual(refused, host)
    }
    let current = await transport.current()
    XCTAssertNil(current)
    let local = await PortForwardingModel.Transport.on(.local, manager: manager).current()
    XCTAssertNotNil(local)
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

  // MARK: Local port and declared forwards

  /// A port number nothing on this Mac holds right now.
  private func freePort() throws -> UInt16 {
    let made = try XCTUnwrap(LoopbackSocket.listen())
    Darwin.close(made.descriptor)
    return made.port
  }

  /// A listener on this Mac holding a port, as a dev server of its own would; closed at tearDown.
  private func hold(ipv6 v6: Bool = false) throws -> UInt16 {
    if !v6 {
      let made = try XCTUnwrap(LoopbackSocket.listen())
      addTeardownBlock { Darwin.close(made.descriptor) }
      return made.port
    }
    let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    addTeardownBlock { Darwin.close(descriptor) }
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_addr = in6addr_loopback
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, 1) == 0
          && getsockname(descriptor, $0, &length) == 0
      }
    }
    XCTAssertTrue(bound, "no ::1 listener")
    return UInt16(bigEndian: address.sin6_port)
  }

  /// The dev container convention: port N is reachable at N on this Mac when nothing here holds it.
  /// `localhost:N`, which the Ports list shows, reaches the container on `::1` too, where a browser
  /// tries first, and a server the Mac starts later on `::1:N` can't take it from the forward.
  func testAForwardAnswersLocalhostOnIPv6AndKeepsItFromALaterServer() async throws {
    let port = try freePort()
    let model = try await model(lease: lease(), sameLocalPort: true)
    model.draft = String(port)
    await model.add()
    XCTAssertNil(model.message)
    XCTAssertEqual(model.forwards.first?.localPort, port)
    XCTAssertNil(
      LoopbackSocket.listenIPv6(port: port), "a later ::1 server took the forward's port")

    let client = socket(AF_INET6, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(client, 0)
    defer { Darwin.close(client) }
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr = in6addr_loopback
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
      }
    }
    XCTAssertTrue(connected, "nothing answers localhost on ::1")
    XCTAssertEqual(Darwin.write(client, "x", 1), 1)
    var byte: UInt8 = 0
    XCTAssertEqual(Darwin.read(client, &byte, 1), 1, "the ::1 connection was not carried")
    XCTAssertEqual(byte, UInt8(ascii: "x"))
  }

  /// A port only finished connections hold keeps its number: a forward this side closed first (the
  /// app quitting with a browser's connection open) leaves it in `TIME_WAIT`, which refuses a plain
  /// bind for about 30 s, and the relaunch's forward must still get it.
  func testAForwardReclaimsItsNumberFromConnectionsInTimeWait() async throws {
    let made = try XCTUnwrap(LoopbackSocket.listen())
    let client = try TCPClient(port: made.port)
    let accepted = Darwin.accept(made.descriptor, nil, nil)
    XCTAssertGreaterThanOrEqual(accepted, 0)
    // This side's FIN first, then the peer's: this side's end waits in TIME_WAIT on the port.
    Darwin.close(accepted)
    XCTAssertEqual(try client.read(1, timeout: 2), Data(), "the close did not reach the client")
    client.close()
    Darwin.close(made.descriptor)
    XCTAssertNil(LoopbackSocket.listen(port: made.port), "no TIME_WAIT: the fixture proves nothing")

    let model = try await model(lease: lease(), sameLocalPort: true)
    model.draft = String(made.port)
    await model.add()
    XCTAssertNil(model.message)
    XCTAssertEqual(model.forwards.first?.localPort, made.port)
  }

  /// Reclaiming a port from `TIME_WAIT` never takes it from a live listener on every address, which
  /// `SO_REUSEADDR` alone would allow: the Mac's own server keeps its port and the forward moves.
  func testAForwardNeverTakesAPortFromAWildcardListener() async throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    addTeardownBlock { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, 4) == 0
          && getsockname(descriptor, $0, &length) == 0
      }
    }
    XCTAssertTrue(bound, "no 0.0.0.0 listener")
    let port = UInt16(bigEndian: address.sin_port)

    let model = try await model(lease: lease(), sameLocalPort: true)
    model.draft = String(port)
    await model.add()
    XCTAssertNil(model.message)
    let entry = try XCTUnwrap(model.forwards.first)
    XCTAssertNotEqual(entry.localPort, port, "the forward took the Mac server's port")
  }

  /// A port this Mac holds moves to another, on 127.0.0.1 or only on `::1` (where a bind on
  /// 127.0.0.1 succeeds, and a browser asking for `localhost` would reach the Mac's own server).
  func testAForwardMovesToAnotherPortWhenThisMacHoldsItsNumber() async throws {
    for v6 in [false, true] {
      let port = try hold(ipv6: v6)
      XCTAssertEqual(LoopbackSocket.answers(port: port, ipv6: true), v6)
      let model = try await model(lease: lease(), sameLocalPort: true)
      model.draft = String(port)
      await model.add()
      XCTAssertNil(model.message, "ipv6 \(v6)")
      let entry = try XCTUnwrap(model.forwards.first, "ipv6 \(v6)")
      XCTAssertNotEqual(entry.localPort, port, "ipv6 \(v6)")
      let client = try TCPClient(port: entry.localPort)
      try client.write(Data("x".utf8))
      XCTAssertEqual(try client.read(1), Data("x".utf8), "ipv6 \(v6)")
      client.close()
    }
  }

  /// What the dev container declares is forwarded, each port at its own number with its label; a
  /// port that `requireLocalPort`s a number this Mac holds is refused and said, and the rest still
  /// forwarded.
  func testDeclaredPortsAreForwardedWithTheirLabels() async throws {
    let web = try freePort()
    let api = try freePort()
    let taken = try hold()
    let model = try await model(lease: lease(), sameLocalPort: true)
    let file = """
      {
        "forwardPorts": [\(web), \(taken), \(api)],
        "portsAttributes": {
          "\(web)": { "label": "Web" },
          "\(taken)": { "label": "Taken", "requireLocalPort": true },
        },
      }
      """
    await model.forwardDeclared { (".devcontainer/devcontainer.json", Data(file.utf8)) }
    XCTAssertTrue(model.declared)
    XCTAssertEqual(model.forwards.map(\.remotePort), [web, api])
    XCTAssertEqual(model.forwards.map(\.localPort), [web, api])
    XCTAssertEqual(model.forwards.map(\.label), ["Web", nil])
    XCTAssertEqual(
      model.message,
      "Port \(taken) is in use on this Mac, and the dev container requires the same port.")
  }

  /// `requireLocalPort` refuses a port held only on `::1` too, which a bind on 127.0.0.1 doesn't
  /// see: a Node dev server on `localhost` holds just that, and a browser asking for `localhost`
  /// would reach it rather than the container.
  func testRequireLocalPortRefusesAPortHeldOnlyOnIPv6Loopback() async throws {
    let taken = try hold(ipv6: true)
    let model = try await model(lease: lease(), sameLocalPort: true)
    let file = """
      {"forwardPorts": [\(taken)], "portsAttributes": {"\(taken)": {"requireLocalPort": true}}}
      """
    await model.forwardDeclared { (".devcontainer.json", Data(file.utf8)) }
    XCTAssertTrue(model.forwards.isEmpty, "the Mac's ::1 listener was shadowed")
    XCTAssertEqual(
      model.message,
      "Port \(taken) is in use on this Mac, and the dev container requires the same port.")
  }

  /// A file declaring more ports than `maxForwards` has only the first of them forwarded, and says
  /// so: each forward holds a descriptor for the launch, which a hostile or generated list must not
  /// exhaust for the terminals and connections that share the app's limit.
  func testDeclaredPortsPastTheCapAreNotForwarded() async throws {
    let model = try await model(lease: lease())
    let declared = (0..<DevContainerConfig.maxForwards + 8).map { 20000 + $0 }
    let file = #"{"forwardPorts": \#(declared)}"#
    await model.forwardDeclared { (".devcontainer.json", Data(file.utf8)) }
    XCTAssertEqual(
      model.forwards.map { Int($0.remotePort) },
      Array(declared.prefix(DevContainerConfig.maxForwards)))
    XCTAssertEqual(
      model.message,
      ".devcontainer.json declares \(declared.count) ports; only the first "
        + "\(DevContainerConfig.maxForwards) are forwarded.")
  }

  /// Forwarded once a launch: a second call reads nothing, and a declared port already forwarded
  /// (the user added it first) is not forwarded twice.
  func testDeclaredPortsAreForwardedOnceAndNeverTwice() async throws {
    let model = try await model(lease: lease())
    model.draft = "3000"
    await model.add()
    let reads = Counter()
    let read = { @Sendable () -> (path: String, data: Data)? in
      reads.bump()
      return (".devcontainer.json", Data(#"{"forwardPorts": [3000, 5173]}"#.utf8))
    }
    await model.forwardDeclared(read: read)
    await model.forwardDeclared(read: read)
    XCTAssertEqual(reads.count, 1, "the file was read again")
    XCTAssertEqual(model.forwards.map(\.remotePort), [3000, 5173])
  }

  /// A read the host's connection fails (Docker not running yet at launch) runs again by itself
  /// once the host connects, with the workroom still selected and nothing else asking; no file at
  /// all, one that isn't JSON, or one the host refuses is an answer, said where it is one, and is
  /// not tried again.
  func testAFailedReadIsTriedAgainWhenTheHostConnectsAndAnAnswerIsNot() async throws {
    let model = try await model(lease: lease())
    let reads = Counter()
    await model.forwardDeclared {
      reads.bump()
      if reads.count == 1 { throw RepositoryRoutingError.unavailable(.remote(UUID())) }
      return (".devcontainer.json", Data(#"{"forwardPorts": [5173]}"#.utf8))
    }
    XCTAssertNil(model.message)
    // The model's stream holds a `connected` snapshot: the host is up again.
    await settle("the failed read was not run again") { model.declared }
    XCTAssertEqual(model.forwards.map(\.remotePort), [5173])
    XCTAssertEqual(reads.count, 2)

    let none = try await self.model(lease: lease())
    await none.forwardDeclared { nil }
    XCTAssertTrue(none.declared)
    XCTAssertTrue(none.forwards.isEmpty)

    let broken = try await self.model(lease: lease())
    await broken.forwardDeclared { (".devcontainer.json", Data("{".utf8)) }
    XCTAssertTrue(broken.declared)
    XCTAssertTrue(
      broken.message?.hasPrefix("Couldn't read .devcontainer.json: ") == true,
      broken.message ?? "no message")

    let refused = try await self.model(lease: lease())
    await refused.forwardDeclared { throw FileServiceError.tooLarge }
    XCTAssertTrue(refused.declared)
    XCTAssertEqual(refused.message, "Couldn't read the dev container file: File too large.")
  }

  /// A host that goes away mid-way leaves the rest for when it is back, not lost.
  func testAForwardThatFailsMidWayIsLeftForWhenTheHostIsBack() async throws {
    let first = lease()
    let fails = Counter()
    let held = try await service(on: first)
    let model = try await model(
      lease: first,
      forwarding: {
        fails.bump()
        if fails.count == 1 { throw RepositoryRoutingError.unavailable(.remote(UUID())) }
        return held
      })
    let read = { @Sendable () -> (path: String, data: Data)? in
      (".devcontainer.json", Data(#"{"forwardPorts": [5173]}"#.utf8))
    }
    await model.forwardDeclared(read: read)
    XCTAssertEqual(model.forwards, [], "nothing was forwarded through the failed connection")
    await settle("the cut-short pass was not run again") { model.declared }
    XCTAssertEqual(model.forwards.map(\.remotePort), [5173])
    XCTAssertNil(model.message)
  }
}

// MARK: - Helpers

/// Holds a transport's answer until the test lets it through, so the test can act while `add()` is
/// suspended.
final class CurrentLease: Sendable {
  private let lease = Mutex<HostConnectionManager.Lease?>(nil)
  func set(_ lease: HostConnectionManager.Lease?) { self.lease.withLock { $0 = lease } }
  func get() -> HostConnectionManager.Lease? { lease.withLock { $0 } }
}

actor Gate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var value: (HostConnectionManager.Lease, DaemonForwardService)?

  func hold(_ value: (HostConnectionManager.Lease, DaemonForwardService)) { self.value = value }

  func held() throws -> (HostConnectionManager.Lease, DaemonForwardService) {
    guard let value else { throw HostConnectionError.connectionLost }
    return value
  }

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

/// Counts `current()` reads, which arrive from the watch's task and `add()` alike.
final class Reads: Sendable {
  private let calls = Mutex(0)
  var count: Int { calls.withLock { $0 } }
  func next() -> Int {
    calls.withLock {
      $0 += 1
      return $0
    }
  }
}

/// Refusals collected off the forward's event callback, which fires on whichever thread noticed.
final class Failures: Sendable {
  private struct State {
    var values: [String] = []
    var openedCount = 0
  }
  private let state = Mutex(State())
  func add(_ event: PortForward.Event) {
    state.withLock {
      switch event {
      case .opened: $0.openedCount += 1
      case .failed(let detail), .stopped(let detail): $0.values.append(detail)
      }
    }
  }
  var all: [String] { state.withLock { $0.values } }
  var opened: Int { state.withLock { $0.openedCount } }
}
