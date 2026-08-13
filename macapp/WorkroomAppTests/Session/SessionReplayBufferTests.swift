import XCTest

@testable import WorkroomSessionProtocol

final class SessionReplayBufferTests: XCTestCase {
  func testWrapsAndKeepsNewestBytes() {
    var buffer = SessionReplayBuffer(capacity: 8)
    buffer.append(Array("abcdefgh".utf8))
    buffer.append(Array("ij".utf8))
    XCTAssertEqual(String(bytes: buffer.bytes, encoding: .utf8), "cdefghij")
  }

  func testReplaySkipsAlternateScreen() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append(Array("before".utf8))
    buffer.append([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68])  // enter alt
    buffer.append(Array("hidden".utf8))
    XCTAssertTrue(buffer.isAlternateScreenActive)
    XCTAssertEqual(buffer.replayBytes, [])
    buffer.append([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C])  // leave alt
    buffer.append(Array("after".utf8))
    XCTAssertFalse(buffer.isAlternateScreenActive)
    XCTAssertEqual(String(bytes: buffer.replayBytes, encoding: .utf8), "after")
  }

  func testRemoveAllClearsState() {
    var buffer = SessionReplayBuffer(capacity: 16)
    buffer.append(Array("hello".utf8))
    buffer.removeAll()
    XCTAssertTrue(buffer.isEmpty)
    XCTAssertEqual(buffer.replayBytes, [])
  }
}
