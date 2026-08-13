import Foundation

/// Which agent CLI backs a diagnosis (issue #49). Capabilities differ per decision X1:
/// - `.claude` can run a **true no-tools** inline diagnosis (`--allowed-tools none --permission-mode
///   plan`, verified: returns a JSON envelope with no tool calls), so it backs the inline/automatic
///   path AND the Investigate hand-off.
/// - `.codex exec` has no zero-tools mode (`-s read-only` still runs read-only commands), so it is
///   **Investigate-only** — never the silent inline path. (Investigate is wired in the banner, T8.)
enum AgentBackend: String, Sendable, CaseIterable {
  case claude
  case codex

  /// The executable name, resolved on the augmented PATH by `StatusCommandRunner` via `/usr/bin/env`.
  var executable: String { rawValue }

  /// How the agent is named in the UI ("Resume Claude…"). Separate from `executable` so a rename of
  /// either cannot silently change the other.
  var displayName: String {
    switch self {
    case .claude: return "Claude"
    case .codex: return "Codex"
    }
  }

  /// Only claude can run the inline diagnosis with no tool execution (X1).
  var supportsInlineDiagnosis: Bool { self == .claude }

  /// The inline-diagnosis backend among those installed: claude or nothing (X1). When nil, the UI
  /// offers Investigate-with-codex only rather than a silent inline run.
  static func inlineBackend(installed: Set<AgentBackend>) -> AgentBackend? {
    installed.contains(.claude) ? .claude : nil
  }

  /// Preferred backend for the Investigate hand-off: claude, else codex.
  static func preferred(installed: Set<AgentBackend>) -> AgentBackend? {
    if installed.contains(.claude) { return .claude }
    if installed.contains(.codex) { return .codex }
    return nil
  }
}

/// A resolved CLI command: the executable plus its argv (the prompt is the trailing positional).
struct AgentInvocation: Equatable, Sendable {
  let executable: String
  let arguments: [String]
}

/// Pure argv construction (unit-tested; no process spawning).
enum AgentInvocationBuilder {
  /// The inline, no-tools claude diagnosis (issue #49, X1). Verified against the installed claude:
  /// - `--print --output-format json` → a single JSON result envelope (the `result` field is the
  ///   text; parsed in T5),
  /// - `--permission-mode plan` + `--allowed-tools none` → no edits, no execution, no tool calls
  ///   (the allowlist is exclusive, so the bogus name denies every real tool),
  /// - `--no-session-persistence` → the prompt/output don't land in claude's session history.
  /// The working directory is supplied to the executor (`run(in:)`), not as a claude flag.
  /// `systemPrompt`, when given, replaces claude's heavy default system prompt — it both shapes the
  /// output and cuts token cost (task #15). `model`, when given, pins a cheap/fast model so the
  /// diagnosis doesn't run on the user's (often Opus) default. The prompt stays the trailing positional.
  static func claudeInline(systemPrompt: String? = nil, model: String? = nil, prompt: String)
    -> AgentInvocation
  {
    var arguments = [
      "--print",
      "--output-format", "json",
      "--permission-mode", "plan",
      "--allowed-tools", "none",
      "--no-session-persistence",
    ]
    if let model, !model.isEmpty {
      arguments.append(contentsOf: ["--model", model])
    }
    if let systemPrompt, !systemPrompt.isEmpty {
      arguments.append(contentsOf: ["--system-prompt", systemPrompt])
    }
    arguments.append(prompt)
    return AgentInvocation(executable: AgentBackend.claude.executable, arguments: arguments)
  }
}

/// The raw outcome of an inline diagnosis run, before the model's text is parsed into an
/// `AgentDiagnosis` (T5). Distinct cases so the banner can show actionable states (X1/A2).
enum AgentRunOutcome: Sendable, Equatable {
  /// Process succeeded; `stdout` is the raw JSON envelope (claude `--output-format json`).
  case success(stdout: String)
  /// `/usr/bin/env` exit 127 — the agent CLI isn't on PATH.
  case cliNotFound
  /// The process never launched at all (e.g. the workroom's cwd vanished) — `CommandResult
  /// .launchFailed`, not a real exit code. Distinct from `cliNotFound`: that means env ran and
  /// searched PATH, a different fact from "nothing ran."
  case launchFailed
  /// Non-zero exit whose output looks like an auth/login failure.
  case notAuthenticated
  /// The timeout fired.
  case timedOut
  /// Killed by a signal (our own cancellation SIGKILL, an OS kill under memory pressure, a crash) —
  /// NOT a timeout, which is checked first and reported as `.timedOut` instead (a timeout's
  /// `terminate()` call also sets `signaled`, so order matters). `exitCode` on a signalled result is
  /// the SIGNAL NUMBER, not a real CLI exit status, so it must never reach `.failed(exitCode:)` — a
  /// killed `claude` showing "exit 9" is exactly the nonsense class the gh-flap fix ended elsewhere.
  case interrupted
  /// Succeeded but produced no usable text.
  case emptyOutput
  /// Any other non-zero exit (stderr tail kept for the banner / logs).
  case failed(exitCode: Int32, stderr: String)
}

/// A seam (mirrors `StatusCommandRunning`) so the inline-agent manager (T6) is unit-testable with a
/// fake runner — no real `claude`/`codex` process.
protocol AgentRunning: Sendable {
  /// Run an inline, no-tools diagnosis (claude only, X1). `systemPrompt` replaces claude's default
  /// to shape output + cut cost; `model` pins a cheap/fast model (task #15). `cwd` is where claude
  /// runs — callers should pass a NEUTRAL dir (not the project) so `CLAUDE.md` doesn't auto-load:
  /// the inline path has no tools and gets all context from `prompt`, so the real failure cwd
  /// belongs in the prompt text, not here.
  func diagnoseInline(
    systemPrompt: String?, model: String?, prompt: String, cwd: String, timeout: TimeInterval
  ) async -> AgentRunOutcome
}

/// Default `AgentRunning`: builds the claude inline argv and runs it through the existing
/// `StatusCommandRunning` executor (CQ1 — no duplicated process/drain/timeout/cancel code). The
/// executor's process-group termination (X2, T3) reaps any agent child processes on cancel/timeout.
struct AgentRunner: AgentRunning {
  let executor: StatusCommandRunning

  init(executor: StatusCommandRunning = StatusCommandRunner()) {
    self.executor = executor
  }

  func diagnoseInline(
    systemPrompt: String? = nil, model: String? = nil, prompt: String, cwd: String,
    timeout: TimeInterval = 60
  ) async -> AgentRunOutcome {
    let invocation = AgentInvocationBuilder.claudeInline(
      systemPrompt: systemPrompt, model: model, prompt: prompt)
    let result = await executor.run(
      invocation.executable, invocation.arguments, in: cwd, timeout: timeout)
    return Self.classify(result)
  }

  /// Map a raw process result to a diagnosis outcome. Pure + unit-tested. stdout carries the model's
  /// JSON; stderr is treated only as diagnostics (CLI warnings must not be mistaken for the result).
  static func classify(_ result: CommandResult) -> AgentRunOutcome {
    if result.timedOut { return .timedOut }
    if result.signaled { return .interrupted }
    if result.exitCode == CommandResult.launchFailed { return .launchFailed }
    if result.exitCode == CommandResult.commandNotFound { return .cliNotFound }
    if result.exitCode != 0 {
      if isAuthFailure(result.stderr + "\n" + result.stdout) {
        return .notAuthenticated
      }
      return .failed(exitCode: result.exitCode, stderr: String(result.stderr.suffix(2000)))
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .emptyOutput
      : .success(stdout: result.stdout)
  }

  /// Heuristic auth/login-failure detection over the agent CLI's combined output.
  static func isAuthFailure(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return [
      "not authenticated", "unauthorized", "authentication", "invalid api key", "invalid_api_key",
      "please log in", "please login", "run `claude login`", "run claude login", "no api key",
    ].contains { lowered.contains($0) }
  }
}
