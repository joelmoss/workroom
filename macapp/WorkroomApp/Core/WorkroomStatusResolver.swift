import Foundation

/// What a CI probe decided. `keepPrior` means "don't overwrite the last good value" (a
/// transient rate-limit / network blip), so a flaky `gh` doesn't flicker the badge to nothing.
enum CIResolution: Equatable, Sendable {
  case state(CIState)
  case absent  // gh missing/unauth, no remote, no runs, or runs are for a different commit
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
      ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
      in: dir, timeout: timeout)
    guard r.ok else {
      return WorkroomStatus(dirty: nil, failure: Self.classifyGitFailure(r))
    }
    let p = Self.parseGitPorcelainV2Z(r.stdout)
    return WorkroomStatus(
      dirty: p.dirty, conflicted: p.conflicted, ahead: p.ahead, behind: p.behind,
      changedFiles: p.files, branchForCI: p.branch)
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
    // Phase 1 omits jj ahead/behind (no reliable git-equivalent — see plan); ci branch comes
    // from the colocated git ref if present (resolveCI handles that), so leave branchForCI nil.
    return WorkroomStatus(
      dirty: !files.isEmpty || head.conflicted, conflicted: head.conflicted, ahead: nil,
      behind: nil, changedFiles: files, branchForCI: nil, jjRefs: head.refs,
      jjDescription: head.description, jjChangeID: head.changeID, jjCommitID: head.commitID)
  }

  // MARK: Stage 2 — CI (slow, network; never blocks stage 1)

  /// `branch` is the git branch from stage 1 (git workrooms); when nil (jj, or unknown) we try
  /// the colocated git ref. CI is hidden whenever the branch/HEAD/remote can't be resolved.
  func resolveCI(path: String, branch: String?) async -> CIResolution {
    let headR = await runner.run("git", ["rev-parse", "HEAD"], in: path, timeout: timeout)
    guard headR.ok else { return .absent }  // no git backing → no CI
    let head = headR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !head.isEmpty else { return .absent }

    var branchName = branch
    if branchName == nil {
      let b = await runner.run(
        "git", ["symbolic-ref", "--quiet", "--short", "HEAD"], in: path, timeout: timeout)
      branchName = b.ok ? b.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    guard let branchName, !branchName.isEmpty else { return .absent }

    let r = await runner.run(
      "gh",
      [
        "run", "list", "--branch", branchName, "--limit", "20", "--json",
        "headSha,status,conclusion,workflowName",
      ], in: path, timeout: ciTimeout)
    return Self.classifyCI(r, head: head)
  }

  // MARK: - Pure parsers / classifiers (unit-tested directly)

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

  static func classifyGitFailure(_ r: CommandResult) -> VCSStatusFailure {
    if r.timedOut { return .timeout }
    if r.exitCode == CommandResult.gitFatal { return .notRepository }
    return .notRepository  // any other non-zero: treat the repo as unreadable (unknown, not clean)
  }

  /// Decode `gh run list ... --json` and collapse to a single CI state, considering only runs
  /// whose `headSha` matches the current HEAD (so a stale older run for a different commit can't
  /// mislead). Distinguishes absent (no gh / no runs / sha mismatch) from a transient rate-limit
  /// (`keepPrior`).
  static func classifyCI(_ r: CommandResult, head: String) -> CIResolution {
    if r.timedOut { return .keepPrior }
    if r.exitCode == CommandResult.commandNotFound { return .absent }  // gh not installed
    let lowerErr = r.stderr.lowercased()
    if lowerErr.contains("rate limit") || lowerErr.contains("503") || lowerErr.contains("timeout") {
      return .keepPrior
    }
    if !r.ok { return .absent }  // auth failure, no remote, not a gh repo, etc.

    struct Run: Decodable {
      let headSha: String?
      let status: String?
      let conclusion: String?
      let workflowName: String?
    }
    guard let data = r.stdout.data(using: .utf8),
      let runs = try? JSONDecoder().decode([Run].self, from: data)
    else { return .absent }

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
}
