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

  // MARK: One shared accessor

  /// `branchName(for:)` is the single answer every branch-showing surface uses — the status bar, the
  /// Changes header, the sidebar root row and the VCS toolbar. `branchLabel(for:)` must stay a thin
  /// wrapper over it, or those surfaces can drift apart again.
  func testBranchLabelDelegatesToTheSharedAccessor() {
    let store = makeStore()
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    store.workroomStatuses[sid] = WorkroomStatus(branchForCI: "feature/login")
    let target = store.target(for: sid)!
    XCTAssertEqual(store.branchLabel(for: target), store.branchName(for: sid))
  }

  /// The resolver's answer leads when it has one: it is force-refreshed the moment anything changes the
  /// branch, whereas `branchForCI` waits for the status sweep's TTL. Without this the toolbar and the
  /// status bar could show different names for the same workroom.
  func testResolvedNameWinsOverTheStatusSweep() {
    let store = makeStore()
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    store.workroomStatuses[sid] = WorkroomStatus(branchForCI: "stale-name")
    store.setResolvedBranchName("fresh-name", for: sid)
    XCTAssertEqual(store.branchName(for: sid), "fresh-name")
    let target = store.target(for: sid)!
    XCTAssertEqual(store.branchLabel(for: target), "fresh-name", "every surface agrees")
  }

  func testClearingTheResolvedNameFallsBackToTheSweep() {
    let store = makeStore()
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    store.workroomStatuses[sid] = WorkroomStatus(branchForCI: "from-sweep")
    store.setResolvedBranchName("from-resolver", for: sid)
    store.setResolvedBranchName(nil, for: sid)
    XCTAssertEqual(store.branchName(for: sid), "from-sweep")
  }

  /// An empty resolver answer must not blank the label — it should fall through, not win with "".
  func testEmptyResolvedNameDoesNotWin() {
    let store = makeStore()
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    store.workroomStatuses[sid] = WorkroomStatus(branchForCI: "from-sweep")
    store.setResolvedBranchName("", for: sid)
    XCTAssertEqual(store.branchName(for: sid), "from-sweep")
  }

  /// **The performance guard.** Reading a branch label must cost nothing — every source is a cache
  /// already filled by something else. The sidebar and status bar render this per row, so a read that
  /// quietly opened a repo would reproduce the recorded `history-eager-focus-is-a-full-vcs-read`
  /// starvation, which is invisible unless something asserts against it.
  ///
  /// Asserted by *cost*, because that is the property that actually matters and the only one a test can
  /// observe: `branchName` is synchronous, so any VCS work it did would have to happen inline. Opening a
  /// repo or spawning `git` costs milliseconds each; 2000 cache reads cost microseconds. The budget is
  /// two orders of magnitude below a single subprocess, so this passes comfortably on a slow machine and
  /// fails immediately if a provider call is ever added.
  func testBranchNameIsCacheOnlyAndCostsNothing() {
    let store = makeStore()
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    store.workroomStatuses[sid] = WorkroomStatus(branchForCI: "feature/login")
    store.workroomStatuses[.root(project: "/p")] = WorkroomStatus(branchForCI: "main")
    let target = store.target(for: sid)!

    let started = Date()
    for _ in 0..<500 {
      // Every shape: workroom, project root, a sid that resolves to nothing, and the wrapper.
      _ = store.branchName(for: sid)
      _ = store.branchName(for: .root(project: "/p"))
      _ = store.branchName(for: .workroom(project: "/p", name: "does-not-exist"))
      _ = store.branchLabel(for: target)
    }
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(
      elapsed, 0.5,
      """
      2000 branch-label reads took \(elapsed)s. That is far more than dictionary lookups cost, so \
      something in branchName is doing real work — most likely a VCS provider call. It must read \
      caches only; see the doc comment on AppStore.branchName(for:).
      """)
  }
}
