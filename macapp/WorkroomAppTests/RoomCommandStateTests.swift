import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

@MainActor
final class RoomCommandStateTests: XCTestCase {
  private func store(path: String = NSTemporaryDirectory()) -> (AppStore, SidebarID) {
    let store = AppStore()
    store.inspectorVisibleOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = [
      Project(path: path, vcs: "git", workrooms: []),
      Project(path: "/room-command-other", vcs: "git", workrooms: []),
    ]
    let id = SidebarID.root(project: path)
    _ = store.terminals.addTab(for: store.target(for: id)!)
    store.selectedTargetID = id
    store.selectionStatusTask?.cancel()
    store.refreshSelectionHasTabs()
    store.workroomStatuses[id] = WorkroomStatus(dirty: true)
    return (store, id)
  }

  private func pr(draft: Bool, title: String = "A change") -> PullRequestInfo {
    PullRequestInfo(
      number: 12, title: title, state: .open, isDraft: draft,
      url: "https://github.com/example/repo/pull/12", reviewDecision: nil, reviewers: [])
  }

  func testUnrelatedStatusAndFreshnessDoNotChangeMenuPresentation() {
    let (store, id) = store()
    defer { Task { await store.terminals.reapAll() } }
    let before = RoomCommandState.read(store)
    XCTAssertTrue(before.canCommit)
    store.mergeLocalStatus(
      WorkroomStatus(dirty: true), into: .root(project: "/room-command-other"))
    XCTAssertEqual(RoomCommandState.read(store), before)
    store.mergeLocalStatus(WorkroomStatus(dirty: true, insertions: 42), into: id)
    XCTAssertEqual(RoomCommandState.read(store), before, "counts and freshness are not menu inputs")
  }

  func testDirtyAndCommittingStateDriveCommitEligibility() {
    let (store, id) = store()
    defer { Task { await store.terminals.reapAll() } }
    store.workroomStatuses[id] = WorkroomStatus(dirty: false)
    XCTAssertFalse(RoomCommandState.read(store).canCommit)
    store.workroomStatuses[id] = WorkroomStatus(dirty: true)
    XCTAssertTrue(RoomCommandState.read(store).canCommit)
    store.committingTargets.insert(id)
    XCTAssertFalse(RoomCommandState.read(store).canCommit)
    store.committingTargets.remove(id)
    XCTAssertTrue(RoomCommandState.read(store).canCommit)
    store.selectedTargetID = nil
    XCTAssertFalse(RoomCommandState.read(store).canCommit)
  }

  func testPullRequestActionsInFlightAndModalGatesRemainLive() {
    let (store, id) = store()
    defer { Task { await store.terminals.reapAll() } }
    store.workroomStatuses[id] = WorkroomStatus(dirty: true, pr: pr(draft: true))
    let draft = RoomCommandState.read(store)
    XCTAssertEqual(draft.pullRequest?.number, 12)
    XCTAssertEqual(draft.pullRequest?.url, "https://github.com/example/repo/pull/12")
    XCTAssertEqual(draft.pullRequest?.draftAction, .markReady)
    XCTAssertTrue(draft.canChangeDraft)
    store.workroomStatuses[id] = WorkroomStatus(dirty: true, pr: pr(draft: true, title: "Retitled"))
    XCTAssertEqual(RoomCommandState.read(store), draft, "an unused PR title must not rebuild menus")
    store.prActionInFlight = true
    XCTAssertFalse(RoomCommandState.read(store).canChangeDraft)
    store.prActionInFlight = false
    store.auxSheetPresented = true
    let modal = RoomCommandState.read(store)
    XCTAssertFalse(modal.canCommit)
    XCTAssertNil(modal.pullRequest)
    XCTAssertFalse(modal.canChangeDraft)
    XCTAssertTrue(modal.canRevealInFinder, "Finder's existing modal behavior is unchanged")
    store.auxSheetPresented = false
    XCTAssertEqual(RoomCommandState.read(store), draft)
    store.workroomStatuses[id] = WorkroomStatus(dirty: true, pr: pr(draft: false))
    XCTAssertEqual(RoomCommandState.read(store).pullRequest?.draftAction, .convertToDraft)
  }

  func testFinderAvailabilityIsRefreshedWhenTheDirectoryDisappears() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, _) = store(path: directory.path)
    defer { Task { await store.terminals.reapAll() } }
    XCTAssertTrue(RoomCommandState.read(store).canRevealInFinder)
    try FileManager.default.removeItem(at: directory)
    XCTAssertFalse(RoomCommandState.read(store).canRevealInFinder)
  }
}
