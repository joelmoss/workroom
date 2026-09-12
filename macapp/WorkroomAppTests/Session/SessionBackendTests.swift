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

  // MARK: - Selection

  func testDefaultsToTheShippedDaemon() {
    XCTAssertEqual(SessionBackend.default, .swiftDaemon)
  }

  func testSelectionHonoursTheStoredValueWhereOffered() {
    XCTAssertEqual(
      SessionBackend.selected(stored: .rustAgent, selectable: true), .rustAgent)
    XCTAssertEqual(
      SessionBackend.selected(stored: .swiftDaemon, selectable: true), .swiftDaemon)
  }

  /// A stored preference must not select the agent on a build that does not offer it. Without
  /// this, a value set in Nightly could put a stable build onto unfinished code — the exact thing
  /// PRODUCT.md principle 5 forbids, arriving through the back door of a shared defaults suite.
  func testSelectionIgnoresAStoredAgentWhereNotOffered() {
    XCTAssertEqual(
      SessionBackend.selected(stored: .rustAgent, selectable: false), .swiftDaemon)
  }

  /// Raw values are a stored-data contract, like `ReleaseChannel`'s.
  func testRawValuesAreStable() {
    XCTAssertEqual(SessionBackend.swiftDaemon.rawValue, "swift")
    XCTAssertEqual(SessionBackend.rustAgent.rawValue, "rust")
    XCTAssertEqual(SessionBackend(rawValue: "swift"), .swiftDaemon)
    XCTAssertEqual(SessionBackend(rawValue: "rust"), .rustAgent)
  }

  func testUnknownStoredValueFallsBackRatherThanCrashing() {
    XCTAssertNil(SessionBackend(rawValue: "wasm"))
  }

  // MARK: - The probe

  func testProbeReportsNotBundledWhenTheBinaryIsAbsent() {
    let result = SessionBackendProbe.probe(.rustAgent, binaryURL: nil) { _ in
      XCTFail("must not run anything when there is no binary")
      return (0, "")
    }
    XCTAssertEqual(result, .notBundled)
    XCTAssertFalse(result.isReady)
  }

  func testProbeReportsReadyOnAParseableVersion() {
    let result = SessionBackendProbe.probe(.rustAgent, binaryURL: URL(fileURLWithPath: "/x")) {
      _ in (0, "protocol 1 (minimum supported 1)\ngreeting 21 bytes: [57]\n")
    }
    XCTAssertEqual(result, .ready(version: "protocol 1"))
    XCTAssertTrue(result.isReady)
  }

  /// The failure a file-existence check cannot see, and the one a rollback decision needs.
  func testProbeReportsUnhealthyOnANonZeroExit() {
    let result = SessionBackendProbe.probe(.rustAgent, binaryURL: URL(fileURLWithPath: "/x")) {
      _ in (127, "")
    }
    XCTAssertEqual(result, .unhealthy(reason: "exited 127"))
  }

  func testProbeReportsUnhealthyOnUnrecognisedOutput() {
    let result = SessionBackendProbe.probe(.rustAgent, binaryURL: URL(fileURLWithPath: "/x")) {
      _ in (0, "dyld: Library not loaded\n")
    }
    XCTAssertEqual(result, .unhealthy(reason: "unrecognised reply"))
  }

  func testProbeReportsUnhealthyWhenTheHelperThrows() {
    struct Boom: LocalizedError {
      var errorDescription: String? { "bad CPU type" }
    }
    let result = SessionBackendProbe.probe(.rustAgent, binaryURL: URL(fileURLWithPath: "/x")) {
      _ in throw Boom()
    }
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
      .swiftDaemon, binaryURL: URL(fileURLWithPath: "/x")
    ) { _ in
      XCTFail("the shipped daemon must not be executed to answer a health question")
      return (0, "")
    }
    XCTAssertTrue(result.isReady)
  }
}
