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
  private var signIn: Task<Void, Never>?

  init(credentials: BrokerCredentials = .standard()) {
    self.credentials = credentials
    if let (account, _) = credentials.load() { state = .signedIn(account) }
  }

  var baseURL: URL {
    URL(string: Defaults[.brokerURL]) ?? URL(string: "https://codaset.dev")!
  }

  /// Where the person manages their Macs and repository access.
  var accountPageURL: URL { baseURL.appendingPathComponent("workroom/account") }

  func startSignIn() {
    guard signIn == nil else { return }
    error = nil
    state = .signingIn
    let flow = BrokerSignIn(
      baseURL: baseURL, credentials: credentials,
      openBrowser: { url in Task { @MainActor in NSWorkspace.shared.open(url) } })
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
    credentials.load().map { BrokerClient(baseURL: baseURL, key: $0.key) }
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
