import CryptoKit
import Darwin
import Foundation

/// Signs this Mac in to the Workroom broker (#251; eng D6, R35, R37): a loopback redirect with
/// PKCE, not the device flow.
///
/// 1. Listen on an ephemeral `127.0.0.1` port and open `codaset.dev/workroom/sign-in` in the
///    browser with a PKCE challenge. The person signs in with GitHub there.
/// 2. Codaset sends the browser to `http://127.0.0.1:<port>/callback?code&attempt`.
/// 3. Generate this Mac's key and redeem the code with the verifier, signed by that new key, which
///    registers it. Store the key and the account.
/// 4. Send the signed "complete" for the attempt, and only then answer the browser, sending it to
///    `codaset.dev/workroom/sign-in/<attempt>`, which says "signed in" once "complete" arrived. A
///    failure sends it there too, where the matching error is shown.
struct BrokerSignIn: Sendable {
  let baseURL: URL
  let credentials: BrokerCredentials
  let openBrowser: @Sendable (URL) -> Void
  var session: URLSession = .shared
  var makeKey: @Sendable () throws -> BrokerDeviceKey = { try BrokerDeviceKey.generate() }
  /// How long to wait for the browser to come back before giving up.
  var timeout: TimeInterval = 600

  func run(deviceName: String) async throws -> BrokerAccount {
    try BrokerEndpoint.check(baseURL)
    var random = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
      throw BrokerError.keyStorage("no randomness for PKCE")
    }
    let verifier = Data(random).base64URL
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

    let listener = try LoopbackListener()
    defer { listener.close() }
    var start = URLComponents(
      url: baseURL.appendingPathComponent("workroom/sign-in"), resolvingAgainstBaseURL: false)
    start?.queryItems = [
      URLQueryItem(name: "flow", value: "mac"),
      URLQueryItem(name: "port", value: String(listener.port)),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "device_name", value: deviceName),
    ]
    guard let startURL = start?.url else { throw BrokerError.malformed("bad sign-in URL") }
    openBrowser(startURL)

    let callback = try await listener.callback(timeout: timeout)
    let outcome = baseURL.appendingPathComponent("workroom/sign-in/\(callback.attempt)")
    defer { callback.redirect(to: outcome) }

    let key = try makeKey()
    let client = BrokerClient(baseURL: baseURL, key: key, session: session)
    let device = try await client.redeem(code: callback.code, verifier: verifier, name: deviceName)
    let account = BrokerAccount(deviceID: device.deviceId, login: device.login, email: device.email)
    try credentials.save(account: account, key: key)
    do {
      try await client.complete(attempt: callback.attempt)
    } catch BrokerError.refused(let refusal) {
      // The broker did not complete the attempt, so the browser will say Workroom didn't finish
      // signing in; so does this Mac.
      credentials.clear()
      throw BrokerError.refused(refusal)
    } catch is CancellationError {
      // The person pressed Cancel: they are not signed in, whatever the broker recorded.
      credentials.clear()
      throw CancellationError()
    } catch {
      // No answer: the broker may have completed it and the page may say "signed in". The key is
      // registered and works either way, so keeping it is the true state; at worst the page asks
      // to start again and a second sign-in replaces this one.
    }
    return account
  }
}

/// The browser's return to the loopback listener, held open until the sign-in has an outcome.
struct LoopbackCallback: Sendable {
  let code: String
  let attempt: String
  fileprivate let connection: Int32

  /// Answers the browser with a redirect and closes the connection.
  func redirect(to url: URL) {
    let response =
      "HTTP/1.1 302 Found\r\nLocation: \(url.absoluteString)\r\nContent-Length: 0\r\n"
      + "Connection: close\r\n\r\n"
    _ = response.withCString { Darwin.send(connection, $0, strlen($0), 0) }
    Darwin.close(connection)
  }
}

/// A one-shot HTTP listener on `127.0.0.1` for the sign-in redirect. Only loopback: nothing off
/// this Mac can reach it, and the code it receives is worthless without the PKCE verifier.
final class LoopbackListener: @unchecked Sendable {
  let port: UInt16
  private let socket: Int32
  private let lock = NSLock()
  private var closed = false
  private var cancelled = false

  init() throws {
    guard let (socket, port) = LoopbackSocket.listen() else {
      throw BrokerError.signIn("Couldn't listen on a local port (\(errno)).")
    }
    self.socket = socket
    self.port = port
  }

  deinit { close() }

  func close() {
    let wasOpen = lock.withLock {
      defer { closed = true }
      return !closed
    }
    if wasOpen { Darwin.close(socket) }
  }

  /// Waits for `GET /callback?code=…&attempt=…`, answering anything else (a favicon request) with
  /// a 404. Cancelling the task ends the wait within a second. It shuts the socket down rather than
  /// closing it: a descriptor closed under a poll could be reused by another open, and accepted on.
  ///
  /// Every connection is read at once, each against its own deadline. One at a time, a burst of
  /// idle connections queued ahead of the browser's would hold it back 5 s each, and the accept
  /// queue holds 128: longer than the whole sign-in. One thread polls them all, so a burst takes no
  /// threads either, and past `maxPending` the oldest is dropped.
  func callback(timeout: TimeInterval) async throws -> LoopbackCallback {
    let socket = self.socket
    let deadline = Date().addingTimeInterval(timeout)
    return try await withTaskCancellationHandler {
      try await runBlocking {
        var pending: [Request] = []
        defer { for request in pending { Darwin.close(request.connection) } }
        while true {
          if self.lock.withLock({ self.cancelled }) { throw CancellationError() }
          let now = Date()
          guard deadline > now else {
            throw BrokerError.signIn("Signing in took too long. Start again.")
          }
          pending.removeAll { request in
            guard request.deadline <= now else { return false }
            Self.answerNotFound(request.connection)
            return true
          }
          let wait = ([deadline, now.addingTimeInterval(1)] + pending.map(\.deadline)).min()!
          var watched =
            [pollfd(fd: socket, events: Int16(POLLIN), revents: 0)]
            + pending.map { pollfd(fd: $0.connection, events: Int16(POLLIN), revents: 0) }
          let ready = poll(
            &watched, nfds_t(watched.count), Int32(max(0, wait.timeIntervalSince(now)) * 1000))
          if ready < 0, errno == EINTR { continue }
          guard ready >= 0, watched[0].revents & Int16(POLLNVAL) == 0 else {
            throw CancellationError()
          }
          // Backwards, so a removal leaves the indices still to visit in place.
          for index in pending.indices.reversed() where watched[index + 1].revents != 0 {
            guard let outcome = pending[index].receive() else { continue }
            pending.remove(at: index)
            guard let callback = outcome else { continue }
            // A request that arrived as Cancel was pressed is not accepted.
            if self.lock.withLock({ self.cancelled }) {
              callback.redirect(to: URL(string: "about:blank")!)
              throw CancellationError()
            }
            return callback
          }
          if watched[0].revents & Int16(POLLIN) != 0 {
            let connection = accept(socket, nil, nil)
            guard connection >= 0 else { continue }
            if pending.count >= Self.maxPending {
              Darwin.close(pending.removeFirst().connection)
            }
            pending.append(Request(connection))
          }
        }
      }
    } onCancel: {
      self.lock.withLock { self.cancelled = true }
      shutdown(socket, SHUT_RDWR)
    }
  }

  /// Connections being read at once. A browser's real request completes as it lands, so dropping
  /// the oldest past this keeps idle ones from crowding it out without spending a descriptor each.
  static let maxPending = 32

  /// One connection's request head, read as it arrives.
  private struct Request {
    let connection: Int32
    /// 5 s for the whole head, not per read: a client trickling a byte at a time gets no longer.
    let deadline = Date().addingTimeInterval(5)
    private var head = Data()

    init(_ connection: Int32) {
      self.connection = connection
      _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) | O_NONBLOCK)
      var noSignal: Int32 = 1
      setsockopt(
        connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    /// What has arrived. nil while the head is still coming; then `.some` of a `/callback` with
    /// both parameters, its connection open and blocking again, or `.some(nil)` for anything else,
    /// answered 404 and closed.
    mutating func receive() -> LoopbackCallback?? {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = recv(connection, &buffer, buffer.count, 0)
      if count < 0, errno == EAGAIN || errno == EINTR { return nil }
      if count > 0 { head.append(buffer, count: count) }
      // Only a complete request head: one the client stopped short of is not a request.
      let complete = head.range(of: Data("\r\n\r\n".utf8)) != nil
      if count > 0, !complete, head.count < 16 * 1024 { return nil }
      if complete, let callback = Self.callback(in: head, connection: connection) {
        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        return .some(callback)
      }
      LoopbackListener.answerNotFound(connection)
      return .some(nil)
    }

    private static func callback(in head: Data, connection: Int32) -> LoopbackCallback? {
      let line = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
      let parts = line.split(separator: " ")
      guard parts.count >= 2, parts[0] == "GET",
        let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == "/callback"
      else { return nil }
      let items = url.queryItems ?? []
      let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
      let attempt = value("attempt")
      let safe = attempt.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
      guard !value("code").isEmpty, !attempt.isEmpty, safe else { return nil }
      return LoopbackCallback(code: value("code"), attempt: attempt, connection: connection)
    }
  }

  private static func answerNotFound(_ connection: Int32) {
    let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    _ = notFound.withCString { Darwin.send(connection, $0, strlen($0), 0) }
    Darwin.close(connection)
  }
}
