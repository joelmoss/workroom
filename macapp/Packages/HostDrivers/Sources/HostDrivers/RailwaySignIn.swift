import Foundation
import Network
import Synchronization

/// The loopback redirect of Login with Railway (ADR 0073): an HTTP listener on `127.0.0.1` only,
/// on a port the system picks for each sign-in, so no other program holding a fixed port can break
/// sign-in. Its URI is `http://127.0.0.1:<port>/callback`, against the registered portless
/// `http://127.0.0.1/callback`. It answers the browser's first request to `/callback` and ignores
/// every other path (a favicon fetch).
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
        guard once.withLock({ done in
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

  /// Stops listening.
  public func cancel() {
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
      return respond(connection, status: "404 Not Found", body: "Not found.")
    }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    let callback = Callback(code: value("code"), state: value("state"), error: value("error"))
    respond(
      connection, status: "200 OK",
      body: callback.error == nil
        ? "Workroom is signed in to Railway. You can close this tab and go back to Workroom."
        : "Workroom wasn't signed in to Railway. You can close this tab and go back to Workroom.")
    finish(.success(callback))
  }

  private func respond(_ connection: NWConnection, status: String, body: String) {
    let html =
      "<!doctype html><meta charset=utf-8><title>Workroom</title>"
      + "<body style=\"font:15px -apple-system,sans-serif;margin:3em\"><p>\(body)</p>"
    let response =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
      + html
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

  /// Signs in. Cancelling the task (the sheet closed) stops the listener.
  public func run(open: @Sendable (URL) async -> Void) async throws -> RailwayTokens {
    let redirect = try await RailwayLoopbackRedirect.start()
    defer { redirect.cancel() }
    let pkce = RailwayPKCE()
    let state = RailwayPKCE().verifier
    await open(
      client.authorizationURL(
        redirectURI: redirect.uri, state: state, codeChallenge: pkce.challenge))
    let callback = try await redirect.callback()
    try Task.checkCancellation()
    guard callback.state == state else { throw RailwayOAuthError.stateMismatch }
    if let error = callback.error { throw RailwayOAuthError.denied(error) }
    guard let code = callback.code, !code.isEmpty else {
      throw RailwayOAuthError.denied("no code")
    }
    return try await client.exchange(
      code: code, redirectURI: redirect.uri, codeVerifier: pkce.verifier)
  }
}
