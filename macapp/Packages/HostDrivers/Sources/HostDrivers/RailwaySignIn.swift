import Foundation
import Network
import Synchronization

/// The loopback redirect of Login with Railway (ADR 0073): an HTTP listener on `127.0.0.1` only,
/// on a port the system picks for each sign-in, so no other program holding a fixed port can break
/// sign-in. Its URI is `http://127.0.0.1:<port>/callback`, against the registered portless
/// `http://127.0.0.1/callback`. Its first request to `/callback` ends the wait, every other path is
/// ignored (a favicon fetch), and the browser's page waits for `reply`, so it tells the sign-in's
/// real outcome rather than the redirect's.
public final class RailwayLoopbackRedirect: Sendable {
  /// What the callback carried.
  public struct Callback: Sendable, Equatable {
    public let code: String?
    public let state: String?
    public let error: String?
  }

  public let uri: URL
  private let listener: NWListener
  private let queue: DispatchQueue
  private struct Wait {
    var outcome: Result<Callback, Error>?
    var waiter: CheckedContinuation<Callback, Error>?
    /// Callback requests the browser is waiting on, until `reply`.
    var held: [NWConnection] = []
    /// The page `reply` chose; later callback requests (a reload) get it too.
    var page: RailwaySignInPage.Outcome?
  }
  private let state = Mutex(Wait())

  private init(uri: URL, listener: NWListener, queue: DispatchQueue) {
    self.uri = uri
    self.listener = listener
    self.queue = queue
  }

  /// Starts listening on a port the system picks.
  public static func start() async throws -> RailwayLoopbackRedirect {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    parameters.allowLocalEndpointReuse = false
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "com.developwithstyle.workroom.railway-redirect")
    let port: UInt16 = try await withCheckedThrowingContinuation { ready in
      let once = Mutex(false)
      @Sendable func finish(_ result: Result<UInt16, Error>) {
        guard
          once.withLock({ done in
            defer { done = true }
            return !done
          })
        else { return }
        ready.resume(with: result)
      }
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let port = listener.port?.rawValue { finish(.success(port)) }
        case .failed(let error): finish(.failure(error))
        case .cancelled: finish(.failure(CancellationError()))
        default: break
        }
      }
      // Connections wait for the handler below.
      listener.newConnectionHandler = { $0.cancel() }
      listener.start(queue: queue)
    }
    let redirect = RailwayLoopbackRedirect(
      uri: URL(string: "http://127.0.0.1:\(port)/callback")!, listener: listener, queue: queue)
    listener.newConnectionHandler = { [weak redirect] connection in
      guard let redirect else { return connection.cancel() }
      redirect.serve(connection)
    }
    listener.stateUpdateHandler = { [weak redirect] state in
      if case .failed(let error) = state { redirect?.finish(.failure(error)) }
    }
    return redirect
  }

  /// Waits for the browser's request to `/callback`. Cancelling the task ends the wait.
  public func callback() async throws -> Callback {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter in
        let outcome: Result<Callback, Error>? = state.withLock { state in
          if let outcome = state.outcome { return outcome }
          state.waiter = waiter
          return nil
        }
        if let outcome { waiter.resume(with: outcome) }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  /// Answers the browser's callback requests, held and later, with the sign-in's outcome. The first
  /// reply stands.
  public func reply(_ outcome: RailwaySignInPage.Outcome) {
    let held = state.withLock { state -> [NWConnection] in
      guard state.page == nil else { return [] }
      state.page = outcome
      defer { state.held = [] }
      return state.held
    }
    for connection in held { respond(connection, body: RailwaySignInPage.html(outcome)) }
  }

  /// Stops listening; a browser still waiting is told the sign-in didn't finish, unless `reply`
  /// already told it otherwise.
  public func cancel() {
    reply(.failed)
    listener.cancel()
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: Result<Callback, Error>) {
    // The first outcome stands: a cancel after the callback doesn't undo it.
    let waiter = state.withLock { state -> CheckedContinuation<Callback, Error>? in
      guard state.outcome == nil else { return nil }
      state.outcome = result
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(with: result)
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, buffer: Data())
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, isComplete, error in
      guard let self else { return connection.cancel() }
      var buffer = buffer
      if let data { buffer.append(data) }
      if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil
        || buffer.count > 65_536
      {
        self.answer(connection, request: buffer)
      } else {
        self.read(connection, buffer: buffer)
      }
    }
  }

  private func answer(_ connection: NWConnection, request: Data) {
    let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
    let parts = line.split(separator: " ")
    let target = parts.count >= 2 ? String(parts[1]) : ""
    let components = URLComponents(string: "http://127.0.0.1\(target)")
    guard parts.first == "GET", let components, components.path == "/callback" else {
      return respond(
        connection, status: "404 Not Found", type: "text/plain", body: "Not found.")
    }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    let callback = Callback(code: value("code"), state: value("state"), error: value("error"))
    let page = state.withLock { state -> RailwaySignInPage.Outcome? in
      if state.page == nil { state.held.append(connection) }
      return state.page
    }
    if let page { respond(connection, body: RailwaySignInPage.html(page)) }
    finish(.success(callback))
  }

  private func respond(
    _ connection: NWConnection, status: String = "200 OK", type: String = "text/html",
    body: String
  ) {
    let response =
      "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\n"
      + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
      + body
    connection.send(
      content: Data(response.utf8),
      completion: .contentProcessed { _ in connection.cancel() })
  }
}

/// One Login with Railway, from the browser opening to the tokens (ADR 0073): a fresh PKCE pair,
/// state and loopback redirect each time, Railway's consent page opened with `open`, the callback's
/// state checked, and its code exchanged with the very redirect URI.
public struct RailwaySignIn: Sendable {
  let client: RailwayOAuthClient

  public init(client: RailwayOAuthClient) { self.client = client }

  /// Signs in, and `keep` keeps the tokens before the browser's page says Workroom is connected, so
  /// a failed exchange or keep shows there too. Cancelling the task (the sheet closed) stops the
  /// listener.
  public func run(
    open: @Sendable (URL) async -> Void,
    keep: @Sendable (RailwayTokens) async throws -> Void = { _ in }
  ) async throws -> RailwayTokens {
    let redirect = try await RailwayLoopbackRedirect.start()
    var page = RailwaySignInPage.Outcome.failed
    defer {
      redirect.reply(page)
      redirect.cancel()
    }
    let pkce = RailwayPKCE()
    let state = RailwayPKCE().verifier
    await open(
      client.authorizationURL(
        redirectURI: redirect.uri, state: state, codeChallenge: pkce.challenge))
    let callback = try await redirect.callback()
    try Task.checkCancellation()
    guard callback.state == state else { throw RailwayOAuthError.stateMismatch }
    if let error = callback.error {
      page = .declined
      throw RailwayOAuthError.denied(error)
    }
    guard let code = callback.code, !code.isEmpty else {
      throw RailwayOAuthError.denied("no code")
    }
    let tokens = try await client.exchange(
      code: code, redirectURI: redirect.uri, codeVerifier: pkce.verifier)
    try await keep(tokens)
    page = .connected
    return tokens
  }
}
