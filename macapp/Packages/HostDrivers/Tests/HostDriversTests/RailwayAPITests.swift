import Foundation
import Synchronization
import XCTest

@testable import HostDrivers

/// Railway's GraphQL API client (#627), with Railway stubbed at HTTP (`StubRailway`): the seam the
/// Railway driver's later tickets call through.
final class RailwayAPITests: XCTestCase {
  /// A token provider that hands out `tokens` in turn, recording the ones the API rejected.
  private final class Tokens: RailwayAccessTokenProviding, Sendable {
    private let state: Mutex<(next: [String], rejected: [String])>
    init(_ tokens: [String]) { state = Mutex((tokens, [])) }
    var rejected: [String] { state.withLock { $0.rejected } }
    func accessToken() async throws -> String {
      state.withLock { $0.next.count > 1 ? $0.next.removeFirst() : $0.next[0] }
    }
    func accessTokenRejected(_ token: String) async {
      state.withLock { $0.rejected.append(token) }
    }
  }

  private struct Me: Decodable, Equatable {
    struct User: Decodable, Equatable { let email: String }
    let me: User
  }

  /// Value: protects=every Railway call is a POST of the query and its variables to
  /// backboard.railway.com/graphql/v2 with the access token as a bearer; fails_when=the token,
  /// endpoint or body is wrong, or `data` doesn't decode; seam=RailwayAPI over the HTTP transport
  func testAQuerySendsTheBearerTokenAndDecodesItsData() async throws {
    let railway = StubRailway()
    railway.answer("me", data: ["me": ["email": "me@x.dev"]])
    let api = RailwayAPI(transport: railway, tokens: Tokens(["at-1"]))

    let me = try await api.query(
      "query me($n: Int) { me { email } }", variables: ["n": 3], as: Me.self)

    XCTAssertEqual(me, Me(me: .init(email: "me@x.dev")))
    let request = try XCTUnwrap(railway.graphQLRequests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = StubRailway.graphQLBody(request)
    XCTAssertEqual(body["query"] as? String, "query me($n: Int) { me { email } }")
    XCTAssertEqual((body["variables"] as? [String: Any])?["n"] as? Int, 3)
  }

  /// Value: protects=Railway's own words reach the user when it refuses a call; fails_when=the
  /// error loses the messages or a partial `data` is taken as success; seam=RailwayAPI
  func testRailwaysErrorsComeBackAsItsMessages() async {
    let railway = StubRailway()
    railway.answer("me") { _ in
      RailwayHTTPResponse(
        status: 200,
        body: Data(
          #"{"data":null,"errors":[{"message":"Not Authorized"},{"message":"Try later"}]}"#.utf8))
    }
    let api = RailwayAPI(transport: railway, tokens: Tokens(["at-1"]))

    do {
      _ = try await api.query("query { me { email } }", as: Me.self)
      XCTFail("an errors answer decoded")
    } catch {
      XCTAssertEqual(error as? RailwayAPIError, .graphQL(["Not Authorized", "Try later"]))
      XCTAssertEqual(error.localizedDescription, "Railway said: Not Authorized. Try later")
    }
  }

  /// Value: protects=an access token Railway rejects (401) is refreshed and the call made once
  /// more, so an hour-old token never surfaces as an error; fails_when=it surfaces, or retries
  /// forever; seam=RailwayAPI with its token provider
  func testARejectedTokenIsReportedAndTheCallRetriedOnce() async throws {
    let railway = StubRailway()
    railway.answer("me") { request in
      request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
        ? RailwayHTTPResponse(status: 200, body: Data(#"{"data":{"me":{"email":"a@b"}}}"#.utf8))
        : RailwayHTTPResponse(status: 401, body: Data("Unauthorized".utf8))
    }
    let tokens = Tokens(["stale", "fresh"])
    let api = RailwayAPI(transport: railway, tokens: tokens)

    let me = try await api.query("query { me { email } }", as: Me.self)

    XCTAssertEqual(me.me.email, "a@b")
    XCTAssertEqual(tokens.rejected, ["stale"])

    let always = StubRailway()
    always.answer("me") { _ in RailwayHTTPResponse(status: 401, body: Data()) }
    do {
      _ = try await RailwayAPI(transport: always, tokens: Tokens(["x"]))
        .query("query { me { email } }", as: Me.self)
      XCTFail("a 401 decoded")
    } catch {
      XCTAssertEqual(error as? RailwayAPIError, .unauthorized)
      XCTAssertEqual(always.graphQLRequests.count, 2)
    }
  }

  /// Value: protects=a server failure says its status, not a decoding error, even with GraphQL
  /// errors in its body (review 3, C1); fails_when=a 5xx reads as Railway refusing; seam=RailwayAPI
  func testAServerFailureSaysItsStatus() async {
    let railway = StubRailway()
    railway.answer("me") { _ in RailwayHTTPResponse(status: 503, body: Data("down".utf8)) }
    do {
      _ = try await RailwayAPI(transport: railway, tokens: Tokens(["x"]))
        .query("query { me { email } }", as: Me.self)
      XCTFail("a 503 decoded")
    } catch {
      XCTAssertEqual(error as? RailwayAPIError, .http(status: 503, message: "down"))
    }

    // GraphQL errors on a server failure are still the server's failure, with Railway's words.
    let erring = StubRailway()
    erring.answer("me") { _ in
      RailwayHTTPResponse(status: 502, body: Data(#"{"errors":[{"message":"Upstream"}]}"#.utf8))
    }
    do {
      _ = try await RailwayAPI(transport: erring, tokens: Tokens(["x"]))
        .query("query { me { email } }", as: Me.self)
      XCTFail("a 502 decoded")
    } catch {
      XCTAssertEqual(error as? RailwayAPIError, .http(status: 502, message: "Upstream"))
    }
  }

  // MARK: Workspaces and plans

  /// Value: protects=the sheet lists the workspaces the user granted with their plans (`me {
  /// workspaces }`); fails_when=a workspace or its plan is lost; seam=RailwayAPI.grantedWorkspaces
  func testGrantedWorkspacesComeWithTheirPlans() async throws {
    let railway = StubRailway()
    railway.answer(
      "me",
      data: [
        "me": [
          "workspaces": [
            ["id": "ws-1", "name": "Personal", "plan": "HOBBY"],
            ["id": "ws-2", "name": "Codaset", "plan": "FREE"],
          ]
        ]
      ])
    let api = RailwayAPI(transport: railway, tokens: Tokens(["x"]))

    let workspaces = try await api.grantedWorkspaces()

    XCTAssertEqual(
      workspaces,
      [
        RailwayWorkspace(id: "ws-1", name: "Personal", plan: .hobby),
        RailwayWorkspace(id: "ws-2", name: "Codaset", plan: .free),
      ])
    let query = StubRailway.graphQLBody(railway.graphQLRequests[0])["query"] as? String ?? ""
    XCTAssertFalse(query.contains("customer"), "the listing must not depend on billing access")
  }

  /// Value: protects=Trial is read per workspace from its customer, as a separate call;
  /// seam=RailwayAPI.isTrialing
  func testTrialIsReadFromTheWorkspacesCustomer() async throws {
    let railway = StubRailway()
    railway.answer("workspace") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any]
      XCTAssertEqual(variables?["id"] as? String, "ws-1")
      return RailwayHTTPResponse(
        status: 200, body: Data(#"{"data":{"workspace":{"customer":{"isTrialing":true}}}}"#.utf8))
    }
    let trialing = try await RailwayAPI(transport: railway, tokens: Tokens(["x"]))
      .isTrialing(workspaceID: "ws-1")
    XCTAssertTrue(trialing)
  }

  /// Value: protects=Trial and Free are refused with the reason, Hobby and Pro allowed, and a
  /// plan this build doesn't know isn't refused; seam=RailwayWorkspace.refusal
  func testTrialAndFreeAreRefusedWithTheReason() {
    let free = RailwayWorkspace(id: "a", name: "A", plan: .free)
    let hobby = RailwayWorkspace(id: "b", name: "B", plan: .hobby)
    let pro = RailwayWorkspace(id: "c", name: "C", plan: .pro)
    let newer = RailwayWorkspace(id: "d", name: "D", plan: .other("ENTERPRISE"))

    XCTAssertEqual(free.refusal(trialing: false), RailwayPlanRefusal.free)
    XCTAssertEqual(hobby.refusal(trialing: true), RailwayPlanRefusal.trial)
    XCTAssertNil(hobby.refusal(trialing: false))
    XCTAssertNil(pro.refusal(trialing: nil))
    XCTAssertNil(newer.refusal(trialing: nil))
    XCTAssertTrue(RailwayPlanRefusal.free.reason.contains("Hobby or Pro"))
    XCTAssertTrue(RailwayPlanRefusal.trial.reason.contains("5 minutes"))
  }

  /// A `sandboxes` page of `id`, saying there is a next page after `cursor` (none for nil).
  private static func page(_ id: String, next cursor: String?, hasNext: Bool? = nil) throws
    -> RailwayHTTPResponse
  {
    let row: [String: Any] = [
      "id": id, "status": "RUNNING", "createdAt": "2026-11-01T09:00:00Z", "environmentId": "env-1",
    ]
    return RailwayHTTPResponse(
      status: 200,
      body: try JSONSerialization.data(withJSONObject: [
        "data": [
          "sandboxes": [
            "edges": [["cursor": id, "node": row]],
            "pageInfo": [
              "hasNextPage": hasNext ?? (cursor != nil), "endCursor": cursor ?? NSNull(),
            ] as [String: Any],
          ]
        ]
      ]))
  }

  /// Value: protects=an environment with more sandboxes than one page (Railway's cap is up to
  /// 100) is listed whole, and a cursor Railway repeats, or a next page with no cursor, fails the
  /// listing rather than looping forever or handing back part of it, from which the sweep could
  /// match the wrong sandbox (review #8, review 3 C3); fails_when=only the first page is read, a
  /// repeated `endCursor` is asked for again and again, or a partial list is returned;
  /// seam=RailwayAPI.sandboxes over StubRailway
  func testSandboxesReadsEveryPageAndFailsWhenTheCursorDoesNotAdvance() async throws {
    let railway = StubRailway()
    railway.answer("sandboxes") { request in
      let after = (StubRailway.graphQLBody(request)["variables"] as? [String: Any])?["after"]
      return try Self.page(after == nil ? "sbx-a" : "sbx-b", next: after == nil ? "page-2" : nil)
    }
    let api = RailwayAPI(transport: railway, tokens: Tokens(["at-1"]))
    let all = try await api.sandboxes(environmentID: "env-1")
    XCTAssertEqual(all.map(\.id), ["sbx-a", "sbx-b"])

    let stuck = StubRailway()
    let asked = Mutex(0)
    stuck.answer("sandboxes") { _ in
      // Bounded, so the defect fails the test instead of hanging it.
      guard
        asked.withLock({
          $0 += 1
          return $0
        }) <= 10
      else { throw URLError(.cancelled) }
      return try Self.page("sbx-a", next: "page-2")
    }
    do {
      let listed = try await RailwayAPI(transport: stuck, tokens: Tokens(["at-1"]))
        .sandboxes(environmentID: "env-1")
      XCTFail("a repeated cursor handed back part of the list: \(listed.map(\.id))")
    } catch RailwayAPIError.malformed {}
    XCTAssertEqual(asked.withLock { $0 }, 2, "asked again for a cursor that didn't advance")

    let cursorless = StubRailway()
    cursorless.answer("sandboxes") { _ in try Self.page("sbx-a", next: nil, hasNext: true) }
    do {
      _ = try await RailwayAPI(transport: cursorless, tokens: Tokens(["at-1"]))
        .sandboxes(environmentID: "env-1")
      XCTFail("a next page with no cursor handed back part of the list")
    } catch RailwayAPIError.malformed {}
  }

  /// Value: protects=a listing whose cursors keep advancing without end (a Railway bug, a hostile
  /// answer) fails after `RailwayAPI.maxPages` pages rather than asking forever (review 4, Y2);
  /// fails_when=the pager has no bound, or stops early and hands back part of the list;
  /// seam=RailwayAPI.sandboxes over StubRailway
  func testAListingWithEndlessPagesFailsAfterItsBound() async throws {
    let railway = StubRailway()
    let asked = Mutex(0)
    railway.answer("sandboxes") { _ in
      let n = asked.withLock {
        $0 += 1
        return $0
      }
      // Bounded, so the defect fails the test instead of hanging it.
      guard n <= RailwayAPI.maxPages + 50 else { throw URLError(.cancelled) }
      return try Self.page("sbx-\(n)", next: "page-\(n + 1)")
    }
    do {
      let listed = try await RailwayAPI(transport: railway, tokens: Tokens(["at-1"]))
        .sandboxes(environmentID: "env-1")
      XCTFail("an endless listing handed back \(listed.count) sandboxes")
    } catch RailwayAPIError.malformed {}
    XCTAssertEqual(asked.withLock { $0 }, RailwayAPI.maxPages)
  }

  /// Value: protects=the Mac's key is found on an account with more ssh keys than one page, so
  /// it isn't registered again, and the listing fails rather than loops on a repeated cursor
  /// (review 3, I3); fails_when=only the first page is read, or a repeated cursor is followed;
  /// seam=RailwayAPI.sshPublicKeys over StubRailway
  func testSSHPublicKeysReadsEveryPage() async throws {
    @Sendable func keys(_ key: String, next: String?) throws -> RailwayHTTPResponse {
      RailwayHTTPResponse(
        status: 200,
        body: try JSONSerialization.data(withJSONObject: [
          "data": [
            "sshPublicKeys": [
              "edges": [["node": ["id": key, "publicKey": key]]],
              "pageInfo": [
                "hasNextPage": next != nil, "endCursor": next.map { $0 as Any } ?? NSNull(),
              ],
            ]
          ]
        ]))
    }
    let railway = StubRailway()
    railway.answer("sshPublicKeys") { request in
      let after = (StubRailway.graphQLBody(request)["variables"] as? [String: Any])?["after"]
      return try after == nil
        ? keys("ssh-ed25519 AAAA1", next: "c1") : keys("ssh-ed25519 AAAA2", next: nil)
    }
    let all = try await RailwayAPI(transport: railway, tokens: Tokens(["at-1"])).sshPublicKeys()
    XCTAssertEqual(all, ["ssh-ed25519 AAAA1", "ssh-ed25519 AAAA2"])

    let stuck = StubRailway()
    let asked = Mutex(0)
    stuck.answer("sshPublicKeys") { _ in
      guard
        asked.withLock({
          $0 += 1
          return $0
        }) <= 10
      else { throw URLError(.cancelled) }
      return try keys("ssh-ed25519 AAAA1", next: "c1")
    }
    do {
      _ = try await RailwayAPI(transport: stuck, tokens: Tokens(["at-1"])).sshPublicKeys()
      XCTFail("a repeated cursor handed back part of the keys")
    } catch RailwayAPIError.malformed {}
    XCTAssertEqual(asked.withLock { $0 }, 2)
  }
}
