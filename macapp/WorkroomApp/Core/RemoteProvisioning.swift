import Foundation

/// Making remote workrooms the portable way (#252; design doc Phase 4, "Remote creation is one
/// sequence"). Every workroom is a host of its own, made fresh, with its own clone:
/// **create → enrol → clone and check out → serve.** A driver's speed differs, never the sequence.
/// There is no base machine to derive from: a derive measured slower than a fresh machine on boxd,
/// and saved about 2.5 s on exe.dev (2026-10-10).
///
/// Every step before the last undoes what the sequence made when a later one fails: the host and
/// its enrolment grant.
///
/// Repository work runs through the agent's exec service, and the Go CLI stays on the Mac.
enum RemoteProvisioning {
  /// A step of a remote create that takes long enough to say (#356): the boxd driver's machine work
  /// and the sequence's own git and enrolment.
  enum Step: String, CaseIterable, Sendable {
    case machine = "Creating the workroom's machine"
    case setup = "Setting it up"
    case enrol = "Signing it in to Codaset"
    case clone = "Cloning the repository"
    case checkout = "Checking out the workroom's branch"
  }

  /// Told each `Step` as it starts, for a create's progress on its project row. Set with
  /// `$reportStep.withValue`: a task-local, so the driver's methods keep their shape, as
  /// `ContainerHostDriver.$pullProgress` does for an image pull.
  @TaskLocal static var reportStep: (@Sendable (Step) -> Void)?

  /// What the sequence reaches a provider and the broker through.
  struct Environment: Sendable {
    let driver: any HostDriver
    /// The agent's socket on each host of `driver`, which puts the agent's binary beside it.
    let agentSocket: String
    /// The broker, when signed in to Codaset. Without it, only a relayed workroom can be made
    /// (#309).
    let client: BrokerClient?
    /// The Mac's own GitHub token (`gh`), for a workroom whose repository's git goes through the
    /// Mac's credential relay rather than the broker (#309), or nil where there is none (a remote
    /// host).
    var gitHubToken: (@Sendable () async throws -> String)? = nil
    var agentBroker: AgentEnrolment.AgentBroker = .standard
    /// A connection to the agent on a host, bootstrapping one there first.
    var connect: @Sendable (HostID) async throws -> AgentVCSConnection

    init(
      driver: any HostDriver, agentSocket: String, client: BrokerClient?,
      gitHubToken: (@Sendable () async throws -> String)? = nil,
      agentBroker: AgentEnrolment.AgentBroker = .standard,
      connect: (@Sendable (HostID) async throws -> AgentVCSConnection)? = nil
    ) {
      self.driver = driver
      self.agentSocket = agentSocket
      self.client = client
      self.gitHubToken = gitHubToken
      self.agentBroker = agentBroker
      self.connect =
        connect ?? { host in
          try await AgentBootstrap.connect(host: host, driver: driver, socket: agentSocket)
        }
    }

    var agentBinary: String { AgentBootstrap.binary(besideSocket: agentSocket) }
  }

  /// A workroom's host, serving requests over `connection`.
  struct Instance: Sendable {
    let host: HostID
    /// Its broker grant; nil for a relayed workroom, which never enrols.
    let grantID: String?
    let path: String
    let branch: String
    let connection: AgentVCSConnection

    /// Whether its git takes credentials from the Mac's relay instead of the broker (#309).
    var relayed: Bool { grantID == nil }
  }

  enum Failure: Error, Equatable, LocalizedError {
    case git(command: String, detail: String)
    /// A step failed with `cause`, and undoing what the sequence had made failed too: `host` is
    /// still up (nil once it is gone) and `grantID` still live (nil once cancelled). The caller
    /// has to record them and finish the job, since nothing else knows about them. An empty
    /// `cause` is a teardown that failed itself (`tearDown`), with nothing it was undoing.
    case rollbackIncomplete(cause: String, host: HostID?, grantID: String?, cleanup: [String])

    var errorDescription: String? {
      switch self {
      case .git(let command, let detail): return "git \(command) failed on the host: \(detail)"
      case .rollbackIncomplete(let cause, _, _, let cleanup) where cause.isEmpty:
        // What stopped it is the advice: a reason already ending in a full stop gets no second.
        let left = cleanup.joined(separator: "; ")
        return "Taking it down didn't finish: \(left)\(left.hasSuffix(".") ? "" : ".")"
      case .rollbackIncomplete(let cause, _, _, let cleanup):
        return "\(cause) Undoing it failed too: \(cleanup.joined(separator: "; "))"
      }
    }
  }

  /// How long one git command may run, start to end: the agent's exec deadline is a wall clock
  /// (`exec_timeout` in `vcs.rs`, capped at 610 s), and so is the connection's request deadline.
  /// ponytail: a clone that takes longer fails, and its workroom is removed. Upgrade path: start the
  /// clone detached on the host and poll for it, so only silence ends it.
  static let gitTimeout: TimeInterval = 600

  // MARK: A legacy base

  /// Removes a base a build made before remote workrooms stopped deriving from one, and its
  /// record. Workrooms derived from it are not affected: each is a copy.
  static func destroyBase(
    _ host: UUID, in environment: Environment, forget: @Sendable () async throws -> Void
  ) async throws {
    try await environment.driver.destroy(.remote(host))
    try await forget()
  }

  // MARK: Credentials

  /// The Mac's GitHub token, for a relayed workroom (#309).
  private static func relayToken(_ environment: Environment) async throws -> String {
    guard let gitHubToken = environment.gitHubToken else {
      throw RemoteWorkrooms.Failure.signedOut
    }
    return try await gitHubToken()
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

  /// Provisions a workroom's host, signs it in, clones `cloneURL` into `path` there, and checks its
  /// own `branch` out from the remote's `startBranch`, or its default branch when that is nil (the
  /// project's base branch setting). Returns it serving. On a failure at any step, the grant is
  /// cancelled (by the enrolment itself when it was the step that failed) and the host destroyed;
  /// if either of those fails too, `Failure.rollbackIncomplete` says what is still live.
  ///
  /// git's credentials are the broker's when signed in to Codaset: `wr-agent enrol` makes the
  /// agent's helper git's, so the clone needs no token of its own. A workroom takes the Mac's own
  /// token instead, and never enrols (#309), when signed out or when the repository's owner hasn't
  /// installed the Codaset App, wherever the Mac has a token to give: a local container, never a
  /// remote provider's machine (OQ20).
  ///
  /// `checkpoint` is told what is live as soon as it is: the host once it exists, then the grant
  /// once it is minted. A crash later still leaves both recorded for a delete to take down (#253).
  /// A checkpoint that fails is a failed step, and undoes the create.
  static func provision(
    repository: String, cloneURL: String, path: String, workroom: UUID, branch: String,
    startBranch: String? = nil, in environment: Environment,
    checkpoint: @Sendable (_ host: HostID, _ grant: String?) async throws -> Void = { _, _ in }
  ) async throws -> Instance {
    // Signed out, only the Mac's token will do: checked before the machine, which can take minutes.
    let signedOut =
      environment.client == nil ? cloneEnvironment(token: try await relayToken(environment)) : nil
    let host = try await environment.driver.create()
    var connection: AgentVCSConnection?
    var grant: String?
    do {
      try await checkpoint(host, nil)
      let connected = try await environment.connect(host)
      connection = connected
      // A relayed workroom's clone and switch carry the Mac's token, and its later git asks the
      // Mac through the relay the app's connect installs.
      var header = signedOut ?? [:]
      if signedOut == nil, let client = environment.client {
        reportStep?(.enrol)
        do {
          grant = try await AgentEnrolment.enrol(
            client: client, driver: environment.driver, host: host,
            agentBinary: environment.agentBinary, workroomID: workroom,
            repository: repository, agentBroker: environment.agentBroker)
        } catch BrokerError.refused(let refusal)
          where refusal.code == "app_not_installed" && environment.gitHubToken != nil
        {
          // The broker refuses before it makes a grant, so there is none to cancel. Without `gh`
          // either, the App's install is what the user needs to hear about.
          guard let token = try? await relayToken(environment) else {
            throw BrokerError.refused(refusal)
          }
          header = cloneEnvironment(token: token)
        } catch let live as AgentEnrolment.GrantStillLive {
          // The enrolment's own cancel failed; the grant is still live, and only this knows it.
          throw RollbackStart.grantLive(
            live.grantID, cause: live.cause, failure: live.cancelFailure)
        }
        if let grant { try await checkpoint(host, grant) }
      }
      reportStep?(.clone)
      _ = try await git(
        ["clone", "--quiet", "--origin", "origin", "--", cloneURL, path], in: "/",
        environment: header, on: connected)
      reportStep?(.checkout)
      // Fully qualified: a tag or branch named like the short form would make it ambiguous.
      _ = try await git(
        [
          "switch", "--quiet", "--no-track", "--create", branch,
          "refs/remotes/origin/\(startBranch ?? "HEAD")",
        ],
        in: path, environment: header, on: connected)
      return Instance(
        host: host, grantID: grant, path: path, branch: branch, connection: connected)
    } catch {
      var error = error
      var alreadyFailed: (grant: String, failure: String)?
      if case RollbackStart.grantLive(let live, let cause, let failure) = error {
        (error, alreadyFailed) = (cause, (live, "cancelling grant \(live): \(failure)"))
      }
      let (made, client, opened) = (grant, environment.client, connection)
      // In a task of its own, so a cancelled create still undoes itself.
      let (grantLive, hostLive, failures) = await Task {
        () -> (String?, HostID?, [String]) in
        await opened?.close()
        var grantLive: String?
        var hostLive: HostID?
        var failures: [String] = []
        if let made, let client {
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
      let all = (alreadyFailed.map { [$0.failure] } ?? []) + failures
      guard !all.isEmpty else { throw error }
      throw Failure.rollbackIncomplete(
        cause: error.localizedDescription, host: hostLive,
        grantID: grantLive ?? alreadyFailed?.grant, cleanup: all)
    }
  }

  /// Carries a live grant from the enrolment step into `provision`'s rollback.
  private enum RollbackStart: Error {
    case grantLive(String, cause: any Error, failure: String)
  }

  /// Takes a workroom down: its grant first, so nothing mints for it once its box is gone, then
  /// the box. A grant the broker could not cancel does not keep the box: the key that would mint
  /// against it goes with the box. If either fails, `Failure.rollbackIncomplete` names what is
  /// still live once both have been tried.
  static func destroy(_ instance: Instance, workroom: UUID, in environment: Environment)
    async throws
  {
    await instance.connection.close()
    try await tearDown(
      host: instance.host, grantID: instance.grantID, workroom: workroom, in: environment)
  }

  /// `destroy` by what a workroom's record says is live (#253), with no connection to it: the grant
  /// if there is one, the workroom's route to the broker, and the box if there is one. Cancelling an
  /// ended grant and removing a box already gone both succeed, so a delete can be tried again.
  static func tearDown(
    host: HostID?, grantID: String?, workroom: UUID?, in environment: Environment
  ) async throws {
    var failures: [String] = []
    var (grantLive, hostLive): (String?, HostID?) = (nil, nil)
    if let grantID {
      do {
        // A grant needs the broker to cancel; signed out, it is left for a later delete.
        guard let client = environment.client else {
          throw RemoteWorkrooms.Failure.signedOutOfGrant
        }
        try await client.cancelGrant(grantID)
      } catch {
        grantLive = grantID
        failures.append("cancelling grant \(grantID): \(error.localizedDescription)")
      }
    }
    if let workroom { await environment.agentBroker.release(workroom) }
    if let host {
      do { try await environment.driver.destroy(host) } catch {
        hostLive = host
        failures.append("destroying the instance: \(error.localizedDescription)")
      }
    }
    guard !failures.isEmpty else { return }
    throw Failure.rollbackIncomplete(
      cause: "", host: hostLive, grantID: grantLive,
      cleanup: failures)
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
}
