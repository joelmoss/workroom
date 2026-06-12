import Defaults
import XCTest

@testable import Workroom

/// Store-level tests for the always-present workroom tab bar (issue #23): the pure tab-ordering math,
/// the active-set derivation (tabs strictly follow terminal presence), the focused-tab ⇄ selection
/// coupling, and ⌥⌘1–9 tab switching. Drives a real, non-singleton `AppStore` with the terminal
/// factory seam overridden (no live PTY). The drag gesture is covered by manual QA (not unit-testable).
@MainActor
final class WorkroomsViewTests: XCTestCase {

  override func setUp() {
    super.setUp()
    Defaults[.workroomTabOrder] = []
  }

  override func tearDown() {
    Defaults[.workroomTabOrder] = []
    super.tearDown()
  }

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  /// Select `sid` and open a terminal there (the real selection → ⌘T path), so it becomes active.
  private func activate(_ store: AppStore, _ sid: SidebarID) {
    store.selectedTargetID = sid
    store.newTerminalInSelectedTarget()
  }

  // MARK: orderedActiveTargets (pure)

  func testKeepsPersistedOrderAndFiltersInactive() {
    let r = AppStore.orderedActiveTargets(persisted: ["a", "b", "c"], active: ["a", "c"])
    XCTAssertEqual(r, ["a", "c"])
  }

  func testAppendsNewActiveSorted() {
    let r = AppStore.orderedActiveTargets(persisted: ["b"], active: ["b", "a"])
    XCTAssertEqual(r, ["b", "a"])  // b kept from persisted; a (new) appended via sorted extras
  }

  func testInactiveTargetNeverIncluded() {
    // A persisted id with no terminal (not in `active`) drops out — tabs follow terminal presence.
    XCTAssertEqual(AppStore.orderedActiveTargets(persisted: ["a", "b"], active: ["a"]), ["a"])
  }

  func testEmptyActiveIsEmpty() {
    XCTAssertEqual(AppStore.orderedActiveTargets(persisted: ["a"], active: []), [])
  }

  // MARK: activeTargetIDs (terminal presence)

  func testActiveTargetIDsReflectsOpenTerminalsAndDropsOnClose() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!

    XCTAssertFalse(store.terminals.activeTargetIDs.contains(target.id))
    activate(store, a)
    XCTAssertTrue(store.terminals.activeTargetIDs.contains(target.id))

    // Closing the last terminal leaves an empty dict — the non-empty filter must drop it (tab hides).
    let tab = store.terminals.focusedTab(for: target)!
    store.terminals.closeTab(tab.id, for: target)
    XCTAssertFalse(store.terminals.activeTargetIDs.contains(target.id))
  }

  // MARK: orderedWorkroomTargets (resolve)

  func testResolvesActiveTargetsIncludingRoots() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let root = SidebarID.root(project: "/a")
    let wr = SidebarID.workroom(project: "/a", name: "main")
    // The root's fake path reads as "missing", so add its tab directly (the derivation only cares the
    // target has a terminal); the workroom opens normally.
    store.terminals.addTab(for: store.target(for: root)!)
    activate(store, wr)

    let sids = Set(store.orderedWorkroomTargets(order: []).map(\.sid))
    XCTAssertEqual(sids, [root, wr])  // roots are valid tabs (A1)
  }

  func testDropsDeletedWorkroom() {
    let store = makeStore([project("/a", workrooms: ["main", "feature"])])
    let feature = SidebarID.workroom(project: "/a", name: "feature")
    activate(store, feature)
    XCTAssertTrue(store.orderedWorkroomTargets(order: []).contains { $0.sid == feature })

    // Remove the workroom from the project list (its terminal is still live, but it no longer resolves).
    store.projects = [project("/a", workrooms: ["main"])]
    XCTAssertFalse(store.orderedWorkroomTargets(order: []).contains { $0.sid == feature })
  }

  func testEmptiedWorkroomDropsFromTabs() {
    // ⌘W-ing a workroom's last terminal hides its tab immediately (no pinning) — even if it's selected.
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    activate(store, a)
    XCTAssertTrue(store.orderedWorkroomTargets().contains { $0.sid == a })

    store.terminals.closeTab(store.terminals.focusedTab(for: target)!.id, for: target)
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.sid == a },
      "the tab hides when the last terminal closes, even though it's still selected")
    XCTAssertEqual(store.selectedTargetID, a)  // selection itself is unchanged
  }

  // MARK: focusWorkroomTab (⌥⌘1–9)

  func testFocusWorkroomTabSwitchesByIndex() {
    let store = makeStore([project("/a", workrooms: ["main", "feature"])])
    store.workroomTabOrder = [
      TerminalTarget.workroomID(project: "/a", name: "main"),
      TerminalTarget.workroomID(project: "/a", name: "feature"),
    ]
    activate(store, .workroom(project: "/a", name: "main"))
    activate(store, .workroom(project: "/a", name: "feature"))

    let tabs = store.orderedWorkroomTargets()
    XCTAssertEqual(tabs.count, 2)
    XCTAssertTrue(store.focusWorkroomTab(at: 0))
    XCTAssertEqual(store.selectedTargetID, tabs[0].sid)
    XCTAssertTrue(store.focusWorkroomTab(at: 1))
    XCTAssertEqual(store.selectedTargetID, tabs[1].sid)
  }

  func testFocusWorkroomTabOutOfRangeReturnsFalse() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    activate(store, .workroom(project: "/a", name: "main"))
    let before = store.selectedTargetID
    XCTAssertFalse(store.focusWorkroomTab(at: 8), "no Nth tab → not handled, key passes through")
    XCTAssertEqual(store.selectedTargetID, before)
  }

  // MARK: cycleWorkroomTab (⇧⌥⌘←/→, issue #29)

  func testCycleWorkroomTabWrapsBothWays() {
    let store = makeStore([project("/a", workrooms: ["main", "feature"])])
    store.workroomTabOrder = [
      TerminalTarget.workroomID(project: "/a", name: "main"),
      TerminalTarget.workroomID(project: "/a", name: "feature"),
    ]
    activate(store, .workroom(project: "/a", name: "main"))
    activate(store, .workroom(project: "/a", name: "feature"))

    let tabs = store.orderedWorkroomTargets()
    XCTAssertEqual(tabs.count, 2)
    XCTAssertEqual(store.selectedTargetID, tabs[1].sid)  // feature selected (activated last)

    XCTAssertTrue(store.cycleWorkroomTab(forward: true))  // index 1 wraps to 0
    XCTAssertEqual(store.selectedTargetID, tabs[0].sid)
    XCTAssertTrue(store.cycleWorkroomTab(forward: false))  // index 0 wraps to 1
    XCTAssertEqual(store.selectedTargetID, tabs[1].sid)
    XCTAssertTrue(store.cycleWorkroomTab(forward: false))  // 1 → 0
    XCTAssertEqual(store.selectedTargetID, tabs[0].sid)
  }

  func testCycleWorkroomTabSingleTabReturnsFalse() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    activate(store, .workroom(project: "/a", name: "main"))
    let before = store.selectedTargetID
    XCTAssertFalse(
      store.cycleWorkroomTab(forward: true), "one tab → nothing to cycle (no-op)")
    XCTAssertEqual(store.selectedTargetID, before)
  }

  func testCycleWorkroomTabStepsInWhenSelectionNotInBar() {
    // Selection isn't a tab (a root with no terminal): forward steps in at the first tab, back the last.
    let store = makeStore([project("/a", workrooms: ["main", "feature"])])
    store.workroomTabOrder = [
      TerminalTarget.workroomID(project: "/a", name: "main"),
      TerminalTarget.workroomID(project: "/a", name: "feature"),
    ]
    activate(store, .workroom(project: "/a", name: "main"))
    activate(store, .workroom(project: "/a", name: "feature"))
    let tabs = store.orderedWorkroomTargets()

    store.selectedTargetID = .root(project: "/a")  // not in the bar
    XCTAssertTrue(store.cycleWorkroomTab(forward: true))
    XCTAssertEqual(store.selectedTargetID, tabs.first?.sid)

    store.selectedTargetID = .root(project: "/a")
    XCTAssertTrue(store.cycleWorkroomTab(forward: false))
    XCTAssertEqual(store.selectedTargetID, tabs.last?.sid)
  }

  // MARK: cycleTerminalTab (⌥⌘←/→, issue #29)

  func testCycleTerminalTabWrapsBothWays() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    store.selectedTargetID = a
    store.terminals.addTab(for: target)  // tab 0
    store.terminals.addTab(for: target)  // tab 1
    store.terminals.addTab(for: target)  // tab 2 (focused — addTab focuses the new tab)

    let tabs = store.terminals.tabs(for: target)
    XCTAssertEqual(tabs.count, 3)
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, tabs[2].id)

    XCTAssertTrue(store.cycleTerminalTab(forward: true))  // index 2 wraps to 0
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, tabs[0].id)
    XCTAssertTrue(store.cycleTerminalTab(forward: false))  // index 0 wraps to 2
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, tabs[2].id)
    XCTAssertTrue(store.cycleTerminalTab(forward: false))  // 2 → 1
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, tabs[1].id)
  }

  func testCycleTerminalTabSingleTabReturnsFalse() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    activate(store, a)  // one tab
    let target = store.target(for: a)!
    let before = store.terminals.activeTab(for: target)?.id
    XCTAssertFalse(store.cycleTerminalTab(forward: true), "one tab → nothing to cycle")
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, before)
  }

  func testCycleTerminalTabNoSelectionReturnsFalse() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    XCTAssertFalse(store.cycleTerminalTab(forward: true), "no selected target → not handled")
  }

  // MARK: Selecting a workroom does not auto-open a terminal

  func testSelectingWorkroomDoesNotCreateTerminal() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    store.selectedTargetID = a
    store.ensureInitialTerminal(for: target)  // the WorkroomTerminalsView .task path, on mount
    XCTAssertEqual(
      store.terminals.tabCount(forTargetID: target.id), 0,
      "selecting a workroom must not auto-create a terminal")
    XCTAssertTrue(store.orderedWorkroomTargets().isEmpty, "no terminal → no tab")
  }

  // MARK: Run-command interaction (#7)

  func testTargetWithOnlyARunTabIsActive() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let target = store.target(for: .workroom(project: "/a", name: "main"))!
    _ = store.terminals.addRunTab(for: target, command: "echo hi", cwd: target.path)
    XCTAssertTrue(store.terminals.activeTargetIDs.contains(target.id))
    XCTAssertEqual(
      store.orderedWorkroomTargets(order: []).map(\.sid),
      [.workroom(project: "/a", name: "main")])
  }
}
