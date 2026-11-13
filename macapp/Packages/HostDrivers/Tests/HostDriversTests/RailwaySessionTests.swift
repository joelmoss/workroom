import CryptoKit
import Foundation
import Synchronization
import XCTest

@testable import HostDrivers

/// Login with Railway (ADR 0073, #627), with Railway stubbed at HTTP: the authorization request,
/// the code exchange, and the session that keeps the refresh token and refreshes as its one owner.
final class RailwaySessionTests: XCTestCase {
  private let clientID = "rlwy_oaci_test"

  private func client(_ railway: StubRailway) -> RailwayOAuthClient {
    RailwayOAuthClient(clientID: clientID, transport: railway)
  }

  // MARK: The authorization request

  /// Value: protects=sign-in asks for exactly ADR 0073's scopes, always with consent, PKCE S256
  /// and the state, against Codaset's client; fails_when=any parameter drifts, as a missing
  /// `prompt=consent` would cost the refresh token; seam=RailwayOAuthClient.authorizationURL
  func testTheAuthorizationRequestCarriesADR0073sParameters() throws {
    let url = client(StubRailway()).authorizationURL(
      redirectURI: URL(string: "http://127.0.0.1:50123/callback")!, state: "st",
      codeChallenge: "ch")

    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "backboard.railway.com")
    XCTAssertEqual(components.path, "/oauth/auth")
    let items = Dictionary(
      (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    XCTAssertEqual(
      items,
      [
        "response_type": "code", "client_id": clientID,
        "redirect_uri": "http://127.0.0.1:50123/callback",
        "scope": "openid email profile workspace:member project:member ssh_keys offline_access",
        "prompt": "consent", "state": "st", "code_challenge": "ch",
        "code_challenge_method": "S256",
      ])
  }

  /// Value: protects=the PKCE challenge is RFC 7636's S256 of the verifier; fails_when=it is
  /// padded, not URL-safe, or another hash; seam=RailwayPKCE (RFC 7636 appendix B's vector)
  func testThePKCEChallengeIsS256OfTheVerifier() {
    let pkce = RailwayPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let made = RailwayPKCE()
    XCTAssertGreaterThanOrEqual(made.verifier.count, 43)
    XCTAssertNotEqual(made.verifier, RailwayPKCE().verifier)
  }

  // MARK: The code exchange

  /// Value: protects=the code is exchanged as a public client: the verifier, the very redirect
  /// URI, the client ID in the form and no secret; fails_when=a Basic auth or secret is sent, or the
  /// redirect differs; seam=RailwayOAuthClient.exchange
  func testTheCodeIsExchangedWithPKCEAndNoSecret() async throws {
    let railway = StubRailway()
    railway.answerToken("authorization_code") { _ in StubRailway.tokens(access: "at", refresh: "rt") }

    let tokens = try await client(railway).exchange(
      code: "the-code", redirectURI: URL(string: "http://127.0.0.1:50123/callback")!,
      codeVerifier: "verifier")

    XCTAssertEqual(tokens.accessToken, "at")
    XCTAssertEqual(tokens.refreshToken, "rt")
    XCTAssertEqual(tokens.expiresIn, 3600)
    let request = try XCTUnwrap(railway.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    XCTAssertEqual(
      StubRailway.form(request),
      [
        "grant_type": "authorization_code", "code": "the-code",
        "redirect_uri": "http://127.0.0.1:50123/callback", "code_verifier": "verifier",
        "client_id": clientID,
      ])
  }

  /// Value: protects=a sign-in that brings no refresh token fails, since Workroom couldn't keep
  /// it past the hour; seam=RailwayOAuthClient.exchange
  func testASignInWithNoRefreshTokenFails() async {
    let railway = StubRailway()
    railway.answerToken("authorization_code") { _ in StubRailway.tokens(access: "at", refresh: nil) }
    do {
      _ = try await client(railway).exchange(
        code: "c", redirectURI: URL(string: "http://127.0.0.1:1/callback")!, codeVerifier: "v")
      XCTFail("a sign-in with no refresh token passed")
    } catch {
      XCTAssertEqual(error as? RailwayOAuthError, .noRefreshToken)
    }
  }

  // MARK: The session

  private func session(
    _ railway: StubRailway, store: MemoryTokenStore, now: @escaping @Sendable () -> Date = Date.init
  ) -> RailwaySession {
    RailwaySession(client: client(railway), store: store, lock: InProcessRefreshLock(), now: now)
  }

  /// Value: protects=a sign-in keeps its refresh token in the store and hands out its access
  /// token without a refresh; seam=RailwaySession
  func testSigningInKeepsTheRefreshToken() async throws {
    let railway = StubRailway()
    let store = MemoryTokenStore()
    let session = session(railway, store: store)

    try await session.signIn(with: RailwayTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600))

    XCTAssertEqual(store.token, "rt")
    let signedIn = await session.isSignedIn
    XCTAssertTrue(signedIn)
    let token = try await session.accessToken()
    XCTAssertEqual(token, "at")
    XCTAssertTrue(railway.tokenRequests.isEmpty)
  }

  /// Value: protects=after a restart the stored refresh token gets an access token, and the
  /// newest refresh token Railway returns is the one kept; fails_when=the old one is kept, which
  /// would sign the user out on the next refresh; seam=RailwaySession
  func testARefreshStoresTheNewestRefreshToken() async throws {
    let railway = StubRailway()
    railway.answerToken("refresh_token") { request in
      XCTAssertEqual(StubRailway.form(request)["refresh_token"], "rt-1")
      XCTAssertEqual(StubRailway.form(request)["client_id"], "rlwy_oaci_test")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      return StubRailway.tokens(access: "at-2", refresh: "rt-2")
    }
    let store = MemoryTokenStore("rt-1")

    let token = try await session(railway, store: store).accessToken()

    XCTAssertEqual(token, "at-2")
    XCTAssertEqual(store.token, "rt-2")
  }

  /// Value: protects=one owner refreshes at a time: callers that ask together share one refresh,
  /// so a rotated token is never sent twice; fails_when=two refreshes go out; seam=RailwaySession
  func testCallersAskingTogetherShareOneRefresh() async throws {
    let railway = StubRailway()
    let count = Mutex(0)
    railway.answerToken("refresh_token") { request in
      let n = count.withLock {
        $0 += 1
        return $0
      }
      Thread.sleep(forTimeInterval: 0.05)
      return StubRailway.tokens(access: "at-\(n)", refresh: "rt-\(n + 1)")
    }
    let store = MemoryTokenStore("rt-1")
    let session = session(railway, store: store)

    async let a = session.accessToken()
    async let b = session.accessToken()
    async let c = session.accessToken()
    let tokens = try await [a, b, c]

    XCTAssertEqual(tokens, ["at-1", "at-1", "at-1"])
    XCTAssertEqual(railway.tokenRequests.count, 1)
    XCTAssertEqual(store.token, "rt-2")
  }

  /// Value: protects=an access token is reused until it nearly expires, then refreshed with the
  /// latest refresh token; seam=RailwaySession with a clock
  func testAnExpiringAccessTokenIsRefreshed() async throws {
    let railway = StubRailway()
    railway.answerToken("refresh_token") { request in
      XCTAssertEqual(StubRailway.form(request)["refresh_token"], "rt")
      return StubRailway.tokens(access: "at-2", refresh: "rt-2")
    }
    let clock = Mutex(Date(timeIntervalSince1970: 0))
    let store = MemoryTokenStore()
    let session = session(railway, store: store, now: { clock.withLock { $0 } })
    try await session.signIn(with: RailwayTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600))

    clock.withLock { $0 = $0.addingTimeInterval(3000) }
    let early = try await session.accessToken()
    XCTAssertEqual(early, "at")

    clock.withLock { $0 = $0.addingTimeInterval(590) }
    let late = try await session.accessToken()
    XCTAssertEqual(late, "at-2")
    XCTAssertEqual(store.token, "rt-2")
  }

  /// Value: protects=a refresh token another app (Release beside Nightly) rotated meanwhile is
  /// read back from the shared store and used, rather than the rotated one this one remembered;
  /// fails_when=the stale one is sent, which revokes the whole authorization; seam=RailwaySession
  func testARefreshUsesTheTokenAnotherAppRotatedMeanwhile() async throws {
    let railway = StubRailway()
    railway.answerToken("refresh_token") { request in
      StubRailway.form(request)["refresh_token"] == "rt-other"
        ? StubRailway.tokens(access: "at-3", refresh: "rt-3") : StubRailway.oauthError("invalid_grant")
    }
    let clock = Mutex(Date(timeIntervalSince1970: 0))
    let store = MemoryTokenStore()
    let session = session(railway, store: store, now: { clock.withLock { $0 } })
    try await session.signIn(with: RailwayTokens(accessToken: "at", refreshToken: "rt", expiresIn: 60))
    try store.write("rt-other")  // Nightly refreshed

    let token = try await session.accessToken()

    XCTAssertEqual(token, "at-3")
    XCTAssertEqual(store.token, "rt-3")
    XCTAssertEqual(railway.tokenRequests.map { $0["refresh_token"] }, ["rt-other"])
  }

  /// Value: protects=a refresh token Railway refuses (a rotated one used again, a revoked sign-in)
  /// forces a new sign-in: the store is emptied and the session says signed out; fails_when=the
  /// dead token stays and every call retries it; seam=RailwaySession
  func testARefusedRefreshTokenForcesANewSignIn() async throws {
    let railway = StubRailway()
    railway.answerToken("refresh_token") { _ in StubRailway.oauthError("invalid_grant") }
    let store = MemoryTokenStore("rt-rotated")
    let session = session(railway, store: store)

    do {
      _ = try await session.accessToken()
      XCTFail("a refused refresh token gave a token")
    } catch {
      XCTAssertEqual(error as? RailwaySessionError, .signedOut)
    }
    XCTAssertNil(store.token)
    let signedIn = await session.isSignedIn
    XCTAssertFalse(signedIn)
  }

  /// Value: protects=a refresh that fails for the network or Railway's servers keeps the sign-in;
  /// fails_when=a 503 or an offline Mac signs the user out; seam=RailwaySession
  func testARefreshThatFailsForTheNetworkKeepsTheSignIn() async throws {
    let railway = StubRailway()
    railway.answerToken("refresh_token") { _ in throw URLError(.notConnectedToInternet) }
    let store = MemoryTokenStore("rt")
    let session = session(railway, store: store)

    do {
      _ = try await session.accessToken()
      XCTFail("an offline refresh gave a token")
    } catch {
      XCTAssertNotEqual(error as? RailwaySessionError, .signedOut)
    }
    XCTAssertEqual(store.token, "rt")

    railway.answerToken("refresh_token") { _ in StubRailway.oauthError("server_error", status: 503) }
    _ = try? await session.accessToken()
    XCTAssertEqual(store.token, "rt")
  }

  /// Value: protects=signing out forgets the refresh token and the access token; seam=RailwaySession
  func testSigningOutForgetsTheSignIn() async throws {
    let store = MemoryTokenStore()
    let session = session(StubRailway(), store: store)
    try await session.signIn(with: RailwayTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600))

    try await session.signOut()

    XCTAssertNil(store.token)
    do {
      _ = try await session.accessToken()
      XCTFail("a signed-out session gave a token")
    } catch {
      XCTAssertEqual(error as? RailwaySessionError, .signedOut)
    }
  }

  /// Value: protects=the cross-process lock really excludes: a second holder waits for the
  /// first; seam=FileRefreshLock on a temporary file
  func testTheFileLockExcludesASecondHolder() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("railway-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: path) }
    let first = FileRefreshLock(path: path)
    let second = FileRefreshLock(path: path)
    let order = Mutex<[String]>([])

    async let a: Void = first.withLock {
      order.withLock { $0.append("a-in") }
      try await Task.sleep(for: .milliseconds(150))
      order.withLock { $0.append("a-out") }
    }
    try await Task.sleep(for: .milliseconds(30))
    async let b: Void = second.withLock { order.withLock { $0.append("b-in") } }
    _ = try await (a, b)

    XCTAssertEqual(order.withLock { $0 }, ["a-in", "a-out", "b-in"])
  }
}
