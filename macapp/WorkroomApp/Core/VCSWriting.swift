import Foundation

/// A VCS action the toolbar can perform.
enum VCSRemoteAction: String, Equatable, Sendable, CaseIterable {
  case fetch, push, pull, abortRebase

  var label: String {
    switch self {
    case .fetch: return "Fetch"
    case .push: return "Push"
    case .pull: return "Pull"
    case .abortRebase: return "Abort rebase"
    }
  }

  /// Whether the action contacts a remote — drives the timeout budget and whether the command needs
  /// the auth-forwarding environment (`StatusCommandRunner.runNetwork`).
  var touchesNetwork: Bool { self != .abortRebase }
}

/// Why a remote read or action failed.
///
/// Deliberately NOT folded into `VCSError`: that enum is the backend-*read* taxonomy
/// (`lockContention`/`staleSnapshot`/`partialData`/…) and `WorkroomStatusResolver.failure(for:)`
/// switches over it exhaustively to choose a sidebar badge. `.authRequired` has no sidebar badge and
/// no sensible answer there, so adding it would force a meaningless decision in a function that
/// currently has a principled one for every case. Same reasoning that put `CIResolution`/`PRResolution`
/// beside their resolver instead of in `VCSModels.swift`.
enum VCSRemoteFailure: Equatable, Sendable {
  /// `git`/`jj` not on PATH. Distinct from `VCSToolVersions`' floor check, which runs at launch —
  /// this is the same condition caught at the point of use.
  case toolMissing(String)
  case timedOut(VCSRemoteAction)
  /// Credentials were needed and none were available.
  case authRequired(String)
  /// The host's key isn't in `known_hosts`. `BatchMode=yes` turns what would be an interactive
  /// confirmation into this, so it needs its own copy — telling the user to configure a credential
  /// helper would be wrong advice.
  case hostKeyUnverified(String)
  case noRemote
  /// Push rejected (non-fast-forward). The engine NEVER force-pushes; the UI offers Pull.
  case rejected(String)
  /// git refused because tracked files would be overwritten.
  case dirtyWorkingTree(String)
  /// A failed or killed `git pull --rebase` left `rebase-merge`/`rebase-apply` behind. The repo needs
  /// `git rebase --abort`, so the UI must offer that instead of a retry that will fail identically.
  case rebaseInProgress
  /// A repo lock was held — git `index.lock`/`packed-refs.lock`, or jj's `git_import_export.lock`.
  /// Transient; the UI offers Retry.
  case locked
  case other(String)
}

/// What a remote-state read decided. Mirrors `CIResolution`/`PRResolution`, `keepPrior` included: a
/// transient blip must not blank a good toolbar.
enum VCSRemoteResolution: Equatable, Sendable {
  case state(VCSRemoteState)
  /// Not a git/jj repo, or a repo with no refs at all (a fresh `git init`).
  case absent
  case keepPrior
  case failed(VCSRemoteFailure)
}

/// What an action decided.
///
/// There is deliberately no `okWithConflicts`: jj records conflicts *inside* commits and `jj rebase`
/// exits 0 when it produces them, so the exit code cannot distinguish them — and the working-copy read
/// that could is not safe to make here (it would re-enter `JJSnapshotGate` for the same project root,
/// which that type documents as a deadlock). `RemoteStateModel` upgrades a `.ok` pull to "conflicted"
/// from the status refresh it already triggers, after the gate has released.
enum VCSRemoteActionResult: Equatable, Sendable {
  case ok(summary: String)
  case failed(VCSRemoteFailure)
}

/// The seam for VCS operations that **write** — remote state reads plus fetch/push/pull.
///
/// Separate from `VCSProviding` on purpose. That protocol's doc calls it "the single seam the app
/// **reads** VCS data through", and four resolvers construct providers freely and call them with no
/// gate. Putting `fetch` there would mean nothing structurally prevented a read path from firing a
/// network mutation — the opposite of what `JJSnapshotGate` exists to guarantee. Keeping writes on
/// their own protocol also gives the injected `StatusCommandRunning` a home: `GitProvider` and
/// `RustJJProvider` are stateless value types constructed at four call sites with nowhere to put one.
///
/// This is the growth surface for the rest of the VCS write phase (commit/amend, bookmark management,
/// the deep jj ops), which is why it's a protocol with a factory rather than one standalone resolver —
/// otherwise each later operation re-derives repo kind and wires its own runner.
protocol VCSWriting: Sendable {
  /// Everything the toolbar renders, as ONE coherent snapshot.
  func remoteState(path: String, projectRoot: String) async -> VCSRemoteResolution
  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult
  /// `anonymousRevision` is used only by jj, and only when `@` carries no bookmark: it is the revision
  /// the auto-created `push-<change-id>` bookmark will point at. Compute it with
  /// `CLIVCSWriter.jjPushRevision(hasChanges:hasDescription:)` — pushing a bare `@` fails when the
  /// working copy is empty and undescribed, which is the state a fresh workroom sits in. Ignored by git.
  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool,
    anonymousRevision: String
  ) async -> VCSRemoteActionResult
  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String,
    tracking: VCSTracking?
  ) async -> VCSRemoteActionResult
  /// Recover a workroom left mid-rebase. git only; a no-op for jj, whose rebase is atomic and
  /// `jj undo`-able.
  func abortRebase(path: String, projectRoot: String) async -> VCSRemoteActionResult
}

extension VCS {
  /// The writer for a repo, or a typed error for an unsupported path. Mirrors `provider(for:)`, and
  /// routes on the same `repoKind(at:)`.
  static func writer(
    for root: URL, runner: StatusCommandRunning = StatusCommandRunner(),
    makeProvider: @escaping @Sendable (URL) throws -> VCSProviding = { try VCS.provider(for: $0) },
    gate: JJSnapshotGate = .shared
  ) throws -> VCSWriting {
    switch repoKind(at: root) {
    case .jjColocated, .jjNonColocated:
      return CLIVCSWriter(vcs: "jj", runner: runner, makeProvider: makeProvider, gate: gate)
    case .plainGit:
      return CLIVCSWriter(vcs: "git", runner: runner, makeProvider: makeProvider, gate: gate)
    case .unsupported(let reason):
      throw VCSError.unsupportedRepo(reason)
    }
  }
}

/// `VCSWriting` over the real `git` / `jj` CLIs.
///
/// **Why the CLI and not the libraries.** SwiftGitX 0.4.0's `fetch`/`push` pass `NULL` for the options
/// struct that would carry `git_remote_callbacks.credentials`, so they have no credential path at all —
/// HTTPS authentication is impossible through them — and it has no `pull`. Shelling the real binaries
/// means the user's own credential helpers, SSH agent and config just work, which is the same bet the
/// status layer already makes with `gh`. jj has no Swift API for these at all.
///
/// Pure `static` arg-builders, parsers and classifiers carry all the semantics, so they are unit-tested
/// without spawning anything — the pattern `RustJJProvider.workingDiffArgs` established for exactly
/// this reason.
///
/// ```
///                 ┌──────────── every network op ────────────┐
///                 │ runNetwork: stdin=/dev/null, BatchMode,   │
///                 │ askpass off, SSH_AUTH_SOCK forwarded      │
///                 └────────────────────┬─────────────────────┘
///                                      │
///                 ┌────────────────────┴─────────────────────┐
///                 │  JJSnapshotGate.run(projectRoot:)         │  git writes too
///                 │  NEVER re-enter for the same root         │
///                 └────────────────────┬─────────────────────┘
///                                      │
///     git ─────────────────────────────┼───────────────────────────── jj
///  fetch → PROJECT ROOT (FETCH_HEAD    │   fetch → PROJECT ROOT (a workspace
///          is per-worktree; the root   │           has no .git)
///          is one shared answer)       │   push  → PROJECT ROOT (bookmarks are
///  push  → workroom                    │           repo-global)
///  pull  → root (fetch) + workroom     │   pull  → root (fetch) + workroom (rebase)
///  abort → workroom                    │
/// ```
struct CLIVCSWriter: VCSWriting, Sendable {
  /// `"git"` or `"jj"` — resolved once by `VCS.writer(for:)` so no method re-derives it.
  let vcs: String
  let runner: StatusCommandRunning
  /// For `currentRef` only. The app already has a canonical answer including jj `.ancestor` and git
  /// `.detached`; re-deriving it from `%(HEAD)` would lose both.
  let makeProvider: @Sendable (URL) throws -> VCSProviding
  /// Serializes writes per project root. Applied to **git** as well as jj: a project's workrooms are
  /// `git worktree add` worktrees sharing one `.git`, so a lock lost mid-`pull --rebase` can leave a
  /// workroom wedged in a rebase.
  let gate: JJSnapshotGate

  var refTimeout: TimeInterval = 5
  var fetchTimeout: TimeInterval = 120
  var pushTimeout: TimeInterval = 120
  /// Generous because SIGKILLing a rebase is the one genuinely unsafe timeout here — it can leave
  /// `rebase-merge` behind. `classify` probes for that and reports `.rebaseInProgress`.
  var pullTimeout: TimeInterval = 300

  // MARK: - Placement

  /// Where an operation must run.
  ///
  /// **fetch always runs at the project root, for both backends.** For jj because a secondary
  /// workspace has no `.git` (the rule `WorkroomStatusResolver.ghProbeDirectory` already encodes for
  /// `gh`). For git because `FETCH_HEAD` is **per-worktree** — fetching inside a workroom would leave
  /// the project and every sibling workroom reading "never fetched" while their remote refs were
  /// perfectly fresh. At the root it's one fact every workroom of the project agrees on.
  ///
  /// **jj push also runs at the root**, because bookmarks are repo-global. Everything else runs in the
  /// workroom: push/pull act on THIS worktree's HEAD, and jj's `rebase` must rewrite THIS workspace's
  /// `@`.
  static func opDirectory(_ action: VCSRemoteAction, path: String, vcs: String, projectRoot: String)
    -> String
  {
    switch action {
    case .fetch: return projectRoot
    case .push: return vcs == "jj" ? projectRoot : path
    case .pull, .abortRebase: return path
    }
  }

  /// The **common** git directory for a path — the one shared by every worktree of the repo.
  ///
  /// `.git` is a directory in a normal repo and a FILE in a worktree, containing
  /// `gitdir: <repo>/.git/worktrees/<name>`. That per-worktree directory has its own `FETCH_HEAD`,
  /// `HEAD` and `index`, so reading `FETCH_HEAD` from it after fetching at the root finds nothing —
  /// the root's fetch wrote the root's copy. Stripping the `/worktrees/<name>` suffix gets the shared
  /// directory, which is where a root fetch's `FETCH_HEAD` actually lands.
  ///
  /// Pure string work, no subprocess: `git rev-parse --git-common-dir` is authoritative but costs a
  /// process for something two file reads answer.
  static func commonGitDir(at path: String) -> URL? {
    let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
      return nil
    }
    if isDir.boolValue { return dotGit }
    // A worktree's `.git` file: `gitdir: /abs/or/relative/path`.
    guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
    let line = contents.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard line.hasPrefix("gitdir:") else { return nil }
    let raw = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let gitDir =
      raw.hasPrefix("/")
      ? URL(fileURLWithPath: raw)
      : URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(raw).standardized
    // `<common>/worktrees/<name>` → `<common>`.
    let parts = gitDir.standardized.pathComponents
    guard let index = parts.lastIndex(of: "worktrees"), index > 0 else { return gitDir }
    return URL(fileURLWithPath: "/" + parts[1..<index].joined(separator: "/"))
  }

  /// `FETCH_HEAD`'s modification time. git rewrites it on **every** fetch, no-ops included (verified),
  /// so its mtime is a complete record of git fetches — including one the user ran in a terminal.
  static func gitLastFetch(commonGitDir: URL?) -> VCSLastFetch {
    guard let dir = commonGitDir else { return .unknown }
    let head = dir.appendingPathComponent("FETCH_HEAD")
    guard FileManager.default.fileExists(atPath: head.path) else { return .never }
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: head.path),
      let date = attrs[.modificationDate] as? Date
    else { return .unknown }
    return .at(date)
  }

  // MARK: - git argument builders

  /// Every remote ref plus, implicitly, the remote names. No `--count` cap: with branch switching cut
  /// there is no picker to fill, so this only ever answers "which remotes exist" and "does my branch
  /// have a counterpart".
  static func gitRemoteRefsArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + [
      "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", "refs/remotes",
    ]
  }

  /// Exact two-way divergence, independent of the user's `push.default`.
  ///
  /// **Deliberately not `%(push:track)`/`%(upstream:track)`.** Under `push.default=simple` — git's
  /// built-in default — `%(push)` resolves to nothing for a branch with no upstream, and every
  /// workroom is `git worktree add -b`, i.e. has no upstream. Deriving counts from that field leaves
  /// the badge permanently blank on any machine not set to `push.default=current` (verified on git
  /// 2.55). It also sidesteps a branch whose `%(upstream)` is a *local* branch, which would otherwise
  /// produce counts against a ref that isn't on any remote.
  ///
  /// `A...B` with `--left-right --count` prints `<only in A>\t<only in B>`, so with `A = HEAD` the
  /// left number is ahead and the right is behind.
  static func gitCountsArgs(remote: String, branch: String) -> [String] {
    WorkroomStatusResolver.gitHardening + [
      "rev-list", "--left-right", "--count", "HEAD...refs/remotes/\(remote)/\(branch)",
    ]
  }

  /// No `--prune`: omitting it lets the repo's own `fetch.prune` decide, the same
  /// pass-NULL-and-honour-config philosophy `GitCommitDiff` documents. No `--no-write-fetch-head`
  /// either — `FETCH_HEAD` is exactly what `gitLastFetch` reads.
  static func gitFetchArgs(remote: String) -> [String] {
    WorkroomStatusResolver.gitHardening + ["fetch", remote]
  }

  /// `--set-upstream` only when there is no counterpart yet; passing it on every push would rewrite
  /// `branch.<name>.remote`/`.merge` each time. **Never** `--force`/`--force-with-lease`: a rejection
  /// becomes `.rejected` and the UI offers Pull.
  static func gitPushArgs(branch: String, remote: String, setUpstream: Bool) -> [String] {
    WorkroomStatusResolver.gitHardening + ["push"]
      + (setUpstream ? ["--set-upstream"] : []) + [remote, branch]
  }

  /// `--autostash` is mandatory, not a nicety: workroom trees are essentially always dirty, and
  /// without it every pull dies on "cannot pull with rebase: You have unstaged changes". The remote
  /// branch is explicit so a workroom with no configured upstream can still pull.
  static func gitPullArgs(remote: String, branch: String) -> [String] {
    WorkroomStatusResolver.gitHardening + ["pull", "--rebase", "--autostash", remote, branch]
  }

  static func gitAbortRebaseArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + ["rebase", "--abort"]
  }

  // MARK: - jj argument builders

  /// Read-only jj flags. `--ignore-working-copy` is REQUIRED on reads: without it every toolbar poll
  /// would snapshot `@` and take the working-copy lock (the house rule on `VCSProviding`).
  static let jjReadFlags = ["--ignore-working-copy", "--color", "never", "--no-pager"]
  /// Mutating jj commands must NOT carry `--ignore-working-copy` — the snapshot is what preserves
  /// uncommitted edits into the old `@` before the working copy is rewritten.
  static let jjWriteFlags = ["--color", "never", "--no-pager"]

  /// One record per `(name, remote)` pair.
  ///
  /// Three verified traps in this template. The keyword is **`self`**, not `ref` (`ref.name()` errors).
  /// The `self.remote() && self.tracked() && self.tracking_present()` guards are load-bearing —
  /// calling `tracking_*_count()` on a local ref renders the literal string
  /// `<Error: Not a tracked remote ref>` into the output. And a colocated repo has a pseudo-remote
  /// called `git` that `--all-remotes` includes, which `parseJJBookmarks` drops.
  static func jjBookmarkListArgs() -> [String] {
    let template = """
      self.name() \
      ++ "\\x00" ++ if(self.remote(), self.remote(), "") \
      ++ "\\x00" ++ if(self.present() && !self.conflict(), self.normal_target().commit_id(), "") \
      ++ "\\x00" ++ if(self.present(), "1", "0") \
      ++ "\\x00" ++ if(self.conflict(), "1", "0") \
      ++ "\\x00" ++ if(self.tracked(), "1", "0") \
      ++ "\\x00" ++ if(self.remote() && self.tracked() && self.tracking_present(), \
      self.tracking_ahead_count().lower(), "") \
      ++ "\\x00" ++ if(self.remote() && self.tracked() && self.tracking_present(), \
      self.tracking_behind_count().lower(), "") \
      ++ "\\n"
      """
    return ["bookmark", "list", "--all-remotes"] + jjReadFlags + ["-T", template]
  }

  /// Newest-first operations, for the last-fetch scan.
  static func jjOpLogArgs(limit: Int = 200) -> [String] {
    ["op", "log", "--no-graph"] + jjReadFlags + [
      "--limit", "\(limit)",
      "-T", #"self.time().end().format("%s") ++ "\x00" ++ self.description().first_line() ++ "\n""#,
    ]
  }

  /// Count commits in a revset — one line of output per commit.
  static func jjRevsetCountArgs(_ revset: String) -> [String] {
    ["log", "--no-graph"] + jjReadFlags + ["-r", revset, "-T", #""x\n""#]
  }

  /// What bare `jj git push` would send, so the ahead count and the Push button agree by construction.
  static func jjAheadRevset(remote: String) -> String {
    "remote_bookmarks(remote=\(remote))..@"
  }
  static func jjBehindRevset(remote: String) -> String {
    "@..remote_bookmarks(remote=\(remote))"
  }

  static func jjFetchArgs(remote: String) -> [String] {
    ["git", "fetch", "--remote", remote] + jjWriteFlags
  }

  static func jjPushBookmarkArgs(bookmark: String, remote: String) -> [String] {
    ["git", "push", "--remote", remote, "--bookmark", bookmark] + jjWriteFlags
  }

  /// jj's built-in anonymous-branch push: it creates the bookmark, tracks it automatically, and names
  /// it from `templates.git_push_bookmark` (default `"push-" ++ change_id.short()`). This is the normal
  /// workroom case — `jj workspace add --name` creates a workspace, not a bookmark, so `@` is
  /// unbookmarked and there is otherwise nothing for `--bookmark` to name.
  static func jjPushChangeArgs(revision: String, remote: String) -> [String] {
    ["git", "push", "--remote", remote, "--change", revision] + jjWriteFlags
  }

  /// `-b @`, not `-s @`: `-b` moves the whole branch containing `@` onto the new tip, which is the
  /// pull-rebase shape. `-s` would move only `@` and its descendants, orphaning its parents.
  static func jjRebaseArgs(onto destination: String) -> [String] {
    ["rebase", "-b", "@", "-d", destination] + jjWriteFlags
  }

  /// Which revision an anonymous push should send.
  ///
  /// `@` when it carries work, otherwise its parent. jj refuses to push a commit with an empty
  /// description, and a fresh `@` after `jj new` has neither changes nor a description — so pushing
  /// `@` blindly fails for the most common state a workroom sits in.
  static func jjPushRevision(hasChanges: Bool, hasDescription: Bool) -> String {
    (hasChanges || hasDescription) ? "@" : "@-"
  }

  // MARK: - Parsers

  struct RemoteRefs: Equatable, Sendable {
    /// Remote names, first-seen order (so `origin` keeps its natural primacy when present).
    let remotes: [String]
    /// Short names, e.g. `"origin/main"`.
    let shortNames: Set<String>
  }

  /// Parse `for-each-ref refs/remotes` output.
  ///
  /// Skips records with a non-empty `%(symref)` — that's `refs/remotes/<remote>/HEAD`, whose short
  /// name is the bare remote and which would otherwise look like a branch called `origin`.
  /// Field count is checked rather than assumed: a ref name can't contain a control character, but
  /// being strict here means a malformed line is dropped rather than crashing the read.
  static func parseGitRemoteRefs(_ stdout: String) -> RemoteRefs {
    var remotes: [String] = []
    var shortNames: Set<String> = []
    for line in stdout.split(whereSeparator: \.isNewline) {
      let fields = line.components(separatedBy: "\0")
      guard fields.count == 3 else { continue }
      guard fields[2].isEmpty else { continue }  // symref → origin/HEAD
      let refname = fields[0]
      let prefix = "refs/remotes/"
      guard refname.hasPrefix(prefix) else { continue }
      let short = String(refname.dropFirst(prefix.count))
      guard let slash = short.firstIndex(of: "/") else { continue }
      let remote = String(short[short.startIndex..<slash])
      guard !remote.isEmpty, slash < short.index(before: short.endIndex) else { continue }
      if !remotes.contains(remote) { remotes.append(remote) }
      shortNames.insert(short)
    }
    return RemoteRefs(remotes: remotes, shortNames: shortNames)
  }

  /// `"3\t1"` → (ahead: 3, behind: 1). `nil` for anything unexpected — never a misleading zero.
  static func parseCounts(_ stdout: String) -> (ahead: Int, behind: Int)? {
    let fields = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0 == "\t" || $0 == " " })
    guard fields.count == 2, let ahead = Int(fields[0]), let behind = Int(fields[1]) else {
      return nil
    }
    return (ahead, behind)
  }

  /// One bookmark, folded from its local row and its `@<remote>` row.
  struct JJBookmark: Equatable, Sendable {
    let name: String
    let tracking: VCSTracking?
  }

  /// Parse `bookmark list --all-remotes` output into per-name tracking, plus the remote names.
  ///
  /// **jj's counts are inverted relative to git and are swapped here.** `tracking_ahead_count()` on an
  /// `@origin` ref means *the remote is ahead of local*, which is git's **behind** — jj's own default
  /// template proves it by printing "ahead by N commits" next to `@origin`. One line, one comment, and
  /// a cross-backend integration test pins it.
  static func parseJJBookmarks(_ stdout: String) -> (bookmarks: [JJBookmark], remotes: [String]) {
    var remotes: [String] = []
    var trackingByName: [String: VCSTracking] = [:]
    var localNames: [String] = []
    for line in stdout.split(whereSeparator: \.isNewline) {
      let f = line.components(separatedBy: "\0")
      guard f.count == 8 else { continue }
      let (name, remote) = (f[0], f[1])
      let present = f[3] == "1"
      let tracked = f[5] == "1"
      guard !name.isEmpty else { continue }
      if remote.isEmpty {
        if !localNames.contains(name) { localNames.append(name) }
        continue
      }
      // A colocated repo exposes a pseudo-remote called `git` (jj's local git-tracking bookmarks).
      // It is not a remote, and including it would both pollute the remote list and produce counts
      // against the local git refs rather than a server.
      guard remote != "git" else { continue }
      if !remotes.contains(remote) { remotes.append(remote) }
      // An untracked remote bookmark, or one deleted on the remote, cannot answer counts. `gone`
      // reports the deletion; nil counts report "unanswerable" rather than a misleading zero.
      let jjAhead = Int(f[6])
      let jjBehind = Int(f[7])
      trackingByName[name] = VCSTracking(
        comparedTo: "\(name)@\(remote)",
        ahead: tracked && present ? jjBehind : nil,  // swapped — see the doc comment
        behind: tracked && present ? jjAhead : nil,
        gone: !present)
    }
    let bookmarks = localNames.map { JJBookmark(name: $0, tracking: trackingByName[$0]) }
    return (bookmarks, remotes)
  }

  /// The newest operation whose description says it fetched.
  ///
  /// Matches a prefix rather than the whole string so a reworded suffix survives. The failure mode is
  /// graceful — one absent label, never a wrong one — and an integration test reddens on a jj bump.
  ///
  /// **Incomplete by design**: a `jj git fetch` that brings nothing prints "Nothing changed." and
  /// records NO operation (verified, jj 0.43), so this answers "last fetch that changed something".
  /// `RemoteStateModel` takes the max of this and Workroom's own recorded fetch time to close the gap.
  static func parseJJFetchOp(_ stdout: String) -> Date? {
    for line in stdout.split(whereSeparator: \.isNewline) {
      let f = line.components(separatedBy: "\0")
      guard f.count == 2, f[1].hasPrefix("fetch from git remote") else { continue }
      guard let seconds = TimeInterval(f[0]) else { continue }
      return Date(timeIntervalSince1970: seconds)
    }
    return nil
  }

  // MARK: - Classification

  /// Map a failed command to a typed failure. `nil` means success.
  ///
  /// `gitDir` lets a failed pull be upgraded to `.rebaseInProgress` — the distinction matters because
  /// that state must offer Abort, not Retry.
  static func classify(
    _ result: CommandResult, action: VCSRemoteAction, tool: String,
    gitDir: URL? = nil
  ) -> VCSRemoteFailure? {
    if result.exitCode == CommandResult.commandNotFound { return .toolMissing(tool) }
    let err = result.stderr + "\n" + result.stdout
    // A timed-out pull may have left a rebase behind; that reads better than "timed out".
    if result.timedOut {
      if action == .pull, rebaseInProgress(gitDir: gitDir) { return .rebaseInProgress }
      return .timedOut(action)
    }
    guard !result.ok else { return nil }
    if err.contains("Host key verification failed") || err.contains("REMOTE HOST IDENTIFICATION") {
      return .hostKeyUnverified(err)
    }
    if err.contains("terminal prompts disabled") || err.contains("could not read Username")
      || err.contains("could not read Password") || err.contains("Authentication failed")
      || err.contains("Permission denied (publickey)")
    {
      return .authRequired(err)
    }
    if err.contains("would be overwritten") { return .dirtyWorkingTree(err) }
    if err.contains("does not appear to be a git repository") || err.contains("No such remote")
      || err.contains("no such remote") || err.contains("No git remotes")
    {
      return .noRemote
    }
    if err.contains("Updates were rejected") || err.contains("! [rejected]") {
      return .rejected(err)
    }
    if err.contains("Failed to take lock for Git import/export")
      || (err.contains(".lock")
        && (err.contains("could not be obtained") || err.contains("File exists")
          || err.contains("Unable to create")))
    {
      return .locked
    }
    if action == .pull, rebaseInProgress(gitDir: gitDir) { return .rebaseInProgress }
    let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
    return .other(trimmed.isEmpty ? "\(tool) exited \(result.exitCode)" : trimmed)
  }

  /// Whether a rebase is parked in this worktree. Both directory names are checked: `rebase-merge` for
  /// an interactive/merge rebase, `rebase-apply` for the am-based one.
  static func rebaseInProgress(gitDir: URL?) -> Bool {
    guard let gitDir else { return false }
    let fm = FileManager.default
    return fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
      || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path)
  }

  /// This worktree's OWN git directory — `<common>/worktrees/<name>` for a workroom, the same as the
  /// common dir for a project root. Rebase state (`rebase-merge`), `HEAD` and `index` live here, unlike
  /// `FETCH_HEAD` which `commonGitDir` deliberately resolves to the shared copy.
  static func worktreeGitDir(at path: String) -> URL? {
    let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
      return nil
    }
    if isDir.boolValue { return dotGit }
    guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
    let line = contents.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard line.hasPrefix("gitdir:") else { return nil }
    let raw = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    return raw.hasPrefix("/")
      ? URL(fileURLWithPath: raw)
      : URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(raw).standardized
  }

  // MARK: - Running

  private func run(
    _ args: [String], in directory: String, timeout: TimeInterval, network: Bool = false
  ) async -> CommandResult {
    network
      ? await runner.runNetwork(vcs, args, in: directory, timeout: timeout)
      : await runner.run(vcs, args, in: directory, timeout: timeout)
  }

  /// Run a write through the per-project gate.
  ///
  /// `JJSnapshotGate`'s doc warns against timing the innermost call, because `withTimeout` cannot
  /// cancel a blocking jj-lib call and the gate would release while the abandoned call still held the
  /// lock. That reasoning does **not** apply to a subprocess: `StatusCommandRunner` SIGTERMs at
  /// `+timeout` and `ProcessTree.killTree`s at `+timeout+2`, so the process is genuinely gone and its
  /// locks genuinely released. Hence the runner's own timeout with no outer `withTimeout` — this looks
  /// like a violation of that doc and isn't.
  private func gated(
    _ projectRoot: String, _ body: @Sendable @escaping () async -> CommandResult
  ) async -> CommandResult? {
    try? await gate.run(projectRoot: projectRoot, body)
  }

  // MARK: - Remote state

  func remoteState(path: String, projectRoot: String) async -> VCSRemoteResolution {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let current: VCSRef
    do {
      current = try await makeProvider(root).currentRef(root: root)
    } catch {
      return .failed(.other("couldn't read the current ref: \(error)"))
    }
    return vcs == "jj"
      ? await jjRemoteState(path: path, projectRoot: projectRoot, current: current)
      : await gitRemoteState(path: path, current: current)
  }

  private func gitRemoteState(path: String, current: VCSRef) async -> VCSRemoteResolution {
    let refs = await run(Self.gitRemoteRefsArgs(), in: path, timeout: refTimeout)
    if let failure = Self.classify(refs, action: .fetch, tool: "git") {
      // A blip must not blank a good toolbar; a missing tool or a real error should show.
      if case .timedOut = failure { return .keepPrior }
      return .failed(failure)
    }
    let parsed = Self.parseGitRemoteRefs(refs.stdout)
    let primary = Self.primaryRemote(parsed.remotes)
    var tracking: VCSTracking?
    if let primary, let branch = current.name, current.kind == .branch {
      let counterpart = "\(primary)/\(branch)"
      if parsed.shortNames.contains(counterpart) {
        let counts = await run(
          Self.gitCountsArgs(remote: primary, branch: branch), in: path, timeout: refTimeout)
        if let parsedCounts = Self.parseCounts(counts.stdout) {
          tracking = VCSTracking(
            comparedTo: counterpart, ahead: parsedCounts.ahead, behind: parsedCounts.behind,
            gone: false)
        } else {
          tracking = VCSTracking(comparedTo: counterpart, ahead: nil, behind: nil, gone: false)
        }
      } else {
        // No counterpart on the remote — the normal state of a fresh workroom, since
        // `git worktree add -b` sets no upstream. Reported as `gone` so the toolbar offers Publish.
        tracking = VCSTracking(comparedTo: counterpart, ahead: nil, behind: nil, gone: true)
      }
    }
    return .state(
      VCSRemoteState(
        current: current, tracking: tracking, remotes: parsed.remotes, primaryRemote: primary,
        lastFetch: Self.gitLastFetch(commonGitDir: Self.commonGitDir(at: path)),
        resolvedAt: Date()))
  }

  private func jjRemoteState(path: String, projectRoot: String, current: VCSRef) async
    -> VCSRemoteResolution
  {
    // Reads take no lock, so they stay ungated.
    let list = await run(Self.jjBookmarkListArgs(), in: path, timeout: refTimeout)
    if let failure = Self.classify(list, action: .fetch, tool: "jj") {
      if case .timedOut = failure { return .keepPrior }
      return .failed(failure)
    }
    let parsed = Self.parseJJBookmarks(list.stdout)
    let primary = Self.primaryRemote(parsed.remotes)
    var tracking: VCSTracking?
    if let primary {
      switch current.kind {
      case .branch:
        tracking = current.name.flatMap { name in
          parsed.bookmarks.first { $0.name == name }?.tracking
        }
      case .ancestor:
        // `@` carries no bookmark — the normal workroom state, since `jj workspace add --name` creates
        // no bookmark. The bookmark row's counts would describe the ANCESTOR, not the user's work, so
        // count the actual revsets instead. `remote_bookmarks(remote=…)..@` is exactly what bare
        // `jj git push` sends, so the number and the button agree by construction.
        let ahead = await run(
          Self.jjRevsetCountArgs(Self.jjAheadRevset(remote: primary)), in: path, timeout: refTimeout
        )
        let behind = await run(
          Self.jjRevsetCountArgs(Self.jjBehindRevset(remote: primary)), in: path,
          timeout: refTimeout)
        tracking = VCSTracking(
          comparedTo: primary,
          ahead: ahead.ok ? Self.countLines(ahead.stdout) : nil,
          behind: behind.ok ? Self.countLines(behind.stdout) : nil,
          gone: false)
      case .detached, .none:
        tracking = nil
      }
    }
    // jj's fetch is invisible to `FETCH_HEAD` (it passes `--no-write-fetch-head`), so scan the op log.
    let ops = await run(Self.jjOpLogArgs(), in: path, timeout: refTimeout)
    let lastFetch = ops.ok ? Self.parseJJFetchOp(ops.stdout) : nil
    return .state(
      VCSRemoteState(
        current: current, tracking: tracking, remotes: parsed.remotes, primaryRemote: primary,
        lastFetch: lastFetch.map { .at($0) } ?? (ops.ok ? .never : .unknown),
        resolvedAt: Date()))
  }

  /// `origin` when it exists, else the first remote, else nil. Origin-scoped by default, matching the
  /// deliberate choice `VCSPushState` documents.
  static func primaryRemote(_ remotes: [String]) -> String? {
    remotes.contains("origin") ? "origin" : remotes.first
  }

  static func countLines(_ stdout: String) -> Int {
    stdout.split(whereSeparator: \.isNewline).count
  }

  // MARK: - Actions

  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult {
    let dir = Self.opDirectory(.fetch, path: path, vcs: vcs, projectRoot: projectRoot)
    let args = vcs == "jj" ? Self.jjFetchArgs(remote: remote) : Self.gitFetchArgs(remote: remote)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: fetchTimeout, network: true)
        })
    else { return .failed(.other("fetch was cancelled")) }
    if let failure = Self.classify(result, action: .fetch, tool: vcs) { return .failed(failure) }
    return .ok(summary: "Fetched \(remote)")
  }

  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool,
    anonymousRevision: String
  ) async -> VCSRemoteActionResult {
    let dir = Self.opDirectory(.push, path: path, vcs: vcs, projectRoot: projectRoot)
    let args: [String]
    if vcs == "jj" {
      if current.kind == .branch, let bookmark = current.name {
        args = Self.jjPushBookmarkArgs(bookmark: bookmark, remote: remote)
      } else {
        // Unbookmarked `@`: let jj mint and track a `push-<change-id>` bookmark.
        args = Self.jjPushChangeArgs(revision: anonymousRevision, remote: remote)
      }
    } else {
      guard let branch = current.name, current.kind == .branch else {
        return .failed(.other("HEAD is detached — check out a branch before pushing."))
      }
      args = Self.gitPushArgs(branch: branch, remote: remote, setUpstream: setUpstream)
    }
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: pushTimeout, network: true)
        })
    else { return .failed(.other("push was cancelled")) }
    if let failure = Self.classify(result, action: .push, tool: vcs) { return .failed(failure) }
    return .ok(summary: "Pushed to \(remote)")
  }

  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String,
    tracking: VCSTracking?
  ) async -> VCSRemoteActionResult {
    // Both backends fetch first, at the project root, for the reasons `opDirectory` documents. For git
    // `pull` would fetch too, but doing it explicitly at the root keeps `FETCH_HEAD` — and so the
    // "last fetched" label — correct for every workroom of the project.
    let fetchDir = Self.opDirectory(.fetch, path: path, vcs: vcs, projectRoot: projectRoot)
    let fetchArgs =
      vcs == "jj" ? Self.jjFetchArgs(remote: remote) : Self.gitFetchArgs(remote: remote)
    guard
      let fetched = await gated(
        projectRoot,
        { [self] in
          await run(fetchArgs, in: fetchDir, timeout: fetchTimeout, network: true)
        })
    else { return .failed(.other("pull was cancelled")) }
    if let failure = Self.classify(fetched, action: .pull, tool: vcs) { return .failed(failure) }

    let dir = Self.opDirectory(.pull, path: path, vcs: vcs, projectRoot: projectRoot)
    let gitDir = Self.worktreeGitDir(at: path)
    let args: [String]
    if vcs == "jj" {
      guard let destination = tracking?.comparedTo, destination != remote else {
        // An unbookmarked `@` has no single remote bookmark to rebase onto; jj's own fetch already
        // moved the remote bookmarks and jj auto-rebases descendants, so there is nothing more to do.
        return .ok(summary: "Fetched \(remote)")
      }
      args = Self.jjRebaseArgs(onto: destination)
    } else {
      guard let branch = Self.pullBranch(current: current, tracking: tracking) else {
        return .failed(.other("no remote branch to pull from."))
      }
      args = Self.gitPullArgs(remote: remote, branch: branch)
    }
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: pullTimeout, network: true)
        })
    else { return .failed(.other("pull was cancelled")) }
    if let failure = Self.classify(result, action: .pull, tool: vcs, gitDir: gitDir) {
      return .failed(failure)
    }
    return .ok(summary: "Pulled from \(remote)")
  }

  /// The remote branch a pull rebases from: the counterpart's own name, stripped of its `<remote>/`
  /// prefix, falling back to the local branch name (the same-name convention).
  static func pullBranch(current: VCSRef, tracking: VCSTracking?) -> String? {
    if let comparedTo = tracking?.comparedTo, let slash = comparedTo.firstIndex(of: "/") {
      return String(comparedTo[comparedTo.index(after: slash)...])
    }
    return current.name
  }

  func abortRebase(path: String, projectRoot: String) async -> VCSRemoteActionResult {
    guard vcs != "jj" else {
      // jj's rebase is atomic and undoable — there is no half-finished state to abort.
      return .ok(summary: "Nothing to abort")
    }
    let dir = Self.opDirectory(.abortRebase, path: path, vcs: vcs, projectRoot: projectRoot)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(Self.gitAbortRebaseArgs(), in: dir, timeout: refTimeout)
        })
    else { return .failed(.other("abort was cancelled")) }
    if let failure = Self.classify(result, action: .abortRebase, tool: vcs) {
      return .failed(failure)
    }
    return .ok(summary: "Rebase aborted")
  }
}
