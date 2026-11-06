import WorkroomSystem
import XCTest

@testable import Workroom

/// A `StatusCommandRunning` returning canned `CommandResult`s per (executable, args), so the probe
/// is tested without spawning real git.
private struct MockStatusRunner: StatusCommandRunning {
  let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    handler(executable, args)
  }
}

/// Like `MockStatusRunner` but records every (exe, args, dir) call, so a test can assert *where* a
/// probe ran and what it named.
private final class RecordingStatusRunner: StatusCommandRunning, @unchecked Sendable {
  private let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  private let lock = NSLock()
  private var _calls: [(exe: String, args: [String], dir: String)] = []
  var calls: [(exe: String, args: [String], dir: String)] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  init(_ handler: @escaping @Sendable (_ executable: String, _ args: [String]) -> CommandResult) {
    self.handler = handler
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    lock.lock()
    _calls.append((executable, args, directory))
    lock.unlock()
    return handler(executable, args)
  }
}

private func ok(_ stdout: String) -> CommandResult {
  CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
}

final class GitRepositoryProbeTests: XCTestCase {
  private let repo = GitHubRepository(host: "github.com", owner: "octo", name: "repo")!

  /// A create without gh (a remote provider's needs none) reads the repository from the project's
  /// own origin remote (#260); a project with no origin, or git failing, has none.
  func testOriginRepositoryReadsGitAlone() async {
    let runner = RecordingStatusRunner { _, _ in ok("git@github.com:octo/repo.git\n") }
    let found = await GitRepositoryProbe(runner: runner).originRepository(in: "/proj")
    XCTAssertEqual(found, repo)
    XCTAssertEqual(runner.calls.first?.dir, "/proj")
    XCTAssertEqual(runner.calls.first?.args, ["remote", "get-url", "origin"])
    let none = await GitRepositoryProbe(
      runner: MockStatusRunner { _, _ in
        CommandResult(
          stdout: "", stderr: "error: No such remote 'origin'", exitCode: 2, timedOut: false)
      }
    ).originRepository(in: "/proj")
    XCTAssertNil(none)
  }

  /// A remote create reads the project's remotes to tell `upstream/main` from an origin branch.
  func testRemoteNamesListsGitRemotes() async {
    let names = await GitRepositoryProbe(
      runner: MockStatusRunner { _, args in
        XCTAssertEqual(args, ["remote"])
        return ok("origin\nupstream\n")
      }
    ).remoteNames(in: "/proj")
    XCTAssertEqual(names, ["origin", "upstream"])
  }

  /// A remote create checks origin has the project's base branch: `ls-remote --exit-code` exits 2
  /// only for no match, so anything else (offline, no credentials) is left undecided.
  func testOriginHasBranchReadsLsRemotesExitCode() async {
    func ask(_ code: Int32) async -> Bool? {
      await GitRepositoryProbe(
        runner: MockStatusRunner { _, args in
          XCTAssertEqual(
            args, ["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/develop"])
          return CommandResult(stdout: "", stderr: "", exitCode: code, timedOut: false)
        }
      ).originHasBranch("develop", in: "/proj")
    }
    let found = await ask(0)
    let missing = await ask(2)
    let unknown = await ask(128)
    XCTAssertEqual(found, true)
    XCTAssertEqual(missing, false)
    XCTAssertNil(unknown)
  }
}
