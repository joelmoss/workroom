import Foundation
import Synchronization
import XCTest

@testable import HostDrivers

/// What the driver assumes of Railway's API and can't check offline (review of #635): that
/// `environment(id:) { projectId }` names an environment's project, that `sandboxes(active:)`
/// leaves out destroyed sandboxes and keeps creating, running and failed ones, and how Railway
/// treats a FAILED sandbox. Opt-in and run by hand like `RailwayHostDriverLiveTests`
/// (`WR_RAILWAY_LIVE_TESTS=1`, `WR_RAILWAY_TOKEN` or `WR_RAILWAY_SIGN_IN=1`,
/// `WR_RAILWAY_WORKSPACE`), with `--filter RailwayAPIAssumptionsLiveTests`.
///
/// It reuses one project, `workroom-api-checks`, and one environment in it, `api-checks`, each made
/// the first time and kept (a member sign-in can delete neither). Every sandbox it makes is
/// destroyed before it ends, failed run or not.
final class RailwayAPIAssumptionsLiveTests: XCTestCase {
  // Value: protects=the lost-create candidates, placement moves, sweep and presence; fails_when=
  // Railway's environment lookup, active filter or FAILED handling differ from what the driver
  // assumes; why_new=only the real API can say; seam=none
  func testRailwaysAPIMeansWhatTheDriverAssumes() async throws {
    let environment = ProcessInfo.processInfo.environment
    let token = environment["WR_RAILWAY_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    unsetenv("WR_RAILWAY_TOKEN")
    guard environment["WR_RAILWAY_LIVE_TESTS"] == "1" else {
      throw XCTSkip("set WR_RAILWAY_LIVE_TESTS=1 to run (docs/designs/railway-live-checks.md)")
    }
    guard let workspace = environment["WR_RAILWAY_WORKSPACE"], !workspace.isEmpty else {
      throw XCTSkip("set WR_RAILWAY_WORKSPACE to run")
    }
    let api: RailwayAPI
    let transport = URLSessionRailwayTransport()
    if let token {
      api = RailwayAPI(transport: transport, tokens: AssumptionsToken(token: token))
    } else if environment["WR_RAILWAY_SIGN_IN"] == "1" {
      guard let clientID = environment["WR_RAILWAY_OAUTH_CLIENT_ID"] ?? Self.infoClientID() else {
        throw XCTSkip("no RailwayOAuthClientID; set WR_RAILWAY_OAUTH_CLIENT_ID")
      }
      let client = RailwayOAuthClient(clientID: clientID, transport: transport)
      Self.log("opening Railway's consent page in the browser: approve the workspace to use")
      let tokens = try await RailwaySignIn(client: client).run { url in
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.absoluteString]
        try? open.run()
      }
      let session = RailwaySession(
        client: client, store: MemoryTokenStore(), lock: InProcessRefreshLock())
      try await session.signIn(with: tokens)
      api = RailwayAPI(transport: transport, tokens: session)
    } else {
      throw XCTSkip("set WR_RAILWAY_TOKEN, or WR_RAILWAY_SIGN_IN=1, to run")
    }

    let suffix = String(UUID().uuidString.prefix(6)).lowercased()
    let project: String
    if let found = try await api.projects(workspaceID: workspace)
      .first(where: { $0.name == "workroom-api-checks" })
    {
      project = found.id
    } else {
      project = try await api.createProject(name: "workroom-api-checks", workspaceID: workspace)
    }
    let place: String
    if let found = try await Self.environment(named: "api-checks", in: project, api) {
      place = found
    } else {
      place = try await api.createEnvironment(name: "api-checks", projectID: project)
    }
    Self.log("project \(project), environment \(place)")
    let made = Made()
    // Runs whatever failed above, after the test body.
    addTeardownBlock {
      let leftovers = made.ids.withLock { $0 }
      for id in leftovers { try? await api.destroySandbox(id, environmentID: place) }
      for id in leftovers {
        _ = try? await Self.wait(api, id, place, seconds: 300) {
          $0 == nil || $0.map(RailwaySandbox.isEnding) == true
        }
      }
    }

    // 1. The environment lookup the sweep, presence and placement fall back on.
    let named = try await api.project(ofEnvironment: place)
    Self.log("environment { projectId } named \(named ?? "nil")")
    XCTAssertEqual(named, project, "environment(id:) { projectId } doesn't name the project")

    // 2. The active filter while a sandbox is being made, once it runs, and once destroyed.
    let running = try await api.createSandbox(environmentID: place)
    made.ids.withLock { $0.append(running) }
    let first = try await api.sandboxStatus(running, environmentID: place)
    let whileNew = try await api.sandboxes(environmentID: place)
    Self.log("new sandbox \(running) is \(first ?? "nil"); active lists \(Self.ids(whileNew))")
    XCTAssertTrue(
      whileNew.contains { $0.id == running },
      "active leaves out a sandbox that is \(first ?? "nil")")
    let up = try await Self.wait(api, running, place, seconds: 300) {
      $0 != RailwaySandbox.creating
    }
    let whileUp = try await api.sandboxes(environmentID: place)
    Self.log("then \(up ?? "nil"); active lists \(Self.ids(whileUp))")
    XCTAssertTrue(whileUp.contains { $0.id == running }, "active leaves out a running sandbox")

    // 3. A FAILED sandbox: a create from a checkpoint that doesn't exist is the one way the
    // suite knows to ask for one.
    var options = RailwaySandboxOptions()
    options.checkpoint = "workroom-no-such-checkpoint-\(suffix)"
    do {
      let broken = try await api.createSandbox(environmentID: place, options: options)
      made.ids.withLock { $0.append(broken) }
      let end = try await Self.wait(api, broken, place, seconds: 300) {
        $0 != RailwaySandbox.creating
      }
      let listed = try await api.sandboxes(environmentID: place)
      Self.log(
        "a create from no checkpoint made \(broken), now \(end ?? "nil"); active "
          + (listed.contains { $0.id == broken } ? "lists it" : "leaves it out"))
      if end == RailwaySandbox.failed {
        XCTAssertTrue(
          listed.contains { $0.id == broken },
          "active leaves out a FAILED sandbox, so a failed lost create is never offered")
        do {
          try await api.destroySandbox(broken, environmentID: place)
          Self.log("Railway accepted a destroy of the FAILED sandbox")
        } catch {
          Self.log("Railway refused a destroy of the FAILED sandbox: \(error)")
        }
        let after = try await Self.wait(api, broken, place, seconds: 120) {
          $0 != RailwaySandbox.failed && $0 != RailwaySandbox.destroying
        }
        Self.log("the FAILED sandbox is \(after ?? "nil") after the destroy")
      }
    } catch {
      Self.log("Railway refused a create from no checkpoint outright, no FAILED sandbox: \(error)")
    }

    try await api.destroySandbox(running, environmentID: place)
    let gone = try await Self.wait(api, running, place, seconds: 300) {
      $0 == nil || $0 == RailwaySandbox.destroyed
    }
    let afterDestroy = try await api.sandboxes(environmentID: place)
    let unfiltered = try await Self.allSandboxes(api, place)
    Self.log(
      "destroyed sandbox is \(gone ?? "nil"); active lists \(Self.ids(afterDestroy)); "
        + "unfiltered lists \(Self.ids(unfiltered))")
    XCTAssertFalse(
      afterDestroy.contains { $0.id == running && $0.status == RailwaySandbox.destroyed },
      "active still lists a destroyed sandbox")
  }

  // MARK: Helpers

  private static func log(_ text: String) { print("railway api check: \(text)") }

  private static func ids(_ sandboxes: [RailwaySandbox]) -> String {
    sandboxes.isEmpty
      ? "nothing" : sandboxes.map { "\($0.id) \($0.status)" }.joined(separator: ", ")
  }

  /// Polls the sandbox's status every 5 s until `done` holds or `seconds` pass: the last status.
  private static func wait(
    _ api: RailwayAPI, _ id: String, _ environment: String, seconds: Int,
    until done: (String?) -> Bool
  ) async throws -> String? {
    var status = try await api.sandboxStatus(id, environmentID: environment)
    var waited = 0
    while !done(status) && waited < seconds {
      try await Task.sleep(nanoseconds: 5_000_000_000)
      waited += 5
      status = try await api.sandboxStatus(id, environmentID: environment)
    }
    return status
  }

  /// The environment's sandboxes with no `active` filter, destroyed ones and all.
  private static func allSandboxes(_ api: RailwayAPI, _ environment: String) async throws
    -> [RailwaySandbox]
  {
    struct Answer: Decodable { let sandboxes: RailwayConnection<RailwaySandbox> }
    return try await api.pages { after in
      var variables: [String: RailwayJSON] = ["environmentId": .string(environment), "first": 100]
      if let after { variables["after"] = .string(after) }
      return try await api.query(
        "query sandboxes($environmentId: String!, $first: Int, $after: String) { sandboxes("
          + "environmentId: $environmentId, first: $first, after: $after) { edges { node { id "
          + "status createdAt environmentId } } pageInfo { hasNextPage endCursor } } }",
        variables: variables, as: Answer.self
      ).sandboxes
    }
  }

  /// The id of `project`'s environment called `name`, if it has one.
  private static func environment(named name: String, in project: String, _ api: RailwayAPI)
    async throws -> String?
  {
    struct Answer: Decodable {
      struct Project: Decodable {
        struct Connection: Decodable {
          struct Edge: Decodable {
            struct Node: Decodable {
              let id: String
              let name: String
            }
            let node: Node
          }
          let edges: [Edge]
        }
        let environments: Connection
      }
      let project: Project
    }
    return try await api.query(
      "query project($id: String!) { project(id: $id) { environments { edges { node { id name "
        + "} } } } }",
      variables: ["id": .string(project)], as: Answer.self
    ).project.environments.edges.first { $0.node.name == name }?.node.id
  }

  private static func infoClientID() -> String? {
    guard let data = try? Data(contentsOf: LiveSettings.info),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return (plist["RailwayOAuthClientID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// The sandboxes the check made, for its teardown.
private final class Made: Sendable {
  let ids = Mutex<[String]>([])
}

private struct AssumptionsToken: RailwayAccessTokenProviding {
  let token: String
  func accessToken() async throws -> String { token }
  func accessTokenRejected(_ token: String) async {}
}
