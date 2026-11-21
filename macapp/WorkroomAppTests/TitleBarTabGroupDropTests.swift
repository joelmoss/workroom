import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Dropping a title-bar tab on another tab to group them (#652): a standalone terminal's tab on
/// another's makes an unnamed group of the two; on a group's tab it joins that group; a group's
/// tab on another group's moves all its terminals there and the emptied group goes; a group's tab
/// on a standalone terminal's takes that terminal in. A workroom's tab takes no part. Each terminal
/// keeps its session.
@MainActor
final class TitleBarTabGroupDropTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()

  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    isolate(store.terminals, service: retaggingService())
    return store
  }

  private func retaggingService() -> PersistentSessionService {
    PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  private func tabs(_ store: AppStore, _ sid: SidebarID) -> [TerminalTab.ID] {
    store.target(for: sid).map { store.terminals.tabs(for: $0).map(\.id) } ?? []
  }

  private func session(_ store: AppStore, _ tab: TerminalTab.ID, in sid: SidebarID) -> UUID? {
    sid.targetID.flatMap { store.terminals.sessionID(forTab: tab, inTarget: $0) }
  }

  /// A standalone terminal in `store` whose terminal has session `session`.
  private func standalone(_ store: AppStore, session: UUID = UUID()) throws -> SidebarID {
    let sid = try XCTUnwrap(section.addStandalone().sidebarID)
    let target = try XCTUnwrap(store.target(for: sid))
    let tab = store.terminals.addTab(for: target)
    store.terminals.giveSession(session, toTab: tab.id, in: target)
    return sid
  }

  /// A group named `name` (nil: unnamed) with `count` terminals, each with its own session.
  private func group(_ store: AppStore, _ name: String?, count: Int) throws -> SidebarID {
    let sid = try XCTUnwrap(section.addGroup(named: name).sidebarID)
    let target = try XCTUnwrap(store.target(for: sid))
    for _ in 0..<count {
      let tab = store.terminals.addTab(for: target)
      store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    }
    return sid
  }

  private func settle(until done: () -> Bool = { true }) async {
    for _ in 0..<200 where !done() { await Task.yield() }
    await section.regroupsSettled()
  }

  // MARK: The store

  /// Value: protects=case 1, a standalone tab dropped on another standalone tab makes the same
  /// unnamed group a sidebar row drop makes; fails_when=it is refused, a terminal is lost or
  /// restarted; why_new=#652 title-bar grouping; seam=AppStore.dropTab; no_claim=the pointer
  func testAStandaloneTabOnAnotherMakesAnUnnamedGroup() async throws {
    let store = makeStore()
    let aSession = UUID()
    let a = try standalone(store, session: aSession)
    let b = try standalone(store)
    let aTab = try XCTUnwrap(tabs(store, a).first)
    let bTab = try XCTUnwrap(tabs(store, b).first)

    XCTAssertTrue(store.canDropTab(a, onto: b))
    XCTAssertFalse(store.canDropTab(a, onto: a), "never onto itself")
    let dropped = await store.dropTab(a, onto: b)
    await settle { rows.count == 1 }

    XCTAssertTrue(dropped)
    let made = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows, [made])
    guard case .terminalGroup = made else { return XCTFail("\(made) is not a group") }
    XCTAssertNil(section.group(try XCTUnwrap(made.targetID))?.name, "unnamed")
    XCTAssertEqual(tabs(store, made), [bTab, aTab], "the dropped terminal joins second")
    XCTAssertEqual(session(store, aTab, in: made), aSession, "the same shell")
  }

  /// Value: protects=case 2, a standalone tab dropped on a group's tab joins it at the end and its
  /// own tab goes; fails_when=it is refused, lands first, or its row stays; why_new=#652;
  /// seam=AppStore.dropTab; no_claim=the pointer
  func testAStandaloneTabOnAGroupJoinsItAtTheEnd() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops", count: 2)
    let aSession = UUID()
    let a = try standalone(store, session: aSession)
    let before = tabs(store, ops)
    let aTab = try XCTUnwrap(tabs(store, a).first)

    XCTAssertTrue(store.canDropTab(a, onto: ops))
    let dropped = await store.dropTab(a, onto: ops)
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(rows, [ops])
    XCTAssertEqual(tabs(store, ops), before + [aTab])
    XCTAssertEqual(session(store, aTab, in: ops), aSession)
    XCTAssertEqual(section.group(try XCTUnwrap(ops.targetID))?.name, "Ops")
  }

  /// Value: protects=case 3, a group's tab dropped on another group's moves every terminal there in
  /// order, each with its session, and the emptied group goes, even an unnamed two-terminal one
  /// that would dissolve after its first terminal left; fails_when=a terminal is lost, reordered or
  /// restarted, or the dragged group stays; why_new=#652; seam=AppStore.dropTab; no_claim=the pointer
  func testAGroupsTabOnAnotherGroupMovesAllItsTerminalsAndTheEmptyGroupGoes() async throws {
    let store = makeStore()
    let dev = try group(store, "Dev", count: 1)
    let unnamed = try group(store, nil, count: 2)
    let devTabs = tabs(store, dev)
    let moving = tabs(store, unnamed)
    let sessions = moving.map { session(store, $0, in: unnamed) }
    store.selectedTargetID = unnamed

    XCTAssertTrue(store.canDropTab(unnamed, onto: dev))
    let dropped = await store.dropTab(unnamed, onto: dev)
    await settle { !rows.contains(unnamed) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(rows, [dev], "the dragged group, emptied, is deleted")
    XCTAssertEqual(tabs(store, dev), devTabs + moving, "in order, at the end")
    XCTAssertEqual(moving.map { session(store, $0, in: dev) }, sessions, "the same shells")
    XCTAssertEqual(section.group(try XCTUnwrap(dev.targetID))?.name, "Dev")
    XCTAssertEqual(store.selectedTargetID, dev)
  }

  /// Value: protects=case 4, a group's tab dropped on a standalone terminal's tab takes that
  /// terminal in at the end and keeps its name; fails_when=a new group is made, the name is lost,
  /// or the standalone row stays; why_new=#652 (the owner left it open: the symmetric rule);
  /// seam=AppStore.dropTab; no_claim=the pointer
  func testAGroupsTabOnAStandaloneTabTakesThatTerminalIn() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops", count: 1)
    let a = try standalone(store)
    let before = tabs(store, ops)
    let aTab = try XCTUnwrap(tabs(store, a).first)

    XCTAssertTrue(store.canDropTab(ops, onto: a))
    let dropped = await store.dropTab(ops, onto: a)
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(rows, [ops])
    XCTAssertEqual(tabs(store, ops), before + [aTab])
    XCTAssertEqual(section.group(try XCTUnwrap(ops.targetID))?.name, "Ops")
  }

  /// Value: protects=case 5, a workroom's tab takes no part either way, and nothing groups with
  /// itself; fails_when=a workroom tab is offered as a group target; why_new=#652;
  /// seam=AppStore.canDropTab; no_claim=the reorder, which the UI test covers
  func testAWorkroomsTabNeverGroups() throws {
    let store = makeStore()
    let a = try standalone(store)
    let ops = try group(store, "Ops", count: 1)
    let workroom = SidebarID.workroom(project: "/tmp/p", name: "w")

    XCTAssertFalse(store.canDropTab(a, onto: workroom))
    XCTAssertFalse(store.canDropTab(ops, onto: workroom))
    XCTAssertFalse(store.canDropTab(workroom, onto: a))
    XCTAssertFalse(store.canDropTab(workroom, onto: ops))
    XCTAssertFalse(store.canDropTab(ops, onto: ops))
  }

  // MARK: The geometry

  /// Value: protects=a title-bar tab dragged over another's middle half drops on it, near either
  /// edge it still reorders; fails_when=an edge drop takes the terminals, or a middle drop doesn't;
  /// why_new=#652; seam=TerminalDragSession.titleBarBand; no_claim=whether the pair can group
  func testOnlyATabsMiddleHalfIsADropTarget() {
    let band = TerminalDragSession.titleBarBand(of: CGRect(x: 104, y: 0, width: 100, height: 30))
    XCTAssertTrue(band.contains(CGPoint(x: 154, y: 15)), "the middle")
    XCTAssertTrue(band.contains(CGPoint(x: 130, y: 15)), "just inside its middle half")
    XCTAssertFalse(band.contains(CGPoint(x: 110, y: 15)), "its leading edge reorders")
    XCTAssertFalse(band.contains(CGPoint(x: 200, y: 15)), "its trailing edge reorders")
  }
}
