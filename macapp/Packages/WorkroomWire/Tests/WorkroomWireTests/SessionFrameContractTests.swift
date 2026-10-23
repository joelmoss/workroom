import Foundation
import XCTest

@testable import WorkroomWire

/// Reads `testdata/contracts/frames.tsv`, which the Rust codec's tests read too
/// (`vcs/crates/wr-protocol/src/frame.rs`): every kind encodes and decodes to the same bytes in
/// both codecs, and the same malformed frames are refused.
final class SessionFrameContractTests: XCTestCase {
  /// Kinds the daemon added after WorkroomWire was frozen (v2.0.0). The shipped app reads them as
  /// unknown, so that is what this checks; a kind missing from both here and `SessionFrameKind`
  /// fails the test rather than being skipped.
  private static let newerThanWorkroomWire: Set<String> = ["handOff", "signal"]

  /// The repository's `testdata/contracts/frames.tsv`, found from this file's own source location.
  private static let fixture = URL(fileURLWithPath: String(describing: #filePath))
    .deletingLastPathComponent()  // WorkroomWireTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // WorkroomWire
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // macapp
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("testdata/contracts/frames.tsv")

  private func bytes(_ hex: Substring) -> [UInt8] {
    guard hex != "-" else { return [] }
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      out.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return out
  }

  func testTheSharedContractFixtureHolds() throws {
    let text = try String(contentsOf: Self.fixture, encoding: .utf8)
    let kinds = Dictionary(
      uniqueKeysWithValues: SessionFrameKind.allCases.map { (String(describing: $0), $0) })
    var rows = 0
    var seen: [String] = []
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
      XCTAssertEqual(columns.count, 3, "not three columns: \(line)")
      guard columns.count == 3 else { continue }
      let expect = String(columns[0])
      let frame = bytes(columns[1])
      let payload = bytes(columns[2])
      var decoder = SessionFrameDecoder()
      decoder.push(frame)
      switch expect {
      case "error:frameTooLarge":
        XCTAssertThrowsError(try decoder.next(), expect) { error in
          guard case .frameTooLarge = error as? SessionProtocolError else {
            return XCTFail("\(line): \(error)")
          }
        }
      case "error:unknownKind":
        XCTAssertThrowsError(try decoder.next(), expect) { error in
          XCTAssertEqual(error as? SessionProtocolError, .unknownFrameKind(frame[0]), "\(line)")
        }
      default:
        seen.append(expect)
        if let kind = kinds[expect] {
          XCTAssertEqual(kind.rawValue, frame[0], "\(line)")
          XCTAssertEqual(SessionFrame(kind: kind, payload: payload).encoded(), frame, "\(line)")
          XCTAssertEqual(try decoder.next(), SessionFrame(kind: kind, payload: payload), "\(line)")
          XCTAssertEqual(decoder.bufferedByteCount, 0, "\(line)")
        } else {
          XCTAssertTrue(
            Self.newerThanWorkroomWire.contains(expect), "\(expect) is in neither codec's list")
          XCTAssertThrowsError(try decoder.next(), expect) { error in
            XCTAssertEqual(error as? SessionProtocolError, .unknownFrameKind(frame[0]), "\(line)")
          }
        }
      }
      rows += 1
    }
    XCTAssertEqual(rows, 17, "every row was read")
    // Every kind WorkroomWire defines has exactly one row, so none can go uncovered.
    XCTAssertEqual(seen.count, Set(seen).count, "a kind is listed twice")
    XCTAssertEqual(
      Set(seen), Set(kinds.keys).union(Self.newerThanWorkroomWire), "one fixture row per frame kind"
    )
  }
}
