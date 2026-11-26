import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Rename… on a Terminals-section row's title-bar tab (#652 critique): the row edits its name in
/// place while it is drawn and the sidebar shows it; otherwise the caller shows the sheet. And the
/// renames themselves, from the row's field or the tab's menu.
@MainActor
final class SidebarInlineRenameTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: projects, terminalsSection: section)
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.sidebarVisible = true
    return store
  }

  private func standalone(_ store: AppStore) throws -> SidebarID {
    store.newStandaloneTerminal()
    return try XCTUnwrap(store.selectedTargetID)
  }

  // MARK: SidebarInlineRename

  /// Value: protects=a row asked to rename only while it is drawn, and only once;
  /// fails_when=a row out of view is asked (so no sheet shows and nothing happens), or a row
  /// claims the ask twice; seam=SidebarInlineRename
  func testOnlyADrawnRowIsAskedAndTakesTheAskOnce() {
    let renames = SidebarInlineRename()
    let sid = SidebarID.standalone(UUID())

    XCTAssertFalse(renames.begin(sid), "a row not drawn can't be asked")
    XCTAssertNil(renames.pending)

    renames.rowAppeared(sid)
    XCTAssertTrue(renames.begin(sid))
    XCTAssertFalse(renames.claim(.standalone(UUID())), "another row doesn't take it")
    XCTAssertTrue(renames.claim(sid))
    XCTAssertFalse(renames.claim(sid), "taken once")
  }

  /// A row drawn twice at once (a List re-making it) stays drawn until both go; going clears an
  /// ask it never took.
  func testARowStaysDrawnUntilEveryViewOfItGoes() {
    let renames = SidebarInlineRename()
    let sid = SidebarID.terminalGroup(UUID())
    renames.rowAppeared(sid)
    renames.rowAppeared(sid)
    renames.rowDisappeared(sid)
    XCTAssertTrue(renames.isDrawn(sid))
    XCTAssertTrue(renames.begin(sid))

    renames.rowDisappeared(sid)
    XCTAssertFalse(renames.isDrawn(sid))
    XCTAssertNil(renames.pending, "an ask the row never took goes with it")
  }

  /// The row whose name field shows is the one editing, which keeps its row drag off; it stops on
  /// its own field going or the row going, not on another row's.
  func testTheRowEditingItsNameIsTheOneWhoseFieldShows() {
    let renames = SidebarInlineRename()
    let sid = SidebarID.standalone(UUID())
    renames.rowAppeared(sid)

    renames.setEditing(sid, true)
    XCTAssertEqual(renames.editing, sid)
    renames.setEditing(.terminalGroup(UUID()), false)
    XCTAssertEqual(renames.editing, sid, "another row's field going leaves it")
    renames.setEditing(sid, false)
    XCTAssertNil(renames.editing)

    renames.setEditing(sid, true)
    renames.rowDisappeared(sid)
    XCTAssertNil(renames.editing, "a row that goes edits nothing")
  }

  // MARK: From the tab

  /// Value: protects=Rename… on a section target's tab edits its row in place only when the row is
  /// in view; fails_when=it asks a hidden sidebar's or the Projects view's row (leaving the user with
  /// nothing), or asks a project's target; seam=AppStore.beginSidebarRename
  func testTheTabsRenameAsksTheRowOnlyWhenItIsInView() throws {
    let store = makeStore()
    let sid = try standalone(store)

    XCTAssertFalse(store.beginSidebarRename(sid), "its row isn't drawn")
    store.sidebarRename.rowAppeared(sid)
    XCTAssertTrue(store.beginSidebarRename(sid))
    XCTAssertTrue(store.sidebarRename.claim(sid))

    store.sidebarVisible = false
    XCTAssertFalse(store.beginSidebarRename(sid), "the sidebar is hidden")
    store.sidebarVisible = true

    store.sidebarView = .projects
    XCTAssertFalse(store.beginSidebarRename(sid), "the sidebar shows its Projects view")
    store.sidebarView = .open

    let root = SidebarID.root(project: "/p")
    store.sidebarRename.rowAppeared(root)
    XCTAssertFalse(store.beginSidebarRename(root), "only Terminals-section rows rename so")
  }

  // MARK: The renames

  /// Value: protects=a standalone terminal's row names it, and an empty name gives the default
  /// back; fails_when=the name doesn't reach the terminal or an empty one sticks;
  /// seam=AppStore.renameStandaloneTerminal
  func testRenamingAStandaloneTerminalNamesItAndAnEmptyNameRestoresTheDefault() throws {
    let store = makeStore()
    let sid = try standalone(store)
    let before = try XCTUnwrap(store.standaloneTerminal(sid)?.tab.title)

    store.renameStandaloneTerminal(sid, to: "  Build box ")
    XCTAssertEqual(store.standaloneTerminal(sid)?.tab.title, "Build box")
    XCTAssertEqual(store.standaloneTerminal(sid)?.tab.terminal?.userTitle, "Build box")

    store.renameStandaloneTerminal(sid, to: "")
    XCTAssertNil(store.standaloneTerminal(sid)?.tab.terminal?.userTitle)
    XCTAssertEqual(store.standaloneTerminal(sid)?.tab.title, before)
  }

  /// Value: protects=New Terminal in Group on a group's tab opens one in it, selected;
  /// fails_when=it opens nowhere or in another target; seam=AppStore.newTerminalInGroup
  func testNewTerminalInGroupFromItsTabOpensOneInTheGroup() throws {
    let store = makeStore()
    let sid = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    let id = try XCTUnwrap(sid.targetID)
    store.newStandaloneTerminal()
    XCTAssertNotEqual(store.selectedTargetID, sid)

    store.newTerminalInGroup(sid)

    XCTAssertEqual(store.selectedTargetID, sid)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 2)
  }
}
