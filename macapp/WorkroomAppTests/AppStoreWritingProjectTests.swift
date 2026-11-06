import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// `VCSStatusService.isWritingProject`/`beginWrite`/`endWrite` — the cross-window write-in-flight refusal
/// (VCS-foundation eng-review). `committingProjectRoots`/`isCommittingProject` exist to suppress READ
/// lanes during a commit; this is the separate, umbrella mechanism that all four write kinds
/// (commit/fetch/push/pull) check BEFORE starting, so a second write on the same project root is
/// refused outright instead of queuing into `RepositoryWriteGate` and possibly racing a live one past the
/// gate's own wedge-detection ceiling.
@MainActor
final class AppStoreWritingProjectTests: XCTestCase {

  private func makeStore(_ projects: [Project]) async throws -> AppStore {
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(projects))
    let store = AppStore()
    store.projectStore.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "main", warnings: [])
      })
  }

  func testIsWritingProjectTracksBeginAndEnd() async throws {
    let proj = try await RepositoryLocation.local("/proj")
    let store = try await makeStore([])
    XCTAssertFalse(store.vcsStatus.isWritingProject(proj))
    store.vcsStatus.beginWrite(projectRoot: proj)
    XCTAssertTrue(store.vcsStatus.isWritingProject(proj))
    store.vcsStatus.endWrite(projectRoot: proj)
    XCTAssertFalse(store.vcsStatus.isWritingProject(proj))
  }

  func testIsWritingProjectIsPerProjectRoot() async throws {
    let a = try await RepositoryLocation.local("/a")
    let b = try await RepositoryLocation.local("/b")
    let store = try await makeStore([])
    store.vcsStatus.beginWrite(projectRoot: a)
    XCTAssertTrue(store.vcsStatus.isWritingProject(a))
    XCTAssertFalse(
      store.vcsStatus.isWritingProject(b), "a different project root must be unaffected")
  }

  /// Counted, not a flag: two sibling writes can legitimately be marked in flight against one root
  /// (defensive symmetry with `committingProjectRoots`, even though in steady state
  /// `isWritingProject` refuses a second write before a second `beginWrite` is ever reached).
  func testEndWriteDecrementsRatherThanClears() async throws {
    let proj = try await RepositoryLocation.local("/proj")
    let store = try await makeStore([])
    store.vcsStatus.beginWrite(projectRoot: proj)
    store.vcsStatus.beginWrite(projectRoot: proj)
    store.vcsStatus.endWrite(projectRoot: proj)
    XCTAssertTrue(
      store.vcsStatus.isWritingProject(proj),
      "one of two writes finished — the other is still in flight")
    store.vcsStatus.endWrite(projectRoot: proj)
    XCTAssertFalse(store.vcsStatus.isWritingProject(proj))
  }

  /// `endWrite` on a root with no recorded write must not underflow into a negative count that
  /// would make `isWritingProject` report busy forever.
  func testEndWriteOnAnUntrackedRootIsSafe() async throws {
    let never = try await RepositoryLocation.local("/never-began")
    let store = try await makeStore([])
    store.vcsStatus.endWrite(projectRoot: never)
    XCTAssertFalse(store.vcsStatus.isWritingProject(never))
  }

  /// `performCommit` must refuse immediately — never touching the writer, never entering
  /// `committingTargets` — when another write is already in flight for the same project root.
  func testPerformCommitRefusesWhenAnotherWriteIsInFlight() async throws {
    // Real checkouts: `prepare` registers only a project and workroom that are git checkouts.
    let root = NSTemporaryDirectory() + "writing-project-\(UUID().uuidString)"
    try makeGitCheckout(atPath: root)
    try makeGitCheckout(atPath: root + "/feat")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let proj = try await RepositoryLocation.local(root)
    let store = try await makeStore([project(root, workrooms: ["feat"])])
    let sid = SidebarID.workroom(project: root, name: "feat")
    store.vcsStatus.beginWrite(projectRoot: proj)

    let request = VCSCommitRequest(message: "msg", files: [], mode: .commit)
    var results: [VCSCommitResult] = []
    await withCheckedContinuation { continuation in
      store.performCommit(request, on: sid) {
        results.append($0)
        continuation.resume()
      }
    }

    XCTAssertEqual(results, [.failed(.locked(nil))])
    XCTAssertFalse(
      store.vcsStatus.isCommitting(sid),
      "the refused commit must never have marked itself as committing")
  }

  /// **The mechanism the write-in-flight leak fix depends on.** `VCSStatusService.endWrite` must
  /// release the mark with no live `AppStore` involved at all — this is
  /// what lets `performCommit`'s Task and `RemoteStateModel`'s `writeDidFinish` wiring release the
  /// mark even after the `AppStore`/`RemoteStateModel` that started the write has already been
  /// deallocated (e.g. the window closed mid-write). If this ever required a live `AppStore`, a
  /// closed window mid-write would leak the mark forever and refuse every future write for that
  /// project, in every window, until the app restarts.
  func testReleaseWriteWorksAgainstAProjectStoreAloneNoAppStoreNeeded() async throws {
    let proj = try await RepositoryLocation.local("/proj")
    let vcsStatus = VCSStatusService(projectStore: ProjectStore())
    vcsStatus.writingProjectRoots[proj] = 1
    vcsStatus.endWrite(projectRoot: proj)
    XCTAssertNil(
      vcsStatus.writingProjectRoots[proj],
      "the mark must clear even though no AppStore instance was ever touched")
  }

  /// Unknown ownership refuses the commit before reserving any cross-window suppression.
  func testUnregisteredCommitFailsWithoutMarkingAWrite() async throws {
    let store = AppStore(projectStore: ProjectStore())
    store.projectStore.projects = [project("/missing-project", workrooms: ["feat"])]
    let sid = SidebarID.workroom(project: "/missing-project", name: "feat")
    let request = VCSCommitRequest(message: "msg", files: [], mode: .commit)
    let result: VCSCommitResult = await withCheckedContinuation { continuation in
      store.performCommit(request, on: sid) { continuation.resume(returning: $0) }
    }
    guard case .failed = result else { return XCTFail("unregistered write succeeded") }
    XCTAssertFalse(store.vcsStatus.isCommitting(sid))
    XCTAssertTrue(store.vcsStatus.writingProjectRoots.isEmpty)
  }
}

extension AppStoreWritingProjectTests {
  func testSamePathOnDifferentHostsHasIndependentCrossWindowSuppression() throws {
    let shared = VCSStatusService(projectStore: ProjectStore())
    let firstWindow = AppStore(vcsStatus: shared)
    let secondWindow = AppStore(vcsStatus: shared)
    let one = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let two = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    firstWindow.vcsStatus.beginWrite(projectRoot: one)
    XCTAssertTrue(secondWindow.vcsStatus.isWritingProject(one))
    XCTAssertFalse(secondWindow.vcsStatus.isWritingProject(two))
    secondWindow.vcsStatus.beginWrite(projectRoot: two)
    firstWindow.vcsStatus.endWrite(projectRoot: one)
    XCTAssertFalse(secondWindow.vcsStatus.isWritingProject(one))
    XCTAssertTrue(secondWindow.vcsStatus.isWritingProject(two))
    secondWindow.vcsStatus.endWrite(projectRoot: two)
    XCTAssertTrue(shared.writingProjectRoots.isEmpty)
  }

  /// Value: protects=Room ▸ Commit… and the Changes commit button open the dialog only for a dirty,
  /// known, not-committing workroom or root; fails_when=a clean, unknown, in-flight or group-header
  /// target opens it, or a dirty one doesn't; why_new=the rule moved out of a view, untested; seam=none;
  /// no_claim=the menu item's drawing
  func testCanCommitAndRequestCommitFollowTheTargetsStatus() async throws {
    let store = try await makeStore([project("/proj", workrooms: ["wr"])])
    let wr = SidebarID.workroom(project: "/proj", name: "wr")
    let root = SidebarID.root(project: "/proj")

    XCTAssertFalse(store.canCommit(nil), "nothing inspected")
    XCTAssertFalse(store.canCommit(wr), "no status read yet")
    store.vcsStatus.workroomStatuses[wr] = WorkroomStatus(dirty: false)
    XCTAssertFalse(store.canCommit(wr), "clean")
    store.vcsStatus.workroomStatuses[wr] = .unresolved
    XCTAssertFalse(store.canCommit(wr), "unknown")
    store.vcsStatus.workroomStatuses[.project("/proj")] = WorkroomStatus(dirty: true)
    XCTAssertFalse(store.canCommit(.project("/proj")), "a group header has no status to commit")

    store.vcsStatus.workroomStatuses[wr] = WorkroomStatus(dirty: true)
    store.vcsStatus.workroomStatuses[root] = WorkroomStatus(dirty: true)
    XCTAssertTrue(store.canCommit(wr))
    XCTAssertTrue(store.canCommit(root))

    store.vcsStatus.committingTargets.insert(wr)
    XCTAssertFalse(store.canCommit(wr), "a commit is already in flight")
    store.requestCommit(wr)
    XCTAssertNil(store.modals.pendingCommit)

    store.vcsStatus.committingTargets.remove(wr)
    store.requestCommit(nil)
    XCTAssertNil(store.modals.pendingCommit)
    store.requestCommit(wr)
    XCTAssertEqual(store.modals.pendingCommit, PendingCommit(sid: wr))
  }
}
