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

  /// Value: protects=picking another workspace puts new hosts there; fails_when=the old
  /// workspace's project or environment is used in the new one; seam=ensure
  func testAnotherWorkspaceStartsAgainThere() async throws {
    try store.update {
      $0 = RailwayPlacement(workspaceID: "ws-1", projectID: "prj-1", environmentID: "env-1")
    }
    let railway = railway(projects: [])
    let placed = try await store.ensure(
      workspaceID: "ws-2", api: RailwayAPI(transport: railway, tokens: Tokens()),
      environmentName: "mac-x-1")
    XCTAssertEqual(placed.projectID, "prj-new")
    XCTAssertEqual(placed.environmentID, "env-mac")
    XCTAssertEqual(store.read().workspaceID, "ws-2")
  }

  func testTheEnvironmentIsNamedForTheMacWithASuffix() {
    XCTAssertEqual(
      RailwayPlacementStore.environmentName(computer: "Joel's MacBook.local", suffix: "a1b2c3"),
      "mac-joel-s-macbook-a1b2c3")
    XCTAssertEqual(
      RailwayPlacementStore.environmentName(computer: "", suffix: "a1b2c3"), "mac-unnamed-a1b2c3")
  }
}
