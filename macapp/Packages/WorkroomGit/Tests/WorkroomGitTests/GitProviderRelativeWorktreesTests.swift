import Foundation
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import WorkroomGit

/// `GitProvider` reads through the vendored libgit2: a repository with `extensions.relativeWorktrees`
/// (what git 2.48's `worktree.useRelativePaths`, or `git worktree add --relative-paths`, sets) reads
/// like any other. The libgit2 that SwiftGitX's fork shipped refused to open one at all, so every
/// read of that project and each of its worktrees failed. The `LibGit2` package's own tests cover the
/// open; this one covers the app's reads on it.
///
/// Repos are created fresh under `NSTemporaryDirectory()` and removed in `tearDown`; these never touch
/// a developer's own repository.
final class GitProviderRelativeWorktreesTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  func testReadsARepositoryWithRelativeWorktrees() async throws {
    let repo = NSTemporaryDirectory() + "wr-gprw-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    dirs.append(repo)
    for command in [
      "git init -q -b main",
      "printf 'one\\n' > a.txt && git add a.txt",
      "git -c user.name=t -c user.email=t@example.com commit -q -m first",
      "git config core.repositoryformatversion 1",
      "git config extensions.relativeWorktrees true",
      "printf 'two\\n' >> a.txt",
    ] {
      XCTAssertEqual(sh(command, in: repo), 0, command)
    }
    let root = URL(fileURLWithPath: repo)
    let provider = GitProvider()

    let status = try provider.workingStatus(root: root)
    XCTAssertEqual(status.changedFiles, [ChangedFile(path: "a.txt", change: .modified)])
    XCTAssertEqual(status.branchForCI, "main")

    let history = try provider.log(root: root, limit: 10)
    XCTAssertEqual(history.commits.map(\.summary), ["first"])

    let ref = try await provider.currentRef(root: root)
    XCTAssertEqual(ref, VCSRef(name: "main", kind: .branch))
  }

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
  }
}
