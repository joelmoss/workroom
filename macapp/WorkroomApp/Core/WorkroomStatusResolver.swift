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

/// Resolves a workroom's VCS + CI status app-side by shelling to git/jj/gh. App-side (not in
/// the `workroom --json` contract) for the same reasons as `BranchResolver`: GUI-only, keeps
/// `list` instant, isolates a slow repo to its own row. Stage 1 (`resolveLocal`) is fast/local;
/// stage 2 (`resolveCI`) is the slow network call and runs separately so it never blocks the
/// dirty dot. Pure parsers are `static` so they're unit-tested without spawning anything.
struct WorkroomStatusResolver: Sendable {
  let runner: StatusCommandRunning
  var timeout: TimeInterval  // local git/jj
  var ciTimeout: TimeInterval  // gh (network)

  init(
    runner: StatusCommandRunning = StatusCommandRunner(), timeout: TimeInterval = 3,
    ciTimeout: TimeInterval = 10
  ) {
    self.runner = runner
    self.timeout = timeout
    self.ciTimeout = ciTimeout
  }

  /// `-c` overrides prepended to every `git` invocation. A workroom can be a clone of an *untrusted*
  /// repo, and the status sweep runs git automatically on load/focus/selection — without this, a
  /// repo-local `core.fsmonitor` runs an arbitrary program on a plain `git status`. The diff probe
  /// additionally passes `--no-ext-diff`/`--no-textconv` (and the runner unsets `GIT_EXTERNAL_DIFF`)
  /// so `diff.external`/textconv config can't execute either. These flags go before the subcommand.
  static let gitHardening = ["-c", "core.fsmonitor="]

  // MARK: Stage 1 — local VCS status

  func resolveLocal(path: String, vcs: String) async -> WorkroomStatus {
    guard FileManager.default.fileExists(atPath: path) else {
      return WorkroomStatus(dirty: nil, failure: .missingPath)
    }
    switch vcs {
    case "git": return await resolveGit(path)
    case "jj": return await resolveJJ(path)
    default: return WorkroomStatus(dirty: nil, failure: .notRepository)
    }
  }

  private func resolveGit(_ dir: String) async -> WorkroomStatus {
    let r = await runner.run(
      "git",
      Self.gitHardening + [
        "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal",
      ],
      in: dir, timeout: timeout)
    guard r.ok else {
      return WorkroomStatus(dirty: nil, failure: Self.classifyGitFailure(r))
    }
    let p = Self.parseGitPorcelainV2Z(r.stdout)
    // Line counts vs HEAD (staged + unstaged tracked changes; untracked files aren't in the diff).
    let statR = await runner.run(
      "git", Self.gitHardening + ["diff", "--no-ext-diff", "--no-textconv", "--shortstat", "HEAD"],
      in: dir, timeout: timeout)
    let stat = statR.ok ? Self.parseDiffStat(statR.stdout) : (insertions: 0, deletions: 0)
    return WorkroomStatus(
      dirty: p.dirty, conflicted: p.conflicted, ahead: p.ahead, behind: p.behind,
      changedFiles: p.files, insertions: stat.insertions, deletions: stat.deletions,
      branchForCI: p.branch)
  }

  private func resolveJJ(_ dir: String) async -> WorkroomStatus {
    // STEP 1 (serial): this command snapshots `@` and takes the working-copy lock. Run it alone
    // first so the snapshot is fresh and the lock is released before the concurrent reads below.
    let summary = await runner.run(
      "jj", ["diff", "--summary", "-r", "@", "--color", "never"], in: dir, timeout: timeout)
    guard summary.ok else {
      return WorkroomStatus(dirty: nil, failure: Self.classifyGitFailure(summary))
    }
    let files = Self.parseJJSummary(summary.stdout)

    // STEP 2 (concurrent): the remaining reads reuse the snapshot from STEP 1. `--ignore-working-copy`
    // means none of them re-snapshots or takes the working-copy lock, so they're safe to run in
    // parallel (without it, concurrent jj would contend on the lock and could block/error). All are
    // best-effort: a failure degrades that slice rather than failing the whole probe.
    async let headR = runner.run(
      "jj",
      [
        "log", "-r", "@", "--ignore-working-copy", "--no-graph", "--color", "never", "-T",
        Self.jjHeadTemplate,
      ], in: dir, timeout: timeout)
    async let parentSummaryR = runner.run(
      "jj", ["diff", "--summary", "-r", "@-", "--ignore-working-copy", "--color", "never"],
      in: dir, timeout: timeout)
    async let parentHeadR = runner.run(
      "jj",
      [
        "log", "-r", "@-", "--ignore-working-copy", "--no-graph", "--color", "never", "-T",
        Self.jjHeadTemplate,
      ], in: dir, timeout: timeout)
    async let parentCountR = runner.run(
      "jj",
      [
        "log", "-r", "@-", "--ignore-working-copy", "--no-graph", "--color", "never", "-T",
        Self.jjParentCountTemplate,
      ], in: dir, timeout: timeout)
    async let statR = runner.run(
      "jj", ["diff", "-r", "@", "--ignore-working-copy", "--stat", "--color", "never"],
      in: dir, timeout: timeout)
    // CI/PR branch: jj's `@` is a *detached* git HEAD, so `git symbolic-ref` (resolveCI's fallback)
    // finds nothing. Resolve the nearest bookmark in `@`'s ancestry instead — that's the branch
    // pushed to origin, which `gh` keys PR/CI off. nil ⇒ no bookmark ⇒ CI/PR stay absent.
    async let branchR = runner.run(
      "jj",
      [
        "log", "-r", "heads(::@ & bookmarks())", "--ignore-working-copy", "--no-graph", "--color",
        "never", "-T", Self.jjBranchTemplate,
      ], in: dir, timeout: timeout)

    let (logR, parentSummary, parentHead, parentCount, statR2, branchR2) =
      await (headR, parentSummaryR, parentHeadR, parentCountR, statR, branchR)

    let head = logR.ok ? Self.parseJJHead(logR.stdout) : JJHead()
    let stat = statR2.ok ? Self.parseDiffStat(statR2.stdout) : (insertions: 0, deletions: 0)
    let branch = branchR2.ok ? Self.parseJJBranch(branchR2.stdout) : nil
    let workingCopy = JJCommitChanges(
      changeID: head.changeID, commitID: head.commitID, refs: head.refs,
      description: head.description, files: files)
    let parent = Self.resolveJJParent(
      summary: parentSummary, head: parentHead, count: parentCount)
    // Phase 1 omits jj ahead/behind (no reliable git-equivalent — see plan). `changedFiles` mirrors
    // the working copy's files (set from the one STEP-1 parse) so non-panel consumers are unchanged.
    return WorkroomStatus(
      dirty: !files.isEmpty || head.conflicted, conflicted: head.conflicted, ahead: nil,
      behind: nil, changedFiles: files, insertions: stat.insertions, deletions: stat.deletions,
      branchForCI: branch, jjWorkingCopy: workingCopy, jjParent: parent)
  }

  /// Classify the working copy's parent (`@-`) from its three best-effort probes. `count` (a
  /// one-token-per-revision template) disambiguates the structural cases that `summary`/`head`
  /// can't: 0 revisions ⇒ `@` is the root (`.root`), >1 ⇒ a merge (`.merge`, and `jj diff -r @-`
  /// would itself error on a multi-rev revset). For a single parent the `summary` probe is
  /// authoritative for the file list — if it failed we can't show the parent's changes truthfully,
  /// so `.unavailable` rather than a misleading empty list; `head` is best-effort (a missing
  /// id/description just drops the header chips, not the files).
  static func resolveJJParent(summary: CommandResult, head: CommandResult, count: CommandResult)
    -> JJParentState
  {
    if count.ok {
      let n = count.stdout.split(whereSeparator: \.isNewline).count
      if n == 0 { return .root }
      if n > 1 { return .merge(n) }
    }
    guard summary.ok else { return .unavailable }
    let files = parseJJSummary(summary.stdout)
    let h = head.ok ? parseJJHead(head.stdout) : JJHead()
    return .changes(
      JJCommitChanges(
        changeID: h.changeID, commitID: h.commitID, refs: h.refs, description: h.description,
        files: files))
  }

  // MARK: Stage 2 — CI (slow, network; never blocks stage 1)

  /// CI for `branch` (stage 1's branch/bookmark), as GitHub's own combined **status check rollup**
  /// for the branch-tip commit — the same aggregate the GitHub UI shows, covering *all* check types
  /// (Actions check-runs + external commit statuses + check-run apps), not just Actions runs (#76).
  ///
  /// `vcs`/`projectRoot` pick where `gh` runs (`ghProbeTarget`; jj → colocated project root). The
  /// commit is `ciMatchCommit`'s tip (for jj that's the bookmark's tip, since `@` is an unpushed
  /// empty change). `nameWithOwner` (`owner/repo`) keys the GraphQL `repository(owner:name:)` lookup;
  /// pass it from the sweep's per-project cache, or leave `nil` to resolve it inline (one extra
  /// `gh repo view`). Everything goes through the authenticated `gh` token, so private repos work
  /// with no extra config. CI is hidden whenever the branch / commit / repo / gh context can't be
  /// resolved.
  func resolveCI(
    path: String, vcs: String, projectRoot: String, branch: String?, nameWithOwner: String? = nil
  ) async -> CIResolution {
    guard
      let target = await ghProbeTarget(
        path: path, vcs: vcs, projectRoot: projectRoot, branch: branch)
    else { return .absent }
    guard let head = await ciMatchCommit(path: path, vcs: vcs, branch: target.branch) else {
      return .absent
    }
    // Use the caller's cached `owner/repo` when given (the sweep's per-project cache); otherwise
    // resolve it inline. (`??` can't wrap an `await` — its rhs is a non-async autoclosure.)
    let resolvedNWO: String?
    if let nameWithOwner {
      resolvedNWO = nameWithOwner
    } else {
      resolvedNWO = await resolveNameWithOwner(in: target.dir)
    }
    guard let nwo = resolvedNWO, let slash = nwo.firstIndex(of: "/") else { return .absent }
    let owner = String(nwo[..<slash])
    let name = String(nwo[nwo.index(after: slash)...])
    guard !owner.isEmpty, !name.isEmpty else { return .absent }

    let r = await runner.run(
      "gh",
      [
        "api", "graphql", "-f",
        "query=\(Self.checkRollupQuery(owner: owner, name: name, oid: head))",
      ],
      in: target.dir, timeout: ciTimeout)
    return Self.classifyCheckRollup(r)
  }

  /// The repo's `owner/repo` for the GraphQL rollup lookup, from `gh repo view` in the probe dir
  /// (resolves via the dir's git remote — works for git worktrees and a jj colocated project root).
  /// The sweep caches this per project; `resolveCI` falls back to calling it inline. `nil` ⇒ no
  /// remote / not a gh repo ⇒ caller treats CI as absent.
  func resolveNameWithOwner(in dir: String) async -> String? {
    let r = await runner.run(
      "gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], in: dir,
      timeout: ciTimeout)
    guard r.ok else { return nil }
    let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
  }

  /// GraphQL query for a commit's status-check rollup state. Uses `repository(owner:name:)` +
  /// `object(oid:)` so it runs against whatever host `gh` resolves for the repo (github.com or GHE),
  /// no hardcoded URL. Mirrors the `reviewURLQuery` style (interpolated, trusted inputs: repo names
  /// can't contain quotes; `oid` is a hex sha).
  static func checkRollupQuery(owner: String, name: String, oid: String) -> String {
    "{repository(owner:\"\(owner)\",name:\"\(name)\"){object(oid:\"\(oid)\"){... on Commit{statusCheckRollup{state}}}}}"
  }

  /// The pull request for `branch`. Like `resolveCI`, `vcs`/`projectRoot` pick where `gh` runs (a
  /// jj workspace has no `.git` of its own, so `gh` must run from the colocated project root). `gh
  /// pr list --head` returns a JSON array — empty when the branch has no PR — so "no PR" is a clean
  /// `.absent`, not an error.
  func resolvePR(path: String, vcs: String, projectRoot: String, branch: String?) async
    -> PRResolution
  {
    let res = await resolvePRRaw(path: path, vcs: vcs, projectRoot: projectRoot, branch: branch)
    return await enrichPR(res, path: path, vcs: vcs, projectRoot: projectRoot)
  }

  /// The classified PR (`gh pr list`) *without* the reviewer-permalink enrichment round-trip. The
  /// selection flow uses this so it has the PR `number` immediately — letting `resolveChecks` and the
  /// (slower, conditional) reviewer-URL enrichment run concurrently instead of checks waiting behind
  /// enrichment (issue #75, Codex #5). `resolvePR` composes this + `enrichPR` to preserve its old
  /// behaviour for any other caller.
  func resolvePRRaw(path: String, vcs: String, projectRoot: String, branch: String?) async
    -> PRResolution
  {
    guard
      let target = await ghProbeTarget(
        path: path, vcs: vcs, projectRoot: projectRoot, branch: branch)
    else { return .absent }

    let r = await runner.run(
      "gh",
      [
        "pr", "list", "--head", target.branch, "--state", "all", "--limit", "1", "--json",
        "number,title,state,isDraft,url,reviewDecision,latestReviews,reviewRequests,"
          + "mergeable,mergeStateStatus",
      ], in: target.dir, timeout: ciTimeout)
    return Self.classifyPR(r)
  }

  /// Attach reviewer permalinks to an already-classified PR. Runs `gh` in the same repo context as
  /// the read probes (jj → colocated project root). A no-op for `.absent`/`.keepPrior` (and for a PR
  /// with no submitted reviews — see `enrichReviewURLs`), so it's safe to call unconditionally.
  func enrichPR(_ res: PRResolution, path: String, vcs: String, projectRoot: String) async
    -> PRResolution
  {
    let dir = Self.ghProbeDirectory(path: path, vcs: vcs, projectRoot: projectRoot)
    return await enrichReviewURLs(res, in: dir)
  }

  /// The PR's individual CI checks (issue #75) via `gh pr checks <number>`. Keyed off the PR
  /// `number`, so unlike CI/PR it needs no branch resolution — just the gh repo context (jj →
  /// colocated project root, like the other probes). The pure `classifyChecks` decides from stdout
  /// regardless of exit code (see its doc), so a "pending" (exit 8) or "a check failed" (exit 1) run
  /// still yields the list rather than being misread as a hard failure.
  func resolveChecks(path: String, vcs: String, projectRoot: String, number: Int) async
    -> ChecksResolution
  {
    let dir = Self.ghProbeDirectory(path: path, vcs: vcs, projectRoot: projectRoot)
    let r = await runner.run(
      "gh",
      ["pr", "checks", "\(number)", "--json", "name,state,bucket,link,workflow"],
      in: dir, timeout: ciTimeout)
    return Self.classifyChecks(r)
  }

  /// Attach each submitted reviewer's review permalink so the PR panel can deep-link a row to its
  /// comment. `gh pr list --json` blanks review urls/ids, so fetch them with a GraphQL
  /// `resource(url:)` follow-up keyed by the PR's own URL. Best-effort: any failure (the probe
  /// errors, returns nothing, or the PR has no submitted reviews) leaves urls `nil` and returns the
  /// already-resolved PR unchanged — it never downgrades a good result. Only fires when there's a
  /// submitted (non-`requested`) reviewer, so PRs awaiting first review skip the extra round-trip.
  private func enrichReviewURLs(_ res: PRResolution, in dir: String) async -> PRResolution {
    guard case .info(let pr) = res,
      pr.reviewers.contains(where: { $0.state != .requested })
    else { return res }
    let g = await runner.run(
      "gh", ["api", "graphql", "-f", "query=\(Self.reviewURLQuery(prURL: pr.url))"],
      in: dir, timeout: ciTimeout)
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

  /// Where a stage-2 `gh` probe must run and which branch it keys off, per VCS. A **git worktree**
  /// has its own `.git`, so `gh` runs in-place (`path`) keyed by the git branch (stage-1 branch, or
  /// the colocated ref via `git symbolic-ref`). A **jj workspace** has no `.git` of its own — only
  /// the colocated `projectRoot` does — so `gh` runs from `projectRoot`, keyed by the bookmark.
  /// `nil` ⇒ no resolvable branch ⇒ caller returns `.absent`.
  private func ghProbeTarget(path: String, vcs: String, projectRoot: String, branch: String?) async
    -> (dir: String, branch: String)?
  {
    let dir = Self.ghProbeDirectory(path: path, vcs: vcs, projectRoot: projectRoot)
    if vcs == "jj" {
      guard let branch, !branch.isEmpty else { return nil }
      return (dir, branch)
    }
    guard let branchName = await resolveBranchName(branch, in: path) else { return nil }
    return (dir, branchName)
  }

  /// The directory a `gh` invocation must run in for this workroom: in-place for a git worktree
  /// (it has its own `.git` + remote), but the colocated `projectRoot` for a jj workspace (a
  /// secondary jj workspace has no `.git`, so `gh` can't resolve the repo there). Shared by the
  /// read probes (`ghProbeTarget`) and the PR write actions (`performPRAction`) so they agree.
  static func ghProbeDirectory(path: String, vcs: String, projectRoot: String) -> String {
    vcs == "jj" ? projectRoot : path
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

  /// Run a mutating `gh pr …` command (Phase 2b PR actions). Network timeout, like the read probes.
  /// Returns the raw result so the caller can refresh on success or surface `stderr` on failure.
  func runPRCommand(_ arguments: [String], in dir: String) async -> CommandResult {
    await runner.run("gh", arguments, in: dir, timeout: ciTimeout)
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
  func resolveGitHubCLI() async -> GitHubCLIStatus {
    let r = await runner.run(
      "gh", ["auth", "status", "--active", "--json", "hosts"], in: NSTemporaryDirectory(),
      timeout: ciTimeout)
    return Self.classifyGitHubCLI(r)
  }

  // MARK: - Pure parsers / classifiers (unit-tested directly)

  static func classifyGitHubCLI(_ r: CommandResult) -> GitHubCLIStatus {
    if r.exitCode == CommandResult.commandNotFound { return .notInstalled }
    if r.timedOut { return .available }  // network/keyring blip — don't cry wolf
    // `--json hosts` exits 0 even when the active token fails to validate, emitting structured
    // per-account state. Parse that to tell a transient network failure from a real logout (#86).
    if let status = classifyGitHubCLIJSON(r.stdout) { return status }
    // Fallback for an unparseable payload (pre-2.57 gh without `--json`, or a fatal gh error): the
    // old exit-code heuristic. A non-zero exit here is rare and ambiguous, so keep the prior
    // behaviour of treating it as not-authenticated rather than silently masking a real problem.
    return r.ok ? .available : .notAuthenticated
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

  struct GitParse: Equatable {
    var dirty = false
    var conflicted = false
    var ahead: Int?
    var behind: Int?
    var branch: String?
    var files: [ChangedFile] = []
  }

  /// Parse `git status --porcelain=v2 -z --branch`. The stream is NUL-separated; `# ...` lines
  /// are headers; entries start with `1 `/`2 `/`u `/`? `. A `2 ` (rename/copy) entry is followed
  /// by an extra NUL field holding the original path — consumed and skipped.
  static func parseGitPorcelainV2Z(_ output: String) -> GitParse {
    var p = GitParse()
    let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var i = 0
    while i < fields.count {
      let f = fields[i]
      i += 1
      if f.isEmpty { continue }
      if f.hasPrefix("# ") {
        let rest = String(f.dropFirst(2))
        if rest.hasPrefix("branch.head ") {
          let name = String(rest.dropFirst("branch.head ".count))
          p.branch = name == "(detached)" ? nil : name
        } else if rest.hasPrefix("branch.ab ") {
          let nums = rest.dropFirst("branch.ab ".count).split(separator: " ")
          for n in nums {
            if n.hasPrefix("+") { p.ahead = Int(n.dropFirst()) }
            if n.hasPrefix("-") { p.behind = Int(n.dropFirst()) }
          }
        }
        continue
      }
      switch f.first {
      case "1":
        p.dirty = true
        if let cf = changedFile(type1: f) { p.files.append(cf) }
      case "2":
        p.dirty = true
        if let cf = pathAfter(f, fields: 9).map({ ChangedFile(path: $0, change: .renamed) }) {
          p.files.append(cf)
        }
        i += 1  // skip the original-path field
      case "u":
        p.dirty = true
        p.conflicted = true
        if let path = pathAfter(f, fields: 10) {
          p.files.append(ChangedFile(path: path, change: .conflicted))
        }
      case "?":
        p.dirty = true
        let path = String(f.dropFirst(2))
        if !path.isEmpty { p.files.append(ChangedFile(path: path, change: .untracked)) }
      default:
        break  // "!" ignored, or unrecognized
      }
    }
    return p
  }

  /// Path of a type-1 entry plus its change kind, derived from the XY status code.
  private static func changedFile(type1 f: String) -> ChangedFile? {
    guard let path = pathAfter(f, fields: 8) else { return nil }
    let parts = f.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    let xy = parts.count > 1 ? String(parts[1]) : ".."
    return ChangedFile(path: path, change: change(forXY: xy))
  }

  /// The path is everything after the first `fieldCount` space-delimited fields (paths may
  /// contain spaces, so we split at most `fieldCount` times and take the remainder).
  private static func pathAfter(_ f: String, fields fieldCount: Int) -> String? {
    let parts = f.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
    guard parts.count > fieldCount else { return nil }
    let path = String(parts[fieldCount])
    return path.isEmpty ? nil : path
  }

  private static func change(forXY xy: String) -> ChangedFile.Change {
    let chars = Set(xy)
    if chars.contains("A") { return .added }
    if chars.contains("D") { return .deleted }
    if chars.contains("R") { return .renamed }
    if chars.contains("M") || chars.contains("T") { return .modified }
    return .other
  }

  /// Parse `jj diff --summary -r @` (lines like `M path`, `A path`, `D path`).
  static func parseJJSummary(_ output: String) -> [ChangedFile] {
    var files: [ChangedFile] = []
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      guard line.count >= 2, let code = line.first,
        line[line.index(line.startIndex, offsetBy: 1)] == " "
      else { continue }
      let path = String(line.dropFirst(2))
      guard !path.isEmpty else { continue }
      let change: ChangedFile.Change
      switch code {
      case "A": change = .added
      case "D": change = .deleted
      case "M": change = .modified
      case "R", "C": change = .renamed
      default: change = .other
      }
      files.append(ChangedFile(path: path, change: change))
    }
    return files
  }

  /// jj template for the working-copy head line, tab-separated: conflict flag, the change-id's
  /// shortest **unique prefix** on its own (`change_id.shortest()`, no padding), the shortest-8
  /// commit-id, then bookmarks, tags, and description. Description comes last so its (possible)
  /// newlines don't break the split. The `\t` stays a literal backslash-t in this raw string —
  /// jj's template parser turns it into a tab. Verified against jj 0.42.
  static let jjHeadTemplate =
    #"if(conflict, "true", "false") ++ "\t" ++ change_id.shortest() ++ "\t" ++ commit_id.shortest(8) ++ "\t" ++ bookmarks ++ "\t" ++ tags ++ "\t" ++ description"#

  struct JJHead: Equatable {
    var conflicted = false
    var changeID: String?  // shortest unique change-id prefix, no padding
    var commitID: String?  // shortest-8 commit-id
    var refs: [String] = []  // bookmarks + tags
    var description: String?  // first line; nil ⇒ "(no description set)"
  }

  /// jj template for the CI/PR branch query — just the bookmark name(s) on the matched commit.
  static let jjBranchTemplate = #"bookmarks ++ "\n""#

  /// jj template that emits one token per matched revision, so the line count of `jj log -r @-`
  /// distinguishes a single parent (1) from a merge (>1) or the root, which has no parent (0).
  static let jjParentCountTemplate = #""x\n""#

  /// First bookmark from `jj log -r 'heads(::@ & bookmarks())' -T 'bookmarks'` — the nearest
  /// bookmark in `@`'s ancestry, used as the jj branch for CI/PR lookup. Strips jj's `*` (ahead) /
  /// `??` (conflicted) decorations. `nil` when there's no bookmark (CI/PR then stay absent).
  static func parseJJBranch(_ output: String) -> String? {
    for raw in output.split(whereSeparator: \.isNewline) {
      guard let token = raw.split(separator: " ").first.map(String.init) else { continue }
      let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "*?"))
      if !cleaned.isEmpty { return cleaned }
    }
    return nil
  }

  static func parseJJHead(_ output: String) -> JJHead {
    var h = JJHead()
    let f = output.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
      .map(String.init)
    if f.count > 0 { h.conflicted = f[0].trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
    if f.count > 1, !f[1].isEmpty { h.changeID = f[1] }
    if f.count > 2, !f[2].isEmpty { h.commitID = f[2] }
    if f.count > 3 { h.refs += f[3].split(separator: " ").map(String.init) }
    if f.count > 4 { h.refs += f[4].split(separator: " ").map(String.init) }
    if f.count > 5 {
      let first = f[5].split(whereSeparator: \.isNewline).first.map(String.init)
      h.description = (first?.isEmpty == false) ? first : nil
    }
    return h
  }

  /// Sum the totals from a git `--shortstat` or jj `--stat` summary line, e.g.
  /// "3 files changed, 12 insertions(+), 4 deletions(-)". Either clause may be absent (→ 0); empty
  /// input (a clean tree) ⇒ (0, 0).
  static func parseDiffStat(_ text: String) -> (insertions: Int, deletions: Int) {
    func count(before noun: String) -> Int {
      guard let r = text.range(of: "\\d+(?= \(noun))", options: .regularExpression) else {
        return 0
      }
      return Int(text[r]) ?? 0
    }
    return (count(before: "insertion"), count(before: "deletion"))
  }

  static func classifyGitFailure(_ r: CommandResult) -> VCSStatusFailure {
    if r.timedOut { return .timeout }
    // Any non-zero exit (128 "not a repository", or anything else) ⇒ the repo is unreadable —
    // report unknown, never "clean". No finer distinction is needed today.
    return .notRepository
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
