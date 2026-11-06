import DaemonConnection
import XCTest

/// Pins the `Retag` frame against the daemon's reading of it (`terminal/dispatch.rs`,
/// `FrameKind::Retag`): the literals are the daemon's numbers, not a round trip through this
/// encoder.
final class SessionRetagTests: XCTestCase {
  private let session = UUID(uuidString: "5A1E0F7E-0D6C-4C9F-9C3E-2B7F1D0A8E11")!

  func testTheFrameIsTheKindTheLengthTheSessionAndTheWorkroom() {
    XCTAssertEqual(
      SessionRetag.frame(session: session, workroom: "wr|/p|a"),
      [0x27, 0, 0, 0, 23]
        + [
          0x5A, 0x1E, 0x0F, 0x7E, 0x0D, 0x6C, 0x4C, 0x9F, 0x9C, 0x3E, 0x2B, 0x7F, 0x1D, 0x0A, 0x8E,
          0x11,
        ] + Array("wr|/p|a".utf8))
  }

  func testRepliesSayWhetherItWasRetagged() {
    XCTAssertEqual(SessionRetag.decode([0x32, 0, 0, 0, 0]), true)
    let gone = Array("no session 5a1e0f7e".utf8)
    XCTAssertEqual(SessionRetag.decode([0x14, 0, 0, 0, UInt8(gone.count)] + gone), false)
    XCTAssertNil(SessionRetag.decode([0x31, 0, 0, 0, 0]), "a session list is no reply to a retag")
  }
}
