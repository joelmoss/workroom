import Foundation

/// Forwards `StatusCommandRunning` calls to wr-agent's exec service instead of spawning `git`/`jj`
/// locally. This is the whole seam `AgentVCSConnection.writer` needs: `CLIVCSWriter`'s arg
/// building, stdout/stderr parsing and failure classification are untouched Swift, and see exactly
/// the bytes a host-executed command produced — see `vcs.rs`'s `ExecRequest` doc for the design.
///
/// Never throws: `StatusCommandRunning.run` doesn't, so any transport or decode failure here
/// degrades to `CommandResult.launchFailed`, the same fact `StatusCommandRunner` reports when
/// `Process.run()` itself fails — `CLIVCSWriter.classify`/`.classifyCommit` already handle it.
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
    // Always forwarded, network or not: wr-agent is a long-lived daemon "negotiated with, never
    // replaced" (`LocalAgentVCS`), so its own inherited PATH at spawn time can predate a tool
    // install and is never refreshed — without this, a write that would succeed natively could
    // fail to find `git`/`jj` through an old agent.
    var env = ["PATH": ShellEnvironment.path()]
    if network { env.merge(Self.networkEnv()) { _, replacement in replacement } }
    let request = AgentExecRequest(
      executable: executable, args: args, dir: directory,
      timeoutMs: Int((timeout * 1000).rounded(.up)),
      // Latin-1, not UTF-8: a pathspec payload is NUL-separated and paths are not guaranteed
      // valid UTF-8, and Latin-1 is a total bijection over every byte 0x00-0xFF, so this never
      // fails and `vcs.rs`'s `latin1_bytes` is its exact inverse — see `ExecRequest.stdin`'s doc.
      // Far more compact on the wire than a JSON byte-number array for ordinary text.
      stdin: stdin.map { String(data: $0, encoding: .isoLatin1) ?? "" },
      env: env)
    do {
      // Slack above the command's own timeout: the round trip and the agent's own bookkeeping
      // must not race the command's own timeout into a spurious `.launchFailed`.
      let reply = try await connection.request(request, timeout: timeout + 15)
      let result = try AgentVCSReply<AgentExecResult>.decode(reply)
      return CommandResult(
        stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode,
        timedOut: result.timedOut, signaled: result.signaled)
    } catch {
      return CommandResult(
        stdout: "", stderr: "\(error)", exitCode: CommandResult.launchFailed, timedOut: false)
    }
  }

  /// The same forwarded-auth-key computation `StatusCommandRunner.networkEnvironment` does for a
  /// native network command, as a standalone delta rather than a merged base environment: the
  /// agent process's OWN inherited environment may predate this request and carry a stale or
  /// absent `SSH_AUTH_SOCK` (see `ShellEnvironment`'s whole reason for existing), so the relevant
  /// keys are resolved here, in the caller's process, and sent rather than re-derived agent-side.
  private static func networkEnv() -> [String: String] {
    StatusCommandRunner.networkEnvironment(base: [:], probed: ShellEnvironment.environment())
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
