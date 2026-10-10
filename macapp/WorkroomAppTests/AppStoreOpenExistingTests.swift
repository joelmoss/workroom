import WorkroomDomain
import XCTest

@testable import Workroom

/// `AppStore.openExisting` — the Open Workroom picker's action (issue #94). Drives a real,
/// non-singleton `AppStore` with injected projects and the terminal factory seam overridden, the
/// same harness as `AppStoreNavigationTests`. The menu/`focusedSceneValue` wiring is verified
/// manually; `NSApp.activate` inside `openExisting` is an inert no-op under the test host.
@MainActor
final class AppStoreOpenExistingTests: XCTestCase {

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

  @discardableResult
  private func addTerminal(_ store: AppStore, _ sid: SidebarID) -> UUID {
    store.selectedTargetID = sid
    store.newTerminalInSelectedTarget()
    return store.terminals.focusedTab(for: store.target(for: sid)!)!.id
  }

  /// Opening a different target switches selection to it.
  func testOpensSwitchesSelection() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    addTerminal(store, a)
    addTerminal(store, b)  // selection now b

    store.openExisting(a)

    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(store.selectedProjectID, "/a")
  }

  /// Opening focuses the target's existing tab (the "switch and focus" of the issue).
  func testOpensFocusesExistingTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = addTerminal(store, a)
    // Move selection away so opening has to refocus.
    store.selectedTargetID = .root(project: "/a")

    store.openExisting(a)

    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(store.terminals.focusedTab(for: store.target(for: a)!)?.id, tab)
  }

  /// Opening a root that has no terminal yet still selects it (the detail pane opens it) — no crash.
  func testOpensRootWithoutTabSelects() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let root = SidebarID.root(project: "/a")

    store.openExisting(root)

    XCTAssertEqual(store.selectedTargetID, root)
  }

  /// Opening the already-selected target is a safe refocus (stays selected, no crash).
  func testOpensAlreadySelectedRefocuses() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = addTerminal(store, a)  // a is selected + focused

    store.openExisting(a)

    XCTAssertEqual(store.selectedTargetID, a)
    XCTAssertEqual(store.terminals.focusedTab(for: store.target(for: a)!)?.id, tab)
  }

  /// Opening records the jump in nav history (one entry), like the notification path.
  func testOpensRecordsHistory() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    addTerminal(store, a)
    addTerminal(store, b)
    let before = store.history.entries.count

    store.openExisting(a)

    XCTAssertEqual(store.history.entries.count, before + 1)
    XCTAssertEqual(store.history.current?.target, a)
  }
}
