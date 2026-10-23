import DaemonConnection
import XCTest

/// Pins the `Signal` frame (#522) against the daemon's reading of it (`serve.rs`, `FrameKind::Signal`
/// and `RunSignal`): the literals are the daemon's numbers, not a round trip through this encoder.
final class RunSignalTests: XCTestCase {
  private let session = UUID(uuidString: "5A1E0F7E-0D6C-4C9F-9C3E-2B7F1D0A8E11")!

  func testTheFrameIsTheKindTheLengthTheSessionAndTheSignal() {
    XCTAssertEqual(
      RunSignal.stop.frame(session: session),
      [0x26, 0, 0, 0, 17]
        + [
          0x5A, 0x1E, 0x0F, 0x7E, 0x0D, 0x6C, 0x4C, 0x9F, 0x9C, 0x3E, 0x2B, 0x7F, 0x1D, 0x0A, 0x8E,
          0x11,
        ] + [2])
    XCTAssertEqual(RunSignal.restart.rawValue, 1)
    XCTAssertEqual(RunSignal.quit.rawValue, 3)
  }

  /// "no session …" is the one refusal the app may answer by starting the run again: the daemon
  /// holds nothing under that id, so a new session cannot double a server.
  func testRepliesSayWhetherTheRunIsGone() {
    XCTAssertEqual(RunSignalReply.decode([0x32, 0, 0, 0, 0]), .delivered)
    let gone = Array("no session 5a1e0f7e".utf8)
    XCTAssertEqual(
      RunSignalReply.decode([0x14, 0, 0, 0, UInt8(gone.count)] + gone), .noSuchSession)
    let shell = Array("not a run session: 5a1e".utf8)
    XCTAssertEqual(
      RunSignalReply.decode([0x14, 0, 0, 0, UInt8(shell.count)] + shell),
      .refused("not a run session: 5a1e"))
    XCTAssertNil(
      RunSignalReply.decode([0x31, 0, 0, 0, 0]), "a session list is no reply to a signal")
  }
}
