import CryptoKit
import Foundation

/// A typed "no" from the broker. `code` is a contract with Codaset (`Broker::Refusal`); the
/// message shown to the user is Workroom's own.
struct BrokerRefusal: Error, Equatable, Sendable {
  let status: Int
  let code: String
  let message: String
  /// `app_not_installed` carries where an admin installs the App (`codaset.dev/install/{owner}`).
  let installURL: URL?

  /// What Workroom says, for the codes a person can act on (#251).
  var userMessage: String {
    switch code {
    case "app_not_installed":
      return "The Workroom GitHub App doesn't cover this repository, or it was deleted. "
        + "An admin of its owner can install the App."
    case "no_push_access": return "You can't push to this repository on GitHub."
    case "no_read_access": return "You can't read this repository on GitHub."
    case "ip_allow_list":
      return "This organisation limits GitHub access to an IP allow list, which Workroom "
        + "doesn't support yet."
    case "sign_in_required":
      return "Sign in to Codaset again: Workroom's GitHub access has stopped working."
    case "unknown_key": return "This Mac was removed from Codaset. Sign in again."
    case "rate_limited": return "Too many requests to Codaset. Try again in a few minutes."
    case "github_unavailable": return "GitHub isn't responding. Try again shortly."
    case "invalid_code": return "The sign-in expired. Start again."
    default: return message
    }
  }
}

enum BrokerError: Error, Equatable, Sendable, LocalizedError {
  case refused(BrokerRefusal)
  /// A remote workroom's agent was refused while enrolling (`AgentEnrolment`).
  case agentRefused(BrokerRefusal)
  /// A remote workroom's agent failed for its own reasons.
  case agent(String)
  case transport(String)
  case malformed(String)
  case keyStorage(String)
  case signIn(String)

  var errorDescription: String? {
    switch self {
    case .refused(let refusal): return refusal.userMessage
    // The broker's own message for a bad enrolment code says which (unknown, expired, another
    // workroom's); the sign-in wording does not apply.
    case .agentRefused(let refusal):
      return refusal.code == "invalid_code" ? refusal.message : refusal.userMessage
    case .agent(let detail): return detail
    case .transport(let detail): return "Couldn't reach Codaset: \(detail)"
    case .malformed(let detail): return "Codaset sent an unexpected answer: \(detail)"
    case .keyStorage(let detail): return "Couldn't store this Mac's key: \(detail)"
    case .signIn(let detail): return detail
    }
  }
}

/// A DPoP-shaped proof (RFC 9449) for one request, as `Broker::Proof` verifies it: an ES256 JWT
/// with the public key in its header, bound to the method and the URL without its query.
enum BrokerProof {
  static func make(key: BrokerDeviceKey, method: String, url: URL, issuedAt: Date) throws -> String
  {
    var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
    target?.query = nil
    target?.fragment = nil
    guard let htu = target?.string else { throw BrokerError.malformed("bad URL \(url)") }
    var jti = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, jti.count, &jti) == errSecSuccess else {
      throw BrokerError.keyStorage("no randomness for the proof")
    }
    let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": jwk(key.publicKey)]
    let claims: [String: Any] = [
      "htm": method, "htu": htu, "iat": Int(issuedAt.timeIntervalSince1970),
      "jti": Data(jti).base64URL,
    ]
    let input = try [header, claims].map { try encode($0).base64URL }.joined(separator: ".")
    return input + "." + (try key.signature(for: Data(input.utf8))).base64URL
  }

  /// The public half as a JWK. `rawRepresentation` is x || y, 32 bytes each.
  static func jwk(_ key: P256.Signing.PublicKey) -> [String: String] {
    let raw = key.rawRepresentation
    return [
      "kty": "EC", "crv": "P-256",
      "x": raw.prefix(32).base64URL, "y": raw.suffix(32).base64URL,
    ]
  }

  private static func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}

extension Data {
  /// base64url without padding, as JWTs and PKCE use it.
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

/// The Mac's calls to the Workroom broker, each signed with this Mac's key.
struct BrokerClient: Sendable {
  /// Per request; the agent's side uses 15 s (`broker.rs`), the Mac is not on a shared exec budget.
  static let requestTimeout: TimeInterval = 30

  /// Sent with every request, so Codaset can show which build and version created its records:
  /// `Workroom/2.1.0 (nightly; build 4321)`.
  static let userAgent = makeUserAgent(
    version: AppVersion.current,
    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
    kind: buildKind())

  static func makeUserAgent(version: String?, build: String?, kind: String) -> String {
    "Workroom/\(version ?? "unknown") (\(kind); build \(build ?? "unknown"))"
  }

  /// `dev` for a Debug build, `nightly` for Workroom Nightly, `release` for the main app.
  static func buildKind(
    nightly: Bool = ReleaseChannel.isNightlyBuild, debug: Bool = SentryConfig.isDebugBuild
  ) -> String {
    debug ? "dev" : nightly ? "nightly" : "release"
  }

  /// `BrokerSession.baseURL`; every request is checked against `BrokerEndpoint` first.
  let baseURL: URL
  let key: BrokerDeviceKey
  var session: URLSession = .shared
  var now: @Sendable () -> Date = { Date() }

  struct Device: Decodable, Equatable, Sendable {
    let deviceId: String
    let login: String
    let email: String
  }

  struct Grant: Decodable, Equatable, Sendable {
    let grantId: String
    let enrolmentCode: String
    let repositoryId: Int
    let expiresAt: String
  }

  /// A read-only installation token for cloning a base machine (#252). The broker does not keep
  /// it, so only GitHub can revoke it (`CloneToken.revoke`); otherwise it lives out its hour.
  struct CloneToken: Decodable, Sendable {
    let token: String
    let expiresAt: String
  }

  private struct State: Decodable { let state: String }

  /// Redeems the loopback code, registering this client's key as a new device.
  func redeem(code: String, verifier: String, name: String) async throws -> Device {
    try await send(
      "POST", "broker/devices", body: ["code": code, "code_verifier": verifier, "name": name])
  }

  /// Tells the broker this Mac stored its key, so the browser's page may say "signed in".
  func complete(attempt: String) async throws {
    let _: State = try await send("POST", "broker/sign-in-attempts/\(attempt)/complete", body: nil)
  }

  func createGrant(repository: String, workroomID: UUID) async throws -> Grant {
    try await send(
      "POST", "broker/grants",
      body: ["repository": repository, "workroom_id": workroomID.uuidString.lowercased()])
  }

  func cancelGrant(_ grantID: String) async throws {
    let _: State = try await send("DELETE", "broker/grants/\(grantID)", body: nil)
  }

  func baseCloneToken(repository: String) async throws -> CloneToken {
    try await send("POST", "broker/base-clone-tokens", body: ["repository": repository])
  }

  /// One signed request. A `stale_proof` refusal carries the broker's `Date`; the request is
  /// signed again on that clock and sent once more.
  private func send<Response: Decodable>(
    _ method: String, _ path: String, body: [String: String]?
  ) async throws -> Response {
    let url = baseURL.appendingPathComponent(path)
    try BrokerEndpoint.check(url)
    var skew: TimeInterval = 0
    for attempt in 0..<2 {
      var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
      request.httpMethod = method
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      request.setValue(
        try BrokerProof.make(key: key, method: method, url: url, issuedAt: now() + skew),
        forHTTPHeaderField: "DPoP")
      if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
      }
      let (data, response): (Data, URLResponse)
      do {
        try Task.checkCancellation()
        (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
      } catch let error as URLError where error.code == .cancelled {
        // A cancelled task, not an outage: callers treat the two differently.
        throw CancellationError()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw BrokerError.transport(error.localizedDescription)
      }
      guard let http = response as? HTTPURLResponse else {
        throw BrokerError.malformed("not an HTTP response")
      }
      if (200..<300).contains(http.statusCode) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
          return try decoder.decode(Response.self, from: data)
        } catch {
          throw BrokerError.malformed("\(path): \(error.localizedDescription)")
        }
      }
      let refusal = Self.refusal(status: http.statusCode, data: data)
      if attempt == 0, refusal.status == 401, refusal.code == "stale_proof",
        let date = http.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate)
      {
        skew = date.timeIntervalSince(now())
        continue
      }
      throw BrokerError.refused(refusal)
    }
    throw BrokerError.malformed("unreachable")
  }

  /// Refuses redirects: one would carry the proof to wherever it points. The broker never
  /// redirects, so a 3xx arrives as a refusal.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
  }

  private static func refusal(status: Int, data: Data) -> BrokerRefusal {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let code = object["error"] as? String ?? "http_\(status)"
    return BrokerRefusal(
      status: status, code: code, message: object["message"] as? String ?? code,
      installURL: (object["install_url"] as? String).flatMap(URL.init(string:)))
  }

  /// An HTTP `Date` (IMF-fixdate).
  static func httpDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.date(from: text)
  }
}
