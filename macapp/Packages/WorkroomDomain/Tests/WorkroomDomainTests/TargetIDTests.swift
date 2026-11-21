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
      (.quickTerminal, "group:51C10A7E-0D4F-4E6A-9B2C-000000000001"),
      (.standalone(Self.run), "standalone:6F9619FF-8B86-D011-B42D-00C04FC964FF"),
      (.terminalGroup(Self.run), "group:6F9619FF-8B86-D011-B42D-00C04FC964FF"),
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
    for string in [
      "", "wr|/p", "creation:not-a-uuid", "creation|\(Self.run)", "/p", "x",
      "standalone:not-a-uuid", "standalone|\(Self.run)", "group:not-a-uuid", "group|\(Self.run)",
    ] {
      XCTAssertNil(TargetID(encoded: string), string)
    }
  }

  func testOnlyRootsAndWorkroomsAreSidebarRowsOfAProject() {
    XCTAssertEqual(TargetID.root(project: "/p").sidebarID, .root(project: "/p"))
    XCTAssertEqual(
      TargetID.workroom(project: "/p", name: "a").sidebarID, .workroom(project: "/p", name: "a"))
    XCTAssertNil(TargetID.creation(Self.run).sidebarID)
    XCTAssertEqual(TargetID.workroom(project: "/p", name: "a").projectPath, "/p")
    XCTAssertNil(TargetID.creation(Self.run).projectPath)
  }

  /// Value: protects=the Quick Terminal's sessions and row keeping one id across launches, and an
  /// older build's Quick Terminal sessions being recognisable only to the launch sweep (ADR 0077);
  /// fails_when=its well-known id drifts, or the legacy tag parses as a target that could be
  /// restored; why_new=the Quick Terminal became the built-in group (#661); seam=none;
  /// no_claim=what the sweep does with the tag
  func testTheQuickTerminalIsTheBuiltInGroupAndItsOldTagIsNoTarget() {
    XCTAssertEqual(TargetID.quickTerminal, .terminalGroup(TargetID.quickTerminalGroupID))
    XCTAssertEqual(TargetID.quickTerminal.sidebarID, .terminalGroup(TargetID.quickTerminalGroupID))
    XCTAssertNil(TargetID.quickTerminal.projectPath)
    XCTAssertEqual(TargetID.legacyQuickTerminalTag, "workroom.quickTerminal")
    XCTAssertNil(TargetID(encoded: TargetID.legacyQuickTerminalTag))
  }

  func testEverySidebarRowButAProjectOpensATarget() {
    XCTAssertEqual(SidebarID.root(project: "/p").targetID, .root(project: "/p"))
    XCTAssertEqual(
      SidebarID.workroom(project: "/p", name: "a").targetID, .workroom(project: "/p", name: "a"))
    XCTAssertEqual(SidebarID.creation(project: "/p", id: Self.run).targetID, .creation(Self.run))
    XCTAssertNil(SidebarID.project("/p").targetID)
  }

  /// Value: protects=a standalone terminal's row, title-bar tab and sessions living apart from
  /// every project (ADR 0077); fails_when=a standalone id claims a project or loses its row;
  /// why_new=the standalone kind (#655); seam=none; no_claim=whether the terminal still exists
  func testAStandaloneTerminalBelongsToNoProject() {
    let id = TargetID.standalone(Self.run)
    XCTAssertNil(id.projectPath)
    XCTAssertEqual(id.sidebarID, .standalone(Self.run))
    XCTAssertEqual(SidebarID.standalone(Self.run).targetID, id)
    XCTAssertFalse(SidebarID.standalone(Self.run).belongsToProject("/p"))
    XCTAssertTrue(SidebarID.standalone(Self.run).isInTerminalsSection)
    XCTAssertFalse(SidebarID.root(project: "/p").isInTerminalsSection)
  }

  /// Value: protects=a terminal group's row, title-bar tab and sessions living apart from every
  /// project (ADR 0077); fails_when=a group id claims a project or loses its row; why_new=terminal
  /// groups (#658); seam=none; no_claim=whether the group still exists
  func testATerminalGroupBelongsToNoProject() {
    let id = TargetID.terminalGroup(Self.run)
    XCTAssertNil(id.projectPath)
    XCTAssertEqual(id.sidebarID, .terminalGroup(Self.run))
    XCTAssertEqual(SidebarID.terminalGroup(Self.run).targetID, id)
    XCTAssertFalse(SidebarID.terminalGroup(Self.run).belongsToProject("/p"))
    XCTAssertTrue(SidebarID.terminalGroup(Self.run).isInTerminalsSection)
    XCTAssertNotEqual(
      id, .standalone(Self.run), "a group and a standalone terminal never share an id")
  }
}
