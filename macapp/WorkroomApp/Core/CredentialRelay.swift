import Foundation
import os

/// The Mac's end of the git credential relay for a local container workroom that never enrolled
/// with the Codaset broker (#309): the user is signed in to `gh`, not to Codaset, or the repository's
/// owner hasn't installed the Codaset App.
///
/// Its agent's `wr-agent credential` dials a port on its own box's loopback (`port(for:)`), which
/// `ReverseForwardRegistry` carries over the app's connection to a listener here, on this Mac's
/// loopback. A connection sends the workroom's secret, then git's request; it is answered from
/// `gh auth git-credential get`, for `https://github.com` only. The secret is what keeps another
/// user of this Mac, who can also reach the listener, from being answered; it is made per launch
/// and installed on every connect (`install`).
///
/// **Accepted exposure (D9, #309).** Anything in the workroom can read the secret and ask, so such
/// a workroom has the GitHub access the user's own `gh` has, while the app is connected to it, as a
/// workroom on the Mac itself does. A remote workroom never uses this: it always enrols.
final class CredentialRelay: @unchecked Sendable {
  static let shared = CredentialRelay()

  private let lock = NSLock()
  private var listener: (descriptor: Int32, port: UInt16)?
  /// Each relayed host's secret.
  private var secrets: [UUID: String] = [:]
  private let answer: @Sendable (_ request: String) throws -> String
  /// How the registry reaches a host's connection: the app's own, or a test's.
  private let transport: ReverseForwardRegistry.Transport
  /// The listeners on relayed hosts, made on the main actor the first time one is installed.
  private var forwards: ReverseForwardRegistry?
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "CredentialRelay")
  /// The most a request may be: git's credential protocol is a handful of short lines.
  static let maxRequest = 16 * 1024

  init(
    answer: @escaping @Sendable (_ request: String) throws -> String = CredentialRelay.gh,
    transport: ReverseForwardRegistry.Transport = .live
  ) {
    self.answer = answer
    self.transport = transport
  }

  /// The agent's port for workroom host `id`: the same on every connection and every launch, so
  /// the `relay.json` it was given stays right. 30000-31999, below Linux's ephemeral ports (32768
  /// up) and apart from the Debug broker route's (`BrokerReverseForwards`).
  static func port(for id: UUID) -> UInt16 {
    let bytes = id.uuid
    return 30_000 + (UInt16(bytes.2) << 8 | UInt16(bytes.3)) % 2_000
  }

  /// The secret host `id`'s agent sends, made the first time it is asked for this launch. Throws
  /// rather than make one the system's random source didn't fill: a guessable secret would answer
  /// anyone on this Mac.
  func secret(for id: UUID) throws -> String {
    try lock.withLock {
      if let secret = secrets[id] { return secret }
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw HostDriverError.provisioning("couldn't make a secret for git's credentials")
      }
      let secret = bytes.map { String(format: "%02x", $0) }.joined()
      secrets[id] = secret
      return secret
    }
  }

  /// Requests served at once; one more is turned away. A request takes a thread for up to
  /// `requestDeadline`, so this bounds what a flood of connections can hold.
  static let maxConcurrent = 8
  /// The most one request may take to arrive, whatever pace its bytes come at.
  static let requestDeadline: TimeInterval = 15
  private let serving = DispatchSemaphore(value: maxConcurrent)
  private let queue = DispatchQueue(
    label: "com.developwithstyle.workroom.credential-relay", qos: .userInitiated,
    attributes: .concurrent)

  /// The listener on this Mac's loopback, started the first time it is needed.
  func localPort() throws -> UInt16 {
    try lock.withLock {
      if let listener { return listener.port }
      guard let made = LoopbackSocket.listen(backlog: 8) else {
        throw HostDriverError.provisioning("couldn't listen for git credentials (errno \(errno))")
      }
      listener = made
      Thread.detachNewThread { [weak self] in self?.accept(on: made.descriptor) }
      return made.port
    }
  }

  private func accept(on descriptor: Int32) {
    while true {
      let connection = Darwin.accept(descriptor, nil, nil)
      if connection < 0 {
        switch errno {
        case EINTR, ECONNABORTED: continue
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
          // Out of descriptors or memory for now: wait it out rather than stop relaying.
          Thread.sleep(forTimeInterval: 0.1)
          continue
        default:
          // Forgotten, so the next install listens again.
          Self.logger.error("credential relay stopped accepting: errno \(errno)")
          lock.withLock { if listener?.descriptor == descriptor { listener = nil } }
          Darwin.close(descriptor)
          return
        }
      }
      guard serving.wait(timeout: .now()) == .success else {
        Darwin.close(connection)
        continue
      }
      queue.async { [weak self] in
        defer {
          Darwin.close(connection)
          self?.serving.signal()
        }
        self?.serve(connection)
      }
    }
  }

  /// One request: a known secret, then `protocol=https` and `host=github.com`, or nothing back.
  private func serve(_ connection: Int32) {
    // A peer that resets before the reply would otherwise raise SIGPIPE, which ends the app.
    var on: Int32 = 1
    guard
      setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else { return }
    var timeout = timeval(tv_sec: Int(Self.requestDeadline), tv_usec: 0)
    setsockopt(
      connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard let request = Self.readRequest(connection) else { return }
    let reply = respond(to: request)
    _ = reply.withCString { send(connection, $0, strlen($0), 0) }
  }

  /// Reads up to the blank line that ends git's request, or nil past `maxRequest` or
  /// `requestDeadline`, which bounds the whole request however slowly its bytes come.
  static func readRequest(_ connection: Int32) -> String? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    let deadline = Date().addingTimeInterval(requestDeadline)
    while data.count < maxRequest {
      let left = deadline.timeIntervalSinceNow
      guard left > 0 else { return nil }
      var timeout = timeval(
        tv_sec: Int(left), tv_usec: Int32(left.truncatingRemainder(dividingBy: 1) * 1_000_000))
      setsockopt(
        connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      let count = recv(connection, &buffer, buffer.count, 0)
      guard count > 0 else { return nil }
      data.append(buffer, count: count)
      if data.range(of: Data("\n\n".utf8)) != nil { return String(data: data, encoding: .utf8) }
    }
    return nil
  }

  /// The reply to `request` (the secret's line, then git's), as `username`/`password` lines, or an
  /// `error=` line the agent passes on to git.
  func respond(to request: String) -> String {
    let lines = request.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let secret = lines.first, !secret.isEmpty,
      lock.withLock({ secrets.values.contains { Self.same($0, secret) } })
    else { return "error=this workroom's credential relay isn't known to the Workroom app\n" }
    var fields: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let equals = line.firstIndex(of: "=") else { continue }
      fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    guard fields["protocol"] == "https", fields["host"] == "github.com" else {
      return "error=only github.com over https is relayed\n"
    }
    do {
      let answer = try answer("protocol=https\nhost=github.com\n\n")
      // Only the credential goes back.
      let credential = answer.split(separator: "\n").filter {
        $0.hasPrefix("username=") || $0.hasPrefix("password=")
      }
      guard credential.count == 2 else {
        return "error=gh has no GitHub sign-in on this Mac: run `gh auth login`\n"
      }
      return credential.joined(separator: "\n") + "\n"
    } catch {
      return "error=\(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))\n"
    }
  }

  /// Compares in time that depends on the lengths only.
  static func same(_ one: String, _ other: String) -> Bool {
    let (a, b) = (Array(one.utf8), Array(other.utf8))
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
  }

  // MARK: gh

  /// `gh auth git-credential get` with `request` on stdin: gh's own answer to git, for the account
  /// it has signed in on github.com.
  @Sendable static func gh(_ request: String) throws -> String {
    try runGH(["auth", "git-credential", "get"], input: request)
  }

  /// The token `gh` holds for github.com, for git commands the app runs on a relayed workroom's
  /// host while provisioning it (`RemoteProvisioning.cloneEnvironment`).
  @Sendable static func gitHubToken() async throws -> String {
    try await runBlocking {
      let token = try runGH(["auth", "token", "--hostname", "github.com"], input: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else { throw RemoteWorkrooms.Failure.signedOut }
      return token
    }
  }

  /// Whether `gh` lists a sign-in for github.com, read from its config without running it: for the
  /// New Workroom menu, which can't wait. A create checks for real (`gitHubToken`).
  static func hasGitHubSignIn(
    hosts: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/gh/hosts.yml")
  ) -> Bool {
    guard let text = try? String(contentsOf: hosts, encoding: .utf8) else { return false }
    return text.split(separator: "\n").contains { $0.hasPrefix("github.com:") }
  }

  private static func runGH(_ arguments: [String], input: String?) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh"] + arguments
    // A Finder-launched app's PATH has no Homebrew; gh is wherever the user's shell finds it.
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = ShellEnvironment.path()
    environment["GH_PROMPT_DISABLED"] = "1"
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    // A gh gone before its input is written would raise SIGPIPE, which ends the app.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try process.run()
    // Read on another queue, so a gh that hangs (a keychain prompt) is ended by the deadline
    // rather than holding this thread until it closes its output.
    let read = DispatchGroup()
    nonisolated(unsafe) var output = Data()
    DispatchQueue.global().async(group: read) {
      output = stdout.fileHandleForReading.readDataToEndOfFile()
    }
    if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
    try? stdin.fileHandleForWriting.close()
    guard exited.wait(timeout: .now() + 15) == .success else {
      process.terminate()
      throw HostDriverError.provisioning("gh didn't answer in time")
    }
    read.wait()
    guard process.terminationStatus == 0 else {
      throw HostDriverError.provisioning(
        "gh has no GitHub sign-in on this Mac: run `gh auth login`")
    }
    return String(decoding: output, as: UTF8.self)
  }

  // MARK: Hosts

  /// Has host `id`'s agent ask this Mac for git's credentials: its listener carried here, and
  /// `wr-agent credential relay` run there with this launch's secret. Run on every connect: the
  /// listener goes with the connection, and the secret with the launch.
  @MainActor
  func install(on host: HostID, driver: any HostDriver, agentBinary: String) async throws {
    guard case .remote(let id) = host else { return }
    let target = try localPort()
    try await registry(target: target).open(workroom: id, host: host)
    let command =
      ContainerHostDriver.shellQuoted(agentBinary)
      + " credential relay --port \(Self.port(for: id))"
    let (status, output) = try await driver.exec(command, on: host).communicate(
      Data((try secret(for: id) + "\n").utf8), timeout: 30)
    guard status == 0 else {
      throw HostDriverError.provisioning("setting up git's credentials failed: \(output)")
    }
  }

  /// Stops carrying host `id`'s relay: its workroom is gone.
  @MainActor
  func close(_ id: UUID) {
    lock.withLock { forwards }?.close(workroom: id)
    _ = lock.withLock { secrets.removeValue(forKey: id) }
  }

  @MainActor
  private func registry(target: UInt16) -> ReverseForwardRegistry {
    if let made = lock.withLock({ forwards }) { return made }
    let made = ReverseForwardRegistry(
      transport: transport, port: { Self.port(for: $0) }, target: { target },
      failure: {
        HostDriverError.provisioning("the workroom's agent couldn't relay git's credentials: \($0)")
      })
    lock.withLock { forwards = made }
    return made
  }
}
