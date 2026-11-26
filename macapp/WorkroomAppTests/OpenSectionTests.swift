import AppKit
import Defaults
import WorkroomDomain
import XCTest

@testable import Workroom

/// The sidebar's Open section's rows (#819): the window's workroom tabs as the title bar shows
/// them, each with its tabs as its strip shows them, plus the section's own fold state. Written in
/// the style of `StandaloneNavigationTests`.
@MainActor
final class OpenSectionTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let one = SidebarID.workroom(project: "/p", name: "one")
  private let two = SidebarID.workroom(project: "/p", name: "two")
  private var savedSelection: String?
  private var savedOrder: [String] = []

  override func setUp() async throws {
    try await super.setUp()
    // A store with no active window persists its selection and tab order.
    savedSelection = Defaults[.sidebarSelection]
    savedOrder = Defaults[.workroomTabOrder]
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: ["one", "two"].map {
          Workroom(name: $0, path: "/p/\($0)", vcsName: "workroom/\($0)", warnings: [])
        })
    ]
  }

  override func tearDown() async throws {
    Defaults[.sidebarSelection] = savedSelection
    Defaults[.workroomTabOrder] = savedOrder
    try await super.tearDown()
  }

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
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1400, height: 800)
    return store
  }

  /// Opens `sid` with one terminal and selects it.
  @discardableResult
  private func open(_ sid: SidebarID, in store: AppStore) throws -> TerminalTarget {
    store.openExisting(sid)
    let target = try XCTUnwrap(store.target(for: sid))
    if store.terminals.tabCount(forTargetID: target.id) == 0 {
      store.terminals.addTab(for: target)
    }
    return target
  }

  private func row(_ sid: SidebarID, in store: AppStore) throws -> OpenSectionRow {
    try XCTUnwrap(store.openSectionRows().first { $0.sid == sid }, "\(sid) has a row")
  }

  // MARK: Workroom rows mirror the title bar

  func testTheRowsAreTheTitleBarsWorkroomTabsInItsOrder() throws {
    let store = makeStore()
    try open(one, in: store)
    store.newStandaloneTerminal()
    let standalone = try XCTUnwrap(store.selectedTargetID)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    try open(two, in: store)

    let rows = store.openSectionRows().map(\.sid)
    XCTAssertEqual(Set(rows), [one, two, standalone, group])
    XCTAssertEqual(rows, store.displayedWorkroomTargets().map(\.sid))
  }

  func testAReorderInEitherPlaceReordersTheOther() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(two, in: store)
    XCTAssertEqual(store.openSectionRows().map(\.sid), [one, two])

    // From the section: the title bar follows.
    XCTAssertTrue(store.moveWorkroomTab(two, toIndex: 0))
    XCTAssertEqual(store.displayedWorkroomTargets().map(\.sid), [two, one])

    // From the title bar's order: the section follows.
    store.workroomTabOrder = [one.targetID!, two.targetID!]
    XCTAssertEqual(store.openSectionRows().map(\.sid), [one, two])
  }

  func testAWorkroomTabThatClosesLeavesTheSection() throws {
    let store = makeStore()
    let target = try open(one, in: store)
    try open(two, in: store)

    for tab in store.terminals.allTabs(for: target) {
      store.terminals.closeTab(tab.id, for: target)
    }

    XCTAssertEqual(store.openSectionRows().map(\.sid), [two])
  }

  func testAGroupLeavesWhenItsLastTabCloses() throws {
    let store = makeStore()
    try open(one, in: store)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    XCTAssertNotNil(try? row(group, in: store), "a group with a tab has a row")
    let target = try XCTUnwrap(store.target(for: group))

    for tab in store.terminals.allTabs(for: target) {
      store.terminals.closeTab(tab.id, for: target)
    }

    XCTAssertFalse(store.openSectionRows().contains { $0.sid == group })
    XCTAssertNotNil(section.group(group.targetID!), "the group itself stays")
  }

  func testAWorkroomBeingCreatedHasARowWithNothingToClose() throws {
    let store = makeStore()
    let run = CreationRun(
      project: projects.projects[0], kind: nil, splitAnchor: nil, previousSelection: nil)
    store.lifecycle.register(run)

    let creation = SidebarID.creation(project: "/p", id: run.id)
    XCTAssertEqual(store.openSectionRows().map(\.sid), [creation])
    XCTAssertNil(try row(creation, in: store).model.presentation.closeName)
  }

  // MARK: Tab rows mirror the strip

  func testTabRowsAreTheStripsTabsInItsOrderOfEveryKind() throws {
    let store = makeStore()
    let target = try open(one, in: store)
    store.terminals.addTab(for: target)
    let diff = store.terminals.openDiffPersistent(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: false),
      for: target)

    let strip = store.terminals.tabs(for: target).map(\.id)
    XCTAssertEqual(strip.count, 3)
    XCTAssertEqual(try row(one, in: store).tabs.map(\.id), strip)
    XCTAssertTrue(try row(one, in: store).tabs.contains { $0.id == diff && $0.tab.terminal == nil })

    // A reorder from the section reorders the strip.
    store.moveOpenTab(diff, toIndex: 0, in: one)
    XCTAssertEqual(store.terminals.tabs(for: target).first?.id, diff)
    XCTAssertEqual(try row(one, in: store).tabs.first?.id, diff)
  }

  func testAStandaloneTerminalsOneTerminalIsItsRow() throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    let standalone = try XCTUnwrap(store.selectedTargetID)

    XCTAssertEqual(try row(standalone, in: store).tabs.count, 0, "it shows no strip either")
  }

  // MARK: Selected, focused and visible in a split

  func testTheSelectedRowAndTheFocusedTab() throws {
    let store = makeStore()
    try open(one, in: store)
    let second = try open(two, in: store)
    store.terminals.addTab(for: second)
    let focused = try XCTUnwrap(store.terminals.activeTab(for: second)?.id)

    let selected = try row(two, in: store)
    XCTAssertTrue(selected.isSelected)
    XCTAssertEqual(selected.tabs.filter(\.isFocused).map(\.id), [focused])

    let other = try row(one, in: store)
    XCTAssertFalse(other.isSelected)
    XCTAssertFalse(other.isVisibleInSplit)
    XCTAssertTrue(other.tabs.allSatisfy { !$0.isFocused && !$0.isVisibleInSplit })
  }

  func testTabsShownInOtherPanesOfASplitAreVisibleInSplit() throws {
    let store = makeStore()
    let first = try open(one, in: store)
    try open(two, in: store)
    XCTAssertTrue(store.insertWorkroomSplit(one, beside: two, edge: .right))
    XCTAssertEqual(store.selectedTargetID, one)
    // `two` beside it, and a terminal split inside `one`.
    store.terminals.splitFocusedPane(for: first, orientation: .horizontal)
    let focused = try XCTUnwrap(store.terminals.activeTab(for: first)?.id)

    let selected = try row(one, in: store)
    XCTAssertEqual(selected.tabs.count, 2)
    XCTAssertEqual(selected.tabs.filter(\.isFocused).map(\.id), [focused])
    XCTAssertEqual(selected.tabs.filter(\.isVisibleInSplit).count, 1, "the other pane")

    let beside = try row(two, in: store)
    XCTAssertTrue(beside.isVisibleInSplit)
    XCTAssertEqual(beside.tabs.filter(\.isVisibleInSplit).count, 1, "its pane is on screen")
  }

  // MARK: Fold state

  func testOnlyTheSelectedRowIsUnfoldedByDefault() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(two, in: store)

    XCTAssertFalse(try row(two, in: store).isFolded)
    XCTAssertTrue(try row(one, in: store).isFolded)

    store.selectWorkroomTab(one)
    XCTAssertFalse(try row(one, in: store).isFolded, "selecting a folded row unfolds it")
    XCTAssertTrue(try row(two, in: store).isFolded)
  }

  func testAFoldChoiceStays() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(two, in: store)

    store.toggleOpenRowFold(one)
    XCTAssertFalse(try row(one, in: store).isFolded)
    store.selectWorkroomTab(one)
    store.selectWorkroomTab(two)
    XCTAssertFalse(try row(one, in: store).isFolded, "unfolded by hand, it stays unfolded")
  }

  func testTheSelectedRowFoldsUntilItIsNextSelected() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(two, in: store)

    XCTAssertTrue(try row(two, in: store).canFold, "its chevron stays live")
    store.setOpenRow(two, folded: true)
    XCTAssertTrue(try row(two, in: store).isFolded, "the selected row folds")

    store.selectWorkroomTab(one)
    XCTAssertTrue(try row(two, in: store).isFolded)
    store.selectWorkroomTab(two)
    XCTAssertFalse(try row(two, in: store).isFolded, "selecting it again unfolds it")
  }

  func testEachWindowHasItsOwnRowsAndFolds() throws {
    let first = makeStore()
    try open(one, in: first)
    try open(two, in: first)
    first.toggleOpenRowFold(one)
    let second = makeStore()
    try open(two, in: second)

    XCTAssertEqual(second.openSectionRows().map(\.sid), [two])
    XCTAssertTrue(second.unfoldedOpenTargets.isEmpty)
  }

  func testFoldsAreSavedWithTheWindow() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(two, in: store)
    store.toggleOpenRowFold(one)

    XCTAssertEqual(store.captureWindowSession().unfoldedOpenTargets, [one.targetID!.encoded])
  }

  /// Value: protects=the selected row folded by hand is saved with the window, so a relaunch
  /// brings it back folded (#819 story 70); fails_when=the capture leaves it out, or keeps it once
  /// the selection moves on (selecting unfolds); seam=AppStore.captureWindowSession
  func testTheSelectedRowsFoldIsSavedWithTheWindow() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(two, in: store)
    XCTAssertNil(store.captureWindowSession().foldedSelectedTarget, "nothing folded yet")

    store.setOpenRow(two, folded: true)
    XCTAssertEqual(store.captureWindowSession().foldedSelectedTarget, two.targetID?.encoded)

    store.selectWorkroomTab(one)
    XCTAssertNil(store.captureWindowSession().foldedSelectedTarget, "selecting another unfolds")
  }

  // MARK: The rows' menus

  /// Value: protects=a group's Open row menu offers Expand or Collapse as its row stands, and
  /// a workroom's or a standalone terminal's offers none (#819 review, owner's call);
  /// fails_when=the item is missing, worded against the row's fold, or on another kind of row;
  /// seam=WorkroomMenuModel(store:) + AppStore.toggleOpenRowFold
  func testAGroupsOpenRowMenuFoldsItsRow() throws {
    let store = makeStore()
    try open(one, in: store)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    func menu(_ sid: SidebarID) -> [WorkroomMenuModel.Entry] {
      WorkroomMenuModel(
        store: store, lifecycle: store.lifecycle, sid: sid, target: store.target(for: sid),
        closeName: "x", removableFromSplit: false
      ).entries(for: .openRow)
    }

    XCTAssertEqual(menu(group).first, .fold(SidebarFoldItem(expanded: true)), "selected: unfolded")
    store.toggleOpenRowFold(group)
    XCTAssertTrue(try row(group, in: store).isFolded)
    XCTAssertEqual(menu(group).first, .fold(SidebarFoldItem(expanded: false)))

    store.newStandaloneTerminal()
    let standalone = try XCTUnwrap(store.selectedTargetID)
    for sid in [one, standalone] {
      XCTAssertFalse(
        menu(sid).contains { if case .fold = $0 { true } else { false } }, "\(sid) has none")
    }
  }

  // MARK: The pane

  /// The List lists each workroom tab's row and, unfolded, its tabs' rows: a folded row's tabs
  /// are left out, and nothing open lists no row (the view shows its New Terminal link).
  func testTheListListsTheRowsItShows() throws {
    let store = makeStore()
    XCTAssertTrue(SidebarOpenList.items(of: store.openSectionRows()).isEmpty, "nothing open")
    try open(one, in: store)
    let target = try XCTUnwrap(store.target(for: one))
    store.terminals.addTab(for: target)
    try open(two, in: store)

    XCTAssertEqual(
      SidebarOpenList.items(of: store.openSectionRows()).count, 3, "one folded; two and its tab")
    store.setOpenRow(one, folded: false)
    XCTAssertEqual(
      SidebarOpenList.items(of: store.openSectionRows()).count, 5, "one's two tabs too")
  }

  /// The selection scrolls into view: its focused tab's row, or its own row once folded.
  func testTheSelectedRowIsWhatScrollsIntoView() throws {
    let store = makeStore()
    try open(one, in: store)
    let target = try XCTUnwrap(store.target(for: one))
    store.terminals.addTab(for: target)
    let focused = try XCTUnwrap(store.terminals.activeTab(for: target)?.id)

    XCTAssertEqual(
      SidebarOpenList.scrollTarget(of: store.openSectionRows()), .tab(focused, in: one))
    store.setOpenRow(one, folded: true)
    XCTAssertEqual(SidebarOpenList.scrollTarget(of: store.openSectionRows()), .workroom(one))
  }

  // MARK: Actions

  func testSelectingATabRowSelectsItsWorkroomAndTheTab() throws {
    let store = makeStore()
    let first = try open(one, in: store)
    store.terminals.addTab(for: first)
    let tab = try XCTUnwrap(store.terminals.tabs(for: first).first?.id)
    try open(two, in: store)

    store.selectOpenTab(tab, in: one)

    XCTAssertEqual(store.selectedTargetID, one)
    XCTAssertTrue(try row(one, in: store).tabs.first { $0.id == tab }?.isFocused == true)
  }
}
