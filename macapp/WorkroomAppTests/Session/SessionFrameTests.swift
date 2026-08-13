import XCTest

@testable import WorkroomSessionProtocol

final class SessionFrameTests: XCTestCase {
  func testRoundTripsEmptyPayload() throws {
    let frame = SessionFrame(kind: .list)
    var decoder = SessionFrameDecoder()
    decoder.push(frame.encoded())
    let decoded = try XCTUnwrap(decoder.next())
    XCTAssertEqual(decoded, frame)
    XCTAssertNil(try decoder.next())
  }

  func testRoundTripsAttachPayload() throws {
    let identifier = try XCTUnwrap(
      SessionIdentifier(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
    let request = SessionAttachRequest(
      identifier: identifier,
      columns: 80,
      rows: 24,
      workingDirectory: "/tmp",
      command: "",
      shell: "/bin/zsh",
      resourcesDirectory: "/resources",
      environment: [SessionEnvironmentEntry(key: "FOO", value: "bar")],
      metadata: [SessionEnvironmentEntry(key: SessionMetadataKey.title, value: "Term")])
    let frame = SessionFrame(kind: .attach, payload: request.encoded())
    var decoder = SessionFrameDecoder()
    decoder.push(frame.encoded())
    let decoded = try XCTUnwrap(decoder.next())
    XCTAssertEqual(try SessionAttachRequest.decode(decoded.payload), request)
  }

  func testRejectsUnknownKind() {
    var decoder = SessionFrameDecoder()
    decoder.push([0xFF, 0, 0, 0, 0])
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? SessionProtocolError, .unknownFrameKind(0xFF))
    }
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? SessionProtocolError, .decoderFailed)
    }
  }

  func testRejectsOversizedFrame() {
    var decoder = SessionFrameDecoder()
    decoder.push([SessionFrameKind.output.rawValue, 0x00, 0x20, 0x00, 0x00])
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? SessionProtocolError, .frameTooLarge(0x20_0000))
    }
  }

  func testIdentifierUUIDRoundTrip() {
    let uuid = UUID()
    let identifier = SessionIdentifier(uuid)
    XCTAssertEqual(identifier.uuidString.lowercased(), uuid.uuidString.lowercased())
    XCTAssertEqual(SessionIdentifier(uuidString: identifier.uuidString)?.bytes, identifier.bytes)
  }

  func testBoundedListDecodeRejectsHugeCount() {
    var writer = SessionByteWriter()
    writer.writeUInt32(1_000_000)
    XCTAssertThrowsError(try SessionDescriptor.decodeList(writer.bytes))
  }
}
