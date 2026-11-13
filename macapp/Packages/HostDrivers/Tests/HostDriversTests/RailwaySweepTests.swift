import Foundation
import WorkroomDomain
import XCTest

@testable import HostDrivers

/// The Railway launch sweep (#630, ADR 0071) with Railway stubbed at HTTP (`StubRailway`): a
/// sandbox has no name or label, so this Mac's environment is all that says a sandbox is its own,
/// and a sandbox there that no host record names is billing for nothing.
final class RailwaySweepTests: XCTestCase {
  private struct Tokens: RailwayAccessTokenProviding {
    func accessToken() async throws -> String { "at-1" }
    func accessTokenRejected(_ token: String) async {}
  }

  private struct SignedOut: RailwayAccessTokenProviding {
    func accessToken() async throws -> String { throw RailwaySessionError.signedOut }
    func accessTokenRejected(_ token: String) async {}
  }

  /// Made well before any create still under way could have made it.
  static let old = "2026-11-01T09:00:00.000Z"

  private var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-sweep-\(UUID().uuidString)")
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  private func driver(
    _ railway: StubRailway, tokens: any RailwayAccessTokenProviding = Tokens(),
    relay: RailwayHostDriverTests.StubRelay = .init()
  ) -> RailwayHostDriver {
    RailwayHostDriver(
      configuration: .init(
        environmentID: "env-1", projectID: "prj-1", keys: root.appendingPathComponent("railway"),
        relayHost: RailwayHostDriverTests.relayHost, hostSetup: .checkout,
        pollInterval: .milliseconds(1)),
      api: RailwayAPI(transport: railway, tokens: tokens),
      directory: root.appendingPathComponent("hosts"), runner: relay)
  }

  /// A sandbox row as `sandboxes` lists it.
  private static func sandbox(
    _ id: String, status: String = "RUNNING", createdAt: String = old,
    environment: String = "env-1"
  ) -> [String: Any] {
    ["id": id, "status": status, "createdAt": createdAt, "environmentId": environment]
  }

  /// A Railway whose `sandboxes` lists `rows` on one page, and that destroys whatever it is asked.
  private func railway(_ rows: [[String: Any]]) -> StubRailway {
    let railway = StubRailway()
    railway.answer(
      "sandboxes",
      data: [
        "sandboxes": [
          "edges": rows.map { ["cursor": $0["id"]!, "node": $0] },
          "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ]
      ])
    railway.answer("sandboxDestroy") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let body = try JSONSerialization.data(withJSONObject: [
        "data": ["sandboxDestroy": ["id": variables["id"]!, "status": "DESTROYING"]]
      ])
      return RailwayHTTPResponse(status: 200, body: body)
    }
    return railway
  }

  private func requests(_ railway: StubRailway, _ field: String) -> [[String: Any]] {
    railway.graphQLRequests.map(StubRailway.graphQLBody)
      .filter { ($0["query"] as? String)?.contains("\(field)(") == true }
      .map { $0["variables"] as? [String: Any] ?? [:] }
  }

  private func destroyed(_ railway: StubRailway) -> Set<String> {
    Set(requests(railway, "sandboxDestroy").compactMap { $0["id"] as? String })
  }

  /// Value: protects=no sandbox is left billing that no workroom names, and no other Mac's host is
  /// touched (ADR 0071); fails_when=an unnamed sandbox in this Mac's environment survives the
  /// sweep, a recorded one goes, or the sweep lists or destroys in another environment;
  /// seam=RailwayHostDriver.sweep over StubRailway
  func testTheSweepDestroysEverySandboxInThisMacsEnvironmentThatNoRecordNames() async throws {
    let railway = railway([
      Self.sandbox("sbx-orphan"), Self.sandbox("sbx-kept"), Self.sandbox("sbx-orphan-2"),
    ])
    let failures = try await driver(railway).sweep(keeping: ["sbx-kept"])
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(railway), ["sbx-orphan", "sbx-orphan-2"])
    let sent = requests(railway, "sandboxes") + requests(railway, "sandboxDestroy")
    XCTAssertFalse(sent.isEmpty)
    for variables in sent {
      XCTAssertEqual(variables["environmentId"] as? String, "env-1", "\(variables)")
    }
  }

  /// Value: protects=a create still under way keeps its sandbox, in this app or in the other build
  /// sharing the environment (Release and Nightly, ADR 0036); fails_when=the sweep destroys a
  /// sandbox no record names yet because its create hasn't recorded it, or asks Railway to destroy
  /// one already gone; seam=RailwayHostDriver.sweep over StubRailway
  func testTheSweepLeavesACreateStillUnderWayAndWhatIsGone() async throws {
    let now = ISO8601DateFormatter().string(from: Date())
    let railway = railway([
      Self.sandbox("sbx-1", createdAt: Self.old),  // This app's create, not yet recorded.
      Self.sandbox("sbx-other-build", createdAt: now),
      Self.sandbox("sbx-unparsed", createdAt: "soon"),
      Self.sandbox("sbx-destroyed", status: "DESTROYED"),
      Self.sandbox("sbx-destroying", status: "DESTROYING"),
    ])
    railway.answer("sshPublicKeys", data: ["sshPublicKeys": ["edges": []]])
    railway.answer("sshPublicKeyCreate", data: ["sshPublicKeyCreate": ["id": "key-1"]])
    railway.answer(
      "sandboxCreate", data: ["sandboxCreate": ["id": "sbx-1", "status": "CREATING"]])
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "RUNNING"]])
    let driver = driver(railway)
    _ = try await driver.create()

    let failures = try await driver.sweep(keeping: [])
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(railway), [])
  }

  /// Value: protects=an environment with more sandboxes than one page (Railway's cap is up to 100)
  /// is swept whole; fails_when=the sweep reads only the first page; seam=RailwayHostDriver.sweep
  /// over StubRailway
  func testTheSweepReadsEveryPage() async throws {
    let railway = railway([])
    railway.answer("sandboxes") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let second = variables["after"] as? String == "page-2"
      let row = Self.sandbox(second ? "sbx-b" : "sbx-a")
      let body = try JSONSerialization.data(withJSONObject: [
        "data": [
          "sandboxes": [
            "edges": [["cursor": row["id"]!, "node": row]],
            "pageInfo": [
              "hasNextPage": !second, "endCursor": second ? NSNull() : "page-2",
            ] as [String: Any],
          ]
        ]
      ])
      return RailwayHTTPResponse(status: 200, body: body)
    }
    _ = try await driver(railway).sweep(keeping: [])
    XCTAssertEqual(destroyed(railway), ["sbx-a", "sbx-b"])
  }

  /// Value: protects=a sweep Railway couldn't answer is owed again, and one destroy Railway refused
  /// is reported without stopping the rest; fails_when=a signed-out or failed listing reads as an
  /// empty environment, or a refused destroy is lost or ends the sweep; seam=RailwayHostDriver.sweep
  /// over StubRailway
  func testASweepRailwayCannotAnswerThrowsAndARefusedDestroyIsReported() async throws {
    do {
      _ = try await driver(railway([Self.sandbox("sbx-a")]), tokens: SignedOut()).sweep(
        keeping: [])
      XCTFail("a signed-out sweep read as an empty environment")
    } catch RailwaySessionError.signedOut {}

    let railway = railway([Self.sandbox("sbx-stuck"), Self.sandbox("sbx-b")])
    railway.answer("sandboxDestroy") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let id = variables["id"] as? String ?? ""
      let body =
        id == "sbx-stuck"
        ? #"{"errors":[{"message":"Railway is down"}]}"#
        : #"{"data":{"sandboxDestroy":{"id":"\#(id)","status":"DESTROYING"}}}"#
      return RailwayHTTPResponse(status: 200, body: Data(body.utf8))
    }
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-stuck", "status": "RUNNING"]])
    let failures = try await driver(railway).sweep(keeping: [])
    XCTAssertEqual(failures.count, 1, "\(failures)")
    XCTAssertTrue(failures.first?.contains("sbx-stuck") == true, "\(failures)")
    XCTAssertEqual(destroyed(railway), ["sbx-stuck", "sbx-b"])
  }
}
