import CryptoKit
import Foundation
import Synchronization

/// Tokens Railway's token endpoint answered with.
public struct RailwayTokens: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  /// Seconds the access token lasts (an hour).
  public let expiresIn: Int

  public init(accessToken: String, refreshToken: String?, expiresIn: Int) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresIn = expiresIn
  }
}

/// Why a step of Login with Railway failed.
public enum RailwayOAuthError: Error, Equatable, LocalizedError {
  /// Railway refused the refresh token or code (`invalid_grant`): a rotated token used again, a
  /// revoked sign-in. Only this one signs the user out.
  case invalidGrant
  /// A sign-in that brought no refresh token, so Workroom couldn't keep it.
  case noRefreshToken
  /// The callback's state isn't the request's.
  case stateMismatch
  /// The user declined, or Railway's consent page answered with this error.
  case denied(String)
  /// Any other token endpoint failure: its status and OAuth error.
  case server(status: Int, error: String)

  public var errorDescription: String? {
    switch self {
    case .invalidGrant: "Railway no longer accepts this sign-in. Sign in again."
    case .noRefreshToken:
      "Railway didn't give Workroom a lasting sign-in. Sign in again, and approve on Railway's page."
    case .stateMismatch:
      "The answer from Railway didn't match this sign-in, so Workroom ignored it. Sign in again."
    case .denied(let error):
      error == "access_denied"
        ? "Sign-in was cancelled on Railway's page." : "Railway refused the sign-in (\(error))."
    case .server(let status, let error): "Railway's sign-in answered \(status) (\(error))."
    }
  }
}

/// A PKCE pair (RFC 7636): a random verifier, and its S256 challenge.
public struct RailwayPKCE: Sendable, Equatable {
  public let verifier: String

  public init(verifier: String) { self.verifier = verifier }

  /// 32 random bytes, base64url: a 43-character verifier.
  public init() {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    verifier = Self.base64URL(Data(bytes))
  }

  public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// Codaset's Native (Public) OAuth app on Railway (ADR 0073): the authorization request and the
/// token endpoint, as a public client with PKCE and no secret anywhere.
public struct RailwayOAuthClient: Sendable {
  public static let authorizationEndpoint = URL(string: "https://backboard.railway.com/oauth/auth")!
  public static let tokenEndpoint = URL(string: "https://backboard.railway.com/oauth/token")!
  /// `openid` is required; `email` and `profile` are what `me { workspaces }` needs; `ssh_keys`
  /// registers Workroom's key; `offline_access` (with `prompt=consent`) brings the refresh token.
  public static let scopes =
    "openid email profile workspace:member project:member ssh_keys offline_access"

  public let clientID: String
  let transport: any RailwayHTTPTransport

  public init(clientID: String, transport: any RailwayHTTPTransport) {
    self.clientID = clientID
    self.transport = transport
  }

  /// Railway's consent page, always shown (`prompt=consent`): without it a returning user may skip
  /// it, getting no refresh token and no say in which workspaces are shared.
  public func authorizationURL(redirectURI: URL, state: String, codeChallenge: String) -> URL {
    var components = URLComponents(
      url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: Self.scopes),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components.url!
  }

  /// Exchanges the callback's code, with the verifier and the very redirect URI the request
  /// named. A sign-in without a refresh token fails.
  public func exchange(code: String, redirectURI: URL, codeVerifier: String) async throws
    -> RailwayTokens
  {
    let tokens = try await token([
      ("grant_type", "authorization_code"), ("code", code),
      ("redirect_uri", redirectURI.absoluteString), ("code_verifier", codeVerifier),
      ("client_id", clientID),
    ])
    guard tokens.refreshToken?.isEmpty == false else { throw RailwayOAuthError.noRefreshToken }
    return tokens
  }

  /// A new access token for `refreshToken`. Railway rotates refresh tokens: keep the answer's.
  public func refresh(_ refreshToken: String) async throws -> RailwayTokens {
    try await token([
      ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID),
    ])
  }

  private struct TokenAnswer: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
      case error
    }
  }

  private func token(_ form: [(String, String)]) async throws -> RailwayTokens {
    var request = URLRequest(url: Self.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      form.map { "\($0)=\(Self.formEncode($1))" }.joined(separator: "&").utf8)
    let answer = try await transport.send(request)
    let decoded = try? JSONDecoder().decode(TokenAnswer.self, from: answer.body)
    guard (200..<300).contains(answer.status), let access = decoded?.accessToken else {
      let error = decoded?.error ?? "no access token"
      if error == "invalid_grant" { throw RailwayOAuthError.invalidGrant }
      throw RailwayOAuthError.server(status: answer.status, error: error)
    }
    return RailwayTokens(
      accessToken: access, refreshToken: decoded?.refreshToken,
      expiresIn: decoded?.expiresIn ?? 3600)
  }

  private static let formAllowed: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()

  static func formEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
  }
}

// MARK: Keeping the sign-in

/// Where the refresh token is kept: the Keychain in the app, in an access group Release and
/// Nightly share (ADR 0073). Never `~/.railway`.
public protocol RailwayTokenStore: Sendable {
  func read() throws -> String?
  func write(_ token: String) throws
  func delete() throws
}

/// Makes refreshes one at a time across every app that shares the token store (Release and
/// Nightly), since a rotated refresh token sent twice revokes the whole sign-in.
public protocol RailwayRefreshLock: Sendable {
  func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
}

/// No lock beyond the session's own one-at-a-time: for a store no other process shares.
public struct InProcessRefreshLock: RailwayRefreshLock {
  public init() {}
  public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    try await body()
  }
}

/// An exclusive `flock` on a file every sharing app names, held while one refreshes.
public struct FileRefreshLock: RailwayRefreshLock {
  public let path: URL
  /// How long a refresh waits for the other app to let go before it fails (`timedOut`), which
  /// keeps the sign-in: only Railway refusing the refresh token signs out.
  public let timeout: Duration

  public init(path: URL, timeout: Duration = CrossProcessLock.timeout) {
    self.path = path
    self.timeout = timeout
  }

  public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    try await CrossProcessLock(path: path, timeout: timeout).withLock(body)
  }
}

/// Why a cross-process lock wasn't taken.
public enum RailwayRefreshLockError: Error, Equatable, LocalizedError {
  /// Another app held the lock file named here for longer than the wait's bound.
  case timedOut(String)

  public var errorDescription: String? {
    switch self {
    case .timedOut(let name):
      "Another Workroom app held its lock (\(name)) for too long. Try again."
    }
  }
}

/// An exclusive `flock` on `path`, shared by every app that names it (Release and Nightly), held
/// for the length of a body. The wait polls rather than blocking a thread, so it ends when its
/// task is cancelled, and it gives up after `timeout` (`RailwayRefreshLockError.timedOut`). `path`
/// is a lock file of its own, never a file written atomically, which replaces the inode and the
/// lock with it. Two holders in one process exclude each other too: each opens its own file.
public struct CrossProcessLock: Sendable {
  /// How long a wait lasts by default: far longer than any holder's work.
  public static let timeout: Duration = .seconds(30)
  static let poll: Duration = .milliseconds(20)

  public let path: URL
  public let timeout: Duration

  public init(path: URL, timeout: Duration = CrossProcessLock.timeout) {
    self.path = path
    self.timeout = timeout
  }

  public func withLock<T>(_ body: () async throws -> T) async throws -> T {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let deadline = ContinuousClock.now + timeout
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let failure = errno
      guard failure == EWOULDBLOCK || failure == EINTR else {
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
      }
      guard ContinuousClock.now < deadline else {
        throw RailwayRefreshLockError.timedOut(path.lastPathComponent)
      }
      try await Task.sleep(for: Self.poll)
    }
    defer { flock(fd, LOCK_UN) }
    return try await body()
  }
}

/// Why the session has no access token.
public enum RailwaySessionError: Error, Equatable, LocalizedError {
  /// Not signed in, or the sign-in ended (refused or signed out): sign in again.
  case signedOut

  public var errorDescription: String? { "Workroom isn't signed in to Railway." }
}

/// The Railway sign-in this app holds (ADR 0073): the refresh token in the store, and the hour's
/// access token in memory. It is the one owner that refreshes: callers asking together share one
/// refresh, and under the shared lock it reads the store again first, so a refresh token another
/// app rotated meanwhile is the one sent. It always stores the newest refresh token before handing
/// out the access token. Only Railway refusing the refresh token (`invalid_grant`) signs out; the
/// network or Railway's servers failing keeps the sign-in.
public actor RailwaySession: RailwayAccessTokenProviding {
  /// Refreshes this long before the access token's hour ends.
  static let expiryMargin: TimeInterval = 120

  private let client: RailwayOAuthClient
  private let store: any RailwayTokenStore
  private let lock: any RailwayRefreshLock
  private let now: @Sendable () -> Date
  private var access: (token: String, expires: Date)?
  private var refreshing: Task<String, Error>?
  /// Bumped by each sign-in and sign-out, so a refresh that started before one stores nothing.
  private var generation = 0

  public init(
    client: RailwayOAuthClient, store: any RailwayTokenStore, lock: any RailwayRefreshLock,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.store = store
    self.lock = lock
    self.now = now
  }

  /// Whether a refresh token is kept.
  public var isSignedIn: Bool { ((try? store.read()) ?? nil) != nil }

  /// Keeps a new sign-in's tokens.
  public func signIn(with tokens: RailwayTokens) throws {
    guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
      throw RailwayOAuthError.noRefreshToken
    }
    generation += 1
    refreshing = nil
    try store.write(refresh)
    access = (tokens.accessToken, expiry(of: tokens))
  }

  /// Forgets the sign-in. Railway has no revocation endpoint Workroom can call, so the
  /// authorization stays listed on the user's Railway account until they remove it there.
  public func signOut() throws {
    generation += 1
    refreshing = nil
    access = nil
    try store.delete()
  }

  public func accessToken() async throws -> String {
    if let access, access.expires > now() { return access.token }
    if let refreshing { return try await refreshing.value }
    // Set before the first suspension: the actor is re-entrant.
    let task = Task { try await self.refresh() }
    refreshing = task
    defer { refreshing = nil }
    return try await task.value
  }

  public func accessTokenRejected(_ token: String) {
    if access?.token == token { access = nil }
  }

  private func refresh() async throws -> String {
    let generation = self.generation
    let tokens: RailwayTokens = try await lock.withLock {
      guard let current = try await self.storedToken(generation) else {
        throw RailwaySessionError.signedOut
      }
      do {
        return try await self.refresh(current, generation: generation)
      } catch RailwayOAuthError.invalidGrant {
        // Another app may have rotated it between the read and the refusal.
        if let again = try await self.storedToken(generation), again != current {
          do {
            return try await self.refresh(again, generation: generation)
          } catch RailwayOAuthError.invalidGrant {
            try await self.forget(again, generation: generation)
            throw RailwaySessionError.signedOut
          }
        }
        try await self.forget(current, generation: generation)
        throw RailwaySessionError.signedOut
      }
    }
    guard generation == self.generation else { throw RailwaySessionError.signedOut }
    access = (tokens.accessToken, expiry(of: tokens))
    return tokens.accessToken
  }

  /// The stored refresh token, unless the user signed out since `generation`.
  private func storedToken(_ generation: Int) throws -> String? {
    guard generation == self.generation else { throw RailwaySessionError.signedOut }
    return try store.read()
  }

  /// Refreshes with `token` and stores the newest refresh token before anything uses the answer,
  /// unless the user signed out meanwhile.
  private func refresh(_ token: String, generation: Int) async throws -> RailwayTokens {
    let tokens = try await client.refresh(token)
    guard generation == self.generation else { throw RailwaySessionError.signedOut }
    if let newest = tokens.refreshToken, !newest.isEmpty, newest != token {
      try store.write(newest)
    }
    return tokens
  }

  /// Empties the store of a refused `token`, unless another app has already replaced it.
  private func forget(_ token: String, generation: Int) throws {
    guard generation == self.generation else { return }
    if try store.read() == token { try store.delete() }
  }

  private func expiry(of tokens: RailwayTokens) -> Date {
    now().addingTimeInterval(TimeInterval(tokens.expiresIn) - Self.expiryMargin)
  }
}
