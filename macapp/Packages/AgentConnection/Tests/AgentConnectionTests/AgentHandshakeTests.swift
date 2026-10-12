import AgentConnection
import XCTest

/// Pins the Swift half of the agent greeting against the Rust half (`wr_protocol::envelope`).
///
/// The byte literals are deliberate: asserting "encode then decode round-trips" would pass happily
/// while both halves drifted together away from what the agent actually speaks.
final class AgentHandshakeTests: XCTestCase {
  func testHelloStartsWithTheMagicAndVersion() {
    let bytes = AgentHandshake.encodeHello(build: "Workroom")
    XCTAssertEqual(Array(bytes.prefix(4)), Array("WRA1".utf8))
    XCTAssertEqual(bytes[4], 0, "protocol version is a big-endian u16")
    XCTAssertEqual(bytes[5], 7, "PROTOCOL_VERSION in the agent, bumped for Service::Layout")
    XCTAssertEqual(Int(bytes[6]), "Workroom".utf8.count)
  }

  func testHelloRoundTrips() throws {
    let bytes = AgentHandshake.encodeHello(build: "Workroom 2.0")
    let decoded = try XCTUnwrap(try AgentHandshake.decodeHello(bytes))
    XCTAssertEqual(decoded.version, AgentHandshake.protocolVersion)
    XCTAssertEqual(decoded.consumed, bytes.count)
  }

  /// Every prefix must report "need more", never a spurious value — the greeting arrives over a
  /// socket and can be split anywhere.
  func testHelloNeedsMoreBytesRatherThanGuessing() throws {
    let bytes = AgentHandshake.encodeHello(build: "Workroom")
    for cut in 0..<bytes.count {
      XCTAssertNil(
        try AgentHandshake.decodeHello(Array(bytes.prefix(cut))),
        "a \(cut)-byte prefix should not decode")
    }
  }

  /// An ssh banner or MOTD must fail at once, not wait out the read timeout.
  func testHelloRejectsAPeerThatIsNotAnAgent() {
    XCTAssertThrowsError(try AgentHandshake.decodeHello(Array("Welcome to Ubuntu".utf8)))
    XCTAssertThrowsError(try AgentHandshake.decodeHello(Array("X".utf8)))
  }

  /// But a genuine prefix of the magic is not yet a failure — the rest may still arrive.
  func testHelloTreatsAMagicPrefixAsIncomplete() throws {
    XCTAssertNil(try AgentHandshake.decodeHello(Array("W".utf8)))
    XCTAssertNil(try AgentHandshake.decodeHello(Array("WRA".utf8)))
  }
}
