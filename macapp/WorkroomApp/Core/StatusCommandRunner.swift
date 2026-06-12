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
    await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      proc.arguments = [executable] + args
      proc.currentDirectoryURL = URL(fileURLWithPath: directory)

      var env = ProcessInfo.processInfo.environment
      env["PATH"] = ShellEnvironment.path()
      env["GIT_OPTIONAL_LOCKS"] = "0"
      env["GIT_TERMINAL_PROMPT"] = "0"
      proc.environment = env

      let outPipe = Pipe()
      let errPipe = Pipe()
      proc.standardOutput = outPipe
      proc.standardError = errPipe

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
        if proc.isRunning { proc.terminate() }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

      proc.terminationHandler = { finished in
        timeoutItem.cancel()
        drain.wait()  // both pipes fully read (child has exited and closed its write ends)
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
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        gate.resume(
          CommandResult(
            stdout: "", stderr: "\(error)", exitCode: CommandResult.commandNotFound,
            timedOut: false))
      }
    }
  }

  /// Drain a pipe to EOF, retaining at most `cap` bytes but reading the rest so the child
  /// never blocks on a full pipe buffer.
  private static func readCapped(_ handle: FileHandle, cap: Int) -> Data {
    var collected = Data()
    while true {
      let chunk = handle.availableData
      if chunk.isEmpty { break }  // EOF: pipe closed
      if collected.count < cap {
        collected.append(chunk.prefix(cap - collected.count))
      }
    }
    return collected
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
