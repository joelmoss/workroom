import AppKit
import DaemonConnection
import WorkroomDomain
import XCTest

@testable import Workroom

/// The sidebar's view switcher (ADR 0083): which view a window shows, the dot a hidden view's tab
/// wears while something in it waits on the user, and a terminal drag resting on a hidden view's
/// tab to show it. The view's round trip with the window's session is
/// `AppStoreSessionRestoreTests`'; that only the shown view is mounted is
/// `SidebarInvalidationTests`'.
@MainActor
final class SidebarViewTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: projects, terminalsSection: section)
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    return store
  }

  private func notification(for target: TargetID) -> WorkroomNotification {
    WorkroomNotification(
      id: UUID(), targetID: target, tabID: UUID(), source: "fixture", title: "Done", body: nil,
      date: Date(), count: 1)
  }

  // MARK: The selection

  /// Value: protects=a new window shows Open, a tab's click shows its view, and View ▸ Show Open
  /// / Show Projects shows the sidebar too; fails_when=a window starts on Projects, selecting the
  /// shown view writes again, or the menu leaves a hidden sidebar hidden; seam=AppStore
  func testANewWindowShowsOpenAndTheTabsSwitchIt() {
    let store = makeStore()
    XCTAssertEqual(store.sidebarView, .open)

    store.selectSidebarView(.projects)
    XCTAssertEqual(store.sidebarView, .projects)
    store.selectSidebarView(.open)
    XCTAssertEqual(store.sidebarView, .open)

    store.sidebarVisible = false
    store.showSidebarView(.projects)
    XCTAssertEqual(store.sidebarView, .projects)
    XCTAssertTrue(store.sidebarVisible, "the menu's item shows a hidden sidebar")
  }

  /// Value: protects=the switcher's tabs name and identify their views as the UI tests and
  /// VoiceOver read them; fails_when=an id or a name changes under them
  func testEachViewsTabNamesIt() {
    XCTAssertEqual(SidebarView.allCases, [.open, .projects], "Open first, then Projects")
    XCTAssertEqual(SidebarView.open.identifier, "sidebar.view.open")
    XCTAssertEqual(SidebarView.projects.identifier, "sidebar.view.projects")
    XCTAssertEqual(SidebarView.open.title, "Open")
    XCTAssertEqual(SidebarView.projects.title, "Projects")
  }

  // MARK: The attention dot

  /// Value: protects=the Open tab's dot follows the window's workroom tabs: unread on one, or a
  /// terminal in one waiting, and nothing else; fails_when=it misses a waiting terminal or an
  /// unread mark, or lights for a workroom this window hasn't open; seam=sidebarViewNeedsAttention
  func testTheOpenDotFollowsTheWindowsOpenRows() throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    let sid = try XCTUnwrap(store.selectedTargetID)
    let id = try XCTUnwrap(sid.targetID)
    XCTAssertFalse(store.sidebarViewNeedsAttention(.open), "nothing waits")

    store.notifications.seedForTesting([
      notification(for: .workroom(project: "/p", name: "a"))
    ])
    XCTAssertFalse(
      store.sidebarViewNeedsAttention(.open), "a workroom this window hasn't open isn't Open's")
    XCTAssertTrue(store.sidebarViewNeedsAttention(.projects), "it is the Projects view's")

    store.notifications.seedForTesting([notification(for: id)])
    XCTAssertTrue(store.sidebarViewNeedsAttention(.open), "unread on an open row")

    store.notifications.seedForTesting([])
    let target = try XCTUnwrap(store.target(for: sid))
    let tab = try XCTUnwrap(store.terminals.tabs(for: target).first)
    store.terminals.seedProgramStatusForFixture(
      tab: tab.id, target: id,
      records: [ProgramStatusRecord(id: "", state: .blocked, kind: .permission, episode: 1)])
    XCTAssertTrue(store.sidebarViewNeedsAttention(.open), "a terminal waiting on an open row")
    XCTAssertFalse(
      store.sidebarViewNeedsAttention(.projects), "a terminal with no project isn't Projects'")
  }

  // MARK: Spring-loading

  private static let projectsTab = CGRect(x: 100, y: 500, width: 60, height: 30)

  private func session(_ store: AppStore) -> TerminalDragSession {
    TerminalDragSession(
      store: store, measure: { _ in [] },
      springTabs: { _ in
        [(.open, CGRect(x: 60, y: 500, width: 20, height: 30)), (.projects, Self.projectsTab)]
      })
  }

  /// Value: protects=a terminal drag resting on the hidden view's tab shows that view when the
  /// wait is up, the tab showing the wait meanwhile, and moving off drops it (ADR 0083);
  /// fails_when=the drag never springs, springs to the view already shown, or a wait outlives
  /// the drag; seam=TerminalDragSession.moved / springFired
  func testADragRestingOnTheHiddenViewsTabShowsIt() throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    let sid = try XCTUnwrap(store.selectedTargetID)
    let drag = session(store)
    let over = CGPoint(x: Self.projectsTab.midX, y: Self.projectsTab.midY)

    drag.moved(.entry(sid), from: .titleBar, to: CGPoint(x: 70, y: 510))
    XCTAssertNil(drag.springCandidate, "over the shown view's tab, nothing to show")

    drag.moved(.entry(sid), from: .titleBar, to: over)
    XCTAssertEqual(drag.springCandidate, .projects)
    XCTAssertEqual(store.sidebarSpringTarget, .projects, "the tab shows the wait")
    drag.moved(.entry(sid), from: .titleBar, to: CGPoint(x: 400, y: 100))
    XCTAssertNil(drag.springCandidate, "moving off drops the wait")
    XCTAssertNil(store.sidebarSpringTarget)

    drag.moved(.entry(sid), from: .titleBar, to: over)
    drag.springFired()
    XCTAssertEqual(store.sidebarView, .projects, "the wait up, the view shows")
    XCTAssertNil(store.sidebarSpringTarget)

    store.selectSidebarView(.open)
    drag.moved(.entry(sid), from: .titleBar, to: over)
    drag.cancel()
    XCTAssertNil(drag.springCandidate, "the drag's end drops the wait")
    drag.springFired()
    XCTAssertEqual(store.sidebarView, .open, "and nothing springs after it")
  }

  /// Value: protects=a Projects-tree terminal row's drag never springs: its gesture lives on the
  /// row, and showing the Open view would end it mid-drag; fails_when=its drag springs;
  /// seam=TerminalDragSession.springLoads
  func testAProjectsTreeTerminalsDragDoesNotSpring() throws {
    let store = makeStore()
    store.selectSidebarView(.projects)
    let root = SidebarID.root(project: "/p")
    let drag = TerminalDragSession(
      store: store, measure: { _ in [] },
      springTabs: { _ in [(.open, CGRect(x: 60, y: 500, width: 20, height: 30))] })

    drag.moved(.terminal(UUID(), of: root), from: .sidebar, to: CGPoint(x: 70, y: 510))
    XCTAssertNil(drag.springCandidate)
    XCTAssertTrue(TerminalDragSession.springLoads(.terminal(UUID(), of: root), from: .paneTabs))
    XCTAssertTrue(TerminalDragSession.springLoads(.entry(root), from: .sidebar), "an Open row's")
  }
}
