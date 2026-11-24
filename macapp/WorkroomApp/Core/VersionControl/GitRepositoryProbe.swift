import Foundation
import WorkroomGit
import WorkroomSystem
import WorkroomVCS

/// The few facts the app reads from a checkout on this Mac by running `git` itself, rather than
/// through `RepositoryRouter`: its origin and remotes (a remote create's plan, #260), whether origin
/// has a branch, and the branch and commit a local CI probe keys off. Every other read goes through
/// the router.
struct GitRepositoryProbe: Sendable {
  let runner: StatusCommandRunning
  var timeout: TimeInterval  // local git
  var networkTimeout: TimeInterval  // `git ls-remote`

  /// What `discoverRepository` runs git with: a runner that applies a per-call environment.
  let discoveryRunner: StatusCommandRunning
  /// The discovery limits `discoverRepository` runs with. A seam for tests.
  let discoveryEnvironment: @Sendable () -> [String: String]

  init(
    runner: StatusCommandRunning = StatusCommandRunner(), timeout: TimeInterval = 3,
    networkTimeout: TimeInterval = 10,
    discoveryRunner: StatusCommandRunning = StatusCommandRunner(),
    discoveryEnvironment: @escaping @Sendable () -> [String: String] = {
      GitRepositoryProbe.discoveryLimits(
        inherited: ProcessInfo.processInfo.environment, probed: ShellEnvironment.environment())
    }
  ) {
    self.runner = runner
    self.discoveryRunner = discoveryRunner
    self.discoveryEnvironment = discoveryEnvironment
    self.timeout = timeout
    self.networkTimeout = networkTimeout
  }

  /// The GitHub repository `dir`'s `origin` remote names, from git alone (#260): for a remote
  /// workroom's create when `gh` can't answer, since a remote provider's workroom needs no `gh`.
  /// nil with no origin, or one that names no GitHub-shaped repository.
  func originRepository(in dir: String) async -> GitHubRepository? {
    await originURL(in: dir).flatMap(GitHubRepository.init(remote:))
  }

  /// `dir`'s origin URL, as git config has it; nil when git fails.
  func originURL(in dir: String) async -> String? {
    let r = await runner.run("git", ["remote", "get-url", "origin"], in: dir, timeout: timeout)
    guard r.exitCode == 0, !r.timedOut else { return nil }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The names of `dir`'s git remotes, from local config; empty when git fails.
  func remoteNames(in dir: String) async -> [String] {
    let r = await runner.run("git", ["remote"], in: dir, timeout: timeout)
    guard r.exitCode == 0, !r.timedOut else { return [] }
    return r.stdout.split(whereSeparator: \.isNewline).map(String.init)
  }

  /// Whether `dir`'s origin has `branch`, asked of origin itself: nil when that can't be told
  /// (offline, no credentials, a timeout), as `git ls-remote --exit-code` exits 2 only for no match.
  func originHasBranch(_ branch: String, in dir: String) async -> Bool? {
    // A network call: the network runner (the shell's ssh agent and BatchMode) and its timeout.
    let r = await runner.runNetwork(
      "git", ["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/\(branch)"], in: dir,
      timeout: networkTimeout)
    guard !r.timedOut else { return nil }
    switch r.exitCode {
    case 0: return true
    case 2: return false
    default: return nil
    }
  }

  /// The innermost git repository containing `folder` on this Mac, nil outside one or when git
  /// couldn't tell (see `discoverRepository`). What an inspector following a terminal reads (#803).
  func repository(containing folder: String) async -> FollowedFolder.Repository? {
    if case .repository(let found) = await discoverRepository(containing: folder) { return found }
    return nil
  }

  /// What `discoverRepository` found for a folder.
  enum Discovery: Equatable, Sendable {
    case repository(FollowedFolder.Repository)
    /// git answered that the folder is in no work tree, or the folder is gone.
    case notARepository
    /// git couldn't tell: a timeout, a failed spawn, a repository it refused (dubious ownership).
    case unknown
  }

  /// The innermost git repository containing `folder` on this Mac, as `git rev-parse
  /// --show-toplevel` answers it, so a linked worktree and a submodule are each their own.
  ///
  /// The one git run that must discover a repository ABOVE its working directory, which the
  /// runner's `GIT_CEILING_DIRECTORIES` forbids every other caller: it runs with the user's own
  /// discovery limits instead (`discoveryLimits`), on `discoveryRunner`, which must apply a per-call
  /// environment (the daemon-routed runner drops it, and re-sets the ceiling from the folder).
  ///
  /// The root it names is the folder's WORK TREE, which `core.worktree` can put anywhere, and every
  /// later read rediscovers a repository from that root. So the root counts only when the repository
  /// found there, under the normal ceiling, is the one found from the folder; else the root would
  /// read another repository (or none) than the one the folder is in.
  func discoverRepository(containing folder: String) async -> Discovery {
    // Every stat runs on GCD under the timeout: a stale network mount blocks one indefinitely.
    guard
      let isFolder = await stat({
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
          && isDirectory.boolValue
      })
    else { return .unknown }
    guard isFolder else { return .notARepository }
    let found = await discoveryRunner.run(
      "git", GitCommand.hardening + ["rev-parse", "--show-toplevel", "--absolute-git-dir"],
      in: folder, timeout: timeout, environment: discoveryEnvironment())
    guard found.ok else { return Self.notARepository(found) ? .notARepository : .unknown }
    let lines = found.stdout.split(whereSeparator: \.isNewline).map(String.init)
    guard lines.count == 2 else { return .unknown }
    let (root, gitDir) = (lines[0], lines[1])
    let atRoot = await discoveryRunner.run(
      "git", GitCommand.hardening + ["rev-parse", "--absolute-git-dir"], in: root,
      timeout: timeout)
    guard atRoot.ok else { return Self.notARepository(atRoot) ? .notARepository : .unknown }
    guard atRoot.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == gitDir else {
      return .notARepository
    }
    guard
      let (isRepository, isWritable) = await stat({
        (
          isGitRepo(at: URL(fileURLWithPath: root)),
          FileManager.default.isWritableFile(atPath: root)
        )
      })
    else { return .unknown }
    guard isRepository else { return .notARepository }
    return .repository(
      FollowedFolder.Repository(
        root: root, branch: await localBranch(path: root, branch: nil), isWritable: isWritable))
  }

  /// The discovery limits the resolve runs with: the user's own `GIT_CEILING_DIRECTORIES` (a
  /// dotfiles repository at `$HOME` is commonly fenced off this way) and
  /// `GIT_DISCOVERY_ACROSS_FILESYSTEM`, else no ceiling. The app's inherited environment wins over
  /// the probed shell's, as for a network command (`StatusCommandRunner.networkEnvironment`).
  static func discoveryLimits(inherited: [String: String], probed: [String: String])
    -> [String: String]
  {
    var env = ["GIT_CEILING_DIRECTORIES": ""]
    for key in ["GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"] {
      if let value = inherited[key] ?? probed[key] { env[key] = value }
    }
    return env
  }

  /// Whether a failed `rev-parse` said the folder is in no work tree (git's message under the
  /// runner's `LC_ALL=C`), rather than that it couldn't tell.
  private static func notARepository(_ r: CommandResult) -> Bool {
    guard r.exitCode == CommandResult.gitFatal, !r.timedOut, !r.signaled else { return false }
    return r.stderr.contains("not a git repository")
      || r.stderr.contains("must be run in a work tree")
  }

  /// `work` off the cooperative pool, nil when it outruns `timeout`.
  private func stat<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
    try? await withTimeout(seconds: timeout) { try await runBlocking { work() } }
  }

  // MARK: Local-only derivation (a local host reads these from its own checkout)

  /// The branch a PR/CI probe keys off, for a **local** host: the stage-1 branch when known; else
  /// the checked-out ref via `git symbolic-ref` (nil for a detached HEAD). A remote host has no
  /// checkout to ask, so it never calls this and treats a nil branch as absent.
  func localBranch(path: String, branch: String?) async -> String? {
    await resolveBranchName(branch, in: path)
  }

  /// The commit CI must match for a **local** host — see `ciMatchCommit`. nil ⇒ no resolvable
  /// branch or commit ⇒ the caller treats CI as absent.
  func localCICommit(path: String, branch: String?) async -> String? {
    guard await localBranch(path: path, branch: branch) != nil else { return nil }
    return await ciMatchCommit(path: path)
  }

  /// The commit a `gh run` must match to count as "this branch's CI": `HEAD` (the branch tip).
  /// `nil` ⇒ unresolved ⇒ absent.
  private func ciMatchCommit(path: String) async -> String? {
    let r = await runner.run(
      "git", GitCommand.hardening + ["rev-parse", "HEAD"], in: path, timeout: timeout)
    guard r.ok else { return nil }
    let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return sha.isEmpty ? nil : sha
  }

  /// The git branch CI/PR key off: the stage-1 branch when known, else the checked-out git ref
  /// via `git symbolic-ref` (empty for a *detached* HEAD). Returns `nil` when neither yields
  /// a non-empty name. Faithful to the prior inline fallback: a non-nil `branch` is used as-is (the
  /// symbolic-ref probe runs only when it's nil).
  private func resolveBranchName(_ branch: String?, in path: String) async -> String? {
    var branchName = branch
    if branchName == nil {
      let b = await runner.run(
        "git", GitCommand.hardening + ["symbolic-ref", "--quiet", "--short", "HEAD"], in: path,
        timeout: timeout)
      branchName = b.ok ? b.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    guard let branchName, !branchName.isEmpty else { return nil }
    return branchName
  }
}
