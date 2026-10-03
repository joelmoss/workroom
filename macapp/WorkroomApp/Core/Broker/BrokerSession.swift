import AppKit
import Defaults
import Foundation

/// This Mac's sign-in to the Workroom broker, for the Settings row and, once remote workrooms
/// provision, for creating and cancelling their grants.
@MainActor
final class BrokerSession: ObservableObject {
  enum State: Equatable {
    case signedOut
    case signingIn
    case signedIn(BrokerAccount)
  }

  @Published private(set) var state: State = .signedOut

  var isSignedIn: Bool {
    if case .signedIn = state { return true }
    return false
  }
  @Published var error: String?

  private let credentials: BrokerCredentials
  private let session: URLSession
  private var signIn: Task<Void, Never>?

  /// One per app, so a sign-in in progress survives the Settings window changing panes (a
  /// per-view session would orphan it, and a second flow's save would clear the first's key).
  static let shared = BrokerSession()

  init(credentials: BrokerCredentials = .standard(), session: URLSession = .shared) {
    self.credentials = credentials
    self.session = session
    if let (account, _) = credentials.load() { state = .signedIn(account) }
  }

  /// The Codaset this build talks to (`BrokerEndpoint.resolve`).
  var baseURL: URL {
    BrokerEndpoint.resolve(Defaults[.brokerURL], debug: SentryConfig.isDebugBuild)
  }

  /// Where the person manages their Macs and repository access.
  var accountPageURL: URL { baseURL.appendingPathComponent("workroom/account") }

  func startSignIn() {
    guard signIn == nil else { return }
    error = nil
    state = .signingIn
    let flow = BrokerSignIn(
      baseURL: baseURL, credentials: credentials,
      openBrowser: { url in Task { @MainActor in NSWorkspace.shared.open(url) } },
      session: session)
    let name = Host.current().localizedName ?? "Mac"
    signIn = Task {
      do {
        state = .signedIn(try await flow.run(deviceName: name))
      } catch is CancellationError {
        state = .signedOut
      } catch {
        state = .signedOut
        self.error = error.localizedDescription
      }
      signIn = nil
    }
  }

  func cancelSignIn() { signIn?.cancel() }

  /// Forgets this Mac's key. The broker keeps the device until it is removed at codaset.dev,
  /// where the Workroom access page lists it; without the key it can do nothing.
  func signOut() {
    credentials.clear()
    state = .signedOut
    error = nil
  }

  /// A client signed with this Mac's key, or nil when signed out.
  func client() -> BrokerClient? {
    credentials.load().map { BrokerClient(baseURL: baseURL, key: $0.key, session: session) }
  }

  /// Runs `call` with this Mac's client. A key the broker no longer knows (the Mac was removed at
  /// codaset.dev) signs this Mac out, so the next attempt asks for a fresh sign-in.
  func perform<T>(_ call: (BrokerClient) async throws -> T) async throws -> T {
    guard let client = client() else {
      throw BrokerError.refused(
        BrokerRefusal(status: 401, code: "unknown_key", message: "Not signed in", installURL: nil))
    }
    do {
      return try await call(client)
    } catch BrokerError.refused(let refusal) where refusal.code == "unknown_key" {
      signOut()
      error = refusal.userMessage
      throw BrokerError.refused(refusal)
    }
  }
}

/// Which Codaset a build may talk to. Release and Nightly builds use codaset.dev, or an https
/// override. Debug builds (the Dev app and every test host) use only a Codaset on this Mac and
/// never reach production, whatever `Defaults[.brokerURL]` says: `BrokerClient` and `BrokerSignIn`
/// check every URL here before sending a request or opening the browser.
enum BrokerEndpoint {
  static let production = URL(string: "https://codaset.dev")!
  /// Where `bin/dev` serves a Codaset checkout named `codaset` (Caddy, HTTPS).
  static let development = URL(string: "https://codaset.localhost")!

  static func fallback(debug: Bool) -> URL { debug ? development : production }

  /// `setting` when this build `allows` it and it has no userinfo, path, query or fragment: the
  /// agent accepts exactly these (`acceptable_broker`), and this URL is what enrolment hands it.
  /// Anything else falls back to the build's own Codaset, rather than sending a key's proofs in
  /// the clear, or a Dev build's to production.
  static func resolve(_ setting: String, debug: Bool) -> URL {
    guard let url = URL(string: setting), url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, ["", "/"].contains(url.path()),
      allows(url, debug: debug)
    else {
      return fallback(debug: debug)
    }
    return url
  }

  /// https, or plain http to 127.0.0.1; in a Debug build, only to this Mac (`localhost`,
  /// `*.localhost` or 127.0.0.1).
  static func allows(_ url: URL, debug: Bool = SentryConfig.isDebugBuild) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    let loopback = host == "127.0.0.1"
    guard url.scheme == "https" || (url.scheme == "http" && loopback) else { return false }
    return !debug || loopback || host == "localhost" || host.hasSuffix(".localhost")
  }

  /// Throws unless this build `allows` `url`.
  static func check(_ url: URL, debug: Bool = SentryConfig.isDebugBuild) throws {
    guard allows(url, debug: debug) else {
      throw BrokerError.transport("this build does not send requests to \(url.absoluteString)")
    }
  }
}
