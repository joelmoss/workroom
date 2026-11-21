import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Unnamed terminal groups (#659, ADR 0077): splitting a standalone terminal, or dropping one
/// standalone terminal's row on another's, makes an unnamed group in its place, labelled by its
/// terminals' names; once it is down to one terminal across every window it dissolves back into a
/// standalone terminal there. A name keeps a group, and clearing it lets the rule apply again.
@MainActor
final class UnnamedTerminalGroupTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  /// Every retag of a moved terminal's session, in order: (session, tag).
  private var retags: [(UUID, String)] = []
  private var retagSucceeds = true

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
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { [weak self] session, tag in
        guard let self, self.retagSucceeds else { return false }
        self.retags.append((session, tag))
        return true
      })
    return store
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  private func tabs(_ store: AppStore, _ sid: SidebarID) -> [TerminalTab.ID] {
    store.target(for: sid).map { store.terminals.tabs(for: $0).map(\.id) } ?? []
  }

  /// A standalone terminal in `store`, selected, whose one terminal has session `session`.
  private func standalone(_ store: AppStore, session: UUID = UUID()) throws -> SidebarID {
    let anchor = store.selectedTargetID?.targetID
    let sid = try XCTUnwrap(section.addStandalone(after: anchor).sidebarID)
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: sid)), sessionID: session)
    store.selectedTargetID = sid
    return sid
  }

  private func isStandalone(_ sid: SidebarID?) -> Bool {
    if case .standalone = sid { return true }
    return false
  }

  private func isUnnamedGroup(_ sid: SidebarID?) -> Bool {
    guard case .terminalGroup = sid, let id = sid?.targetID, let group = section.group(id)
    else { return false }
    return group.name == nil
  }

  private func settle() async { await section.regroupsSettled() }

  // MARK: ⌘D

  /// Value: protects=⌘D on a standalone terminal makes an unnamed group in its place, and closing
  /// one half returns exactly to one standalone terminal there (stories 19–20); fails_when=the
  /// split happens in place, the group lands elsewhere in the section or the title bar, the
  /// session keeps the old tag, or the close leaves a one-terminal group behind; why_new=#659;
  /// seam=AppStore over a shared section; no_claim=the row's drawing
  func testSplittingAStandaloneTerminalMakesAGroupAndClosingAHalfReturnsToTheStart() async throws {
    let store = makeStore()
    let a = try standalone(store)
    let session = UUID()
    let s = try standalone(store, session: session)
    let b = try standalone(store)
    store.selectedTargetID = s
    let original = try XCTUnwrap(tabs(store, s).first)
    let titleBar = store.orderedWorkroomTargets().map(\.sid)
    XCTAssertEqual(rows, [a, s, b])
    let middle = try XCTUnwrap(titleBar.firstIndex(of: s))

    store.splitFocusedRight()
    await settle()

    let group = try XCTUnwrap(store.selectedTargetID)
    XCTAssertTrue(isUnnamedGroup(group), "\(group) is an unnamed group")
    XCTAssertEqual(rows, [a, group, b], "in the standalone terminal's place")
    XCTAssertEqual(tabs(store, group).count, 2)
    XCTAssertEqual(tabs(store, group).first, original, "the same terminal, then the new one")
    XCTAssertTrue(tabs(store, s).isEmpty)
    XCTAssertEqual(store.orderedWorkroomTargets().map(\.sid)[middle], group, "same title-bar slot")
    XCTAssertEqual(store.orderedWorkroomTargets().count, titleBar.count)
    XCTAssertEqual(retags.map(\.0), [session])
    XCTAssertEqual(retags.map(\.1), [try XCTUnwrap(group.targetID).encoded])
    let names = section.terminalNames(of: try XCTUnwrap(group.targetID))
    XCTAssertEqual(store.target(for: group)?.title, "\(names[0]) + 1 more")
    XCTAssertEqual(names.count, 2, "two terminals")

    store.closeCurrentTerminalTab()
    await settle()

    let back = try XCTUnwrap(store.selectedTargetID)
    XCTAssertTrue(isStandalone(back), "\(back) is standalone again")
    XCTAssertEqual(rows, [a, back, b], "in the group's place")
    XCTAssertEqual(tabs(store, back), [original], "the terminal that stayed")
    XCTAssertNil(section.group(try XCTUnwrap(group.targetID)), "the group has gone")
    XCTAssertEqual(store.orderedWorkroomTargets().map(\.sid)[middle], back)
    XCTAssertEqual(store.orderedWorkroomTargets().count, titleBar.count)
    XCTAssertEqual(retags.last?.0, session)
    XCTAssertEqual(retags.last?.1, try XCTUnwrap(back.targetID).encoded)
  }

  /// ⌘⇧D, and a pane's own split, convert as ⌘D does.
  func testEverySplitOfAStandaloneTerminalMakesAGroup() async throws {
    let store = makeStore()
    let s = try standalone(store)
    let tab = try XCTUnwrap(tabs(store, s).first)

    store.splitFocusedDown()
    await settle()
    let group = try XCTUnwrap(store.selectedTargetID)
    XCTAssertTrue(isUnnamedGroup(group))
    XCTAssertEqual(tabs(store, group).count, 2)

    let t = try standalone(store)
    let target = try XCTUnwrap(store.target(for: t))
    store.terminals.splitTab(try XCTUnwrap(tabs(store, t).first), on: .right, for: target)
    await settle()
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows.allSatisfy(isUnnamedGroup))
    XCTAssertEqual(tabs(store, group).first, tab)
  }

  /// The old id is rewritten to the group wherever this window had it: a side-by-side split and
  /// the back/forward history.
  func testTheGroupTakesTheStandaloneTerminalsPlaceInASplitAndHistory() async throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.ensureInitialTerminal(for: try XCTUnwrap(store.selectedTarget))
    let s = try standalone(store)
    let tab = try XCTUnwrap(tabs(store, s).first)
    store.selectedTargetID = workroom
    XCTAssertTrue(store.insertWorkroomSplit(s, beside: workroom, edge: .right))
    store.selectedTargetID = s
    store.recordCurrentLocation()
    XCTAssertTrue(store.history.entries.contains { $0.target == s })

    store.splitFocusedRight()
    await settle()

    let group = try XCTUnwrap(store.selectedTargetID)
    XCTAssertTrue(isUnnamedGroup(group))
    XCTAssertTrue(store.workroomSplits.contains { $0.contains(group) }, "in the split")
    XCTAssertFalse(store.workroomSplits.contains { $0.contains(s) })
    XCTAssertTrue(store.workroomSplits.contains { $0.contains(workroom) })
    XCTAssertFalse(store.history.entries.contains { $0.target == s })
    XCTAssertTrue(store.history.entries.contains { $0.target == group && $0.tab == tab })
  }

  /// A terminal whose session can't be retagged isn't moved, and nothing is split.
  func testAStandaloneTerminalThatCannotMoveStaysAndDoesNotSplit() async throws {
    let store = makeStore()
    let s = try standalone(store)
    retagSucceeds = false

    store.splitFocusedRight()
    await settle()

    XCTAssertEqual(rows, [s])
    XCTAssertEqual(store.selectedTargetID, s)
    XCTAssertEqual(tabs(store, s).count, 1)
  }

  /// ⌘D in a workroom splits in place, as it always has.
  func testSplittingAWorkroomIsUnchanged() async throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.ensureInitialTerminal(for: try XCTUnwrap(store.selectedTarget))

    store.splitFocusedRight()
    await settle()

    XCTAssertTrue(rows.isEmpty)
    XCTAssertEqual(tabs(store, workroom).count, 2)
  }

  // MARK: Counting across windows

  /// Value: protects=an unnamed group counts its terminals across every window before it goes
  /// (story 27), and the terminal left becomes standalone in the window that holds it;
  /// fails_when=one window's close dissolves a group another window still has terminals in, or
  /// the survivor's window isn't the one given the standalone terminal; why_new=#659;
  /// seam=two AppStores over one section; no_claim=raising the holder
  func testAnUnnamedGroupCountsItsTerminalsAcrossWindows() async throws {
    let first = makeStore()
    let second = makeStore()
    _ = try standalone(first)
    first.splitFocusedRight()
    await settle()
    let group = try XCTUnwrap(first.selectedTargetID)
    XCTAssertTrue(isUnnamedGroup(group))
    second.selectedTargetID = group
    second.ensureInitialTerminal(for: try XCTUnwrap(second.selectedTarget))
    let survivor = try XCTUnwrap(tabs(second, group).first)

    first.closeCurrentTerminalTab()
    await settle()
    XCTAssertEqual(rows, [group], "two terminals left, one in each window: still a group")

    first.closeCurrentTerminalTab()
    await settle()

    let back = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(isStandalone(back))
    XCTAssertEqual(tabs(second, back), [survivor], "standalone in the window that holds it")
    XCTAssertTrue(tabs(first, back).isEmpty)
    XCTAssertEqual(second.selectedTargetID, back)
  }

  /// A window closing takes its terminals out of the count.
  func testClosingAWindowCountsItsGroupTerminalsOut() async throws {
    let first = makeStore()
    var second: AppStore? = makeStore()
    _ = try standalone(first)
    first.splitFocusedRight()
    await settle()
    let group = try XCTUnwrap(first.selectedTargetID)
    second?.selectedTargetID = group
    second?.ensureInitialTerminal(for: try XCTUnwrap(second?.selectedTarget))
    first.closeCurrentTerminalTab()
    await settle()
    XCTAssertEqual(rows, [group])

    await second?.endStandaloneTerminalsOnClose()
    second = nil
    await settle()

    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(isStandalone(rows.first))
    XCTAssertEqual(first.selectedTargetID, rows.first)
  }

  // MARK: Dropping a row on a row

  /// Value: protects=dropping one standalone terminal's row on another's makes an unnamed group
  /// of the two in the destination's place (story 21); fails_when=either terminal is lost, the
  /// dropped row stays, or the order of their tabs is wrong; why_new=#659; seam=AppStore;
  /// no_claim=the drag gesture
  func testDroppingAStandaloneRowOnAnotherMakesAGroup() async throws {
    let store = makeStore()
    let a = try standalone(store)
    let b = try standalone(store)
    let c = try standalone(store)
    let aTab = try XCTUnwrap(tabs(store, a).first)
    let cTab = try XCTUnwrap(tabs(store, c).first)
    store.selectedTargetID = c

    store.dropStandalone(c, onto: a)
    await settle()

    let group = try XCTUnwrap(rows.first)
    XCTAssertTrue(isUnnamedGroup(group))
    XCTAssertEqual(rows, [group, b])
    XCTAssertEqual(tabs(store, group), [aTab, cTab], "the dropped terminal joins second")
    XCTAssertEqual(store.selectedTargetID, group)
    XCTAssertEqual(store.orderedWorkroomTargets().map(\.sid).filter { $0 == group }.count, 1)
  }

  /// Each terminal stays in the window that holds it; the group spans both.
  func testDroppingARowHeldByAnotherWindowGroupsAcrossWindows() async throws {
    let first = makeStore()
    let second = makeStore()
    let a = try standalone(first)
    let b = try standalone(second)

    second.dropStandalone(b, onto: a)
    await settle()

    let group = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(isUnnamedGroup(group))
    XCTAssertEqual(tabs(first, group).count, 1)
    XCTAssertEqual(tabs(second, group).count, 1)
    XCTAssertEqual(first.selectedTargetID, group)
    XCTAssertEqual(second.selectedTargetID, group)
  }

  /// Dropping a row on itself, or on a group, makes nothing here.
  func testDroppingARowOnItselfDoesNothing() async throws {
    let store = makeStore()
    let a = try standalone(store)

    store.dropStandalone(a, onto: a)
    await settle()

    XCTAssertEqual(rows, [a])
  }

  /// Value: protects=a standalone terminal's row dropped on another's groups them, the drag
  /// gesture's model (#659 AC 2), and a group's row is somewhere it joins instead (#652);
  /// fails_when=a row groups with itself, or a drop on a group's row is refused;
  /// why_new=#659 left the gesture open; seam=AppStore; no_claim=hit-testing the pointer.
  func testAStandaloneRowDropsOnAnotherStandaloneRowToGroupThem() async throws {
    let store = makeStore()
    let a = try standalone(store)
    let b = try standalone(store)
    let named = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))

    XCTAssertTrue(store.canDropRow(.standalone(b), onto: a))
    XCTAssertFalse(store.canDropRow(.standalone(a), onto: a))
    XCTAssertTrue(store.canDropRow(.standalone(a), onto: named), "it joins the group (#652)")

    let dropped = await store.dropRow(.standalone(b), onto: a)
    XCTAssertTrue(dropped)
    await settle()

    XCTAssertTrue(isUnnamedGroup(rows.first))
    XCTAssertEqual(rows.count, 2)
  }

  // MARK: Names

  /// Value: protects=a name keeps a group, and clearing it makes the group unnamed again,
  /// dissolving at once when it holds one terminal (story 25); fails_when=a cleared one-terminal
  /// group stays, or a cleared two-terminal group goes; why_new=#659; seam=AppStore;
  /// no_claim=the inline field
  func testClearingANameMakesTheGroupUnnamedAgain() async throws {
    let store = makeStore()
    let named = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    let one = try XCTUnwrap(tabs(store, named).first)
    await settle()
    XCTAssertEqual(rows, [named], "named, it stays with one terminal")

    store.renameTerminalGroup(named, to: "  ")
    await settle()

    let back = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(isStandalone(back), "one terminal: it dissolves at once")
    XCTAssertEqual(tabs(store, back), [one])
    XCTAssertEqual(store.selectedTargetID, back)
  }

  func testClearingANameOfAGroupWithTwoTerminalsKeepsItUnnamed() async throws {
    let store = makeStore()
    let sid = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    store.newTerminalInSelectedTarget()

    store.renameTerminalGroup(sid, to: "")
    await settle()

    XCTAssertEqual(rows, [sid])
    XCTAssertTrue(isUnnamedGroup(sid))
    let target = try XCTUnwrap(store.target(for: sid))
    let first = TerminalState.programAndFolder(
      program: TerminalState.shellName, folder: target.path
    ).text
    XCTAssertEqual(target.title, "\(first) + 1 more")

    store.renameTerminalGroup(sid, to: "Servers")
    store.closeCurrentTerminalTab()
    await settle()
    XCTAssertEqual(rows, [sid], "named again, it keeps")
  }

  func testClearingANameOfAnEmptyGroupRemovesIt() async throws {
    let store = makeStore()
    let sid = try XCTUnwrap(section.addGroup(named: "Ops").sidebarID)

    store.renameTerminalGroup(sid, to: "")
    await settle()

    XCTAssertTrue(rows.isEmpty)
  }

  // MARK: The launch prune

  /// Value: protects=the launch's prune of rows nothing restored applies the unnamed rule: none
  /// held goes, one held becomes standalone; fails_when=an empty unnamed group lingers, or a
  /// one-terminal one stays a group; why_new=#659 over #658's prune; seam=the section with a
  /// registered window; no_claim=ending the pruned sessions
  func testTheLaunchPruneSettlesUnnamedGroups() async throws {
    let store = makeStore()
    let empty = try XCTUnwrap(section.addGroup(named: nil).sidebarID)
    let one = try XCTUnwrap(section.addGroup(named: nil).sidebarID)
    let tab = store.terminals.addTab(for: try XCTUnwrap(store.target(for: one))).id
    let two = try XCTUnwrap(section.addGroup(named: nil).sidebarID)
    for _ in 0..<2 { _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: two))) }

    let pruned = section.pruneUnheld()
    await settle()

    XCTAssertEqual(pruned, [empty.targetID].compactMap { $0 })
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(isStandalone(rows.first))
    XCTAssertEqual(tabs(store, try XCTUnwrap(rows.first)), [tab])
    XCTAssertEqual(rows.last, two)
  }
}
