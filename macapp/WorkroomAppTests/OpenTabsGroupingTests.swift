import AppKit
import Defaults
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Open Tabs view's groupings: Project, Project › Workroom, Workroom and None
/// (`AppStore.openTabsLayout`), the list each lays out, and its fold state.
@MainActor
final class OpenTabsGroupingTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let one = SidebarID.workroom(project: "/p", name: "one")
  private let two = SidebarID.workroom(project: "/p", name: "two")
  private let root = SidebarID.root(project: "/p")
  private let other = SidebarID.workroom(project: "/q", name: "other")
  private var savedSelection: String?
  private var savedOrder: [String] = []

  override func setUp() async throws {
    try await super.setUp()
    savedSelection = Defaults[.sidebarSelection]
    savedOrder = Defaults[.workroomTabOrder]
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: ["one", "two"].map {
          Workroom(name: $0, path: "/p/\($0)", vcsName: "workroom/\($0)", warnings: [])
        }),
      Project(
        path: "/q", vcs: "git",
        workrooms: [Workroom(name: "other", path: "/q/other", vcsName: "w/other", warnings: [])]),
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

  /// Opens `sid` with `tabs` terminals and selects it. Returns its tabs.
  @discardableResult
  private func open(_ sid: SidebarID, tabs: Int = 1, in store: AppStore) throws -> [TerminalTab.ID]
  {
    store.openExisting(sid)
    let target = try XCTUnwrap(store.target(for: sid))
    while store.terminals.tabCount(forTargetID: target.id) < tabs {
      store.terminals.addTab(for: target)
    }
    // A shell each, so its terminals can move.
    for tab in store.terminals.tabs(for: target) {
      store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    }
    return store.terminals.tabs(for: target).map(\.id)
  }

  /// A lift of `dragged` in `grouping`'s list, as the list's drag makes it.
  private func lift(
    _ dragged: OpenTabsItem, in grouping: OpenTabsGrouping, store: AppStore
  ) throws -> OpenRowReflow {
    let layout = store.openTabsLayout(grouping: grouping)
    var leaves = false
    var joinable: Set<SidebarID> = []
    if case .tab(let tab, let owner) = dragged {
      leaves = store.canMoveOpenTabToStandalone(tab, in: owner)
      joinable = OpenRowLift.joinable(tab, of: owner, rows: layout.rows, store: store)
    }
    return try XCTUnwrap(
      OpenRowReflow(
        items: SidebarOpenList.items(of: layout), dragged: dragged, leavesWorkroom: leaves,
        joinable: joinable,
        shape: SidebarOpenList.shape(
          of: layout, titleBar: store.displayedWorkroomTargets().map(\.sid))))
  }

  private let pitch: CGFloat = 30

  /// The pointer at `fraction` down the row `reflow` shows at `row`.
  private func point(_ reflow: inout OpenRowReflow, at row: OpenTabsItem, _ fraction: CGFloat)
    throws
  {
    let slot = try XCTUnwrap(reflow.order.firstIndex(of: row), "\(row) is shown")
    reflow.pointer(at: (CGFloat(slot) + fraction) * pitch, pitch: pitch)
  }

  private func settle() async {
    for _ in 0..<50 { await Task.yield() }
    await section.regroupsSettled()
  }

  /// Puts the title bar's tabs in `sids`' order, as a drag of its tabs would.
  private func order(_ sids: [SidebarID], in store: AppStore) {
    store.workroomTabOrder = sids.compactMap(\.targetID)
    XCTAssertEqual(store.displayedWorkroomTargets().map(\.sid), sids, "the title bar's order")
  }

  private func items(_ grouping: OpenTabsGrouping, in store: AppStore) -> [OpenTabsItem] {
    SidebarOpenList.items(of: store.openTabsLayout(grouping: grouping))
  }

  // MARK: Project › Workroom

  /// Value: protects=Project › Workroom nests each project's workrooms under one header, placed
  /// where its first workroom is in the title bar, with a project's workrooms together although
  /// the title bar has them apart (owner, 2026-11-27); fails_when=a project's workrooms split, the
  /// header lands at its last workroom, or a standalone terminal goes under a project;
  /// seam=AppStore.openTabsLayout.
  func testProjectWorkroomNestsWorkroomsUnderTheirProjectInTitleBarOrder() throws {
    let store = makeStore()
    let oneTabs = try open(one, tabs: 2, in: store)
    let otherTabs = try open(other, in: store)
    store.newStandaloneTerminal()
    let standalone = try XCTUnwrap(store.selectedTargetID)
    let twoTabs = try open(two, tabs: 2, in: store)
    order([one, other, standalone, two], in: store)
    // One unfolded by hand, two selected: both show their tabs. Other is folded.
    store.setOpenRow(one, folded: false)

    XCTAssertEqual(
      items(.projectWorkroom, in: store),
      [
        .project("/p"),
        .workroom(one), .tab(oneTabs[0], in: one), .tab(oneTabs[1], in: one),
        .workroom(two), .tab(twoTabs[0], in: two), .tab(twoTabs[1], in: two),
        .project("/q"),
        .workroom(other),
        .workroom(standalone),
      ])
    _ = otherTabs
  }

  /// Value: protects=a project root is its project's first workroom in the project groupings,
  /// wherever its tab is in the title bar (owner, 2026-11-27); fails_when=it keeps its title-bar
  /// place under its project; seam=AppStore.openTabsLayout.
  func testAProjectRootComesFirstInItsProject() throws {
    let store = makeStore()
    let oneTabs = try open(one, in: store)
    let rootTabs = try open(root, in: store)
    order([one, root], in: store)

    XCTAssertEqual(
      items(.projectWorkroom, in: store),
      [.project("/p"), .workroom(root), .tab(rootTabs[0], in: root), .workroom(one)])
    XCTAssertEqual(
      items(.project, in: store),
      [.project("/p"), .tab(rootTabs[0], in: root), .tab(oneTabs[0], in: one)])
  }

  // MARK: Project

  /// Value: protects=Project lists every tab of a project's workrooms under its header, whatever
  /// each workroom's own fold, each naming its workroom, while a terminal group keeps its own
  /// foldable row (owner, 2026-11-27); fails_when=a folded workroom's tabs vanish, a tab shows no
  /// workroom, or a group's tabs lose their row; seam=AppStore.openTabsLayout.
  func testProjectListsEveryTabUnderItsProjectNamingItsWorkroom() throws {
    let store = makeStore()
    let oneTabs = try open(one, tabs: 2, in: store)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    let groupTarget = try XCTUnwrap(store.target(for: group))
    let twoTabs = try open(two, in: store)
    store.setOpenRow(group, folded: false)
    order([one, two, group], in: store)
    XCTAssertTrue(store.isOpenRowFolded(one), "one's own fold, which Project doesn't show")

    let layout = store.openTabsLayout(grouping: .project)
    let groupTab = try XCTUnwrap(store.terminals.tabs(for: groupTarget).first?.id)
    XCTAssertEqual(
      SidebarOpenList.items(of: layout),
      [
        .project("/p"), .tab(oneTabs[0], in: one), .tab(oneTabs[1], in: one),
        .tab(twoTabs[0], in: two),
        .workroom(group), .tab(groupTab, in: group),
      ])
    let contexts = layout.rows.flatMap(\.tabs).map(\.model.context)
    XCTAssertEqual(
      contexts,
      [
        OpenTabsTabContext(project: nil, name: .text("one")),
        OpenTabsTabContext(project: nil, name: .text("one")),
        OpenTabsTabContext(project: nil, name: .text("two")),
        nil,
      ])
  }

  // MARK: None

  /// Value: protects=None lists every tab in title-bar then strip order, each naming its project
  /// and workroom, or its group, with a standalone terminal as its own one row (owner,
  /// 2026-11-27); fails_when=a header or workroom row shows, a folded row hides its tabs, or a
  /// tab names nothing; seam=AppStore.openTabsLayout.
  func testNoneListsEveryTabFlatNamingWhereItLives() throws {
    let store = makeStore()
    let oneTabs = try open(one, tabs: 2, in: store)
    store.newStandaloneTerminal()
    let standalone = try XCTUnwrap(store.selectedTargetID)
    let otherTabs = try open(other, in: store)
    let rootTabs = try open(root, in: store)
    order([one, standalone, other, root], in: store)

    let layout = store.openTabsLayout(grouping: .ungrouped)
    XCTAssertEqual(
      SidebarOpenList.items(of: layout),
      [
        .tab(oneTabs[0], in: one), .tab(oneTabs[1], in: one), .workroom(standalone),
        .tab(otherTabs[0], in: other), .tab(rootTabs[0], in: root),
      ])
    XCTAssertEqual(
      layout.rows.flatMap(\.tabs).map(\.model.context),
      [
        OpenTabsTabContext(project: "p", name: .text("one")),
        OpenTabsTabContext(project: "p", name: .text("one")),
        OpenTabsTabContext(project: "q", name: .text("other")),
        OpenTabsTabContext(project: "p", name: .root(projectPath: "/p")),
      ])
    XCTAssertTrue(
      SidebarOpenList.entries(of: layout).allSatisfy { $0.depth == 0 }, "nothing is indented")
  }

  /// Value: protects=Workroom lays the list out as it was before groupings, so the default
  /// changes nothing (owner, 2026-11-27); fails_when=a header or a tab's workroom name shows;
  /// seam=AppStore.openTabsLayout.
  func testWorkroomIsTheListAsItWas() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(other, tabs: 2, in: store)

    let layout = store.openTabsLayout(grouping: .workroom)
    XCTAssertEqual(
      SidebarOpenList.items(of: layout), SidebarOpenList.items(of: store.openTabsRows()))
    XCTAssertTrue(layout.rows.flatMap(\.tabs).allSatisfy { $0.model.context == nil })
  }

  // MARK: Folds

  /// Value: protects=a project's group starts unfolded, folds to its header alone, and unfolds
  /// when one of its targets is selected (owner, 2026-11-27); fails_when=a new project starts
  /// folded, a folded one leaks rows, or selecting leaves it folded; seam=AppStore.
  func testAProjectGroupFoldsAndSelectingUnfoldsIt() throws {
    let store = makeStore()
    try open(one, in: store)
    let otherTabs = try open(other, in: store)

    XCTAssertEqual(
      items(.project, in: store).filter { $0 == .tab(otherTabs[0], in: other) }.count, 1,
      "unfolded at first")

    store.toggleOpenProjectFold("/q")
    XCTAssertEqual(
      items(.project, in: store).filter { $0.owner == other || $0 == .project("/q") },
      [.project("/q")], "folded, its header alone")

    store.selectWorkroomTab(one)
    store.selectWorkroomTab(other)
    XCTAssertFalse(store.foldedOpenProjects.contains("/q"), "selecting one of its targets")
  }

  /// Value: protects=Collapse All folds every project and every target that folds, the selected
  /// one included, then Expand All unfolds them, and the button says which it will do
  /// (owner, 2026-11-27); fails_when=a level is missed, the selected row stays open, or the
  /// button offers the wrong action; seam=AppStore.openTabsFoldAll / foldAllOpenRows.
  func testCollapseAllThenExpandAllAtEveryLevel() throws {
    let store = makeStore()
    try open(one, tabs: 2, in: store)
    try open(other, tabs: 2, in: store)
    let grouping = OpenTabsGrouping.projectWorkroom
    XCTAssertEqual(store.openTabsFoldAll(grouping: grouping), .collapse, "other is unfolded")

    store.foldAllOpenRows(.collapse, grouping: grouping)
    XCTAssertEqual(items(grouping, in: store), [.project("/p"), .project("/q")])
    XCTAssertTrue(store.isOpenRowFolded(other), "the selected row too")
    XCTAssertEqual(store.openTabsFoldAll(grouping: grouping), .expand)

    store.foldAllOpenRows(.expand, grouping: grouping)
    XCTAssertEqual(items(grouping, in: store).count, 8, "two headers, two rows, four tabs")
    XCTAssertEqual(store.openTabsFoldAll(grouping: grouping), .collapse)
  }

  /// Value: protects=the button is disabled with nothing to fold, and None offers it nothing
  /// (owner, 2026-11-27); fails_when=it offers a fold that does nothing; seam=AppStore.
  func testNothingToFoldOffersNoFoldAll() throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    XCTAssertNil(
      store.openTabsFoldAll(grouping: .workroom),
      "a standalone terminal alone: \(store.displayedWorkroomTargets().map(\.sid))")
    try open(one, tabs: 2, in: store)
    XCTAssertNil(store.openTabsFoldAll(grouping: .ungrouped))
    XCTAssertNotNil(store.openTabsFoldAll(grouping: .workroom))
  }

  /// Value: protects=a folded project's group comes back folded after a relaunch (owner,
  /// 2026-11-27); fails_when=it is lost; seam=SavedLayout WindowSession round trip.
  func testFoldedProjectsAreSavedWithTheWindow() throws {
    let store = makeStore()
    try open(one, in: store)
    store.foldedOpenProjects = ["/q"]
    let session = store.captureWindowSession()
    XCTAssertEqual(session.foldedOpenProjects, ["/q"])

    let data = try JSONEncoder().encode(SessionFile(savedAt: Date(), windows: [session]))
    let decoded = try JSONDecoder().decode(SessionFile.self, from: data).sanitized().file
    XCTAssertEqual(decoded.windows.first?.foldedOpenProjects, ["/q"])
  }

  // MARK: The Projects view's Expand All / Collapse All

  /// Value: protects=the Projects view's Collapse All collapses every project and every workroom's
  /// terminals, then Expand All opens them all, the button saying which it will do (owner,
  /// 2026-11-27); fails_when=a project or a terminal subtree is missed, or the button offers the
  /// wrong action; seam=AppStore.projectsFoldAll / foldAllProjects.
  func testProjectsCollapseAllThenExpandAll() throws {
    let store = makeStore()
    let saved = store.collapsedProjects
    defer { store.collapsedProjects = saved }
    try open(one, tabs: 2, in: store)
    store.collapsedProjects = ["/q"]
    XCTAssertEqual(store.projectsFoldAll(), .collapse, "/p is expanded")

    store.foldAllProjects(.collapse)
    XCTAssertEqual(store.collapsedProjects, ["/p", "/q"])
    XCTAssertTrue(store.expandedTerminalTargets.isEmpty)
    XCTAssertEqual(store.projectsFoldAll(), .expand)

    store.foldAllProjects(.expand)
    XCTAssertTrue(store.collapsedProjects.isEmpty)
    let target = try XCTUnwrap(store.target(for: one))
    XCTAssertEqual(store.expandedTerminalTargets, [target.id], "one's two terminals show")
    XCTAssertEqual(store.projectsFoldAll(), .collapse)
  }

  // MARK: Drags land where their gap shows

  /// Value: protects=a project header dragged above another moves its project's title-bar tabs as
  /// one run, so the list lands it where its gap showed (owner, 2026-11-27); fails_when=the list
  /// and the title bar disagree, or only one of its workrooms moves; seam=OpenRowReflow +
  /// AppStore.moveWorkroomTabs.
  func testADraggedProjectHeaderLandsWhereItsGapShowed() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(other, in: store)
    try open(two, in: store)
    order([one, other, two], in: store)
    var reflow = try lift(.project("/q"), in: .projectWorkroom, store: store)

    try point(&reflow, at: .project("/p"), 0.3)
    XCTAssertEqual(reflow.order.first, .project("/q"), "the gap above /p")
    let move = try XCTUnwrap(reflow.titleBarMove)
    XCTAssertTrue(store.moveWorkroomTabs(move.moving, to: move.place))

    XCTAssertEqual(store.displayedWorkroomTargets().map(\.sid), [other, one, two])
    XCTAssertEqual(
      items(.projectWorkroom, in: store).filter { if case .project = $0 { true } else { false } },
      [.project("/q"), .project("/p")])
  }

  /// Value: protects=a workroom row under its project's header reorders among its project's
  /// workrooms, its project's title-bar tabs reordered in the slots they hold (owner, 2026-11-27);
  /// fails_when=it leaves its project or lands a row off; seam=OpenRowReflow +
  /// AppStore.moveWorkroomTabs.
  func testANestedWorkroomRowReordersAmongItsProjectsWorkrooms() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(other, in: store)
    try open(two, in: store)
    order([one, other, two], in: store)
    var reflow = try lift(.workroom(two), in: .projectWorkroom, store: store)

    try point(&reflow, at: .workroom(one), 0.3)
    let move = try XCTUnwrap(reflow.titleBarMove)
    XCTAssertEqual(move.moving, [two, one])
    XCTAssertEqual(move.place, .inTheirSlots)
    XCTAssertTrue(store.moveWorkroomTabs(move.moving, to: move.place))

    XCTAssertEqual(store.displayedWorkroomTargets().map(\.sid), [two, other, one])
    let rows = items(.projectWorkroom, in: store).filter(\.isWorkroom)
    XCTAssertEqual(rows, [.workroom(two), .workroom(one), .workroom(other)])
  }

  /// Value: protects=reordering a project's first workroom under its header keeps the header where
  /// it was, the list landing as its gap showed, although another project's tab is between its
  /// workrooms in the title bar (Codex review, PR #837); fails_when=the header moves below the
  /// other project's; seam=OpenRowReflow + AppStore.moveWorkroomTabs.
  func testANestedReorderKeepsItsProjectInPlace() throws {
    let store = makeStore()
    try open(one, in: store)
    try open(other, in: store)
    try open(two, in: store)
    order([one, other, two], in: store)
    var reflow = try lift(.workroom(one), in: .projectWorkroom, store: store)

    try point(&reflow, at: .workroom(two), 0.7)
    let shown = reflow.order
    let move = try XCTUnwrap(reflow.titleBarMove)
    XCTAssertTrue(store.moveWorkroomTabs(move.moving, to: move.place))

    XCTAssertEqual(store.displayedWorkroomTargets().map(\.sid), [two, other, one])
    XCTAssertEqual(items(.projectWorkroom, in: store), shown, "the list as the gap showed it")
  }

  /// Value: protects=in Project › Workroom a tab dragged over a folded workroom's row under its
  /// header is onto that row, so let go there it joins that workroom, as grouped by workroom
  /// (Codex review, PR #837); fails_when=the row takes no drop and the drag cancels;
  /// seam=OpenRowReflow.liftedY.
  func testATabOverAFoldedNestedWorkroomIsOntoIt() throws {
    let store = makeStore()
    try open(two, tabs: 2, in: store)
    let oneTabs = try open(one, tabs: 2, in: store)
    order([one, two], in: store)
    let reflow = try lift(.tab(oneTabs[0], in: one), in: .projectWorkroom, store: store)
    XCTAssertFalse(reflow.order.contains { $0.isTab && $0.owner == two }, "two is folded")

    let slot = try XCTUnwrap(reflow.order.firstIndex(of: .workroom(two)))
    let was = try XCTUnwrap(reflow.measured.firstIndex(of: .workroom(two)))
    let y = (CGFloat(slot) + 0.5) * pitch
    XCTAssertEqual(
      reflow.liftedY(for: y, pitch: pitch), (CGFloat(was) + 0.5) * pitch,
      "its middle is onto its row as the drag measured it")
  }

  /// Value: protects=in Project a tab let go over another workroom's tab's lower half joins that
  /// workroom just after it, where its gap showed (owner, 2026-11-27, Q24); fails_when=it lands
  /// elsewhere or becomes standalone; seam=OpenRowReflow + AppStore.moveOpenTab.
  func testInProjectATabJoinsTheWorkroomOfTheTabItIsBeside() async throws {
    let store = makeStore()
    let oneTabs = try open(one, tabs: 2, in: store)
    let twoTabs = try open(two, tabs: 2, in: store)
    order([one, two], in: store)
    var reflow = try lift(.tab(oneTabs[0], in: one), in: .project, store: store)

    try point(&reflow, at: .tab(twoTabs[0], in: two), 0.7)
    let shown = reflow.order
    let place = try XCTUnwrap(reflow.joinPlace)
    XCTAssertEqual(place.into, two)
    XCTAssertEqual(place.before, twoTabs[1])
    let moved = await store.moveOpenTab(
      oneTabs[0], of: one, into: place.into, before: place.before)
    await settle()
    XCTAssertTrue(moved)

    XCTAssertEqual(
      items(.project, in: store),
      shown.map { $0 == .tab(oneTabs[0], in: one) ? .tab(oneTabs[0], in: two) : $0 },
      "the list as the gap showed it")
  }

  /// Value: protects=in Project a tab let go on a project header's upper half becomes a standalone
  /// terminal between the two projects, where its gap showed (owner, 2026-11-27, Q24);
  /// fails_when=it joins a workroom or lands inside a project; seam=OpenRowReflow +
  /// AppStore.moveOpenTabToStandalone.
  func testInProjectATabAboveAHeaderBecomesStandaloneBetweenProjects() async throws {
    let store = makeStore()
    let oneTabs = try open(one, tabs: 2, in: store)
    try open(other, in: store)
    order([one, other], in: store)
    var reflow = try lift(.tab(oneTabs[0], in: one), in: .project, store: store)

    try point(&reflow, at: .project("/q"), 0.3)
    let gap = try XCTUnwrap(reflow.slot)
    let place = try XCTUnwrap(reflow.standalonePlace)
    XCTAssertEqual(place.after, one)
    XCTAssertEqual(place.before, other)
    let moved = await store.moveOpenTabToStandalone(
      oneTabs[0], in: one, after: place.after, before: place.before)
    await settle()
    XCTAssertTrue(moved)

    let landed = items(.project, in: store)
    XCTAssertEqual(landed.count, reflow.order.count)
    guard case .workroom(let sid) = landed[gap], sid.isStandaloneTerminal else {
      return XCTFail("a standalone terminal's row where the gap was: \(landed)")
    }
  }

  /// Value: protects=in None a tab let go over another workroom's tab's upper half joins it just
  /// before that tab (owner, 2026-11-27, Q24); fails_when=it reorders in place or lands after;
  /// seam=OpenRowReflow + AppStore.moveOpenTab.
  func testInNoneATabJoinsBeforeTheTabItIsAbove() async throws {
    let store = makeStore()
    let oneTabs = try open(one, tabs: 2, in: store)
    let otherTabs = try open(other, in: store)
    order([one, other], in: store)
    var reflow = try lift(.tab(oneTabs[1], in: one), in: .ungrouped, store: store)

    try point(&reflow, at: .tab(otherTabs[0], in: other), 0.3)
    let shown = reflow.order
    let place = try XCTUnwrap(reflow.joinPlace)
    XCTAssertEqual(place.into, other)
    XCTAssertEqual(place.before, otherTabs[0])
    let moved = await store.moveOpenTab(
      oneTabs[1], of: one, into: place.into, before: place.before)
    await settle()
    XCTAssertTrue(moved)

    XCTAssertEqual(
      items(.ungrouped, in: store),
      shown.map { $0 == .tab(oneTabs[1], in: one) ? .tab(oneTabs[1], in: other) : $0 })
  }
}
