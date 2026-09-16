import Foundation
import XCTest

@testable import Workroom

/// Each list call stops after taking its request slot; tests choose its result and completion order.
private actor GatedListCLI: WorkroomCLIProtocol {
  let started: [XCTestExpectation]
  private var pending: [Int: CheckedContinuation<ListResponse, Error>] = [:]
  private var count = 0

  init(started: [XCTestExpectation]) { self.started = started }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    let index = count
    count += 1
    guard index < started.count else {
      XCTFail("Unexpected list request \(index)")
      throw WorkroomCLIError.timedOut
    }
    return try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
      started[index].fulfill()
    }
  }

  func release(_ index: Int, projects: [Project]) {
    pending.removeValue(forKey: index)?.resume(
      returning: ListResponse(projects: projects, workroomsDir: nil, configPath: nil))
  }

  func fail(_ index: Int) {
    pending.removeValue(forKey: index)?.resume(throwing: WorkroomCLIError.timedOut)
  }

  func addProject(_ path: String, create: Bool) async throws -> String { path }
  func create(
    project: String, onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse { throw WorkroomCLIError.timedOut }
  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}
  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

@MainActor
final class AppStoreLoadOrderingTests: XCTestCase {
  private let path = "/nonexistent/workroom-load-ordering"

  private func projects(_ names: [String]) -> [Project] {
    [
      Project(
        path: path, vcs: "git",
        workrooms: names.map {
          Workroom(name: $0, path: "\(path)/\($0)", vcsName: "git", warnings: [])
        })
    ]
  }

  private func makeStore(_ shared: ProjectStore, cli: GatedListCLI) -> AppStore {
    let store = AppStore(projectStore: shared, cli: cli)
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    return store
  }

  func testLateSnapshotPreservesSelectionAndSplitInOneWindow() async {
    await checkLateSnapshot(acrossWindows: false)
  }

  func testLateSnapshotPreservesSelectionAndSplitAcrossWindows() async {
    await checkLateSnapshot(acrossWindows: true)
  }

  private func checkLateSnapshot(acrossWindows: Bool) async {
    let started = [expectation(description: "older list"), expectation(description: "newer list")]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let first = makeStore(shared, cli: cli)
    let second = acrossWindows ? makeStore(shared, cli: cli) : first
    first.projects = projects(["anchor"])
    let older = Task { await first.reload() }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await second.reload() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(1, projects: projects(["anchor", "created"]))
    await newer.value

    let anchor = SidebarID.workroom(project: path, name: "anchor")
    let created = SidebarID.workroom(project: path, name: "created")
    first.insertWorkroomSplit(created, beside: anchor, edge: .right)
    XCTAssertEqual(first.selectedTargetID, created)
    XCTAssertEqual(first.workroomSplits.first?.tabIDs, [anchor, created])
    XCTAssertTrue(first.isLoading)
    if acrossWindows { XCTAssertFalse(second.isLoading) }

    await cli.release(0, projects: projects(["anchor"]))
    await older.value
    XCTAssertEqual(shared.projects.first?.workrooms.map(\.name), ["anchor", "created"])
    XCTAssertEqual(first.selectedTargetID, created)
    XCTAssertEqual(first.workroomSplits.first?.tabIDs, [anchor, created])
    XCTAssertFalse(first.isLoading)
  }

  func testOlderSuccessIsIgnoredWhileNewerLoadIsPendingEvenIfNewerFails() async {
    let started = [expectation(description: "older list"), expectation(description: "newer list")]
    let cli = GatedListCLI(started: started)
    let store = makeStore(ProjectStore(), cli: cli)
    store.projects = projects(["existing"])
    let older = Task { await store.reload() }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await store.reload() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(0, projects: [])
    XCTAssertEqual(store.projects.first?.workrooms.map(\.name), ["existing"])
    XCTAssertTrue(store.isLoading)

    await cli.fail(1)
    await newer.value
    await older.value
    XCTAssertEqual(store.projects.first?.workrooms.map(\.name), ["existing"])
    XCTAssertNotNil(store.errorMessage, "the current request's error must still surface")
    XCTAssertFalse(store.isLoading)
  }

  func testSupersededErrorDoesNotSurfaceAcrossWindows() async {
    let started = [expectation(description: "older list"), expectation(description: "newer list")]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let first = makeStore(shared, cli: cli)
    let second = makeStore(shared, cli: cli)
    let older = Task { await first.reload() }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await second.reload() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(1, projects: projects(["created"]))
    await newer.value
    await cli.fail(0)
    await older.value
    XCTAssertNil(first.errorMessage)
    XCTAssertEqual(shared.projects.first?.workrooms.map(\.name), ["created"])
    XCTAssertFalse(first.isLoading)
    XCTAssertFalse(second.isLoading)
  }

  func testNewerBackgroundFailureDoesNotSurfaceInSupersededWindow() async {
    let started = [expectation(description: "foreground"), expectation(description: "background")]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let first = makeStore(shared, cli: cli)
    let second = makeStore(shared, cli: cli)
    first.projects = projects(["existing"])
    let older = Task { await first.reload() }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await second.reloadIfStale() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(0, projects: [])
    await cli.fail(1)
    await newer.value
    await older.value
    XCTAssertNil(first.errorMessage)
    XCTAssertNil(second.errorMessage)
    XCTAssertEqual(shared.projects.first?.workrooms.map(\.name), ["existing"])
    XCTAssertFalse(first.isLoading)
    XCTAssertFalse(second.isLoading)
  }

  func testAddProjectWaitsForNewerReadBeforeSelectingRoot() async {
    let started = [expectation(description: "add reload"), expectation(description: "background")]
    let cli = GatedListCLI(started: started)
    let store = makeStore(ProjectStore(), cli: cli)
    let finished = expectation(description: "add must wait")
    finished.isInverted = true
    let adding = Task {
      await store.addProject(path, create: false)
      finished.fulfill()
    }
    await fulfillment(of: [started[0]], timeout: 5)
    let background = Task { await store.reloadIfStale() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(0, projects: projects([]))
    await fulfillment(of: [finished], timeout: 0.1)
    await cli.release(1, projects: projects([]))
    await background.value
    await adding.value
    XCTAssertEqual(store.selectedTargetID, .root(project: path))
    XCTAssertFalse(store.isLoading)
  }

  func testAddProjectReportsFailureWhenNewerBackgroundReadFails() async {
    let started = [expectation(description: "add reload"), expectation(description: "background")]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let store = makeStore(shared, cli: cli)
    let other = makeStore(shared, cli: cli)
    let adding = Task { await store.addProject(path, create: false) }
    await fulfillment(of: [started[0]], timeout: 5)
    let background = Task { await other.reloadIfStale() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(0, projects: projects([]))
    await cli.fail(1)
    await background.value
    let result = await adding.value
    guard case .failure(let error) = result else {
      XCTFail("An unresolved project must not report success to onboarding")
      return
    }
    XCTAssertEqual(
      error.localizedDescription,
      "The project was registered, but could not be loaded. Refresh to try again.")
    XCTAssertEqual(store.errorMessage, error.localizedDescription)
    XCTAssertNil(other.errorMessage)
    XCTAssertTrue(shared.projects.isEmpty)
    XCTAssertNil(store.selectedTargetID)
  }

  func testCreateAsSplitWaitsForNewerReadInAnotherWindow() async {
    let started = [
      expectation(description: "landing reload"), expectation(description: "other window"),
    ]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let store = makeStore(shared, cli: cli)
    let other = makeStore(shared, cli: cli)
    store.projects = projects(["anchor"])
    let anchor = SidebarID.workroom(project: path, name: "anchor")
    let created = SidebarID.workroom(project: path, name: "created")
    let finished = expectation(description: "landing must wait")
    finished.isInverted = true
    let landing = Task {
      await store.landOnCreatedWorkroom(
        name: "created", project: projects(["anchor"])[0], setup: true,
        session: ScriptLogSession(title: "Setup", phase: "setup"),
        splitAnchor: anchor, landing: CreationLandingBox())
      finished.fulfill()
    }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await other.reload() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(0, projects: projects(["anchor", "created"]))
    await fulfillment(of: [finished], timeout: 0.1)
    await cli.release(1, projects: projects(["anchor", "created"]))
    await newer.value
    await landing.value
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [anchor, created])
    XCTAssertEqual(store.selectedTargetID, created)
  }

  func testSupersededWindowPrunesDeletedSelectionAndSplit() async {
    let started = [
      expectation(description: "first window"), expectation(description: "second window"),
    ]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let first = makeStore(shared, cli: cli)
    let second = makeStore(shared, cli: cli)
    first.projects = projects(["anchor", "deleted"])
    let anchor = SidebarID.workroom(project: path, name: "anchor")
    let deleted = SidebarID.workroom(project: path, name: "deleted")
    first.insertWorkroomSplit(deleted, beside: anchor, edge: .right)
    let older = Task { await first.reload() }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await second.reload() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(1, projects: projects(["anchor"]))
    await newer.value
    await cli.release(0, projects: projects(["anchor", "deleted"]))
    await older.value
    XCTAssertEqual(first.selectedTargetID, anchor)
    XCTAssertTrue(first.workroomSplits.isEmpty)
    XCTAssertEqual(first.projects.first?.workrooms.map(\.name), ["anchor"])
  }

  func testSupersededWindowRestoresItsOwnPendingSelection() async {
    let started = [
      expectation(description: "restoring window"), expectation(description: "other window"),
    ]
    let cli = GatedListCLI(started: started)
    let shared = ProjectStore()
    let first = makeStore(shared, cli: cli)
    let second = makeStore(shared, cli: cli)
    first.pendingRestoreSelection = TerminalTarget.workroomID(project: path, name: "saved")
    let older = Task { await first.reload() }
    await fulfillment(of: [started[0]], timeout: 5)
    let newer = Task { await second.reload() }
    await fulfillment(of: [started[1]], timeout: 5)
    await cli.release(1, projects: projects(["saved"]))
    await newer.value
    await cli.release(0, projects: [])
    await older.value
    XCTAssertEqual(first.selectedTargetID, .workroom(project: path, name: "saved"))
    XCTAssertNil(first.pendingRestoreSelection)
  }

}
