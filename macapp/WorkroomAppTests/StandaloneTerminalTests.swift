import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Standalone terminals in a window (#655, ADR 0077): ⌘T and ⌥⌘T open one, it gets a row in the
/// Terminals section and a title-bar tab of its own, and nothing project-shaped (the inspector,
/// version control, Run) applies to it. Two windows share one section, as they share one project
/// list, and each keeps its own tabs.
@MainActor
final class StandaloneTerminalTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let workroom = SidebarID.workroom(project: "/p", name: "a")

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  private func makeStore(cli: WorkroomCLIProtocol? = nil) -> AppStore {
    let store: AppStore
    if let cli {
      store = AppStore(terminalsSection: section, cli: cli)
    } else {
      store = AppStore(projectStore: projects, terminalsSection: section)
    }
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    // No daemon behind these panes: every retag succeeds.
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    return store
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  private func standalone(_ store: AppStore, file: StaticString = #filePath, line: UInt = #line)
    throws -> SidebarID
  {
    let sid = try XCTUnwrap(store.selectedTargetID, file: file, line: line)
    guard case .standalone = sid else {
      XCTFail("\(sid) is not a standalone terminal", file: file, line: line)
      return sid
    }
    return sid
  }

  private func tabCount(_ store: AppStore, _ sid: SidebarID) -> Int {
    sid.targetID.map(store.terminals.tabCount(forTargetID:)) ?? 0
  }

  // MARK: Opening one

  /// Value: protects=⌘T always gives a shell (story 1); fails_when=⌘T with nothing selected does
  /// nothing, or opens a terminal with no row or tab; why_new=standalone terminals (#655);
  /// seam=AppStore; no_claim=the views drawing the row
  func testCommandTWithNothingSelectedOpensAStandaloneTerminal() throws {
    let store = makeStore()

    store.newTerminalInSelectedTarget()

    let sid = try standalone(store)
    XCTAssertEqual(rows, [sid], "its row is in the Terminals section")
    XCTAssertEqual(tabCount(store, sid), 1, "with its one terminal")
    XCTAssertEqual(
      store.orderedWorkroomTargets().map(\.target.id), [sid.targetID], "and its title-bar tab")
    XCTAssertEqual(store.selectedTarget?.path, TerminalsSection.newTerminalDirectory())
    XCTAssertEqual(store.selectedTarget?.title, "Terminal 1", "titled by its terminal's name")
  }

  /// A project's row is selected by `selectedProjectID` alone: it opens no terminals.
  func testCommandTOnAProjectsRowOpensAStandaloneTerminal() throws {
    let store = makeStore()
    store.selectedProjectID = "/p"

    store.newTerminalInSelectedTarget()

    XCTAssertEqual(rows, [try standalone(store)])
  }

  /// Value: protects=each standalone terminal stays its own row and tab (story 3);
  /// fails_when=⌘T on one adds a second tab inside it; why_new=#655; seam=AppStore;
  /// no_claim=groups (#659)
  func testCommandTOnAStandaloneTerminalOpensAnotherJustBelowIt() throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let first = try standalone(store)
    store.newTerminalInSelectedTarget()
    let second = try standalone(store)
    store.selectedTargetID = first

    store.newTerminalInSelectedTarget()

    let third = try standalone(store)
    XCTAssertEqual(rows, [first, third, second])
    for sid in rows { XCTAssertEqual(tabCount(store, sid), 1, "\(sid)") }
    XCTAssertEqual(
      Set(store.orderedWorkroomTargets().map(\.target.id)), Set(rows.compactMap(\.targetID)))
  }

  /// ⌘T in a workroom is unchanged.
  func testCommandTInAWorkroomStillOpensATabThere() {
    let store = makeStore()
    store.selectedTargetID = workroom

    store.newTerminalInSelectedTarget()

    XCTAssertEqual(tabCount(store, workroom), 1)
    XCTAssertTrue(rows.isEmpty)
  }

  /// Value: protects=New Standalone Terminal from inside a workroom (story 2); fails_when=it opens
  /// a tab in the workroom, or closes it; why_new=#655; seam=AppStore; no_claim=the ⌥⌘T key itself
  /// (ShortcutRegistryTests, the UI test)
  func testNewStandaloneTerminalFromAWorkroomLeavesTheWorkroomBeside() throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.newTerminalInSelectedTarget()

    store.newStandaloneTerminal()

    let sid = try standalone(store)
    XCTAssertEqual(rows, [sid])
    XCTAssertEqual(tabCount(store, workroom), 1)
    XCTAssertEqual(
      Set(store.orderedWorkroomTargets().map(\.target.id)), [workroom.targetID, sid.targetID])
  }

  // MARK: Living beside the projects

  /// Value: protects=a reload of the project list never closes a terminal with no project;
  /// fails_when=selection or the row is dropped because no project lists it; why_new=#655;
  /// seam=AppStore over a fake CLI; no_claim=restore (below)
  func testAProjectReloadKeepsTheStandaloneTerminal() async throws {
    let fake = FakeWorkroomCLI(canonical: "/p", projects: projects.projects)
    let store = makeStore(cli: fake)
    await store.reload()
    store.newTerminalInSelectedTarget()
    let sid = try standalone(store)

    await store.reload()

    XCTAssertEqual(store.selectedTargetID, sid)
    XCTAssertEqual(rows, [sid])
    XCTAssertEqual(tabCount(store, sid), 1)
  }

  /// Every window lists every row, while the terminal itself is in the window that opened it.
  func testAnotherWindowListsTheRowByItsTerminalsName() throws {
    let holder = makeStore()
    let other = makeStore()
    holder.newTerminalInSelectedTarget()
    let sid = try standalone(holder)

    XCTAssertEqual(other.sidebarID(for: try XCTUnwrap(sid.targetID)), sid)
    XCTAssertEqual(other.target(for: sid)?.title, "Terminal 1")
    XCTAssertEqual(other.terminals.tabCount(forTargetID: try XCTUnwrap(sid.targetID)), 0)
  }

  /// Value: protects=a closed terminal leaves no dead row behind; fails_when=its row outlives its
  /// terminal; why_new=#655; seam=AppStore; no_claim=closing a window (#656)
  func testClosingItsTerminalDropsItsRow() throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let sid = try standalone(store)

    store.closeCurrentTerminalTab()

    XCTAssertEqual(tabCount(store, sid), 0)
    XCTAssertTrue(rows.isEmpty)
    XCTAssertNil(store.liveSelection(sid, in: projects.projects))
  }

  /// A move to another window keeps it: the terminal is still open there.
  func testMovingItToAnotherWindowKeepsItsRow() throws {
    let origin = makeStore()
    let destination = makeStore()
    origin.selectedTargetID = workroom
    origin.newTerminalInSelectedTarget()
    origin.newStandaloneTerminal()
    let sid = try standalone(origin)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(rows, [sid])
    XCTAssertEqual(tabCount(destination, sid), 1)
  }

  /// Moving its terminal into a workroom leaves no dead row behind.
  func testMovingItsTerminalIntoAWorkroomDropsItsRow() async throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.newTerminalInSelectedTarget()
    store.newStandaloneTerminal()
    let from = try XCTUnwrap(store.selectedTarget)
    let tab = try XCTUnwrap(store.terminals.tabs(for: from).first)

    await PaneMove.move(
      tab.id, of: from, source: store.terminals, notifications: store.notifications, to: store,
      into: try XCTUnwrap(workroom.targetID))

    XCTAssertTrue(rows.isEmpty)
    XCTAssertEqual(tabCount(store, workroom), 2)
  }

  /// A quit tears its terminal down, which must not read as the user closing it: the row comes
  /// back at the next launch.
  func testAQuitKeepsItsRow() async throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let sid = try standalone(store)
    WindowRegistry.shared.isTerminating = true
    defer { WindowRegistry.shared.isTerminating = false }

    await store.terminals.reapAll()

    XCTAssertEqual(rows, [sid])
  }

  /// The tab strip's + and a pane's New Terminal on a standalone terminal open another one.
  func testNewTerminalInAStandaloneTerminalOpensAnother() throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let first = try standalone(store)

    store.newTerminal(in: try XCTUnwrap(store.target(for: first)))

    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(tabCount(store, first), 1)
  }

  // MARK: Nothing project-shaped

  /// Value: protects=no inspector, VCS, pull-request or Run for a terminal with no project
  /// (stories 48–49); fails_when=any of them resolves a target for it; why_new=#655;
  /// seam=AppStore; no_claim=the menu items' rendering
  func testItHasNoInspectorVersionControlOrRun() throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let sid = try standalone(store)

    XCTAssertTrue(store.selectionHasTabs)
    XCTAssertNil(store.inspectorTargetID)
    XCTAssertNil(store.remoteTarget())
    XCTAssertFalse(store.vcsStatus.targetExists(sid))
    XCTAssertNil(AppStore.projectPath(of: sid))
    XCTAssertNil(store.project(forTargetID: try XCTUnwrap(sid.targetID)))
  }

  // MARK: Sessions

  /// Value: protects=a standalone terminal's session outlives the launch sweep (ADR 0077);
  /// fails_when=its tag doesn't resolve, so the sweep ends it; why_new=#655; seam=the sweep's
  /// resolver; no_claim=the daemon's own sweep
  func testTheLaunchSweepSparesAStandaloneTerminalsSession() throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.selectedTarget)
    guard case .standalone(let id) = target.id else { return XCTFail("\(target.id)") }

    XCTAssertEqual(target.sessionWorkroomKey, "standalone:\(id.uuidString)", "its stored name")
    XCTAssertTrue(store.sessionTagResolves(target.sessionWorkroomKey))
    XCTAssertTrue(store.sessionTagResolves("wr|/p|a"))
    XCTAssertFalse(store.sessionTagResolves(TargetID.standalone(UUID()).encoded), "a closed one")
    XCTAssertFalse(store.sessionTagResolves("standalone:not-a-uuid"))
  }
}
