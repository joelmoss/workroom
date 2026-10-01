import Foundation

/// Making remote workrooms the portable way (#252; design doc Phase 4, "Remote creation is one
/// sequence"). A project has one **base machine**, its repository cloned and an agent present,
/// which never enrols. Every workroom is derived from it:
/// **derive → re-init machine identity → enrol → fetch and check out → serve.**
/// A driver's speed differs, never the sequence. Re-initialising the machine's identity is the
/// driver's part of the derive (`HostDriver.deriveFromBase`), so a derived instance serves nothing
/// as its base.
///
/// Every step before the last undoes what the sequence made when a later one fails: the instance,
/// its enrolment grant, and a base's clone token.
///
/// Repository work runs through the agent's exec service, and the Go CLI stays on the Mac.
enum RemoteProvisioning {
  /// What the sequence reaches a provider and the broker through.
  struct Environment: Sendable {
    let driver: any HostDriver
    /// The agent's socket on each host of `driver`, which puts the agent's binary beside it.
    let agentSocket: String
    let client: BrokerClient
    var agentBroker: AgentEnrolment.AgentBroker = .standard
    /// A connection to the agent on a host, bootstrapping one there first.
    var connect: @Sendable (HostID) async throws -> AgentVCSConnection
    /// Lets go of a base's clone token once the clone is done, whether or not it succeeded.
    var revoke: @Sendable (BrokerClient.CloneToken) async -> Void = CloneToken.revoke

    init(
      driver: any HostDriver, agentSocket: String, client: BrokerClient,
      agentBroker: AgentEnrolment.AgentBroker = .standard,
      connect: (@Sendable (HostID) async throws -> AgentVCSConnection)? = nil,
      revoke: @escaping @Sendable (BrokerClient.CloneToken) async -> Void = CloneToken.revoke
    ) {
      self.driver = driver
      self.agentSocket = agentSocket
      self.client = client
      self.agentBroker = agentBroker
      self.connect =
        connect ?? { host in
          try await AgentBootstrap.connect(host: host, driver: driver, socket: agentSocket)
        }
      self.revoke = revoke
    }

    var agentBinary: String { AgentBootstrap.binary(besideSocket: agentSocket) }
  }

  /// A project's base machine, as the project's host descriptor records it.
  struct Base: Codable, Equatable, Sendable {
    let host: UUID
    /// `owner/name` on GitHub, which the broker mints tokens for.
    let repository: String
    let cloneURL: String
    /// The clone on the host.
    let path: String
  }

  /// A workroom derived from a base, serving requests over `connection`.
  struct Instance: Sendable {
    let host: HostID
    let grantID: String
    let path: String
    let branch: String
    let connection: AgentVCSConnection
  }

  enum Failure: Error, Equatable, LocalizedError {
    case git(command: String, detail: String)
    /// A step failed with `cause`, and undoing what the sequence had made failed too: `host` is
    /// still up (nil once it is gone) and `grantID` still live (nil once cancelled). The caller
    /// has to record them and finish the job, since nothing else knows about them.
    case rollbackIncomplete(cause: String, host: HostID?, grantID: String?, cleanup: [String])

    var errorDescription: String? {
      switch self {
      case .git(let command, let detail): return "git \(command) failed on the host: \(detail)"
      case .rollbackIncomplete(let cause, _, _, let cleanup):
        return "\(cause) Undoing it failed too: \(cleanup.joined(separator: "; "))"
      }
    }
  }

  /// How long one git command may run, start to end: the agent's exec deadline is a wall clock
  /// (`exec_timeout` in `vcs.rs`, capped at 610 s), and so is the connection's request deadline.
  /// ponytail: a clone that takes longer fails, and its base is removed. Upgrade path: start the
  /// clone detached on the host and poll for it, so only silence ends it.
  static let gitTimeout: TimeInterval = 600

  // MARK: The base

  /// Provisions a base, clones `cloneURL` into `path` there with a one-shot read-only token from
  /// the broker, and records it with `record`. The token reaches git only through the exec
  /// request's environment (`cloneEnvironment`), never its arguments, the remote URL or the disk,
  /// and is revoked once the clone is over. A failure removes the base.
  static func buildBase(
    repository: String, cloneURL: String, path: String, in environment: Environment,
    record: @Sendable (Base) async throws -> Void
  ) async throws -> Base {
    let host = try await environment.driver.create()
    do {
      guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
      let connection = try await environment.connect(host)
      defer { Task { await connection.close() } }
      try await withCloneToken(repository, in: environment) { header in
        _ = try await git(
          ["clone", "--quiet", "--origin", "origin", "--", cloneURL, path], in: "/",
          environment: header, on: connection)
      }
      let base = Base(host: id, repository: repository, cloneURL: cloneURL, path: path)
      try await record(base)
      return base
    } catch {
      let failed = await Task { () -> String? in
        do {
          try await environment.driver.destroy(host)
          return nil
        } catch { return error.localizedDescription }
      }.value
      guard let failed else { throw error }
      throw Failure.rollbackIncomplete(
        cause: error.localizedDescription, host: host, grantID: nil, cleanup: [failed])
    }
  }

  /// Brings the base's clone up to date with the remote, for workrooms derived from it later: a
  /// derived workroom fetches what it lacks itself, so this only shortens that fetch. The base
  /// never enrols, so it fetches with a clone token too.
  static func refreshBase(_ base: Base, in environment: Environment) async throws {
    try await BaseLocks.shared.exclusively(on: base.host) {
      let connection = try await environment.connect(.remote(base.host))
      defer { Task { await connection.close() } }
      try await withCloneToken(base.repository, in: environment) { header in
        try await fetch(base.path, environment: header, on: connection)
      }
    }
  }

  /// Fetches, then asks the remote which branch is its default. `fetch` never moves
  /// `origin/HEAD`, which the clone fixed: after a rename of the default branch it would name the
  /// old one, and once `--prune` drops that, nothing at all (git 2.39 has no `followRemoteHEAD`).
  private static func fetch(
    _ path: String, environment extra: [String: String] = [:], on connection: AgentVCSConnection
  ) async throws {
    _ = try await git(
      ["fetch", "--quiet", "--prune", "origin"], in: path, environment: extra, on: connection)
    _ = try await git(
      ["remote", "set-head", "origin", "--auto"], in: path, environment: extra, on: connection)
  }

  /// Removes the base and its record. Workrooms derived from it are not affected: each is a copy.
  static func destroyBase(
    _ base: Base, in environment: Environment, forget: @Sendable () async throws -> Void
  ) async throws {
    try await BaseLocks.shared.exclusively(on: base.host) {
      try await environment.driver.destroy(.remote(base.host))
    }
    try await forget()
  }

  /// Mints a clone token, hands `body` the exec environment carrying it, and revokes it after,
  /// whatever `body` did.
  private static func withCloneToken(
    _ repository: String, in environment: Environment,
    _ body: ([String: String]) async throws -> Void
  ) async throws {
    let token = try await environment.client.baseCloneToken(repository: repository)
    do {
      try await body(cloneEnvironment(token: token.token))
    } catch {
      await cleanUp { await environment.revoke(token) }
      throw error
    }
    await cleanUp { await environment.revoke(token) }
  }

  /// git's configuration through its environment (`GIT_CONFIG_COUNT`), so the token is in no
  /// argument a process list shows, in no URL git stores, and in no file: an `Authorization`
  /// header for github.com only, which is how GitHub takes an installation token over https.
  static func cloneEnvironment(token: String) -> [String: String] {
    let credentials = Data("x-access-token:\(token)".utf8).base64EncodedString()
    return [
      "GIT_CONFIG_COUNT": "1",
      "GIT_CONFIG_KEY_0": "http.https://github.com/.extraHeader",
      "GIT_CONFIG_VALUE_0": "Authorization: Basic \(credentials)",
    ]
  }

  // MARK: A workroom

  /// Derives a workroom from `base`, enrols it, and checks its own `branch` out from the remote's
  /// default branch. Returns it serving. On a failure at any step, the grant is cancelled (by the
  /// enrolment itself when it was the step that failed) and the instance destroyed; if either of
  /// those fails too, `Failure.rollbackIncomplete` says what is still live.
  static func derive(
    from base: Base, workroom: UUID, branch: String, in environment: Environment
  ) async throws -> Instance {
    // The snapshot only: a commit taken while a refresh's fetch holds its ref locks would hand
    // every workroom derived from it those stale `.lock` files.
    let host = try await BaseLocks.shared.exclusively(on: base.host) {
      try await environment.driver.deriveFromBase(.remote(base.host))
    }
    var connection: AgentVCSConnection?
    var grant: String?
    do {
      let connected = try await environment.connect(host)
      connection = connected
      let grantID = try await AgentEnrolment.enrol(
        client: environment.client, driver: environment.driver, host: host,
        agentBinary: environment.agentBinary, workroomID: workroom,
        repository: base.repository, agentBroker: environment.agentBroker)
      grant = grantID
      // With the instance's own credentials: `wr-agent enrol` made its helper git's.
      try await fetch(base.path, on: connected)
      // Fully qualified: a tag or branch named `origin/HEAD` would make the short form ambiguous.
      _ = try await git(
        ["switch", "--quiet", "--no-track", "--create", branch, "refs/remotes/origin/HEAD"],
        in: base.path, on: connected)
      return Instance(
        host: host, grantID: grantID, path: base.path, branch: branch, connection: connected)
    } catch {
      let (made, client, opened) = (grant, environment.client, connection)
      // In a task of its own, so a cancelled derive still undoes itself.
      let (grantLive, hostLive, failures) = await Task {
        () -> (String?, HostID?, [String]) in
        await opened?.close()
        var grantLive: String?
        var hostLive: HostID?
        var failures: [String] = []
        if let made {
          do { try await client.cancelGrant(made) } catch {
            grantLive = made
            failures.append("cancelling grant \(made): \(error.localizedDescription)")
          }
        }
        await environment.agentBroker.release(workroom)
        do { try await environment.driver.destroy(host) } catch {
          hostLive = host
          failures.append("destroying the instance: \(error.localizedDescription)")
        }
        return (grantLive, hostLive, failures)
      }.value
      guard !failures.isEmpty else { throw error }
      throw Failure.rollbackIncomplete(
        cause: error.localizedDescription, host: hostLive, grantID: grantLive, cleanup: failures)
    }
  }

  /// Takes a workroom down: its grant first, so nothing mints for it once its box is gone, then
  /// the box. A grant the broker could not cancel does not keep the box: the key that would mint
  /// against it goes with the box. The first failure is thrown once both have been tried.
  static func destroy(_ instance: Instance, workroom: UUID, in environment: Environment)
    async throws
  {
    await instance.connection.close()
    var failure: Error?
    do { try await environment.client.cancelGrant(instance.grantID) } catch { failure = error }
    await environment.agentBroker.release(workroom)
    do { try await environment.driver.destroy(instance.host) } catch { failure = failure ?? error }
    if let failure { throw failure }
  }

  // MARK: Plumbing

  /// One git command on the host, through the agent's exec service: the host's own environment,
  /// the remote policy pins, and `extra` on top.
  static func git(
    _ args: [String], in directory: String, environment extra: [String: String] = [:],
    on connection: AgentVCSConnection
  ) async throws -> String {
    var request = AgentCommandRunner.request(
      "git", args, in: directory, timeout: gitTimeout, stdin: nil, network: true,
      host: connection.host)
    request.env.merge(extra) { _, new in new }
    let reply = try await connection.request(request, timeout: gitTimeout + 15)
    let result = try AgentVCSReply<AgentExecResult>.decode(reply)
    guard result.exitCode == 0, !result.timedOut, !result.signaled else {
      throw Failure.git(
        command: args.first ?? "",
        detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result.stdout
  }

  /// Undoes a step whatever the caller's state: in a task of its own, so a cancelled sequence
  /// still cleans up after itself.
  private static func cleanUp(_ body: @escaping @Sendable () async throws -> Void) async {
    await Task { try? await body() }.value
  }
}

/// One operation at a time on each base (#252): a derive's snapshot, a refresh, a destroy. A
/// `docker commit` freezes the base wherever its git happens to be, so a snapshot taken during a
/// refresh's fetch would keep that fetch's `.lock` files. Different bases go on at once.
/// ponytail: in this process only; a second app instance could still overlap. Upgrade path: a
/// lock on the host, taken through the agent.
actor BaseLocks {
  static let shared = BaseLocks()
  private var busy: Set<UUID> = []
  private var waiting: [UUID: [CheckedContinuation<Void, Never>]] = [:]

  func exclusively<T: Sendable>(on base: UUID, _ body: @Sendable () async throws -> T)
    async throws -> T
  {
    await acquire(base)
    // A caller cancelled while it waited gives the base up rather than start a 15-minute commit
    // nobody wants. ponytail: it still waits its turn first; a waiter is not dequeued on
    // cancellation.
    if Task.isCancelled {
      release(base)
      throw CancellationError()
    }
    do {
      let value = try await body()
      release(base)
      return value
    } catch {
      release(base)
      throw error
    }
  }

  private func acquire(_ base: UUID) async {
    guard busy.contains(base) else {
      busy.insert(base)
      return
    }
    await withCheckedContinuation { waiting[base, default: []].append($0) }
  }

  /// Hands the base straight to the next waiter, so nobody can slip in between.
  private func release(_ base: UUID) {
    if var queue = waiting[base], !queue.isEmpty {
      let next = queue.removeFirst()
      waiting[base] = queue.isEmpty ? nil : queue
      next.resume()
    } else {
      busy.remove(base)
    }
  }
}

extension RemoteProvisioning {
  enum CloneToken {
    /// Revokes an installation token at GitHub, which accepts the call authenticated as the token
    /// itself. Best effort: one that fails still expires within its hour.
    @Sendable static func revoke(_ token: BrokerClient.CloneToken) async {
      guard let url = URL(string: "https://api.github.com/installation/token") else { return }
      var request = URLRequest(url: url, timeoutInterval: 15)
      request.httpMethod = "DELETE"
      request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      _ = try? await URLSession.shared.data(for: request)
    }
  }
}
