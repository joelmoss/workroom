import Foundation
import XCTest

@testable import HostDrivers

/// This Mac's place for its Railway hosts (ADR 0071, #629), with Railway stubbed at HTTP: the
/// `Workroom` project picked or made in the chosen workspace, and an environment of this Mac's own,
/// each recorded as soon as Railway makes it.
final class RailwayPlacementTests: XCTestCase {
  private struct Tokens: RailwayAccessTokenProviding {
    func accessToken() async throws -> String { "at-1" }
    func accessTokenRejected(_ token: String) async {}
  }

  private var store: RailwayPlacementStore!

  override func setUp() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-placement-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    store = RailwayPlacementStore(file: root.appendingPathComponent("placement.json"))
  }

  private func railway(projects: [[String: String]]) -> StubRailway {
    let railway = StubRailway()
    railway.answer(
      "projects", data: ["projects": ["edges": projects.map { ["node": $0] }]])
    railway.answer("projectCreate", data: ["projectCreate": ["id": "prj-new"]])
    railway.answer("environmentCreate", data: ["environmentCreate": ["id": "env-mac"]])
    return railway
  }

  private func sent(_ railway: StubRailway, _ field: String) -> [[String: Any]] {
    railway.graphQLRequests.map(StubRailway.graphQLBody)
      .filter { ($0["query"] as? String)?.contains("\(field)(") == true }
      .compactMap { ($0["variables"] as? [String: Any])?["input"] as? [String: Any] }
  }

  /// Value: protects=hosts go in the user's `Workroom` project, and each Mac in its own
  /// environment there; fails_when=a second project is made beside an existing one, or no
  /// environment is recorded; seam=RailwayPlacementStore.ensure over StubRailway
  func testAnExistingWorkroomProjectIsPickedAndThisMacGetsAnEnvironment() async throws {
    let railway = railway(projects: [
      ["id": "prj-app", "name": "my-app"], ["id": "prj-wr", "name": "Workroom"],
    ])
    let api = RailwayAPI(transport: railway, tokens: Tokens())

    let placed = try await store.ensure(
      workspaceID: "ws-1", api: api, environmentName: "mac-studio-abc123")

    XCTAssertEqual(placed.projectID, "prj-wr")
    XCTAssertEqual(placed.environmentID, "env-mac")
    XCTAssertTrue(sent(railway, "projectCreate").isEmpty, "a second project was made")
    let environment = try XCTUnwrap(sent(railway, "environmentCreate").first)
    XCTAssertEqual(environment["projectId"] as? String, "prj-wr")
    XCTAssertEqual(environment["name"] as? String, "mac-studio-abc123")
    XCTAssertEqual(
      store.read(),
      RailwayPlacement(workspaceID: "ws-1", projectID: "prj-wr", environmentID: "env-mac"))

    // Recorded: the next create asks Railway nothing.
    let before = railway.graphQLRequests.count
    _ = try await store.ensure(workspaceID: "ws-1", api: api, environmentName: "other")
    XCTAssertEqual(railway.graphQLRequests.count, before)
  }

  /// Value: protects=Release and Nightly setting up at once make one project and one environment
  /// between them, not one each (review 3, C6); fails_when=a placement runs while the other app
  /// holds the placement's lock, or acts on what it read before the other app finished;
  /// seam=RailwayPlacementStore.ensure over StubRailway, with the lock file held from another
  /// open file and the other app's placement written before it lets go
  func testAPlacementWaitsForTheOtherAppsAndUsesWhatItMade() async throws {
    let railway = railway(projects: [])
    let api = RailwayAPI(transport: railway, tokens: Tokens())
    let lock = store.lockFile
    try FileManager.default.createDirectory(
      at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    var held = true
    defer { if held { close(fd) } }

    let store = store!
    let ensure = Task {
      try await store.ensure(workspaceID: "ws-1", api: api, environmentName: "mac-a")
    }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(railway.graphQLRequests.isEmpty, "placed while the other app held the lock")

    // The other app placed this Mac meanwhile, then let go.
    try store.update {
      $0.workspaceID = "ws-1"
      $0.projectID = "prj-other"
      $0.environmentID = "env-other"
    }
    flock(fd, LOCK_UN)
    close(fd)
    held = false

    let placed = try await ensure.value
    XCTAssertEqual(placed.projectID, "prj-other")
    XCTAssertEqual(placed.environmentID, "env-other")
    XCTAssertTrue(sent(railway, "projectCreate").isEmpty, "a second project was made")
    XCTAssertTrue(sent(railway, "environmentCreate").isEmpty, "a second environment was made")
  }

  /// Value: protects=a retry after a failure never makes a second project; fails_when=the
  /// project's id is only recorded with the environment's; seam=ensure
  func testAProjectIsMadeWhenNoneIsThereAndKeptWhenTheEnvironmentFails() async throws {
    let railway = railway(projects: [["id": "prj-app", "name": "my-app"]])
    railway.answer("environmentCreate") { _ in
      RailwayHTTPResponse(status: 200, body: Data(#"{"errors":[{"message":"busy"}]}"#.utf8))
    }
    let api = RailwayAPI(transport: railway, tokens: Tokens())
    do {
      _ = try await store.ensure(workspaceID: "ws-1", api: api, environmentName: "mac-x-1")
      XCTFail("a failed environment was recorded")
    } catch RailwayAPIError.graphQL {}
    XCTAssertEqual(sent(railway, "projectCreate").first?["name"] as? String, "Workroom")
    XCTAssertEqual(sent(railway, "projectCreate").first?["workspaceId"] as? String, "ws-1")
    XCTAssertEqual(store.read().projectID, "prj-new")

    railway.answer("environmentCreate", data: ["environmentCreate": ["id": "env-mac"]])
    let placed = try await store.ensure(workspaceID: "ws-1", api: api, environmentName: "mac-x-1")
    XCTAssertEqual(placed.environmentID, "env-mac")
    XCTAssertEqual(sent(railway, "projectCreate").count, 1, "a second project was made")
  }

  /// `env-1`'s sandboxes as Railway lists them, each with its status.
  private func list(_ railway: StubRailway, _ sandboxes: [String: String]) {
    railway.answer(
      "sandboxes",
      data: [
        "sandboxes": [
          "edges": sandboxes.map { id, status in
            [
              "node": [
                "id": id, "status": status, "createdAt": "2026-01-01T00:00:00Z",
                "environmentId": "env-1",
              ]
            ]
          },
          "pageInfo": ["hasNextPage": false],
        ]
      ])
  }

  private func listed(_ railway: StubRailway) -> [String] {
    railway.graphQLRequests.map(StubRailway.graphQLBody)
      .filter { ($0["query"] as? String)?.contains("sandboxes(") == true }
      .compactMap { ($0["variables"] as? [String: Any])?["environmentId"] as? String }
  }

  /// Value: protects=picking another workspace puts new hosts there once this Mac's environment
  /// holds nothing; fails_when=the old workspace's project or environment is used in the new one,
  /// or the old environment isn't checked first; seam=ensure
  func testAnotherWorkspaceStartsAgainThere() async throws {
    try store.update {
      $0 = RailwayPlacement(workspaceID: "ws-1", projectID: "prj-1", environmentID: "env-1")
    }
    let railway = railway(projects: [])
    list(railway, ["sbx-old": "DESTROYED"])
    let placed = try await store.ensure(
      workspaceID: "ws-2", api: RailwayAPI(transport: railway, tokens: Tokens()),
      environmentName: "mac-x-1")
    XCTAssertEqual(placed.projectID, "prj-new")
    XCTAssertEqual(placed.environmentID, "env-mac")
    XCTAssertEqual(store.read().workspaceID, "ws-2")
    XCTAssertEqual(listed(railway), ["env-1"])
  }

  /// Value: protects=no sandbox is left billing in an environment no sweep lists again: the
  /// launch sweep lists only this Mac's current environment, so leaving one that still holds a
  /// sandbox, recorded or not, would orphan it; fails_when=the placement moves while the old
  /// environment holds a live sandbox, or while Railway can't list it; seam=ensure
  func testLeavingAnEnvironmentThatStillHoldsASandboxIsRefused() async throws {
    let before = RailwayPlacement(workspaceID: "ws-1", projectID: "prj-1", environmentID: "env-1")
    try store.update { $0 = before }
    let railway = railway(projects: [["id": "prj-app", "name": "my-app"]])
    list(railway, ["sbx-live": "RUNNING", "sbx-old": "DESTROYED"])
    let api = RailwayAPI(transport: railway, tokens: Tokens())

    for leave in [("ws-2", nil), ("ws-1", .existing("prj-app"))] as [(String, RailwayProjectPick?)]
    {
      do {
        _ = try await store.ensure(
          workspaceID: leave.0, project: leave.1, api: api, environmentName: "mac-x-1")
        XCTFail("left an environment holding a sandbox for \(leave)")
      } catch RailwayPlacementError.environmentHoldsSandboxes(let count) {
        XCTAssertEqual(count, 1)
      }
    }
    XCTAssertEqual(store.read(), before)
    XCTAssertTrue(sent(railway, "projectCreate").isEmpty)
    XCTAssertTrue(sent(railway, "environmentCreate").isEmpty)

    // Railway can't list it: the placement stays too.
    railway.answer("sandboxes") { _ in
      RailwayHTTPResponse(status: 200, body: Data(#"{"errors":[{"message":"busy"}]}"#.utf8))
    }
    do {
      _ = try await store.ensure(workspaceID: "ws-2", api: api, environmentName: "mac-x-1")
      XCTFail("left an environment Railway couldn't list")
    } catch RailwayAPIError.graphQL {}
    XCTAssertEqual(store.read(), before)
  }

  /// Value: protects=the setup sheet's pick of an existing project (story 14) gets this Mac's
  /// environment in it; fails_when=a project is made beside the picked one, or the recorded
  /// project is kept; seam=ensure with a project
  func testAPickedProjectGetsThisMacsEnvironment() async throws {
    try store.update {
      $0 = RailwayPlacement(workspaceID: "ws-1", projectID: "prj-1", environmentID: "env-1")
    }
    let railway = railway(projects: [["id": "prj-app", "name": "my-app"]])
    list(railway, [:])
    let placed = try await store.ensure(
      workspaceID: "ws-1", project: .existing("prj-app"),
      api: RailwayAPI(transport: railway, tokens: Tokens()), environmentName: "mac-x-1")
    XCTAssertEqual(placed.projectID, "prj-app")
    XCTAssertEqual(placed.environmentID, "env-mac")
    XCTAssertTrue(sent(railway, "projectCreate").isEmpty)
    XCTAssertEqual(sent(railway, "environmentCreate").first?["projectId"] as? String, "prj-app")
    XCTAssertEqual(
      store.read(),
      RailwayPlacement(workspaceID: "ws-1", projectID: "prj-app", environmentID: "env-mac"))
  }

  /// Value: protects=choosing a new `Workroom` project in the sheet makes one, even with another
  /// project recorded in the workspace; fails_when=the recorded project is kept, or a second
  /// Workroom project is made beside one; seam=ensure with `.workroom`
  func testPickingANewWorkroomProjectMakesItOnce() async throws {
    try store.update {
      $0 = RailwayPlacement(workspaceID: "ws-1", projectID: "prj-app", environmentID: "env-1")
    }
    let railway = railway(projects: [["id": "prj-app", "name": "my-app"]])
    list(railway, [:])
    let api = RailwayAPI(transport: railway, tokens: Tokens())
    let placed = try await store.ensure(
      workspaceID: "ws-1", project: .workroom, api: api, environmentName: "mac-x-1")
    XCTAssertEqual(placed.projectID, "prj-new")
    XCTAssertEqual(sent(railway, "projectCreate").map { $0["name"] as? String }, ["Workroom"])

    // Railway now lists it: picking it again makes nothing.
    railway.answer(
      "projects",
      data: ["projects": ["edges": [["node": ["id": "prj-new", "name": "Workroom"]]]]])
    let before = railway.graphQLRequests.count
    let again = try await store.ensure(
      workspaceID: "ws-1", project: .workroom, api: api, environmentName: "mac-x-1")
    XCTAssertEqual(again.environmentID, placed.environmentID)
    XCTAssertEqual(railway.graphQLRequests.count, before + 1, "more than the projects read")
  }

  func testTheEnvironmentIsNamedForTheMacWithASuffix() {
    XCTAssertEqual(
      RailwayPlacementStore.environmentName(computer: "Joel's MacBook.local", suffix: "a1b2c3"),
      "mac-joel-s-macbook-a1b2c3")
    XCTAssertEqual(
      RailwayPlacementStore.environmentName(computer: "", suffix: "a1b2c3"), "mac-unnamed-a1b2c3")
  }
}
