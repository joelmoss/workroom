import Foundation

/// Forwards `StatusCommandRunning` calls to wr-agent's exec service instead of spawning `git`/`jj`
/// locally. This is the whole seam `AgentVCSConnection.writer` needs: `CLIVCSWriter`'s arg
/// building, stdout/stderr parsing and failure classification are untouched Swift, and see exactly
/// the bytes a host-executed command produced — see `vcs.rs`'s `ExecRequest` doc for the design.
///
/// Never throws: `StatusCommandRunning.run` doesn't, so every failure here becomes a
/// `CommandResult` the existing classifiers already understand. Which one is NOT uniform, and the
/// distinction is load-bearing — see `neverRan` and `outcomeUnknown`.
struct AgentCommandRunner: StatusCommandRunning, Sendable {
  let connection: AgentVCSConnection
  /// The shared root of a jj repository on a REMOTE host, whose working-copy barrier the agent
  /// takes around each command (`barrier_root` in `vcs.rs`). Nil locally, where the caller's gate
  /// holds it for the whole operation and the agent must never take it again.
  var barrierRoot: String?

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    await exec(executable, args, in: directory, timeout: timeout, stdin: nil, network: false)
  }

  func run(
    _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
    stdin: Data?
  ) async -> CommandResult {
    await exec(executable, args, in: directory, timeout: timeout, stdin: stdin, network: false)
  }

  func runNetwork(
    _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval
  ) async -> CommandResult {
    await exec(executable, args, in: directory, timeout: timeout, stdin: nil, network: true)
  }

  private func exec(
    _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
    stdin: Data?, network: Bool
  ) async -> CommandResult {
    // The WHOLE environment native would use, not a key allowlist. wr-agent `env_clear()`s and
    // adopts this map, so the child sees exactly what a native child sees. An allowlist could not
    // work here: wr-agent is a long-lived daemon "negotiated with, never replaced"
    // (`LocalAgentVCS`), so its own inherited environment is a snapshot of whichever app launch
    // first spawned it, and the set of variables `git`/`jj` read for identity, config, signing and
    // hooks is open-ended (`GIT_AUTHOR_*`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_PARAMETERS`, `HOME`,
    // `JJ_CONFIG`, `EMAIL`, `GNUPGHOME`, …). Forwarding only `PATH` silently authored commits under
    // the daemon's stale identity — see `StatusCommandRunner.childEnvironment`'s doc.
    // Latin-1, not UTF-8: a pathspec payload is NUL-separated and paths are not guaranteed valid
    // UTF-8, and Latin-1 is a total bijection over every byte 0x00-0xFF, so this never fails and
    // `vcs.rs`'s `latin1_bytes` is its exact inverse — see `ExecRequest.stdin`'s doc. Far more
    // compact on the wire than a JSON byte-number array for ordinary text.
    var payload: String?
    if let stdin {
      // Unreachable (Latin-1 decodes every byte), but the old `?? ""` fallback would have staged
      // nothing or committed an empty message. Refuse rather than send a silent lie.
      guard let encoded = String(data: stdin, encoding: .isoLatin1) else {
        return Self.neverRan("stdin payload is not representable on the wire")
      }
      payload = encoded
    }
    let request = Self.request(
      executable, args, in: directory, timeout: timeout, stdin: payload, network: network,
      host: connection.host, barrierRoot: barrierRoot)
    let reply: Data
    do {
      // Slack above the command's own timeout: the round trip and the agent's own bookkeeping
      // must not race the command's own timeout.
      //
      // Cancellable on purpose. The write path's protection against a cancelled command releasing
      // the JJ barrier early lives in `JJSnapshotGate.run`, which shields the whole gated operation
      // once it holds the flock — see the comment there. Shielding HERE instead would also cover
      // `remoteState`'s ungated reads, and a superseded `RemoteStateModel` refresh would then squat
      // one of this connection's 32 shared slots until the agent answered.
      //
      // Plus the barrier's own wait where the agent takes one (a remote jj command): it can wait
      // up to 30s for the barrier before the command starts (`SnapshotLock::acquire`), and a
      // deadline that did not cover that would give up on a command still running.
      let barrierWait: TimeInterval = request.barrierRoot == nil ? 0 : 30
      reply = try await connection.request(request, timeout: timeout + 15 + barrierWait)
    } catch let error as VCSError {
      // Raised before anything left this process — today only the 1 MiB single-envelope request
      // ceiling. Nothing ran, and the workroom is fine.
      return Self.refused("\(error)")
    } catch HostConnectionError.notDispatched {
      // Refused locally with nothing written to the socket (a closed connection, an exhausted
      // stream counter, a full request pool). Definitively never ran.
      return Self.refused(HostConnectionError.notDispatched.localizedDescription)
    } catch {
      // The request reached the socket and no reply came back: connection loss, the client-side
      // deadline, or cancellation. The command may have completed host-side.
      return Self.outcomeUnknown(error)
    }
    do {
      let result = try AgentVCSReply<AgentExecResult>.decode(reply)
      return CommandResult(
        stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode,
        timedOut: result.timedOut, signaled: result.signaled)
    } catch {
      return Self.replyRefusal(error)
    }
  }

  /// A reply that ARRIVED carrying an error, as a result.
  ///
  /// wr-agent answers one only for a request it refused before spawning, with one exception: the
  /// reply-size guard in `vcs.rs` sends `PartialData` after the command ran. Lock contention (the
  /// `ACTIVE` budget is spent) and the request-reassembly refusals named below are "try again";
  /// everything else (bad version, unusable `dir`, non-Latin-1 stdin) keeps `neverRan`.
  ///
  /// `PartialData` is sorted by an allowlist of pre-run messages, never a denylist of the one
  /// post-run message: a reworded agent message then costs a Retry button (unknown outcome), not a
  /// retry that double-applies a push.
  static func replyRefusal(_ error: Error) -> CommandResult {
    switch error {
    case VCSError.lockContention: return refused("The agent is busy; nothing ran. Try again.")
    case VCSError.partialData(let reason) where preRunRefusals.contains(reason):
      return refused(reason)
    case VCSError.partialData: return outcomeUnknown(error)
    default: return neverRan("\(error)")
    }
  }

  /// `vcs.rs`'s request-reassembly refusals, sent before a request is dispatched at all.
  static let preRunRefusals: Set<String> = [
    "truncated request chunk", "too many large VCS requests in flight",
    "VCS request exceeds 16 MiB",
  ]

  /// Refused before it ran, with the workroom intact — see `CommandResult.refused`.
  static func refused(_ reason: String) -> CommandResult {
    CommandResult(stdout: "", stderr: reason, exitCode: CommandResult.refused, timedOut: false)
  }

  /// The command never started. `CommandResult.launchFailed`'s own doc is strict about this value:
  /// it means "nothing ran", which is a different fact from 127 ("env ran and searched PATH"), and
  /// `CLIVCSWriter.classify` checks it before everything else to reach `.launchFailed`.
  ///
  /// This no longer covers a command that merely produced too much output: `vcs.rs`'s `exec` bounds
  /// the two streams to what one reply can carry (`bound_exec_streams`), so an enormous but
  /// successful command is truncated and still reports its real exit code, as native does.
  static func neverRan(_ reason: String) -> CommandResult {
    CommandResult(
      stdout: "", stderr: reason, exitCode: CommandResult.launchFailed, timedOut: false)
  }

  /// The command may or may not have completed; we stopped listening. Carries
  /// `CommandResult.outcomeUnknown` rather than `launchFailed`, because `launchFailed` asserts a
  /// falsehood: a cancelled or disconnected `git push` DID run host-side (there is no cancel message
  /// in the protocol), and telling the user it never launched invites a retry that double-applies it.
  ///
  /// It classifies as `VCSRemoteFailure.outcomeUnknown` / `VCSCommitFailure.outcomeUnknown`, carrying
  /// the underlying error's own description — `HostConnectionError.connectionLost`'s is already
  /// exactly right ("An operation may have completed; refresh before retrying"), and used to be
  /// discarded.
  ///
  /// A sentinel exit code rather than the SIGTERM-shaped result this used to return. That one was
  /// indistinguishable from a genuinely signaled command, so it classified as `.other` — which
  /// `VCSSyncPresentation.retryAction` still offers a Retry for, i.e. the honest message came with
  /// a button that could double-apply the write. `signaled` is now false: its doc makes `exitCode`
  /// the signal number whenever it's true, and -2 isn't one. `timedOut` stays false so this can
  /// never be mistaken for a command that ran and exceeded its own deadline.
  static func outcomeUnknown(_ error: Error) -> CommandResult {
    let reason =
      (error as? LocalizedError)?.errorDescription
      ?? (error is CancellationError ? "The operation was cancelled; it may have completed." : nil)
      ?? "\(error)"
    return CommandResult(
      stdout: "", stderr: reason, exitCode: CommandResult.outcomeUnknown, timedOut: false)
  }
}

extension AgentCommandRunner {
  /// The exec request for `host`. **Nothing from the Mac's environment goes to a remote host.**
  ///
  /// Locally the request carries the app's whole child environment, which the agent adopts in place
  /// of its own stale one (see `StatusCommandRunner.childEnvironment`). A remote host is a different
  /// machine: the Mac's `HOME` and `PATH` name nothing there, and its `SSH_AUTH_SOCK`, git identity
  /// and credential variables are the user's Mac credentials, which must not cross (design doc,
  /// premise 6: agent forwarding was rejected, and git on a remote host authenticates with what the
  /// host has). So a remote request sends only `remoteEnvironment`'s policy pins and asks the agent
  /// to build the rest from the host's own environment (`host_environment` in `vcs.rs`), which also
  /// pins ssh to fail rather than prompt, as `networkEnvironment` does here.
  static func request(
    _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
    stdin: String?, network: Bool, host: HostID, barrierRoot: String? = nil
  ) -> AgentExecRequest {
    let remote = host != .local
    return AgentExecRequest(
      executable: executable, args: args, dir: directory,
      timeoutMs: Int((timeout * 1000).rounded(.up)),
      stdin: stdin,
      env: remote
        ? StatusCommandRunner.remoteEnvironment
        : StatusCommandRunner.childEnvironment(network: network),
      hostEnvironment: remote ? true : nil,
      // Not for a network command (`jj git fetch`/`push`): the barrier is handed to the child, and
      // git's detached helpers (`git maintenance --auto`, a credential cache daemon) would inherit
      // it and hold it long after jj exits. jj's own op log reconciles a snapshot that runs
      // alongside one of those.
      barrierRoot: remote && !network ? barrierRoot : nil)
  }
}

struct AgentExecRequest: Encodable, Sendable {
  var version = 1
  var kind = "exec"
  let executable: String
  let args: [String]
  let dir: String
  let timeoutMs: Int
  var stdin: String?
  var env: [String: String]
  /// Set only for a remote host, and omitted otherwise: an agent that predates the field rejects
  /// any request carrying it (`deny_unknown_fields`), and a local agent may be one.
  var hostEnvironment: Bool?
  /// Remote only, for the same reason: see `AgentCommandRunner.barrierRoot`.
  var barrierRoot: String?
}

struct AgentExecResult: Decodable, Sendable {
  let stdout: String
  let stderr: String
  let exitCode: Int32
  let timedOut: Bool
  let signaled: Bool
}

/// Feeds `CLIVCSWriter.remoteState`'s `currentRef` read through the agent-routed reader that
/// `AgentVCSConnection.writer` already has, instead of shelling a native process for it.
/// `CLIVCSWriter`'s own doc on `makeProvider` says the seam exists "for `currentRef` only"; every
/// other method here enforces that by throwing rather than silently answering something wrong.
struct AgentCurrentRefProvider: LocalVCSProviding {
  let reader: VCSProviding

  func currentRef(root: URL) async throws -> VCSRef { try await reader.currentRef() }

  func log(root: URL, limit: Int) throws -> VCSHistoryPage { throw Self.unused }
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset { throw Self.unused }
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    throw Self.unused
  }
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    throw Self.unused
  }
  func fileContent(root: URL, rev: String, path: String) async throws -> String? {
    throw Self.unused
  }

  private static var unused: VCSError {
    .unsupportedRepo("AgentCurrentRefProvider only answers currentRef")
  }
}
