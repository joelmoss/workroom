import XCTest

@testable import Workroom

/// The app's half of the wakefulness service (issue #208): the wire decode, the protocol-version
/// gate, the settings-to-flags mapping, the ceiling prompt's state machine, and the model's rules
/// (one poll loop, reconcile from every reply, the poll-before-event race, the staleness rule).
///
/// `FakeAgent` (`AgentFileIntegrationTests`) is the transport double throughout, for the same reason
/// the File service uses it: the cases worth pinning are ones the real binary cannot produce on
/// demand — an old peer, a prompt raised on cue. The real binary appears once, to pin the reply
/// shape the fixture claims to copy.
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

  private static let notPending: [(String, String)] = [
    (#""prompt_pending":true"#, #""prompt_pending":false"#),
    (#""prompt_deadline":15600.0"#, #""prompt_deadline":null"#),
  ]

  /// The fixture at a later reading of the agent's clock: a classifier that ticked.
  private static func ticked(to monotonic: Double) -> [(String, String)] {
    [(#""monotonic":15000.0"#, "\"monotonic\":\(monotonic)")]
  }

  // MARK: - Decoding

  func testStatusDecodesEveryFieldTheAgentSends() throws {
    let status = try status()
    XCTAssertTrue(status.running)
    XCTAssertEqual(status.verdict, "BUSY")
    XCTAssertTrue(status.busy)
    XCTAssertEqual(status.classifierVerdict, "BUSY")
    XCTAssertEqual(status.monotonic, 15000, accuracy: 0.001)
    XCTAssertEqual(status.awakeSeconds, 14400.5, accuracy: 0.001)
    XCTAssertTrue(status.awakeCeilingExceeded)
    XCTAssertTrue(status.promptPending)
    XCTAssertEqual(status.promptDeadline ?? 0, 15600, accuracy: 0.001)
    XCTAssertEqual(status.asserting, true)
    XCTAssertFalse(status.suppressed)
    XCTAssertEqual(status.ceilingSeconds ?? 0, 14400, accuracy: 0.001)
    XCTAssertEqual(status.promptTimeoutSeconds, 600, accuracy: 0.001)
    XCTAssertEqual(status.askAtCeiling, true)
    XCTAssertEqual(status.cpuFraction ?? 0, 0.0021, accuracy: 0.0001)
    XCTAssertEqual(status.verdictWritten, true)
  }

  /// The fixture above is a Swift string. This is the shipped binary: a field the agent renames or
  /// drops fails HERE, not as a badge that silently blanks. A macOS agent answers `running: false`
  /// with every field present, which is exactly what the shape check needs.
  func testTheShippedAgentsStatusReplyDecodesAndKeepIsAccepted() async throws {
    let agent = try AgentHarness.start()
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    connections.append(connection)
    let service = try connection.wakefulness()
    let status = try await service.status()
    XCTAssertFalse(status.running, "the classifier is Linux-only")
    XCTAssertNotNil(status.verdictWritten, "the field `unprotected` reads")
    XCTAssertNotNil(status.askAtCeiling, "the field the settings-mismatch line reads")
    XCTAssertNotNil(status.ceilingSeconds)
    try await service.keep()
  }

  /// The agent's clock is its own. `promptRemaining` is the ONLY subtraction allowed on it, and both
  /// operands come from the same reply — 15600 - 15000 = 600, never `deadline - Date()`.
  func testPromptRemainingUsesTheAgentsOwnClockReading() throws {
    XCTAssertEqual(try XCTUnwrap(try status().promptRemaining), 600, accuracy: 0.001)
  }

  func testNoPromptMeansNoRemaining() throws {
    let status = try status(Self.notPending)
    XCTAssertNil(status.promptRemaining)
    XCTAssertFalse(status.promptPending)
  }

  /// Past the ceiling outranks plain busy: the badge must say so, because that is the whole point of
  /// an advisory ceiling nobody acts on.
  func testDisplayRanksCeilingAboveBusy() throws {
    XCTAssertEqual(try status().display, .busyPastCeiling)
    let notExceeded = (#""awake_ceiling_exceeded":true"#, #""awake_ceiling_exceeded":false"#)
    XCTAssertEqual(try status([notExceeded]).display, .busy)
    XCTAssertEqual(
      try status([notExceeded, (#""busy":true"#, #""busy":false"#)]).display, .idle)
  }

  /// The one state the badge must not soften. `Suppressed` is `awake_ceiling_exceeded: true` with
  /// `busy: false`: the prompt went unanswered and the provider may now sleep a box whose classifier
  /// still says BUSY. "Busy past the ceiling, nothing has been slept" was the wrong sentence for it.
  /// And `verdict_written: false` is a BUSY verdict that never reached the shim: same badge.
  func testUnprotectedOutranksEverything() throws {
    let suppressed = try status([
      (#""busy":true"#, #""busy":false"#), (#""suppressed":false"#, #""suppressed":true"#),
    ])
    XCTAssertEqual(suppressed.display, .busyUnprotected)
    XCTAssertTrue(suppressed.unprotected)

    let unwritten = try status([(#""verdict_written":true"#, #""verdict_written":false"#)])
    XCTAssertEqual(unwritten.display, .busyUnprotected)

    // An IDLE verdict that was not written protects nothing that needs protecting.
    let idleUnwritten = try status([
      (#""verdict_written":true"#, #""verdict_written":false"#),
      (#""busy":true"#, #""busy":false"#),
      (#""awake_ceiling_exceeded":true"#, #""awake_ceiling_exceeded":false"#),
    ])
    XCTAssertEqual(idleUnwritten.display, .idle)

    // An agent that predates the field is not accused of anything.
    let older = try status([(#","verdict_written":true"#, "")])
    XCTAssertNil(older.verdictWritten)
    XCTAssertEqual(older.display, .busyPastCeiling)
  }

  /// The fields nothing displays are optional: an agent that renames one must not blank the badge.
  func testDiagnosticFieldsAreOptional() throws {
    let trimmed = try status([
      (#""verdict":"BUSY","#, ""), (#""classifier_verdict":"BUSY","#, ""),
      (#""asserting":true,"#, ""), (#""ceiling_seconds":14400.0,"#, ""),
      (#""ask_at_ceiling":true,"#, ""), (#""cpu_fraction":0.0021,"#, ""),
    ])
    XCTAssertEqual(trimmed.display, .busyPastCeiling)
    XCTAssertNil(trimmed.cpuFraction)
  }

  /// The agent's settings are flags fixed at its start, and it outlives the app; the reply says what
  /// it was started with, and this is the sentence that tells the user the toggle they flipped has
  /// not reached it.
  func testTheSettingsMismatchNamesWhatTheRunningAgentHas() throws {
    let status = try status()
    XCTAssertNil(
      status.settingsMismatch(against: AgentWakefulnessSettings(ceiling: 14400, ask: true)))
    let mismatch = try XCTUnwrap(
      status.settingsMismatch(against: AgentWakefulnessSettings(ceiling: 7200, ask: false)))
    XCTAssertTrue(mismatch.contains("ask-before-sleep on"), mismatch)
    XCTAssertTrue(mismatch.contains("4h ceiling"), mismatch)
    XCTAssertTrue(mismatch.contains("when it next starts"), mismatch)
    // An older agent that reports neither has nothing to disagree with.
    let older = try self.status([
      (#""ceiling_seconds":14400.0,"#, ""), (#""ask_at_ceiling":true,"#, ""),
    ])
    XCTAssertNil(older.settingsMismatch(against: AgentWakefulnessSettings(ceiling: 1, ask: false)))
  }

  func testAnErrorReplyIsAServiceFailure() {
    let json = #"{"version":1,"error":{"unsupported":"status requests are ..."}}"#
    XCTAssertThrowsError(try decode(json)) { error in
      guard case HostConnectionError.serviceUnavailable = error else {
        return XCTFail("expected serviceUnavailable, got \(error)")
      }
    }
  }

  func testAWrongVersionReplyIsAServiceFailure() {
    XCTAssertThrowsError(try decode(#"{"version":2,"result":{}}"#)) { error in
      XCTAssertEqual(
        error as? HostConnectionError,
        .serviceUnavailable("Unsupported status response version."))
    }
  }

  /// A `keep` the agent declined must not read as a `keep` that landed: the card clears on success.
  func testADeclinedKeepIsAnError() {
    XCTAssertNoThrow(
      try AgentStatusReply<AgentKept>.decode(Data(#"{"version":1,"result":{"kept":true}}"#.utf8)))
    let declined = try? AgentStatusReply<AgentKept>.decode(
      Data(#"{"version":1,"result":{"kept":false}}"#.utf8))
    XCTAssertEqual(declined?.kept, false, "decodes; the service turns it into an error")
  }

  /// Forward compatibility, the same rule the file events follow: an event kind this build does not
  /// know is dropped, never an error.
  func testTheCeilingPromptEventDecodes() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let event = try decoder.decode(
      AgentStatusEvent.self, from: Data(FakeAgent.ceilingPromptJSON.utf8))
    XCTAssertEqual(event.version, 1)
    XCTAssertEqual(event.event, "awake_ceiling_prompt")
    XCTAssertEqual(event.awakeSeconds ?? 0, 14400.5, accuracy: 0.001)

    let unknown = try decoder.decode(
      AgentStatusEvent.self, from: Data(#"{"version":1,"event":"something_new"}"#.utf8))
    XCTAssertEqual(unknown.event, "something_new")
    XCTAssertNil(unknown.promptDeadline)
  }

  // MARK: - The version gate

  /// A peer below `minStatusVersion` silently DROPS a Status envelope, so none is sent — otherwise
  /// every poll would wait out its timeout against an agent that can never answer.
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

  private func firstPrompt(
    on service: AgentWakefulnessService, after push: () -> Void
  ) async -> AgentCeilingPrompt? {
    // Bounded, so a prompt that never arrives fails the test instead of hanging the suite. Note what
    // actually makes this race-free: NOT the ordering below — `Task {}` does not start
    // synchronously, so the push can land first — but the stream's `.bufferingNewest(1)` policy,
    // which holds the prompt until someone iterates. Change that policy and this goes flaky.
    let waiter = Task { () -> AgentCeilingPrompt? in
      for await prompt in service.prompts { return prompt }
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

  /// The prompt arrives unsolicited on stream 0 of service 4. Before #208 that envelope would have
  /// failed `receive()`'s validity guard and torn down every in-flight VCS and File request with it.
  func testACeilingPromptOnStreamZeroIsDeliveredAndDoesNotFailTheConnection() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let service = try connection.wakefulness()
    let received = await firstPrompt(on: service) { fake.pushCeilingPrompt() }
    let prompt = try XCTUnwrap(received, "no ceiling prompt arrived")
    XCTAssertEqual(prompt.awakeSeconds, 14400.5, accuracy: 0.001)
    XCTAssertEqual(prompt.promptDeadline, 15600, accuracy: 0.001)
    // The connection survived the stream-0 envelope — which is the regression this pins: before the
    // Status service was allowed on stream 0, that envelope failed `receive()`'s validity guard and
    // took every in-flight request with it.
    _ = try await service.status()
  }

  /// A malformed event, an unknown kind, or a version this build does not speak is dropped — the
  /// connection stays up and no prompt is raised. One stream per connection, so one fake per case.
  func testAMalformedOrForeignStatusEventIsDroppedAndTheConnectionSurvives() async throws {
    for body in [
      #"{"version":2,"event":"awake_ceiling_prompt","awake_seconds":1.0,"prompt_deadline":2.0}"#,
      #"{"version":1,"event":"awake_ceiling_prompt","awake_seconds":1.0}"#,
      #"{"version":1,"event":"something_new","awake_seconds":1.0,"prompt_deadline":2.0}"#,
      "not json",
    ] {
      let fake = try FakeAgent(version: 4, status: true)
      fakes.append(fake)
      let connection = try await AgentVCSConnection.connect(
        host: .local, socketPath: fake.socketPath)
      connections.append(connection)
      let service = try connection.wakefulness()
      let received = await firstPrompt(on: service) { fake.pushCeilingPrompt(body: body) }
      XCTAssertNil(received, "dropped: \(body)")
      _ = try await service.status()
    }
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
  /// flags is configured the same way as the one the app spawns directly. Under `WORKROOM_SESSION_`,
  /// because that is the prefix the agent scrubs from the user's shell.
  func testTheEnvironmentFormMatchesTheFlags() {
    let settings = AgentWakefulnessSettings(ceiling: 7200, promptTimeout: 300, ask: true)
    let environment = Dictionary(uniqueKeysWithValues: settings.serveEnvironment)
    XCTAssertEqual(environment["WORKROOM_SESSION_AWAKE_CEILING"], "7200")
    XCTAssertEqual(environment["WORKROOM_SESSION_AWAKE_PROMPT_TIMEOUT"], "300")
    XCTAssertEqual(environment["WORKROOM_SESSION_ASK_AT_AWAKE_CEILING"], "1")
    XCTAssertNil(
      Dictionary(uniqueKeysWithValues: AgentWakefulnessSettings().serveEnvironment)[
        "WORKROOM_SESSION_ASK_AT_AWAKE_CEILING"],
      "off is absent, not \"0\": the agent reads presence")
    for (key, _) in settings.serveEnvironment {
      XCTAssertTrue(key.hasPrefix("WORKROOM_SESSION_"), "\(key) would reach the user's shell")
    }
  }

  /// The two duration keys have no UI, so nothing but this stops a hand-edited preference reaching
  /// the agent as `nan`, `inf` or `-3600` on its command line. The agent would fall back to its
  /// defaults for those; the app does the same, so the two agree on what it runs with.
  func testUnusablePreferencesBecomeTheAgentsDefaults() {
    for bad in [Double.nan, .infinity, -.infinity, 0, -1] {
      let settings = AgentWakefulnessSettings(
        ceilingHours: bad, promptTimeoutMinutes: bad, ask: true)
      XCTAssertEqual(settings.ceiling, 14400, "ceiling \(bad)")
      XCTAssertEqual(settings.promptTimeout, 600, "prompt timeout \(bad)")
      XCTAssertTrue(settings.ask)
    }
    let good = AgentWakefulnessSettings(ceilingHours: 0.5, promptTimeoutMinutes: 1, ask: false)
    XCTAssertEqual(good.ceiling, 1800)
    XCTAssertEqual(good.promptTimeout, 60)
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
    XCTAssertEqual(state.agentDeadline ?? 0, 15600, accuracy: 0.001)
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

  /// `prompt_timeout_seconds` is a wire value. A NaN deadline is one `tick` can never reach: a card
  /// that never clears and eats clicks for the rest of the app's life.
  func testAGarbageTimeoutOffTheWireCannotMakeAnUnexpirableCard() {
    for garbage in [Double.nan, .infinity, -1, 1e300] {
      var state = AwakeCeilingPromptState()
      state.raise(raised, promptTimeout: garbage, now: origin)
      let remaining = try? XCTUnwrap(state.remaining(now: origin))
      XCTAssertNotNil(remaining)
      XCTAssertFalse((remaining ?? 0).isNaN, "\(garbage)")
      state.tick(now: origin.addingTimeInterval(101 * 365 * 24 * 3600))
      XCTAssertFalse(state.isShowing, "a card raised with \(garbage) must still expire")
    }
  }

  func testKeepClearsThePrompt() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    state.keep()
    XCTAssertFalse(state.isShowing)
    XCTAssertNil(state.remaining(now: origin))
    XCTAssertNil(state.awakeSeconds)
    XCTAssertNil(state.agentDeadline)
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

    state.restoreAfterFailedKeep(beforeKeep, now: origin)
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
    state.restoreAfterFailedKeep(beforeKeep, now: origin)
    state.tick(now: origin.addingTimeInterval(599))
    XCTAssertTrue(state.isShowing)
    state.tick(now: origin.addingTimeInterval(600))
    XCTAssertFalse(state.isShowing)
    XCTAssertFalse(state.keepFailed, "clearing drops the failure flag with everything else")
  }

  /// Click with two seconds left and the request drops: its 5 s timeout lands after the deadline,
  /// and a card restored with a past deadline would flash for one tick and vanish — the box about to
  /// sleep, the user's explicit "keep" answered with nothing. A retry into `Suppressed` still works,
  /// so the card gets a minute.
  func testAFailedKeepAfterTheDeadlineStillOffersARetry() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 2, now: origin)
    let beforeKeep = state
    state.keep()
    let late = origin.addingTimeInterval(7)
    state.restoreAfterFailedKeep(beforeKeep, now: late)
    XCTAssertTrue(state.isShowing)
    XCTAssertTrue(state.keepFailed)
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: late)), AwakeCeilingPromptState.retryGrace, accuracy: 0.001
    )
    state.tick(now: late)
    XCTAssertTrue(state.isShowing, "not cleared on the next tick")
  }

  /// A `keep` from the badge, with no card up, that fails: the grace IS the card, so the click is
  /// answered with the failure and a retry rather than silence.
  func testAFailedKeepWithNoCardRaisesTheFailureAsACard() {
    var state = AwakeCeilingPromptState()
    let empty = state
    state.keep()
    state.restoreAfterFailedKeep(empty, now: origin)
    XCTAssertTrue(state.isShowing)
    XCTAssertTrue(state.keepFailed)
    XCTAssertNil(state.awakeSeconds)
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: origin)), AwakeCeilingPromptState.retryGrace,
      accuracy: 0.001
    )
  }

  /// A prompt raised while the `keep` was in flight is newer than the one being restored: it wins.
  func testAFailedKeepDoesNotStompANewerPrompt() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let beforeKeep = state
    state.keep()
    let newer = AgentCeilingPrompt(awakeSeconds: 20000, promptDeadline: 21000)
    state.raise(newer, promptTimeout: 120, now: origin.addingTimeInterval(3))
    state.restoreAfterFailedKeep(beforeKeep, now: origin.addingTimeInterval(5))
    XCTAssertEqual(state.agentDeadline ?? 0, 21000, accuracy: 0.001)
    XCTAssertFalse(state.keepFailed)
  }

  /// A fresh prompt after a failed keep is a clean slate, not a retry.
  func testANewPromptClearsTheFailedKeepFlag() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let beforeKeep = state
    state.keep()
    state.restoreAfterFailedKeep(beforeKeep, now: origin)
    XCTAssertTrue(state.keepFailed)
    state.raise(
      AgentCeilingPrompt(awakeSeconds: 20000, promptDeadline: 21000), promptTimeout: 600,
      now: origin.addingTimeInterval(9000))
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

  /// The SAME prompt again — the event after a reply that already raised it — keeps the countdown it
  /// has: the reply's remaining time is exact and the event's is a fresh full timeout.
  func testTheSamePromptTwiceKeepsItsCountdown() {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    state.raise(raised, promptTimeout: 600, now: origin.addingTimeInterval(300))
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: origin.addingTimeInterval(300))), 300, accuracy: 0.001)
  }

  // MARK: - Reconciling with a status reply

  /// An app that connects while a prompt is pending gets no event — the agent sent it once, to
  /// whoever was listening then. The reply is where it shows up, with the exact time left.
  func testAPendingPromptInAReplyRaisesTheCard() throws {
    var state = AwakeCeilingPromptState()
    let reply = try status([(#""monotonic":15000.0"#, #""monotonic":15450.0"#)])
    state.reconcile(reply, now: origin)
    XCTAssertTrue(state.isShowing)
    XCTAssertEqual(state.awakeSeconds ?? 0, 14400.5, accuracy: 0.001)
    XCTAssertEqual(state.agentDeadline ?? 0, 15600, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(state.remaining(now: origin)), 150, accuracy: 0.001)
  }

  /// The agent answers a prompt on its own — the job finished, the user typed into the box, it
  /// resumed, another Workroom sent keep — and says so only in the next reply.
  func testAReplyWithNoPromptWithdrawsTheCard() throws {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    state.reconcile(try status(Self.notPending), now: origin.addingTimeInterval(10))
    XCTAssertFalse(state.isShowing)
  }

  /// The event's countdown is optimistic by the time the event spent in flight (or buffered while
  /// the watch was asleep); the reply about the same prompt corrects it without touching anything
  /// else.
  func testAReplyAboutTheShowingPromptCorrectsTheCountdown() throws {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let reply = try status([(#""monotonic":15000.0"#, #""monotonic":15500.0"#)])
    state.reconcile(reply, now: origin.addingTimeInterval(10))
    XCTAssertEqual(
      try XCTUnwrap(state.remaining(now: origin.addingTimeInterval(10))), 100, accuracy: 0.001)
    XCTAssertFalse(state.keepFailed)
  }

  /// A different deadline is a different prompt, and it wins.
  func testAReplyAboutANewerPromptReplacesTheCard() throws {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let reply = try status([
      (#""prompt_deadline":15600.0"#, #""prompt_deadline":30600.0"#),
      (#""monotonic":15000.0"#, #""monotonic":30000.0"#),
    ])
    state.reconcile(reply, now: origin)
    XCTAssertEqual(state.agentDeadline ?? 0, 30600, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(state.remaining(now: origin)), 600, accuracy: 0.001)
  }

  /// The failed-keep card is the user's retry, not the agent's prompt: the agent (which by now says
  /// no prompt is pending, and may be `Suppressed`) does not get to withdraw it. Its own grace does.
  func testAReplyDoesNotWithdrawAFailedKeepsRetry() throws {
    var state = AwakeCeilingPromptState()
    state.raise(raised, promptTimeout: 600, now: origin)
    let beforeKeep = state
    state.keep()
    state.restoreAfterFailedKeep(beforeKeep, now: origin)
    state.reconcile(try status(Self.notPending), now: origin)
    XCTAssertTrue(state.isShowing)
    XCTAssertTrue(state.keepFailed)
  }

  // MARK: - The model

  private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var _reply: Result<AgentWakefulness, Error>
    private var _calls = 0
    private var _gate: CheckedContinuation<Void, Never>?
    private var _holdCall: Int?

    init(_ reply: AgentWakefulness) { _reply = .success(reply) }

    var reply: Result<AgentWakefulness, Error> {
      get { lock.withLock { _reply } }
      set { lock.withLock { _reply = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    /// The Nth call parks until `release()`: a request on the wire whose reply has not come back.
    func hold(call: Int) { lock.withLock { _holdCall = call } }

    func release() {
      let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        defer { _gate = nil }
        return _gate
      }
      gate?.resume()
    }

    @Sendable func status() async throws -> AgentWakefulness {
      let held = lock.withLock { () -> Bool in
        _calls += 1
        return _holdCall == _calls
      }
      if held {
        await withCheckedContinuation { continuation in
          lock.withLock { _gate = continuation }
        }
      }
      return try reply.get()
    }

    private var _stream: AsyncStream<AgentCeilingPrompt>?

    /// Hands the stream out ONCE, then reports no connection: a finished stream handed out again
    /// would make the watch loop spin (prompts, status, an empty `for await`, repeat).
    func prompts(_ stream: AsyncStream<AgentCeilingPrompt>)
      -> @Sendable () async throws ->
      AsyncStream<AgentCeilingPrompt>
    {
      lock.withLock { _stream = stream }
      return { [self] in
        let taken = lock.withLock { () -> AsyncStream<AgentCeilingPrompt>? in
          defer { _stream = nil }
          return _stream
        }
        guard let taken else { throw Unavailable() }
        return taken
      }
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

  /// N badges (N windows with the inspector open, plus the card, plus Settings) are N callers of ONE
  /// poll, not N polls: with N loops one caller's failed round trip blanked every window's badge.
  @MainActor
  func testHoweverManyCallersThereIsOnePollLoop() async throws {
    let script = Script(try status())
    let model = WakefulnessModel(
      transport: .init(status: script.status, keep: {}, prompts: { throw Unavailable() }))
    let callers = (0..<3).map { _ in Task { await model.poll() } }
    await eventually("the first poll ran") { model.status != nil }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(script.calls, 1, "three callers, one round trip")
    for caller in callers { caller.cancel() }
    for caller in callers { await caller.value }
    XCTAssertNotNil(model.status, "a cancelled poll leaves the last verdict standing")
  }

  /// Every reply reconciles the card: raised from a pending reply, withdrawn from a clear one.
  @MainActor
  func testEveryReplyReconcilesThePrompt() async throws {
    let script = Script(try status())
    let model = WakefulnessModel(
      transport: .init(status: script.status, keep: {}, prompts: { throw Unavailable() }))
    await model.refresh()
    XCTAssertTrue(model.prompt.isShowing)
    XCTAssertEqual(model.prompt.agentDeadline ?? 0, 15600, accuracy: 0.001)
    // A later tick, or the staleness rule would (rightly) distrust the reply.
    script.reply = .success(try status(Self.notPending + Self.ticked(to: 15010)))
    await model.refresh()
    XCTAssertFalse(model.prompt.isShowing)
    script.reply = .failure(Unavailable())
    await model.refresh()
    XCTAssertNil(model.status, "a failed poll clears the verdict")
  }

  /// The race the generation counter exists for: a `status` request leaves, the prompt event
  /// arrives, THEN the reply (older than the event) comes back saying no prompt is pending. It must
  /// not withdraw the prompt it predates. The next reply, requested after the event, may.
  @MainActor
  func testAReplyOlderThanThePromptCannotWithdrawIt() async throws {
    let script = Script(try status(Self.notPending))
    let (prompts, continuation) = AsyncStream<AgentCeilingPrompt>.makeStream()
    let model = WakefulnessModel(
      transport: .init(status: script.status, keep: {}, prompts: script.prompts(prompts)))
    model.startWatchingPrompts()
    await eventually("the watch's first status call") { script.calls == 1 }
    // The second call is the poll that leaves before the event. Each reply is a later tick, so the
    // staleness rule is not what suppresses it — only the generation guard is under test here.
    script.reply = .success(try status(Self.notPending + Self.ticked(to: 15010)))
    script.hold(call: 2)
    let inFlight = Task { await model.refresh() }
    await eventually("the poll is on the wire") { script.calls == 2 }
    continuation.yield(raised)
    await eventually("the event raised the card") { model.prompt.isShowing }
    script.release()
    await inFlight.value
    XCTAssertTrue(
      model.prompt.isShowing, "a reply requested before the prompt does not withdraw it")
    XCTAssertNotNil(model.status, "and it was not stale: the verdict itself was taken")
    script.reply = .success(try status(Self.notPending + Self.ticked(to: 15020)))
    await model.refresh()
    XCTAssertFalse(model.prompt.isShowing, "a reply requested after the prompt does")
    continuation.finish()
  }

  /// The connection that carried the prompt ended: its card would send `keep` into nothing. If the
  /// agent is still there, the next connection's first reply raises the prompt again.
  @MainActor
  func testTheCardIsWithdrawnWhenItsConnectionEnds() async throws {
    let script = Script(try status(Self.notPending))
    let (prompts, continuation) = AsyncStream<AgentCeilingPrompt>.makeStream()
    let model = WakefulnessModel(
      transport: .init(status: script.status, keep: {}, prompts: script.prompts(prompts)))
    model.startWatchingPrompts()
    await eventually("the watch is up") { script.calls == 1 }
    continuation.yield(raised)
    await eventually("raised") { model.prompt.isShowing }
    continuation.finish()
    await eventually("withdrawn with the connection") { !model.prompt.isShowing }
  }

  /// The reader's staleness rule: a classifier that has not ticked between two polls is saying
  /// nothing about the box now. Its last verdict is not shown; when it ticks again, it is.
  @MainActor
  func testAClassifierThatStoppedTickingIsNotShown() async throws {
    let script = Script(try status(Self.notPending))
    let model = WakefulnessModel(
      transport: .init(status: script.status, keep: {}, prompts: { throw Unavailable() }))
    await model.refresh()
    XCTAssertNotNil(model.status)
    await model.refresh()
    XCTAssertNil(model.status, "same monotonic twice while running: stale")
    script.reply = .success(
      try status(Self.notPending + Self.ticked(to: 15010)))
    await model.refresh()
    XCTAssertNotNil(model.status, "it ticked again")
    // A macOS agent never ticks and never claims to: not stale, just not running.
    script.reply = .success(
      try status(Self.notPending + [(#""running":true"#, #""running":false"#)]))
    await model.refresh()
    await model.refresh()
    XCTAssertEqual(model.status?.running, false)
  }

  /// A failed `keep` brings the card back; a successful one leaves it cleared.
  @MainActor
  func testKeepClearsOptimisticallyAndComesBackOnFailure() async throws {
    let script = Script(try status())
    let failing = WakefulnessModel(
      transport: .init(
        status: script.status, keep: { throw Unavailable() }, prompts: { throw Unavailable() }))
    await failing.refresh()
    XCTAssertTrue(failing.prompt.isShowing)
    failing.keep()
    XCTAssertFalse(failing.prompt.isShowing, "cleared optimistically")
    await eventually("the failure brought it back") { failing.prompt.keepFailed }
    XCTAssertTrue(failing.prompt.isShowing)

    let landing = WakefulnessModel(
      transport: .init(status: script.status, keep: {}, prompts: { throw Unavailable() }))
    await landing.refresh()
    landing.keep()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(landing.prompt.isShowing)
    XCTAssertFalse(landing.prompt.keepFailed)
  }
}
