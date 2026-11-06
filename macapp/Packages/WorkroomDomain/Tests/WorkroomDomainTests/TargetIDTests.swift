import Foundation
import WorkroomDomain
import XCTest

/// `TargetID`'s encoding is a stored contract: `session.json`, `Defaults`, the daemon's session
/// tags and banner `userInfo` all hold it, and sessions outlive app versions.
final class TargetIDTests: XCTestCase {
  private static let run = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

  /// Value: protects=old session.json files and session tags read back to the same targets;
  /// fails_when=a kind's encoding or its parse drifts; why_new=the id was a bare string before;
  /// seam=none; no_claim=whether the target still exists
  func testEachKindEncodesAsEarlierBuildsWroteIt() {
    let cases: [(TargetID, String)] = [
      (.root(project: "/p"), "root|/p"),
      (.workroom(project: "/p", name: "calm-otter"), "wr|/p|calm-otter"),
      (.creation(Self.run), "creation:6F9619FF-8B86-D011-B42D-00C04FC964FF"),
      (.quickTerminal, "workroom.quickTerminal"),
    ]
    for (id, string) in cases {
      XCTAssertEqual(id.encoded, string)
      XCTAssertEqual("\(id)", string, "interpolated into keys and log lines")
      XCTAssertEqual(TargetID(encoded: string), id, string)
    }
  }

  /// Value: protects=sorted id lists in session.json and the run toasts' order;
  /// fails_when=ordering stops following the encoded string; why_new=a String sorted itself;
  /// seam=none; no_claim=none
  func testOrderIsTheEncodedStringsOrder() {
    let ids: [TargetID] = [
      .workroom(project: "/p", name: "b"), .root(project: "/p"), .quickTerminal,
      .creation(Self.run), .workroom(project: "/p", name: "a"),
    ]
    XCTAssertEqual(ids.sorted().map(\.encoded), ids.map(\.encoded).sorted())
  }

  func testAProjectPathMayHoldTheSeparator() {
    let id = TargetID.workroom(project: "/a|b", name: "fix_1")
    XCTAssertEqual(id.encoded, "wr|/a|b|fix_1")
    XCTAssertEqual(TargetID(encoded: id.encoded), id)
    XCTAssertEqual(TargetID(encoded: "root|/a|b"), .root(project: "/a|b"))
  }

  func testAStringNoBuildWroteIsNoTarget() {
    for string in ["", "wr|/p", "creation:not-a-uuid", "creation|\(Self.run)", "/p", "x"] {
      XCTAssertNil(TargetID(encoded: string), string)
    }
  }

  func testOnlyRootsAndWorkroomsAreSidebarRowsOfAProject() {
    XCTAssertEqual(TargetID.root(project: "/p").sidebarID, .root(project: "/p"))
    XCTAssertEqual(
      TargetID.workroom(project: "/p", name: "a").sidebarID, .workroom(project: "/p", name: "a"))
    XCTAssertNil(TargetID.creation(Self.run).sidebarID)
    XCTAssertNil(TargetID.quickTerminal.sidebarID)
    XCTAssertEqual(TargetID.workroom(project: "/p", name: "a").projectPath, "/p")
    XCTAssertNil(TargetID.creation(Self.run).projectPath)
    XCTAssertNil(TargetID.quickTerminal.projectPath)
  }

  func testEverySidebarRowButAProjectOpensATarget() {
    XCTAssertEqual(SidebarID.root(project: "/p").targetID, .root(project: "/p"))
    XCTAssertEqual(
      SidebarID.workroom(project: "/p", name: "a").targetID, .workroom(project: "/p", name: "a"))
    XCTAssertEqual(SidebarID.creation(project: "/p", id: Self.run).targetID, .creation(Self.run))
    XCTAssertNil(SidebarID.project("/p").targetID)
  }
}
