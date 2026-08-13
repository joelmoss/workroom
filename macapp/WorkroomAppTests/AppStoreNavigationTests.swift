import XCTest

@testable import Workroom

/// End-to-end back/forward tests (issue #26) driving a real, non-singleton `AppStore` (D4): inject
/// `projects`, override the terminal factory seam, and exercise the real recording + navigation
/// paths. Covers the store-level logic; the menu/`focusedSceneValue` wiring (which uses
/// `AppStore.shared`) is verified manually.
@MainActor
final class AppStoreNavigationTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    // A GhosttySurfaceView only spawns its PTY once it enters a window, so this is inert in tests.
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

  private func focused(_ store: AppStore, _ sid: SidebarID) -> UUID? {
    store.terminals.focusedTab(for: store.target(for: sid)!)?.id
  }

  /// The issue #26 acceptance example, end-to-end through the store.
  func testIssueExampleEndToEnd() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")

    let t1 = addTerminal(store, a)  // Terminal 1 of A
    let tNew = addTerminal(store, a)  // new terminal in A
    addTerminal(store, b)  // a terminal in B (we switch to it)

    XCTAssertEqual(store.history.entries.count, 3)

    store.navigateBack()
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(focused(store, a), tNew)

    store.navigateBack()
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(focused(store, a), t1)

    store.navigateForward()
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(focused(store, a), tNew)
  }

  /// Restore-like selection (set before any terminal exists) records nothing; the first entry
  /// appears when the first terminal is created (Codex #3).
  func testFirstEntryRecordedAtTerminalCreationNotAtSelection() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")

    store.selectedTargetID = a  // like a launch restore — no terminal yet
    XCTAssertTrue(store.history.entries.isEmpty)

    store.newTerminalInSelectedTarget()
    XCTAssertEqual(store.history.entries.count, 1)
    XCTAssertEqual(store.history.current?.target, a)
  }

  /// Back/forward replay must not append history entries.
  func testReplayDoesNotAppendEntry() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    addTerminal(store, a)
    addTerminal(store, b)
    let count = store.history.entries.count

    store.navigateBack()
    store.navigateForward()
    XCTAssertEqual(store.history.entries.count, count)
  }

  /// A notification/openTerminal jump records exactly one entry — no phantom intermediate (D1). The
  /// cursor is on B when we jump into A, so the old "didSet records A's prior tab, then select
  /// records the target tab" path would have appended two.
  func testOpenTerminalRecordsSingleEntryNoPhantom() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    let targetA = store.target(for: a)!
    let t1 = addTerminal(store, a)
    addTerminal(store, a)  // A.focused = t2
    addTerminal(store, b)  // now viewing B; A's focus stays on t2
    let before = store.history.entries.count

    store.openTerminal(targetID: targetA.id, tabID: t1)
    XCTAssertEqual(
      store.history.entries.count, before + 1, "openTerminal must record exactly one entry")
    XCTAssertEqual(store.history.current?.tab, t1)
    XCTAssertEqual(focused(store, a), t1)
  }

  /// Closing the focused tab makes its neighbour current (D6); the closed entry is pruned and the
  /// exposed duplicate collapses, so here history reduces to a single live entry.
  func testClosingFocusedTabRecordsSuccessorThenPrunesClosed() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    let t1 = addTerminal(store, a)
    let t2 = addTerminal(store, a)  // focused; history [t1, t2]

    store.terminals.closeTab(t2, for: targetA)
    XCTAssertEqual(focused(store, a), t1)
    XCTAssertEqual(store.history.current?.tab, t1)
    XCTAssertFalse(store.canGoBack)  // collapsed to [t1] — honestly nothing to go back to
  }

  /// Closing a non-focused tab prunes its history entry; Back then lands on the previous live one.
  func testClosingNonFocusedTabPrunesEntry() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    let t1 = addTerminal(store, a)
    let t2 = addTerminal(store, a)
    addTerminal(store, a)  // t3 focused; history [t1, t2, t3]
    XCTAssertEqual(store.history.entries.count, 3)

    store.terminals.closeTab(t2, for: targetA)  // non-focused → prune (a, t2)
    XCTAssertEqual(store.history.entries.count, 2)
    store.navigateBack()
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(focused(store, a), t1)
  }

  /// Honest enablement: closing the only back entry's tab disables Back immediately (no no-op).
  func testClosingBackTabDisablesBackHonestly() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    let t1 = addTerminal(store, a)
    addTerminal(store, a)  // t2 focused; history [t1, t2]
    XCTAssertTrue(store.canGoBack)

    store.terminals.closeTab(t1, for: targetA)  // close the back entry's tab
    XCTAssertFalse(store.canGoBack)
  }

  /// A gone workroom's entries are skipped (isLive resolves the target against live projects).
  func testNavigateSkipsDeletedWorkroomEntry() async {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    let t1 = addTerminal(store, a)
    addTerminal(store, b)  // history [(a,t1), (b,tB)], cursor on B

    // Simulate a delete without the CLI: reap B's terminals and drop it from the project list.
    await store.terminals.reap(store.target(for: b)!.id)
    store.projects = [project("/a", workrooms: ["main"])]

    store.navigateBack()  // (a,t1) is the only live earlier entry
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(focused(store, a), t1)
  }

  /// Back/forward are no-ops at the ends and leave the location untouched.
  func testNavigateNoOpAtBoundaries() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let t1 = addTerminal(store, a)

    XCTAssertFalse(store.canGoBack)
    XCTAssertFalse(store.canGoForward)
    store.navigateBack()
    store.navigateForward()
    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(focused(store, a), t1)
  }
}
