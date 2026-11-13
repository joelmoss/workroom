import Foundation
import Synchronization
import XCTest

@testable import HostDrivers

/// The browser half of Login with Railway (ADR 0073, #627): the loopback redirect on a port the
/// system picks, its state check, and the whole sign-in with a stand-in browser that follows the
/// redirect as Railway's consent page would. Railway itself is stubbed at HTTP.
final class RailwaySignInTests: XCTestCase {
  /// Follows the authorization URL's redirect with `code` (and the request's own state unless
  /// `state` overrides it), as the browser does once the user approves.
  private static func browser(code: String = "the-code", state: String? = nil, error: String? = nil)
    -> @Sendable (URL) async -> Void
  {
    { url in
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
      var callback = URLComponents(string: redirect)!
      callback.queryItems =
        error.map { [URLQueryItem(name: "error", value: $0)] }
        ?? [URLQueryItem(name: "code", value: code)]
      callback.queryItems?.append(
        URLQueryItem(name: "state", value: state ?? items.first { $0.name == "state" }?.value))
      _ = try? await URLSession.shared.data(from: callback.url!)
    }
  }

  /// Value: protects=the redirect listens on 127.0.0.1 only, on a port the system picked, at
  /// `/callback`; fails_when=a fixed port or another interface is used; seam=RailwayLoopbackRedirect
  func testTheRedirectListensOnALoopbackPortTheSystemPicks() async throws {
    let first = try await RailwayLoopbackRedirect.start()
    let second = try await RailwayLoopbackRedirect.start()
    defer {
      first.cancel()
      second.cancel()
    }

    for redirect in [first, second] {
      XCTAssertEqual(redirect.uri.scheme, "http")
      XCTAssertEqual(redirect.uri.host, "127.0.0.1")
      XCTAssertEqual(redirect.uri.path, "/callback")
      XCTAssertNotNil(redirect.uri.port)
    }
    XCTAssertNotEqual(first.uri.port, second.uri.port)
  }

  /// Value: protects=the whole sign-in: the browser is opened on Railway's consent page, the
  /// callback's code is exchanged with the same redirect URI and the PKCE verifier whose challenge
  /// was sent; fails_when=any of them differ; seam=RailwaySignIn with a stand-in browser
  func testSigningInExchangesTheCallbacksCode() async throws {
    let railway = StubRailway()
    railway.answerToken("authorization_code") { _ in StubRailway.tokens(access: "at", refresh: "rt") }
    let opened = Mutex<URL?>(nil)
    let follow = Self.browser()

    let tokens = try await RailwaySignIn(
      client: RailwayOAuthClient(clientID: "cid", transport: railway)
    ).run(open: { url in
      opened.withLock { $0 = url }
      await follow(url)
    })

    XCTAssertEqual(tokens, RailwayTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600))
    let url = try XCTUnwrap(opened.withLock { $0 })
    let items = Dictionary(
      (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
        ($0.name, $0.value ?? "")
      }, uniquingKeysWith: { $1 })
    let form = try XCTUnwrap(railway.tokenRequests.first)
    XCTAssertEqual(form["code"], "the-code")
    XCTAssertEqual(form["redirect_uri"], items["redirect_uri"])
    XCTAssertEqual(
      RailwayPKCE(verifier: form["code_verifier"] ?? "").challenge, items["code_challenge"])
  }

  /// Value: protects=a callback whose state isn't the request's is refused and its code never
  /// exchanged (a forged redirect); seam=RailwaySignIn
  func testACallbackWithAnotherStateIsRefused() async {
    let railway = StubRailway()
    railway.answerToken("authorization_code") { _ in StubRailway.tokens(access: "at", refresh: "rt") }
    do {
      _ = try await RailwaySignIn(client: RailwayOAuthClient(clientID: "c", transport: railway))
        .run(open: Self.browser(state: "forged"))
      XCTFail("a forged state signed in")
    } catch {
      XCTAssertEqual(error as? RailwayOAuthError, .stateMismatch)
    }
    XCTAssertTrue(railway.tokenRequests.isEmpty)
  }

  /// Value: protects=the user declining on Railway's page ends the sign-in with Railway's error;
  /// seam=RailwaySignIn
  func testDecliningOnRailwaysPageEndsTheSignIn() async {
    let railway = StubRailway()
    do {
      _ = try await RailwaySignIn(client: RailwayOAuthClient(clientID: "c", transport: railway))
        .run(open: Self.browser(error: "access_denied"))
      XCTFail("a declined consent signed in")
    } catch {
      XCTAssertEqual(error as? RailwayOAuthError, .denied("access_denied"))
    }
  }

  /// Value: protects=a request to another path doesn't end the sign-in (a browser's favicon
  /// fetch); seam=RailwayLoopbackRedirect
  func testOtherPathsDontEndTheSignIn() async throws {
    let redirect = try await RailwayLoopbackRedirect.start()
    defer { redirect.cancel() }
    var other = URLComponents(url: redirect.uri, resolvingAgainstBaseURL: false)!
    other.path = "/favicon.ico"
    _ = try? await URLSession.shared.data(from: other.url!)
    var callback = URLComponents(url: redirect.uri, resolvingAgainstBaseURL: false)!
    callback.queryItems = [.init(name: "code", value: "c"), .init(name: "state", value: "s")]
    async let follow: Void = { _ = try? await URLSession.shared.data(from: callback.url!) }()

    let answer = try await redirect.callback()
    _ = await follow

    XCTAssertEqual(answer, RailwayLoopbackRedirect.Callback(code: "c", state: "s", error: nil))
  }

  /// Value: protects=cancelling the sign-in (the sheet closed) ends the wait; seam=RailwaySignIn
  func testCancellingEndsTheWait() async {
    let signIn = RailwaySignIn(
      client: RailwayOAuthClient(clientID: "c", transport: StubRailway()))
    let task = Task { try await signIn.run(open: { _ in }) }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("a cancelled sign-in finished")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
  }
}
