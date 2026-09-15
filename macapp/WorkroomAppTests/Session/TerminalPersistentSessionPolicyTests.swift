import XCTest

@testable import Workroom

final class TerminalPersistentSessionPolicyTests: XCTestCase {
  func testDefaultOnWhenAvailable() {
    XCTAssertTrue(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true,
        isAvailable: true,
        isRunCommand: false,
        hasExistingSession: false,
        isFixture: false))
  }

  func testOffPreferenceDisables() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: false,
        isAvailable: true,
        isRunCommand: false,
        hasExistingSession: false,
        isFixture: false))
  }

  /// The user's preference beats a restored id. Turning background sessions off means off, even for
  /// a pane that already has one.
  func testOffPreferenceDisablesEvenWithAnExistingSession() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: false,
        isAvailable: false,
        isRunCommand: false,
        hasExistingSession: true,
        isFixture: false))
  }

  func testRunCommandAndFixtureAreExcluded() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true, isAvailable: true, isRunCommand: true,
        hasExistingSession: false, isFixture: false))
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true, isAvailable: true, isRunCommand: false,
        hasExistingSession: false, isFixture: true))
  }

  /// No backend can take a NEW session, so a fresh pane gets none.
  func testUnavailableHelperGivesANewPaneNoSession() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true,
        isAvailable: false,
        isRunCommand: false,
        hasExistingSession: false,
        isFixture: false))
  }

  /// REGRESSION, and the reason `hasExistingSession` exists.
  ///
  /// `isAvailable` answers for the backend a NEW session would go to. A RESTORED pane already has
  /// an id naming a session some helper may still be holding, and running that id through the same
  /// gate discarded it before anything could ask who owned it — so an unhealthy agent silently
  /// stranded every session the Swift daemon was still holding, one layer above the fix that was
  /// supposed to prevent exactly that. Keeping the id is safe: if nothing can attach to it,
  /// `attachCommand` returns nil and the pane opens a plain shell anyway.
  func testARestoredSessionSurvivesAnUnavailableHelper() {
    XCTAssertTrue(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true,
        isAvailable: false,
        isRunCommand: false,
        hasExistingSession: true,
        isFixture: false),
      "a pane restoring a session it already had must keep its id so the owner can be resolved")
  }

  /// A run command is still excluded even when restoring, so the bypass cannot widen past its case.
  func testARestoredRunCommandIsStillExcluded() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true,
        isAvailable: false,
        isRunCommand: true,
        hasExistingSession: true,
        isFixture: false))
  }
}

final class TerminalPayloadSessionIDTests: XCTestCase {
  func testAbsentSessionIDStillDecodes() throws {
    let json = """
      {"defaultTitle":"Terminal 1","cwd":"/tmp"}
      """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(TerminalPayload.self, from: json)
    XCTAssertEqual(payload.defaultTitle, "Terminal 1")
    XCTAssertNil(payload.sessionID)
  }

  func testSessionIDRoundTrips() throws {
    let payload = TerminalPayload(
      defaultTitle: "Terminal 1", cwd: "/tmp", sessionID: UUID().uuidString)
    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(TerminalPayload.self, from: data)
    XCTAssertEqual(decoded.sessionID, payload.sessionID)
  }
}
