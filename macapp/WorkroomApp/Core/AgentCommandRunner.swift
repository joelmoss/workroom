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
    let request = AgentExecRequest(
      executable: executable, args: args, dir: directory,
      timeoutMs: Int((timeout * 1000).rounded(.up)),
      stdin: payload,
      env: StatusCommandRunner.childEnvironment(network: network))
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
      reply = try await connection.request(request, timeout: timeout + 15)
    } catch let error as VCSError {
      // Raised before anything left this process — today only the 1 MiB single-envelope request
      // ceiling. Nothing ran.
      return Self.neverRan("\(error)")
    } catch HostConnectionError.notDispatched {
      // Refused locally with nothing written to the socket (closed connection, exhausted stream
      // counter, full request pool). Definitively never ran.
      return Self.neverRan(HostConnectionError.notDispatched.localizedDescription)
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
      // A reply ARRIVED carrying an error. wr-agent answers one only for a request it refused
      // before spawning (bad version, unusable `dir`, non-Latin-1 stdin) or for a reply too large
      // to send — see `neverRan`'s caveat on that last case.
      return Self.neverRan("\(error)")
    }
  }

  /// The command never started. `CommandResult.launchFailed`'s own doc is strict about this value:
  /// it means "nothing ran", which is a different fact from 127 ("env ran and searched PATH"), and
  /// `CLIVCSWriter.classify` checks it before everything else to reach `.launchFailed`.
  ///
  /// Caveat: `vcs.rs`'s `send` replaces an over-16-MiB reply with a `PartialData` error, so a
  /// command that ran and produced enormous output lands here too. That is the one remaining
  /// misreport in this direction and is tracked separately from this fix.
  static func neverRan(_ reason: String) -> CommandResult {
    CommandResult(
      stdout: "", stderr: reason, exitCode: CommandResult.launchFailed, timedOut: false)
  }

  /// The command may or may not have completed; we stopped listening. Reported as a SIGTERM-signaled
  /// result rather than `launchFailed`, because `launchFailed` asserts a falsehood: a cancelled or
  /// disconnected `git push` DID run host-side (there is no cancel message in the protocol), and
  /// telling the user it never launched invites a retry that double-applies it.
  ///
  /// It classifies as `.other(reason)`, carrying the underlying error's own description —
  /// `HostConnectionError.connectionLost`'s is already exactly right ("An operation may have
  /// completed; refresh before retrying"), and used to be discarded. Not the `"\(tool) was
  /// interrupted"` branch: that one requires EMPTY stderr, and the message is worth more here.
  /// `signaled: true` is therefore descriptive rather than load-bearing, and `timedOut` stays false
  /// so this can never be mistaken for a command that ran and exceeded its own deadline.
  ///
  /// KNOWN GAP: `.other` is retryable (`VCSSyncPresentation.retryAction`), so the user is still
  /// offered a Retry for an operation that may already have landed. Telling the truth in the
  /// message is strictly better than the old `launchFailed` ("never ran"), but suppressing the
  /// button needs its own `VCSRemoteFailure`/`VCSCommitFailure` case — that switch is exhaustive on
  /// purpose, and adding a case is a user-visible taxonomy change, not a drive-by fix.
  static func outcomeUnknown(_ error: Error) -> CommandResult {
    let reason =
      (error as? LocalizedError)?.errorDescription
      ?? (error is CancellationError ? "The operation was cancelled; it may have completed." : nil)
      ?? "\(error)"
    return CommandResult(
      stdout: "", stderr: reason, exitCode: 15, timedOut: false, signaled: true)
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
