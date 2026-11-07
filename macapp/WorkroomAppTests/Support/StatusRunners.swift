import Foundation
import Synchronization
import WorkroomSystem

/// A `StatusCommandRunning` returning canned `CommandResult`s per (executable, args), so a probe
/// or resolver is tested without spawning real git or gh.
struct MockStatusRunner: StatusCommandRunning {
  let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    handler(executable, args)
  }
}

/// Like `MockStatusRunner` but records every (exe, args, dir) call, so a test can assert *where* a
/// probe ran and what it named — e.g. that a `gh` probe runs in the neutral directory with `--repo`.
final class RecordingStatusRunner: StatusCommandRunning, Sendable {
  private let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  private let recorded = Mutex<[(exe: String, args: [String], dir: String)]>([])
  var calls: [(exe: String, args: [String], dir: String)] { recorded.withLock { $0 } }

  init(_ handler: @escaping @Sendable (_ executable: String, _ args: [String]) -> CommandResult) {
    self.handler = handler
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    recorded.withLock { $0.append((executable, args, directory)) }
    return handler(executable, args)
  }
}

/// A command that exited 0, saying `stdout`.
func ok(_ stdout: String) -> CommandResult {
  CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
}

/// A command that exited 1, saying "boom".
func fail() -> CommandResult {
  CommandResult(stdout: "", stderr: "boom", exitCode: 1, timedOut: false)
}
