import WorkroomDomain
import XCTest

@testable import Workroom

/// A window with no projects is a plain terminal window (#657, ADR 0077): ⌘T opens a standalone
/// terminal, the sidebar and its toggle show once a terminal has a row, and the launch sweep still
/// ends the standalone sessions a crash left behind.
@MainActor
final class NoProjectsWindowTests: XCTestCase {
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
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    return store
  }

  /// Value: protects=the sidebar and its toggle appear with only terminals; fails_when=they stay
  /// keyed on the project list alone; why_new=#657; seam=AppStore; no_claim=the view layout
  func testSidebarHasContentOnceATerminalHasARowEvenWithNoProjects() {
    let store = makeStore()
    XCTAssertFalse(store.sidebarHasContent)

    store.newStandaloneTerminal()

    XCTAssertTrue(projects.projects.isEmpty)
    XCTAssertTrue(store.sidebarHasContent)
    store.sidebarVisible = true
    store.toggleSidebar()
    XCTAssertFalse(store.sidebarVisible, "the toggle works with terminals and no projects")
  }

  /// Value: protects=the toggle stays inert with nothing to list; fails_when=it flips a hidden
  /// sidebar; why_new=#657; seam=AppStore; no_claim=none
  func testToggleSidebarDoesNothingWithNoProjectsAndNoTerminals() {
    let store = makeStore()
    store.sidebarVisible = true
    store.toggleSidebar()
    XCTAssertTrue(store.sidebarVisible)
  }

  /// Value: protects=⌘T with no projects opens a standalone terminal and its menu item is on;
  /// fails_when=New Terminal needs a project; why_new=#657; seam=AppStore; no_claim=the menu bar
  func testNewTerminalWorksWithNoProjects() throws {
    let store = makeStore()
    XCTAssertTrue(store.newTerminalAvailable(workroomSelected: false))

    store.newTerminalInSelectedTarget()

    let sid = try XCTUnwrap(store.selectedTargetID)
    guard case .standalone = sid else { return XCTFail("\(sid) is not a standalone terminal") }
    XCTAssertEqual(section.entries.map(\.sidebarID), [sid])
  }

  /// Value: protects=⌘T stays off while a project row's terminal can't open and a target is
  /// selected; fails_when=it is enabled over a blocked target; why_new=#657; seam=AppStore
  func testNewTerminalIsOffOverASelectionThatOpensNone() {
    projects.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let store = makeStore()
    store.selectedTargetID = .root(project: "/p")
    XCTAssertFalse(store.newTerminalAvailable(workroomSelected: false))
    XCTAssertTrue(store.newTerminalAvailable(workroomSelected: true))
  }

  /// Value: protects=a crash's standalone sessions are ended when the listing loaded empty, and a
  /// project session is spared; fails_when=the empty listing skips the sweep, or ends everything;
  /// why_new=#657; seam=AppStore; no_claim=the daemon call
  func testSweepOfAnEmptyListingEndsOnlyOrphanedStandaloneSessions() {
    let store = makeStore()
    let live = section.addStandalone()
    let gone = TargetID.standalone(UUID()).encoded

    XCTAssertTrue(store.sessionSurvivesSweep(live.encoded, in: []), "its row is in the section")
    XCTAssertFalse(store.sessionSurvivesSweep(gone, in: []), "no row: orphaned")
    XCTAssertTrue(
      store.sessionSurvivesSweep("wr|/p|a", in: []),
      "an empty listing could be a config that read as nothing: project sessions stay")
    XCTAssertFalse(
      store.sessionSurvivesSweep("wr|/p|a", in: [Project(path: "/q", vcs: "git", workrooms: [])]),
      "a real listing still ends a workroom that is gone")
  }
}
