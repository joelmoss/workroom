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

  /// The Swift daemon's socket name is a stored-data contract: an installed build has sessions
  /// live on `session.sock` right now, and renaming it would orphan them on upgrade.
  func testSwiftDaemonKeepsItsShippedSocketName() {
    XCTAssertEqual(SessionBackend.swiftDaemon.socketFileName, "session.sock")
    XCTAssertEqual(SessionBackend.swiftDaemon.binaryName, "workroom-session")
  }

  func testSocketPathsDifferPerBackend() throws {
    let daemon = try PersistentSessionPaths.preferredSocketPath(backend: .swiftDaemon)
    let agent = try PersistentSessionPaths.preferredSocketPath(backend: .rustAgent)
    XCTAssertNotEqual(daemon, agent)
    XCTAssertTrue(daemon.hasSuffix("session.sock"))
    XCTAssertTrue(agent.hasSuffix("agent.sock"))
  }

  /// The fallback path exists for long home directories; it must keep the separation too, or the
  /// collision returns for exactly the users least able to diagnose it.
  func testFallbackSocketPathsAlsoDifferPerBackend() throws {
    let daemon = try PersistentSessionPaths.fallbackSocketPath(backend: .swiftDaemon)
    let agent = try PersistentSessionPaths.fallbackSocketPath(backend: .rustAgent)
    XCTAssertNotEqual(daemon, agent)
  }

  // MARK: - Choosing where a new session goes

  /// New sessions go to the agent when it works. Nobody is asked, and nothing is stored.
  func testNewSessionsPreferTheAgentWhenItIsHealthy() {
    let backend = SessionBackend.preferred { _ in .ready(version: "protocol 1") }
    XCTAssertEqual(backend, .rustAgent)
  }

  /// And keep working on the daemon when it does not. A build where the agent is missing or broken
  /// must still open terminals — this is the automatic fallback, which is only safe because the
  /// two never share a socket and ownership is per session.
  func testNewSessionsFallBackToTheDaemonWhenTheAgentCannotRun() {
    XCTAssertEqual(SessionBackend.preferred { _ in .notBundled }, .swiftDaemon)
    XCTAssertEqual(
      SessionBackend.preferred { _ in .unhealthy(reason: "exited 127") }, .swiftDaemon)
  }

  /// Raw values are a stored-data contract for logs and diagnostics, even though no preference
  /// stores them any more.
  func testRawValuesAreStable() {
    XCTAssertEqual(SessionBackend.swiftDaemon.rawValue, "swift")
    XCTAssertEqual(SessionBackend.rustAgent.rawValue, "rust")
  }

  // MARK: - The migration

  /// The property the whole migration rests on: the two helpers use different socket files, so a
  /// session created by one is never reachable through the other. If these ever matched, a
  /// draining daemon and a running agent would fight over one socket — and the user would see
  /// terminals stealing each other's input rather than a clean error.
  func testTheTwoHelpersCanNeverMeet() throws {
    let daemon = try PersistentSessionPaths.preferredSocketPath(backend: .swiftDaemon)
    let agent = try PersistentSessionPaths.preferredSocketPath(backend: .rustAgent)
    XCTAssertNotEqual(daemon, agent)
    XCTAssertNotEqual(
      try PersistentSessionPaths.fallbackSocketPath(backend: .swiftDaemon),
      try PersistentSessionPaths.fallbackSocketPath(backend: .rustAgent))
  }

  /// Nothing persists a backend choice. A stored one would go stale the moment a daemon exited or
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
      .rustAgent,
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
      .rustAgent,
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
      .rustAgent,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in (127, "")
      }
    )
    XCTAssertEqual(result, .unhealthy(reason: "exited 127"))
  }

  func testProbeReportsUnhealthyOnUnrecognisedOutput() {
    let result = SessionBackendProbe.probe(
      .rustAgent,
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
      .rustAgent,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in throw Boom()
      }
    )
    XCTAssertEqual(result, .unhealthy(reason: "bad CPU type"))
  }

  /// The version line may grow detail; the contract is its leading token only, so the agent can
  /// say more without needing a matching app release.
  func testVersionParsingToleratesExtraDetail() {
    XCTAssertEqual(SessionBackendProbe.parseProtocolVersion("protocol 4 (min 2) extra"), 4)
    XCTAssertEqual(
      SessionBackendProbe.parseProtocolVersion("noise\nprotocol 9 (minimum supported 1)"), 9)
    XCTAssertNil(SessionBackendProbe.parseProtocolVersion("protocol none"))
    XCTAssertNil(SessionBackendProbe.parseProtocolVersion(""))
  }

  /// The daemon has no self-describing subcommand and is not getting one — it is being retired.
  func testSwiftDaemonIsNotExecutedByTheProbe() {
    let result = SessionBackendProbe.probe(
      .swiftDaemon,
      locate: { _ in URL(fileURLWithPath: "/x") },
      run: {
        _ in
        XCTFail("the shipped daemon must not be executed to answer a health question")
        return (0, "")
      }
    )
    XCTAssertTrue(result.isReady)
  }
}
