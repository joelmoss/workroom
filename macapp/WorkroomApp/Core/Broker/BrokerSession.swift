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

  /// `Defaults[.brokerURL]` when it is https, or plain http to 127.0.0.1 (a development Codaset),
  /// with no userinfo, path, query or fragment: the agent accepts exactly these
  /// (`acceptable_broker`), and this URL is what enrolment hands it. Anything else falls back to
  /// the default rather than sending a key's proofs in the clear.
  var baseURL: URL {
    let fallback = URL(string: Defaults.Keys.brokerURL.defaultValue)!
    guard let url = URL(string: Defaults[.brokerURL]), let host = url.host(),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      ["", "/"].contains(url.path())
    else {
      return fallback
    }
    let local = url.scheme == "http" && host == "127.0.0.1"
    return url.scheme == "https" || local ? url : fallback
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
