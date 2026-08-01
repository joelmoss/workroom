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
  ///
  /// The payload is the lock file itself when we could find it on disk, and that distinction decides
  /// what the UI offers. **`nil` ⇒ transient contention**, so Retry is genuine: another command held the
  /// lock briefly and by the next click it is likely gone. **Non-nil ⇒ a lock file is sitting there
  /// right now**, and retrying fails identically every time — the same reasoning that makes
  /// `rebaseInProgress` offer Abort instead of Retry.
  ///
  /// A leftover lock is what a SIGKILLed git leaves: the runner escalates to `killTree` two seconds
  /// after SIGTERM, and SIGKILL cannot be caught, so git's own cleanup never runs.
  ///
  /// Workroom does NOT delete it. Whether a lock is truly abandoned or held by a git running right now
  /// is not knowable from outside the process — `lsof` can't be trusted for it, and removing a live
  /// lock corrupts the index — so this reports and explains, and the removal stays the user's call.
  /// That is also what git's own message tells you to do.
  case locked(VCSLockFile?)
  /// jj refused to rewrite a commit protected by `immutable_heads()` — reached by Pull, whose
  /// `jj rebase -b @` moves the whole branch containing `@`, and that branch usually contains a
  /// remote-tracked commit. Measured on jj 0.43 for a workroom based off a feature branch while trunk
  /// moved on: `Error: Commit 4c8e754829da is immutable`.
  ///
  /// Offers no retry, for `rebaseInProgress`'s reason: the destination doesn't change between clicks, so
  /// every retry fails identically. The real fix is remembering each workroom's own base instead of
  /// guessing `trunk()` — filed, not built.
  case immutableHistory(String)
  /// jj refuses to push a commit with an empty description, changes or not. This is the state a workroom
  /// sits in the moment you edit a file and before you write a message, so it is the most reachable
  /// failure on the push path, not an edge case. Measured: `Error: Won't push commit 050e657d3c36 since
  /// it has no description`.
  case needsDescription(String)
  case other(String)
}

/// A VCS remote action queued behind a confirmation. Only a pull over a dirty working tree needs one:
/// `--autostash` stashes and reapplies, and workroom trees are essentially always dirty, so this fires
/// most times someone pulls — the copy has to be worth reading rather than a speed bump.
///
/// Carries the `SidebarID` it was raised for, and `AppStore.runRemoteAction` verifies it: the dialog is
/// not modal to the sidebar, so the selection can move while it is open.
struct PendingVCSAction: Identifiable, Equatable, Sendable {
  let action: VCSRemoteAction
  let sid: SidebarID
  var id: String { "\(action.rawValue)-\(sid.hashValue)" }
}

/// A failure raised for the user's attention, carried to the failure dialog.
///
/// Only ever raised for a **user-initiated** action. The automatic fetch deliberately doesn't raise one:
/// it's a network call nobody asked for, so failing it must stay as quiet as succeeding it
/// (`RemoteStateModel.autoFetchIfDue`). It still records `lastFailure`, so the toolbar tells the story.
///
/// `sequence` is the identity, not the failure: presenting the same failure twice — a retry that fails
/// identically, or the user re-opening the details — must count as a NEW presentation, and a `.sheet(item:)`
/// keyed on the failure's own value would silently skip the second one.
struct VCSFailureReport: Identifiable, Equatable, Sendable {
  let failure: VCSRemoteFailure
  /// What was attempted, so the dialog's title can name it.
  let action: VCSRemoteAction?
  let sequence: Int
  var id: Int { sequence }
}

/// A lock file found blocking a VCS operation.
///
/// Located by parsing the path out of git's own error, which names it exactly, then stat-ing it — so the
/// file reported is the one git actually complained about rather than a guess at which lock it might be.
struct VCSLockFile: Equatable, Sendable {
  let path: String
  let modifiedAt: Date

  var filename: String { (path as NSString).lastPathComponent }
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
  /// **Everything except fetch runs in the workroom, including jj push.** It used to send jj push to the
  /// root on the grounds that bookmarks are repo-global. Bookmarks are — but `@` is not: it is
  /// WORKSPACE-scoped, resolved against the working directory. So `jj git push --change @` run at the root
  /// pushed the ROOT workspace's working copy and left the workroom's commit at home, while still
  /// returning `.ok` so the toolbar reported "Pushed to origin".
  ///
  /// Measured, root holding `ROOT-WORKSPACE-WORK` and workspace `wsA` holding `WORKROOM-WORK`: the push
  /// created `refs/heads/push-<root's change id>` carrying `ROOT-WORKSPACE-WORK`. Wrong commit published,
  /// the user's work never sent, success reported. `--bookmark` works from a secondary workspace too, so
  /// nothing needed the root.
  ///
  /// The integration test could not see this — it passes `path` and `projectRoot` as the same directory,
  /// which makes the two indistinguishable. `opDirectoryTests` now pins them as different.
  static func opDirectory(_ action: VCSRemoteAction, path: String, projectRoot: String) -> String {
    switch action {
    case .fetch: return projectRoot
    case .push, .pull, .abortRebase: return path
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

  /// The CONFIGURED remotes, one name per line.
  ///
  /// Deliberately separate from `gitRemoteRefsArgs`: remote-tracking refs prove a remote has been
  /// *fetched*, not that one is configured. `git remote add origin …` writes config and no refs, so a
  /// remotes list derived from `refs/remotes` reads as "No remote configured" on a repo that can push
  /// perfectly well. Config is the authority for "is there a remote"; the refs still answer "does my
  /// branch have a counterpart".
  static func gitRemoteListArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + ["remote"]
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
  /// `--` closes the option list. See `gitPushArgs` for why every builder in this file does that.
  static func gitFetchArgs(remote: String) -> [String] {
    WorkroomStatusResolver.gitHardening + ["fetch", "--", remote]
  }

  /// `--set-upstream` only when there is no counterpart yet; passing it on every push would rewrite
  /// `branch.<name>.remote`/`.merge` each time. **Never** `--force`/`--force-with-lease`: a rejection
  /// becomes `.rejected` and the UI offers Pull.
  ///
  /// `--porcelain` is what makes the rejection detectable without reading prose — see
  /// `gitPushRejected(stdout:)`. It moves a machine-readable per-ref line onto stdout and leaves
  /// stderr's hints alone, so nothing else about the failure path changes.
  /// **The branch is sent as a fully-qualified refspec, never as a bare operand.** An argv array stops
  /// SHELL injection; it does nothing about OPTION injection, and git parses options that appear after
  /// the positional remote.
  ///
  /// The whole chain is verified on git 2.55, not theorised. `refs/heads/--all` is a legal refname
  /// (`check-ref-format` accepts it; only the `--branch` shorthand refuses). A malicious remote that
  /// points its `HEAD` at that ref makes `git clone` create a LOCAL branch called `--all`, which is what
  /// `git branch --show-current` and therefore `GitProvider.currentRef` then report. Feeding that to
  /// `push <remote> <branch>` pushed **every** branch in the repo to the attacker's server — measured:
  /// `refs/heads/--all`, `refs/heads/private-work-1`, `refs/heads/private-work-2`. Since every workroom
  /// of a project is a `git worktree add -b` in the same repo, that is every workroom's branch. `--mirror`
  /// is worse still: it can delete remote refs that are absent locally.
  ///
  /// A `refs/heads/…:refs/heads/…` refspec cannot present as an option no matter what the name contains,
  /// and it also pins the push to this one ref regardless of `push.default`. `--` alone would fix THIS
  /// builder, but not the pull one (see `gitPullArgs`), so both use refspecs for one rule.
  static func gitPushArgs(branch: String, remote: String, setUpstream: Bool) -> [String] {
    WorkroomStatusResolver.gitHardening + ["push", "--porcelain"]
      + (setUpstream ? ["--set-upstream"] : [])
      + ["--", remote, "refs/heads/\(branch):refs/heads/\(branch)"]
  }

  /// Whether `push --porcelain` reported a rejected ref.
  ///
  /// Each porcelain line is `<flag>\t<from>:<to>\t<summary>`, and the flag is the contract: `!`
  /// rejected, ` ` updated, `*` new ref, `=` up to date, `-` deleted, `+` forced (we never force).
  ///
  /// This exists because the prose we used to match is translated and the flag is not. Homebrew git
  /// 2.55 under `fr_FR.UTF-8` answers `Les mises à jour ont été rejetées …` on stderr while stdout
  /// still reads `!\trefs/heads/master:refs/heads/master\t[rejected] (fetch first)` — measured, both
  /// locales. `StatusCommandRunner` pins `LC_ALL=C` so the prose match works today; this stops
  /// `.rejected` — the one failure whose recovery is a *different action* — depending on that pin.
  static func gitPushRejected(stdout: String) -> Bool {
    stdout.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("!\t") }
  }

  /// `--autostash` is mandatory, not a nicety: workroom trees are essentially always dirty, and
  /// without it every pull dies on "cannot pull with rebase: You have unstaged changes". The remote
  /// branch is explicit so a workroom with no configured upstream can still pull.
  ///
  /// **`--` is NOT enough here, which is why the branch is fully qualified.** Measured on git 2.55 with a
  /// local branch named `--upload-pack=<script>` (a legal refname, planted by a malicious remote's HEAD
  /// as `gitPushArgs` describes): `pull --rebase --autostash <remote> <branch>` ran the script, and so did
  /// `pull --rebase --autostash -- <remote> <branch>` — `git pull` forwards the refspec to fetch in a way
  /// that still parses it as an option. `pull … <remote> refs/heads/<branch>` did not, and neither did
  /// `fetch -- <remote> <branch>`. So the operand boundary is per-subcommand and cannot be reasoned about
  /// from `--` alone; a `refs/heads/` prefix can never look like an option, so that is the rule used.
  static func gitPullArgs(remote: String, branch: String) -> [String] {
    WorkroomStatusResolver.gitHardening
      + ["pull", "--rebase", "--autostash", "--", remote, "refs/heads/\(branch)"]
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

  /// The CONFIGURED remotes, `<name> <url>` per line.
  ///
  /// The same distinction `gitRemoteListArgs` documents, and jj makes it sharper: `jj git remote add`
  /// creates no remote bookmarks at all, so `bookmark list --all-remotes` on a freshly-remoted repo
  /// lists only local rows and `@git`, and the toolbar said "No remote configured" while
  /// `jj git remote list` showed origin.
  ///
  /// `--ignore-working-copy` is load-bearing for a second reason here: without it this command takes
  /// the **Git import/export** lock (verified, jj 0.43), which no other read in this file does.
  static func jjRemoteListArgs() -> [String] {
    ["git", "remote", "list"] + jjReadFlags
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

  /// Quote a name for interpolation into a revset.
  ///
  /// Bare interpolation is a real parse bug, not a hypothetical. Verified against jj 0.43: a remote
  /// named `a b`, `a)b` or `a:b` fails outright (`Failed to parse revset: Syntax error`), and — worse —
  /// `a|b` *succeeds* as the UNION of two patterns, so the count comes back wrong with no error to
  /// notice. Quoting fixes all of them.
  ///
  /// `\` is escaped before `"`, so the backslash pass cannot re-escape the escapes the quote pass adds.
  static func jjQuote(_ name: String) -> String {
    let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// The base an unbookmarked `@` is measured — and rebased — against.
  ///
  /// `trunk()` is jj's own alias, so this defers to the user's `revset-aliases.'trunk()'` when they've
  /// set one and to jj's default (the latest of `main`/`master`/`trunk` on a remote) when they haven't.
  /// Verified to degrade quietly: in a repo whose only remote bookmark was `weird-name`, `trunk()`
  /// resolved without error and `@..trunk()` counted 0, so an unusual repo reports "not behind" rather
  /// than a failure.
  ///
  /// One literal, shared by `jjBehindRevset` and `jjRebaseDestination`, because the count and the button
  /// have to mean the same thing.
  static let jjTrunkRevset = "trunk()"

  /// Commits of ours that no remote bookmark has — what a push would send.
  ///
  /// Scoped to ALL of the remote's bookmarks on purpose, unlike `jjBehindRevset`: a commit already
  /// reachable from some other remote branch IS pushed, so it must not count as ahead.
  ///
  /// The `~(empty() && description(exact:""))` filter is `jjPushRevision`'s rule expressed as a revset —
  /// jj won't push a commit with no changes AND no description, and a workroom's `@` after `jj new` is
  /// exactly that, so without this every clean workroom read as "1 to push". `~empty()` alone is NOT
  /// equivalent and undercounts: describe an empty `@` and jj will push it while `~empty()` reports 0.
  /// Both measured on jj 0.43.
  static func jjAheadRevset(remote: String) -> String {
    "(remote_bookmarks(remote=\(jjQuote(remote)))..@) & ~(empty() & description(exact:\"\"))"
  }

  /// Commits on the main line that we don't have — what a pull would bring.
  ///
  /// **Measured against `trunk()`, not against every remote bookmark.** It used to be
  /// `@..remote_bookmarks(remote=…)`, which counts every commit on every remote branch that isn't in
  /// `@`'s ancestry — so a repo with unmerged feature branches reported their commits as "to pull" while
  /// sitting exactly on the tip of master. Reproduced on jj 0.43: with `@-` equal to `master@origin`,
  /// origin holding master and one unmerged `feat`, that revset counted 3 and named `feat1`/`feat2`/
  /// `feat3`; `@..trunk()` counted 0. The equivalent git query has always been scoped to one branch
  /// (`HEAD...refs/remotes/<remote>/<branch>`), so this also ends an asymmetry between the backends.
  static let jjBehindRevset = "@..\(jjTrunkRevset)"

  /// Where a jj pull rebases `@`.
  ///
  /// A bookmarked `@` goes onto its own remote counterpart. An unbookmarked one has no counterpart —
  /// `VCSTracking.comparedTo` carries the bare remote name as the sentinel for that state — and goes onto
  /// `trunk()`, the same base its behind count is measured from.
  ///
  /// That second case used to return early without rebasing at all, so Pull fetched and stopped: the
  /// toolbar offered "Pull" beside a count the button could not act on. git's Pull has always been
  /// pull-and-rebase, and this is what makes jj's the same operation.
  static func jjRebaseDestination(comparedTo: String?, remote: String) -> String {
    guard let comparedTo, comparedTo != remote else { return jjTrunkRevset }
    return comparedTo
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

  /// `git remote` output → remote names, listed order preserved.
  static func parseGitRemoteList(_ stdout: String) -> [String] {
    var remotes: [String] = []
    for line in stdout.split(whereSeparator: \.isNewline) {
      let name = line.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !remotes.contains(name) else { continue }
      remotes.append(name)
    }
    return remotes
  }

  /// `jj git remote list` output (`<name> <url>` per line) → remote names, listed order preserved.
  ///
  /// Split on the LAST space, not the first: jj accepts a remote name containing spaces (the same
  /// permissiveness `jjQuote` exists for), while a URL has none.
  static func parseJJRemoteList(_ stdout: String) -> [String] {
    var remotes: [String] = []
    for line in stdout.split(whereSeparator: \.isNewline) {
      let row = String(line)
      guard let lastSpace = row.lastIndex(of: " ") else { continue }
      let name = String(row[row.startIndex..<lastSpace])
      // `git` is jj's colocated pseudo-remote, not a server. `jj git remote list` doesn't list it
      // (verified, jj 0.43) and `parseJJBookmarks` drops it — dropped here too so the invariant holds
      // wherever the name comes from.
      guard !name.isEmpty, name != "git", !remotes.contains(name) else { continue }
      remotes.append(name)
    }
    return remotes
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
    // Flag column first, prose second. The string checks stay as a fallback rather than being replaced:
    // `--porcelain` is ours to pass on the push path only, so a rejection surfaced by any other route
    // (a remote helper, a future caller that forgets the flag) still classifies.
    if gitPushRejected(stdout: result.stdout) || err.contains("Updates were rejected")
      || err.contains("! [rejected]")
    {
      return .rejected(err)
    }
    // Both jj-only, and both permanent until the user acts — so they must NOT reach `.other`, whose
    // recovery is a retry of the same doomed command. jj doesn't localize, so matching its prose is safe
    // here in a way it wouldn't be for git.
    if err.contains("since it has no description") || err.contains("has no description") {
      return .needsDescription(err)
    }
    if err.contains("is immutable") || err.contains("immutable commits") {
      return .immutableHistory(err)
    }
    if err.contains("Failed to take lock for Git import/export")
      || (err.contains(".lock")
        && (err.contains("could not be obtained") || err.contains("File exists")
          || err.contains("Unable to create")))
    {
      return .locked(lockFile(in: err))
    }
    if action == .pull, rebaseInProgress(gitDir: gitDir) { return .rebaseInProgress }
    // A lock failure that never names a lock. git's message depends on WHICH internal step hit the lock:
    // a fast-forward pull reports `Unable to create '<path>': File exists.`, but a pull that must really
    // rebase fails in autostash first and says only `error: could not write index` / `fatal: Cannot
    // autostash` — no path, no "lock", nothing the checks above can match. That is the diverged pull,
    // i.e. exactly what the toolbar's Pull button is for, and it was landing in `.other` with raw stderr.
    //
    // So when the symptoms are lock-shaped, ask the DISK instead of the message. Deliberately last: any
    // failure git explains properly keeps its own classification, and this only speaks for the ones it
    // doesn't.
    if lockSymptom(err), let lock = existingLockFile(gitDir: gitDir) { return .locked(lock) }
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

  /// The lock file a failure is complaining about, or nil if we can't point at one.
  ///
  /// The path is taken from git's OWN message rather than guessed: git names the exact file it couldn't
  /// create (`fatal: Unable to create '<path>': File exists.`), and a repo has several lock files that
  /// mean different things — `index.lock`, `packed-refs.lock`, `HEAD.lock`, `config.lock`. Naming the
  /// wrong one would send someone to delete a file that isn't the problem.
  ///
  /// Returns nil for jj's import/export lock, whose message carries no path, and — deliberately — when
  /// the named file no longer exists: a lock that cleared between the failure and this check WAS
  /// transient contention, which is exactly the case where Retry is the right offer.
  static func lockFile(in stderr: String) -> VCSLockFile? {
    guard let path = parseLockPath(stderr) else { return nil }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let modified = attrs[.modificationDate] as? Date
    else { return nil }
    return VCSLockFile(path: path, modifiedAt: modified)
  }

  /// Whether a failure LOOKS like it was caused by a lock, without saying so.
  ///
  /// Narrow on purpose. These are the symptoms git reports when it fails to take a lock through a path
  /// that doesn't print the lock's name; anything broader would start blaming a lock file that happens to
  /// exist for failures it had nothing to do with.
  static func lockSymptom(_ stderr: String) -> Bool {
    stderr.contains("could not write index") || stderr.contains("Cannot autostash")
      || stderr.contains("cannot lock ref") || stderr.contains("Unable to write")
  }

  /// The lock files a repo can be blocked by, newest-relevant first. `index.lock` lives in the WORKTREE's
  /// own git dir; `packed-refs.lock` and `config.lock` live in the COMMON dir that every worktree shares.
  static let knownLockNames = ["index.lock", "packed-refs.lock", "HEAD.lock", "config.lock"]

  /// The first lock file actually present in this repo, checking both the worktree's git dir and the
  /// common one — a workroom is a `git worktree`, so its `index.lock` and the repo's `packed-refs.lock`
  /// are in different directories.
  static func existingLockFile(gitDir: URL?) -> VCSLockFile? {
    guard let gitDir else { return nil }
    let fm = FileManager.default
    var dirs = [gitDir]
    // `<common>/worktrees/<name>` → `<common>`. Cheap and string-only; `commonGitDir` does the same trip
    // from a path rather than from an already-resolved git dir.
    if gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
      dirs.append(gitDir.deletingLastPathComponent().deletingLastPathComponent())
    }
    for dir in dirs {
      for name in knownLockNames {
        let candidate = dir.appendingPathComponent(name)
        guard let attrs = try? fm.attributesOfItem(atPath: candidate.path),
          let modified = attrs[.modificationDate] as? Date
        else { continue }
        return VCSLockFile(path: candidate.path, modifiedAt: modified)
      }
    }
    return nil
  }

  /// The quoted path out of git's lock errors. Pure, so the parsing is testable without a repo.
  ///
  /// Covers both phrasings that quote a path — the bare `Unable to create '<path>'` and the ref-update
  /// form (`error: cannot lock ref 'refs/…': Unable to create '<path>.lock': File exists`), which nests
  /// two quoted strings and must yield the second.
  static func parseLockPath(_ stderr: String) -> String? {
    guard let marker = stderr.range(of: "Unable to create '") else { return nil }
    let rest = stderr[marker.upperBound...]
    guard let close = rest.firstIndex(of: "'") else { return nil }
    let path = String(rest[..<close])
    // Only ever report an absolute path to a `.lock`: a relative one would be meaningless to a user
    // reading it out of a tooltip, and a non-`.lock` match means the phrasing wasn't what we assumed.
    guard path.hasPrefix("/"), path.hasSuffix(".lock") else { return nil }
    return path
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
    let list = await run(Self.gitRemoteListArgs(), in: path, timeout: refTimeout)
    let remotes = Self.mergeRemotes(
      configured: list.ok ? Self.parseGitRemoteList(list.stdout) : [], derived: parsed.remotes)
    let primary = Self.primaryRemote(remotes)
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
        current: current, tracking: tracking, remotes: remotes, primaryRemote: primary,
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
    let remoteList = await run(Self.jjRemoteListArgs(), in: path, timeout: refTimeout)
    let remotes = Self.mergeRemotes(
      configured: remoteList.ok ? Self.parseJJRemoteList(remoteList.stdout) : [],
      derived: parsed.remotes)
    let primary = Self.primaryRemote(remotes)
    var tracking: VCSTracking?
    if let primary {
      switch current.kind {
      case .branch:
        if let name = current.name {
          // No `@<remote>` row for this bookmark ⇒ it has never been pushed. Reported as `gone`, exactly
          // as the git path reports a missing counterpart, so the toolbar offers Publish. Leaving it nil
          // fell through to the fetch tier, which offered a Fetch that can never produce the counterpart
          // — the permanent dead end a freshly-remoted repo landed in.
          tracking =
            parsed.bookmarks.first { $0.name == name }?.tracking
            ?? VCSTracking(
              comparedTo: "\(name)@\(primary)", ahead: nil, behind: nil, gone: true)
        }
      // `.none` belongs with `.ancestor`, and leaving it out was a bug that hid the exact case this
      // toolbar exists for. `jj git fetch` fast-forwards a tracked local bookmark, so as soon as the
      // main line moves, an unbookmarked `@`'s ancestry contains no bookmark at all and `currentRef`
      // drops from `.ancestor` to `.none`. Sending that to `tracking = nil` meant the counts, the pills
      // and `canPull` all vanished at the moment the workroom first became behind — the toolbar went
      // quiet precisely when it had something to say. The revsets below never needed a bookmark to
      // begin with; `.detached` still yields nil, since that's git's shape and has no jj meaning.
      case .ancestor, .none:
        // `@` carries no bookmark — the normal workroom state, since `jj workspace add --name` creates
        // no bookmark. The bookmark row's counts would describe the ANCESTOR, not the user's work, so
        // count the actual revsets instead. The two are deliberately scoped differently: ahead against
        // every remote bookmark (anything already pushed anywhere isn't ahead), behind against `trunk()`
        // alone (see `jjBehindRevset` — the all-bookmarks form counted other branches' work as ours to
        // pull). Both agree with what the buttons do: `jjPushRevision` and `jjRebaseDestination`.
        let ahead = await run(
          Self.jjRevsetCountArgs(Self.jjAheadRevset(remote: primary)), in: path, timeout: refTimeout
        )
        let behind = await run(
          Self.jjRevsetCountArgs(Self.jjBehindRevset), in: path, timeout: refTimeout)
        tracking = VCSTracking(
          comparedTo: primary,
          ahead: ahead.ok ? Self.countLines(ahead.stdout) : nil,
          behind: behind.ok ? Self.countLines(behind.stdout) : nil,
          gone: false)
      case .detached:
        tracking = nil
      }
    }
    // jj's fetch is invisible to `FETCH_HEAD` (it passes `--no-write-fetch-head`), so scan the op log.
    let ops = await run(Self.jjOpLogArgs(), in: path, timeout: refTimeout)
    let lastFetch = ops.ok ? Self.parseJJFetchOp(ops.stdout) : nil
    return .state(
      VCSRemoteState(
        current: current, tracking: tracking, remotes: remotes, primaryRemote: primary,
        lastFetch: lastFetch.map { .at($0) } ?? (ops.ok ? .never : .unknown),
        resolvedAt: Date()))
  }

  /// `origin` when it exists, else the first remote, else nil. Origin-scoped by default, matching the
  /// deliberate choice `VCSPushState` documents.
  static func primaryRemote(_ remotes: [String]) -> String? {
    remotes.contains("origin") ? "origin" : remotes.first
  }

  /// Configured remotes, plus any ref-derived name config didn't mention.
  ///
  /// A union rather than a replacement so a failed remote-list call degrades to the old ref-derived
  /// answer instead of blanking a toolbar that was working — the same "a blip must not blank a good
  /// toolbar" rule the resolution paths follow. Configured order comes first, so `primaryRemote`'s
  /// first-listed fallback picks a real remote over a stale ref's.
  static func mergeRemotes(configured: [String], derived: [String]) -> [String] {
    configured + derived.filter { !configured.contains($0) }
  }

  static func countLines(_ stdout: String) -> Int {
    stdout.split(whereSeparator: \.isNewline).count
  }

  // MARK: - Actions

  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult {
    let dir = Self.opDirectory(.fetch, path: path, projectRoot: projectRoot)
    let args = vcs == "jj" ? Self.jjFetchArgs(remote: remote) : Self.gitFetchArgs(remote: remote)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: fetchTimeout, network: true)
        })
    else { return .failed(.other("fetch was cancelled")) }
    if let failure = Self.classify(
      result, action: .fetch, tool: vcs, gitDir: Self.worktreeGitDir(at: path))
    {
      return .failed(failure)
    }
    return .ok(summary: "Fetched \(remote)")
  }

  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool,
    anonymousRevision: String
  ) async -> VCSRemoteActionResult {
    let dir = Self.opDirectory(.push, path: path, projectRoot: projectRoot)
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
    if let failure = Self.classify(
      result, action: .push, tool: vcs, gitDir: Self.worktreeGitDir(at: path))
    {
      return .failed(failure)
    }
    return .ok(summary: "Pushed to \(remote)")
  }

  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String,
    tracking: VCSTracking?
  ) async -> VCSRemoteActionResult {
    // Both backends fetch first, at the project root, for the reasons `opDirectory` documents. For git
    // `pull` would fetch too, but doing it explicitly at the root keeps `FETCH_HEAD` — and so the
    // "last fetched" label — correct for every workroom of the project.
    // Hoisted above the fetch: BOTH steps classify against it, since a lock can block either one.
    let gitDir = Self.worktreeGitDir(at: path)
    let fetchDir = Self.opDirectory(.fetch, path: path, projectRoot: projectRoot)
    let fetchArgs =
      vcs == "jj" ? Self.jjFetchArgs(remote: remote) : Self.gitFetchArgs(remote: remote)
    guard
      let fetched = await gated(
        projectRoot,
        { [self] in
          await run(fetchArgs, in: fetchDir, timeout: fetchTimeout, network: true)
        })
    else { return .failed(.other("pull was cancelled")) }
    if let failure = Self.classify(fetched, action: .pull, tool: vcs, gitDir: gitDir) {
      return .failed(failure)
    }

    let dir = Self.opDirectory(.pull, path: path, projectRoot: projectRoot)
    let args: [String]
    if vcs == "jj" {
      // Always rebases now. An unbookmarked `@` falls back to `trunk()` rather than returning early:
      // fetching moves the remote bookmarks but does NOT move `@`, so stopping there left the workroom
      // as far behind as it started while the toolbar went on offering Pull. Already a descendant of the
      // destination is not an error — jj prints "Nothing changed." and exits 0.
      args = Self.jjRebaseArgs(
        onto: Self.jjRebaseDestination(comparedTo: tracking?.comparedTo, remote: remote))
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
    let dir = Self.opDirectory(.abortRebase, path: path, projectRoot: projectRoot)
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
