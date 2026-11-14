import Foundation
import Synchronization

@testable import HostDrivers

/// Railway stubbed at HTTP (#627): answers the GraphQL endpoint by the first operation field a
/// query names (`me`, `workspace`), and the OAuth token endpoint by its `grant_type`. Records every
/// request, so a test can read what Workroom sent.
final class StubRailway: RailwayHTTPTransport, Sendable {
  typealias Answer = @Sendable (URLRequest) throws -> RailwayHTTPResponse

  private let graphQL = Mutex<[String: Answer]>([:])
  private let token = Mutex<[String: Answer]>([:])
  private let sent = Mutex<[URLRequest]>([])

  /// Answers GraphQL queries that name `field` with `data` as their `data`.
  func answer(_ field: String, data: [String: Any]) {
    let body = try! JSONSerialization.data(withJSONObject: ["data": data])
    answer(field) { _ in RailwayHTTPResponse(status: 200, body: body) }
  }

  func answer(_ field: String, _ answer: @escaping Answer) {
    graphQL.withLock { $0[field] = answer }
  }

  /// Answers the token endpoint's `grantType` requests.
  func answerToken(_ grantType: String, _ answer: @escaping Answer) {
    token.withLock { $0[grantType] = answer }
  }

  /// A token response with `refresh` as its refresh token (none for nil).
  static func tokens(access: String, refresh: String?, expiresIn: Int = 3600)
    -> RailwayHTTPResponse
  {
    var json: [String: Any] = [
      "access_token": access, "expires_in": expiresIn, "token_type": "Bearer",
      "scope": RailwayOAuthClient.scopes,
    ]
    if let refresh { json["refresh_token"] = refresh }
    return RailwayHTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: json))
  }

  static func oauthError(_ code: String, status: Int = 400) -> RailwayHTTPResponse {
    RailwayHTTPResponse(
      status: status,
      body: try! JSONSerialization.data(withJSONObject: [
        "error": code, "error_description": "The refresh token is invalid.",
      ]))
  }

  /// A connection's only page, of `nodes`.
  static func lastPage(_ nodes: [[String: Any]]) -> [String: Any] {
    [
      "edges": nodes.map { ["node": $0] },
      "pageInfo": ["hasNextPage": false, "endCursor": NSNull()] as [String: Any],
    ]
  }

  var requests: [URLRequest] { sent.withLock { $0 } }
  var tokenRequests: [[String: String]] {
    requests.filter { $0.url == RailwayOAuthClient.tokenEndpoint }.map(Self.form)
  }
  var graphQLRequests: [URLRequest] { requests.filter { $0.url == RailwayAPI.endpoint } }

  static func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body.replacingOccurrences(of: "+", with: "%20")
    return Dictionary(
      (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
  }

  static func graphQLBody(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
  }

  func send(_ request: URLRequest) async throws -> RailwayHTTPResponse {
    sent.withLock { $0.append(request) }
    if request.url == RailwayOAuthClient.tokenEndpoint {
      let grant = Self.form(request)["grant_type"] ?? ""
      guard let answer = token.withLock({ $0[grant] }) else {
        return Self.oauthError("unsupported_grant_type")
      }
      return try answer(request)
    }
    let query = Self.graphQLBody(request)["query"] as? String ?? ""
    let field = Self.firstField(of: query)
    guard let answer = graphQL.withLock({ $0[field] }) else {
      let body = try JSONSerialization.data(withJSONObject: [
        "errors": [["message": "Problem processing request: no stub for \(field)"]]
      ])
      return RailwayHTTPResponse(status: 200, body: body)
    }
    return try answer(request)
  }

  /// The first field a query or mutation selects: `me` in `query { me { … } }`.
  private static func firstField(of query: String) -> String {
    guard let open = query.firstIndex(of: "{") else { return "" }
    let rest = query[query.index(after: open)...].drop(while: { $0.isWhitespace })
    return String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
  }
}

/// A token store in memory, as the Keychain would hold it.
final class MemoryTokenStore: RailwayTokenStore, Sendable {
  private let value: Mutex<String?>
  init(_ value: String? = nil) { self.value = Mutex(value) }
  var token: String? { value.withLock { $0 } }
  func read() throws -> String? { value.withLock { $0 } }
  func write(_ token: String) throws { value.withLock { $0 = token } }
  func delete() throws { value.withLock { $0 = nil } }
}
