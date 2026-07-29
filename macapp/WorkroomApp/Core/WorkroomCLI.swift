import Foundation

/// Errors surfaced from running the bundled `workroom` binary.
enum WorkroomCLIError: LocalizedError {
  case binaryMissing
  case timedOut
  case decodeFailed(raw: String)
  /// A structured error from the CLI's --json contract.
  case cli(kind: String, message: String)
  /// Non-zero exit without a decodable JSON error envelope.
  case nonzero(code: Int32, stderr: String)

  var errorDescription: String? {
    switch self {
    case .binaryMissing:
      return "The bundled 'workroom' helper was not found in the app bundle."
    case .timedOut:
      return "The workroom command timed out."
    case .decodeFailed(let raw):
      return "Could not parse the workroom response: \(raw.prefix(200))"
    case .cli(_, let message):
      return message
    case .nonzero(let code, let stderr):
      return stderr.isEmpty ? "workroom exited with code \(code)." : stderr
    }
  }

  /// The stable machine `error.kind` when available (for UI branching).
  var kind: String? {
    if case .cli(let kind, _) = self { return kind }
    return nil
  }
}

private struct CLIResult {
  let stdout: Data
  let stderr: String
  let exitCode: Int32
  /// The timeout fired and we `terminate()`d the child.
  let timedOut: Bool
  /// The child was killed by a signal (`terminationReason == .uncaughtSignal`) rather than
  /// exiting normally — e.g. our own timeout's SIGTERM, or a SIGTERM the system delivers around
  /// sleep/wake. `exitCode` is then the *signal number* (SIGTERM = 15), NOT a CLI exit status.
  let signaled: Bool
}

/// Lock-guarded state shared across the drain/timeout/termination callbacks. A
/// reference type so the @Sendable closures capture an immutable `let` and mutate
/// through it, rather than capturing mutable vars (a data race under Swift 6).
private final class RunState: @unchecked Sendable {
  private let lock = NSLock()
  private var _stdout = Data()
  private var _finished = false
  private var _timedOut = false

  func setStdout(_ d: Data) {
    lock.lock()
    _stdout = d
    lock.unlock()
  }
  func markFinished() {
    lock.lock()
    _finished = true
    lock.unlock()
  }
  func markTimedOut() {
    lock.lock()
    _timedOut = true
    lock.unlock()
  }
  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _finished
  }
  var timedOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _timedOut
  }
  var stdout: Data {
    lock.lock()
    defer { lock.unlock() }
    return _stdout
  }
}

/// Reads stderr incrementally, splitting on newlines so NDJSON log events surface
/// live (rather than only after the process exits). It also keeps the raw bytes for
/// the fallback error path (a non-zero exit without a decodable stdout envelope).
/// `@unchecked Sendable` because the file handle's readability callbacks are
/// serialized, and the lock guards the buffers regardless.
private final class StderrCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var raw = Data()
  private var pending = Data()
  private let onEvent: ((StreamEvent) -> Void)?

  init(onEvent: ((StreamEvent) -> Void)?) { self.onEvent = onEvent }

  func consume(_ data: Data) {
    lock.lock()
    raw.append(data)
    var events: [StreamEvent] = []
    if onEvent != nil {
      pending.append(data)
      while let nl = pending.firstIndex(of: 0x0A) {
        let line = Data(pending[pending.startIndex..<nl])
        pending = Data(pending[(nl + 1)...])
        if let event = try? JSONDecoder().decode(StreamEvent.self, from: line) {
          events.append(event)
        }
      }
    }
    lock.unlock()
    if let onEvent { events.forEach(onEvent) }
  }

  var rawString: String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: raw, encoding: .utf8) ?? ""
  }
}

/// The subset of `WorkroomCLI` that `AppStore` drives, expressed as a protocol so
/// tests can inject a fake (issue #103). `WorkroomCLI` is the production conformer;
/// `bundledBinaryURL` and the process plumbing stay concrete (not used by AppStore).
protocol WorkroomCLIProtocol {
  func list(warnings: String, project: String?) async throws -> ListResponse
  func addProject(_ path: String, create: Bool) async throws -> String
  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((_ name: String, _ path: String, _ hasSetup: Bool) -> Void)?
  ) async throws -> CreateResponse
  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws
  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL]
}

/// Drives the bundled `workroom` binary over its `--json` contract. All work runs
/// off the main thread. Mutations are rare and one-shot; the binary itself forks to
/// git/jj, so the subprocess spawn is negligible.
final class WorkroomCLI: WorkroomCLIProtocol {
  static let shared = WorkroomCLI()
  private init() {}

  // MARK: Public API

  func list(warnings: String = "fast", project: String? = nil) async throws -> ListResponse {
    var args = ["list", "--json", "--warnings=\(warnings)"]
    if let project { args += ["--project", project] }
    let result = try await run(args, timeout: warnings == "full" ? 15 : 5)
    return try decode(ListResponse.self, from: result)
  }

  /// Registers a project. With `create`, the CLI creates and git-initializes the
  /// directory if it does not already exist (issue #103); otherwise the path must
  /// already be a Git/JJ repo. Returns the canonical path the CLI registered (used
  /// to select the project after a reload). The git init + initial commit can take
  /// a moment, so the timeout is generous.
  func addProject(_ path: String, create: Bool) async throws -> String {
    var args = ["add-project", path, "--json"]
    if create { args.append("--create") }
    let result = try await run(args, timeout: 60)
    return try decode(AddProjectResponse.self, from: result).path
  }

  /// Creates a workroom. `onReady(name, path, hasSetup)` fires when the workroom exists
  /// but setup is still running — `hasSetup` reports whether a setup script will run, so
  /// the caller can block on its log. `onLog` streams setup output lines as they arrive.
  @discardableResult
  func create(
    project: String,
    onLog: ((String) -> Void)? = nil,
    onReady: ((_ name: String, _ path: String, _ hasSetup: Bool) -> Void)? = nil
  ) async throws -> CreateResponse {
    // Setup scripts run inside this call, so resolve the user's environment first — freshly, in
    // case a tool was installed or a dotfile edited since launch. Usually already warm: the New
    // Workroom dialog kicks the same single-flighted probe when it opens.
    await ShellEnvironment.refresh()
    let result = try await run(
      ["create", "--json", "--no-editor", "--project", project], timeout: 600, userInitiated: true
    ) { event in
      switch event.type {
      case "log": if let text = event.text { onLog?(text) }
      case "created":
        if let name = event.name, let path = event.path {
          onReady?(name, path, event.setup ?? false)
        }
      default: break
      }
    }
    return try decode(CreateResponse.self, from: result)
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)? = nil) async throws {
    await ShellEnvironment.refresh()  // a teardown script may run inside this call
    let result = try await run(
      ["delete", name, "--json", "--project", project, "--confirm", name], timeout: 600,
      userInitiated: true
    ) { event in
      if event.type == "log", let text = event.text { onLog?(text) }
    }
    try throwIfError(result)
  }

  /// Removes a project from the config. Three modes (mutually exclusive on disk):
  /// - default (config-only): nothing on disk is touched (worktree dirs, branches, files stay).
  /// - `withWorkrooms`: also tears down every registered workroom (hard-deletes worktree dirs +
  ///   files; branches are always kept), streaming teardown output via `onLog`.
  /// - `fromDisk`: runs each workroom's teardown, drops the project from config, and RETURNS the
  ///   directories (project root first, then workrooms) for the app to move to the Bin — the CLI
  ///   never deletes them itself (issue #108). The returned `[URL]` is empty in the other modes.
  ///
  /// `--confirm` echoes the path (the type-to-confirm guard lives in the sheet; this just
  /// satisfies the CLI gate).
  /// Whether a `delete-project` in this mode will run per-workroom teardown scripts. Only the
  /// cascading modes do; plain config-only removal touches nothing on disk, so it must not pay for
  /// a shell probe. Keyed on the same condition as the timeout below, and factored out so the
  /// gating decision is testable without spawning the bundled binary.
  static func deleteProjectRunsScripts(withWorkrooms: Bool, fromDisk: Bool) -> Bool {
    withWorkrooms || fromDisk
  }

  @discardableResult
  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)? = nil
  ) async throws -> [URL] {
    var args = ["delete-project", path, "--json", "--confirm", path]
    if withWorkrooms { args.append("--with-workrooms") }
    if fromDisk { args.append("--from-disk") }
    let runsScripts = Self.deleteProjectRunsScripts(
      withWorkrooms: withWorkrooms, fromDisk: fromDisk)
    if runsScripts { await ShellEnvironment.refresh() }
    let result = try await run(
      args, timeout: runsScripts ? 600 : 15, userInitiated: runsScripts
    ) { event in
      if event.type == "log", let text = event.text { onLog?(text) }
    }
    guard fromDisk else {
      try throwIfError(result)
      return []
    }
    let response = try decode(DeleteProjectResponse.self, from: result)
    return (response.trashPaths ?? []).map { URL(fileURLWithPath: $0) }
  }

  // MARK: Binary location

  /// The bundled `workroom` binary in Contents/Resources (NOT Contents/MacOS — "workroom"
  /// would collide with the "Workroom" app executable on the case-insensitive filesystem),
  /// or a dev fallback next to the running executable. Static so `CommandLineInstaller` can
  /// resolve the same binary when symlinking it into the user's PATH.
  static func bundledBinaryURL() throws -> URL {
    if let url = Bundle.main.url(forResource: "workroom", withExtension: nil) {
      return url
    }
    let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
    let candidate = exeDir.appendingPathComponent("workroom")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
    throw WorkroomCLIError.binaryMissing
  }

  // MARK: Decoding

  private func decode<T: Decodable>(_ type: T.Type, from result: CLIResult) throws -> T {
    try throwIfError(result)
    do {
      return try JSONDecoder().decode(type, from: result.stdout)
    } catch {
      throw WorkroomCLIError.decodeFailed(raw: String(data: result.stdout, encoding: .utf8) ?? "")
    }
  }

  /// Inspects the result and throws if it represents a failure. The CLI writes one
  /// JSON envelope to stdout for both success and error; a non-zero exit means error.
  private func throwIfError(_ result: CLIResult) throws {
    // A child killed by a signal — our timeout's `terminate()` (SIGTERM), or a SIGTERM the
    // system delivers around sleep/wake — reports the *signal number* as `terminationStatus`,
    // not a CLI exit code. Surfacing that as "workroom exited with code 15" was wrong (15 ==
    // SIGTERM); treat it as a timeout so it isn't mistaken for a real CLI failure.
    if result.timedOut || result.signaled { throw WorkroomCLIError.timedOut }
    if result.exitCode == 0 { return }
    if let env = try? JSONDecoder().decode(Envelope.self, from: result.stdout),
      let body = env.error
    {
      throw WorkroomCLIError.cli(kind: body.kind, message: body.message)
    }
    throw WorkroomCLIError.nonzero(code: result.exitCode, stderr: result.stderr)
  }

  // MARK: Process execution

  /// Runs the helper with `args`, draining stdout (read to end for the single JSON
  /// envelope) and stderr (read incrementally so `onLog` fires per NDJSON line as the
  /// script runs) concurrently, and enforcing a timeout. On timeout the process is
  /// terminated then killed.
  ///
  /// `userInitiated` selects the environment the child gets. The commands that run the user's own
  /// setup/teardown scripts get the full probed environment, so those scripts see the shell they
  /// were written against. Everything else (`list`, `add-project`) takes PATH only — a cheap,
  /// frequent read has no reason to carry the user's whole environment.
  private func run(
    _ args: [String], timeout: TimeInterval, userInitiated: Bool = false,
    onEvent: ((StreamEvent) -> Void)? = nil
  ) async throws -> CLIResult {
    let url = try Self.bundledBinaryURL()
    return try await withCheckedThrowingContinuation { continuation in
      let proc = Process()
      proc.executableURL = url
      proc.arguments = args

      var env: [String: String]
      if userInitiated {
        env = ShellEnvironment.environment()
      } else {
        env = ProcessInfo.processInfo.environment
        env["PATH"] = ShellEnvironment.path()
      }
      env["GIT_TERMINAL_PROMPT"] = "0"
      env["GIT_OPTIONAL_LOCKS"] = "0"
      proc.environment = env

      let outPipe = Pipe()
      let errPipe = Pipe()
      proc.standardOutput = outPipe
      proc.standardError = errPipe

      let state = RunState()
      let collector = StderrCollector(onEvent: onEvent)
      let drain = DispatchGroup()

      drain.enter()
      DispatchQueue.global().async {
        state.setStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
        drain.leave()
      }

      drain.enter()
      errPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
          handle.readabilityHandler = nil  // EOF: pipe closed
          drain.leave()
          return
        }
        collector.consume(data)
      }

      let timeoutItem = DispatchWorkItem {
        guard !state.isFinished, proc.isRunning else { return }
        state.markTimedOut()
        proc.terminate()
        // NOTE: full process-group kill (also reaping git/jj grandchildren)
        // would require launching via posix_spawn with setpgid; terminate() +
        // GIT_TERMINAL_PROMPT=0 is sufficient for the MVP.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
          if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

      proc.terminationHandler = { finishedProc in
        state.markFinished()
        timeoutItem.cancel()
        drain.wait()
        continuation.resume(
          returning: CLIResult(
            stdout: state.stdout,
            stderr: collector.rawString,
            exitCode: finishedProc.terminationStatus,
            timedOut: state.timedOut,
            signaled: finishedProc.terminationReason == .uncaughtSignal
          ))
      }

      do {
        try proc.run()
      } catch {
        errPipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
