import Foundation
import WorkroomWire
import XCTest

@testable import DaemonConnection

/// Pins the bytes of the one Control codec both control clients send through: the envelope and the
/// Control verbs (list, kill, signal, retag).
///
/// The byte literals are the daemon's reading of the wire (`wr_protocol::envelope`,
/// `terminal/dispatch.rs`), not a round trip through the encoder. `Legacy` is the two encoders the
/// clients carried before they shared this codec (the app's `DaemonControlClient.encodeEnvelope`
/// and the connection's private `envelope(service:stream:payload:)`), kept
/// verbatim so the move is checked byte for byte against what shipped.
final class DaemonControlCodecTests: XCTestCase {
  private let session = UUID(uuidString: "5A1E0F7E-0D6C-4C9F-9C3E-2B7F1D0A8E11")!
  private let sessionBytes: [UInt8] = [
    0x5A, 0x1E, 0x0F, 0x7E, 0x0D, 0x6C, 0x4C, 0x9F, 0x9C, 0x3E, 0x2B, 0x7F, 0x1D, 0x0A, 0x8E, 0x11,
  ]

  // MARK: - What both clients sent before the shared codec

  func testTheLocalClientsListRequestIsTheseBytes() {
    let frame = SessionFrame(kind: .list).encoded()
    XCTAssertEqual(frame, [0x21, 0, 0, 0, 0])
    XCTAssertEqual(
      Legacy.localEnvelope(service: 0, stream: 0, payload: frame),
      [0x00, 0, 0, 0, 0, 0, 0, 0, 5, 0x21, 0, 0, 0, 0])
  }

  func testTheRemoteClientsListRequestIsTheseBytes() {
    let frame = Data(SessionFrame(kind: .list).encoded())
    XCTAssertEqual(
      [UInt8](Legacy.remoteEnvelope(service: 0, stream: 7, payload: frame)),
      [0x00, 0, 0, 0, 7, 0, 0, 0, 5, 0x21, 0, 0, 0, 0])
  }

  func testAKillIsTheKindTheLengthAndTheSession() throws {
    let identifier = try XCTUnwrap(SessionIdentifier(uuidString: session.uuidString))
    XCTAssertEqual(
      SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier)).encoded(),
      [0x23, 0, 0, 0, 16] + sessionBytes)
  }

  func testBothEncodersAgreeOnEveryServiceAndStream() {
    let payload: [UInt8] = Array("{\"version\":1}".utf8)
    for service in UInt8(0)...7 {
      for stream: UInt32 in [0, 1, 0xFF, 0x0102_0304, 0xDEAD_BEEF, .max] {
        XCTAssertEqual(
          Legacy.localEnvelope(service: service, stream: stream, payload: payload),
          [UInt8](Legacy.remoteEnvelope(service: service, stream: stream, payload: Data(payload))))
      }
    }
  }

  // MARK: - The shared codec sends exactly that

  func testTheCodecsEnvelopeIsByteIdenticalToBothFormerEncoders() throws {
    let payloads: [[UInt8]] = [
      [], [0x21, 0, 0, 0, 0], Array(repeating: 7, count: 5000),
      Array(repeating: 0xAB, count: 70_000),
    ]
    for byte in UInt8(0)...7 {
      let service = try XCTUnwrap(DaemonService(rawValue: byte))
      for stream: UInt32 in [0, 1, 0xFF, 0x0102_0304, 0xDEAD_BEEF, .max] {
        for payload in payloads {
          let local = Legacy.localEnvelope(service: byte, stream: stream, payload: payload)
          XCTAssertEqual(
            DaemonEnvelope.encode(service: service, stream: stream, payload: payload), local)
          XCTAssertEqual(
            DaemonEnvelope.encode(service: service, stream: stream, payload: Data(payload)),
            Legacy.remoteEnvelope(service: byte, stream: stream, payload: Data(payload)))
        }
      }
    }
  }

  func testTheCodecsVerbsAreTheFramesTheClientsSent() throws {
    XCTAssertEqual(DaemonControl.list(), SessionFrame(kind: .list).encoded())
    let identifier = try XCTUnwrap(SessionIdentifier(uuidString: session.uuidString))
    XCTAssertEqual(
      DaemonControl.kill(identifier),
      SessionFrame(kind: .kill, payload: SessionIdentifierPayload.encode(identifier)).encoded())
    XCTAssertEqual(
      DaemonControl.signal(.quit, session: session), RunSignal.quit.frame(session: session))
    XCTAssertEqual(
      DaemonControl.retag(session: session, workroom: "wr|/p|a"),
      SessionRetag.frame(session: session, workroom: "wr|/p|a"))
  }

  func testTheServicesAreTheDaemonsNumbers() {
    XCTAssertEqual(DaemonService.control.rawValue, 0)
    XCTAssertEqual(DaemonService.terminal.rawValue, 1)
    XCTAssertEqual(DaemonService.vcs.rawValue, 2)
    XCTAssertEqual(DaemonService.file.rawValue, 3)
    XCTAssertEqual(DaemonService.status.rawValue, 4)
    XCTAssertEqual(DaemonService.forward.rawValue, 5)
    XCTAssertEqual(DaemonService.layout.rawValue, 6)
    XCTAssertEqual(DaemonService.programStatus.rawValue, 7)
  }

  // MARK: - Envelope (moved from the app's DaemonControlClientTests)

  func testEnvelopeHeaderIsServiceThenStreamThenLength() {
    let bytes = DaemonEnvelope.encode(service: .terminal, stream: 0xDEAD_BEEF, payload: [1, 2, 3])
    XCTAssertEqual(bytes[0], 0x01, "terminal service")
    XCTAssertEqual(Array(bytes[1..<5]), [0xDE, 0xAD, 0xBE, 0xEF], "stream id, big-endian")
    XCTAssertEqual(Array(bytes[5..<9]), [0, 0, 0, 3], "payload length, big-endian")
    XCTAssertEqual(Array(bytes[9...]), [1, 2, 3])
  }

  func testEnvelopeRoundTrips() throws {
    let payload = Array(repeating: UInt8(7), count: 5000)
    let bytes = DaemonEnvelope.encode(service: .control, stream: 1, payload: payload)
    let decoded = try XCTUnwrap(DaemonEnvelope.decode(bytes))
    XCTAssertEqual(decoded.payload, payload)
    XCTAssertEqual(decoded.consumed, bytes.count)
  }

  func testEnvelopeNeedsMoreBytesRatherThanGuessing() {
    let bytes = DaemonEnvelope.encode(service: .control, stream: 1, payload: [9, 9])
    for cut in 0..<bytes.count {
      XCTAssertNil(
        DaemonEnvelope.decode(Array(bytes.prefix(cut))), "a \(cut)-byte prefix should not decode")
    }
  }

  /// The layering the whole design rests on: a terminal frame inside an envelope, out again
  /// unchanged.
  func testASessionFrameSurvivesTheEnvelope() throws {
    let frame = SessionFrame(kind: .list)
    let wire = DaemonEnvelope.encode(service: .control, stream: 0, payload: frame.encoded())
    let decoded = try XCTUnwrap(DaemonEnvelope.decode(wire))

    var frames = SessionFrameDecoder()
    frames.push(decoded.payload)
    XCTAssertEqual(try frames.next(), frame)
  }

  /// The header the connection's read loop routes on: service, stream and length, read from the
  /// first nine bytes whatever follows them.
  func testTheHeaderIsReadFromTheFirstNineBytes() throws {
    let wire = DaemonEnvelope.encode(service: .layout, stream: 0x0102_0304, payload: [1, 2, 3, 4])
    XCTAssertNil(DaemonEnvelope.header(of: Data(wire.prefix(8))))
    let header = try XCTUnwrap(DaemonEnvelope.header(of: Data(wire.prefix(9))))
    XCTAssertEqual(header, DaemonEnvelope.Header(service: 6, stream: 0x0102_0304, length: 4))
    XCTAssertEqual(DaemonEnvelope.header(of: Data(wire)), header)
    let decoded = try XCTUnwrap(DaemonEnvelope.decode(wire))
    XCTAssertEqual(decoded.header, header)
  }

  // MARK: - Replies, as both clients read them

  func testASessionListReplyIsReadOnlyFromASessionsFrame() throws {
    let empty = SessionFrame(kind: .sessions, payload: [0, 0, 0, 0])
    XCTAssertEqual(try DaemonControl.sessionList(in: empty).count, 0)
    let refusal = SessionFrame(kind: .failure, payload: Array("too many".utf8))
    XCTAssertThrowsError(try DaemonControl.sessionList(in: refusal)) {
      XCTAssertEqual(
        $0 as? HostConnectionError, .serviceUnavailable("No session list: too many"))
    }
    let truncated = SessionFrame(kind: .sessions, payload: [0, 0, 0, 1])
    XCTAssertThrowsError(try DaemonControl.sessionList(in: truncated))
  }

  func testAKillIsAnsweredOnlyByAnAcknowledgement() {
    XCTAssertTrue(DaemonControl.killed(SessionFrame(kind: .acknowledged)))
    XCTAssertFalse(DaemonControl.killed(SessionFrame(kind: .failure, payload: [0x61])))
    XCTAssertFalse(DaemonControl.killed(SessionFrame(kind: .sessions, payload: [0, 0, 0, 0])))
  }

  /// The local client reads a frame it has already decoded; the remote one reads the first frame
  /// of the envelope's payload (`DaemonClient.signalSession`). Both must read the same answer from
  /// the same frame.
  func testASignalOrRetagReplyReadsTheSameFromAFrameAsFromItsBytes() {
    let frames = [
      SessionFrame(kind: .acknowledged),
      SessionFrame(kind: .failure, payload: Array("no session 5a1e0f7e".utf8)),
      SessionFrame(kind: .failure, payload: Array("not a run session: 5a1e".utf8)),
      SessionFrame(kind: .sessions, payload: [0, 0, 0, 0]),
    ]
    for frame in frames {
      let read = try? DaemonControl.firstFrame(of: Data(frame.encoded()))
      XCTAssertEqual(RunSignalReply(frame: frame), read.flatMap(RunSignalReply.init(frame:)))
      XCTAssertEqual(SessionRetag.reply(to: frame), read.flatMap(SessionRetag.reply(to:)))
    }
  }

  func testTheFirstFrameOfAReplyIsItsAnswer() throws {
    let reply =
      SessionFrame(kind: .acknowledged).encoded() + SessionFrame(kind: .failure).encoded()
    XCTAssertEqual(try DaemonControl.firstFrame(of: Data(reply)), SessionFrame(kind: .acknowledged))
    XCTAssertNil(try DaemonControl.firstFrame(of: Data([0x32, 0, 0])), "an incomplete frame")
  }
}

/// The two envelope encoders as they were before the shared codec, verbatim but for their names.
private enum Legacy {
  /// `DaemonControlClient.encodeEnvelope`, with the service as its raw byte.
  static func localEnvelope(service: UInt8, stream: UInt32, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = [service]
    for shift in [24, 16, 8, 0] { bytes.append(UInt8((stream >> UInt32(shift)) & 0xFF)) }
    let length = UInt32(payload.count)
    for shift in [24, 16, 8, 0] { bytes.append(UInt8((length >> UInt32(shift)) & 0xFF)) }
    bytes.append(contentsOf: payload)
    return bytes
  }

  /// `DaemonVCSConnection.envelope(service:stream:payload:)`.
  static func remoteEnvelope(service: UInt8, stream: UInt32, payload: Data) -> Data {
    var envelope = Data([service])
    for value in [stream, UInt32(payload.count)] {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
    }
    envelope.append(payload)
    return envelope
  }
}
