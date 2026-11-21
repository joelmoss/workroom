import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Standalone terminals and terminal groups wherever a workroom can be reached or shown (#662,
/// ADR 0077): the quick switcher, ⌥Tab, back/forward history, the title-bar tab shortcuts, the Open
/// picker, and beside a workroom (⌥⌘O or a title-bar tab dropped on a pane's edge), which survives
/// a quit. Written in the style of `QuickSwitcherTests`, `OpenPickerModelTests`,
/// `NavigationHistoryTests` and `WorkroomSplitTests`.
@MainActor
final class StandaloneNavigationTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  private var directory: URL!

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("standalone-nav-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func configure(_ store: AppStore) {
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
  }

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: projects, terminalsSection: section)
    configure(store)
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1400, height: 800)
    return store
  }

  /// A window showing the workroom, a standalone terminal and a named group, with the workroom
  /// selected last so the others are "elsewhere".
  private func populated() throws -> (
    store: AppStore, standalone: SidebarID, group: SidebarID
  ) {
    let store = makeStore()
    store.newStandaloneTerminal()
    let standalone = try XCTUnwrap(store.selectedTargetID)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    store.openExisting(workroom)
    if let target = store.target(for: workroom),
      store.terminals.tabCount(forTargetID: target.id) == 0
    {
      store.terminals.addTab(for: target)
    }
    return (store, standalone, group)
  }

  // MARK: Title-bar tab shortcuts (⌥⌘1–9, next/previous)

  func testTheTitleBarTabShortcutsReachStandaloneTerminalsAndGroups() throws {
    let (store, standalone, group) = try populated()
    let tabs = store.displayedWorkroomTargets().map(\.sid)
    XCTAssertEqual(Set(tabs), [workroom, standalone, group], "each has a title-bar tab")

    for (index, sid) in tabs.enumerated() {
      XCTAssertTrue(store.focusWorkroomTab(at: index), "⌥⌘\(index + 1)")
      XCTAssertEqual(store.selectedTargetID, sid)
    }

    store.selectedTargetID = standalone
    let order = store.displayedWorkroomTargets().map(\.sid)
    let at = try XCTUnwrap(order.firstIndex(of: standalone))
    XCTAssertTrue(store.cycleWorkroomTab(forward: true))
    XCTAssertEqual(store.selectedTargetID, order[(at + 1) % order.count], "next")
    store.selectedTargetID = standalone
    XCTAssertTrue(store.cycleWorkroomTab(forward: false))
    XCTAssertEqual(store.selectedTargetID, order[(at + order.count - 1) % order.count], "previous")
  }

  // MARK: Quick switcher and ⌥Tab

  func testTheWorkroomSwitcherListsAndSwitchesToThem() throws {
    let (store, standalone, group) = try populated()
    let registry = WindowRegistry()
    registry.register(window: NSWindow(), store: store)
    let recency = SwitcherRecency()

    let slots = QuickSwitcher.workroomSlots(registry: registry, recency: recency)
    XCTAssertEqual(Set(slots.map(\.sid)), [workroom, standalone, group])

    for sid in [standalone, group] {
      let slot = try XCTUnwrap(slots.first { $0.sid == sid })
      XCTAssertTrue(QuickSwitcher.commit(slot, from: store), "\(sid)")
      XCTAssertEqual(store.selectedTargetID, sid)
    }
  }

  func testTheSwitcherLabelsThemByTheirTitles() throws {
    let (store, _, group) = try populated()
    XCTAssertEqual(store.target(for: group)?.title, "Ops")
    let slots = QuickSwitcher.workroomSlots(
      registry: {
        let registry = WindowRegistry()
        registry.register(window: NSWindow(), store: store)
        return registry
      }(), recency: SwitcherRecency())
    XCTAssertTrue(slots.contains { $0.target.title == "Ops" })
  }

  // MARK: Back / forward

  func testBackAndForwardStepThroughStandaloneTerminalsAndGroups() throws {
    let (store, standalone, group) = try populated()
    store.openExisting(standalone)
    store.openExisting(group)

    store.navigateBack()
    XCTAssertEqual(store.selectedTargetID, standalone, "back")
    store.navigateBack()
    XCTAssertEqual(store.selectedTargetID, workroom, "back again")
    store.navigateForward()
    XCTAssertEqual(store.selectedTargetID, standalone, "forward")
    store.navigateForward()
    XCTAssertEqual(store.selectedTargetID, group, "forward again")
  }

  // MARK: Open picker

  func testTheOpenPickerListsStandaloneTerminalsAndGroupsWithRootsAndWorkrooms() throws {
    let (_, standalone, group) = try populated()
    let rows = OpenPickerModel.targets(from: projects.projects, terminals: section)

    XCTAssertEqual(
      rows.map(\.sid), [standalone, group, workroom],
      "terminals first, as the sidebar lists them; the missing root is left out")
    let titles = rows.map(\.title)
    XCTAssertEqual(
      titles.first, section.target(for: standalone)?.title, "titled as the sidebar row is")
    XCTAssertEqual(titles[1], "Ops")
  }

  func testTheOpenPickerGroupsThemUnderTerminalsAndFiltersByName() throws {
    let (_, standalone, group) = try populated()
    let rows = OpenPickerModel.targets(from: projects.projects, terminals: section)

    let sections = OpenPickerModel.grouped(rows)
    XCTAssertEqual(sections.first?.projectName, "Terminals")
    XCTAssertEqual(sections.first?.rows.map(\.sid), [standalone, group])

    XCTAssertEqual(OpenPickerModel.filtered(rows, query: "ops").map(\.sid), [group])
    XCTAssertEqual(
      OpenPickerModel.filtered(rows, query: "terminals").map(\.sid), [standalone, group],
      "the heading text matches, as a project's name surfaces its workrooms")
  }

  func testAPickedTerminalOpensIt() throws {
    let (store, standalone, group) = try populated()
    let rows = OpenPickerModel.targets(from: projects.projects, terminals: section)
    for sid in [standalone, group] {
      let row = try XCTUnwrap(rows.first { $0.sid == sid })
      store.openExisting(row.sid)
      XCTAssertEqual(store.selectedTargetID, sid)
    }
  }

  // MARK: Beside a workroom

  func testOpenAsSplitShowsAStandaloneTerminalAndAGroupBesideAWorkroom() throws {
    let (store, standalone, group) = try populated()
    store.selectedTargetID = workroom

    XCTAssertTrue(store.canOpenAsSplit(standalone))
    store.openExistingAsSplit(standalone)
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [workroom, standalone], "⌥⌘O: to the right")
    XCTAssertEqual(store.selectedTargetID, standalone)

    store.openExistingAsSplit(group)
    XCTAssertEqual(
      Set(store.workroomSplits.first?.tabIDs ?? []), [workroom, standalone, group])
  }

  func testDroppingATitleBarTabOnAPaneEdgeSplitsIt() throws {
    let (store, standalone, group) = try populated()
    for (dropped, edge) in [(standalone, PaneEdge.left), (group, PaneEdge.bottom)] {
      store.workroomSplits = []
      XCTAssertTrue(
        store.insertWorkroomSplit(
          dropped, beside: workroom, edge: edge,
          destinationRect: store.workroomPaneRect(for: workroom)),
        "\(dropped) on \(edge)")
      XCTAssertEqual(Set(store.workroomSplits.first?.tabIDs ?? []), [workroom, dropped])
    }
  }

  func testAWorkroomCanBeDroppedBesideAStandaloneTerminalToo() throws {
    let (store, standalone, _) = try populated()
    XCTAssertTrue(store.insertWorkroomSplit(workroom, beside: standalone, edge: .right))
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [standalone, workroom])
  }

  func testAClosedStandaloneTerminalLeavesTheSplitAndItsRowGoes() throws {
    let (store, standalone, _) = try populated()
    store.openExistingAsSplit(standalone)
    XCTAssertNotNil(store.workroomSplits.first)

    section.remove(try XCTUnwrap(standalone.targetID))

    XCTAssertTrue(store.workroomSplits.compactMap { store.resolvedSplitLeaves(of: $0) }.isEmpty)
    XCTAssertFalse(store.isWorkroomSplitVisible, "a dead leaf is no split")
  }

  // MARK: Surviving a quit

  func testTheSplitSurvivesAQuit() throws {
    let sessionURL = directory.appendingPathComponent("session.json")
    let sectionURL = TerminalsSectionFile.beside(sessionURL: sessionURL)
    let before = TerminalsSection(file: TerminalsSectionFile(url: sectionURL))
    let window = AppStore(projectStore: projects, terminalsSection: before)
    configure(window)
    window.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1400, height: 800)
    window.openExisting(workroom)
    window.terminals.addTab(for: try XCTUnwrap(window.target(for: workroom)))
    window.newStandaloneTerminal()
    let standalone = try XCTUnwrap(window.selectedTargetID)
    let group = try XCTUnwrap(window.newTerminalGroup(named: "Ops"))
    window.openExisting(workroom)
    window.openExistingAsSplit(standalone)
    window.openExistingAsSplit(group)
    let tabs = Set(window.workroomSplits.first?.tabIDs ?? [])
    XCTAssertEqual(tabs, [workroom, standalone, group])
    SavedLayoutStore(url: sessionURL).writeSynchronously(
      SessionFile(savedAt: Date(), windows: [window.captureWindowSession()]))
    before.flush()

    let projectStore = ProjectStore()
    projectStore.projects = projects.projects
    projectStore.sessionCoordinator = SavedLayoutCoordinator(
      store: SavedLayoutStore(url: sessionURL), debounce: 0.05, ceiling: 0.2, capture: { [] })
    let after = TerminalsSection(file: TerminalsSectionFile(url: sectionURL))
    let relaunched = AppStore(projectStore: projectStore, terminalsSection: after)
    relaunched.isRestoreWindow = true
    relaunched.claimsSavedSession = true
    configure(relaunched)
    relaunched.claimSessionIfNeeded()
    relaunched.restorePersistedSessionIfPending(in: projects.projects)

    XCTAssertEqual(
      Set(relaunched.workroomSplits.first?.tabIDs ?? []), tabs, "the same three, side by side")
  }
}
