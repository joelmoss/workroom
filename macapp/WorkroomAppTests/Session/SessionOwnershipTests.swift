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
