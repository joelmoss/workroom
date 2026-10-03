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
/// a workroom has the GitHub access the user's own `gh` has, as a workroom on the Mac itself does.
/// It can ask only while the app is connected, but a token it was answered with works until the
/// user revokes it. A remote workroom never uses this: it always enrols.
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

  /// Connections read at once, before anything is known of them; one more is turned away. A read
  /// takes a thread for up to `requestDeadline`, so this bounds what a flood can hold.
  static let maxReading = 32
  /// Requests answered at once, each a gh run of up to 15 s. Only a request with a known secret
  /// gets here, so connections that never say one, from anyone who can reach the listener, can't
  /// keep a workroom from being answered.
  static let maxConcurrent = 8
  /// The most one request may take to arrive, whatever pace its bytes come at. The agent writes it
  /// whole, at once (`relay` in `broker.rs`), so a second is plenty.
  static let requestDeadline: TimeInterval = 2
  private let reading = DispatchSemaphore(value: maxReading)
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
      guard reading.wait(timeout: .now()) == .success else {
        Darwin.close(connection)
        continue
      }
      queue.async { [weak self] in
        defer { Darwin.close(connection) }
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
    let request = { () -> String? in
      defer { reading.signal() }
      return Self.readRequest(connection)
    }()
    guard let request else { return }
    // Only a known secret waits its turn for an answer; anything else is answered at once.
    let reply: String
    if knows(request) {
      guard serving.wait(timeout: .now() + 5) == .success else { return }
      defer { serving.signal() }
      reply = respond(to: request)
    } else {
      reply = respond(to: request)
    }
    _ = reply.withCString { send(connection, $0, strlen($0), 0) }
  }

  /// Whether `request` starts with a secret this launch made.
  private func knows(_ request: String) -> Bool {
    guard let secret = request.split(separator: "\n", omittingEmptySubsequences: false).first,
      !secret.isEmpty
    else { return false }
    return lock.withLock { secrets.values.contains { Self.same($0, String(secret)) } }
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

  /// Whether `gh` has a sign-in for github.com, read from its config without running it: for the
  /// New Workroom menu, which can't wait. A create checks for real (`gitHubToken`). Found as the gh
  /// this app runs finds it, in this app's environment: a token there, else `hosts.yml` in
  /// `GH_CONFIG_DIR`, `$XDG_CONFIG_HOME/gh` or `~/.config/gh`, in gh's order.
  static func hasGitHubSignIn(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    let set = { (name: String) in environment[name].flatMap { $0.isEmpty ? nil : $0 } }
    if set("GH_TOKEN") != nil || set("GITHUB_TOKEN") != nil { return true }
    let directory =
      set("GH_CONFIG_DIR").map { URL(fileURLWithPath: $0) }
      ?? set("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0).appendingPathComponent("gh") }
      ?? home.appendingPathComponent(".config/gh")
    guard
      let text = try? String(
        contentsOf: directory.appendingPathComponent("hosts.yml"), encoding: .utf8)
    else { return false }
    return text.split(separator: "\n").contains { $0.hasPrefix("github.com:") }
  }

  private static func runGH(_ arguments: [String], input: String?) throws -> String {
    // A Finder-launched app's PATH has no Homebrew; gh is wherever the user's shell finds it.
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = ShellEnvironment.path()
    environment["GH_PROMPT_DISABLED"] = "1"
    let (status, output) = try run(
      URL(fileURLWithPath: "/usr/bin/env"), ["gh"] + arguments, input: input,
      environment: environment, name: "gh")
    guard status == 0 else {
      throw HostDriverError.provisioning(
        "gh has no GitHub sign-in on this Mac: run `gh auth login`")
    }
    return output
  }

  /// Runs `executable`, bounded by `deadline` from start to the end of its output, whatever it or
  /// anything it started does: a relay request holds a serving slot until this returns. Its output
  /// is read here, on this thread, so a deadline leaves no reader behind: one that ignores SIGTERM
  /// is killed, and a child of its that keeps its stdout open loses the pipe.
  static func run(
    _ executable: URL, _ arguments: [String], input: String?, environment: [String: String],
    name: String, deadline seconds: TimeInterval = 15
  ) throws -> (status: Int32, output: String) {
    let deadline = DispatchTime.now() + seconds
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
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
    let out = stdout.fileHandleForReading
    defer { try? out.close() }
    let stop = {
      process.terminate()
      if exited.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
    }
    if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
    try? stdin.fileHandleForWriting.close()
    // To EOF or the deadline: a gh that hangs (a keychain prompt) is ended rather than waited on.
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var reader = pollfd(fd: out.fileDescriptor, events: Int16(POLLIN), revents: 0)
    while true {
      let left = Int(
        (deadline.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds) / 1_000_000)
      guard deadline > .now(), left > 0 else {
        stop()
        throw HostDriverError.provisioning("\(name) didn't answer in time")
      }
      let ready = poll(&reader, 1, Int32(min(left, Int(Int32.max))))
      if ready < 0, errno == EINTR { continue }
      guard ready > 0 else { continue }
      let count = Darwin.read(out.fileDescriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      output.append(buffer, count: count)
    }
    guard exited.wait(timeout: deadline) == .success else {
      stop()
      throw HostDriverError.provisioning("\(name) didn't answer in time")
    }
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
  }

  // MARK: Hosts

  /// Has host `id`'s agent ask this Mac for git's credentials: its listener carried here, and
  /// `wr-agent credential relay` run there with this launch's secret. Run on every connect: the
  /// listener goes with the connection, and the secret with the launch.
  @MainActor
  func install(on host: HostID, driver: any HostDriver, agentBinary: String) async throws {
    guard case .remote(let id) = host else { return }
    // Listening first, so a listener that can't be made fails here rather than in the registry.
    _ = try localPort()
    try await registry().open(workroom: id, host: host)
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
  private func registry() -> ReverseForwardRegistry {
    if let made = lock.withLock({ forwards }) { return made }
    // Asked for each listener: a listener that stopped accepting is made again on a new port, and
    // the next connect's install carries the forwards there.
    let made = ReverseForwardRegistry(
      transport: transport, port: { Self.port(for: $0) },
      target: { [weak self] in (try? self?.localPort()) ?? 0 },
      failure: {
        HostDriverError.provisioning("the workroom's agent couldn't relay git's credentials: \($0)")
      })
    lock.withLock { forwards = made }
    return made
  }
}
