import XCTest

@testable import Workroom

/// `AppStore.isWritingProject`/`beginWrite`/`endWrite` — the cross-window write-in-flight refusal
/// (VCS-foundation eng-review). `committingProjectRoots`/`isCommittingProject` exist to suppress READ
/// lanes during a commit; this is the separate, umbrella mechanism that all four write kinds
/// (commit/fetch/push/pull) check BEFORE starting, so a second write on the same project root is
/// refused outright instead of queuing into `JJSnapshotGate` and possibly racing a live one past the
/// gate's own wedge-detection ceiling.
@MainActor
final class AppStoreWritingProjectTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "main", warnings: [])
      })
  }

  func testIsWritingProjectTracksBeginAndEnd() {
    let store = makeStore([])
    XCTAssertFalse(store.isWritingProject("/proj"))
    store.beginWrite(projectRoot: "/proj")
    XCTAssertTrue(store.isWritingProject("/proj"))
    store.endWrite(projectRoot: "/proj")
    XCTAssertFalse(store.isWritingProject("/proj"))
  }

  func testIsWritingProjectIsPerProjectRoot() {
    let store = makeStore([])
    store.beginWrite(projectRoot: "/a")
    XCTAssertTrue(store.isWritingProject("/a"))
    XCTAssertFalse(store.isWritingProject("/b"), "a different project root must be unaffected")
  }

  /// Counted, not a flag: two sibling writes can legitimately be marked in flight against one root
  /// (defensive symmetry with `committingProjectRoots`, even though in steady state
  /// `isWritingProject` refuses a second write before a second `beginWrite` is ever reached).
  func testEndWriteDecrementsRatherThanClears() {
    let store = makeStore([])
    store.beginWrite(projectRoot: "/proj")
    store.beginWrite(projectRoot: "/proj")
    store.endWrite(projectRoot: "/proj")
    XCTAssertTrue(
      store.isWritingProject("/proj"), "one of two writes finished — the other is still in flight")
    store.endWrite(projectRoot: "/proj")
    XCTAssertFalse(store.isWritingProject("/proj"))
  }

  /// `endWrite` on a root with no recorded write must not underflow into a negative count that
  /// would make `isWritingProject` report busy forever.
  func testEndWriteOnAnUntrackedRootIsSafe() {
    let store = makeStore([])
    store.endWrite(projectRoot: "/never-began")
    XCTAssertFalse(store.isWritingProject("/never-began"))
  }

  /// `performCommit` must refuse immediately — never touching the writer, never entering
  /// `committingTargets` — when another write is already in flight for the same project root.
  func testPerformCommitRefusesWhenAnotherWriteIsInFlight() {
    let store = makeStore([project("/proj", workrooms: ["feat"])])
    let sid = SidebarID.workroom(project: "/proj", name: "feat")
    store.beginWrite(projectRoot: "/proj")

    let request = VCSCommitRequest(message: "msg", files: [], mode: .commit)
    var results: [VCSCommitResult] = []
    store.performCommit(request, on: sid) { results.append($0) }

    XCTAssertEqual(results, [.failed(.locked(nil))])
    XCTAssertFalse(
      store.isCommitting(sid), "the refused commit must never have marked itself as committing")
  }

  /// **The mechanism the write-in-flight leak fix depends on.** `AppStore.releaseWrite` must release
  /// the mark against a `ProjectStore` directly, with no live `AppStore` involved at all — this is
  /// what lets `performCommit`'s Task and `RemoteStateModel`'s `writeDidFinish` wiring release the
  /// mark even after the `AppStore`/`RemoteStateModel` that started the write has already been
  /// deallocated (e.g. the window closed mid-write). If this ever required a live `AppStore`, a
  /// closed window mid-write would leak the mark forever and refuse every future write for that
  /// project, in every window, until the app restarts.
  func testReleaseWriteWorksAgainstAProjectStoreAloneNoAppStoreNeeded() {
    let projectStore = ProjectStore()
    projectStore.writingProjectRoots["/proj"] = 1
    AppStore.releaseWrite(projectRoot: "/proj", in: projectStore)
    XCTAssertNil(
      projectStore.writingProjectRoots["/proj"],
      "the mark must clear even though no AppStore instance was ever touched")
  }

  /// Two writes marked against the same root (defensive symmetry, mirrors `testEndWriteDecrements
  /// RatherThanClears`): releasing must decrement, not clear outright, so a sibling write still in
  /// flight isn't falsely freed.
  func testReleaseWriteDecrementsRatherThanClears() {
    let projectStore = ProjectStore()
    projectStore.writingProjectRoots["/proj"] = 2
    AppStore.releaseWrite(projectRoot: "/proj", in: projectStore)
    XCTAssertEqual(projectStore.writingProjectRoots["/proj"], 1)
  }

  /// The common case: no other write in flight, so `performCommit` must proceed past the guard (it
  /// marks `committingTargets`/`committingProjectRoots`/`writingProjectRoots` synchronously before
  /// its `Task` even starts) rather than refusing.
  func testPerformCommitProceedsWhenNoOtherWriteIsInFlight() {
    let store = makeStore([project("/proj", workrooms: ["feat"])])
    let sid = SidebarID.workroom(project: "/proj", name: "feat")

    let request = VCSCommitRequest(message: "msg", files: [], mode: .commit)
    store.performCommit(request, on: sid) { _ in }

    XCTAssertTrue(store.isCommitting(sid), "a real attempt must mark itself as committing")
    XCTAssertTrue(store.isWritingProject("/proj"))
  }
}
