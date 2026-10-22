import XCTest

@testable import Workroom

/// Covers the properties that make the rollback switch safe rather than the switch itself:
/// the two backends can never collide, and a build that does not offer the choice never honours
/// a stored one.
final class SessionBackendTests: XCTestCase {

  // MARK: - The collision property

  /// The whole reason this is a separate socket rather than a shared one. If these ever match,
  /// a half-switched app can bind two pty owners to one socket, which is precisely the failure
  /// "unify" exists to prevent — and it would show up as terminals stealing each other's input,
  /// not as a clean error.
  func testBackendsNeverShareASocketName() {
    let names = Set(SessionBackend.allCases.map(\.socketFileName))
    XCTAssertEqual(names.count, SessionBackend.allCases.count)
  }

  func testBackendsNeverShareABinaryName() {
    let names = Set(SessionBackend.allCases.map(\.binaryName))
    XCTAssertEqual(names.count, SessionBackend.allCases.count)
  }

  /// The Swift helper's socket name is a stored-data contract: an installed build has sessions
  /// live on `session.sock` right now, and renaming it would orphan them on upgrade.
  func testSwiftHelperKeepsItsShippedSocketName() {
    XCTAssertEqual(SessionBackend.legacySessionHelper.socketFileName, "session.sock")
    XCTAssertEqual(SessionBackend.legacySessionHelper.binaryName, "workroom-session")
  }

  // MARK: - Finding the daemon under either socket name (#525)

  private static let support = "/Users/me/Library/Application Support/id/sessions"
  private static let fallback = "/tmp/workroom-501-id"

  /// With nothing listening on either name, a new daemon starts on the new name.
  func testWithNoDaemonListeningTheNewNameIsWhereOneStarts() {
    let socket = PersistentSessionPaths.daemonSocket(
      preferredDirectory: Self.support, fallbackDirectory: Self.fallback, answers: { _ in false })
    XCTAssertNil(socket.live)
    XCTAssertEqual(socket.path, Self.support + "/workroomd")
  }

  /// A /tmp fallback that can't be made private (another user on the Mac owns its name) doesn't
  /// stop the daemon when Application Support is short enough, as before the rename; when it is
  /// too long, that fallback's error is what the caller sees.
  func testAFallbackThatCannotBeMadeStopsTheDaemonOnlyWhenItIsNeeded() throws {
    // Its own Application Support, so the preferred path's length doesn't hang on this Mac's.
    final class FallbackOwnedByAnotherUser: FileManager {
      let support: URL
      init(supportNameLength: Int) {
        support = URL(
          fileURLWithPath: "/tmp/wrs-" + String(repeating: "s", count: supportNameLength))
        super.init()
      }
      override func url(
        for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?, create shouldCreate: Bool
      ) throws -> URL { support }
      override func setAttributes(
        _ attributes: [FileAttributeKey: Any], ofItemAtPath path: String
      ) throws {
        if path.hasPrefix("/tmp/workroom-") { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
      }
    }
    let short = FallbackOwnedByAnotherUser(supportNameLength: 6)
    defer { try? FileManager.default.removeItem(at: short.support) }
    let socket = try PersistentSessionPaths.daemonSocket(fileManager: short)
    XCTAssertNil(socket.live)
    XCTAssertTrue(socket.path.hasPrefix(short.support.path + "/"), socket.path)
    XCTAssertTrue(socket.path.hasSuffix("/sessions/workroomd"), socket.path)

    let long = FallbackOwnedByAnotherUser(supportNameLength: PersistentSessionPaths.sunPathLimit)
    defer { try? FileManager.default.removeItem(at: long.support) }
    XCTAssertThrowsError(try PersistentSessionPaths.daemonSocket(fileManager: long)) {
      XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
    }
  }

  /// A stable user's daemon, started by v2.1.0, is found on `agent.sock` and used as it is: its
  /// terminals live there until it exits.
  func testADaemonOnTheOldNameIsUsedWhereItIs() {
    let old = Self.support + "/agent.sock"
    let socket = PersistentSessionPaths.daemonSocket(
      preferredDirectory: Self.support, fallbackDirectory: Self.fallback, answers: { $0 == old })
    XCTAssertEqual(socket.live, old)
    XCTAssertEqual(socket.path, old)
  }

  /// The new name wins when both answer: a daemon started after the update is the current one.
  func testTheNewNameWinsWhenBothAnswer() {
    let socket = PersistentSessionPaths.daemonSocket(
      preferredDirectory: Self.support, fallbackDirectory: Self.fallback, answers: { _ in true })
    XCTAssertEqual(socket.path, Self.support + "/workroomd")
  }

  /// The new name is a byte shorter than the old, so a v2.1.0 daemon whose `agent.sock` didn't fit
  /// in Application Support is in the `/tmp` fallback while the new name fits here. It must still be
  /// found there, and with nothing running a new daemon starts in Application Support.
  func testAnOldDaemonInTmpIsFoundWhenTheNewNameFitsInApplicationSupport() {
    let long =
      "/Users/" + String(repeating: "u", count: 47) + "/Library/Application Support/x/sessions"
    XCTAssertGreaterThanOrEqual(
      (long + "/agent.sock").utf8.count, PersistentSessionPaths.sunPathLimit)
    XCTAssertLessThan((long + "/workroomd").utf8.count, PersistentSessionPaths.sunPathLimit)
    let old = Self.fallback + "/agent.sock"

    let running = PersistentSessionPaths.daemonSocket(
      preferredDirectory: long, fallbackDirectory: Self.fallback, answers: { $0 == old })
    XCTAssertEqual(running.live, old)

    let none = PersistentSessionPaths.daemonSocket(
      preferredDirectory: long, fallbackDirectory: Self.fallback, answers: { _ in false })
    XCTAssertEqual(none.path, long + "/workroomd")
  }

  /// A daemon too busy to accept (a full backlog refuses a connect) still holds its lock, and counts
  /// as live: taken for gone, a second daemon would start under the other name beside it.
  func testADaemonHoldingItsLockIsLiveEvenWhenItsSocketRefuses() throws {
    let directory = URL(fileURLWithPath: "/tmp/wr-lock-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("agent.sock").path
    let lock = directory.appendingPathComponent("agent.lock").path
    XCTAssertTrue(FileManager.default.createFile(atPath: lock, contents: nil))
    XCTAssertFalse(PersistentSessionPaths.isLive(socket), "an unheld lock and no listener")

    let held = open(lock, O_RDWR)
    XCTAssertGreaterThanOrEqual(held, 0)
    XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
    XCTAssertFalse(PersistentSessionPaths.answers(socket), "nothing accepts")
    XCTAssertTrue(PersistentSessionPaths.isLive(socket), "but the lock is held")
    close(held)
    XCTAssertFalse(PersistentSessionPaths.isLive(socket), "released with its holder")

    // Not under the new name: a daemon starting there must never find the app's probe on its lock.
    let current = directory.appendingPathComponent("workroomd").path
    let currentLock = open(
      directory.appendingPathComponent("workroomd.lock").path, O_RDWR | O_CREAT, 0o600)
    defer { close(currentLock) }
    XCTAssertEqual(flock(currentLock, LOCK_EX | LOCK_NB), 0)
    XCTAssertTrue(PersistentSessionPaths.holdsLock(current))
    XCTAssertFalse(PersistentSessionPaths.isLive(current), "the new name goes by its socket alone")
  }

  /// An Application Support folder that can't be made falls back to /tmp, as v2.1.0's resolver did,
  /// so a daemon already there is found and a new one can start.
  func testAnApplicationSupportThatCannotBeMadeFallsBackToTmp() throws {
    final class NoApplicationSupport: FileManager {
      override func url(
        for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?, create shouldCreate: Bool
      ) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
    }
    let socket = try PersistentSessionPaths.daemonSocket(fileManager: NoApplicationSupport())
    XCTAssertTrue(socket.path.hasPrefix("/tmp/workroom-"), socket.path)
  }

  /// Liveness, not existence: a socket file a crash or reboot left behind is not a daemon, or the
  /// next one would start on the old name and it would never go away.
  func testASocketFileNothingListensOnDoesNotAnswer() throws {
    let directory = URL(fileURLWithPath: "/tmp/wr-answers-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path

    let descriptor = try UnixSocketListener.listen(at: path)
    XCTAssertTrue(PersistentSessionPaths.answers(path), "a listening daemon answers")
    close(descriptor)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the stale file is still there")
    XCTAssertFalse(PersistentSessionPaths.answers(path), "a stale socket file does not answer")
    XCTAssertFalse(PersistentSessionPaths.answers(directory.appendingPathComponent("none").path))
  }

  /// The property the whole migration rests on: a session created by one helper is never reachable
  /// through the other, so a draining helper and a running daemon can't fight over one socket.
  func testSocketPathsDifferPerBackend() throws {
    let helper = try PersistentSessionPaths.preferredSocketPath(backend: .legacySessionHelper)
    let daemon = try PersistentSessionPaths.preferredSocketPath(backend: .daemon)
    XCTAssertNotEqual(helper, daemon)
    XCTAssertTrue(helper.hasSuffix("session.sock"))
    XCTAssertTrue(daemon.hasSuffix("/workroomd"))
  }

  /// The fallback path exists for long home directories; it must keep the separation too, or the
  /// collision returns for exactly the users least able to diagnose it.
  func testFallbackSocketPathsAlsoDifferPerBackend() throws {
    let helper = try PersistentSessionPaths.fallbackSocketPath(backend: .legacySessionHelper)
    let daemon = try PersistentSessionPaths.fallbackSocketPath(backend: .daemon)
    XCTAssertNotEqual(helper, daemon)
  }

  // MARK: - Choosing where a new session goes

  /// New sessions go to the daemon when it works. Nobody is asked, and nothing is stored.
  func testNewSessionsPreferTheDaemonWhenItIsHealthy() {
    let backend = SessionBackend.preferred { _ in .ready(version: "protocol 1") }
    XCTAssertEqual(backend, .daemon)
  }

  /// REGRESSION. This asserted the opposite — that a failed daemon probe fell back to the helper —
  /// and that fallback is exactly what the attach-only change removes. `workroom-session` can no
  /// longer start a helper, so routing a NEW session there would hand libghostty an attach command
  /// for a session nobody holds: a blank pane, then exit 92, and no plain-shell fallback, because
  /// that decision is made before the command is ever spawned. Nowhere is the correct answer, and
  /// the caller opens a plain shell instead.
  ///
  /// Both failure shapes are asserted: `notBundled` is a packaging fact, `unhealthy` a runtime one,
  /// and only the second can appear in a shipped build.
  func testNewSessionsGoNowhereWhenTheDaemonCannotRun() {
    XCTAssertNil(SessionBackend.preferred { _ in .notBundled })
    XCTAssertNil(SessionBackend.preferred { _ in .unhealthy(reason: "exited 127") })
  }

  /// Raw values are a stored-data contract for logs and diagnostics, even though no preference
  /// stores them any more.
  func testRawValuesAreStable() {
    XCTAssertEqual(SessionBackend.legacySessionHelper.rawValue, "swift")
    XCTAssertEqual(SessionBackend.daemon.rawValue, "rust")
  }

  // MARK: - The migration

  /// Nothing persists a backend choice. A stored one would go stale the moment a helper exited or
  /// an upgrade landed, and would send the app to a helper that is not holding the session.
  func testNoBackendChoiceIsStored() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("WorkroomApp/Core/DefaultsKeys.swift"),
      encoding: .utf8)
    XCTAssertFalse(
      source.contains("sessionBackend"),
      "the backend must not become a stored preference again")
  }

  // MARK: - The probe

  func testProbeReportsNotBundledWhenTheBinaryIsAbsent() {
    let result = SessionBackendProbe.probe(
      .daemon,
      locate: { _ in nil },
      run: {
        _ in
        XCTFail("must not run anything when there is no binary")
        return (0, "")
      }
    )
    XCTAssertEqual(result, .notBundled)
    XCTAssertFalse(result.isReady)
  }

  func testProbeReportsReadyOnAParseableVersion() {
    let result = SessionBackendProbe.probe(
      .daemon,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in (0, "protocol 1 (minimum supported 1)\ngreeting 21 bytes: [57]\n")
      }
    )
    XCTAssertEqual(result, .ready(version: "protocol 1"))
    XCTAssertTrue(result.isReady)
  }

  /// The failure a file-existence check cannot see, and the one a rollback decision needs.
  func testProbeReportsUnhealthyOnANonZeroExit() {
    let result = SessionBackendProbe.probe(
      .daemon,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in (127, "")
      }
    )
    XCTAssertEqual(result, .unhealthy(reason: "exited 127"))
  }

  func testProbeReportsUnhealthyOnUnrecognisedOutput() {
    let result = SessionBackendProbe.probe(
      .daemon,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in (0, "dyld: Library not loaded\n")
      }
    )
    XCTAssertEqual(result, .unhealthy(reason: "unrecognised reply"))
  }

  func testProbeReportsUnhealthyWhenTheHelperThrows() {
    struct Boom: LocalizedError {
      var errorDescription: String? { "bad CPU type" }
    }
    let result = SessionBackendProbe.probe(
      .daemon,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in throw Boom()
      }
    )
    XCTAssertEqual(result, .unhealthy(reason: "bad CPU type"))
  }

  /// The probe runs on the main thread inside the session restore, which must finish before any
  /// pane mounts. Waiting must not run the main queue: a selected workroom's pane mounted mid-wait
  /// opened a fresh shell, and the restore then skipped that workroom's saved session. The helper
  /// closes its output first, so the wait for its exit is what this measures, not the read.
  func testRunningAHelperDoesNotRunTheMainQueueWhileItWaits() throws {
    XCTAssertTrue(Thread.isMainThread)
    var ranDuringRun = false
    DispatchQueue.main.async { ranDuringRun = true }

    let result = try SessionBackendProbe.run(
      URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec >&- 2>&-; sleep 0.5"],
      timeout: 5)

    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(ranDuringRun, "main-queue work ran while the probe waited for its helper")
  }

  /// The version line may grow detail; the contract is its leading token only, so the daemon can
  /// say more without needing a matching app release.
  func testVersionParsingToleratesExtraDetail() {
    XCTAssertEqual(SessionBackendProbe.parseProtocolVersion("protocol 4 (min 2) extra"), 4)
    XCTAssertEqual(
      SessionBackendProbe.parseProtocolVersion("noise\nprotocol 9 (minimum supported 1)"), 9)
    XCTAssertNil(SessionBackendProbe.parseProtocolVersion("protocol none"))
    XCTAssertNil(SessionBackendProbe.parseProtocolVersion(""))
  }

  /// The helper has no self-describing subcommand and is not getting one — it is being retired.
  func testSwiftHelperIsNotExecutedByTheProbe() {
    let result = SessionBackendProbe.probe(
      .legacySessionHelper,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in
        XCTFail("the shipped helper must not be executed to answer a health question")
        return (0, "")
      }
    )
    XCTAssertTrue(result.isReady)
  }
}
