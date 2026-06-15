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

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
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
    proc.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

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
          if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
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
  /// SIGKILL the child if still running — the cancellation path abandons the result, so kill
  /// promptly rather than wait out a SIGTERM grace.
  func terminate() {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
