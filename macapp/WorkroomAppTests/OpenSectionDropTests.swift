import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Open section's group management (#819 stories 43, 48–51): the drops its heading and rows
/// take, read back as the rows the section shows. Each test drives the source and zone the
/// section's views send (`SidebarOpenHeader`'s `.standalone`, a workroom row's `.target`, a row's
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
