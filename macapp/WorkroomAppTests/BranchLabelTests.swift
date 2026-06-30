import XCTest

@testable import Workroom

/// `AppStore.branchLabel(for:)` — the source for the detail-panel status bar's branch/bookmark
/// segment (issue #49). It reuses the already-resolved sidebar caches (per-workroom `branchForCI`,
/// the project root's `RootRef`), so these assert the target → SidebarID mapping lands on the right
/// cache entry.
@MainActor
final class BranchLabelTests: XCTestCase {
  private func makeStore() -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "feat", path: "/p/feat", vcsName: "workroom/feat", warnings: [])]
      )
    ]
    return store
  }

  func testWorkroomBranchFromStatus() {
    let store = makeStore()
    store.workroomStatuses[.workroom(project: "/p", name: "feat")] = WorkroomStatus(
      branchForCI: "feature/login")
    let target = store.target(for: .workroom(project: "/p", name: "feat"))!
    XCTAssertEqual(store.branchLabel(for: target), "feature/login")
  }

  func testJJBookmarkFromWorkingCopyWhenNoBranchForCI() {
    let store = makeStore()
    // A jj workroom: no `branchForCI`, the bookmark lives on the working copy (`@`).
    store.workroomStatuses[.workroom(project: "/p", name: "feat")] = WorkroomStatus(
      jjWorkingCopy: JJCommitChanges(
        changeID: "pw", commitID: "abc", refs: ["feature/login"], description: "d", files: []))
    let target = store.target(for: .workroom(project: "/p", name: "feat"))!
    XCTAssertEqual(store.branchLabel(for: target), "feature/login")
  }

  func testRootBranchFromStatus() {
    let store = makeStore()
    store.workroomStatuses[.root(project: "/p")] = WorkroomStatus(branchForCI: "main")
    let target = store.target(for: .root(project: "/p"))!
    XCTAssertEqual(store.branchLabel(for: target), "main")
  }

  func testNilWhenNoStatusResolved() {
    let store = makeStore()
    let target = store.target(for: .workroom(project: "/p", name: "feat"))!
    XCTAssertNil(store.branchLabel(for: target), "no status yet ⇒ no branch segment")
  }
}
