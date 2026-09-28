import CryptoKit
import Defaults
import XCTest

@testable import Workroom

/// Canned broker answers, served in order, and the requests that asked for them. `startLoading()`
/// runs on a queue URLSession owns, hence the lock.
final class BrokerStub: URLProtocol, @unchecked Sendable {
  struct Answer {
    var status = 200
    var headers: [String: String] = [:]
    var body = "{}"
  }

  struct Seen {
    let request: URLRequest
    let body: Data

    var proof: String { request.value(forHTTPHeaderField: "DPoP") ?? "" }
    var json: [String: Any] {
      (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var answers: [Answer] = []
  nonisolated(unsafe) private static var seen: [Seen] = []
  nonisolated(unsafe) private static var failing = false
  nonisolated(unsafe) private static var hanging = false
  /// Once the scripted answers run out, requests are never answered, as a hung server's are.
  static var hangWhenEmpty: Bool {
    get { lock.withLock { hanging } }
    set { lock.withLock { hanging = newValue } }
  }
  /// The request after the next answered one fails at the transport, as a lost answer does.
  static var failNext: Bool {
    get { lock.withLock { failing } }
    set { lock.withLock { failing = newValue } }
  }

  static func reset(_ answers: [Answer]) {
    lock.withLock {
      self.answers = answers
      seen = []
      failing = false
      hanging = false
    }
  }

  static var requests: [Seen] { lock.withLock { seen } }

  static var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BrokerStub.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        body.append(buffer, count: count)
      }
      stream.close()
    }
    let (answer, hang): (Answer?, Bool) = Self.lock.withLock {
      Self.seen.append(Seen(request: request, body: body))
      if Self.answers.isEmpty, Self.hanging { return (nil, true) }
      if Self.answers.isEmpty, Self.failing { return (nil, false) }
      return (Self.answers.isEmpty ? Answer(status: 500) : Self.answers.removeFirst(), false)
    }
    if hang { return }
    guard let answer else {
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
      headerFields: answer.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Decodes one JWT segment.
func jwtPart(_ jwt: String, _ index: Int) -> [String: Any] {
  var text = jwt.split(separator: ".")[index].replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  text += String(repeating: "=", count: (4 - text.count % 4) % 4)
  let data = Data(base64Encoded: text)!
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// Whether a proof's signature verifies with the key in its own header, as `Broker::Proof` checks.
func proofVerifies(_ jwt: String) -> Bool {
  let decode = { (text: String) -> Data in
    var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    return Data(base64Encoded: text)!
  }
  let jwk = jwtPart(jwt, 0)["jwk"] as? [String: String] ?? [:]
  guard let x = jwk["x"], let y = jwk["y"],
    let key = try? P256.Signing.PublicKey(rawRepresentation: decode(x) + decode(y))
  else { return false }
  let parts = jwt.split(separator: ".").map(String.init)
  guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2])) else {
    return false
  }
  return key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
}

final class BrokerClientTests: XCTestCase {
  private let base = URL(string: "https://codaset.test")!

  private func client(now: Date = Date()) -> BrokerClient {
    BrokerClient(
      baseURL: base, key: .software(P256.Signing.PrivateKey()), session: BrokerStub.session,
      now: { now })
  }

  func testRequestsCarryAProofBoundToTheMethodAndTheURL() async throws {
    BrokerStub.reset([.init(body: #"{"grant_id":"g1","state":"cancelled"}"#)])

    try await client().cancelGrant("g1")

    let seen = try XCTUnwrap(BrokerStub.requests.first)
    XCTAssertEqual(seen.request.httpMethod, "DELETE")
    let header = jwtPart(seen.proof, 0)
    let claims = jwtPart(seen.proof, 1)
    XCTAssertEqual(header["typ"] as? String, "dpop+jwt")
    XCTAssertEqual(header["alg"] as? String, "ES256")
    XCTAssertNil((header["jwk"] as? [String: String])?["d"], "never the private half")
    XCTAssertEqual(claims["htm"] as? String, "DELETE")
    XCTAssertEqual(claims["htu"] as? String, "https://codaset.test/broker/grants/g1")
    XCTAssertGreaterThanOrEqual((claims["jti"] as? String)?.count ?? 0, 16)
    XCTAssertTrue(proofVerifies(seen.proof))
  }

  /// `Broker::Proof` compares `htu` with the URL without its query.
  func testAProofsURLLeavesOutTheQuery() throws {
    let proof = try BrokerProof.make(
      key: .software(P256.Signing.PrivateKey()), method: "GET",
      url: URL(string: "https://codaset.test/broker/install-status?repository=o/r")!,
      issuedAt: Date())

    XCTAssertEqual(
      jwtPart(proof, 1)["htu"] as? String, "https://codaset.test/broker/install-status")
  }

  func testAStaleProofIsSignedAgainOnTheBrokersClock() async throws {
    let local = Date(timeIntervalSince1970: 1_790_600_000)
    BrokerStub.reset([
      .init(
        status: 401, headers: ["Date": "Mon, 28 Sep 2026 13:00:00 GMT"],
        body: #"{"error":"stale_proof","message":"proof iat is outside the 60 s window"}"#),
      .init(
        status: 201,
        body: #"{"grant_id":"g1","enrolment_code":"c","repository_id":7,"expires_at":"x"}"#),
    ])

    let grant = try await client(now: local).createGrant(repository: "o/r", workroomID: UUID())

    XCTAssertEqual(grant.grantId, "g1")
    let requests = BrokerStub.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(jwtPart(requests[0].proof, 1)["iat"] as? Int, 1_790_600_000)
    XCTAssertEqual(jwtPart(requests[1].proof, 1)["iat"] as? Int, 1_790_600_400)
  }

  func testAStaleProofIsRetriedOnlyOnce() async {
    let stale = BrokerStub.Answer(
      status: 401, headers: ["Date": "Mon, 28 Sep 2026 13:00:00 GMT"],
      body: #"{"error":"stale_proof"}"#)
    BrokerStub.reset([stale, stale, stale])

    do {
      _ = try await client().createGrant(repository: "o/r", workroomID: UUID())
      XCTFail("a second stale proof is a refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "stale_proof")
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(BrokerStub.requests.count, 2)
  }

  func testRefusalsAreTypedAndCarryTheInstallLink() async {
    BrokerStub.reset([
      .init(
        status: 409,
        body:
          #"{"error":"app_not_installed","message":"x","install_url":"https://codaset.test/install/o"}"#
      )
    ])

    do {
      _ = try await client().createGrant(repository: "o/r", workroomID: UUID())
      XCTFail("expected a refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.status, 409)
      XCTAssertEqual(refusal.code, "app_not_installed")
      XCTAssertEqual(refusal.installURL?.absoluteString, "https://codaset.test/install/o")
      XCTAssertTrue(refusal.userMessage.contains("GitHub App"))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testANonJSONErrorBecomesAnHTTPStatusRefusal() async {
    BrokerStub.reset([.init(status: 502, body: "<html>Bad Gateway</html>")])

    do {
      _ = try await client().createGrant(repository: "o/r", workroomID: UUID())
      XCTFail("expected a refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "http_502")
      XCTAssertEqual(refusal.userMessage, "http_502")
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testTheGrantCarriesALowercaseWorkroomID() async throws {
    BrokerStub.reset([
      .init(
        status: 201,
        body: #"{"grant_id":"g","enrolment_code":"c","repository_id":1,"expires_at":"x"}"#)
    ])
    let id = UUID()

    _ = try await client().createGrant(repository: "o/r", workroomID: id)

    let body = try XCTUnwrap(BrokerStub.requests.first).json
    XCTAssertEqual(body["workroom_id"] as? String, id.uuidString.lowercased())
    XCTAssertEqual(body["repository"] as? String, "o/r")
  }
}

final class BrokerCredentialsTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "broker-credentials-\(UUID().uuidString.prefix(8))")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  /// A Keychain stand-in: the login Keychain is locked on CI.
  private func credentials() -> BrokerCredentials {
    final class Box: @unchecked Sendable { var data: Data? }
    let box = Box()
    return BrokerCredentials(
      directory: directory,
      secrets: .init(
        read: { box.data }, write: { box.data = $0 }, delete: { box.data = nil }))
  }

  func testASoftwareKeyRoundTripsAndSignsTheSame() throws {
    let store = credentials()
    let account = BrokerAccount(deviceID: "d", login: "octo", email: "o@example.com")
    let key = BrokerDeviceKey.software(P256.Signing.PrivateKey())

    XCTAssertNil(store.load())
    try store.save(account: account, key: key)
    let loaded = try XCTUnwrap(store.load())

    XCTAssertEqual(loaded.account, account)
    XCTAssertEqual(loaded.key.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("account.json").path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)

    store.clear()
    XCTAssertNil(store.load())
  }

  /// Only on a Mac with a Secure Enclave (not a CI VM): the key stays in the enclave and a blob
  /// naming it is what is stored.
  func testASecureEnclaveKeyIsStoredAsItsBlob() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave")
    let store = credentials()
    let key = try BrokerDeviceKey.generate()
    guard case .secureEnclave = key else { return XCTFail("expected an enclave key") }

    try store.save(account: BrokerAccount(deviceID: "d", login: "l", email: "e"), key: key)
    let loaded = try XCTUnwrap(store.load())

    guard case .secureEnclave = loaded.key else { return XCTFail("expected an enclave key") }
    XCTAssertEqual(loaded.key.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    let signature = try loaded.key.signature(for: Data("x".utf8))
    XCTAssertTrue(
      key.publicKey.isValidSignature(
        try P256.Signing.ECDSASignature(rawRepresentation: signature), for: Data("x".utf8)))
  }
}

/// The Mac's session: a key the broker no longer knows signs the Mac out (#251: removing a Mac at
/// codaset.dev cuts it off and asks for a fresh sign-in).
@MainActor
final class BrokerSessionTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "broker-session-\(UUID().uuidString.prefix(8))")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func signedInSession() throws -> (BrokerSession, BrokerCredentials) {
    final class Box: @unchecked Sendable { var data: Data? }
    let box = Box()
    let credentials = BrokerCredentials(
      directory: directory,
      secrets: .init(read: { box.data }, write: { box.data = $0 }, delete: { box.data = nil }))
    try credentials.save(
      account: BrokerAccount(deviceID: "d", login: "octo", email: "o@example.com"),
      key: .software(P256.Signing.PrivateKey()))
    return (BrokerSession(credentials: credentials, session: BrokerStub.session), credentials)
  }

  func testAnUnknownKeySignsTheMacOut() async throws {
    BrokerStub.reset([.init(status: 401, body: #"{"error":"unknown_key"}"#)])
    let (session, credentials) = try signedInSession()
    XCTAssertEqual(
      session.state,
      .signedIn(BrokerAccount(deviceID: "d", login: "octo", email: "o@example.com")))

    do {
      _ = try await session.perform {
        try await $0.createGrant(repository: "o/r", workroomID: UUID())
      }
      XCTFail("expected a refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "unknown_key")
    }

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(credentials.load())
    XCTAssertEqual(session.error, "This Mac was removed from Codaset. Sign in again.")
  }

  func testTheBrokerURLIsHTTPSOrLocalOnly() throws {
    let (session, _) = try signedInSession()
    let original = Defaults[.brokerURL]
    defer { Defaults[.brokerURL] = original }
    for (setting, expected) in [
      ("https://staging.codaset.test", "https://staging.codaset.test"),
      ("http://127.0.0.1:3000", "http://127.0.0.1:3000"),
      ("http://codaset.dev", "https://codaset.dev"),
      ("http://localhost:3000", "https://codaset.dev"),
      ("not a url", "https://codaset.dev"),
    ] {
      Defaults[.brokerURL] = setting
      XCTAssertEqual(session.baseURL.absoluteString, expected, setting)
    }
  }

  func testOtherRefusalsLeaveTheMacSignedIn() async throws {
    BrokerStub.reset([.init(status: 403, body: #"{"error":"no_push_access"}"#)])
    let (session, credentials) = try signedInSession()

    _ = try? await session.perform {
      try await $0.createGrant(repository: "o/r", workroomID: UUID())
    }

    XCTAssertNotNil(credentials.load())
    guard case .signedIn = session.state else { return XCTFail("signed out") }
  }
}
