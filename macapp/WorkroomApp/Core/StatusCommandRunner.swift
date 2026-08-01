import Foundation

/// The full result of a short status command: stdout, stderr, exit code, and whether the
/// timeout fired. Unlike `CommandRunning` (which collapses everything to `String?`), this
/// keeps the exit code and timeout flag so `WorkroomStatusResolver` can tell "not a repo"
/// (git exit 128) from "gh not installed" (exit 127) from "timed out" from "clean" — the
/// distinctions the status UI's unknown/stale/absent matrix depends on.
struct CommandResult: Sendable, Equatable {
  let stdout: String
  let stderr: String
  let exitCode: Int32
  let timedOut: Bool

  /// `/usr/bin/env` exits 127 when the command (git/jj/gh) isn't on PATH.
  static let commandNotFound: Int32 = 127
  /// git exits 128 for "not a git repository" and similar fatal usage errors.
  static let gitFatal: Int32 = 128

  var ok: Bool { exitCode == 0 && !timedOut }
}

/// A seam (mirrors `CommandRunning`) so `WorkroomStatusResolver` is unit-testable without
/// spawning real git/jj/gh — but typed (`CommandResult`, not `String?`).
protocol StatusCommandRunning: Sendable {
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult

  /// Like `run`, but for a command that will touch the **network** and therefore may want to
  /// authenticate — `git fetch/push/pull`, `jj git fetch/push`.
  ///
  /// A read like `git status` can never prompt, so it wants the minimal, predictable environment
  /// `run` gives it. A push can: it may need an SSH agent the GUI environment can't see, and it may
  /// try to ask for a passphrase or a host-key confirmation with nowhere to ask. See
  /// `StatusCommandRunner.networkEnvironment` for what changes and why.
  func runNetwork(
    _ executable: String, _ args: [String], in directory: String,
    timeout: TimeInterval
  ) async -> CommandResult
}

extension StatusCommandRunning {
  /// Test doubles never reach a real network, so the distinction is meaningless for them — forward
  /// and let them stay two-line stubs. Only `StatusCommandRunner` overrides this.
  func runNetwork(
    _ executable: String, _ args: [String], in directory: String,
    timeout: TimeInterval
  ) async -> CommandResult {
    await run(executable, args, in: directory, timeout: timeout)
  }
}

/// Default `StatusCommandRunning`: spawns via `/usr/bin/env` (augmented PATH finds Homebrew
/// git/jj/gh), git locks/prompt disabled, and enforces `timeout` by terminating the process.
///
/// Unlike `ProcessCommandRunner` (which reads stdout *in* the termination handler — safe only
/// because a branch name is tiny), this drains stdout AND stderr **concurrently on background
/// queues while the process runs** (the `WorkroomCLI` pattern). Status output can be large (a
/// repo with thousands of changed files, a big `gh` JSON payload); reading post-termination
/// would let the OS pipe buffer fill, block the child on write, and deadlock until the timeout.
/// Retained output is capped (`maxBytes`) so a pathological repo can't blow memory — the reader
/// keeps draining past the cap (so the child never blocks) but discards the overflow.
struct StatusCommandRunner: StatusCommandRunning, Sendable {
  var maxBytes: Int = 4 * 1024 * 1024

  /// Auth-relevant variables forwarded from the user's shell for network commands only.
  ///
  /// A Finder- or Dock-launched `.app` inherits launchd's environment, not the user's shell, and this
  /// runner otherwise overrides only PATH. That was harmless while it ran `git status` and `gh` (which
  /// carries its own token), but it breaks authentication outright: `SSH_AUTH_SOCK` is how a process
  /// finds an SSH agent, and for anyone using 1Password's agent, gpg-agent, or a custom socket it is
  /// set in `.zshrc` and nowhere else. Without it their `git push` cannot reach the agent, and the
  /// error would tell them to configure a credential helper they already have.
  ///
  /// Deliberately an allowlist, not the whole probed environment (which `ShellEnvironment.environment()`
  /// hands to setup/teardown scripts): network ops now run automatically on inspector focus, and a
  /// wholesale transplant would put every variable in the user's shell — secrets included — into a
  /// child on an automatic path.
  static let forwardedAuthKeys = [
    "SSH_AUTH_SOCK", "SSH_AGENT_PID", "GIT_SSH_COMMAND", "GIT_CONFIG_GLOBAL", "XDG_CONFIG_HOME",
  ]

  /// Variables removed for network commands so `ssh` cannot find a graphical prompt helper.
  static let networkClearedKeys = ["SSH_ASKPASS", "DISPLAY"]

  /// The environment for a network command: `base` plus forwarded auth vars, with ssh pinned to
  /// fail fast instead of asking a human.
  ///
  /// `GIT_TERMINAL_PROMPT=0` (set by `run`) governs **git's own** credential prompts and says nothing
  /// to `ssh`. So an SSH remote with a passphrase-protected key and no agent, or a host whose key
  /// isn't in `known_hosts`, would otherwise stall until the timeout — 120s for fetch/push, 300s for
  /// pull. `BatchMode=yes` turns both into an immediate, classifiable failure, and
  /// `SSH_ASKPASS_REQUIRE=never` stops ssh reaching for a GUI helper (OpenSSH 8.4+; macOS ships 10.x).
  ///
  /// A user's own `GIT_SSH_COMMAND` is preserved and appended to rather than replaced — it commonly
  /// carries `-i <key>` or a proxy command that must survive.
  ///
  /// Pure and static so the whole policy is unit-testable without spawning anything.
  static func networkEnvironment(base: [String: String], probed: [String: String])
    -> [String: String]
  {
    var env = base
    for key in forwardedAuthKeys {
      // The inherited environment wins: if it's already set, the app was launched from a shell that
      // had it, and that value is at least as current as the probe's.
      if env[key] == nil, let value = probed[key], !value.isEmpty { env[key] = value }
    }
    for key in networkClearedKeys { env.removeValue(forKey: key) }
    let ssh = env["GIT_SSH_COMMAND"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    env["GIT_SSH_COMMAND"] = (ssh?.isEmpty == false ? ssh! : "ssh") + " -o BatchMode=yes"
    env["SSH_ASKPASS_REQUIRE"] = "never"
    return env
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    await run(executable, args, in: directory, timeout: timeout, network: false)
  }

  func runNetwork(
    _ executable: String, _ args: [String], in directory: String,
    timeout: TimeInterval
  ) async -> CommandResult {
    await run(executable, args, in: directory, timeout: timeout, network: true)
  }

  private func run(
    _ executable: String, _ args: [String], in directory: String,
    timeout: TimeInterval, network: Bool
  ) async -> CommandResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [executable] + args
    proc.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ShellEnvironment.path()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    // A workroom can be a clone of an *untrusted* repo, and the status sweep runs git automatically
    // on load/focus/selection. `git diff` would otherwise run an inherited external-diff program;
    // unset it so only the explicit `--no-ext-diff` flag (see WorkroomStatusResolver) governs diffs.
    env.removeValue(forKey: "GIT_EXTERNAL_DIFF")
    if network { env = Self.networkEnvironment(base: env, probed: ShellEnvironment.environment()) }
    proc.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    // Never let a child read the app's stdin. Unset, it INHERITS ours — which under `make app-run`
    // (or `Scripts/run.sh`) is a real terminal, so a prompting `ssh` or `git` could sit waiting on a
    // tty that the same binary won't have when launched from Finder. Pinning it makes the two launch
    // contexts behave identically and turns any prompt into an immediate EOF. `ShellEnvironment.probe`
    // already does this for the same reason.
    proc.standardInput = FileHandle.nullDevice

    // `proc` is shared with the @Sendable cancellation handler; box it so the non-Sendable Process
    // can cross that boundary (mirrors the @unchecked Sendable helpers below).
    let box = ProcessBox(proc)

    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
        let state = StatusRunState()
        let drain = DispatchGroup()
        let cap = maxBytes
        let gate = CommandResumeGate(continuation)

        // Concurrent drains (the deadlock fix). availableData blocks until data or EOF;
        // started before run() so we never miss a fast child's output, harmless until it runs.
        drain.enter()
        DispatchQueue.global().async {
          state.setStdout(Self.readCapped(outPipe.fileHandleForReading, cap: cap))
          drain.leave()
        }
        drain.enter()
        DispatchQueue.global().async {
          state.setStderr(Self.readCapped(errPipe.fileHandleForReading, cap: cap))
          drain.leave()
        }

        let timeoutItem = DispatchWorkItem {
          state.markTimedOut()
          if proc.isRunning { proc.terminate() }  // SIGTERM
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        // Hard-kill fallback: a wedged child (e.g. `gh` blocked on a dead socket) can ignore SIGTERM,
        // so `terminationHandler` — the only place the continuation resumes — would never fire and the
        // awaiting Task would hang forever, defeating the timeout. SIGKILL is uncatchable, guaranteeing
        // the process exits and we resume. A 2s grace after SIGTERM lets well-behaved children exit.
        let killItem = DispatchWorkItem {
          if proc.isRunning { ProcessTree.killTree(proc.processIdentifier) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: killItem)

        proc.terminationHandler = { finished in
          timeoutItem.cancel()
          killItem.cancel()
          // The process has exited, so its own pipe write ends are closed and EOF is imminent. But a
          // grandchild that inherited the pipe (a helper spawned by gh/git) can hold the write end
          // open after the parent dies — an unbounded `drain.wait()` would then never return and the
          // continuation would never resume, wedging this probe slot forever. Bound the wait and
          // resume with whatever drained; a still-blocked reader writes to `state` we no longer read
          // (safe — lock-guarded) and exits when the grandchild finally closes the pipe.
          _ = drain.wait(timeout: .now() + 2)
          gate.resume(
            CommandResult(
              stdout: String(decoding: state.stdout, as: UTF8.self),
              stderr: String(decoding: state.stderr, as: UTF8.self),
              exitCode: finished.terminationStatus,
              timedOut: state.timedOut))
        }

        do {
          try proc.run()
        } catch {
          // Launch failed (e.g. cwd vanished). Close the write ends so the drain readers hit
          // EOF instead of blocking forever, then resolve as command-not-found.
          timeoutItem.cancel()
          killItem.cancel()
          try? outPipe.fileHandleForWriting.close()
          try? errPipe.fileHandleForWriting.close()
          gate.resume(
            CommandResult(
              stdout: "", stderr: "\(error)", exitCode: CommandResult.commandNotFound,
              timedOut: false))
        }
      }
    } onCancel: {
      // The awaiting Task was cancelled (e.g. a superseded sweep, or rapid selection cycling). Kill
      // the in-flight child so a cancelled probe doesn't leave a git/jj/gh process running to its own
      // timeout. terminationHandler then resumes the continuation with the abandoned result, which
      // the cancelled caller discards. SIGKILL (not SIGTERM) so a wedged child dies promptly.
      box.terminate()
    }
  }

  /// Drain a pipe to EOF, retaining at most `cap` bytes but reading the rest so the child
  /// never blocks on a full pipe buffer.
  private static func readCapped(_ handle: FileHandle, cap: Int) -> Data {
    var collected = Data()
    while true {
      // `read(upToCount:)` (throwing) instead of `availableData`: the latter raises an
      // *Objective-C* `NSFileHandleOperationException` on a read error (common right after the
      // child is `terminate()`d out from under the open read end), which Swift can't catch — it
      // crashes the app. Treat a read error as EOF and return what we have.
      let chunk: Data
      do { chunk = try handle.read(upToCount: 1 << 16) ?? Data() } catch { break }
      if chunk.isEmpty { break }  // EOF: pipe closed
      if collected.count < cap {
        collected.append(chunk.prefix(cap - collected.count))
      }
    }
    return collected
  }
}

/// Boxes a non-Sendable `Process` so it can be captured by the @Sendable task-cancellation handler.
private final class ProcessBox: @unchecked Sendable {
  private let process: Process
  init(_ process: Process) { self.process = process }
  /// SIGKILL the child (and any descendants it spawned) if still running — the cancellation path
  /// abandons the result, so kill promptly rather than wait out a SIGTERM grace.
  ///
  /// Hopped to a global queue because `withTaskCancellationHandler`'s `onCancel` runs **synchronously
  /// on whichever thread called `cancel()`**, and the hottest canceller is the main thread:
  /// `selectedTargetID.didSet` → `scheduleSelectedStatusRefresh` → `selectionStatusTask?.cancel()`
  /// supersedes the in-flight probe on *every* selection change. `ProcessTree.killTree` walks the tree
  /// by spawning a `pgrep -P` per node and blocking on `waitUntilExit` for each, so inline it stalled
  /// the main thread for the length of that walk while switching workroom tabs — and a blocking wait
  /// spins a nested run loop, which drains queued main-queue blocks at a point SwiftUI hasn't committed
  /// its update yet (that reordering is what surfaced the split-member selection snap-back). Deferring
  /// the kill costs nothing: the continuation resumes from `terminationHandler`, never from here, and
  /// the cancelled caller discards the result. Matches `killItem`, which already kills off a global
  /// queue.
  func terminate() {
    let process = self.process
    DispatchQueue.global(qos: .userInitiated).async {
      if process.isRunning { ProcessTree.killTree(process.processIdentifier) }
    }
  }
}

/// Mutable scratch shared between the drain queues and the termination handler. Locked
/// because the two reads and the handler touch it from different threads.
private final class StatusRunState: @unchecked Sendable {
  private let lock = NSLock()
  private var _stdout = Data()
  private var _stderr = Data()
  private var _timedOut = false

  func setStdout(_ d: Data) {
    lock.lock()
    _stdout = d
    lock.unlock()
  }
  func setStderr(_ d: Data) {
    lock.lock()
    _stderr = d
    lock.unlock()
  }
  func markTimedOut() {
    lock.lock()
    _timedOut = true
    lock.unlock()
  }

  var stdout: Data {
    lock.lock()
    defer { lock.unlock() }
    return _stdout
  }
  var stderr: Data {
    lock.lock()
    defer { lock.unlock() }
    return _stderr
  }
  var timedOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _timedOut
  }
}

/// Resumes a `CommandResult` continuation exactly once (termination vs launch-failure race).
private final class CommandResumeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private let continuation: CheckedContinuation<CommandResult, Never>

  init(_ continuation: CheckedContinuation<CommandResult, Never>) {
    self.continuation = continuation
  }

  func resume(_ value: CommandResult) {
    lock.lock()
    let first = !done
    done = true
    lock.unlock()
    if first { continuation.resume(returning: value) }
  }
}
