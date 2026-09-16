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
    await older.value
    XCTAssertEqual(store.projects.first?.workrooms.map(\.name), ["existing"])
    XCTAssertTrue(store.isLoading)

    await cli.fail(1)
    await newer.value
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
}
