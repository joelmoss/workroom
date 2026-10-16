import AgentConnection
import Foundation
import HostDrivers
import WorkroomSystem
import WorkroomVCS

/// Making remote workrooms the portable way (#252; design doc Phase 4, "Remote creation is one
/// sequence"). Every workroom is a host of its own, made fresh, with its own clone:
/// **create → clone and check out → serve.** A driver's speed differs, never the sequence.
/// There is no base machine to derive from: a derive measured slower than a fresh machine on boxd,
/// and saved about 2.5 s on exe.dev (2026-10-10).
///
/// Every step before the last undoes what the sequence made when a later one fails: the host.
///
/// git's credentials on a remote provider's host are the provider's own (boxd's git integration,
/// exe.dev's GitHub integration): Workroom gives that host none. A local container has no provider,
/// so its git asks the Mac's own `gh` through the credential relay (#309).
///
/// Repository work runs through the agent's exec service, and the Go CLI stays on the Mac.
enum RemoteProvisioning {
  /// What the sequence reaches a provider through.
  struct Environment: Sendable {
    let driver: any HostDriver
    /// The agent's socket on each host of `driver`, which puts the agent's binary beside it.
    let agentSocket: String
    /// The Mac's own GitHub token (`gh`), for a workroom whose git goes through the Mac's credential
    /// relay (#309), or nil on a remote provider's host, whose git credentials are the provider's.
    var gitHubToken: (@Sendable () async throws -> String)? = nil
    /// What to tell the user when the clone fails, where the provider gives the host its GitHub
    /// access (`RemoteWorkrooms.Place.credentialHint`).
    var credentialHint: String?
    /// Gives the provider's hosts a repository before the first is made, where Workroom can
    /// (exe.dev's GitHub integration), or nil where it can't or needn't.
    var grantRepository: (@Sendable (GitHubRepository) async throws -> Void)?
    /// A connection to the agent on a host, bootstrapping one there first.
    var connect: @Sendable (HostID) async throws -> AgentVCSConnection

    init(
      driver: any HostDriver, agentSocket: String,
      gitHubToken: (@Sendable () async throws -> String)? = nil,
      credentialHint: String? = nil,
      grantRepository: (@Sendable (GitHubRepository) async throws -> Void)? = nil,
      connect: (@Sendable (HostID) async throws -> AgentVCSConnection)? = nil
    ) {
      self.driver = driver
      self.agentSocket = agentSocket
      self.gitHubToken = gitHubToken
      self.credentialHint = credentialHint
      self.grantRepository = grantRepository
      self.connect =
        connect ?? { host in
          try await AgentBootstrap.connect(host: host, driver: driver, socket: agentSocket)
        }
    }

    var agentBinary: String { AgentInstall.binary(besideSocket: agentSocket) }
  }

  /// A workroom's host, serving requests over `connection`.
  struct Instance: Sendable {
    let host: HostID
    let path: String
    let branch: String
    let connection: AgentVCSConnection
    /// Whether its git takes credentials from the Mac's relay (#309).
    let relayed: Bool
  }

  enum Failure: Error, Equatable, LocalizedError {
    case git(command: String, detail: String)
    /// A step failed with `cause`, and undoing what the sequence had made failed too: `host` is
    /// still up. The caller has to record it and finish the job, since nothing else knows about
    /// it. An empty `cause` is a teardown that failed itself (`tearDown`), with nothing it was
    /// undoing.
    case rollbackIncomplete(cause: String, host: HostID, cleanup: [String])

    var errorDescription: String? {
      switch self {
      case .git(let command, let detail): return "git \(command) failed on the host: \(detail)"
      case .rollbackIncomplete(let cause, _, let cleanup) where cause.isEmpty:
        // What stopped it is the advice: a reason already ending in a full stop gets no second.
        let left = cleanup.joined(separator: "; ")
        return "Taking it down didn't finish: \(left)\(left.hasSuffix(".") ? "" : ".")"
      case .rollbackIncomplete(let cause, _, let cleanup):
        return "\(cause) Undoing it failed too: \(cleanup.joined(separator: "; "))"
      }
    }
  }

  /// How long one git command may run, start to end: the agent's exec deadline is a wall clock
  /// (`exec_timeout` in `vcs.rs`, capped at 610 s), and so is the connection's request deadline.
  /// ponytail: a clone that takes longer fails, and its workroom is removed. Upgrade path: start the
  /// clone detached on the host and poll for it, so only silence ends it.
  static let gitTimeout: TimeInterval = 600

  // MARK: Credentials

  /// git's configuration through its environment (`GIT_CONFIG_COUNT`), so the token is in no
  /// argument a process list shows, in no URL git stores, and in no file: an `Authorization`
  /// header for github.com only, which is how GitHub takes a token over https. An ssh-form origin
  /// is rewritten to https so the header reaches it, as the relay's own git config does after
  /// (`wr-agent credential relay`).
  static func cloneEnvironment(token: String) -> [String: String] {
    let credentials = Data("x-access-token:\(token)".utf8).base64EncodedString()
    return [
      "GIT_CONFIG_COUNT": "2",
      "GIT_CONFIG_KEY_0": "http.https://github.com/.extraHeader",
      "GIT_CONFIG_VALUE_0": "Authorization: Basic \(credentials)",
      "GIT_CONFIG_KEY_1": "url.https://github.com/.insteadOf",
      "GIT_CONFIG_VALUE_1": "git@github.com:",
    ]
  }

  // MARK: A workroom

  /// Provisions a workroom's host, clones `cloneURL` into `path` there, and checks its own `branch`
  /// out from the remote's `startBranch`, or its default branch when that is nil (the project's
  /// base branch setting). Returns it serving. On a failure at any step, the host is destroyed; if
  /// that fails too, `Failure.rollbackIncomplete` says it is still live.
  ///
  /// A workroom with `gitHubToken` (a local container) clones with the Mac's token and later asks
  /// the Mac through the relay the app's connect installs (#309). Any other uses whatever git
  /// credentials its provider gave the host; a clone that fails for want of them says how to give
  /// them (`credentialHint`).
  ///
  /// `checkpoint` is told the host as soon as it exists. A crash later still leaves it recorded for
  /// a delete to take down (#253). A checkpoint that fails is a failed step, and undoes the create.
  static func provision(
    cloneURL: String, path: String, branch: String, startBranch: String? = nil,
    in environment: Environment,
    checkpoint: @Sendable (_ host: HostID) async throws -> Void = { _ in }
  ) async throws -> Instance {
    // The Mac's token first: checked before the machine, which can take minutes.
    var header: [String: String]?
    if let gitHubToken = environment.gitHubToken {
      header = cloneEnvironment(token: try await gitHubToken())
    }
    let host = try await environment.driver.create()
    var connection: AgentVCSConnection?
    do {
      try await checkpoint(host)
      ProvisioningProgress.reportStep?(.connect)
      let connected = try await environment.connect(host)
      connection = connected
      ProvisioningProgress.reportStep?(.clone)
      do {
        _ = try await git(
          ["clone", "--quiet", "--origin", "origin", "--", cloneURL, path], in: "/",
          environment: header ?? [:], on: connected, step: .clone)
      } catch Failure.git(let command, let detail) where environment.credentialHint != nil {
        throw Failure.git(
          command: command, detail: "\(detail)\n\n\(environment.credentialHint ?? "")")
      }
      ProvisioningProgress.reportStep?(.checkout)
      // Fully qualified: a tag or branch named like the short form would make it ambiguous.
      _ = try await git(
        [
          "switch", "--quiet", "--no-track", "--create", branch,
          "refs/remotes/origin/\(startBranch ?? "HEAD")",
        ],
        in: path, environment: header ?? [:], on: connected, step: .checkout)
      return Instance(
        host: host, path: path, branch: branch, connection: connected, relayed: header != nil)
    } catch {
      let opened = connection
      // In a task of its own, so a cancelled create still undoes itself.
      let failure = await Task { () -> String? in
        await opened?.close()
        do { try await environment.driver.destroy(host) } catch {
          return "destroying the instance: \(error.localizedDescription)"
        }
        return nil
      }.value
      guard let failure else { throw error }
      throw Failure.rollbackIncomplete(
        cause: error.localizedDescription, host: host, cleanup: [failure])
    }
  }

  /// Takes a workroom down: its connection, then its box. If that fails,
  /// `Failure.rollbackIncomplete` says the box is still live.
  static func destroy(_ instance: Instance, in environment: Environment) async throws {
    await instance.connection.close()
    try await tearDown(host: instance.host, in: environment)
  }

  /// `destroy` by what a workroom's record says is live (#253), with no connection to it. Removing a
  /// box already gone succeeds, so a delete can be tried again.
  static func tearDown(host: HostID, in environment: Environment) async throws {
    do { try await environment.driver.destroy(host) } catch {
      throw Failure.rollbackIncomplete(
        cause: "", host: host,
        cleanup: ["destroying the instance: \(error.localizedDescription)"])
    }
  }

  // MARK: Plumbing

  /// One git command on the host, through the agent's exec service: the host's own environment,
  /// the remote policy pins, and `extra` on top. With `step`, the command line and its output go to
  /// the create's log (`ProvisioningProgress.log`, #483) under that step. Never `extra`, which can
  /// carry the clone's token header (`cloneEnvironment`).
  static func git(
    _ args: [String], in directory: String, environment extra: [String: String] = [:],
    on connection: AgentVCSConnection, step: ProvisioningProgress.Step? = nil
  ) async throws -> String {
    let log = step.flatMap { step in
      ProvisioningProgress.log.map { log in { @Sendable (text: String) in log(step, text) } }
    }
    log?(
      "$ git "
        + args.map { $0.contains(where: \.isWhitespace) ? PosixShell.quoted($0) : $0 }
        .joined(separator: " "))
    var request = AgentCommandRunner.request(
      "git", args, in: directory, timeout: gitTimeout, stdin: nil, network: true,
      host: connection.host)
    request.env.merge(extra) { _, new in new }
    let reply = try await connection.request(request, timeout: gitTimeout + 15)
    let result = try AgentVCSReply<AgentExecResult>.decode(reply)
    if let log {
      for line in (result.stdout + "\n" + result.stderr).split(separator: "\n") {
        log(String(line))
      }
    }
    guard result.exitCode == 0, !result.timedOut, !result.signaled else {
      throw Failure.git(
        command: args.first ?? "",
        detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result.stdout
  }
}
