import Foundation

/// What a CI probe decided. `keepPrior` means "don't overwrite the last good value" (a
/// transient rate-limit / network blip), so a flaky `gh` doesn't flicker the badge to nothing.
enum CIResolution: Equatable, Sendable {
  case state(CIState)
  case absent  // gh missing/unauth, no remote, no runs, or runs are for a different commit
  case keepPrior
}

/// What a PR probe decided. `keepPrior` (transient rate-limit/network blip) keeps the last good PR
/// so a flaky `gh` doesn't flicker the Pull Request section to empty.
enum PRResolution: Equatable, Sendable {
  case info(PullRequestInfo)
  case absent  // gh missing/unauth, no remote, or no PR for the branch
  case keepPrior
}

/// What a PR-checks probe decided (issue #75). `list([])` is a valid "loaded, no checks" result —
/// distinct from `absent`. `keepPrior` (transient rate-limit/network blip) keeps the last good list
/// so a flaky `gh` doesn't flicker the panel's check rows.
enum ChecksResolution: Equatable, Sendable {
  case list([CICheck])
  case absent  // gh missing/unauth, no remote, or no checks reported
  case keepPrior
}

/// `resolveGit`/`resolveJJ`'s native status seam (mirrors `StatusCommandRunning`'s role for the
/// CLI-shelling probes) — real reads via `GitProvider`/`RustJJProvider`, a gated/counting double in
/// tests.
///
/// ONE protocol, where there were two. They were separate because the two backends' `workingStatus`
/// returned different concrete types, which is also why `workingStatus` was the one VCS read never
/// on `LocalVCSProviding`. It is on it now and both return `WorkroomStatus`, so the split has nothing
/// left to express. A single seam is also the precondition for a third implementation — a remote
/// backend cannot satisfy a protocol whose shape depends on which backend it is.
protocol VCSWorkingStatusReading: Sendable {
  func workingStatus(root: URL) throws -> WorkroomStatus
}
extension GitProvider: VCSWorkingStatusReading {}
extension RustJJProvider: VCSWorkingStatusReading {}

/// Resolves a workroom's VCS + CI status app-side by shelling to git/jj/gh. App-side (not in
/// the `workroom --json` contract) for the same reasons as `BranchResolver`: GUI-only, keeps
/// `list` instant, isolates a slow repo to its own row. Stage 1 (`resolveLocal`) is fast/local;
/// stage 2 (`resolveCI`) is the slow network call and runs separately so it never blocks the
/// dirty dot. Pure parsers are `static` so they're unit-tested without spawning anything.
struct WorkroomStatusResolver: Sendable {
  let runner: StatusCommandRunning
  var timeout: TimeInterval  // local git/jj
  var ciTimeout: TimeInterval  // gh (network)
  /// Serializes jj working-copy snapshots per project root (see `JJSnapshotGate`) — a project's
  /// workrooms share a backing repo, so concurrent snapshots can contend on it.
  var gate: JJSnapshotGate
  /// `resolveGit`/`resolveJJ`'s native status seam — real reads by default (`GitProvider`/
  /// `RustJJProvider`), a gated/counting double in tests. `workingStatus` IS on `LocalVCSProviding` now
  /// and both backends return `WorkroomStatus`; these stay as injection points for the doubles, not
  /// because the two sides differ. See `VCSWorkingStatusReading`.
  var gitStatus: VCSWorkingStatusReading?
  var jjStatus: VCSWorkingStatusReading?

  /// How long `resolveJJ` waits its turn behind other same-project jj snapshots, before the row
  /// reports `.timeout`. Deliberately larger than `timeout`: with the gate serializing a busy
  /// project's workrooms, a healthy repo can sit queued behind several real (not contended)
  /// snapshots — this budgets the *wait*, not any single native call (which stays un-timed inside
  /// the gate; see `JJSnapshotGate`'s doc on why timing the operation itself would be unsafe).
  static let jjGatedWaitTimeout: TimeInterval = 15

  init(
    runner: StatusCommandRunning = StatusCommandRunner(), timeout: TimeInterval = 3,
    ciTimeout: TimeInterval = 10, gate: JJSnapshotGate = .shared,
    gitStatus: VCSWorkingStatusReading? = nil,
    jjStatus: VCSWorkingStatusReading? = nil
  ) {
    self.runner = runner
    self.timeout = timeout
    self.ciTimeout = ciTimeout
    self.gate = gate
    self.gitStatus = gitStatus
    self.jjStatus = jjStatus
  }

  /// `-c` overrides prepended to every `git` invocation. A workroom can be a clone of an *untrusted*
  /// repo, and the status sweep runs git automatically on load/focus/selection — without this, a
  /// repo-local `core.fsmonitor` runs an arbitrary program on a plain `git status`. The diff probe
  /// additionally passes `--no-ext-diff`/`--no-textconv` (and the runner unsets `GIT_EXTERNAL_DIFF`)
  /// so `diff.external`/textconv config can't execute either. These flags go before the subcommand.
  static let gitHardening = ["-c", "core.fsmonitor="]

  // MARK: Stage 1 — local VCS status

  /// `projectRoot` is the colocated project root (`StatusWorkItem.projectRoot`) — required, not
  /// defaulted, so every call site is forced to supply the key `resolveJJ`'s snapshot gate needs;
  /// `resolveGit` ignores it (git reads are never gated).
  func resolveLocal(path: String, vcs: String, projectRoot: String) async -> WorkroomStatus {
    if gitStatus == nil, jjStatus == nil {
      do { return await resolve(location: try await RepositoryLocation.local(path)) } catch {
        return WorkroomStatus(dirty: nil, failure: .unavailable)
      }
    }
    var status: WorkroomStatus
    if FileManager.default.fileExists(atPath: path) {
      switch vcs {
      case "git": status = await resolveGit(path)
      case "jj": status = await resolveJJ(path, projectRoot: projectRoot)
      default: status = WorkroomStatus(dirty: nil, failure: .notRepository)
      }
    } else {
      status = WorkroomStatus(dirty: nil, failure: .missingPath)
    }
    // Stamp when this read FINISHED, so `mergeLocalStatus` can order results that its five unordered
    // lanes produce. It has to be stamped here rather than by the caller: a jj read can sit in
    // `JJSnapshotGate` for seconds before it observes anything, so the caller's invocation time can
    // say a probe is older when it actually saw a LATER tree. Completion is the closest observable
    // bound on when the tree was seen. (Two overlapping reads can still finish in the opposite order
    // to their observations; closing that needs a filesystem generation number, not a clock.)
    status.localReadAt = Date()
    return status
  }

  func resolve(item: AppStore.StatusWorkItem) async -> WorkroomStatus {
    if let location = item.location {
      if location.host != .local || (gitStatus == nil && jjStatus == nil) {
        return await resolve(location: location)
      }
    }
    return await resolveLocal(path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
  }

  func resolve(location: RepositoryLocation, router: RepositoryRouter = .shared) async
    -> WorkroomStatus
  {
    var status: WorkroomStatus
    do {
      if location.host == .local {
        let exists = try await runBlocking { FileManager.default.fileExists(atPath: location.path) }
        guard exists else {
          var missing = WorkroomStatus(dirty: nil, failure: .missingPath)
          missing.localReadAt = Date()
          return missing
        }
      }
      let reader = try await router.reader(for: location)
      status = try await withTimeout(
        seconds: reader.context.backend == .jj ? Self.jjGatedWaitTimeout : timeout
      ) {
        try await reader.workingStatus()
      }
    } catch RepositoryRoutingError.registrationRequired {
      status = WorkroomStatus(dirty: nil, failure: .registrationRequired)
    } catch is RepositoryRoutingError, is HostConnectionError {
      status = WorkroomStatus(dirty: nil, failure: .unavailable)
    } catch is VCSTimeoutError, is VCSCancellationError {
      status = WorkroomStatus(dirty: nil, failure: .timeout)
    } catch let error as VCSError {
      status = WorkroomStatus(dirty: nil, failure: Self.failure(for: error))
    } catch { status = WorkroomStatus(dirty: nil, failure: .notRepository) }
    status.localReadAt = Date()
    return status
  }

  /// Which "unknown" badge a typed backend error earns. Pure, so the mapping is unit-tested without
  /// a repo.
  ///
  /// Only the two states a *retry* can clear get their own badge: the working-copy lock being held
  /// (`.busy`) and a working copy that moved under the read (`.staleWorkingCopy`) — both raised by
  /// the jj core's snapshot, both self-describing in the sidebar tooltip and the Changes panel.
  /// Everything else stays `.notRepository`, which is also the honest answer for the common git case:
  /// `GitProvider` can't bind SwiftGitX's typed error (a Swift 6 SIL crash — see its doc), so a
  /// missing/broken repo arrives as `.io` and must keep reading as "not a repository".
  static func failure(for error: VCSError) -> VCSStatusFailure {
    switch error {
    case .lockContention: return .busy
    case .staleSnapshot: return .staleWorkingCopy
    case .unsupportedRepo, .notFound, .partialData, .backendVersion, .io: return .notRepository
    }
  }

  private func resolveGit(_ dir: String) async -> WorkroomStatus {
    // Read git status structurally through libgit2 (SwiftGitX) instead of shelling `git status` +
    // `git diff --shortstat`. `LocalVCSProviding` has no built-in timeout, so bound the (synchronous,
    // off-main) read with `withTimeout` — a wedged repo abandons only its own row.
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    do {
      let ws = try await withTimeout(seconds: timeout) {
        // `runBlocking` (GCD), NOT `Task.detached`: the cooperative pool is fixed-width and this read
        // is fanned out ~5-wide per sweep (`runLocalSweep`), overlapping History/diff/branch reads —
        // exactly the burst the `runBlocking` doc flags as the "History loads forever" starvation.
        let gitStatus = self.gitStatus ?? GitProvider()
        return try await runBlocking { try gitStatus.workingStatus(root: root) }
      }
      return ws
    } catch is VCSTimeoutError, is VCSCancellationError {
      return WorkroomStatus(dirty: nil, failure: .timeout)
    } catch let error as VCSError {
      return WorkroomStatus(dirty: nil, failure: Self.failure(for: error))
    } catch {
      return WorkroomStatus(dirty: nil, failure: .notRepository)
    }
  }

  private func resolveJJ(_ dir: String, projectRoot: String) async -> WorkroomStatus {
    // Read the jj working-copy status structurally through the Rust core (jj-lib): it snapshots `@`
    // (so it reflects disk) and returns the `@`/`@-` change sets, the ± line counts and the CI branch
    // — replacing the old serial-snapshot-then-concurrent-CLI-reads dance. ONE read, deliberately: the
    // counts used to come from a `jj diff -r @ --stat` process fired after this one, which stated them
    // against a merge `@`'s auto-merged parents (a different base than the file list) and could be
    // read across an intervening edit. `LocalVCSProviding` has no built-in timeout, so
    // bound the (synchronous, off-main) read with `withTimeout` — for `resolveGit` a wedged repo
    // abandons only its own caller. For THIS jj path that's no longer the full story: the read is
    // additionally serialized per project root through `gate` (the ONE jj read that mutates — takes
    // the working-copy lock, can commit a repo-level transaction — and a project's workrooms share
    // that repo-level store, so concurrent snapshots across them can contend; see `JJSnapshotGate`'s
    // doc). A genuinely wedged (never-returning) native call therefore doesn't just abandon its own
    // caller — it can block later same-project calls too, bounded by `JJSnapshotGate.maxChainWait`
    // (the gate self-heals past a hung predecessor instead of queuing behind it forever). `resolveGit`
    // and `log`/`changeset`/`currentRef` (`BranchResolver`) are read-only and never gated, so they're
    // unaffected.
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    do {
      return try await withTimeout(seconds: Self.jjGatedWaitTimeout) {
        try await self.gate.run(projectRoot: projectRoot) {
          // `runBlocking` (GCD), NOT `Task.detached` — the blocking, snapshot-taking jj-lib read
          // must stay off the fixed-width cooperative pool (see `resolveGit` / the `runBlocking`
          // doc). Left un-timed inside the gate on purpose — see `JJSnapshotGate`'s doc.
          let jjStatus = self.jjStatus ?? RustJJProvider()
          return try await runBlocking { try jjStatus.workingStatus(root: root) }
        }
      }
    } catch is VCSTimeoutError, is VCSCancellationError {
      return WorkroomStatus(dirty: nil, failure: .timeout)
    } catch let error as VCSError {
      return WorkroomStatus(dirty: nil, failure: Self.failure(for: error))
    } catch {
      return WorkroomStatus(dirty: nil, failure: .notRepository)
    }
  }

  // MARK: Stage 2 — CI (slow, network; never blocks stage 1)

  /// Where every `gh` probe runs. Each one names its repository explicitly (`--repo` /
  /// `--hostname`), so none depends on a working directory: a remote workroom has no local one, and
  /// for jj it used to have to be the colocated project root because a secondary workspace has no
  /// `.git` of its own (issue #207). A neutral directory that always exists keeps that true.
  static var ghDirectory: String { NSTemporaryDirectory() }

  /// `gh pr …` takes `--repo`; `gh api …` takes `--hostname` (it has no repository of its own — the
  /// GraphQL query names it). Callers pass the WHOLE command, subcommand included, and the helper
  /// appends the flag. Both run in `ghDirectory` with the network timeout. The one place a probe's
  /// working directory and repository are decided, so a new probe cannot quietly go back to
  /// depending on the folder it happens to run in.
  private enum GHFlavor { case pr, api }

  private func gh(_ flavor: GHFlavor, _ arguments: [String], repo: GitHubRepository) async
    -> CommandResult
  {
    let full: [String]
    switch flavor {
    case .pr: full = arguments + ["--repo", repo.flag]
    case .api: full = arguments + ["--hostname", repo.host]
    }
    return await runner.run("gh", full, in: Self.ghDirectory, timeout: ciTimeout)
  }

  /// The repository `dir`'s git remote points at, from `gh repo view` — the ONE `gh` call that
  /// still needs a directory, and local-only. Classified with `ghPreflight` like every other `gh`
  /// probe, so a transient failure is `keepPrior` (the PR panel, checks list and CI badge all depend
  /// on this answer and must not blank on a blip) rather than collapsing into "no repository".
  func resolveRepository(in dir: String) async -> GitHubRepositoryResolution {
    let r = await runner.run(
      "gh", ["repo", "view", "--json", "url", "-q", ".url"], in: dir, timeout: ciTimeout)
    switch Self.ghPreflight(r) {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .proceed: break
    }
    guard let repo = GitHubRepository(url: r.stdout) else { return .absent }
    return .found(repo)
  }

  /// CI for `commit`, as GitHub's own combined **status check rollup** for that commit — the same
  /// aggregate the GitHub UI shows, covering *all* check types (Actions check-runs + external commit
  /// statuses + check-run apps), not just Actions runs (#76).
  ///
  /// `commit` is the branch tip the caller resolved (`localCICommit` for a local host; for jj that's
  /// the bookmark's tip, since `@` is an unpushed empty change). Everything goes through the
  /// authenticated `gh` token, so private repos work with no extra config. CI is hidden whenever the
  /// commit can't be resolved.
  func resolveCI(repo: GitHubRepository, commit: String) async -> CIResolution {
    // `commit` is interpolated into the query; a real one is hex. Anything else is not a commit.
    guard commit.count >= 7, commit.count <= 64, commit.allSatisfy(\.isHexDigit) else {
      return .absent
    }
    let r = await gh(
      .api,
      [
        "api", "graphql", "-f",
        "query=\(Self.checkRollupQuery(owner: repo.owner, name: repo.name, oid: commit))",
      ], repo: repo)
    return Self.classifyCheckRollup(r)
  }

  /// GraphQL query for a commit's status-check rollup state. Uses `repository(owner:name:)` +
  /// `object(oid:)` so it runs against whatever host `gh` resolves for the repo (github.com or GHE),
  /// no hardcoded URL. Mirrors the `reviewURLQuery` style (interpolated, trusted inputs: repo names
  /// can't contain quotes; `oid` is a hex sha).
  static func checkRollupQuery(owner: String, name: String, oid: String) -> String {
    "{repository(owner:\"\(owner)\",name:\"\(name)\"){object(oid:\"\(oid)\"){... on Commit{statusCheckRollup{state}}}}}"
  }

  /// The pull request for `branch`. `gh pr list --head` returns a JSON array — empty when the
  /// branch has no PR — so "no PR" is a clean `.absent`, not an error.
  func resolvePRRaw(repo: GitHubRepository, branch: String) async -> PRResolution {
    let r = await gh(
      .pr,
      [
        "pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json",
        "number,title,state,isDraft,url,reviewDecision,latestReviews,reviewRequests,"
          + "mergeable,mergeStateStatus",
      ], repo: repo)
    return Self.classifyPR(r)
  }

  /// The PR's individual CI checks (issue #75) via `gh pr checks <number>`. Keyed off the PR
  /// `number`, so unlike CI/PR it needs no branch resolution. The pure `classifyChecks` decides from
  /// stdout regardless of exit code (see its doc), so a "pending" (exit 8) or "a check failed"
  /// (exit 1) run still yields the list rather than being misread as a hard failure.
  func resolveChecks(repo: GitHubRepository, number: Int) async -> ChecksResolution {
    let r = await gh(
      .pr, ["pr", "checks", "\(number)", "--json", "name,state,bucket,link,workflow"], repo: repo)
    return Self.classifyChecks(r)
  }

  /// Attach each submitted reviewer's review permalink to an already-classified PR so the PR panel can
  /// deep-link a row to its comment. A no-op for `.absent`/`.keepPrior`, so it is safe to call
  /// unconditionally. `gh pr list --json` blanks review urls/ids, so fetch them with a GraphQL
  /// `resource(url:)` follow-up keyed by the PR's own URL. Best-effort: any failure (the probe
  /// errors, returns nothing, or the PR has no submitted reviews) leaves urls `nil` and returns the
  /// already-resolved PR unchanged — it never downgrades a good result. Only fires when there's a
  /// submitted (non-`requested`) reviewer, so PRs awaiting first review skip the extra round-trip.
  func enrichPR(_ res: PRResolution, repo: GitHubRepository) async -> PRResolution {
    guard case .info(let pr) = res,
      pr.reviewers.contains(where: { $0.state != .requested })
    else { return res }
    let g = await gh(
      .api, ["api", "graphql", "-f", "query=\(Self.reviewURLQuery(prURL: pr.url))"], repo: repo)
    let urls = Self.parseReviewURLs(g)
    guard !urls.isEmpty else { return res }
    let enriched = pr.reviewers.map { rev -> Reviewer in
      guard case .user(let login) = rev.identity, let url = urls[login] else { return rev }
      return Reviewer(identity: rev.identity, state: rev.state, url: url)
    }
    return .info(
      PullRequestInfo(
        number: pr.number, title: pr.title, state: pr.state, isDraft: pr.isDraft, url: pr.url,
        reviewDecision: pr.reviewDecision, reviewers: enriched,
        mergeable: pr.mergeable, mergeState: pr.mergeState))
  }

  /// The GraphQL query that maps a PR's submitted reviews to their author + permalink. Keyed by the
  /// PR's web URL via `resource(url:)` so it needs no separate owner/repo lookup.
  static func reviewURLQuery(prURL: String) -> String {
    "{resource(url:\"\(prURL)\"){... on PullRequest{latestReviews(first:50){nodes{author{login} url}}}}}"
  }

  /// Decode the `reviewURLQuery` response into `login → review-permalink`. Best-effort: a non-JSON
  /// body, a GraphQL `errors` payload, or any missing field yields an empty map (urls stay `nil`),
  /// so a flaky enrichment probe never blanks the reviewer rows.
  static func parseReviewURLs(_ r: CommandResult) -> [String: String] {
    struct Author: Decodable { let login: String? }
    struct Node: Decodable {
      let author: Author?
      let url: String?
    }
    struct Reviews: Decodable { let nodes: [Node]? }
    struct Resource: Decodable { let latestReviews: Reviews? }
    struct Data: Decodable { let resource: Resource? }
    struct Payload: Decodable { let data: Data? }
    guard let data = r.stdout.data(using: .utf8),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return [:] }
    var map: [String: String] = [:]
    for node in payload.data?.resource?.latestReviews?.nodes ?? [] {
      guard let login = node.author?.login, !login.isEmpty,
        let url = node.url, !url.isEmpty
      else { continue }
      map[login] = url
    }
    return map
  }

  // MARK: Local-only derivation (a local host reads these from its own checkout)

  /// The branch a PR/CI probe keys off, for a **local** host: the stage-1 branch/bookmark when known;
  /// else, for git, the colocated ref via `git symbolic-ref` (nil for a detached HEAD); for jj, nil
  /// — a bookmark-less `@` has no branch to look up. A remote host has no checkout to ask, so it
  /// never calls this and treats a nil branch as absent.
  func localBranch(path: String, vcs: String, branch: String?) async -> String? {
    if vcs == "jj" {
      guard let branch, !branch.isEmpty else { return nil }
      return branch
    }
    return await resolveBranchName(branch, in: path)
  }

  /// The commit CI must match for a **local** host — see `ciMatchCommit`. nil ⇒ no resolvable
  /// branch or commit ⇒ the caller treats CI as absent.
  func localCICommit(path: String, vcs: String, branch: String?) async -> String? {
    guard let branch = await localBranch(path: path, vcs: vcs, branch: branch) else { return nil }
    return await ciMatchCommit(path: path, vcs: vcs, branch: branch)
  }

  /// The commit a `gh run` must match to count as "this branch's CI". For a **git worktree** that's
  /// `HEAD` (the branch tip). For a **jj workspace** it's the bookmark's tip commit — jj's `@` is an
  /// unpushed empty change, so CI ran on the bookmark, not `@`. jj's `commit_id` is the git commit
  /// hash in a git-backed repo, so it matches `gh`'s `headSha` exactly. `nil` ⇒ unresolved ⇒ absent.
  private func ciMatchCommit(path: String, vcs: String, branch: String) async -> String? {
    let r: CommandResult
    if vcs == "jj" {
      r = await runner.run(
        "jj", ["log", "-r", branch, "--no-graph", "--color", "never", "-T", "commit_id"],
        in: path, timeout: timeout)
    } else {
      r = await runner.run(
        "git", Self.gitHardening + ["rev-parse", "HEAD"], in: path, timeout: timeout)
    }
    guard r.ok else { return nil }
    let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return sha.isEmpty ? nil : sha
  }

  /// The git branch CI/PR key off when not jj: the stage-1 branch when known, else the colocated
  /// git ref via `git symbolic-ref` (empty for a *detached* HEAD). Returns `nil` when neither yields
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

  /// Run a mutating `gh pr …` command (Phase 2b PR actions) against `repo`. Network timeout, like
  /// the read probes. Returns the raw result so the caller can refresh on success or surface
  /// `stderr` on failure.
  func runPRCommand(_ arguments: [String], repo: GitHubRepository) async -> CommandResult {
    await gh(.pr, arguments, repo: repo)
  }

  /// Probe whether `gh` is installed and authenticated (machine-global, not per-workroom). Runs
  /// `gh auth status --active --json hosts` in a neutral dir; a network/keyring blip reports
  /// `available` so a flaky connection doesn't raise a false "not signed in" warning.
  ///
  /// `--active` (gh ≥ 2.57.0) scopes the check to the *active* account on each host — the one
  /// `gh pr list` / `gh run list` actually use. Without it, plain `gh auth status` exits non-zero
  /// when *any* account on *any* host has an issue, so a single broken secondary / GitHub-App
  /// account would flip the whole app to "not signed in" and gate off the CI/PR sweep even though
  /// the active account works fine (issue #50).
  ///
  /// `--json hosts` (issue #86) is the fix for the *flapping* warning. `gh auth status` validates
  /// the token over the network; when api.github.com is briefly unreachable it can't tell "couldn't
  /// reach the API" from "token is bad", so the plain-text form misreports the blip as "token
  /// invalid" and exits non-zero — a false "not signed in". The `--json` form instead always exits
  /// zero (barring a fatal error) and emits a per-account `state`/`error`, so we can tell a
  /// transport failure (transient → don't cry wolf) from a genuine 401 (really logged out).
  ///
  /// Measured against gh 2.97.0: the JSON goes to **stdout** and the exit code is **0** in every
  /// genuine state — signed in, token rejected (a 401 in the per-account `error`), and no config at
  /// all (`{"hosts":{}}`). So a non-zero exit means we learned nothing, not that you're logged out.
  func resolveGitHubCLI() async -> GHAuthProbe {
    let r = await runner.run(
      "gh", ["auth", "status", "--active", "--json", "hosts"], in: Self.ghDirectory,
      timeout: ciTimeout)
    return Self.classifyGitHubCLI(r)
  }

  // MARK: - Pure parsers / classifiers (unit-tested directly)

  /// The outcome of one `gh auth status` probe: either a verdict about the machine, or "the probe
  /// told us nothing" — which is a THIRD thing, not a synonym for "gh works".
  ///
  /// Forcing "no news" into a `GitHubCLIStatus` is what made the old timeout path lie: reporting
  /// `.available` for a probe that never answered doesn't just fail to warn, it actively ERASES a
  /// correct `.notAuthenticated`/`.notInstalled`/`.tooOld` and leaves the user with a silent panel
  /// and PR probes that fail for no visible reason. `.keepPrior` mirrors `GHPreflight.keepPrior` and
  /// `CIResolution.keepPrior`, and — critically — the store does not stamp the TTL for it, so the
  /// next lane re-probes instead of trusting a non-answer for a full minute.
  enum GHAuthProbe: Equatable {
    case verdict(GitHubCLIStatus)
    case keepPrior
  }

  /// Classify one `gh auth status --active --json hosts` result.
  ///
  /// ```
  ///   exit 127 ─────────────────────────► .verdict(.notInstalled)
  ///   timedOut ─────────────────────────► .keepPrior      ◄─ MUST precede `signaled`:
  ///        │                                                 the timeout SIGTERMs the child,
  ///        │                                                 so a timeout sets BOTH flags
  ///   parseable JSON ───────────────────► .verdict(from the payload)
  ///        │                              ◄─ BEFORE `signaled`: a child that emitted a COMPLETE
  ///        │                                 401 and was killed afterwards really did tell us
  ///        │                                 the token is bad. Don't discard evidence.
  ///   signaled (no parseable payload) ──► .keepPrior      ◄─ killed/crashed: no verdict, no news
  ///        │
  ///   exit 0 ───────────────────────────► .verdict(.available)
  ///   non-zero ─────────────────────────► .verdict(.notAuthenticated)
  /// ```
  static func classifyGitHubCLI(_ r: CommandResult) -> GHAuthProbe {
    if r.exitCode == CommandResult.commandNotFound { return .verdict(.notInstalled) }
    if r.timedOut { return .keepPrior }  // network/keyring blip — and always also `signaled`
    // `--json hosts` exits 0 even when the active token fails to validate, emitting structured
    // per-account state. Parse that to tell a transient network failure from a real logout (#86).
    if let status = classifyGitHubCLIJSON(r.stdout) { return .verdict(status) }
    // Killed with nothing parseable to show for it (superseded probe, jetsam, crash, sleep/wake
    // signal): `exitCode` is a signal number, so the heuristic below would read SIGKILL as a
    // logout. That was the false, sticky "GitHub CLI not signed in".
    if r.signaled { return .keepPrior }
    // A gh too old to understand our flags is a VERSION problem, not a sign-in one, and must be
    // separated before the fallback below reads it as a logout.
    if rejectedUnknownFlag(r) { return .verdict(.tooOld) }
    // Remaining non-zero exits are a fatal gh error with no parseable JSON. Ambiguous, and
    // deliberately still reported as not-authenticated rather than silently masking a real problem.
    return .verdict(r.ok ? .available : .notAuthenticated)
  }

  /// Whether gh rejected one of our flags outright, i.e. it predates them.
  ///
  /// `gh auth status --active --json hosts` needs gh ≥ 2.57. An older gh does NOT ignore an unknown
  /// flag, it refuses the whole command: measured `exit 1`, **empty stdout**, and `unknown flag:
  /// --json` on stderr. Without this that shape fell through to the exit-code heuristic and reported
  /// a perfectly signed-in user as logged out — permanently, since no probe could ever succeed and
  /// `gh auth login` would change nothing.
  ///
  /// Matched on `unknown flag` **generically** rather than a specific flag name: `--active` and
  /// `--json` share the 2.57 floor and gh reports whichever it parses first, so pinning one spelling
  /// would miss the other. Requires a failed result, so a repo whose branch or PR title happens to
  /// contain the words can't trip it.
  static func rejectedUnknownFlag(_ r: CommandResult) -> Bool {
    !r.ok && r.stderr.lowercased().contains("unknown flag")
  }

  /// Classify `gh auth status --active --json hosts` output, or `nil` if it isn't the expected JSON
  /// (so the caller can fall back). Shape: `{"hosts":{"github.com":[{"state":"success"|"error",
  /// "error":"…","active":true,…}]}}`. With `--active` gh emits only each host's active account.
  ///
  /// - No accounts at all ⇒ genuinely logged out (`.notAuthenticated`).
  /// - Any active account validated (`state == "success"`) ⇒ `.available`. A success on the default
  ///   host means the PR/CI probes work even if a *secondary* host's account errors (issue #50).
  /// - Every active account errored ⇒ distinguish the cause: a genuine auth failure (the token was
  ///   rejected — HTTP 401 / "bad credentials") is `.notAuthenticated`; anything else (a transport
  ///   error from an unreachable API, a keyring blip) is a transient failure we don't cry wolf over.
  static func classifyGitHubCLIJSON(_ stdout: String) -> GitHubCLIStatus? {
    guard let data = stdout.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let hosts = root["hosts"] as? [String: Any]
    else { return nil }
    let accounts = hosts.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
    guard !accounts.isEmpty else { return .notAuthenticated }  // no accounts → logged out
    if accounts.contains(where: { ($0["state"] as? String) == "success" }) { return .available }
    let genuineFailure = accounts.contains { isGitHubAuthFailure($0["error"] as? String) }
    return genuineFailure ? .notAuthenticated : .available
  }

  /// Whether a `gh auth status` per-account `error` string reflects the token being *rejected* (a
  /// real logout) rather than the API being *unreachable* (a transient blip). A rejected/expired
  /// token gets an HTTP 401 from the API, which gh formats as `HTTP 401: Bad credentials (…)`; a
  /// connectivity failure is a transport error (`Get "https://api.github.com/": …`) with no HTTP
  /// status, so it falls through to "transient".
  ///
  /// Match the 401 shape specifically (`HTTP 401` / "bad credentials") rather than a bare `401` or
  /// `unauthorized` substring: those appear in unrelated text (a port, a repo name, an SSO/scope
  /// 403) and would mis-gate a logged-in user back to the false warning #86 fixes. A 403 (SSO /
  /// missing scope) is deliberately NOT treated as a logout — it's not a sign-in problem, and "not
  /// signed in" would misdiagnose it; it falls through to transient like any other non-401 error.
  static func isGitHubAuthFailure(_ error: String?) -> Bool {
    guard let e = error?.lowercased() else { return false }
    return e.contains("http 401") || e.contains("bad credentials")
  }

  /// Shared preflight for the two `gh` read probes (CI runs, PR list): distinguishes a transient
  /// blip (timeout / rate-limit / 503 → `keepPrior`, so the badge doesn't flicker) from a hard
  /// absence (gh not installed / auth failure / no remote → `absent`) from "proceed and parse"
  /// (`proceed`). Both classifiers must treat gh's failure modes identically — sharing this keeps
  /// them from drifting.
  enum GHPreflight: Equatable {
    case proceed
    case absent
    case keepPrior
  }

  static func ghPreflight(_ r: CommandResult) -> GHPreflight {
    if r.timedOut { return .keepPrior }
    // Killed rather than finished (cancelled lane, jetsam, crash, sleep/wake signal): `exitCode` is
    // a signal number, so `!r.ok` below would read SIGKILL as "gh failed" and clear a good PR/CI
    // badge. Belt is the callers' `Task.isCancelled` guards (`:153`/`:156`/`:166`/`:169`); this is
    // braces, because those guards are non-local and a future call site can forget them — which is
    // exactly how the gh *auth* probe came to publish a killed child's verdict.
    if r.signaled { return .keepPrior }
    if r.exitCode == CommandResult.commandNotFound { return .absent }  // gh not installed
    let lowerErr = r.stderr.lowercased()
    if lowerErr.contains("rate limit") || lowerErr.contains("503") || lowerErr.contains("timeout") {
      return .keepPrior
    }
    if !r.ok { return .absent }  // auth failure, no remote, not a gh repo, etc.
    return .proceed
  }

  /// Decode the `checkRollupQuery` response into a single CI state (#76). `gh api graphql` exits 0
  /// even when the body carries a GraphQL `errors` payload (the HTTP was 200), and non-zero on
  /// transport failures (auth / rate-limit / 5xx) — so `ghPreflight` is the right gate here (unlike
  /// `gh pr checks`, which overloads its exit code). A GraphQL `errors` payload or malformed JSON ⇒
  /// `.keepPrior` (don't blank a good badge on a transient/schema blip, matching the other
  /// classifiers); a null `resource`/`statusCheckRollup` ⇒ `.absent` (the commit has no checks).
  static func classifyCheckRollup(_ r: CommandResult) -> CIResolution {
    switch ghPreflight(r) {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .proceed: break
    }

    struct Rollup: Decodable { let state: String? }
    struct Object: Decodable { let statusCheckRollup: Rollup? }
    struct Repository: Decodable { let object: Object? }
    struct DataT: Decodable { let repository: Repository? }
    struct GQLError: Decodable { let message: String? }
    struct Payload: Decodable {
      let data: DataT?
      let errors: [GQLError]?
    }
    guard let data = r.stdout.data(using: .utf8),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return .keepPrior }  // malformed/truncated → keep last good (like classifyPR)
    // A GraphQL `errors` payload (HTTP 200) is a transient/lookup error → don't blank a good badge.
    if let errors = payload.errors, !errors.isEmpty { return .keepPrior }

    // `object` null (commit not found yet) or `statusCheckRollup` null (no checks) ⇒ nothing to show.
    guard let state = payload.data?.repository?.object?.statusCheckRollup?.state else {
      return .absent
    }
    // GraphQL `StatusState`: SUCCESS / FAILURE / ERROR / PENDING / EXPECTED. Rollup folds
    // skipped/neutral into SUCCESS, so this path never yields `.neutral` (the panel's `checksSummary`
    // still distinguishes it). An unknown/future value ⇒ `.absent` rather than a misleading glyph.
    switch state.uppercased() {
    case "SUCCESS": return .state(.passing)
    case "FAILURE", "ERROR": return .state(.failing)
    case "PENDING", "EXPECTED": return .state(.running)
    default: return .absent
    }
  }

  /// Decode `gh pr list --head <branch> --state all --json … --limit 1` (a JSON array) into the
  /// first PR, mapping GitHub's UPPER_SNAKE `state`/`reviewDecision` to our enums. An empty array is
  /// `.absent` (no PR); a transient rate-limit is `.keepPrior` so the section doesn't flicker.
  static func classifyPR(_ r: CommandResult) -> PRResolution {
    switch ghPreflight(r) {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .proceed: break
    }

    // `latestReviews` = the latest submitted review per author; `reviewRequests` = pending reviewers
    // (users by `login`, teams by `slug`). Both optional so JSON that omits them (old/other callers)
    // decodes cleanly to an empty reviewer list — only a *present-but-malformed* payload fails the
    // whole decode and trips `.keepPrior` below, so we never silently blank reviewers on a parse error.
    struct RawAuthor: Decodable { let login: String? }
    struct RawReview: Decodable {
      let author: RawAuthor?
      let state: String?
    }
    struct RawRequest: Decodable {
      let login: String?  // present for user reviewers
      let slug: String?  // present for team reviewers (with `name`); `__typename` is ignored
    }
    struct Raw: Decodable {
      let number: Int
      let title: String
      let state: String
      let isDraft: Bool
      let url: String
      let reviewDecision: String?
      let latestReviews: [RawReview]?
      let reviewRequests: [RawRequest]?
      let mergeable: String?  // MERGEABLE / CONFLICTING / UNKNOWN (issue #88)
      let mergeStateStatus: String?  // CLEAN / BLOCKED / BEHIND / … (issue #88)
    }
    // Malformed/truncated JSON (a gh schema change, or output capped mid-stream) must NOT erase the
    // PR badge. A *valid* empty array is different — that genuinely means no PR (handled below).
    guard let data = r.stdout.data(using: .utf8),
      let raws = try? JSONDecoder().decode([Raw].self, from: data)
    else { return .keepPrior }
    guard let raw = raws.first else { return .absent }  // valid empty array ⇒ genuinely no PR

    let state: PullRequestInfo.State
    switch raw.state.uppercased() {
    case "OPEN": state = .open
    case "MERGED": state = .merged
    case "CLOSED": state = .closed
    // An unexpected/future GitHub state: keep the last good PR rather than render one we don't
    // understand — mapping it to `.open` would expose destructive actions (close/draft) on it.
    default: return .keepPrior
    }
    let review: PullRequestInfo.ReviewDecision?
    switch raw.reviewDecision?.uppercased() {
    case "APPROVED": review = .approved
    case "CHANGES_REQUESTED": review = .changesRequested
    case "REVIEW_REQUIRED": review = .reviewRequired
    default: review = nil  // "" or absent → no decision to show
    }

    // Fold the two review arrays into one list keyed by reviewer identity. `latestReviews` is the
    // latest submitted review per author (so a login appears at most once — the keyed insert is
    // idempotent). `reviewRequests` then OVERRIDES: a re-requested reviewer is pending again even if
    // a stale submitted review exists. Order is irrelevant — `PRPresentation.reviewers` sorts.
    var reviewersByID: [String: Reviewer] = [:]
    for rev in raw.latestReviews ?? [] {
      guard let login = rev.author?.login, !login.isEmpty else { continue }
      let st: Reviewer.State
      switch rev.state?.uppercased() {
      case "APPROVED": st = .approved
      case "CHANGES_REQUESTED": st = .changesRequested
      case "COMMENTED": st = .commented
      case "DISMISSED": st = .dismissed
      default: continue  // unrecognised state (e.g. a future GitHub value, PENDING) → don't render
      }
      let reviewer = Reviewer(identity: .user(login: login), state: st)
      reviewersByID[reviewer.id] = reviewer
    }
    for req in raw.reviewRequests ?? [] {
      let identity: Reviewer.Identity
      if let login = req.login, !login.isEmpty {
        identity = .user(login: login)
      } else if let slug = req.slug, !slug.isEmpty {
        identity = .team(slug: slug)
      } else {
        continue  // no usable identifier
      }
      let reviewer = Reviewer(identity: identity, state: .requested)
      reviewersByID[reviewer.id] = reviewer
    }

    // Mergeability (issue #88): `MERGEABLE`/`CONFLICTING` map to true/false; anything else
    // (`UNKNOWN`, absent) stays nil so the Merge button hides while GitHub is still computing.
    let mergeable: Bool?
    switch raw.mergeable?.uppercased() {
    case "MERGEABLE": mergeable = true
    case "CONFLICTING": mergeable = false
    default: mergeable = nil
    }
    let mergeState: PullRequestInfo.MergeState?
    switch raw.mergeStateStatus?.uppercased() {
    case "CLEAN": mergeState = .clean
    case "BLOCKED": mergeState = .blocked
    case "BEHIND": mergeState = .behind
    case "UNSTABLE": mergeState = .unstable
    case "DIRTY": mergeState = .dirty
    case "DRAFT": mergeState = .draft
    case "HAS_HOOKS": mergeState = .hasHooks
    case "UNKNOWN": mergeState = .unknown
    case .some: mergeState = .unknown  // a future value → not-yet-mergeable, never misread as clean
    case nil: mergeState = nil
    }

    return .info(
      PullRequestInfo(
        number: raw.number, title: raw.title, state: state, isDraft: raw.isDraft, url: raw.url,
        reviewDecision: review, reviewers: Array(reviewersByID.values),
        mergeable: mergeable, mergeState: mergeState))
  }

  /// Decode `gh pr checks <n> --json name,state,bucket,link,workflow` into the per-check list.
  ///
  /// CRITICAL: `gh pr checks` overloads its exit code — `8` = checks pending, `1` = a check *failed*
  /// OR no-checks/other error, `0` = all pass — yet it still writes the JSON array to stdout for the
  /// pending/failing cases. So this decides from the JSON, NOT the exit code, and deliberately does
  /// NOT use `ghPreflight` (whose `!r.ok ⇒ .absent` rule is exactly wrong here). Parse stdout first;
  /// only when there's no usable JSON do we fall back to gh's failure modes (missing/blip/absent).
  ///
  /// A valid empty array (`[]`) ⇒ `.absent` ("loaded, no checks" — the store maps it to `[]`). A
  /// transient blip with no stdout ⇒ `.keepPrior` so the rows don't flicker.
  static func classifyChecks(_ r: CommandResult) -> ChecksResolution {
    struct Raw: Decodable {
      let name: String?
      let bucket: String?
      let state: String?
      let link: String?
      let workflow: String?
    }
    let trimmed = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      guard let data = r.stdout.data(using: .utf8),
        let raws = try? JSONDecoder().decode([Raw].self, from: data)
      else {
        // Non-empty but unparseable (truncated output / a gh schema change) must NOT blank the rows
        // — keep the last good list, like classifyCI/classifyPR do for malformed JSON.
        return .keepPrior
      }
      let checks: [CICheck] = raws.compactMap { raw in
        guard let name = raw.name, !name.isEmpty else { return nil }
        return CICheck(
          name: name,
          state: Self.checkState(bucket: raw.bucket),
          workflow: raw.workflow.flatMap { $0.isEmpty ? nil : $0 },
          link: raw.link.flatMap { $0.isEmpty ? nil : $0 })
      }
      // Empty array, or rows that all lacked a usable name ⇒ genuinely no checks to show.
      return checks.isEmpty ? .absent : .list(checks)
    }
    // Empty stdout (gh wrote nothing): distinguish gh-missing / transient blip / hard absence.
    if r.timedOut { return .keepPrior }
    // Killed rather than finished (cancelled lane, jetsam, crash, sleep/wake signal), with nothing
    // to show for it. `exitCode` is a signal number, so every test below reads a lie: 9/15 is
    // neither 127 nor a gh error message, and the `.absent` fallback would blank the rows AND stamp
    // `checksCheckedAt` — which is the loaded marker `PullRequestPanel.checksSummaryGlyph` and
    // `PRPresentation.isFailing` read to stop falling back to the branch CI aggregate. So a killed
    // probe would render a FAILING pr as green, and stay that way until the row is selected again
    // (`resolveChecks` runs only from `scheduleSelectedStatusRefresh`; no sweep refills it).
    //
    // Placed AFTER `timedOut` (the timeout SIGTERMs the child, so a timeout also sets `signaled`)
    // and after the stdout parse above (a child that emitted a COMPLETE payload and was killed
    // afterwards really did tell us something — don't discard evidence). Same ordering, and the same
    // reasoning, as `classifyGitHubCLI`; `ghPreflight` — which this classifier deliberately does not
    // use, because `gh pr checks` overloads its exit code — carries the sibling check.
    if r.signaled { return .keepPrior }
    if r.exitCode == CommandResult.commandNotFound { return .absent }  // gh not installed
    let lowerErr = r.stderr.lowercased()
    if lowerErr.contains("rate limit") || lowerErr.contains("503") || lowerErr.contains("timeout") {
      return .keepPrior
    }
    return .absent  // no checks reported / auth failure / no remote / etc.
  }

  /// gh's normalized `bucket` → our `CICheck.State`. Unknown ⇒ `.skipped` (quiet) so a future gh
  /// bucket value still renders a row rather than vanishing.
  static func checkState(bucket: String?) -> CICheck.State {
    switch bucket?.lowercased() {
    case "pass": return .passing
    case "fail": return .failing
    case "pending": return .pending
    case "skipping": return .skipped
    case "cancel": return .cancelled
    default: return .skipped
    }
  }
}
