import XCTest

@testable import Workroom
@testable import WorkroomWire

/// Pins the Swift half of the agent wire against the Rust half.
///
/// These two encoders live in different languages and cannot share a definition, so the only thing
/// keeping them honest is a test on each side asserting the same bytes. The byte literals here are
/// deliberate: asserting "encode then decode round-trips" would pass happily while both halves
/// drifted together away from what the agent actually speaks.
final class AgentControlClientTests: XCTestCase {

  // MARK: - Envelope

  func testEnvelopeHeaderIsServiceThenStreamThenLength() {
    let bytes = AgentControlClient.encodeEnvelope(
      service: .terminal, stream: 0xDEAD_BEEF, payload: [1, 2, 3])
    XCTAssertEqual(bytes[0], 0x01, "terminal service")
    XCTAssertEqual(Array(bytes[1..<5]), [0xDE, 0xAD, 0xBE, 0xEF], "stream id, big-endian")
    XCTAssertEqual(Array(bytes[5..<9]), [0, 0, 0, 3], "payload length, big-endian")
    XCTAssertEqual(Array(bytes[9...]), [1, 2, 3])
  }

  func testEnvelopeRoundTrips() throws {
    let payload = Array(repeating: UInt8(7), count: 5000)
    let bytes = AgentControlClient.encodeEnvelope(service: .control, stream: 1, payload: payload)
    let decoded = try XCTUnwrap(AgentControlClient.decodeEnvelope(bytes))
    XCTAssertEqual(decoded.payload, payload)
    XCTAssertEqual(decoded.consumed, bytes.count)
  }

  func testEnvelopeNeedsMoreBytesRatherThanGuessing() {
    let bytes = AgentControlClient.encodeEnvelope(service: .control, stream: 1, payload: [9, 9])
    for cut in 0..<bytes.count {
      XCTAssertNil(
        AgentControlClient.decodeEnvelope(Array(bytes.prefix(cut))),
        "a \(cut)-byte prefix should not decode")
    }
  }

  /// The layering the whole design rests on: a terminal frame inside an envelope, out again
  /// unchanged.
  func testASessionFrameSurvivesTheEnvelope() throws {
    let frame = SessionFrame(kind: .list)
    let wire = AgentControlClient.encodeEnvelope(
      service: .control, stream: 0, payload: frame.encoded())
    let decoded = try XCTUnwrap(AgentControlClient.decodeEnvelope(wire))

    var frames = SessionFrameDecoder()
    frames.push(decoded.payload)
    XCTAssertEqual(try frames.next(), frame)
  }

  // MARK: - Descriptors

  /// The agent emits this format so the app's existing decoder works unchanged. These bytes are
  /// what `encode_descriptor_list` in the Rust crate produces for one session; if either side
  /// changes shape, one of the two tests fails rather than the app silently listing no sessions.
  func testDecodesTheDescriptorListTheAgentEmits() throws {
    var bytes: [UInt8] = [0, 0, 0, 1]  // count
    bytes += Array(repeating: UInt8(3), count: 16)  // identifier
    bytes += [0, 0, 0x10, 0x92]  // pid 4242, big-endian i32
    bytes += Array(repeating: UInt8(0), count: 8)  // tty, unused by the app
    let cwd = Array("/work/room".utf8)
    bytes += [0, 0, 0, UInt8(cwd.count)] + cwd
    bytes += [1]  // attached
    bytes += [0, 0, 0, 1]  // one metadata entry
    let key = Array("command".utf8)
    bytes += [0, 0, 0, UInt8(key.count)] + key
    let value = Array("nvim".utf8)
    bytes += [0, 0, 0, UInt8(value.count)] + value

    let descriptors = try SessionDescriptor.decodeList(bytes)
    XCTAssertEqual(descriptors.count, 1)
    let descriptor = try XCTUnwrap(descriptors.first)
    XCTAssertEqual(descriptor.shellProcessID, 4242)
    XCTAssertEqual(descriptor.workingDirectory, "/work/room")
    XCTAssertTrue(descriptor.isAttached)
    XCTAssertEqual(descriptor.value(forMetadataKey: "command"), "nvim")
  }

  func testDecodesAnEmptyDescriptorList() throws {
    XCTAssertEqual(try SessionDescriptor.decodeList([0, 0, 0, 0]).count, 0)
  }

  // MARK: - Routing

  /// Both clients satisfy one protocol, so every caller in `PersistentSessionService` is
  /// backend-agnostic. If this stops compiling, a branch has crept back in.
  func testBothBackendsSatisfyOneControlPlane() {
    let clients: [any SessionControlPlane] = [
      PersistentSessionControlClient(socketPath: "/tmp/nonexistent.sock"),
      AgentControlClient(socketPath: "/tmp/nonexistent.sock"),
    ]
    // Nothing is listening, so both must report empty rather than hang or crash.
    for client in clients {
      XCTAssertTrue(client.list().isEmpty)
    }
  }
}
