import AgentConnection
import Foundation
import HostDrivers
import WorkroomDomain
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

  // MARK: Included files

  /// Copies the root's included files (#367) into the checkout at `path` on `host`: `archive`
  /// writes them to a tar at the URL it is given (the CLI's `include-archive`), and the file is
  /// streamed from disk into tar on the host, which keeps each file's mode (`-p`, as the host's
  /// user is rarely root) and any file the checkout already has (`-k`). It never throws: a create
  /// is never undone for a missing `.env`, so every failure is a warning saying why.
  static func copyIncluded(
    into path: String, on host: HostID, driver: any HostDriver,
    archive: @Sendable (URL) async throws -> IncludeArchive
  ) async -> IncludeResult {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-include-\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: file) }
    let made: IncludeArchive
    do { made = try await archive(file) } catch {
      return .warning(
        "Could not archive the included files: \(error.localizedDescription)", log: [])
    }
    let unread =
      made.warnings.isEmpty
      ? nil
      : "Could not copy \(files(made.warnings.count)): \(made.warnings.joined(separator: "; "))"
    // As the CLI's local step says it (`workroom.SkippedSymlink`). The skip reason names them too: a
    // skipped row's log can't be opened.
    let symlinks = made.skipped ?? []
    let skipped = symlinks.map { "Skipped \($0): it's a symlink" }
    guard !made.paths.isEmpty else {
      let reason =
        symlinks.isEmpty
        ? "No matching files" : "Only symlinks matched: \(symlinks.joined(separator: ", "))"
      return unread.map { .warning($0, log: skipped) } ?? .skipped(reason, log: skipped)
    }
    let command =
      "command -v tar >/dev/null 2>&1 || { echo 'tar is not installed on the host'; exit 127; }; "
      + "tar -x -k -p -f - -C \(PosixShell.quoted(path))"
    do {
      let stream = try await driver.exec(command, on: host)
      let status: Int32
      let output: String
      do {
        (status, output) = try await stream.communicate(contentsOf: file, timeout: 120)
      } catch {
        stream.end()
        throw error
      }
      guard status == 0 else {
        let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .warning("Could not copy the included files to the host: \(said)", log: [])
      }
    } catch {
      return .warning(
        "Could not copy the included files to the host: \(error.localizedDescription)", log: [])
    }
    let size = ByteCountFormatter.string(fromByteCount: made.bytes, countStyle: .file)
    let log =
      skipped + made.paths.map { "Copied \($0)" } + ["Copied \(files(made.paths.count)) (\(size))"]
    return unread.map { .warning($0, log: log) } ?? .copied(log: log)
  }

  private static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

  // MARK: Workroom scripts

  /// A workroom's two scripts, by the word the CLI uses for each (`internal/script`).
  enum Script: String, Sendable {
    case setup, teardown
    var fileName: String { "workroom_\(rawValue)" }
  }

  /// How running a workroom's script on its host ended.
  enum ScriptRun: Equatable, Sendable {
    /// Neither the checkout nor the root has the script.
    case absent
    case passed
    /// Worded as the CLI words a local script's failure: "setup script failed: <why>".
    case failed(String)
    /// Not run: this Mac has not approved the bytes that would have run (#363).
    case notTrusted(ScriptTrust)
  }

  /// Judges a script's bytes against this Mac's approvals: the CLI's `trust status --stdin`.
  typealias ScriptJudge = @Sendable (Data) async throws -> ScriptTrust

  /// How long a script may run, as the app gives a local one through the CLI (`WorkroomCLI.create`).
  static let scriptTimeout: TimeInterval = 600

  /// `WORKROOM_HOST` for a host on `key` (`docs/designs/scripts-on-every-workroom.md`).
  static func hostKind(_ key: RemoteHosts.DriverKey) -> String {
    switch key {
    case .container(let runtime, _): runtime == .docker ? "docker" : "apple"
    case .boxd: "boxd"
    case .exeDev: "exedev"
    }
  }

  /// Runs `script` for workroom `name` in its checkout at `path` on `host`, through the host agent's
  /// `run-script`: `onStart` once a script is found, then `onLine` each line it prints as it prints
  /// it. The checkout's own copy is
  /// run; with none, the root's (`rootScript`, on this Mac) is copied in with its mode and run, as
  /// the CLI falls back to the root's copy locally (`findScript`). Either way the bytes that would
  /// run go to `judge` first, and ones this Mac has not approved never run (#363). It never throws.
  static func runScript(
    _ script: Script, workroom name: String, at path: String, hostKind: String,
    rootScript: URL?, agentBinary: String, on host: HostID, driver: any HostDriver,
    judge: ScriptJudge,
    onStart: @Sendable () -> Void = {}, onLine: @escaping @Sendable (String) -> Void,
    timeout: TimeInterval = scriptTimeout, slack: TimeInterval = 30
  ) async -> ScriptRun {
    let q = PosixShell.quoted
    let failed = { (why: String) in ScriptRun.failed("\(script.rawValue) script failed: \(why)") }
    var scriptPath = path + "/scripts/" + script.fileName
    do {
      let found = try await driver.exec("test -e \(q(scriptPath))", on: host)
        .communicate(nil, timeout: 30)
      // `test -e` says 1 for a missing file. Anything else is the host not answering (ssh's 255),
      // which must never pass for "no script": it would skip a teardown and destroy the host.
      switch found.status {
      case 0:
        let judged = try await judge(try await read(scriptPath, on: host, driver: driver))
        guard judged.trusted else { return .notTrusted(judged) }
      case 1:
        guard let rootScript, FileManager.default.fileExists(atPath: rootScript.path) else {
          return .absent
        }
        // Judged as read here, and those same bytes are what goes up.
        let text = try Data(contentsOf: rootScript)
        let judged = try await judge(text)
        guard judged.trusted else { return .notTrusted(judged) }
        scriptPath = path + "/.git/workroom/" + script.fileName
        try await upload(text, from: rootScript, to: scriptPath, on: host, driver: driver)
      default:
        let said = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return failed("couldn't check the host for \(scriptPath) (exit \(found.status)): \(said)")
      }
      let command =
        "\(q(agentBinary)) run-script --dir \(q(path)) --timeout \(Int(timeout))"
        + " --env \(q("WORKROOM_NAME=\(name)")) --env \(q("WORKROOM_PATH=\(path)"))"
        + " --env \(q("WORKROOM_HOST=\(hostKind)")) -- \(q(scriptPath))"
      onStart()
      let said = AgentSaid()
      let lines = LineSplitter { line in
        said.note(line)
        onLine(line)
      }
      // Its last line too when the link drops: often the script's own error.
      defer { lines.finish() }
      let stream = try await driver.exec(command, on: host)
      let status: Int32
      do {
        // The agent's own wall clock ends the script; these bounds leave room for the connect, the
        // probe and the kill grace before its report. Silence is a dead link. The whole exchange is
        // bounded too, as the local CLI call is: a process the script left in the background holds
        // its output open past the script, and one that keeps printing is never silent.
        (status, _) = try await withTimeout(seconds: timeout + slack) {
          try await stream.communicate(
            nil, timeout: timeout + slack, onOutput: { data, stderr in lines.add(data, stderr) })
        }
      } catch is VCSTimeoutError {
        stream.end()
        return failed(
          "\(scriptPath) still held its output open after \(Int(timeout)) s"
            + " (a process it started in the background, perhaps)")
      } catch {
        stream.end()
        throw error
      }
      // 124 and 126 are the agent's only when it said so: a script can exit with either itself
      // (`timeout 30 ...` does). ssh's own 255 can't be told from a script's, so it says both.
      switch status {
      case 0: return .passed
      case 124 where said.timedOut:
        return failed("\(scriptPath) timed out after \(Int(timeout)) s")
      case 126 where said.notStarted: return failed("\(scriptPath) could not be started")
      case 255:
        return failed(
          "\(scriptPath) returned exit code 255, or the connection to the host dropped while it ran"
        )
      default: return failed("\(scriptPath) returned a non-zero exit code")
      }
    } catch {
      return failed(error.localizedDescription)
    }
  }

  /// A file on `host`, byte for byte.
  private static func read(
    _ path: String, on host: HostID, driver: any HostDriver
  ) async throws -> Data {
    let bytes = DataBox()
    let stream = try await driver.exec("cat \(PosixShell.quoted(path))", on: host)
    let result: (status: Int32, output: String)
    do {
      result = try await stream.communicate(
        nil, timeout: 30, onOutput: { data, stderr in if !stderr { bytes.append(data) } })
    } catch {
      stream.end()
      throw error
    }
    guard result.status == 0 else {
      throw HostDriverError.provisioning("reading \(path) on the host failed: \(result.output)")
    }
    return bytes.data
  }

  /// Bytes a stream's output callback collects.
  private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    var data: Data { lock.withLock { collected } }
    func append(_ more: Data) { lock.withLock { collected.append(more) } }
  }

  /// Copies `text`, read from `file`, to `destination` on `host`, keeping the file's mode: a root
  /// script without its execute bit fails to start there, as it does locally.
  private static func upload(
    _ text: Data, from file: URL, to destination: String, on host: HostID, driver: any HostDriver
  ) async throws {
    let q = PosixShell.quoted
    let mode =
      (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
      as? NSNumber)?.intValue ?? 0o644
    let directory = (destination as NSString).deletingLastPathComponent
    let command =
      "mkdir -p \(q(directory)) && cat > \(q(destination))"
      + " && chmod \(String(mode, radix: 8)) \(q(destination))"
    let stream = try await driver.exec(command, on: host)
    let result: (status: Int32, output: String)
    do {
      result = try await stream.communicate(text, timeout: 30)
    } catch {
      stream.end()
      throw error
    }
    guard result.status == 0 else {
      throw HostDriverError.provisioning(
        "copying \(file.lastPathComponent) to the host failed: \(result.output)")
    }
  }

  /// What `run-script` itself reported about the script: its own stderr lines, which name it.
  private final class AgentSaid: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOutSeen = false
    private var notStartedSeen = false
    var timedOut: Bool { lock.withLock { timedOutSeen } }
    var notStarted: Bool { lock.withLock { notStartedSeen } }

    func note(_ line: String) {
      guard line.hasPrefix("wr-agent run-script: ") else { return }
      lock.withLock {
        if line.contains(" timed out after ") { timedOutSeen = true }
        if line.contains(" could not be started: ") { notStartedSeen = true }
      }
    }
  }

  /// Splits a stream's pieces into lines, stdout's and stderr's apart, since a piece can end
  /// mid-line and the two interleave.
  private final class LineSplitter: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pending: [Bool: Data] = [:]

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func add(_ data: Data, _ stderr: Bool) {
      let lines: [Data] = lock.withLock {
        var buffer = pending[stderr, default: Data()] + data
        var complete: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
          complete.append(buffer[buffer.startIndex..<newline])
          buffer = buffer[buffer.index(after: newline)...]
        }
        pending[stderr] = Data(buffer)
        return complete
      }
      for line in lines { onLine(String(decoding: line, as: UTF8.self)) }
    }

    func finish() {
      let rest = lock.withLock {
        defer { pending = [:] }
        return pending.values.filter { !$0.isEmpty }
      }
      for line in rest { onLine(String(decoding: line, as: UTF8.self)) }
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

/// What the CLI's `include-archive` wrote (#367): the archived paths, their total size, each file it
/// couldn't read, as "path: reason", and the symlinks it matched but never copies.
struct IncludeArchive: Decodable, Equatable {
  var paths: [String]
  var bytes: Int64
  var warnings: [String]
  var skipped: [String]?
}

/// How copying the root's included files into a workroom ended (#367), with its log.
enum IncludeResult: Equatable {
  case copied(log: [String])
  case skipped(String, log: [String])
  case warning(String, log: [String])
}
