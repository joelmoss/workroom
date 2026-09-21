import XCTest

@testable import Workroom

/// The app's half of the wakefulness service (issue #208): the wire decode, the protocol-version
/// gate, the settings-to-flags mapping, and the ceiling prompt's state machine.
///
/// `FakeAgent` (`AgentFileIntegrationTests`) is the transport double throughout, for the same reason
/// the File service uses it: the cases worth pinning are ones the real binary cannot produce on
/// demand — an old peer, an unanswered probe, a prompt raised on cue.
final class AgentWakefulnessTests: XCTestCase {
  private var fakes: [FakeAgent] = []
  private var connections: [AgentVCSConnection] = []

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    for fake in fakes { fake.stop() }
    fakes.removeAll()
    try await super.tearDown()
  }

  // MARK: - Decoding

  func testStatusDecodesEveryFieldTheAgentSends() throws {
    let status = try AgentStatusReply<AgentWakefulness>.decode(Data(FakeAgent.statusJSON.utf8))
    XCTAssertTrue(status.running)
    XCTAssertEqual(status.verdict, "BUSY")
    XCTAssertTrue(status.busy)
    XCTAssertEqual(status.classifierVerdict, "BUSY")
    XCTAssertEqual(status.monotonic, 15000, accuracy: 0.001)
    XCTAssertEqual(status.awakeSeconds, 14400.5, accuracy: 0.001)
    XCTAssertTrue(status.awakeCeilingExceeded)
    XCTAssertTrue(status.promptPending)
    XCTAssertEqual(status.promptDeadline ?? 0, 15600, accuracy: 0.001)
    XCTAssertTrue(status.asserting)
    XCTAssertFalse(status.suppressed)
    XCTAssertEqual(status.ceilingSeconds, 14400, accuracy: 0.001)
    XCTAssertEqual(status.promptTimeoutSeconds, 600, accuracy: 0.001)
    XCTAssertTrue(status.askAtCeiling)
    XCTAssertEqual(status.cpuFraction, 0.0021, accuracy: 0.0001)
  }

  /// The agent's clock is its own. `promptRemaining` is the ONLY subtraction allowed on it, and both
  /// operands come from the same reply — 15600 - 15000 = 600, never `deadline - Date()`.
  func testPromptRemainingUsesTheAgentsOwnClockReading() throws {
    let status = try AgentStatusReply<AgentWakefulness>.decode(Data(FakeAgent.statusJSON.utf8))
    XCTAssertEqual(try XCTUnwrap(status.promptRemaining), 600, accuracy: 0.001)
  }

  func testNoPromptMeansNoRemaining() throws {
    let json = FakeAgent.statusJSON
      .replacingOccurrences(of: #""prompt_pending":true"#, with: #""prompt_pending":false"#)
      .replacingOccurrences(of: #""prompt_deadline":15600.0"#, with: #""prompt_deadline":null"#)
    let status = try AgentStatusReply<AgentWakefulness>.decode(Data(json.utf8))
    XCTAssertNil(status.promptRemaining)
    XCTAssertFalse(status.promptPending)
  }

  /// Past the ceiling outranks plain busy: the badge must say so, because that is the whole point of
  /// an advisory ceiling nobody acts on.
  func testDisplayRanksCeilingAboveBusy() throws {
    let exceeded = try AgentStatusReply<AgentWakefulness>.decode(Data(FakeAgent.statusJSON.utf8))
    XCTAssertEqual(exceeded.display, .busyPastCeiling)

    let busy = try AgentStatusReply<AgentWakefulness>.decode(
      Data(
        FakeAgent.statusJSON.replacingOccurrences(
          of: #""awake_ceiling_exceeded":true"#, with: #""awake_ceiling_exceeded":false"#
        ).utf8))
    XCTAssertEqual(busy.display, .busy)

    let idle = try AgentStatusReply<AgentWakefulness>.decode(
      Data(
        FakeAgent.statusJSON
          .replacingOccurrences(
            of: #""awake_ceiling_exceeded":true"#, with: #""awake_ceiling_exceeded":false"#
          )
          .replacingOccurrences(of: #""busy":true"#, with: #""busy":false"#).utf8))
    XCTAssertEqual(idle.display, .idle)
  }

  func testAnErrorReplyIsAServiceFailure() {
    let json = #"{"version":1,"error":{"unsupported":"status requests are ..."}}"#
    XCTAssertThrowsError(
      try AgentStatusReply<AgentWakefulness>.decode(Data(json.utf8))
    ) { error in
      guard case HostConnectionError.serviceUnavailable = error else {
        return XCTFail("expected serviceUnavailable, got \(error)")
      }
    }
  }

  func testAWrongVersionReplyIsAServiceFailure() {
    let json = #"{"version":2,"result":{}}"#
    XCTAssertThrowsError(try AgentStatusReply<AgentWakefulness>.decode(Data(json.utf8))) { error in
      XCTAssertEqual(
        error as? HostConnectionError,
        .serviceUnavailable("Unsupported status response version."))
    }
  }

  /// Forward compatibility, the same rule the file events follow: an event kind this build does not
  /// know is dropped, never an error.
  func testTheCeilingPromptEventDecodes() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let json =
      #"{"version":1,"event":"awake_ceiling_prompt","awake_seconds":14400.5,"prompt_deadline":15600.0}"#
    let event = try decoder.decode(AgentStatusEvent.self, from: Data(json.utf8))
    XCTAssertEqual(event.event, "awake_ceiling_prompt")
    XCTAssertEqual(event.awakeSeconds ?? 0, 14400.5, accuracy: 0.001)

    let unknown = try decoder.decode(
      AgentStatusEvent.self, from: Data(#"{"version":1,"event":"something_new"}"#.utf8))
    XCTAssertEqual(unknown.event, "something_new")
    XCTAssertNil(unknown.promptDeadline)
  }

  // MARK: - The version gate

  /// A peer below `minStatusVersion` silently DROPS a Status envelope, so none is sent — otherwise
  /// `connect()` would wait out the probe timeout against an agent that can never answer.
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

  /// A peer at `minStatusVersion` that does not answer the probe reports no service either — but it
  /// must NOT take the connection down with it, unlike the File service: wakefulness is a badge, and
  /// retiring a connection that VCS and the file service are sharing costs far more than it is worth.
  func testAnUnansweredStatusProbeLeavesTheConnectionUsable() async throws {
    let fake = try FakeAgent(version: 4)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    XCTAssertTrue(fake.receivedServices.contains(4), "a protocol-4 peer IS probed")
    XCTAssertThrowsError(try connection.wakefulness())
    // Still alive: a VCS request on it still gets an answer.
    let reply = try await connection.request(AgentVCSRequest(method: "capabilities"), timeout: 2)
    XCTAssertNoThrow(try AgentVCSReply<AgentVCSCapabilities>.decode(reply))
  }

  func testAStatusCapableAgentAnswersTheVerdictAndAcceptsKeep() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let service = try connection.wakefulness()
    let status = try await service.status()
    XCTAssertEqual(status.display, .busyPastCeiling)
    try await service.keep()
  }

  /// The connect-time probe's reply is kept, not discarded: it is the only reading of the agent's
  /// prompt timeout the app is guaranteed to have before a ceiling prompt arrives, because the poll
  /// that would otherwise supply it runs only while the Changes inspector is open.
  func testTheConnectProbeKeepsTheAgentsPromptTimeout() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    XCTAssertEqual(try connection.wakefulness().negotiatedPromptTimeout ?? 0, 600, accuracy: 0.001)
  }

  /// The prompt arrives unsolicited on stream 0 of service 4. Before #208 that envelope would have
  /// failed `receive()`'s validity guard and torn down every in-flight VCS and File request with it.
  func testACeilingPromptOnStreamZeroIsDeliveredAndDoesNotFailTheConnection() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let service = try connection.wakefulness()
    // Bounded, so a prompt that never arrives fails the test instead of hanging the suite. Note what
    // actually makes this race-free: NOT the ordering below — `Task {}` does not start
    // synchronously, so the push can land first — but the stream's `.bufferingNewest(1)` policy,
    // which holds the prompt until someone iterates. Change that policy and this goes flaky.
    let waiter = Task { () -> AgentCeilingPrompt? in
      for await prompt in service.prompts { return prompt }
      return nil
    }
    let guardTask = Task {
      try? await Task.sleep(for: .seconds(5))
      waiter.cancel()
    }
    fake.pushCeilingPrompt()
    let received = await waiter.value
    guardTask.cancel()
    let prompt = try XCTUnwrap(received, "no ceiling prompt arrived")
    XCTAssertEqual(prompt.awakeSeconds, 14400.5, accuracy: 0.001)
    XCTAssertEqual(prompt.promptDeadline, 15600, accuracy: 0.001)
    // The connection survived the stream-0 envelope — which is the regression this pins: before the
    // Status service was allowed on stream 0, that envelope failed `receive()`'s validity guard and
    // took every in-flight request with it.
    _ = try await service.status()
  }

  // MARK: - Settings to flags

  func testDefaultSettingsMapToTheAgentsOwnDefaults() {
    let arguments = AgentWakefulnessSettings().serveArguments(socket: "/tmp/a.sock")
    XCTAssertEqual(
      arguments,
      [
        "serve", "--socket", "/tmp/a.sock",
        "--awake-ceiling", "14400",
        "--awake-prompt-timeout", "600",
      ])
  }

  func testAskAtCeilingAddsItsFlagAndNothingElse() {
    let settings = AgentWakefulnessSettings(ceiling: 7200, promptTimeout: 300, ask: true)
    XCTAssertEqual(
      settings.serveArguments(socket: "/tmp/b.sock"),
      [
        "serve", "--socket", "/tmp/b.sock",
        "--awake-ceiling", "7200",
        "--awake-prompt-timeout", "300",
        "--ask-at-awake-ceiling",
      ])
  }

  /// The environment form carries the same three values, so the `serve` that `attach` spawns with no
  /// flags is configured the same way as the one the app spawns directly.
  func testTheEnvironmentFormMatchesTheFlags() {
    let settings = AgentWakefulnessSettings(ceiling: 7200, promptTimeout: 300, ask: true)
    let environment = Dictionary(uniqueKeysWithValues: settings.serveEnvironment)
    XCTAssertEqual(environment["WR_AGENT_AWAKE_CEILING"], "7200")
    XCTAssertEqual(environment["WR_AGENT_AWAKE_PROMPT_TIMEOUT"], "300")
    XCTAssertEqual(environment["WR_AGENT_ASK_AT_AWAKE_CEILING"], "1")
    XCTAssertNil(
      Dictionary(uniqueKeysWithValues: AgentWakefulnessSettings().serveEnvironment)[
        "WR_AGENT_ASK_AT_AWAKE_CEILING"], "off is absent, not \"0\": the agent reads presence")
  }

  /// The socket flag has to stay first and unchanged: `LocalAgentVCS` connects to that exact path,
  /// and a wakefulness flag that displaced it would start an agent nobody can reach.
  func testTheSocketArgumentIsUntouchedByTheWakefulnessFlags() {
    let arguments = AgentWakefulnessSettings(ceiling: 1, promptTimeout: 2, ask: true)
      .serveArguments(socket: "/a path/with spaces.sock")
    XCTAssertEqual(Array(arguments.prefix(3)), ["serve", "--socket", "/a path/with spaces.sock"])
  }

  // MARK: - The prompt state

  private let origin = Date(timeIntervalSince1970: 1_700_000_000)
  private let raised = AgentCeilingPrompt(awakeSeconds: 14400.5, promptDeadline: 15600)

  func testAPromptCountsDownFromThePolledTimeoutNotTheAgentsDeadline() {
    var state = AwakeCeilingPromptState()
    XCTAssertFalse(state.isShowing)
    state.raise(raised, promptTimeout: 600, now: origin)
    XCTAssertTrue(state.isShowing)
    XCTAssertEqual(state.awakeSeconds ?? 0, 14400.5, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(state.remaining(now: origin)), 600, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: origin.addingTimeInterval(59))), 541, accuracy: 0.001)
  }

  /// No poll has happened, so nothing knows the agent's configured timeout: the agent's own default
  /// is the fallback, never the raw `prompt_deadline` (which is on a clock this process cannot read).
  func testAnUnpolledPromptFallsBackToTheAgentsDefaultTimeout() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: nil, now: origin)
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: origin)),
      AgentCeilingPrompt.defaultPromptTimeout, accuracy: 0.001)
  }

  func testKeepClearsThePrompt() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    state.keep()
    XCTAssertFalse(state.isShowing)
    XCTAssertNil(state.remaining(now: origin))
    XCTAssertNil(state.awakeSeconds)
    XCTAssertFalse(state.keepFailed)
  }

  /// A `keep` that never reached the agent must NOT leave the card cleared. The agent moves
  /// `Prompted` to `Suppressed` at the deadline and publishes IDLE, so a swallowed failure sleeps the
  /// box after the user asked for the opposite. The card comes back on the ORIGINAL deadline — the
  /// agent's clock never moved — and says why.
  func testAFailedKeepPutsThePromptBackOnItsOriginalDeadline() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let beforeKeep = state
    state.keep()
    XCTAssertFalse(state.isShowing)

    state.restoreAfterFailedKeep(beforeKeep)
    XCTAssertTrue(state.isShowing)
    XCTAssertTrue(state.keepFailed)
    XCTAssertEqual(state.awakeSeconds ?? 0, 14400.5, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: origin)), 600, accuracy: 0.001,
      "the agent's deadline did not move because the request failed")
  }

  /// A restored prompt still expires on its own: the retry window is the time that was already left,
  /// not a fresh one.
  func testARestoredPromptStillExpiresOnTheOriginalDeadline() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let beforeKeep = state
    state.keep()
    state.restoreAfterFailedKeep(beforeKeep)
    state.tick(now: origin.addingTimeInterval(599))
    XCTAssertTrue(state.isShowing)
    state.tick(now: origin.addingTimeInterval(600))
    XCTAssertFalse(state.isShowing)
    XCTAssertFalse(state.keepFailed, "clearing drops the failure flag with everything else")
  }

  /// A fresh prompt after a failed keep is a clean slate, not a retry.
  func testANewPromptClearsTheFailedKeepFlag() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let beforeKeep = state
    state.keep()
    state.restoreAfterFailedKeep(beforeKeep)
    XCTAssertTrue(state.keepFailed)
    state.raise(raised, promptTimeout: 600, now: origin.addingTimeInterval(9000))
    XCTAssertFalse(state.keepFailed)
  }

  /// `Duration.seconds(Double)` traps on an out-of-range value, and `awakeSeconds` is a
  /// non-optional `Double` straight off the socket. Every other wire path here drops garbage; the
  /// formatter must not be the exception that crashes the app.
  func testAnAbsurdDurationOffTheWireIsClampedRatherThanTrapping() {
    XCTAssertEqual(wakefulnessDuration(0), .seconds(0))
    XCTAssertEqual(wakefulnessDuration(90), .seconds(90))
    XCTAssertEqual(wakefulnessDuration(-5), .seconds(0))
    XCTAssertEqual(wakefulnessDuration(.nan), .seconds(0))
    XCTAssertEqual(wakefulnessDuration(-.infinity), .seconds(0))
    // +∞ clamps to the ceiling like any other too-large value: "longer than the UI can say", not
    // "not busy at all".
    XCTAssertEqual(wakefulnessDuration(.infinity), wakefulnessDuration(1e30))
    XCTAssertGreaterThan(wakefulnessDuration(.infinity), .seconds(365 * 24 * 3600))
    // The point of the test: formatting these must not crash.
    for seconds in [1e30, -1e30, Double.infinity, Double.nan] {
      _ = wakefulnessDuration(seconds).formatted(
        .units(allowed: [.hours, .minutes], width: .narrow))
    }
  }

  /// The deadline passing and the user dismissing are the same outcome, which is OQ22's rule: no
  /// answer lets the box sleep, and the app says nothing to the agent either way.
  func testThePromptClearsItselfOnceTheDeadlinePasses() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    state.tick(now: origin.addingTimeInterval(599))
    XCTAssertTrue(state.isShowing, "a tick before the deadline changes nothing")
    state.tick(now: origin.addingTimeInterval(600))
    XCTAssertFalse(state.isShowing)
    state.tick(now: origin.addingTimeInterval(9999))
    XCTAssertFalse(state.isShowing, "ticking an already-cleared prompt is a no-op")
  }

  func testDismissingIsTheSameAsLettingItExpire() {
    var dismissed = AwakeCeilingPromptState()
    dismissed.raise(raised, promptTimeout: 600, now: origin)
    dismissed.dismiss()
    var expired = AwakeCeilingPromptState()
    expired.raise(raised, promptTimeout: 600, now: origin)
    expired.tick(now: origin.addingTimeInterval(600))
    XCTAssertEqual(dismissed, expired)
  }

  /// A second prompt supersedes the first rather than stacking: there is one box and one ceiling.
  func testASecondPromptReplacesTheFirst() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let later = origin.addingTimeInterval(300)
    state.raise(
      AgentCeilingPrompt(awakeSeconds: 20000, promptDeadline: 21000), promptTimeout: 120, now: later
    )
    XCTAssertEqual(state.awakeSeconds ?? 0, 20000, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(state.remaining(now: later)), 120, accuracy: 0.001)
  }
}
