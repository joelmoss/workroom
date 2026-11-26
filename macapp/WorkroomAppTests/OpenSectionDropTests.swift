import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Open view's group management (#819 stories 43, 48–51): the drops its switcher tab and rows
/// take, read back as the rows the view shows. Each test drives the source and zone the
/// view's controls send (the Open tab's `.standalone`, a workroom row's `.target`, a row's
/// drag as `.entry`); the whole rule matrix is `TerminalDropTests`'.
@MainActor
final class OpenSectionDropTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  private let wr = SidebarID.workroom(project: "/p", name: "a")

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  private func service() -> PersistentSessionService {
    PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
  }

  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    isolate(store.terminals, service: service())
    return store
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  private func openRows(_ store: AppStore) -> [SidebarID] { store.openSectionRows().map(\.sid) }

  private func tabs(_ store: AppStore, _ sid: SidebarID) -> [TerminalTab.ID] {
    store.target(for: sid).map { store.terminals.tabs(for: $0).map(\.id) } ?? []
  }

  private func standalone(_ store: AppStore) throws -> (SidebarID, TerminalTab.ID) {
    let sid = try XCTUnwrap(section.addStandalone().sidebarID)
    let target = try XCTUnwrap(store.target(for: sid))
    let tab = store.terminals.addTab(for: target)
    store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    return (sid, tab.id)
  }

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

  private func settle(until done: () -> Bool = { true }) async {
    for _ in 0..<200 where !done() { await Task.yield() }
    await section.regroupsSettled()
  }

  // MARK: The three drop rules

  /// Value: protects=a terminal tab let go on the Open heading becomes a standalone terminal with
  /// a row of its own in the section (story 48); fails_when=the heading refuses it or no row shows;
  /// why_new=#819 moved the heading; seam=AppStore.dropTerminals + openSectionRows;
  /// no_claim=the pointer (UI tests)
  func testATabLetGoOnTheOpenHeadingBecomesAStandaloneRow() async throws {
    let store = makeStore()
    store.openExisting(wr)
    let target = try XCTUnwrap(store.target(for: wr))
    let first = store.terminals.addTab(for: target).id
    let second = store.terminals.addTab(for: target).id

    XCTAssertTrue(store.canDropTerminals(.terminal(second, of: wr), on: .standalone))
    let dropped = await store.dropTerminals(.terminal(second, of: wr), on: .standalone)
    await settle { rows.count == 1 }

    XCTAssertTrue(dropped)
    let made = try XCTUnwrap(rows.first)
    guard case .standalone = made else { return XCTFail("\(made) is not a standalone terminal") }
    XCTAssertEqual(tabs(store, made), [second])
    XCTAssertEqual(tabs(store, wr), [first])
    XCTAssertEqual(Set(openRows(store)), [wr, made], "its own row in the section")
  }

  /// Value: protects=a standalone terminal's row let go on another's forms one group row in their
  /// place (story 49); fails_when=either row stays or the group lacks a terminal; why_new=#819;
  /// seam=AppStore.dropTerminals + openSectionRows; no_claim=the pointer
  func testAStandaloneRowLetGoOnAnotherFormsAGroupRow() async throws {
    let store = makeStore()
    let (a, aTab) = try standalone(store)
    let (b, bTab) = try standalone(store)

    XCTAssertTrue(store.canDropTerminals(.entry(a), on: .target(b)))
    let dropped = await store.dropTerminals(.entry(a), on: .target(b))
    await settle { rows.count == 1 }

    XCTAssertTrue(dropped)
    let made = try XCTUnwrap(rows.first)
    guard case .terminalGroup = made else { return XCTFail("\(made) is not a group") }
    XCTAssertEqual(openRows(store), [made], "one group row in their place")
    XCTAssertEqual(Set(tabs(store, made)), [aTab, bTab])
  }

  /// Value: protects=a standalone terminal's row let go on a group's row joins the group, and its
  /// own row leaves (story 50); fails_when=it is refused, stays, or lands elsewhere; why_new=#819;
  /// seam=AppStore.dropTerminals + openSectionRows; no_claim=the pointer
  func testAStandaloneRowLetGoOnAGroupRowJoinsIt() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops")
    let (a, aTab) = try standalone(store)

    XCTAssertTrue(store.canDropTerminals(.entry(a), on: .target(ops)))
    let dropped = await store.dropTerminals(.entry(a), on: .target(ops))
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(openRows(store), [ops])
    let row = try XCTUnwrap(store.openSectionRows().first)
    XCTAssertEqual(row.tabs.last?.tab.id, aTab, "at the group's end")
  }

  // MARK: Highlighting

  /// Value: protects=a group row's drop band follows the Open section's fold, not the retired
  /// Terminals list's: folded (no tab rows under it), it takes drops on its lower edge too;
  /// unfolded, that edge is its first tab row's (story 51); fails_when=the band reads
  /// `TerminalGroup.isFolded`; why_new=#819; seam=AppStore.isFoldedGroup; no_claim=the pointer
  func testAGroupRowsDropBandFollowsItsOpenFold() throws {
    let store = makeStore()
    let ops = try group(store, "Ops")
    let id = try XCTUnwrap(ops.targetID)
    store.selectedTargetID = wr

    section.setFolded(id, false)
    XCTAssertTrue(store.isOpenRowFolded(ops))
    XCTAssertTrue(store.isFoldedGroup(.target(ops)), "folded in the Open section")

    section.setFolded(id, true)
    store.setOpenRow(ops, folded: false)
    XCTAssertFalse(store.isFoldedGroup(.target(ops)), "unfolded in the Open section")
  }

  // MARK: A tab row let go between workroom rows

  /// An unnamed group with two terminals, each with a session.
  private func unnamedGroup(_ store: AppStore) throws -> SidebarID {
    let sid = try XCTUnwrap(section.addGroup(named: nil).sidebarID)
    let target = try XCTUnwrap(store.target(for: sid))
    for _ in 0..<2 {
      let tab = store.terminals.addTab(for: target)
      store.terminals.giveSession(UUID(), toTab: tab.id, in: target)
    }
    return sid
  }

  private func session(_ store: AppStore, _ tab: TerminalTab.ID, in sid: SidebarID) -> UUID? {
    sid.targetID.flatMap { store.terminals.sessionID(forTab: tab, inTarget: $0) }
  }

  /// Value: protects=a group's terminal row let go between two other workroom rows becomes a
  /// standalone terminal there, in the window's workroom tab order the Open view and title bar
  /// share, with its shell kept and selected, and its named group keeps the rest; a workroom's
  /// terminal goes the same way, and a standalone terminal's own never does; fails_when=it lands
  /// at the end or in the Terminals section's order only, restarts, or the group goes;
  /// why_new=#819 owner report; seam=AppStore.moveOpenTabToStandalone + openSectionRows;
  /// no_claim=the pointer (OpenRowReflowTests, OpenSectionUITests)
  func testATerminalRowLetGoBetweenWorkroomRowsBecomesAStandaloneThere() async throws {
    let store = makeStore()
    let ops = try group(store, "Ops")
    let (a, aTab) = try standalone(store)
    let (b, _) = try standalone(store)
    store.workroomTabOrder = [ops, a, b].compactMap(\.targetID)
    XCTAssertEqual(openRows(store), [ops, a, b])
    let opsTabs = tabs(store, ops)
    let moving = try XCTUnwrap(opsTabs.last)
    let shell = session(store, moving, in: ops)

    XCTAssertTrue(store.canMoveOpenTabToStandalone(moving, in: ops))
    XCTAssertFalse(store.canMoveOpenTabToStandalone(aTab, in: a), "already standalone")
    let moved = await store.moveOpenTabToStandalone(moving, in: ops, after: a, before: b)
    await settle()

    XCTAssertTrue(moved)
    let rows = openRows(store)
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(Array(rows.prefix(2)), [ops, a])
    XCTAssertEqual(rows.last, b)
    let made = rows[2]
    guard case .standalone = made else { return XCTFail("\(made) is not a standalone terminal") }
    XCTAssertEqual(tabs(store, made), [moving])
    XCTAssertEqual(session(store, moving, in: made), shell, "the same shell")
    XCTAssertEqual(store.titleBarOrder, rows, "the title bar agrees")
    XCTAssertEqual(store.selectedTargetID, made, "selected, as a drop selects")
    XCTAssertEqual(tabs(store, ops), [opsTabs[0]], "the named group keeps its other terminal")

    // A workroom's terminal goes the same way.
    store.openExisting(wr)
    let target = try XCTUnwrap(store.target(for: wr))
    _ = store.terminals.addTab(for: target)
    let wrTab = store.terminals.addTab(for: target).id
    XCTAssertTrue(store.canMoveOpenTabToStandalone(wrTab, in: wr))
  }

  /// Value: protects=let go just above its own unnamed group, a terminal lands there although the
  /// move dissolves that group into the standalone terminal it leaves behind; a named group's last
  /// terminal let go between rows takes the emptied group's place; fails_when=either lands at the
  /// end, or a group outlives its rules; why_new=#819 owner report;
  /// seam=AppStore.moveOpenTabToStandalone + openSectionRows; no_claim=the pointer
  func testATerminalLetGoBesideItsOwnGroupLandsThereAsTheGroupFollowsItsRules() async throws {
    let store = makeStore()
    let (a, _) = try standalone(store)
    let pair = try unnamedGroup(store)
    let pairID = try XCTUnwrap(pair.targetID)
    let (b, _) = try standalone(store)
    store.workroomTabOrder = [a, pair, b].compactMap(\.targetID)
    let pairTabs = tabs(store, pair)

    let moved = await store.moveOpenTabToStandalone(pairTabs[1], in: pair, after: a, before: pair)
    await settle { section.group(pairID) == nil }

    XCTAssertTrue(moved)
    XCTAssertNil(section.group(pairID), "down to one, it dissolves")
    let rows = openRows(store)
    XCTAssertEqual(rows.count, 4, "\(rows)")
    XCTAssertEqual(rows.first, a)
    XCTAssertEqual(rows.last, b)
    XCTAssertEqual(tabs(store, rows[1]), [pairTabs[1]], "the moved terminal, above the group's")
    XCTAssertEqual(tabs(store, rows[2]), [pairTabs[0]], "the one the group left")

    // A named group's last terminal, let go between the rows: the group goes, it stays there.
    let ops = try group(store, "Ops", count: 1)
    let opsID = try XCTUnwrap(ops.targetID)
    store.workroomTabOrder = [a, ops, b].compactMap(\.targetID)
    let last = try XCTUnwrap(tabs(store, ops).first)
    let movedLast = await store.moveOpenTabToStandalone(last, in: ops, after: a, before: ops)
    await settle { section.group(opsID) == nil }

    XCTAssertTrue(movedLast)
    XCTAssertNil(section.group(opsID), "with its last terminal, it goes")
    let after = openRows(store)
    XCTAssertEqual(after.first, a)
    XCTAssertEqual(tabs(store, after[1]), [last])
    XCTAssertFalse(after.contains(ops))
  }

  // MARK: The Quick Terminal

  /// Value: protects=the Quick Terminal's group has no pinned-first place in the Open section: it
  /// is listed only as the title bar lists it (story 43); fails_when=it is pinned first, or the rows stop following the title bar's order;
  /// why_new=#819; seam=AppStore.openSectionRows; no_claim=the panel (QuickTerminalGroupTests)
  func testTheQuickTerminalGroupIsOrderedLikeAnyOtherWorkroomTab() throws {
    let panel = makeQuickTerminalHost(
      notifications: registry.notifications, service: service(), section: section)
    _ = panel.terminals.addTab(for: panel.target)
    let store = makeStore()
    store.openExisting(wr)
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: wr)))
    let ops = try group(store, "Ops")
    XCTAssertNotNil(section.group(.quickTerminal))
    XCTAssertEqual(panel.terminals.tabCount(forTargetID: .quickTerminal), 1, "a terminal open")

    let before = openRows(store)
    XCTAssertEqual(before, store.displayedWorkroomTargets().map(\.sid))
    XCTAssertEqual(Set(before), [wr, ops], "no pinned row of its own")
    let last = try XCTUnwrap(before.last)
    XCTAssertTrue(store.moveWorkroomTab(last, toIndex: 0))
    XCTAssertEqual(openRows(store), before.reversed(), "the title bar's order, nothing pinned")
  }
}
