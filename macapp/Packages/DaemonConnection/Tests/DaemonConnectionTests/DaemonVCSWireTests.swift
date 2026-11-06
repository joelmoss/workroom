import DaemonConnection
import Foundation
import XCTest

/// The VCS replies' decode contract, against canned replies from older and newer daemons. Moved from
/// the app's `DaemonVCSProtocolTests` with the reply types.
final class DaemonVCSWireTests: XCTestCase {
  // MARK: An older daemon's replies

  /// A daemon built before #266 can still answer `current_ref` with jj's `Ancestor` kind (the nearest
  /// bookmark below `@`). It names a branch, so it must read as one rather than fail the decode.
  func testAnOlderDaemonsAncestorRefReadsAsABranch() throws {
    let ref = try DaemonVCSReply<DaemonRef>.decode(
      Data(#"{"version":1,"result":{"name":"main","kind":"Ancestor"}}"#.utf8))
    XCTAssertEqual(ref.name, "main")
    XCTAssertEqual(ref.kind.model, .branch)
  }

  /// A commit from an older daemon carries the jj-era fields (`change_id`, `is_working_copy`,
  /// `is_root`, `change_offset`, `divergent_siblings`), all set. History must still parse.
  func testAnOlderDaemonsJJEraCommitDecodes() throws {
    func commit(_ id: String, siblings: String) -> String {
      #"{"commit_id":""# + id
        + #"","short_id":"abc","change_id":"kxyzkxyz","summary":"s","body":"","#
        + #""authors":[{"name":"A","email":"a@e.com"}],"timestamp_ms":1700000000000,"#
        + #""refs":["main"],"parent_ids":["p1"],"is_working_copy":true,"is_root":false,"#
        + #""change_offset":1,"divergent_siblings":"# + siblings + #","push_state":"Unpushed"}"#
    }
    let json =
      #"{"version":1,"result":{"commits":["#
      + commit("abc123", siblings: "[" + commit("def456", siblings: "[]") + "]")
      + #"],"reached_end":true,"push_scope":null}}"#
    let page = try DaemonVCSReply<DaemonHistory>.decode(Data(json.utf8))
    let model = try XCTUnwrap(page.commits.first?.model)
    XCTAssertEqual(model.commitID, "abc123")
    XCTAssertEqual(model.refs, ["main"])
    XCTAssertEqual(model.parentIDs, ["p1"])
  }

  /// A daemon that has pruned the jj-era fields (ADR 0007) sends a commit without them. History must
  /// parse: an app that required them would hold that pruning back.
  func testACommitWithoutTheJJEraFieldsDecodes() throws {
    let json =
      #"{"version":1,"result":{"commits":[{"commit_id":"abc123","short_id":"abc","summary":"s","#
      + #""body":"","authors":[{"name":"A","email":"a@e.com"}],"timestamp_ms":1700000000000,"#
      + #""refs":["main"],"parent_ids":["p1"],"push_state":"Pushed"}],"#
      + #""reached_end":true,"push_scope":null}}"#
    let page = try DaemonVCSReply<DaemonHistory>.decode(Data(json.utf8))
    let model = try XCTUnwrap(page.commits.first?.model)
    XCTAssertEqual(model.commitID, "abc123")
    XCTAssertEqual(model.pushState, .pushed)
  }

  /// `files` is required: a `working_status` reply without it is malformed, and reading it as "no
  /// changes" would show a dirty checkout as clean.
  func testAWorkingStatusWithoutFilesIsRejectedNotClean() {
    let json = #"{"version":1,"result":{"conflicted":false,"untracked":[]}}"#
    XCTAssertThrowsError(try DaemonVCSReply<DaemonStatus>.decode(Data(json.utf8))) {
      guard case HostConnectionError.serviceUnavailable = $0 else {
        return XCTFail("expected an invalid-response failure, got \($0)")
      }
    }
  }
}
