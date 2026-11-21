import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Where a window's selection goes when the selected terminal outside any project closes and its
/// row goes with it (#652): a standalone terminal, or a group's last terminal. It goes to the
/// previous place this window showed that still has terminals here (back/forward history), else
/// the nearest row above in the Terminals section with terminals here, else the nearest below.
/// With none of those it does what it did before: the rightmost title-bar tab, or nothing.
@MainActor
final class TerminalCloseSelectionTests: XCTestCase {
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
    return store
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  /// Opens a standalone terminal just below the selected row, and returns its row.
  private func openStandalone(_ store: AppStore) throws -> SidebarID {
    store.newStandaloneTerminal()
    return try XCTUnwrap(store.selectedTargetID)
  }

  /// Three standalone terminals, listed A, B, C.
  private func threeStandalones(_ store: AppStore) throws -> (SidebarID, SidebarID, SidebarID) {
    let a = try openStandalone(store)
    let b = try openStandalone(store)
    let c = try openStandalone(store)
    XCTAssertEqual(rows, [a, b, c])
    return (a, b, c)
  }

  private func focusedTab(_ store: AppStore, _ sid: SidebarID) -> TerminalTab.ID? {
    store.target(for: sid).flatMap { store.terminals.focusedTab(for: $0)?.id }
  }

  // MARK: The previous place

  /// Value: protects=closing a standalone terminal lands on the one you were in before it;
  /// fails_when=the selection is left on the closed row (nothing selected) or goes to its
  /// neighbour; why_new=#652 critique; seam=AppStore; no_claim=first responder (the UI test)
  func testClosingAStandaloneTerminalSelectsTheLastSelectedTerminal() throws {
    let store = makeStore()
    let (a, b, c) = try threeStandalones(store)
    store.selectedTargetID = a
    store.selectedTargetID = c

    store.closeCurrentTerminalTab()

    XCTAssertEqual(rows, [a, b])
    XCTAssertEqual(store.selectedTargetID, a, "the previous terminal, not the row above (B)")
    XCTAssertNil(store.selectedProjectID)
    XCTAssertNotNil(focusedTab(store, a), "its terminal is the focused one")
    XCTAssertTrue(store.selectionHasTabs)
  }

  /// "Previous" is any place this window showed, a workroom too.
  func testThePreviousPlaceCanBeAWorkroom() throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.newTerminalInSelectedTarget()
    let a = try openStandalone(store)
    let b = try openStandalone(store)
    store.selectedTargetID = workroom
    store.selectedTargetID = b

    store.closeCurrentTerminalTab()

    XCTAssertEqual(rows, [a])
    XCTAssertEqual(store.selectedTargetID, workroom)
  }

  /// A previous place whose terminals have all closed since is skipped.
  func testAPreviousPlaceWithNoTerminalsLeftIsSkipped() throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.newTerminalInSelectedTarget()
    let a = try openStandalone(store)
    let b = try openStandalone(store)
    store.selectedTargetID = workroom
    store.closeCurrentTerminalTab()  // the workroom's only terminal
    store.selectedTargetID = b

    store.closeCurrentTerminalTab()

    XCTAssertEqual(store.selectedTargetID, a)
  }

  // MARK: The row above, then below

  /// Value: protects=with no history to go by, the row above is next; fails_when=nothing is
  /// selected; why_new=#652 critique; seam=AppStore; no_claim=history (above)
  func testWithNoPreviousPlaceTheRowAboveIsSelected() throws {
    let store = makeStore()
    let (a, b, c) = try threeStandalones(store)
    store.selectedTargetID = b
    store.history = NavigationHistory()

    store.closeCurrentTerminalTab()

    XCTAssertEqual(rows, [a, c])
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertNotNil(focusedTab(store, a))
  }

  func testTheTopRowFallsToTheRowBelow() throws {
    let store = makeStore()
    let (a, b, c) = try threeStandalones(store)
    store.selectedTargetID = a
    store.history = NavigationHistory()

    store.closeCurrentTerminalTab()

    XCTAssertEqual(rows, [b, c])
    XCTAssertEqual(store.selectedTargetID, b)
  }

  /// A row with no terminal in this window (another window's standalone terminal) is passed over.
  func testARowAnotherWindowHoldsIsPassedOver() throws {
    let store = makeStore()
    let other = makeStore()
    let b = try openStandalone(other)
    let c = try openStandalone(store)
    let a = try openStandalone(store)
    XCTAssertEqual(rows, [b, c, a])
    store.selectedTargetID = c
    store.history = NavigationHistory()

    store.closeCurrentTerminalTab()

    XCTAssertEqual(rows, [b, a])
    XCTAssertEqual(store.selectedTargetID, a, "B above is the other window's")
  }

  // MARK: A group's last terminal

  /// Value: protects=closing a group's last terminal deletes it and lands on the previous terminal;
  /// fails_when=the selection goes to the rightmost title-bar tab, or to nothing; why_new=#652
  /// critique; seam=AppStore + the regroup queue; no_claim=a group with terminals left (below)
  func testClosingAGroupsLastTerminalSelectsThePreviousTerminal() async throws {
    let store = makeStore()
    let a = try openStandalone(store)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    let c = try openStandalone(store)
    XCTAssertEqual(rows, [a, group, c])
    // C is the rightmost title-bar tab, where the selection used to go.
    store.workroomTabOrder = [a, group, c].compactMap(\.targetID)
    store.selectedTargetID = a
    store.selectedTargetID = group

    store.closeCurrentTerminalTab()
    await section.regroupsSettled()

    XCTAssertEqual(rows, [a, c], "the group goes with its last terminal")
    XCTAssertEqual(store.selectedTargetID, a, "not C, the rightmost title-bar tab")
  }

  func testClosingAGroupsLastTerminalFallsToTheRowAbove() async throws {
    let store = makeStore()
    let a = try openStandalone(store)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    let c = try openStandalone(store)
    store.workroomTabOrder = [a, group, c].compactMap(\.targetID)
    store.selectedTargetID = group
    store.history = NavigationHistory()

    store.closeCurrentTerminalTab()
    await section.regroupsSettled()

    XCTAssertEqual(rows, [a, c])
    XCTAssertEqual(store.selectedTargetID, a)
  }

  /// Closing one of a group's terminals, with others left, stays in the group on its neighbour.
  func testClosingOneOfAGroupsTerminalsStaysInTheGroup() async throws {
    let store = makeStore()
    _ = try openStandalone(store)
    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    let target = try XCTUnwrap(store.target(for: group))
    store.newTerminalInGroup(group)
    let tabs = store.terminals.tabs(for: target).map(\.id)
    XCTAssertEqual(tabs.count, 2)

    store.closeCurrentTerminalTab()
    await section.regroupsSettled()

    XCTAssertEqual(store.selectedTargetID, group)
    XCTAssertEqual(store.terminals.tabs(for: target).map(\.id), [tabs[0]])
    XCTAssertEqual(focusedTab(store, group), tabs[0])
  }

  // MARK: What stays as it was

  /// With no other terminal anywhere, the selection does what it did: nothing to land on.
  func testTheLastTerminalLeavesNothingSelected() throws {
    let store = makeStore()
    _ = try openStandalone(store)

    store.closeCurrentTerminalTab()

    XCTAssertTrue(rows.isEmpty)
    XCTAssertNil(store.liveSelection(store.selectedTargetID, in: projects.projects))
  }

  func testClosingAnUnselectedStandaloneTerminalLeavesTheSelection() throws {
    let store = makeStore()
    let (a, b, c) = try threeStandalones(store)
    store.selectedTargetID = b
    let target = try XCTUnwrap(store.target(for: c))
    let tab = try XCTUnwrap(store.terminals.tabs(for: target).first?.id)

    store.requestCloseTerminalTab(tab, for: target)

    XCTAssertEqual(rows, [a, b])
    XCTAssertEqual(store.selectedTargetID, b)
  }

  /// A workroom's last terminal still falls to the rightmost title-bar tab (#80).
  func testAWorkroomsLastTerminalStillFallsToTheRightmostTab() throws {
    let store = makeStore()
    let a = try openStandalone(store)
    store.selectedTargetID = workroom
    store.newTerminalInSelectedTarget()
    store.selectedTargetID = a
    store.selectedTargetID = workroom

    store.closeCurrentTerminalTab()

    XCTAssertEqual(store.selectedTargetID, a)
  }
}
