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
    let summary = await runner.run(
      "jj", ["diff", "--summary", "-r", "@", "--color", "never"], in: dir, timeout: timeout)
    guard summary.ok else {
      return WorkroomStatus(dirty: nil, failure: Self.classifyGitFailure(summary))
    }
    let files = Self.parseJJSummary(summary.stdout)
    // One log call yields the working copy's conflict flag, bookmarks, tags, and description —
    // the Changes header shows the jj-native refs + description (not a git-style branch name).
    // Best-effort: a failure leaves a blank head (conflicted=false), not unknown.
    let logR = await runner.run(
      "jj", ["log", "-r", "@", "--no-graph", "--color", "never", "-T", Self.jjHeadTemplate],
      in: dir, timeout: timeout)
    let head = logR.ok ? Self.parseJJHead(logR.stdout) : JJHead()
    let statR = await runner.run(
      "jj", ["diff", "-r", "@", "--stat", "--color", "never"], in: dir, timeout: timeout)
    let stat = statR.ok ? Self.parseDiffStat(statR.stdout) : (insertions: 0, deletions: 0)
    // CI/PR branch: jj's `@` is a *detached* git HEAD, so `git symbolic-ref` (resolveCI's fallback)
    // finds nothing. Resolve the nearest bookmark in `@`'s ancestry instead — that's the branch
    // pushed to origin, which `gh` keys PR/CI off. nil ⇒ no bookmark ⇒ CI/PR stay absent.
    let branchR = await runner.run(
      "jj",
      [
        "log", "-r", "heads(::@ & bookmarks())", "--no-graph", "--color", "never", "-T",
        Self.jjBranchTemplate,
      ], in: dir, timeout: timeout)
    let branch = branchR.ok ? Self.parseJJBranch(branchR.stdout) : nil
    // Phase 1 omits jj ahead/behind (no reliable git-equivalent — see plan).
    return WorkroomStatus(
      dirty: !files.isEmpty || head.conflicted, conflicted: head.conflicted, ahead: nil,
      behind: nil, changedFiles: files, insertions: stat.insertions, deletions: stat.deletions,
      branchForCI: branch, jjRefs: head.refs, jjDescription: head.description,
      jjChangeID: head.changeID, jjCommitID: head.commitID)
  }

  // MARK: Stage 2 — CI (slow, network; never blocks stage 1)

  /// CI for `branch` (stage 1's branch/bookmark). `vcs`/`projectRoot` pick where `gh` runs and which
  /// commit its runs must match — see `ghProbeTarget`. For jj the matched commit is the bookmark's
  /// tip (jj's `@` is an unpushed empty change), so a `gh run` for `@` could never match. CI is
  /// hidden whenever the branch / commit / git+gh context can't be resolved.
  func resolveCI(path: String, vcs: String, projectRoot: String, branch: String?) async
    -> CIResolution
  {
    guard
      let target = await ghProbeTarget(
        path: path, vcs: vcs, projectRoot: projectRoot, branch: branch)
    else { return .absent }
    guard let head = await ciMatchCommit(path: path, vcs: vcs, branch: target.branch) else {
      return .absent
    }

    let r = await runner.run(
      "gh",
      [
        "run", "list", "--branch", target.branch, "--limit", "20", "--json",
        "headSha,status,conclusion,workflowName",
      ], in: target.dir, timeout: ciTimeout)
    return Self.classifyCI(r, head: head)
  }

  /// The pull request for `branch`. Like `resolveCI`, `vcs`/`projectRoot` pick where `gh` runs (a
  /// jj workspace has no `.git` of its own, so `gh` must run from the colocated project root). `gh
  /// pr list --head` returns a JSON array — empty when the branch has no PR — so "no PR" is a clean
  /// `.absent`, not an error.
  func resolvePR(path: String, vcs: String, projectRoot: String, branch: String?) async
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
        "number,title,state,isDraft,url,reviewDecision",
      ], in: target.dir, timeout: ciTimeout)
    return Self.classifyPR(r)
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
  /// `gh auth status` in a neutral dir; a network/keyring blip (timeout) reports `available` so a
  /// flaky connection doesn't raise a false "not signed in" warning.
  func resolveGitHubCLI() async -> GitHubCLIStatus {
    let r = await runner.run(
      "gh", ["auth", "status"], in: NSTemporaryDirectory(), timeout: ciTimeout)
    return Self.classifyGitHubCLI(r)
  }

  // MARK: - Pure parsers / classifiers (unit-tested directly)

  static func classifyGitHubCLI(_ r: CommandResult) -> GitHubCLIStatus {
    if r.exitCode == CommandResult.commandNotFound { return .notInstalled }
    if r.timedOut { return .available }  // network/keyring blip — don't cry wolf
    return r.ok ? .available : .notAuthenticated  // gh auth status fails only when not logged in
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

  /// Decode `gh run list ... --json` and collapse to a single CI state, considering only runs
  /// whose `headSha` matches the current HEAD (so a stale older run for a different commit can't
  /// mislead). Distinguishes absent (no gh / no runs / sha mismatch) from a transient rate-limit
  /// (`keepPrior`).
  static func classifyCI(_ r: CommandResult, head: String) -> CIResolution {
    switch ghPreflight(r) {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .proceed: break
    }

    struct Run: Decodable {
      let headSha: String?
      let status: String?
      let conclusion: String?
      let workflowName: String?
    }
    // Malformed/truncated JSON (a gh schema change, or output capped mid-stream) must NOT erase the
    // CI badge — keep the last good value rather than flip to "no CI".
    guard let data = r.stdout.data(using: .utf8),
      let runs = try? JSONDecoder().decode([Run].self, from: data)
    else { return .keepPrior }

    // Newest-first; keep the first run per workflow, only for the current HEAD.
    var latestByWorkflow: [String: Run] = [:]
    for run in runs where run.headSha == head {
      let key = run.workflowName ?? "_"
      if latestByWorkflow[key] == nil { latestByWorkflow[key] = run }
    }
    guard !latestByWorkflow.isEmpty else { return .absent }

    var anyRunning = false
    var anySuccess = false
    var anyNeutral = false
    for run in latestByWorkflow.values {
      let status = run.status?.lowercased() ?? ""
      let conclusion = run.conclusion?.lowercased() ?? ""
      if status != "completed" {
        anyRunning = true
        continue
      }
      switch conclusion {
      case "success": anySuccess = true
      case "failure", "timed_out", "startup_failure", "action_required":
        return .state(.failing)  // a failure dominates
      case "cancelled", "skipped", "neutral", "stale": anyNeutral = true
      default: anyNeutral = true
      }
    }
    if anyRunning { return .state(.running) }
    if anySuccess { return .state(.passing) }
    if anyNeutral { return .state(.neutral) }
    return .absent
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

    struct Raw: Decodable {
      let number: Int
      let title: String
      let state: String
      let isDraft: Bool
      let url: String
      let reviewDecision: String?
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
    return .info(
      PullRequestInfo(
        number: raw.number, title: raw.title, state: state, isDraft: raw.isDraft, url: raw.url,
        reviewDecision: review))
  }
}
