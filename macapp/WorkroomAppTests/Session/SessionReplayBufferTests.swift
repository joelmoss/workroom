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

  func testReplayStripsColorQueryOSC() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append(Array("before".utf8))
    buffer.append([0x1B, 0x5D] + Array("11;?".utf8) + [0x07])  // OSC 11 query (BEL)
    buffer.append(Array("after".utf8))
    XCTAssertEqual(String(bytes: buffer.replayBytes, encoding: .utf8), "beforeafter")
  }

  func testReplayStripsColorQueryOSCWithSTTerminator() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append([0x1B, 0x5D] + Array("10;?".utf8) + [0x1B, 0x5C])  // OSC 10 query (ST)
    buffer.append(Array("after".utf8))
    XCTAssertEqual(String(bytes: buffer.replayBytes, encoding: .utf8), "after")
  }

  func testReplayKeepsColorSetOSC() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append([0x1B, 0x5D] + Array("11;rgb:1d1d/1d1d/1f1f".utf8) + [0x07])  // OSC 11 SET
    let replayed = buffer.replayBytes
    XCTAssertEqual(String(bytes: replayed, encoding: .utf8), "\u{1B}]11;rgb:1d1d/1d1d/1f1f\u{07}")
  }

  func testReplayKeepsTitleEndingInQuestionMark() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append([0x1B, 0x5D] + Array("2;Continue?".utf8) + [0x07])  // OSC 2 title, not a query
    let replayed = buffer.replayBytes
    XCTAssertEqual(String(bytes: replayed, encoding: .utf8), "\u{1B}]2;Continue?\u{07}")
  }

  func testReplayStripsDeviceAttributesAndStatusReportCSI() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append(Array("before".utf8) + [0x1B, 0x5B, 0x36, 0x6E])  // CSI 6n (cursor position)
    buffer.append([0x1B, 0x5B, 0x3E, 0x63])  // CSI >c (device attributes)
    buffer.append(Array("after".utf8))
    XCTAssertEqual(String(bytes: buffer.replayBytes, encoding: .utf8), "beforeafter")
  }

  func testReplayStripsKittyKeyboardQuery() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append(Array("before".utf8) + [0x1B, 0x5B, 0x3F, 0x75])  // CSI ?u (kitty flags query)
    buffer.append(Array("after".utf8))
    XCTAssertEqual(String(bytes: buffer.replayBytes, encoding: .utf8), "beforeafter")
  }

  func testReplayKeepsKittyKeyboardSetPushPop() {
    var buffer = SessionReplayBuffer(capacity: 256)
    buffer.append([0x1B, 0x5B, 0x3E, 0x35, 0x75])  // CSI >5u (push flags=5) — not a query
    buffer.append([0x1B, 0x5B, 0x3D, 0x35, 0x3B, 0x31, 0x75])  // CSI =5;1u (set) — not a query
    buffer.append([0x1B, 0x5B, 0x3C, 0x75])  // CSI <u (pop) — not a query
    let replayed = String(bytes: buffer.replayBytes, encoding: .utf8)
    XCTAssertEqual(replayed, "\u{1B}[>5u\u{1B}[=5;1u\u{1B}[<u")
  }
}
