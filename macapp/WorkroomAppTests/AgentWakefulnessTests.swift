import XCTest

@testable import Workroom

/// The app's half of the wakefulness service (issues #208, #380): the wire decode of both versions,
/// the protocol-version gate, the pushed changes, the badge's display rules, and the model's watch
/// (subscribe, ask, follow; never run a reading backwards; what a connection ending leaves).
///
/// `FakeAgent` (`AgentFileIntegrationTests`) is the transport double, for the same reason the File
/// service uses it: the cases worth pinning are ones the real binary cannot produce on demand — an
/// old peer, a change pushed on cue. The real binary appears once, to pin the reply shape the
/// fixture claims to copy.
final class AgentWakefulnessTests: XCTestCase {
  private var fakes: [FakeAgent] = []
  private var agents: [AgentHarness] = []
  private var connections: [AgentVCSConnection] = []

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    for fake in fakes { fake.stop() }
    fakes.removeAll()
    for agent in agents { agent.stop() }
    agents.removeAll()
    try await super.tearDown()
  }

  private func decode(_ json: String) throws -> AgentWakefulness {
    try AgentStatusReply<AgentWakefulness>.decode(Data(json.utf8))
  }

  private func status(_ edits: [(String, String)] = []) throws -> AgentWakefulness {
    var json = FakeAgent.statusJSON
    for (from, to) in edits { json = json.replacingOccurrences(of: from, with: to) }
    return try decode(json)
  }

  private static let idle = (#""busy":true"#, #""busy":false"#)
  private static let failing = (#""error":null"#, #""error":"no IPv4 default route""#)
  private static let stalled = (#""stalled":false"#, #""stalled":true"#)
  private static let noHeartbeat = (#","keep_awake":{"last_sent":14990.0,"error":null}"#, "")

  // MARK: - Decoding

  func testStatusDecodesEveryFieldTheAgentSends() throws {
    let status = try status()
    XCTAssertTrue(status.running)
    XCTAssertEqual(status.verdict, "BUSY")
    XCTAssertTrue(status.busy)
    XCTAssertEqual(status.monotonic, 15000, accuracy: 0.001)
    XCTAssertEqual(status.cpuFraction ?? 0, 0.0021, accuracy: 0.0001)
    XCTAssertEqual(status.keepAwake, AgentWakefulness.KeepAwake(lastSent: 14990, error: nil))
    XCTAssertEqual(status.stalled, false)
  }

  /// The fixture above is a Swift string. This is the shipped binary: a field the agent renames or
  /// drops fails HERE, not as a badge that silently blanks. A macOS agent answers `running: false`
  /// with every field present, which is exactly what the shape check needs. The awake ceiling's
  /// requests went with it (#380).
  func testTheShippedAgentsStatusReplyDecodesAndKeepIsGone() async throws {
    let agent = try AgentHarness.start()
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    connections.append(connection)
    let status = try await connection.wakefulness().status()
    XCTAssertFalse(status.running, "the classifier is Linux-only")
    XCTAssertNotNil(status.keepAwake, "the field `unprotected` reads (#257)")
    XCTAssertNotNil(status.stalled)
    let keep = try await connection.statusRequest(AgentStatusRequest(method: "keep"))
    XCTAssertThrowsError(try AgentStatusReply<AgentWakefulness>.decode(keep)) { error in
      XCTAssertEqual(
        error as? HostConnectionError,
        .serviceUnavailable(
          #"unsupported: status requests are {"method": "status"}"#))
    }
  }

  /// A version 1 agent (one a busy box kept rather than hand off, #257) still shows: the fields
  /// this build reads are in both versions, and the ceiling's are ignored.
  func testAVersion1ReplyStillDecodes() throws {
    let old = try decode(
      """
      {"version":1,"result":{"running":true,"verdict":"BUSY","busy":true,\
      "classifier_verdict":"BUSY","monotonic":15000.0,"awake_seconds":14400.5,\
      "awake_ceiling_exceeded":true,"prompt_pending":true,"prompt_deadline":15600.0,\
      "asserting":true,"suppressed":false,"ceiling_seconds":14400.0,\
      "prompt_timeout_seconds":600.0,"ask_at_ceiling":true,"cpu_fraction":0.0021,\
      "keep_awake":{"last_sent":14990.0,"error":null},"stalled":false}}
      """)
    XCTAssertEqual(old.display, .busy)
  }

  /// The fields nothing displays are optional: an agent that renames one must not blank the badge.
  func testDiagnosticFieldsAreOptional() throws {
    let trimmed = try status([(#""verdict":"BUSY","#, ""), (#","cpu_fraction":0.0021"#, "")])
    XCTAssertEqual(trimmed.display, .busy)
    XCTAssertNil(trimmed.cpuFraction)
    XCTAssertNil(trimmed.verdict)
  }

  func testAnErrorReplyIsAServiceFailure() {
    let json = #"{"version":2,"error":{"unsupported":"status requests are ..."}}"#
    XCTAssertThrowsError(try decode(json)) { error in
      guard case HostConnectionError.serviceUnavailable = error else {
        return XCTFail("expected serviceUnavailable, got \(error)")
      }
    }
  }

  func testAnUnknownVersionReplyIsAServiceFailure() {
    for version in [0, 3] {
      XCTAssertThrowsError(try decode(#"{"version":\#(version),"result":{}}"#)) { error in
        XCTAssertEqual(
          error as? HostConnectionError,
          .serviceUnavailable("Unsupported status response version."))
      }
    }
  }

  // MARK: - The badge

  /// The one state the badge must not soften: work is running and nothing keeps the box awake. A
  /// failing heartbeat, an agent that predates it, and a stalled service each say why.
  func testUnprotectedOutranksBusy() throws {
    let help = { (status: AgentWakefulness) in WakefulnessBadge.help(for: status) }
    XCTAssertEqual(try status().display, .busy)
    XCTAssertEqual(try status([Self.idle]).display, .idle)

    let failing = try status([Self.failing])
    XCTAssertEqual(failing.display, .busyUnprotected)
    XCTAssertTrue(help(failing).contains("heartbeat is failing (no IPv4 default route)"))
    // An IDLE box has nothing to keep awake, so a failed heartbeat protects nothing that needs it.
    XCTAssertEqual(try status([Self.failing, Self.idle]).display, .idle)

    let older = try status([Self.noHeartbeat])
    XCTAssertNil(older.keepAwake)
    XCTAssertEqual(older.display, .busyUnprotected)
    XCTAssertTrue(help(older).contains("predates the keep-awake heartbeat"), help(older))

    // This Mac's agent runs no classifier (macOS): no heartbeat field is not an old agent there.
    let notRunning = try status([(#""running":true"#, #""running":false"#), Self.noHeartbeat])
    XCTAssertFalse(notRunning.unprotected)

    let stalled = try status([Self.stalled])
    XCTAssertEqual(stalled.display, .busyUnprotected)
    XCTAssertTrue(help(stalled).contains("stopped checking"))
    XCTAssertFalse(try status([Self.stalled, Self.idle]).unprotected)
  }

  /// A host that never sleeps (a container) has nothing to be kept awake from (#257): an old agent,
  /// a stalled one or a failing heartbeat is not "not kept awake" there, only busy. A host that
  /// sleeps keeps every warning.
  func testAHostThatNeverSleepsIsNeverShownUnprotected() throws {
    let older = try status([Self.noHeartbeat])
    XCTAssertEqual(older.display(hostSleeps: true), .busyUnprotected)
    XCTAssertEqual(older.display(hostSleeps: false), .busy)
    XCTAssertEqual(try status([Self.stalled]).display(hostSleeps: false), .busy)
    XCTAssertEqual(try status([Self.failing]).display(hostSleeps: false), .busy)
    XCTAssertFalse(WakefulnessBadge.help(for: older, hostSleeps: false).contains("restart"))
    // The error is the remote agent's text, so the tooltip takes only so much of it.
    let flood = try status([
      (#""error":null"#, "\"error\":\"" + String(repeating: "x", count: 5000) + "\"")
    ])
    XCTAssertLessThan(WakefulnessBadge.help(for: flood).count, 600)
  }

  /// A stalled service on a host that sleeps: its last reading said IDLE, which may be stale while
  /// work runs, and nothing is keeping the box awake either way, so it reads unknown, not idle
  /// (#356). A host that never sleeps keeps reading idle: there is nothing to keep it awake from.
  func testAStalledIdleReadingIsUnknownWhereTheBoxSleeps() throws {
    let stalledIdle = try status([Self.stalled, Self.idle])
    XCTAssertFalse(stalledIdle.unprotected)
    XCTAssertEqual(stalledIdle.display(hostSleeps: true), .unknown)
    XCTAssertEqual(stalledIdle.display(hostSleeps: false), .idle)
    XCTAssertTrue(WakefulnessBadge.help(for: stalledIdle).contains("unknown"))
  }

  // MARK: - The version gate

  /// A peer below `minStatusVersion` silently DROPS a Status envelope, so none is sent — otherwise
  /// every request would wait out its timeout against an agent that can never answer.
  func testAProtocol3AgentIsNeverSentAStatusEnvelope() async throws {
    let fake = try FakeAgent(version: 3)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    XCTAssertFalse(
      fake.receivedServices.contains(4), "a pre-Status peer must never see a Status envelope")
    XCTAssertThrowsError(try connection.wakefulness()) { error in
      guard case VCSError.backendVersion = error else {
        return XCTFail("expected backendVersion, got \(error)")
      }
    }
  }

  /// The greeting version is the whole gate. There is no connect-time probe: one probe reply slower
  /// than its timeout used to switch the service off for the life of the connection, on an agent
  /// under exactly the load that makes wakefulness matter.
  func testAProtocol4AgentIsNotProbedAndHasTheService() async throws {
    let fake = try FakeAgent(version: 4)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    XCTAssertFalse(fake.receivedServices.contains(4), "nothing is sent on Status at connect")
    XCTAssertNoThrow(try connection.wakefulness())
    let reply = try await connection.request(AgentVCSRequest(method: "capabilities"), timeout: 2)
    XCTAssertNoThrow(try AgentVCSReply<AgentVCSCapabilities>.decode(reply))
  }

  // MARK: - Pushed changes

  private func firstChange(
    on service: AgentWakefulnessService, after push: () -> Void
  ) async -> AgentWakefulness? {
    // Bounded, so a change that never arrives fails the test instead of hanging the suite. What
    // makes this race-free is the stream's `.bufferingNewest(1)` policy, which holds the change
    // until someone iterates: `Task {}` does not start synchronously, so the push can land first.
    let waiter = Task { () -> AgentWakefulness? in
      for await change in service.changes { return change }
      return nil
    }
    let guardTask = Task {
      try? await Task.sleep(for: .seconds(2))
      waiter.cancel()
    }
    push()
    let received = await waiter.value
    guardTask.cancel()
    return received
  }

  /// A change arrives unsolicited on stream 0 of service 4, carrying what `status` returns, and the
  /// connection survives it: before #208 that envelope failed `receive()`'s validity guard and took
  /// every in-flight request with it.
  func testAStatusChangeOnStreamZeroIsDeliveredAndDoesNotFailTheConnection() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let service = try connection.wakefulness()
    let received = await firstChange(on: service) { fake.pushStatusChange() }
    let change = try XCTUnwrap(received, "no change arrived")
    XCTAssertFalse(change.busy)
    XCTAssertEqual(change.monotonic, 15001, accuracy: 0.001)
    _ = try await service.status()
  }

  /// A malformed event, an unknown kind, a version this build does not speak, or a version 1
  /// agent's ceiling prompt is dropped — the connection stays up and nothing is delivered. One
  /// stream per connection, so one fake per case.
  func testAMalformedOrForeignStatusEventIsDroppedAndTheConnectionSurvives() async throws {
    let result = FakeAgent.statusResultJSON
    for body in [
      #"{"version":1,"event":"awake_ceiling_prompt","awake_seconds":1.0,"prompt_deadline":2.0}"#,
      #"{"version":3,"event":"status","status":"# + result + "}",
      #"{"version":2,"event":"something_new","status":"# + result + "}",
      #"{"version":2,"event":"status"}"#,
      #"{"version":2,"event":"status","status":{"busy":true}}"#,
      "not json",
    ] {
      let fake = try FakeAgent(version: 4, status: true)
      fakes.append(fake)
      let connection = try await AgentVCSConnection.connect(
        host: .local, socketPath: fake.socketPath)
      connections.append(connection)
      let service = try connection.wakefulness()
      let received = await firstChange(on: service) { fake.pushStatusChange(body: body) }
      XCTAssertNil(received, "dropped: \(body)")
      _ = try await service.status()
    }
  }

  // Value: protects=the pushed-change stream ends when its connection does, which is how the watch learns
  // the connection is gone; fails_when=AgentVCSConnection.fail stops finishing statusChanges;
  // why_new=the model tests end the stream by hand on a stand-in transport; seam=none
  /// A watch only notices its connection ending (#380) because the stream it follows finishes with
  /// the connection; one that never finished would leave the badge stale for good.
  func testTheChangesStreamEndsWithItsConnection() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let service = try connection.wakefulness()
    // Bounded, so a stream that never finishes fails the test instead of hanging the suite: the
    // cancellation also ends the loop, which `isCancelled` tells apart from the stream finishing.
    let waiter = Task { () -> Bool in
      for await _ in service.changes {}
      return !Task.isCancelled
    }
    let bound = Task {
      try? await Task.sleep(for: .seconds(3))
      waiter.cancel()
    }
    await connection.close()
    let finished = await waiter.value
    bound.cancel()
    XCTAssertTrue(finished, "the changes stream outlived its connection")
  }

  // MARK: - The model

  /// Hands out one connection's worth: its stream ONCE (then reports no connection, so the watch
  /// loop does not spin on a finished stream), and replies in order.
  private final class Agent: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<AgentWakefulness, Error>]
    private var stream: AsyncStream<AgentWakefulness>?
    private(set) var continuation: AsyncStream<AgentWakefulness>.Continuation?
    private var asked = 0

    init(replies: [Result<AgentWakefulness, Error>]) {
      self.replies = replies
      let (stream, continuation) = AsyncStream<AgentWakefulness>.makeStream(
        bufferingPolicy: .bufferingNewest(1))
      self.stream = stream
      self.continuation = continuation
    }

    var calls: Int { lock.withLock { asked } }

    var transport: WakefulnessModel.Transport {
      WakefulnessModel.Transport(
        status: { [self] in
          let reply = lock.withLock { () -> Result<AgentWakefulness, Error> in
            asked += 1
            return replies.isEmpty ? .failure(Unavailable()) : replies.removeFirst()
          }
          return try reply.get()
        },
        changes: { [self] in
          let taken = lock.withLock { () -> AsyncStream<AgentWakefulness>? in
            defer { stream = nil }
            return stream
          }
          guard let taken else { throw Unavailable() }
          return taken
        })
    }
  }

  private struct Unavailable: Error {}

  /// Waits for `condition` on the main actor, failing the test rather than hanging it.
  @MainActor
  private func eventually(
    _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      if ContinuousClock.now > deadline { return XCTFail(message, file: file, line: line) }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func at(_ monotonic: Double, busy: Bool = true) throws -> AgentWakefulness {
    try status(
      [(#""monotonic":15000.0"#, "\"monotonic\":\(monotonic)")] + (busy ? [] : [Self.idle]))
  }

  /// A remote host's model is watching from the moment it is made, and a deleted host's goes,
  /// watch and all.
  @MainActor
  func testARemoteHostsModelWatchesUntilTheHostIsForgotten() {
    let id = UUID()
    let model = WakefulnessModel.model(forHost: id)
    XCTAssertTrue(WakefulnessModel.models[id] === model)
    XCTAssertEqual(model.host, id)
    XCTAssertTrue(model.isWatching)
    WakefulnessModel.forgetHost(id)
    XCTAssertNil(WakefulnessModel.models[id])
    XCTAssertFalse(model.isWatching)
  }

  /// A remote host's transport reads that host's connection and never connects one: a badge is not
  /// a reason to reach a host.
  @MainActor
  func testARemoteHostsTransportNeverConnects() async throws {
    let manager = HostConnectionManager()
    let host = HostID.remote(UUID())
    let transport = WakefulnessModel.Transport.on(host, manager: manager)
    for call in ["status", "changes"] {
      do {
        if call == "status" {
          _ = try await transport.status()
        } else {
          _ = try await transport.changes()
        }
        XCTFail("\(call) answered for a host with no connection")
      } catch RepositoryRoutingError.unavailable(let refused) {
        XCTAssertEqual(refused, host)
      }
    }
    let snapshot = await manager.snapshot(for: host)
    XCTAssertEqual(snapshot.status, .disconnected)
  }

  /// The watch asks once and then follows what is pushed: an idle box is never polled (#380), so
  /// it hears one request per connection, and the badge follows the box.
  @MainActor
  func testTheWatchAsksOnceThenFollowsWhatIsPushed() async throws {
    let agent = Agent(replies: [.success(try at(100))])
    let model = WakefulnessModel(transport: agent.transport, host: UUID())
    model.hostSleeps = false
    model.startWatching()
    defer { model.stopWatching() }
    await eventually("the first reply was never shown") { model.status?.monotonic == 100 }
    agent.continuation?.yield(try at(101, busy: false))
    await eventually("a pushed change was never shown") { model.status?.busy == false }
    agent.continuation?.yield(try at(102))
    await eventually("a second change was never shown") { model.status?.busy == true }
    XCTAssertEqual(agent.calls, 1, "the box was asked more than once on one connection")
  }

  // Value: protects=a busy box is asked again, so a stalled or crashed service shows unprotected;
  // fails_when=the busy re-ask is removed, or runs while idle; why_new=the agent pushes only on a
  // change, which a stalled service never makes, and no other test asks twice; seam=none
  /// A BUSY box is asked again (#380 review): its agent pushes only when its verdict changes, which
  /// a stalled or crashed service never does, so the re-ask is what shows it no longer kept awake.
  /// An IDLE box is never asked again: the app's traffic must not hold it awake.
  @MainActor
  func testOnlyABusyBoxIsAskedAgain() async throws {
    let busy = Agent(replies: [.success(try at(15000)), .success(try status([Self.stalled]))])
    let model = WakefulnessModel(transport: busy.transport, host: UUID())
    model.busyRecheckInterval = .milliseconds(20)
    model.startWatching()
    defer { model.stopWatching() }
    await eventually("a stalled service was never shown") { model.status?.stalled == true }
    XCTAssertEqual(model.status?.display(hostSleeps: true), .busyUnprotected)

    let idle = Agent(replies: [.success(try at(100, busy: false))])
    let quiet = WakefulnessModel(transport: idle.transport, host: UUID())
    quiet.busyRecheckInterval = .milliseconds(20)
    quiet.startWatching()
    defer { quiet.stopWatching() }
    await eventually("the watch never asked") { quiet.status != nil }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(idle.calls, 1, "an idle box was asked again")
  }

  /// The reply and a change pushed meanwhile can arrive in either order; the older reading, by the
  /// agent's clock, never replaces the newer.
  @MainActor
  func testAnOlderReadingDoesNotOverrideANewerOne() throws {
    let model = WakefulnessModel(transport: Agent(replies: []).transport, host: UUID())
    model.apply(try at(105, busy: false))
    model.apply(try at(100))
    XCTAssertEqual(model.status?.busy, false)
    model.apply(try at(106))
    XCTAssertEqual(model.status?.busy, true)
  }

  /// The watch subscribes before it asks, and does not follow a stream it got no reply on: the
  /// reply is what makes the connection one the agent pushes to.
  @MainActor
  func testTheWatchDoesNotFollowAStreamWithoutItsFirstReply() async throws {
    let agent = Agent(replies: [.failure(Unavailable())])
    let model = WakefulnessModel(transport: agent.transport, host: UUID())
    model.startWatching()
    defer { model.stopWatching() }
    await eventually("the watch never asked") { agent.calls == 1 }
    agent.continuation?.yield(try at(100))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(model.status, "a change was taken on a stream nobody subscribed")
  }

  /// A connection ending on a busy box says nothing more about it: the badge clears. One ending on
  /// an idle box keeps its idle reading.
  @MainActor
  func testWhatAConnectionEndingLeaves() throws {
    let busy = WakefulnessModel(transport: Agent(replies: []).transport, host: UUID())
    busy.apply(try at(100))
    busy.connectionEnded()
    XCTAssertNil(busy.status)

    let idle = WakefulnessModel(transport: Agent(replies: []).transport, host: UUID())
    idle.apply(try at(100, busy: false))
    idle.connectionEnded()
    XCTAssertEqual(idle.status?.busy, false, "an idle box's badge stays idle")
  }

  /// Each connection's readings are ordered among themselves only: a box that rebooted restarts
  /// the agent's clock, and its first reading after must still be taken.
  @MainActor
  func testANewConnectionsReadingIsTakenWhateverItsClock() async throws {
    let first = Agent(replies: [.success(try at(9000))])
    let second = Agent(replies: [.success(try at(10, busy: false))])
    let agents = [first, second]
    let handedOut = Counter()
    let model = WakefulnessModel(
      transport: .init(
        status: { try await agents[min(handedOut.value, 1)].transport.status() },
        changes: {
          let stream = try await agents[min(handedOut.value, 1)].transport.changes()
          return stream
        }),
      host: UUID())
    model.hostSleeps = false
    model.retryInterval = .milliseconds(20)
    model.startWatching()
    defer { model.stopWatching() }
    await eventually("the first connection's reading") { model.status?.monotonic == 9000 }
    handedOut.bump()
    first.continuation?.finish()
    // The watch waits `retryInterval` before it looks again; the second connection's reading is
    // what it finds.
    let deadline = ContinuousClock.now + .seconds(3)
    while model.status?.monotonic != 10, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.status?.monotonic, 10, "a rebooted box's reading was refused as older")
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }
}
