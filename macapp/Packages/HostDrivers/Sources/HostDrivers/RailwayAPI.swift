import Foundation
import Synchronization

/// What Railway answered over HTTP: its status and body.
public struct RailwayHTTPResponse: Sendable, Equatable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

/// How Workroom reaches Railway over HTTP, both its GraphQL API and its OAuth endpoints (#627).
/// The one test seam the Railway spec names: tests stub Railway here, so no test needs an account
/// or the network.
public protocol RailwayHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> RailwayHTTPResponse
}

/// The real transport: an ephemeral `URLSession`, so no cookie or cache Railway sets outlives the
/// call.
public struct URLSessionRailwayTransport: RailwayHTTPTransport {
  private let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> RailwayHTTPResponse {
    let (data, response) = try await session.data(for: request)
    return RailwayHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
  }
}

/// Hands the API client an access token (`RailwaySession`), and hears when Railway rejected one.
public protocol RailwayAccessTokenProviding: Sendable {
  func accessToken() async throws -> String
  /// Railway answered 401 to `token`: the next `accessToken()` must not hand it out again.
  func accessTokenRejected(_ token: String) async
}

/// A GraphQL variable's value.
public indirect enum RailwayJSON: Sendable, Equatable, Encodable, ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case object([String: RailwayJSON])
  case array([RailwayJSON])
  case null

  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(dictionaryLiteral elements: (String, RailwayJSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  public init(arrayLiteral elements: RailwayJSON...) { self = .array(elements) }
  public init(nilLiteral: ()) { self = .null }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

/// Why a Railway API call failed.
public enum RailwayAPIError: Error, Equatable, LocalizedError {
  /// Railway answered 2xx with GraphQL errors: their messages. Not proof that nothing was done:
  /// the answer may carry partial data.
  case graphQL([String])
  /// Railway refused the access token, even a fresh one.
  case unauthorized
  /// Any other HTTP failure: its status, and Railway's messages or else its body.
  case http(status: Int, message: String)
  /// An answer that didn't decode.
  case malformed(String)

  public var errorDescription: String? {
    switch self {
    case .graphQL(let messages):
      "Railway said: "
        + messages.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        .joined(separator: ". ")
    case .unauthorized: "Railway didn't accept Workroom's sign-in."
    case .http(let status, let message):
      "Railway answered \(status)\(message.isEmpty ? "" : ": \(message.prefix(200))")."
    case .malformed(let what): "Railway's answer couldn't be read (\(what))."
    }
  }
}

/// Whether a call (`RailwayAPI.query`) sent a request Railway may have acted on: one went out and
/// came back as anything but a refused token (401), or never came back. False when the call
/// failed before sending (signed out, a refresh that failed, a cancel), so a mutation's caller
/// knows nothing was made.
public final class RailwayDelivery: Sendable {
  private let sent = Mutex(false)

  public init() {}

  public var mayHaveActed: Bool { sent.withLock { $0 } }

  func mark(sent value: Bool) { sent.withLock { $0 = value } }
}

/// Railway's public GraphQL API (`backboard.railway.com/graphql/v2`), called with the OAuth
/// access token (ADR 0073), never the `railway` CLI. Small and general: `query` sends one document
/// and decodes its `data`, or throws Railway's error messages. The Railway driver's calls are
/// extensions on it.
public struct RailwayAPI: Sendable {
  public static let endpoint = URL(string: "https://backboard.railway.com/graphql/v2")!

  private let transport: any RailwayHTTPTransport
  private let tokens: any RailwayAccessTokenProviding

  public init(transport: any RailwayHTTPTransport, tokens: any RailwayAccessTokenProviding) {
    self.transport = transport
    self.tokens = tokens
  }

  /// Sends `document` (a query or a mutation) with `variables`, and decodes its `data` as `T`.
  /// A 401 tells the token provider and tries once more with a new token. `delivery` hears
  /// whether a request went out that Railway may have acted on.
  public func query<T: Decodable>(
    _ document: String, variables: [String: RailwayJSON] = [:], as type: T.Type = T.self,
    delivery: RailwayDelivery? = nil
  ) async throws -> T {
    var body: [String: RailwayJSON] = ["query": .string(document)]
    if !variables.isEmpty { body["variables"] = .object(variables) }
    let payload = try JSONEncoder().encode(RailwayJSON.object(body))

    var response = try await send(
      payload, token: try await tokens.accessToken(), delivery: delivery)
    if response.answer.status == 401 {
      await tokens.accessTokenRejected(response.token)
      response = try await send(
        payload, token: try await tokens.accessToken(), delivery: delivery)
      if response.answer.status == 401 { throw RailwayAPIError.unauthorized }
    }
    return try Self.decode(response.answer, as: T.self)
  }

  private func send(_ payload: Data, token: String, delivery: RailwayDelivery?) async throws
    -> (answer: RailwayHTTPResponse, token: String)
  {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = payload
    // A cancel before the request goes out sends nothing.
    try Task.checkCancellation()
    delivery?.mark(sent: true)
    let answer = try await transport.send(request)
    // Railway refused the token: that request did nothing.
    if answer.status == 401 { delivery?.mark(sent: false) }
    return (answer, token)
  }

  private struct Message: Decodable { let message: String }
  private struct Errors: Decodable { let errors: [Message]? }
  private struct Envelope<T: Decodable>: Decodable { let data: T? }

  /// The status decides first: a failed status is an HTTP failure whatever its body says (a 5xx
  /// may have done the work), with Railway's own messages when the body has them.
  private static func decode<T: Decodable>(_ answer: RailwayHTTPResponse, as: T.Type) throws -> T {
    let errors = ((try? JSONDecoder().decode(Errors.self, from: answer.body))?.errors ?? [])
      .map(\.message)
    guard (200..<300).contains(answer.status) else {
      throw RailwayAPIError.http(
        status: answer.status,
        message: errors.isEmpty
          ? String(decoding: answer.body, as: UTF8.self) : errors.joined(separator: ". "))
    }
    if !errors.isEmpty { throw RailwayAPIError.graphQL(errors) }
    let envelope: Envelope<T>
    do { envelope = try JSONDecoder().decode(Envelope<T>.self, from: answer.body) } catch {
      throw RailwayAPIError.malformed(String(describing: error))
    }
    guard let data = envelope.data else { throw RailwayAPIError.malformed("no data") }
    return data
  }
}

// MARK: Workspaces and plans

/// A Railway plan, as `Workspace.plan` names it (`FREE`, `HOBBY`, `PRO`). Trial isn't a plan:
/// it's the workspace's customer `isTrialing`.
public enum RailwayPlan: Sendable, Hashable, Decodable {
  case free, hobby, pro
  case other(String)

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    switch raw {
    case "FREE": self = .free
    case "HOBBY": self = .hobby
    case "PRO": self = .pro
    default: self = .other(raw)
    }
  }

  public var displayName: String {
    switch self {
    case .free: "Free"
    case .hobby: "Hobby"
    case .pro: "Pro"
    case .other(let raw): raw.capitalized
    }
  }
}

/// Why setup refuses a workspace's plan (ADR 0071): on Trial and Free, Railway destroys an idle
/// sandbox after 5 minutes and the timeout can't be turned off.
public enum RailwayPlanRefusal: Sendable, Equatable {
  case trial, free

  public var reason: String {
    let plan = self == .trial ? "a Trial" : "the Free plan"
    return "This workspace is on \(plan). Railway hosts need the Hobby or Pro plan: on Trial and "
      + "Free, Railway destroys a sandbox after 5 minutes without use, and that can't be turned "
      + "off, so a workroom would lose its work."
  }
}

/// A workspace the user granted Workroom on Railway's consent page.
public struct RailwayWorkspace: Sendable, Hashable, Decodable, Identifiable {
  public let id: String
  public let name: String
  public let plan: RailwayPlan

  public init(id: String, name: String, plan: RailwayPlan) {
    self.id = id
    self.name = name
    self.plan = plan
  }

  /// Why setup refuses this workspace, or nil for none. `trialing` nil is a trial check that
  /// couldn't answer, which doesn't refuse: the plan alone decides.
  public func refusal(trialing: Bool?) -> RailwayPlanRefusal? {
    if trialing == true { return .trial }
    return plan == .free ? .free : nil
  }
}

extension RailwayAPI {
  /// The workspaces the user granted (`me { workspaces }`), with their plans. Only fields a
  /// member can read: a workspace's billing (`customer`) is read apart, in `isTrialing`.
  public func grantedWorkspaces() async throws -> [RailwayWorkspace] {
    struct Answer: Decodable {
      struct Me: Decodable { let workspaces: [RailwayWorkspace] }
      let me: Me
    }
    return try await query("query { me { workspaces { id name plan } } }", as: Answer.self)
      .me.workspaces
  }

  /// Whether the workspace is on a Trial (`Workspace.customer.isTrialing`). Whether an OAuth
  /// `workspace:member` token may read a workspace's customer is not documented, so callers treat
  /// a failure as unchecked.
  public func isTrialing(workspaceID: String) async throws -> Bool {
    struct Answer: Decodable {
      struct Workspace: Decodable {
        struct Customer: Decodable { let isTrialing: Bool }
        let customer: Customer
      }
      let workspace: Workspace
    }
    return try await query(
      "query workspace($id: String!) { workspace(workspaceId: $id) { customer { isTrialing } } }",
      variables: ["id": .string(workspaceID)], as: Answer.self
    ).workspace.customer.isTrialing
  }
}
