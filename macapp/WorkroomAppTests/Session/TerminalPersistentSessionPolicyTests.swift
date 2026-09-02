import XCTest

@testable import Workroom

final class TerminalPersistentSessionPolicyTests: XCTestCase {
  func testDefaultOnWhenAvailable() {
    XCTAssertTrue(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true,
        isAvailable: true,
        isRunCommand: false,
        isFixture: false))
  }

  func testOffPreferenceDisables() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: false,
        isAvailable: true,
        isRunCommand: false,
        isFixture: false))
  }

  func testRunCommandAndFixtureAreExcluded() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true, isAvailable: true, isRunCommand: true, isFixture: false))
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true, isAvailable: true, isRunCommand: false, isFixture: true))
  }

  func testUnavailableHelperFallsBack() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        preferenceEnabled: true,
        isAvailable: false,
        isRunCommand: false,
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
