import XCTest

@testable import Workroom

/// Pins ⌘F/⌘G dispatch across ALL tab-content kinds through `AppStore.contentFind` — the single
/// shared `FileFindModel` (eng review decision, 2026-09-01) `startFindInFocusedPane`/
/// `navigateFocusedPaneSearch`/`onFocusChange` route through. Covers the pre-existing `.terminal`/
/// `.file` paths (UNTESTED before this plan, despite being live production code) alongside the new
/// `.diff`/`.changeset` cases — the Iron Rule regression guard for modifying both dispatch functions.
@MainActor
final class AppStoreContentFindTests: XCTestCase {

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

  @discardableResult
  private func addTerminal(_ store: AppStore, _ sid: SidebarID) -> UUID {
    store.selectedTargetID = sid
    store.newTerminalInSelectedTarget()
    return store.terminals.focusedTab(for: store.target(for: sid)!)!.id
  }

  func testTerminalFocusedStartsSurfaceSearch() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    addTerminal(store, a)

    let surface = store.terminals.focusedTab(for: target)!.surface!
    XCTAssertFalse(surface.searchModel.isActive)
    store.startFindInFocusedPane()
    XCTAssertTrue(surface.searchModel.isActive)
  }

  func testFileFocusedOpensContentFind() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)
    store.openFilePreview(path: "README.md")

    XCTAssertFalse(store.contentFind.isOpen)
    store.startFindInFocusedPane()
    XCTAssertTrue(store.contentFind.isOpen)
  }

  func testDiffFocusedOpensContentFind() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)

    XCTAssertFalse(store.contentFind.isOpen)
    store.startFindInFocusedPane()
    XCTAssertTrue(store.contentFind.isOpen)
  }

  func testChangesetFocusedOpensContentFind() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)
    store.openChangesetPreview(commitID: "abc123", title: "abc123")

    XCTAssertFalse(store.contentFind.isOpen)
    store.startFindInFocusedPane()
    XCTAssertTrue(store.contentFind.isOpen)
  }

  func testNavigateStepsContentFindWhenDiffFocusedWithMatches() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)

    store.contentFind.setSource(["foo", "foo foo"])
    store.contentFind.open()
    store.contentFind.setNeedle("foo")
    XCTAssertEqual(store.contentFind.current, 0)

    XCTAssertTrue(store.navigateFocusedPaneSearch(forward: true))
    XCTAssertEqual(store.contentFind.current, 1)
  }

  /// Defence-in-depth: a stale open `contentFind` (left behind from a PREVIOUS content pane — the
  /// model is shared) must not leak into a focused terminal pane just because it happens to be open
  /// with matches.
  func testNavigateReturnsFalseWhenTerminalFocusedEvenIfContentFindHasMatches() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)

    store.contentFind.setSource(["foo"])
    store.contentFind.open()
    store.contentFind.setNeedle("foo")

    XCTAssertFalse(store.navigateFocusedPaneSearch(forward: true))
  }

  func testFocusChangeClosesContentFind() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let target = store.target(for: a)!
    let terminalTabID = addTerminal(store, a)
    // Persistent (not preview), so it's a genuinely separate tab from the terminal — a real focus
    // change, not a same-tab retarget (which must NOT close find, per the review's changeset-file-
    // switch behavior).
    store.openDiffPersistent(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.startFindInFocusedPane()
    XCTAssertTrue(store.contentFind.isOpen)

    store.terminals.focus(terminalTabID, for: target)
    XCTAssertFalse(store.contentFind.isOpen)
  }
}
