import WorkroomDomain
import XCTest

@testable import Workroom

/// Store-level tests for the sidebar terminal subtree (issue #30): the per-target expand flag, the
/// reveal action, and the close-below-2 prune. Mirrors `AppStoreNavigationTests`' harness — a real,
/// non-singleton `AppStore` with the terminal factory seam overridden (a `GhosttySurfaceView` only
/// spawns its PTY once it enters a window, so it's inert here). The view wiring is verified manually.
@MainActor
final class TerminalDisclosureTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
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

  /// Select `sid` and open a fresh terminal there (the real ⌘T path); return the new tab's id.
  @discardableResult
  private func addTerminal(_ store: AppStore, _ sid: SidebarID) -> UUID {
    store.selectedTargetID = sid
    store.newTerminalInSelectedTarget()
    return store.terminals.focusedTab(for: store.target(for: sid)!)!.id
  }

  // MARK: Expansion flag

  /// Terminals are collapsed by default — the expand set starts empty (issue #30).
  func testTerminalsCollapsedByDefault() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let target = store.target(for: .workroom(project: "/a", name: "main"))!
    XCTAssertTrue(store.expandedTerminalTargets.isEmpty)
    XCTAssertFalse(store.isTerminalsExpanded(target.id))
  }

  /// `toggleTerminals` flips the flag both ways.
  func testToggleTerminalsFlips() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let target = store.target(for: .workroom(project: "/a", name: "main"))!

    store.toggleTerminals(for: target.id)
    XCTAssertTrue(store.isTerminalsExpanded(target.id))

    store.toggleTerminals(for: target.id)
    XCTAssertFalse(store.isTerminalsExpanded(target.id))
  }

  // MARK: tabCount

  func testTabCountReflectsLiveTabs() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!

    XCTAssertEqual(store.terminals.tabCount(forTargetID: target.id), 0)
    addTerminal(store, a)
    addTerminal(store, a)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: target.id), 2)
  }

  // MARK: revealTerminal

  /// Tapping a terminal row selects its target and focuses that terminal, recording exactly one
  /// history entry — no phantom intermediate (it reuses the `applyLocation` primitive). Cursor is on
  /// B when we reveal a tab in A, the case that would otherwise double-record.
  func testRevealTerminalSelectsFocusesAndRecordsSingleEntry() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    let t1 = addTerminal(store, a)
    addTerminal(store, a)  // A.focused = t2
    addTerminal(store, b)  // now viewing B; A's focus stays on t2
    let before = store.history.entries.count

    store.revealTerminal(t1, at: a)

    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(store.terminals.focusedTab(for: store.target(for: a)!)?.id, t1)
    XCTAssertEqual(
      store.history.entries.count, before + 1, "revealTerminal must record exactly one entry")
    XCTAssertEqual(store.history.current?.tab, t1)
  }

  // MARK: Close-below-2 prune

  /// Closing a tab so a target drops below the 2-tab disclosure threshold collapses its subtree, so a
  /// stale expand flag can't auto-reveal later.
  func testClosingBelowTwoTabsCollapsesSubtree() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    let t1 = addTerminal(store, a)
    addTerminal(store, a)  // 2 tabs
    store.toggleTerminals(for: target.id)
    XCTAssertTrue(store.isTerminalsExpanded(target.id))

    store.terminals.closeTab(t1, for: target)  // drops to 1 tab
    XCTAssertFalse(store.isTerminalsExpanded(target.id))
  }

  /// Closing a tab while ≥2 remain leaves the subtree expanded.
  func testClosingAboveTwoTabsStaysExpanded() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    let t1 = addTerminal(store, a)
    addTerminal(store, a)
    addTerminal(store, a)  // 3 tabs
    store.toggleTerminals(for: target.id)

    store.terminals.closeTab(t1, for: target)  // 2 tabs remain
    XCTAssertTrue(store.isTerminalsExpanded(target.id))
  }
}
