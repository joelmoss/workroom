import WorkroomSystem
import XCTest

@testable import Workroom

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
