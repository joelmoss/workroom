import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// One rule set for every terminal drag (#652): a source (a terminal, or a standalone terminal's
/// or group's whole handle) let go over a destination (a container, a standalone terminal, or a
/// terminal at a position) decides one drop, and doing it keeps every terminal's session. These
/// cover each source class against each destination class at `AppStore.terminalDrop` and
/// `dropTerminals`; which surface maps the pointer to them is the UI tests'.
@MainActor
final class TerminalDropTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  private let wr = SidebarID.workroom(project: "/p", name: "a")
  private let far = SidebarID.workroom(project: "/p", name: "far")

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [
          Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: []),
          Workroom(
            name: "far", path: "/p/far", vcsName: "workroom/far", warnings: [],
            host: HostDescriptor(id: UUID())),
        ])
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    return store
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  private func tabs(_ store: AppStore, _ sid: SidebarID) -> [TerminalTab.ID] {
    store.target(for: sid).map { store.terminals.tabs(for: $0).map(\.id) } ?? []
  }

  private func session(_ store: AppStore, _ tab: TerminalTab.ID, in sid: SidebarID) -> UUID? {
    sid.targetID.flatMap { store.terminals.sessionID(forTab: tab, inTarget: $0) }
  }

  private func standalone(_ store: AppStore) throws -> (SidebarID, TerminalTab.ID) {
    let sid = try XCTUnwrap(section.addStandalone().sidebarID)
    let target = try XCTUnwrap(store.target(for: sid))
    let tab = store.terminals.addTab(for: target)
    store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    return (sid, tab.id)
  }

  /// A group named `name` with `count` terminals, each with a session of its own.
  private func group(_ store: AppStore, _ name: String, count: Int = 2) throws -> SidebarID {
    let sid = try XCTUnwrap(store.newTerminalGroup(named: name))
    let target = try XCTUnwrap(store.target(for: sid))
    while store.terminals.tabs(for: target).count < count {
      _ = store.terminals.addTab(for: target)
    }
    for tab in store.terminals.tabs(for: target) {
      store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    }
    return sid
  }

  /// Workroom `a` shown with one terminal.
  private func workroomPane(_ store: AppStore) throws -> TerminalTab.ID {
    let target = try XCTUnwrap(store.target(for: wr))
    let tab = store.terminals.addTab(for: target)
    store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    store.selectedTargetID = wr
    return tab.id
  }

  private func settle(until done: () -> Bool = { true }) async {
    for _ in 0..<200 where !done() { await Task.yield() }
    await section.regroupsSettled()
  }

  // MARK: Deciding: a terminal

  /// Value: protects=a terminal (a pane tab or a terminal's row) let go on another container's
  /// terminal lands in that container before it, or after it on its after-half, and on its own
  /// container's reorders, refusing a drop that changes nothing; fails_when=a positional drop
  /// joins at the end, an after-half lands before, or a drop on itself moves; why_new=#652;
  /// seam=AppStore.terminalDrop; no_claim=the pointer
  func testATerminalOnATerminalLandsBeforeOrAfterItAndAmongItsOwnReorders() throws {
    let store = makeStore()
    let ops = try group(store, "Ops", count: 2)
    let dev = try group(store, "Dev", count: 2)
    let opsTabs = tabs(store, ops)
    let devTabs = tabs(store, dev)
    let dragged = TerminalDragSource.terminal(opsTabs[0], of: ops)

    XCTAssertEqual(
      store.terminalDrop(dragged, on: .tab(devTabs[1], in: dev, after: false)),
      .move(opsTabs[0], of: ops, into: dev, before: devTabs[1]))
    XCTAssertEqual(
      store.terminalDrop(dragged, on: .tab(devTabs[0], in: dev, after: true)),
      .move(opsTabs[0], of: ops, into: dev, before: devTabs[1]), "after the first: before the next")
    XCTAssertEqual(
      store.terminalDrop(dragged, on: .tab(devTabs[1], in: dev, after: true)),
      .move(opsTabs[0], of: ops, into: dev, before: nil), "after the last: the end")
    XCTAssertEqual(
      store.terminalDrop(dragged, on: .tab(opsTabs[1], in: ops, after: true)),
      .reorder(opsTabs[0], in: ops, before: nil))
    XCTAssertNil(store.terminalDrop(dragged, on: .tab(opsTabs[0], in: ops, after: false)))
    XCTAssertNil(store.terminalDrop(dragged, on: .tab(opsTabs[1], in: ops, after: false)))
    XCTAssertNil(store.terminalDrop(dragged, on: .target(ops)), "its own container: nothing")
    XCTAssertEqual(
      store.terminalDrop(dragged, on: .terminalRow(devTabs[1], in: dev)),
      .move(opsTabs[0], of: ops, into: dev, before: devTabs[1]), "a terminal's row: above it")
  }

  /// Value: protects=a terminal let go on a container joins it at the end, on a standalone
  /// terminal groups with it, and is refused by a remote workroom; fails_when=a container drop is
  /// refused or a remote drop is offered; why_new=#652; seam=AppStore.terminalDrop;
  /// no_claim=the pointer
  func testATerminalOnAContainerJoinsItsEndAndOnAStandaloneGroups() throws {
    let store = makeStore()
    let pane = try workroomPane(store)
    let ops = try group(store, "Ops")
    let (a, _) = try standalone(store)
    let dragged = TerminalDragSource.terminal(pane, of: wr)

    XCTAssertEqual(
      store.terminalDrop(dragged, on: .target(ops)), .move(pane, of: wr, into: ops, before: nil))
    XCTAssertEqual(
      store.terminalDrop(dragged, on: .target(a)), .move(pane, of: wr, into: a, before: nil))
    XCTAssertEqual(store.terminalDrop(dragged, on: .standalone), .standalone(pane, of: wr))
    XCTAssertNil(store.terminalDrop(dragged, on: .target(far)), "a remote workroom refuses")
  }

  // MARK: Deciding: a standalone terminal's or group's handle

  /// Value: protects=a standalone terminal's row or tab is its terminal: it joins a group, a
  /// workroom, or a terminal's place, and groups with another standalone; fails_when=a standalone
  /// handle is refused by a workroom or a position; why_new=#652; seam=AppStore.terminalDrop;
  /// no_claim=the pointer
  func testAStandalonesHandleDropsAsItsTerminal() throws {
    let store = makeStore()
    _ = try workroomPane(store)
    let ops = try group(store, "Ops")
    let (a, aTab) = try standalone(store)
    let (b, _) = try standalone(store)
    let opsTabs = tabs(store, ops)

    XCTAssertEqual(
      store.terminalDrop(.entry(a), on: .target(ops)), .move(aTab, of: a, into: ops, before: nil))
    XCTAssertEqual(
      store.terminalDrop(.entry(a), on: .tab(opsTabs[1], in: ops, after: false)),
      .move(aTab, of: a, into: ops, before: opsTabs[1]))
    XCTAssertEqual(
      store.terminalDrop(.entry(a), on: .target(b)), .move(aTab, of: a, into: b, before: nil))
    XCTAssertEqual(
      store.terminalDrop(.entry(a), on: .target(wr)), .move(aTab, of: a, into: wr, before: nil))
    XCTAssertNil(store.terminalDrop(.entry(a), on: .target(a)))
  }

  /// Value: protects=a group's handle is all its terminals: onto another group it merges (at a
  /// position too), onto a standalone it takes it in, onto a workroom they all move; never onto
  /// itself; fails_when=a group handle is refused, merges into itself, or a standalone makes a new
  /// group; why_new=#652; seam=AppStore.terminalDrop; no_claim=the pointer
  func testAGroupsHandleMovesAllItsTerminals() throws {
    let store = makeStore()
    _ = try workroomPane(store)
    let ops = try group(store, "Ops")
    let dev = try group(store, "Dev")
    let (a, _) = try standalone(store)
    let devTabs = tabs(store, dev)

    XCTAssertEqual(
      store.terminalDrop(.entry(ops), on: .target(dev)), .moveGroup(ops, into: dev, before: nil))
    XCTAssertEqual(
      store.terminalDrop(.entry(ops), on: .tab(devTabs[1], in: dev, after: false)),
      .moveGroup(ops, into: dev, before: devTabs[1]))
    XCTAssertEqual(
      store.terminalDrop(.entry(ops), on: .target(a)), .takeIn(standalone: a, group: ops))
    XCTAssertEqual(
      store.terminalDrop(.entry(ops), on: .target(wr)), .moveGroup(ops, into: wr, before: nil))
    XCTAssertNil(store.terminalDrop(.entry(ops), on: .target(ops)))
    XCTAssertNil(store.terminalDrop(.entry(ops), on: .target(far)))
    XCTAssertNil(store.terminalDrop(.entry(ops), on: .standalone))
  }

  /// Value: protects=workrooms don't merge: a workroom's row or tab is never a source of
  /// terminals; fails_when=a workroom handle drops into a group or standalone; why_new=#652 (the
  /// owner's decision); seam=AppStore.terminalDrop; no_claim=the workroom's reorder and split
  func testAWorkroomsHandleIsNeverATerminalSource() throws {
    let store = makeStore()
    _ = try workroomPane(store)
    let ops = try group(store, "Ops")
    let (a, _) = try standalone(store)

    XCTAssertNil(store.terminalDrop(.entry(wr), on: .target(ops)))
    XCTAssertNil(store.terminalDrop(.entry(wr), on: .target(a)))
    XCTAssertNil(store.terminalDrop(.entry(wr), on: .standalone))
  }

  // MARK: Doing

  /// Value: protects=a standalone row let go before a group's terminal joins there with its
  /// session; fails_when=it lands at the end or restarts; why_new=#652;
  /// seam=AppStore.dropTerminals; no_claim=the pointer
  func testAStandaloneDroppedBeforeAGroupsTerminalJoinsThere() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops")
    let (a, aTab) = try standalone(store)
    let opsTabs = tabs(store, ops)
    let shell = session(store, aTab, in: a)

    let dropped = await store.dropTerminals(.entry(a), on: .tab(opsTabs[1], in: ops, after: false))
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, ops), [opsTabs[0], aTab, opsTabs[1]])
    XCTAssertEqual(session(store, aTab, in: ops), shell)
    XCTAssertEqual(rows, [ops])
  }

  /// Value: protects=a group dropped at another group's terminal merges there in order, and the
  /// emptied group goes; fails_when=the terminals land at the end, lose order or sessions, or the
  /// group stays; why_new=#652; seam=AppStore.dropTerminals; no_claim=the pointer
  func testAGroupDroppedAtAnotherGroupsTerminalMergesThere() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops")
    let dev = try group(store, "Dev")
    let opsTabs = tabs(store, ops)
    let devTabs = tabs(store, dev)
    let shells = opsTabs.map { session(store, $0, in: ops) }

    let dropped = await store.dropTerminals(
      .entry(ops), on: .tab(devTabs[0], in: dev, after: true))
    await settle { !rows.contains(ops) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, dev), [devTabs[0]] + opsTabs + [devTabs[1]])
    XCTAssertEqual(opsTabs.map { session(store, $0, in: dev) }, shells)
    XCTAssertEqual(rows, [dev])
  }

  /// Value: protects=a group dropped on a workroom moves every terminal into it, in order with
  /// its session, and the emptied group goes, as Move to… a workroom does; fails_when=only one
  /// moves (the group dissolves mid-move), a session is lost, or the group stays; why_new=#652;
  /// seam=AppStore.dropTerminals; no_claim=the pointer
  func testAGroupDroppedOnAWorkroomMovesAllItsTerminalsThere() async throws {
    let store = makeStore()
    let pane = try workroomPane(store)
    let ops = try group(store, "Ops")
    let opsTabs = tabs(store, ops)
    let shells = opsTabs.map { session(store, $0, in: ops) }

    let dropped = await store.dropTerminals(.entry(ops), on: .target(wr))
    await settle { !rows.contains(ops) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, wr), [pane] + opsTabs)
    XCTAssertEqual(opsTabs.map { session(store, $0, in: wr) }, shells)
    XCTAssertEqual(rows, [], "the emptied group is deleted")
  }

  /// Value: protects=a workroom's pane tab let go on a group terminal's after-half joins after it
  /// with its session; fails_when=it lands before or at the end; why_new=#652;
  /// seam=AppStore.dropTerminals; no_claim=the pointer
  func testAPaneTabDroppedAfterAGroupsTerminalJoinsAfterIt() async throws {
    let store = makeStore()
    let pane = try workroomPane(store)
    let ops = try group(store, "Ops")
    let opsTabs = tabs(store, ops)
    let shell = session(store, pane, in: wr)

    let dropped = await store.dropTerminals(
      .terminal(pane, of: wr), on: .tab(opsTabs[0], in: ops, after: true))
    await settle()

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, ops), [opsTabs[0], pane, opsTabs[1]])
    XCTAssertEqual(session(store, pane, in: ops), shell)
  }

  // MARK: The title bar's empty space

  /// Value: protects=a pane let go in the title bar's empty space becomes a standalone terminal,
  /// its session kept, its title-bar tab just before the tab after the gap (#652 owner request);
  /// fails_when=it is refused, restarted, or its tab lands at the end; why_new=#652;
  /// seam=AppStore.terminalDrop/dropTerminals; no_claim=the pointer
  func testAPaneLetGoInTheTitleBarsEmptySpaceBecomesStandaloneThere() async throws {
    let store = makeStore()
    let pane = try workroomPane(store)
    let (a, _) = try standalone(store)
    let (b, _) = try standalone(store)
    let shell = session(store, pane, in: wr)
    let dragged = TerminalDragSource.terminal(pane, of: wr)

    XCTAssertEqual(
      store.terminalDrop(dragged, on: .titleBarGap(before: b)),
      .standalone(pane, of: wr, titleBarBefore: .some(b)))
    let dropped = await store.dropTerminals(dragged, on: .titleBarGap(before: b))
    await settle()

    XCTAssertTrue(dropped)
    let new = try XCTUnwrap(rows.first { $0 != a && $0 != b }, "a new standalone terminal")
    XCTAssertEqual(tabs(store, new), [pane])
    XCTAssertEqual(session(store, pane, in: new), shell, "the same shell")
    let order = store.titleBarOrder
    let newIndex = try XCTUnwrap(order.firstIndex(of: new))
    XCTAssertEqual(order.firstIndex(of: b), newIndex + 1, "its tab just before b's: \(order)")
  }

  /// Value: protects=a standalone terminal's own pane let go in the title bar's empty space only
  /// moves its title-bar tab, and its own place changes nothing; fails_when=a second standalone is
  /// made or a no-op is offered; why_new=#652 owner request; seam=AppStore.terminalDrop;
  /// no_claim=the pointer
  func testAStandalonesPaneInTheTitleBarsEmptySpaceOnlyMovesItsTab() async throws {
    let store = makeStore()
    let (a, aTab) = try standalone(store)
    let (b, _) = try standalone(store)
    store.placeTitleBarTab(try XCTUnwrap(a.targetID), before: b)
    let dragged = TerminalDragSource.terminal(aTab, of: a)

    XCTAssertNil(store.terminalDrop(dragged, on: .titleBarGap(before: b)), "already there")
    XCTAssertNil(store.terminalDrop(dragged, on: .titleBarGap(before: a)), "its own place")
    XCTAssertEqual(
      store.terminalDrop(dragged, on: .titleBarGap(before: nil)),
      .reorderTitleBar(a, before: nil))
    let dropped = await store.dropTerminals(dragged, on: .titleBarGap(before: nil))

    XCTAssertTrue(dropped)
    XCTAssertEqual(store.titleBarOrder.filter { $0 == a || $0 == b }, [b, a])
    XCTAssertEqual(rows.count, 2, "no new terminal")
  }

  // MARK: Where the pointer is

  /// Value: protects=the drag session's zones: a pane tab's halves are before and after it, a
  /// pane tab's own strip keeps its reorder, a sidebar row's edges are the List's gaps (a folded
  /// group's lower edge is its for a terminal's row, not for an Open row, whose edges reorder,
  /// #819), judged against the zones as they were when the drag started;
  /// fails_when=a pane tab drop always lands before, the own strip is a destination, or an edge
  /// of a row takes the drop; why_new=#652; seam=TerminalDragSession.zone(at:);
  /// no_claim=measuring the views (UI tests)
  func testTheSessionsZonesSplitTabsInHalvesAndRowsByBand() throws {
    let store = makeStore()
    let ops = try group(store, "Ops")
    let dev = try group(store, "Dev")
    let opsTabs = tabs(store, ops)
    let session = TerminalDragSession(store: store)
    let tab = TerminalDragSession.Zone(
      zone: .tab(opsTabs[0], in: ops, after: false),
      rect: CGRect(x: 100, y: 500, width: 100, height: 30), isPaneTab: true)
    let row = TerminalDragSession.Zone(
      zone: .target(dev), rect: CGRect(x: 0, y: 300, width: 200, height: 40))
    let folded = TerminalDragSession.Zone(
      zone: .target(ops), rect: CGRect(x: 0, y: 200, width: 200, height: 40),
      isFoldedGroup: true)

    session.begin(.entry(dev), from: .sidebar, zones: [tab, row, folded])
    XCTAssertEqual(
      session.zone(at: CGPoint(x: 120, y: 515)), .tab(opsTabs[0], in: ops, after: false))
    XCTAssertEqual(
      session.zone(at: CGPoint(x: 180, y: 515)), .tab(opsTabs[0], in: ops, after: true))
    XCTAssertEqual(session.zone(at: CGPoint(x: 50, y: 320)), .target(dev), "a row's middle")
    XCTAssertNil(session.zone(at: CGPoint(x: 50, y: 302)), "its lower edge is the List's gap")
    XCTAssertNil(
      session.zone(at: CGPoint(x: 50, y: 202)),
      "an Open row's drag reorders at a folded group's too")

    session.begin(.terminal(opsTabs[1], of: ops), from: .sidebar, zones: [row, folded])
    XCTAssertEqual(
      session.zone(at: CGPoint(x: 50, y: 202)), .target(ops), "a terminal row's takes it")
    XCTAssertNil(session.zone(at: CGPoint(x: 50, y: 238)), "its top quarter reorders")

    session.begin(.terminal(opsTabs[1], of: ops), from: .paneTabs, zones: [tab, row])
    XCTAssertNil(session.zone(at: CGPoint(x: 120, y: 515)), "its own strip keeps its reorder")
    XCTAssertEqual(session.zone(at: CGPoint(x: 50, y: 302)), .target(dev), "a row's whole height")
  }

  /// Value: protects=a terminal let go among its own container's tabs reorders them in place;
  /// fails_when=it moves out or nothing changes; why_new=#652; seam=AppStore.dropTerminals;
  /// no_claim=the pane strip's own reorder
  /// Value: protects=the shared ghost follows an Open row's drag and a pane tab's, and stays off a
  /// Projects-tree terminal row's, as before #819; fails_when=the sidebar surface draws it for
  /// every source or none; why_new=#819 review A4; seam=TerminalDragSession.isProjectsTreeRow;
  /// no_claim=the floating panel itself
  func testTheGhostFollowsAnOpenRowsDragNotAProjectsTerminalRows() {
    let tab = TerminalTab.ID()
    let group = SidebarID.terminalGroup(UUID())
    XCTAssertFalse(TerminalDragSession.isProjectsTreeRow(.entry(group), from: .sidebar))
    XCTAssertTrue(TerminalDragSession.isProjectsTreeRow(.terminal(tab, of: group), from: .sidebar))
    XCTAssertFalse(
      TerminalDragSession.isProjectsTreeRow(.terminal(tab, of: group), from: .paneTabs))
  }

  func testATerminalAmongItsOwnReorders() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops", count: 3)
    let t = tabs(store, ops)

    let dropped = await store.dropTerminals(
      .terminal(t[0], of: ops), on: .tab(t[2], in: ops, after: true))

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, ops), [t[1], t[2], t[0]])
  }
}
