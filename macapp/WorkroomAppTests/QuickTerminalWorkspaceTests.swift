import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Quick Terminal's tabs and splits. Surfaces are non-spawning, so no shell or renderer runs.
@MainActor
final class QuickTerminalWorkspaceTests: XCTestCase {
  private var emptied = 0

  private func makeWorkspace() -> QuickTerminalWorkspace {
    let workspace = QuickTerminalWorkspace(
      makeSurface: { GhosttySurfaceView(workingDirectory: $0, command: nil, spawnsSurface: false) },
      onEmpty: { [weak self] in self?.emptied += 1 })
    workspace.newTab(in: "/a")
    return workspace
  }

  func testSplitOpensBesideTheFocusedPaneInItsFolder() throws {
    let workspace = makeWorkspace()
    let first = try XCTUnwrap(workspace.selectedTab?.focused)
    workspace.panes[first]?.status.cwdChanged("/a/b")

    workspace.split(.horizontal)
    let tab = try XCTUnwrap(workspace.selectedTab)
    XCTAssertEqual(tab.layout.tabIDs.count, 2)
    XCTAssertNotEqual(tab.focused, first, "the new pane takes focus")
    XCTAssertEqual(tab.layout.tabIDs.first, first, "it opens to the right of the old one")
    XCTAssertEqual(
      workspace.focusedPane?.surface.workingDirectory, "/a/b", "in its neighbour's folder")
    guard case .split(_, let orientation, _, _, _) = tab.layout else {
      return XCTFail("not a split")
    }
    XCTAssertEqual(orientation, .horizontal)
  }

  func testNewTabOpensWhereItIsTold() {
    let workspace = makeWorkspace()
    workspace.newTab(in: "/c")
    XCTAssertEqual(workspace.tabs.count, 2)
    XCTAssertEqual(workspace.selectedTabID, workspace.tabs[1].id)
    XCTAssertEqual(workspace.focusedPane?.surface.workingDirectory, "/c")
  }

  func testClosingAPaneFocusesWhatIsLeft() throws {
    let workspace = makeWorkspace()
    let first = try XCTUnwrap(workspace.selectedTab?.focused)
    workspace.split(.vertical)
    let second = try XCTUnwrap(workspace.selectedTab?.focused)

    workspace.closeFocusedPane()
    XCTAssertEqual(workspace.selectedTab?.focused, first)
    XCTAssertEqual(workspace.selectedTab?.layout, .leaf(first))
    XCTAssertNil(workspace.panes[second], "its shell is gone")
    XCTAssertEqual(emptied, 0)
  }

  func testClosingATabsLastPaneSelectsTheNextTabThenTheWindowCloses() throws {
    let workspace = makeWorkspace()
    workspace.newTab(in: "/b")
    workspace.newTab(in: "/c")
    workspace.selectTab(at: 1)
    let third = workspace.tabs[2].id

    workspace.closeFocusedPane()
    XCTAssertEqual(workspace.tabs.count, 2)
    XCTAssertEqual(workspace.selectedTabID, third, "the tab that slid into its place")

    workspace.closeFocusedPane()
    XCTAssertEqual(
      workspace.selectedTabID, workspace.tabs[0].id, "the last tab's neighbour before it")
    workspace.closeFocusedPane()
    XCTAssertTrue(workspace.tabs.isEmpty)
    XCTAssertEqual(emptied, 1, "the last tab going closes the window")
  }

  func testAnUnselectedTabsShellExitingKeepsTheSelection() throws {
    let workspace = makeWorkspace()
    let firstPane = try XCTUnwrap(workspace.selectedTab?.focused)
    workspace.newTab(in: "/b")
    let selected = workspace.selectedTabID

    workspace.closePane(firstPane)
    XCTAssertEqual(workspace.tabs.count, 1)
    XCTAssertEqual(workspace.selectedTabID, selected)
  }

  func testClickingAPaneFocusesItAndSelectingIsBounded() throws {
    let workspace = makeWorkspace()
    let first = try XCTUnwrap(workspace.selectedTab?.focused)
    workspace.split(.horizontal)
    workspace.focus(first)
    XCTAssertEqual(workspace.selectedTab?.focused, first)

    workspace.selectTab(at: 5)
    XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id, "no tab 6: nothing changes")
  }

  func testTearDownAllEndsEveryShell() {
    let workspace = makeWorkspace()
    workspace.split(.horizontal)
    workspace.newTab(in: "/b")
    let surfaces = workspace.allSurfaces
    workspace.tearDownAll()
    XCTAssertTrue(surfaces.allSatisfy(\.isTornDown))
    XCTAssertTrue(workspace.panes.isEmpty)
    XCTAssertEqual(emptied, 0, "the window is already going")
  }
}

final class QuickTerminalKeyTests: XCTestCase {
  func testClassifiesTheQuickTerminalsKeys() {
    XCTAssertEqual(QuickTerminalKey.classify(flags: .command, characters: "w"), .closePane)
    XCTAssertEqual(QuickTerminalKey.classify(flags: .command, characters: "t"), .newTab)
    XCTAssertEqual(QuickTerminalKey.classify(flags: .command, characters: "d"), .splitRight)
    XCTAssertEqual(
      QuickTerminalKey.classify(flags: [.command, .shift], characters: "D"), .splitDown,
      "⇧ arrives as a capital")
    XCTAssertEqual(QuickTerminalKey.classify(flags: .command, characters: "1"), .selectTab(0))
    XCTAssertEqual(QuickTerminalKey.classify(flags: .command, characters: "9"), .selectTab(8))
  }

  func testLeavesEverythingElseToTheTerminal() {
    XCTAssertNil(QuickTerminalKey.classify(flags: .command, characters: "0"))
    XCTAssertNil(QuickTerminalKey.classify(flags: .command, characters: "c"), "copy")
    XCTAssertNil(QuickTerminalKey.classify(flags: .control, characters: "d"), "EOF to the shell")
    XCTAssertNil(QuickTerminalKey.classify(flags: [.command, .option], characters: "w"))
    XCTAssertNil(QuickTerminalKey.classify(flags: [.command, .shift], characters: "W"))
  }
}
