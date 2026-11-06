import Foundation
import WorkroomSystem

/// The few facts the app reads from a checkout on this Mac by running `git` itself, rather than
/// through `RepositoryRouter`: its origin and remotes (a remote create's plan, #260), whether origin
/// has a branch, and the branch and commit a local CI probe keys off. Every other read goes through
/// the router.
struct GitRepositoryProbe: Sendable {
  let runner: StatusCommandRunning
  var timeout: TimeInterval  // local git
  var networkTimeout: TimeInterval  // `git ls-remote`

  init(
    runner: StatusCommandRunning = StatusCommandRunner(), timeout: TimeInterval = 3,
    networkTimeout: TimeInterval = 10
  ) {
    self.runner = runner
    self.timeout = timeout
    self.networkTimeout = networkTimeout
  }

  /// `-c` overrides prepended to every `git` invocation that can read the index or run a diff (the
  /// origin and remote probes below read only config and refs, so they go without). A workroom can
  /// be a clone of an *untrusted* repo, and the status sweep runs git automatically on
  /// load/focus/selection — without this, a repo-local `core.fsmonitor` runs an arbitrary program on a plain `git status`. The diff probe
  /// additionally passes `--no-ext-diff`/`--no-textconv` (and the runner unsets `GIT_EXTERNAL_DIFF`)
  /// so `diff.external`/textconv config can't execute either. These flags go before the subcommand.
  static let gitHardening = ["-c", "core.fsmonitor="]

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
      "git", Self.gitHardening + ["rev-parse", "HEAD"], in: path, timeout: timeout)
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
        "git", Self.gitHardening + ["symbolic-ref", "--quiet", "--short", "HEAD"], in: path,
        timeout: timeout)
      branchName = b.ok ? b.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    guard let branchName, !branchName.isEmpty else { return nil }
    return branchName
  }
}
