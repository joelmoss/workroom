import AgentConnection
import XCTest

/// Decodes the agent's program-status events from the fixtures its serializer tests also read
/// (`testdata/program-status`), so the two halves cannot drift apart.
final class ProgramStatusWireTests: XCTestCase {
  private let boot = "6f1c2e0a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
  private let session = UUID(uuidString: "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a")!

  private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("testdata/program-status/\(name).json"))
  }

  func testStatusFixtureDecodes() throws {
    let decoded = try ProgramStatusEvent.decode(fixture("status"))
    XCTAssertEqual(decoded.droppedRecords, 0)
    XCTAssertEqual(
      decoded.event,
      .status(
        boot: boot, session: session, revision: 7, reporting: true,
        records: [
          ProgramStatusRecord(
            id: "", state: .blocked, kind: .permission, progress: -1, app: "claude-code",
            title: "", message: "Apply?", episode: 1, notify: true)
        ]))
  }

  func testEndedAndSnapshotCompleteFixturesDecode() throws {
    XCTAssertEqual(
      try ProgramStatusEvent.decode(fixture("ended")).event, .ended(boot: boot, session: session))
    XCTAssertEqual(
      try ProgramStatusEvent.decode(fixture("snapshot-complete")).event,
      .snapshotComplete(boot: boot, sessions: [session]))
  }

  /// A newer agent may add fields, states, kinds and events: each costs at most its own record.
  func testUnknownsDropOnlyWhatTheyTouch() throws {
    let record =
      #"{"id":"a","state":"working","kind":"none","progress":40,"app":"x","title":"","message":"","episode":0,"notify":false"#
    let json = """
      {"event":"status","boot":"\(boot)","session":"\(session.uuidString)","revision":1,\
      "reporting":true,"future":1,"records":[\(record),"extra":true},\
      \(record.replacingOccurrences(of: "working", with: "sleeping"))},\
      \(record.replacingOccurrences(of: "\"kind\":\"none\"", with: "\"kind\":\"payment\""))},\
      {"id":"b","state":"done"}]}
      """
    let decoded = try ProgramStatusEvent.decode(Data(json.utf8))
    XCTAssertEqual(decoded.droppedRecords, 3)
    guard case .status(_, _, _, _, let records) = decoded.event else {
      return XCTFail("\(String(describing: decoded.event))")
    }
    XCTAssertEqual(records.map(\.id), ["a"])
    XCTAssertNil(try ProgramStatusEvent.decode(Data(#"{"event":"later"}"#.utf8)).event)
  }

  func testRequestSendsLowercaseSessionAndOmitsAbsentFields() throws {
    let data = try JSONEncoder().encode(
      AgentProgramStatusRequest(method: "seen", session: session, revision: 3, states: ["done"]))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["session"] as? String, "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a")
    XCTAssertEqual(object["version"] as? Int, 1)
    let subscribe = try JSONEncoder().encode(AgentProgramStatusRequest(method: "subscribe"))
    XCTAssertEqual(
      Set((try JSONSerialization.jsonObject(with: subscribe) as? [String: Any])?.keys ?? [:].keys),
      ["version", "method"])
  }
}
