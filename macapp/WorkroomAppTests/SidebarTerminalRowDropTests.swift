import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Dragging any terminal's row in the Terminals section into a group (#652): a standalone
/// terminal's row let go on a group's row (or one of its terminals' rows) joins that group; a
/// group's terminal let go on another group moves there, the Quick Terminal's among them; and one
/// let go between the section's rows becomes a standalone terminal there. Every drop is the move
/// Move to… makes, so the terminal keeps its session.
@MainActor
final class SidebarTerminalRowDropTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  private let builtIn = SidebarID.terminalGroup(TargetID.quickTerminalGroupID)

  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    isolate(store.terminals, service: retaggingService())
    return store
  }

  private func makePanel() -> QuickTerminalHost {
    makeQuickTerminalHost(
      notifications: registry.notifications, service: retaggingService(), section: section)
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

  /// A standalone terminal in `store` whose terminal has session `session`.
  private func standalone(_ store: AppStore, session: UUID = UUID()) throws -> SidebarID {
    let sid = try XCTUnwrap(section.addStandalone().sidebarID)
    let target = try XCTUnwrap(store.target(for: sid))
    let tab = store.terminals.addTab(for: target)
    store.terminals.giveSession(session, toTab: tab.id, in: target)
    return sid
  }

  /// A named group in `store` with its first terminal, which has session `session`.
  private func group(_ store: AppStore, _ name: String, session: UUID = UUID()) throws -> (
    SidebarID, TerminalTab.ID
  ) {
    let sid = try XCTUnwrap(store.newTerminalGroup(named: name))
    let target = try XCTUnwrap(store.target(for: sid))
    let tab = try XCTUnwrap(store.terminals.tabs(for: target).first)
    store.terminals.giveSession(session, toTab: tab.id, in: target)
    return (sid, tab.id)
  }

  private func session(_ store: AppStore, _ tab: TerminalTab.ID, in sid: SidebarID) -> UUID? {
    sid.targetID.flatMap { store.terminals.sessionID(forTab: tab, inTarget: $0) }
  }

  private func settle(until done: () -> Bool) async {
    for _ in 0..<200 where !done() { await Task.yield() }
    await section.regroupsSettled()
  }

  // MARK: Into a group

  /// Value: protects=a standalone terminal's row let go on a group's row joins the group with its
  /// session, and its own row goes (#652 case 1); fails_when=the drop is refused, the terminal is
  /// restarted, or the standalone row stays; why_new=#652; seam=AppStore.dropRow;
  /// no_claim=hit-testing the pointer (TerminalGroupUITests)
  func testAStandaloneRowDroppedOnAGroupJoinsIt() async throws {
    let store = makeStore()
    let session = UUID()
    let a = try standalone(store, session: session)
    let (ops, _) = try group(store, "Ops")
    let aTab = try XCTUnwrap(tabs(store, a).first)

    XCTAssertTrue(store.canDropRow(.standalone(a), onto: ops))
    let dropped = await store.dropRow(.standalone(a), onto: ops)
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(rows, [ops], "its own row goes")
    XCTAssertEqual(tabs(store, ops).count, 2)
    XCTAssertTrue(tabs(store, ops).contains(aTab))
    XCTAssertEqual(self.session(store, aTab, in: ops), session, "the same shell, not a new one")
  }

  /// Value: protects=a group's terminal let go on another group's row moves there with its
  /// session, and the group it left, now empty, is deleted (#652 case 2); fails_when=the drop is
  /// refused, the terminal is restarted, or an empty group stays; why_new=#652;
  /// seam=AppStore.dropRow; no_claim=hit-testing the pointer (TerminalGroupUITests)
  func testAGroupsTerminalDroppedOnAnotherGroupMovesThereAndAnEmptyGroupGoes() async throws {
    let store = makeStore()
    let session = UUID()
    let (ops, opsTab) = try group(store, "Ops", session: session)
    let (dev, _) = try group(store, "Dev")
    let dragged = SidebarRowDragItem.terminal(opsTab, group: ops)

    XCTAssertTrue(store.canDropRow(dragged, onto: dev))
    XCTAssertFalse(store.canDropRow(dragged, onto: ops), "not onto its own group")
    let dropped = await store.dropRow(dragged, onto: dev)
    await settle { !rows.contains(ops) }

    XCTAssertTrue(dropped)
    XCTAssertTrue(tabs(store, dev).contains(opsTab))
    XCTAssertEqual(self.session(store, opsTab, in: dev), session)
    XCTAssertEqual(rows, [dev], "Ops, left empty, is deleted")
  }

  /// Value: protects=a group's terminal let go on a standalone terminal's row makes an unnamed group
  /// of the two, as a standalone row does (#659 rule, #652); fails_when=it is refused or lost;
  /// why_new=#652; seam=AppStore.dropRow; no_claim=the pointer
  func testAGroupsTerminalDroppedOnAStandaloneRowGroupsThem() async throws {
    let store = makeStore()
    let (ops, opsTab) = try group(store, "Ops")
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: ops)))
    let a = try standalone(store)
    let dragged = SidebarRowDragItem.terminal(opsTab, group: ops)

    XCTAssertTrue(store.canDropRow(dragged, onto: a))
    _ = await store.dropRow(dragged, onto: a)
    await settle { !rows.contains(a) }

    let made = try XCTUnwrap(rows.last)
    guard case .terminalGroup = made else { return XCTFail("\(made) is not a group") }
    XCTAssertTrue(tabs(store, made).contains(opsTab))
    XCTAssertEqual(tabs(store, made).count, 2)
    XCTAssertEqual(tabs(store, ops).count, 1)
  }

  /// Value: protects=standalone onto standalone still groups, and a row can't drop on itself or
  /// outside the section (#659 kept); fails_when=either changes; why_new=#652 widened canDropRow;
  /// seam=AppStore.canDropRow; no_claim=the pointer
  func testAStandaloneRowStillGroupsWithAnotherAndNeverWithItself() async throws {
    let store = makeStore()
    let a = try standalone(store)
    let b = try standalone(store)

    XCTAssertTrue(store.canDropRow(.standalone(b), onto: a))
    XCTAssertFalse(store.canDropRow(.standalone(a), onto: a))
    XCTAssertFalse(store.canDropRow(.standalone(a), onto: .workroom(project: "/p", name: "a")))
    let dropped = await store.dropRow(.standalone(b), onto: a)
    await settle { rows.count == 1 }

    XCTAssertTrue(dropped)
    XCTAssertEqual(rows.count, 1)
    guard case .terminalGroup = rows.first else { return XCTFail("no group") }
  }

  // MARK: The Quick Terminal

  /// Value: protects=a group's terminal let go on the Quick Terminal's row moves into its panel
  /// with its session, as Move to… → Quick Terminal does; fails_when=it is refused, or lands in the
  /// window; why_new=#652; seam=AppStore.dropRow; no_claim=the panel's slide
  func testAGroupsTerminalDroppedOnTheQuickTerminalMovesIntoThePanel() async throws {
    let panel = makePanel()
    panel.onReveal = { _ in }
    let store = makeStore()
    let session = UUID()
    let (ops, opsTab) = try group(store, "Ops", session: session)
    let dragged = SidebarRowDragItem.terminal(opsTab, group: ops)

    XCTAssertTrue(store.canDropRow(dragged, onto: builtIn))
    let dropped = await store.dropRow(dragged, onto: builtIn)

    XCTAssertTrue(dropped)
    XCTAssertNotNil(panel.terminals.tab(opsTab, for: panel.target))
    XCTAssertEqual(panel.terminals.sessionID(forTab: opsTab, inTarget: .quickTerminal), session)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0)
  }

  /// Value: protects=one of the Quick Terminal's terminals, its row under the Quick Terminal's,
  /// dragged into a group of the window's, keeps its session there; fails_when=the panel's tab
  /// is refused (the window reads its own panes) or restarted; why_new=#652; seam=AppStore.dropRow;
  /// no_claim=the pointer
  func testAQuickTerminalsTerminalDroppedOnAGroupMovesIntoTheWindow() async throws {
    let panel = makePanel()
    let quick = panel.terminals.addTab(for: panel.target)
    let session = UUID()
    panel.terminals.giveSession(session, toTab: quick.id, in: panel.target)
    let store = makeStore()
    let (ops, _) = try group(store, "Ops")
    let dragged = SidebarRowDragItem.terminal(quick.id, group: builtIn)

    XCTAssertTrue(store.canDropRow(dragged, onto: ops))
    XCTAssertFalse(store.canDropRow(dragged, onto: builtIn), "not onto its own group")
    let dropped = await store.dropRow(dragged, onto: ops)

    XCTAssertTrue(dropped)
    XCTAssertTrue(tabs(store, ops).contains(quick.id))
    XCTAssertEqual(self.session(store, quick.id, in: ops), session)
    XCTAssertNil(panel.terminals.tab(quick.id, for: panel.target), "it left the panel")
  }

  // MARK: At a place in a group

  /// Value: protects=a standalone terminal's row let go just above a group's second terminal
  /// joins the group second in its tabs' order, with its session (#652 follow-up);
  /// fails_when=it lands last, or its row stays; why_new=the owner wants the drop's position to
  /// count; seam=AppStore.dropRow(_:into:before:); no_claim=the List's drop
  func testAStandaloneRowLetGoAboveAGroupsTerminalJoinsThere() async throws {
    let store = makeStore()
    let session = UUID()
    let a = try standalone(store, session: session)
    let (ops, first) = try group(store, "Ops")
    let second = store.terminals.addTab(for: try XCTUnwrap(store.target(for: ops))).id
    let aTab = try XCTUnwrap(tabs(store, a).first)

    let dropped = await store.dropRow(.standalone(a), into: ops, before: second)
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, ops), [first, aTab, second], "second, as it was let go")
    XCTAssertEqual(self.session(store, aTab, in: ops), session)
    XCTAssertEqual(rows, [ops])
  }

  /// Another group's terminal takes the place it was let go at.
  func testAnotherGroupsTerminalLetGoAboveATerminalJoinsThere() async throws {
    let store = makeStore()
    let (ops, first) = try group(store, "Ops")
    let second = store.terminals.addTab(for: try XCTUnwrap(store.target(for: ops))).id
    let (dev, devTab) = try group(store, "Dev")
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: dev)))

    let dropped = await store.dropRow(.terminal(devTab, group: dev), into: ops, before: first)

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, ops), [devTab, first, second], "first, above Ops's first")
    XCTAssertEqual(tabs(store, dev).count, 1)
  }

  /// Value: protects=a group's terminal let go among its own group's terminals moves to that
  /// place in its tabs' order (#652 follow-up); fails_when=it stays put or leaves the group;
  /// why_new=the owner wants the drop's position to count; seam=AppStore.dropRow(_:into:before:);
  /// no_claim=the List's drop
  func testAGroupsTerminalLetGoAmongItsOwnReordersThem() async throws {
    let store = makeStore()
    let (ops, first) = try group(store, "Ops")
    let target = try XCTUnwrap(store.target(for: ops))
    let second = store.terminals.addTab(for: target).id
    let third = store.terminals.addTab(for: target).id

    let dropped = await store.dropRow(.terminal(third, group: ops), into: ops, before: first)

    XCTAssertTrue(dropped)
    XCTAssertEqual(tabs(store, ops), [third, first, second])
  }

  /// Value: protects=a terminal let go among the Quick Terminal's terminals joins its panel at
  /// that place, and one of its own moves there (#652 follow-up); fails_when=it lands last, in the
  /// window, or the panel's own order doesn't change; why_new=the owner named the Quick Terminal;
  /// seam=AppStore.dropRow(_:into:before:); no_claim=the List's drop (no fixture seeds its terminals)
  func testATerminalLetGoAmongTheQuickTerminalsJoinsThePanelThere() async throws {
    let panel = makePanel()
    panel.onReveal = { _ in }
    let q1 = panel.terminals.addTab(for: panel.target).id
    let q2 = panel.terminals.addTab(for: panel.target).id
    let store = makeStore()
    let a = try standalone(store)
    let aTab = try XCTUnwrap(tabs(store, a).first)
    func order() -> [TerminalTab.ID] { panel.terminals.tabs(for: panel.target).map(\.id) }

    let dropped = await store.dropRow(.standalone(a), into: builtIn, before: q2)
    await settle { !rows.contains(a) }

    XCTAssertTrue(dropped)
    XCTAssertEqual(order(), [q1, aTab, q2], "second in the panel")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0)

    let reordered = await store.dropRow(.terminal(q2, group: builtIn), into: builtIn, before: q1)
    XCTAssertTrue(reordered)
    XCTAssertEqual(order(), [q2, q1, aTab], "one of its own moves there")
  }

  // MARK: Onto the Quick Terminal panel's pane tabs

  /// Value: protects=a window's terminal, standalone terminal or group let go on the Quick
  /// Terminal panel's pane tab joins the panel before it, or after it on its after-half, with its
  /// session, by the same rule as a window's pane tab (#652); fails_when=the drop is refused, lands
  /// at the end, in the window, or restarts the shell; why_new=the panel's tabs were no destination;
  /// seam=AppStore.terminalDrop/dropTerminals; no_claim=measuring the panel's views (UI tests)
  func testATerminalLetGoOnTheQuickTerminalPanelsTabJoinsItThere() async throws {
    let panel = makePanel()
    panel.onReveal = { _ in }
    let q1 = panel.terminals.addTab(for: panel.target).id
    let q2 = panel.terminals.addTab(for: panel.target).id
    func order() -> [TerminalTab.ID] { panel.terminals.tabs(for: panel.target).map(\.id) }
    let store = makeStore()
    let shell = UUID()
    let (ops, opsTab) = try group(store, "Ops", session: shell)
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: ops)))

    XCTAssertEqual(
      store.terminalDrop(.terminal(opsTab, of: ops), on: .tab(q1, in: builtIn, after: true)),
      .move(opsTab, of: ops, into: builtIn, before: q2))
    let dropped = await store.dropTerminals(
      .terminal(opsTab, of: ops), on: .tab(q1, in: builtIn, after: true))
    await settle { order().count == 3 }
    XCTAssertTrue(dropped)
    XCTAssertEqual(order(), [q1, opsTab, q2], "after the first, its after-half")
    XCTAssertEqual(panel.terminals.sessionID(forTab: opsTab, inTarget: .quickTerminal), shell)

    let a = try standalone(store)
    let aTab = try XCTUnwrap(tabs(store, a).first)
    let joined = await store.dropTerminals(.entry(a), on: .tab(q1, in: builtIn, after: false))
    await settle { !rows.contains(a) }
    XCTAssertTrue(joined)
    XCTAssertEqual(order(), [aTab, q1, opsTab, q2], "a standalone's handle, before the first")

    let opsRest = tabs(store, ops)
    let merged = await store.dropTerminals(.entry(ops), on: .tab(q2, in: builtIn, after: true))
    await settle { !rows.contains(ops) }
    XCTAssertTrue(merged)
    XCTAssertEqual(order(), [aTab, q1, opsTab, q2] + opsRest, "a group's handle, after the last")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0, "none in the window")
  }

  /// Value: protects=a window's drag over the Quick Terminal panel's pane tab highlights it on the
  /// panel, not the window, and back; the panel in front hides the window's zones under it, and
  /// the window in front the panel's; let go there, the drop lands in the panel (#652);
  /// fails_when=the highlight is set on the dragging window, stays on either, or a hidden zone
  /// takes the drop; why_new=the panel's tabs were no destination;
  /// seam=TerminalDragSession/AppStore.stacked; no_claim=measuring the views (UI tests)
  func testADragOverTheQuickTerminalPanelHighlightsAndDropsThere() async throws {
    let panel = makePanel()
    panel.onReveal = { _ in }
    let q1 = panel.terminals.addTab(for: panel.target).id
    let store = makeStore()
    let (ops, opsTab) = try group(store, "Ops")
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: ops)))
    let dev = try standalone(store)
    let windowFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let panelFrame = CGRect(x: 0, y: 400, width: 800, height: 300)
    let row = TerminalDragSession.Zone(
      zone: .target(dev), rect: CGRect(x: 0, y: 420, width: 200, height: 40))
    var tab = TerminalDragSession.Zone(
      zone: .tab(q1, in: builtIn, after: false),
      rect: CGRect(x: 100, y: 660, width: 100, height: 30), isPaneTab: true)
    tab.host = panel
    let underTab = CGPoint(x: 120, y: 675)
    let underRow = CGPoint(x: 50, y: 440)
    let session = TerminalDragSession(store: store)
    let source = TerminalDragSource.terminal(opsTab, of: ops)

    // The panel in front: its tab takes the drag, the window's row under it doesn't.
    session.begin(
      source, from: .paneTabs,
      zones: AppStore.stacked(
        [row], in: windowFrame, with: [tab], in: panelFrame, panelInFront: true))
    XCTAssertTrue(session.moved(source, from: .paneTabs, to: underTab))
    XCTAssertEqual(panel.incomingPaneDrop, .tab(q1, in: builtIn, after: false))
    XCTAssertNil(store.incomingPaneDrop, "the panel's tab shows it, not the window")
    XCTAssertTrue(session.host(at: underTab) === panel)
    XCTAssertFalse(session.moved(source, from: .paneTabs, to: underRow), "hidden by the panel")
    XCTAssertNil(panel.incomingPaneDrop)
    XCTAssertNil(store.incomingPaneDrop)

    // The window in front: its row takes it where it covers the panel.
    session.begin(
      source, from: .paneTabs,
      zones: AppStore.stacked(
        [row], in: windowFrame, with: [tab], in: CGRect(x: 0, y: 400, width: 800, height: 300),
        panelInFront: false))
    XCTAssertTrue(session.moved(source, from: .paneTabs, to: underRow))
    XCTAssertEqual(store.incomingPaneDrop, .target(dev))
    XCTAssertNil(panel.incomingPaneDrop)
    XCTAssertTrue(session.moved(source, from: .paneTabs, to: underTab), "past the window's edge")
    XCTAssertEqual(panel.incomingPaneDrop, .tab(q1, in: builtIn, after: false))
    XCTAssertNil(store.incomingPaneDrop, "moved off the window's row")

    XCTAssertTrue(session.ended(at: underTab))
    XCTAssertNil(panel.incomingPaneDrop, "the session's end clears the panel's highlight")
    await settle { panel.terminals.tabs(for: panel.target).count == 2 }
    XCTAssertEqual(panel.terminals.tabs(for: panel.target).map(\.id), [opsTab, q1])
  }

  // MARK: Out to standalone

  /// Value: protects=a group's terminal let go between the section's rows becomes a standalone
  /// terminal there with its session (#652 case 3); fails_when=it lands elsewhere, restarts, or
  /// stays in the group; why_new=#652; seam=AppStore.dropRowAsStandalone; no_claim=the List's drop
  func testAGroupsTerminalLetGoBetweenRowsBecomesStandaloneThere() async throws {
    let store = makeStore()
    let a = try standalone(store)
    let session = UUID()
    let (ops, opsTab) = try group(store, "Ops", session: session)
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: ops)))
    XCTAssertEqual(rows, [a, ops])

    let dropped = await store.dropRowAsStandalone(
      .terminal(opsTab, group: ops), before: a.targetID)
    await settle { rows.count == 3 }

    XCTAssertTrue(dropped)
    let made = try XCTUnwrap(rows.first)
    guard case .standalone = made else { return XCTFail("\(made) is not standalone") }
    XCTAssertEqual(rows, [made, a, ops], "above the row it was let go above")
    XCTAssertEqual(tabs(store, made), [opsTab])
    XCTAssertEqual(self.session(store, opsTab, in: made), session)
    XCTAssertEqual(tabs(store, ops).count, 1)
  }

  /// The Quick Terminal's terminals come out to standalone the same way, into the window.
  func testAQuickTerminalsTerminalLetGoBetweenRowsBecomesStandalone() async throws {
    let panel = makePanel()
    let quick = panel.terminals.addTab(for: panel.target)
    let store = makeStore()
    let a = try standalone(store)

    let dropped = await store.dropRowAsStandalone(.terminal(quick.id, group: builtIn), before: nil)
    await settle { rows.count == 2 }

    XCTAssertTrue(dropped)
    let made = try XCTUnwrap(rows.last)
    XCTAssertNotEqual(made, a)
    XCTAssertEqual(tabs(store, made), [quick.id], "at the end, in the window")
    XCTAssertNil(panel.terminals.tab(quick.id, for: panel.target))
  }

  // MARK: The List's drop

  private let s = TargetID.standalone(UUID())
  private let g = SidebarID.terminalGroup(UUID())
  private let h = SidebarID.terminalGroup(UUID())
  private let (g1, g2, h1) = (UUID(), UUID(), UUID())
  /// A standalone terminal, group g with two terminals, then group h with one.
  private var items: [SidebarTerminalsList.Item] {
    [
      .entry(s), .entry(g.targetID!), .terminal(g1, group: g), .terminal(g2, group: g),
      .entry(h.targetID!), .terminal(h1, group: h),
    ]
  }
  private func lands(_ from: Int, _ to: Int) -> SidebarTerminalsList.RowMove {
    SidebarTerminalsList.rowMove(items, from: from, to: to)
  }

  /// Value: protects=a standalone terminal's row let go among a group's terminals joins the group
  /// just above the terminal below the gap; elsewhere it reorders, and a group's row only reorders
  /// (#652 follow-up); fails_when=it lands after the group, or a group row joins a group;
  /// why_new=the owner wants the drop's position to count; seam=SidebarTerminalsList.rowMove;
  /// no_claim=the List calling it
  func testWhereTheListsDropOfAnEntrysRowLands() {
    XCTAssertEqual(lands(0, 3), .joins(g, before: g2), "between g's two terminals")
    XCTAssertEqual(lands(0, 2), .joins(g, before: g1), "above g's first terminal")
    XCTAssertEqual(lands(0, 5), .joins(h, before: h1), "above h's terminal")
    XCTAssertEqual(lands(0, 4), .reorders(before: h.targetID), "below g's last: between rows")
    XCTAssertEqual(lands(0, 6), .reorders(before: nil), "at the end")
    XCTAssertEqual(lands(0, 0), .stays, "in its own place")
    XCTAssertEqual(lands(0, 1), .stays, "just below itself")
    XCTAssertEqual(lands(4, 3), .stays, "a group's row among g's terminals: after g, its place")
    XCTAssertEqual(lands(4, 0), .reorders(before: s))
  }

  /// Value: protects=where the List's drop of a group's terminal row lands: in its own place it
  /// stays, among its own group's terminals it moves to that place, among another group's it
  /// joins that group there, and between top-level rows it becomes standalone above the next one;
  /// fails_when=a drop inside a group makes a standalone, the position is lost, or one between
  /// rows is lost; why_new=#652; seam=SidebarTerminalsList.rowMove; no_claim=the List calling it
  func testWhereTheListsDropOfAGroupsTerminalLands() {
    XCTAssertEqual(lands(2, 2), .stays, "in its own place")
    XCTAssertEqual(lands(2, 3), .stays, "just below itself")
    XCTAssertEqual(lands(3, 2), .joins(g, before: g1), "above its own group's first: it moves")
    XCTAssertEqual(lands(2, 5), .joins(h, before: h1), "among another group's terminals")
    XCTAssertEqual(lands(2, 0), .standalone(before: s), "above the first row")
    XCTAssertEqual(lands(2, 1), .standalone(before: g.targetID), "above its own group")
    XCTAssertEqual(lands(2, 4), .standalone(before: h.targetID), "below its own group")
    XCTAssertEqual(
      lands(3, 4), .standalone(before: h.targetID),
      "its group's last terminal, let go just below it: out of the group")
    XCTAssertEqual(lands(5, 6), .standalone(before: nil), "the last row, let go below the section")
    XCTAssertEqual(lands(2, 6), .standalone(before: nil), "at the end")
  }

  // MARK: A folded group's row

  /// Value: protects=a row let go anywhere on a folded group's row below its top quarter drops on
  /// it, so the terminal joins the group, and its row is highlighted (#652 owner report); an
  /// unfolded group's row, and any other, takes only its middle half; fails_when=a folded group's
  /// lower edge reorders instead, or its top quarter stops reordering above it; why_new=the owner
  /// couldn't drop into a collapsed group; seam=AppStore.groupBand; no_claim=the pointer's hit on
  /// the row's view (TerminalGroupUITests)
  func testAFoldedGroupsRowTakesADropAnywhereBelowItsTopQuarter() {
    // Screen coordinates: y grows up, so the row's top is maxY (140).
    let row = CGRect(x: 0, y: 100, width: 200, height: 40)
    let folded = AppStore.groupBand(of: row, folded: true)
    let open = AppStore.groupBand(of: row)
    for y in [101.0, 105, 115, 120, 125, 129] {
      XCTAssertTrue(folded.contains(CGPoint(x: 50, y: y)), "folded, at y \(y): on the row")
    }
    for y in [131.0, 135, 139] {
      XCTAssertFalse(folded.contains(CGPoint(x: 50, y: y)), "folded, its top quarter at \(y)")
    }
    XCTAssertEqual(open, CGRect(x: 0, y: 110, width: 200, height: 20), "unfolded: the middle half")
    XCTAssertFalse(open.contains(CGPoint(x: 50, y: 105)), "unfolded, its lower edge is a gap")
  }

  /// Value: protects=the List's gap just below a folded group's row, which is also the next row's
  /// top edge, still reorders above that row (the folded row's own lower edge drops on it before
  /// the List moves anything, testAFoldedGroupsRowTakesADropAnywhereBelowItsTopQuarter);
  /// fails_when=that gap joins the folded group, so nothing could go just below it, or just below
  /// the Quick Terminal's row at the section's top; why_new=#652 owner report;
  /// seam=SidebarTerminalsList.rowMove; no_claim=the pointer's position (TerminalGroupUITests)
  func testTheListsGapBelowAFoldedGroupStillReorders() {
    // g is folded: none of its terminals' rows are listed.
    let items: [SidebarTerminalsList.Item] = [
      .entry(.quickTerminal), .entry(s), .entry(g.targetID!), .entry(h.targetID!),
      .terminal(h1, group: h),
    ]
    func lands(_ from: Int, _ to: Int) -> SidebarTerminalsList.RowMove {
      SidebarTerminalsList.rowMove(items, from: from, to: to)
    }
    XCTAssertEqual(lands(1, 3), .reorders(before: h.targetID), "a standalone just below g")
    XCTAssertEqual(lands(4, 3), .standalone(before: h.targetID), "h's terminal just below g")
    XCTAssertEqual(lands(3, 1), .reorders(before: s), "a group's row just below the top")
    XCTAssertEqual(lands(4, 1), .standalone(before: s), "h's terminal at the section's top")
  }
}
