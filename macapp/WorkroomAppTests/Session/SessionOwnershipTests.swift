import Darwin
import Foundation
import WorkroomSessionProtocol
import XCTest

@testable import Workroom

/// `PersistentSessionControlClient.ownership` — telling "the daemon says no" apart from "the daemon
/// never answered".
///
/// **Why this needed its own method.** `transact` returns nil for a connect failure, a write
/// failure, an EOF, its 2-second timeout AND a perfectly good reply that happens to name no
/// session. `info` therefore cannot distinguish them, and folding all of it into "not owned" is
/// what let a slow daemon route one of its own live sessions to the agent — which creates on first
/// attach, so it forked a second pty under the same id, orphaned the user's running shell where no
/// pane could reach it, and showed a fresh prompt as though nothing had been lost.
final class SessionOwnershipTests: XCTestCase {
  private var directory: URL!
  private var servers: [Int32] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    // Short path: a unix socket address is capped at 104 bytes, and the per-test temporary
    // directory blows that.
    directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("wr-own-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    for server in servers { close(server) }
    servers = []
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func identifier() -> SessionIdentifier {
    SessionIdentifier(uuidString: UUID().uuidString)!
  }

  /// A daemon that answers `info` with `reply`, or — when nil — accepts and then says nothing at
  /// all, which is the wedged daemon this whole distinction exists for.
  /// Each call gets its own socket: the fake accepts exactly one connection, so a test that makes
  /// two calls needs two of them, and reusing the path fails to bind with `EADDRINUSE`.
  private func fakeDaemon(reply: [SessionDescriptor]?) throws -> String {
    let socketPath = directory.appendingPathComponent("d\(servers.count).sock").path
    let listener = try Self.listen(at: socketPath)
    servers.append(listener)
    Thread.detachNewThread {
      let accepted = accept(listener, nil, nil)
      guard accepted >= 0 else { return }
      guard let reply else {
        // Held open past the client's 2s deadline WITHOUT replying. Closing instead would be an
        // EOF, which is a different failure and one the old code already handled the same way.
        Thread.sleep(forTimeInterval: 4)
        close(accepted)
        return
      }
      let frame = SessionFrame(
        kind: .sessions, payload: SessionDescriptor.encodeList(reply))
      let bytes = frame.encoded()
      _ = bytes.withUnsafeBytes { Darwin.send(accepted, $0.baseAddress, $0.count, 0) }
      Thread.sleep(forTimeInterval: 0.3)
      close(accepted)
    }
    return socketPath
  }

  /// The case the old `Bool` got wrong, and the reason for the whole change.
  ///
  /// A daemon that accepts the connection and then does not answer is indistinguishable from one
  /// that answered "no such session" if you only look at `info`. Asserting BOTH here is the point:
  /// the two calls must disagree, or `ownership` has bought nothing.
  func testASilentDaemonIsUnreachableNotNotOwned() throws {
    let socketPath = try fakeDaemon(reply: nil)
    let client = PersistentSessionControlClient(socketPath: socketPath)
    let id = identifier()

    XCTAssertNil(client.info(identifier: id), "info cannot tell this from an empty answer")

    let client2 = PersistentSessionControlClient(socketPath: try fakeDaemon(reply: nil))
    guard case .unreachable = client2.ownership(identifier: id) else {
      return XCTFail("a daemon that never answered must not report notOwned")
    }
  }

  /// The other half: a daemon that DOES answer, naming no session, is a definitive no. Without
  /// this, "always report unreachable" would pass the test above.
  func testADaemonThatAnswersWithNoSessionIsNotOwned() throws {
    let socketPath = try fakeDaemon(reply: [])
    let client = PersistentSessionControlClient(socketPath: socketPath)

    guard case .notOwned = client.ownership(identifier: identifier()) else {
      return XCTFail("an empty answer is an answer")
    }
  }

  func testADaemonThatNamesTheSessionOwnsIt() throws {
    let id = identifier()
    let descriptor = SessionDescriptor(
      identifier: id, shellProcessID: 4242, ttyDevice: 0, workingDirectory: "/tmp",
      isAttached: false)
    let client = PersistentSessionControlClient(
      socketPath: try fakeDaemon(reply: [descriptor]))

    guard case .owned = client.ownership(identifier: id) else {
      return XCTFail("the daemon named this session")
    }
  }

  /// **A stale socket FILE is `notOwned`, not `unreachable`** — the case that made the previous
  /// version of this a P0.
  ///
  /// The daemon installs no SIGTERM handler and unlinks its socket only on the graceful path
  /// (`SessionDaemon.swift:167`), so any `pkill` — which is exactly what `make app-run` does —
  /// leaves `session.sock` behind. `existingSocketPath` finds the file, so the service builds a
  /// client and asks; `connect` then gets ECONNREFUSED. Folding that into `unreachable` pinned
  /// EVERY session to a daemon that was not running, and each pane's `workroom-session attach`
  /// respawned the daemon and forked a fresh pty for an id it had never held.
  ///
  /// Simulated exactly: bind and listen so the inode exists, then close the listener. The file
  /// stays, nothing answers.
  func testAStaleSocketFileIsNotOwnedRatherThanUnreachable() throws {
    let socketPath = directory.appendingPathComponent("stale.sock").path
    let listener = try Self.listen(at: socketPath)
    close(listener)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: socketPath),
      "the fixture must leave the FILE behind, or it is testing the absent case instead")

    guard
      case .notOwned = PersistentSessionControlClient(socketPath: socketPath)
        .ownership(identifier: identifier())
    else {
      return XCTFail("a socket nobody is listening on is a definitive no, not ambiguity")
    }
  }

  /// No socket at the path at all — also a definitive no, for the same reason.
  func testAnAbsentDaemonIsNotOwned() {
    let client = PersistentSessionControlClient(
      socketPath: directory.appendingPathComponent("nothing.sock").path)

    guard case .notOwned = client.ownership(identifier: identifier()) else {
      return XCTFail("nothing is listening, so nothing holds this session")
    }
  }

  private static func listen(at socketPath: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket()"])
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw NSError(
        domain: "test", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
    }
    withUnsafeMutableBytes(of: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self) { dest in
        for (index, byte) in pathBytes.enumerated() { dest[index] = CChar(bitPattern: byte) }
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.bind(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
      close(descriptor)
      throw NSError(
        domain: "test", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "bind/listen failed: \(errno)"])
    }
    return descriptor
  }
}

/// The routing rule itself, exhaustively.
///
/// `preferred` is Optional now — nil means "no backend can take a NEW session", which is what a
/// failed agent probe produces since the daemon stopped being a fallback. That makes the nil row of
/// each case the one worth reading.
final class SessionOwnerRuleTests: XCTestCase {
  /// The property the whole attach-only shim rests on, and the one an earlier draft of the change
  /// broke: a daemon that CLAIMS the session still wins even when nothing can take a new one. If
  /// this ever returns nil for `preferred: nil`, a user with an unhealthy agent loses every
  /// terminal an older build left running.
  func testADaemonThatOwnsTheSessionKeepsItEvenWithNowhereForNewOnes() {
    for preferred in [SessionBackend?.none, .rustAgent, .swiftDaemon] {
      XCTAssertEqual(
        PersistentSessionService.owner(preferred: preferred, daemon: .owned), .swiftDaemon,
        "the daemon holds that pty and cannot hand it over, whatever new sessions do")
    }
  }

  /// The drain. Without this the migration never happens — every session would stay on the daemon.
  ///
  /// REGRESSION: the `preferred: .swiftDaemon` row is gone. `preferred()` can no longer name the
  /// daemon under any condition, so that input is unreachable and asserting on it pinned behaviour
  /// that does not exist. The nil row replaces it, and is the live case.
  func testADefinitiveNoSendsTheSessionWhereNewOnesGo() {
    XCTAssertEqual(
      PersistentSessionService.owner(preferred: .rustAgent, daemon: .notOwned), .rustAgent)
    XCTAssertNil(
      PersistentSessionService.owner(preferred: nil, daemon: .notOwned),
      "nothing can take a new session, and the daemon disclaimed this one — so there is nowhere")
  }

  /// An unanswered probe resolves to NEITHER helper.
  ///
  /// This test previously asserted `.swiftDaemon`, on the reasoning that guessing wrong toward the
  /// daemon only fails loudly. That premise was false and the test was pinning it:
  /// `SessionDaemon.handleAttach` ends `create(request:connection:)` for an id it does not hold,
  /// exactly as the agent does, so BOTH guesses silently fork a second shell and orphan the first.
  ///
  /// Nil means the pane opens a plain shell — visible and recoverable — instead of duplicating a
  /// pty, which is neither.
  func testAnUnansweredProbeResolvesToNeitherHelper() {
    for preferred in [SessionBackend?.none, .rustAgent, .swiftDaemon] {
      XCTAssertNil(
        PersistentSessionService.owner(preferred: preferred, daemon: .unreachable),
        "there is no safe guess: both helpers create-on-attach, so either one forks a duplicate")
    }
  }
}

/// The wiring, not just the rule.
///
/// `owner(preferred:daemon:)` above is a pure function, and a test of it cannot tell whether
/// anything CALLS it correctly — the failure this repo has already paid for twice (see the commit
/// "cover the wiring, not just the writer"). These drive the real service through its injected
/// seams and assert on `attachCommand`, which is what `GhosttySurfaceView` actually consults.
final class PersistentSessionRoutingTests: XCTestCase {
  /// The case the attach-only shim exists for, end to end through the service: the agent is
  /// installed but broken, and a session the retired daemon still holds must STILL produce an
  /// attach command.
  ///
  /// **This is NOT a control for the view's guard, and an earlier version of this comment claimed
  /// it was.** Measured: restoring `PersistentSessionService.shared.isAvailable` to the guard in
  /// `GhosttySurfaceView.applyPersistentSession` leaves all three tests here green, because they
  /// drive the service directly and never reach the view. What they prove is the service-level
  /// contract — that the state is reachable and answers correctly. The call site is pinned
  /// separately by `PersistentSessionAttachGateTests`.
  @MainActor
  func testAnUnhealthyAgentStillReachesADaemonOwnedSession() {
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "exited 127") },
      ownership: { _ in .owned })

    XCTAssertNil(service.backend, "nothing can take a NEW session when the agent is unhealthy")
    XCTAssertFalse(service.isAvailable, "the global gate is false, which is why it must not gate")

    let sessionID = UUID()
    XCTAssertEqual(
      service.backend(forSession: sessionID), .swiftDaemon,
      "a daemon that claims the session owns it regardless of where new sessions go")
    let command = service.attachCommand(forSession: sessionID)
    XCTAssertNotNil(
      command,
      """
      an unhealthy agent stranded a session the daemon still holds. This is the whole reason the \
      attach client was kept — see docs/designs/remote-workrooms.md.
      """)
    XCTAssertTrue(
      command?.hasSuffix(" attach") == true && command?.contains("workroom-session") == true,
      "expected the attach-only client, got \(command ?? "nil")")
  }

  /// And the other half: with nowhere for a new session and no daemon claiming this one, the
  /// service says so rather than guessing, so the pane opens a plain shell.
  @MainActor
  func testAnUnhealthyAgentWithNoDaemonResolvesToNothing() {
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "exited 127") },
      ownership: { _ in .notOwned })

    XCTAssertNil(service.backend(forSession: UUID()))
    XCTAssertNil(service.attachCommand(forSession: UUID()))
  }

  /// The probe runs ONCE even when its answer is nil.
  ///
  /// `cachedPreferred` uses nil for the cached value, so before `preferredResolved` existed the
  /// "no backend" answer was indistinguishable from "not asked yet" and re-probed on every access.
  /// The real probe is a `Process()` with a 2-second deadline on the main actor, so an eight-pane
  /// restore against a hung agent froze the app for ~16s. Counting calls is the only way to see it:
  /// the returned value is identical either way.
  @MainActor
  func testTheAgentProbeRunsOnceEvenWhenItAnswersNothing() {
    let probeCount = Counter()
    let service = PersistentSessionService(
      probe: { _ in
        probeCount.increment()
        return .unhealthy(reason: "hung")
      },
      ownership: { _ in .notOwned })

    for _ in 0..<5 {
      _ = service.backend
      _ = service.isAvailable
      _ = service.socketPath
      _ = service.binaryPath
    }

    XCTAssertEqual(
      probeCount.value, 1,
      "a nil answer must cache; re-probing costs 2s of frozen main actor per access")
  }

  /// …but not forever. A nil answer is retried after a cooldown.
  ///
  /// Latching it for the launch was worse than the behaviour it replaced: before this change a
  /// failed probe fell back to the daemon, which could still be started, so a transient failure
  /// degraded to daemon-backed persistence. Now it degrades to none at all, and the probe is a
  /// 2-second-watchdogged `Process()` that a loaded machine or a slow first exec of a
  /// freshly-updated binary is enough to trip once. Without a way back, that user has no persistent
  /// terminals until they quit the app.
  @MainActor
  func testANilAnswerIsRetriedAfterTheCooldown() {
    let probeCount = Counter()
    var clock = 1000.0
    let service = PersistentSessionService(
      probe: { _ in
        probeCount.increment()
        return probeCount.value == 1
          ? .unhealthy(reason: "transient") : .ready(version: "protocol 1")
      },
      ownership: { _ in .notOwned },
      now: { clock })

    XCTAssertNil(service.backend)
    XCTAssertEqual(probeCount.value, 1)

    clock += PersistentSessionService.probeRetryInterval - 1
    XCTAssertNil(service.backend, "still inside the cooldown")
    XCTAssertEqual(probeCount.value, 1, "the cooldown is what keeps the main actor free")

    clock += 2
    XCTAssertEqual(
      service.backend, .rustAgent,
      "past the cooldown the agent gets another chance, and this one answers")
    XCTAssertEqual(probeCount.value, 2)
  }

  /// A successful answer is cached for good — no cooldown, no re-probe. An agent that has answered
  /// does not stop existing, and re-running it would reintroduce the cost the cache exists to avoid.
  @MainActor
  func testAHealthyAnswerIsNeverReprobed() {
    let probeCount = Counter()
    var clock = 1000.0
    let service = PersistentSessionService(
      probe: { _ in
        probeCount.increment()
        return .ready(version: "protocol 1")
      },
      ownership: { _ in .notOwned },
      now: { clock })

    XCTAssertEqual(service.backend, .rustAgent)
    clock += PersistentSessionService.probeRetryInterval * 10
    XCTAssertEqual(service.backend, .rustAgent)
    XCTAssertEqual(probeCount.value, 1)
  }
}

/// The substitution the shipped daemon performs on an id it does not hold, and the re-check that
/// stops us walking into it.
///
/// `SessionDaemon.handleAttach` — in the v2.0.0 binary, which cannot be changed — ends in
/// `create(request:connection:)` rather than refusing. So attaching to a session whose shell has
/// exited does not fail: it silently forks a new one. The user gets a fresh prompt where their
/// build was, and nothing distinguishes it from a successful reattach.
final class DaemonSessionSubstitutionTests: XCTestCase {
  /// The ordinary case: the daemon still has it, so nothing changes.
  @MainActor
  func testAStillHeldSessionIsAttachable() {
    let service = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 1") },
      ownership: { _ in .owned })
    let sessionID = UUID()
    XCTAssertEqual(service.backend(forSession: sessionID), .swiftDaemon)

    XCTAssertEqual(service.confirmBeforeAttach(sessionID: sessionID), .attachable)
  }

  /// The bug. The owner is resolved and cached while the daemon holds the session; the shell then
  /// exits; a later reattach must NOT proceed on the cached answer.
  @MainActor
  func testASessionTheDaemonHasLostIsNotAttachedTo() {
    let answers = OwnershipScript([.owned, .notOwned])
    let service = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 1") },
      ownership: { _ in answers.next() })
    let sessionID = UUID()

    // Resolved and cached while it was still held — this is what makes the cache stale later.
    XCTAssertEqual(service.backend(forSession: sessionID), .swiftDaemon)

    XCTAssertEqual(
      service.confirmBeforeAttach(sessionID: sessionID), .gone,
      """
      attaching here would ask the v2.0.0 daemon for a session it no longer holds, and it creates \
      one rather than refusing — the user's running work is replaced by an empty shell that looks \
      exactly like a successful reattach.
      """)
  }

  /// And the stale answer is dropped, so a later reattach resolves afresh instead of arriving back
  /// at the same wrong conclusion.
  @MainActor
  func testALostSessionDropsItsCachedOwner() {
    let answers = OwnershipScript([.owned, .notOwned, .notOwned])
    let service = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 1") },
      ownership: { _ in answers.next() })
    let sessionID = UUID()
    XCTAssertEqual(service.backend(forSession: sessionID), .swiftDaemon)
    XCTAssertEqual(service.confirmBeforeAttach(sessionID: sessionID), .gone)

    XCTAssertEqual(
      service.backend(forSession: sessionID), .rustAgent,
      "the cached daemon answer must be gone, so the session re-resolves to where new ones go")
  }

  /// **A daemon that cannot answer still gets attached to.** `.unreachable` means we could not ask,
  /// not that the session is gone — and the substitution needs the daemon responsive enough to
  /// answer "not mine" and then fork. One too wedged to reply cannot produce the wrong result, so
  /// refusing here would throw away a session that is probably still running.
  @MainActor
  func testAnUnreachableDaemonIsStillAttachedTo() {
    let answers = OwnershipScript([.owned, .unreachable])
    let service = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 1") },
      ownership: { _ in answers.next() })
    let sessionID = UUID()
    XCTAssertEqual(service.backend(forSession: sessionID), .swiftDaemon)

    XCTAssertEqual(service.confirmBeforeAttach(sessionID: sessionID), .attachable)
  }

  /// Agent-owned sessions are not re-checked at all: the agent refuses an id it does not hold, so
  /// there is no substitution to prevent and no round trip worth paying for.
  @MainActor
  func testAnAgentOwnedSessionIsNotRechecked() {
    let probes = Counter()
    let service = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 1") },
      ownership: { _ in
        probes.increment()
        return .notOwned
      })
    let sessionID = UUID()
    XCTAssertEqual(service.backend(forSession: sessionID), .rustAgent)
    let afterResolve = probes.value

    XCTAssertEqual(service.confirmBeforeAttach(sessionID: sessionID), .attachable)
    XCTAssertEqual(probes.value, afterResolve, "an agent-owned session must not ask the daemon")
  }
}

/// The notice a pane shows when its session is gone.
final class LostSessionCommandTests: XCTestCase {
  /// It has to actually run. A malformed command string is a pane that opens to nothing, which is
  /// worse than the silent fresh prompt this replaces.
  func testTheNoticeCommandRunsAndPrintsThenBecomesTheShell() throws {
    let command = GhosttySurfaceView.lostSessionCommand(shell: "/bin/sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // `-l` would make the exec'd shell read login files and sit waiting; `</dev/null` ends it.
    process.arguments = ["-c", "\(command) < /dev/null"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(
      output.contains("has ended, so this is a new shell"),
      "the pane would come back with no explanation. got: \(output)")
  }

  /// A shell path carrying shell metacharacters must be taken literally. `SHELL` is
  /// environment-supplied, so it is not ours to trust, and this string is handed to `/bin/sh -c`.
  ///
  /// Asserted by RUNNING it and checking the side effect did not happen. The first version of this
  /// test looked for the injected text as a substring of the command and failed — correctly quoted
  /// output still contains it, inside quotes, which is the whole point. A substring check cannot
  /// tell "quoted" from "escaped"; only execution can.
  func testAnAwkwardShellPathIsQuotedNotInterpreted() throws {
    let marker = URL(fileURLWithPath: "/tmp/wr-quoting-\(UUID().uuidString.prefix(8))")
    let hostile = "/nonexistent/sh'; touch \(marker.path); '"
    let command = GhosttySurfaceView.lostSessionCommand(shell: hostile)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "\(command) < /dev/null"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    let escaped = FileManager.default.fileExists(atPath: marker.path)
    try? FileManager.default.removeItem(at: marker)
    XCTAssertFalse(
      escaped,
      "a shell path from the environment broke out of its quoting and ran: \(command)")
  }
}

/// Answers a scripted sequence of ownership results, then repeats the last one.
private final class OwnershipScript: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [SessionOwnership]
  private var index = 0

  init(_ answers: [SessionOwnership]) {
    self.answers = answers
  }

  func next() -> SessionOwnership {
    lock.lock()
    defer { lock.unlock() }
    let answer = answers[min(index, answers.count - 1)]
    index += 1
    return answer
  }
}

/// A plain counter rather than a captured `var`: the closure is `@escaping` and stored on the
/// service, so it cannot capture a local mutable.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
