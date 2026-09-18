import XCTest

@testable import Workroom

final class AgentVCSProtocolTests: XCTestCase {
  func testAbsentContentIsDifferentFromMissingResult() throws {
    let content = try AgentVCSReply<String?>.decode(Data(#"{"version":1,"result":null}"#.utf8))
    XCTAssertNil(content)
    XCTAssertThrowsError(try AgentVCSReply<String?>.decode(Data(#"{"version":1}"#.utf8))) {
      XCTAssertTrue($0 is HostConnectionError)
    }
  }

  func testMalformedAndWrongVersionRepliesAreServiceFailures() {
    for text in [
      "not JSON", #"{"version":99,"result":"text"}"#, #"{"version":1,"result":[]}"#,
      #"{"version":1,"error":"Unknown"}"#, #"{"version":1,"error":{}}"#,
      #"{"version":1,"error":{"Unknown":"failure"}}"#,
    ] {
      XCTAssertThrowsError(try AgentVCSReply<String>.decode(Data(text.utf8))) {
        XCTAssertTrue($0 is HostConnectionError)
      }
    }
  }

  func testNativeErrorMeaningsSurviveTheWire() {
    let cases: [(String, VCSError)] = [
      (#"{"version":1,"error":"LockContention"}"#, .lockContention),
      (#"{"version":1,"error":"StaleSnapshot"}"#, .staleSnapshot),
      (#"{"version":1,"error":{"UnsupportedRepo":"gone"}}"#, .unsupportedRepo("gone")),
      (#"{"version":1,"error":{"PartialData":"retry"}}"#, .partialData("retry")),
      (#"{"version":1,"error":{"Io":"gone"}}"#, .io("gone")),
    ]
    for (text, expected) in cases {
      XCTAssertThrowsError(try AgentVCSReply<String>.decode(Data(text.utf8))) {
        XCTAssertEqual($0 as? VCSError, expected)
      }
    }
  }
}
