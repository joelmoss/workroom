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

// MARK: - Commit

/// Which commit verb to run. Deliberately NOT folded into `VCSRemoteAction`: that enum feeds
/// `VCSRemoteFailure.timedOut`, `PendingVCSAction` and the toolbar's labels, none of which mean
/// anything for a purely local write.
///
/// The cases are backend-scoped and the writer rejects a mismatch with `.unsupportedMode` rather
/// than silently issuing the wrong command:
/// - `.commit` — both backends.
/// - `.amendMessage` — git only. jj's analogue is `.describe`, which is not the same operation.
/// - `.describe` — jj only. Sets `@`'s description and stays on it.
enum VCSCommitMode: String, Equatable, Sendable {
  case commit, amendMessage, describe
}

/// One commit, fully specified. `files` carries `ChangedFile` rather than `String` because a rename
/// needs BOTH sides of the pathspec — see `gitPathspecPayload`.
struct VCSCommitRequest: Equatable, Sendable {
  let message: String
  /// The user's selection. Empty for jj, which has no index and commits the whole change.
  let files: [ChangedFile]
  let mode: VCSCommitMode
}

enum VCSCommitResult: Equatable, Sendable {
  case ok(summary: String, revision: String?)
  /// The ref MOVED but the command still reported failure — a `post-commit` hook that fails or hangs
  /// past the timeout is the reachable case. Distinct from `.failed` because the recovery is
  /// opposite: retrying would create a SECOND commit.
  case committedThenFailed(revision: String, detail: String)
  case failed(VCSCommitFailure)
}

/// Why a commit failed. Separate from `VCSRemoteFailure` for the reason that enum documents about
/// `VCSError`: its `.timedOut` carries a `VCSRemoteAction`, and commit is not a remote action, so
/// reusing it would force a meaningless value.
enum VCSCommitFailure: Equatable, Sendable {
  case toolMissing(String)
  case timedOut
  /// Nothing staged/changed for the selection. jj reports this as an ordinary success ("Nothing
  /// changed."), so the writer maps it rather than surfacing a phantom commit.
  case nothingToCommit
  /// `user.name`/`user.email` unset — git cannot build a signature.
  case identityMissing(String)
  /// gpg/ssh signing refused. With stdin on `/dev/null` this fails FAST rather than hanging, so it
  /// is a classifiable outcome and not a timeout — see `commitSigningMarkers`.
  case signingFailed(String)
  /// A `pre-commit`/`commit-msg` hook rejected it. **Matched, never a catch-all** — a catch-all
  /// mislabels signing failures, config errors and index corruption, sending users to the wrong fix.
  case hookRejected(String)
  case unmergedFiles(String)
  /// A merge, cherry-pick, revert, rebase or bisect is parked in this worktree. Path-limited commits
  /// are invalid during several of these, and finishing the sequencer is the user's call.
  case sequencerInProgress(String)
  case locked(VCSLockFile?)
  /// The verb doesn't exist for this backend (`.amendMessage` on jj, `.describe` on git).
  case unsupportedMode
  case other(String)
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

  /// Record a commit. **Local**, unlike everything above it, so it takes no `remote` and never runs
  /// through `runNetwork` — but it lands here rather than on `VCSProviding` for the reason this
  /// protocol's own doc gives: writes belong behind the gate, and a read seam that could commit is
  /// exactly what that separation prevents.
  ///
  /// Always runs in the **workroom**, both backends. `opDirectory` records the measured bug where a
  /// jj write at the project root operated on the ROOT workspace's `@` and reported success; a
  /// commit at the root would publish the wrong workspace's work in the same way.
  func commit(path: String, projectRoot: String, request: VCSCommitRequest) async -> VCSCommitResult

  /// Selected paths whose STAGED content a commit would silently discard, so the caller can confirm
  /// first. Empty when there is nothing at risk. See `CLIVCSWriter.stagedContentAtRisk`.
  func stagedContentAtRisk(path: String, files: [ChangedFile]) async -> [String]
}

extension VCSWriting {
  /// Test doubles and the fixture have no index to put anything at risk — same reasoning as
  /// `runNetwork`'s default, so they stay short.
  func stagedContentAtRisk(path: String, files: [ChangedFile]) async -> [String] { [] }
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
  /// Deliberately generous, and deliberately NOT tuned down. A `pre-commit` hook that runs a linter
  /// or a test suite routinely takes minutes, and `StatusCommandRunner` escalates to `killTree` two
  /// seconds after SIGTERM — SIGKILL is uncatchable, so git's own cleanup never runs and an
  /// `index.lock` is left behind. Workroom deliberately never deletes that file (see
  /// `VCSRemoteFailure.locked`), so a too-short limit here would wedge every later commit *and*
  /// every status probe until the user removed it by hand. Killing a commit is categorically more
  /// dangerous than killing a fetch.
  var commitTimeout: TimeInterval = 600

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

  // MARK: - git commit argument builders

  /// The NUL-separated pathspec payload for `--pathspec-from-file=-`, written to the child's stdin.
  ///
  /// Three things here are load-bearing, and all three were **measured** on git 2.x rather than
  /// reasoned about:
  ///
  /// 1. **A rename contributes BOTH sides.** `ChangedFile` carries `oldPath`, and the status layer
  ///    pairs renames (`.renamesIndex`/`.renamesWorkingTree`), so one row means two paths. Sending
  ///    only `path`: `mv old new` then committing `new` recorded an **add** and left `D old`
  ///    dangling in the worktree — staged, if the rename came from `git mv`. The user ticked one row
  ///    labelled `old → new` and got half a rename plus a mess.
  ///
  /// 2. **Every entry is `:(literal)`-prefixed.** `--` ends OPTION parsing, not MAGIC parsing, and
  ///    `--pathspec-file-nul` does NOT disable globbing either — its "taken literally" refers to the
  ///    absence of C-quoting in the file format, not to pathspec magic. Measured with `ab.txt` and
  ///    `a[b].txt` both modified: sending `a[b].txt` committed BOTH. A file named `*` would commit
  ///    the whole tree. `:(literal)` is what actually turns it off (verified: commits only the
  ///    bracketed file), and it still parses under `--pathspec-file-nul`.
  ///
  /// 3. **NUL separation, so no path needs escaping** — newlines and quotes in filenames pass
  ///    through unharmed, and thousands of long paths cannot blow the `E2BIG` argv ceiling at spawn,
  ///    where git would never get to emit anything classifiable.
  ///
  /// Order-preserving dedup: a rename whose `oldPath` is also its own `path` (or two rows naming the
  /// same file) must not send a duplicate.
  static func gitPathspecPayload(_ files: [ChangedFile]) -> Data {
    var seen = Set<String>()
    var out = Data()
    for file in files {
      for path in [file.path, file.oldPath].compactMap({ $0 }) where !path.isEmpty {
        guard seen.insert(path).inserted else { continue }
        out.append(contentsOf: Array(":(literal)\(path)".utf8))
        out.append(0)
      }
    }
    return out
  }

  /// The same payload, from paths that are already just paths.
  ///
  /// Used by the intent-to-add step, which must send **only the new side** of a rename. The old side
  /// no longer exists on disk, and `git add` rejects a pathspec matching nothing — `fatal: pathspec
  /// ':(literal)old.txt' did not match any files` — which would fail the whole commit at the step
  /// meant to make it possible. `commit --only` is the opposite: it needs both sides, so the two
  /// steps deliberately do not share a payload.
  static func gitPathspecPayload(literalPaths: [String]) -> Data {
    var seen = Set<String>()
    var out = Data()
    for path in literalPaths where !path.isEmpty {
      guard seen.insert(path).inserted else { continue }
      out.append(contentsOf: Array(":(literal)\(path)".utf8))
      out.append(0)
    }
    return out
  }

  /// Make selections git may not know about committable — see `pathsGitMayNotKnow`.
  ///
  /// `git commit --only` refuses a path git has never seen — measured: `error: pathspec
  /// 'untracked.txt' did not match any file(s) known to git`. `--intent-to-add` records an empty
  /// entry, which is enough for `--only` to then take the file's real contents (verified).
  ///
  /// This is the **only** index mutation the commit path performs, and it is undone by
  /// `gitUnstageArgs` when the commit that follows it fails. Tracked files are never staged — see
  /// `gitCommitOnlyArgs`.
  static func gitIntentToAddArgs() -> [String] {
    WorkroomStatusResolver.gitHardening
      + ["add", "--intent-to-add", "--pathspec-from-file=-", "--pathspec-file-nul"]
  }

  /// Undo `gitIntentToAddArgs` for paths that were untracked, after a failed commit.
  ///
  /// `--cached` so only the index entry goes and the file itself is untouched — it returns to being
  /// untracked, exactly as the user left it. `--ignore-unmatch` so a path something else removed in
  /// the meantime cannot turn cleanup into a second error on top of the one being reported.
  static func gitUnstageArgs() -> [String] {
    WorkroomStatusResolver.gitHardening
      + [
        "rm", "--cached", "--quiet", "--ignore-unmatch", "--pathspec-from-file=-",
        "--pathspec-file-nul",
      ]
  }

  /// Commit exactly the selection, from the WORKTREE, without touching the index for tracked paths.
  ///
  /// `--only` is the whole point and was chosen on measurement: with a pre-staged `other.txt` and a
  /// selection of `tracked.txt`, this committed only `tracked.txt` and left `other.txt` **still
  /// staged** (`M ` in porcelain). A `git add <selection>` + bare `git commit` would have swept that
  /// staged file into the user's commit, which is the "absorbs a partially-staged index" bug the
  /// selection model exists to prevent — reintroduced by the fix.
  ///
  /// The message goes in **argv**, not stdin, because stdin is already carrying the pathspec and a
  /// process has one of them. `-m` accepts embedded newlines fine, so a summary + body is one
  /// argument. Note `--cleanup` still applies: git strips trailing whitespace and collapses runs of
  /// blank lines, so what is recorded can differ slightly from what was typed.
  static func gitCommitOnlyArgs(message: String) -> [String] {
    WorkroomStatusResolver.gitHardening
      + ["commit", "--only", "--pathspec-from-file=-", "--pathspec-file-nul", "-m", message]
  }

  /// Reword the last commit and change **nothing else**.
  ///
  /// `--only` with no pathspec is what makes that true. Measured without it: `git add sneaky.txt &&
  /// git commit --amend -m "…"` absorbed `sneaky.txt` into the amended commit. In a dialog whose
  /// entire premise is that you choose what gets recorded, an Amend that silently commits whatever
  /// happens to be staged is the same defect wearing a different verb.
  static func gitAmendMessageArgs(message: String) -> [String] {
    WorkroomStatusResolver.gitHardening + ["commit", "--amend", "--only", "-m", message]
  }

  /// Porcelain status for the staged-content guard.
  ///
  /// `-z` because a filename can contain a newline, and without it git also C-quotes non-ASCII names
  /// — both would desync the parse. Deliberately takes NO pathspec: `git diff`/`git status` do not
  /// accept `--pathspec-from-file` (measured: `error: invalid option`), and passing thousands of
  /// paths as argv is the `E2BIG` problem the commit path avoids. One unfiltered read plus an
  /// in-memory filter is cheaper and cannot fail on an odd name.
  static func gitStatusPorcelainArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + ["status", "--porcelain", "-z"]
  }

  /// Which of `paths` hold staged content that committing would DISCARD.
  ///
  /// `git commit --only` builds the commit from the **worktree**, so for a selected path whose index
  /// differs from both HEAD and the worktree, the staged intermediate is bypassed and then lost.
  /// That is precisely what someone who ran `git add -p` has: a half-staged file they are still
  /// editing. Measured — the staged hunk vanished with a clean `git status` afterwards and no warning.
  ///
  /// Porcelain's two columns already encode it, so no extra command is needed:
  /// `X` is HEAD→index and `Y` is index→worktree, giving `MM f.txt` (at risk), `M  h.txt` (staged and
  /// identical to disk — safe) and ` M g.txt` (never staged — safe). `?` is untracked, which has no
  /// staged state to lose.
  ///
  /// Pure, so the whole rule is testable without a repo.
  static func stagedContentAtRisk(porcelainZ: String, selecting paths: Set<String>) -> [String] {
    var atRisk: [String] = []
    var fields = porcelainZ.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var index = 0
    while index < fields.count {
      let entry = fields[index]
      index += 1
      guard entry.count > 3 else { continue }
      let chars = Array(entry)
      let x = chars[0]
      let y = chars[1]
      let path = String(chars[3...])
      // A rename or copy spends a SECOND field on its old path. Consuming it keeps the walk aligned;
      // without this every entry after the first rename would be read as a status code.
      if x == "R" || x == "C" { index += 1 }
      guard paths.contains(path) else { continue }
      // Staged content exists (X is neither unmodified nor untracked) AND the worktree has moved on
      // from it (Y is not unmodified) ⇒ `--only` will take the worktree copy and drop the staged one.
      if x != " " && x != "?" && y != " " { atRisk.append(path) }
    }
    return atRisk
  }

  /// `HEAD`'s commit id, or nil when there isn't one (an unborn branch, i.e. a repo with no commits).
  /// Used to tell "the commit didn't happen" from "the commit happened and something after it
  /// failed" — see `VCSCommitResult.committedThenFailed`.
  static func gitHeadArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + ["rev-parse", "--verify", "HEAD"]
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

  /// Describe `@` and start a new empty change on top of it — jj's analogue of a git commit.
  ///
  /// **No pathspec, deliberately.** jj has no index: it commits the whole change. Its path arguments
  /// are a *fileset expression language*, not a list, and interpolating a plain path into one is the
  /// bug `jjQuote` already documents for revsets — measured on jj 0.43, `jj commit -- 'a (copy).txt'`
  /// fails to parse outright, and a fileset that matches nothing **still creates an empty commit and
  /// exits 0**, so the UI would report a commit that recorded nothing. Since partial selection is not
  /// offered for jj (it would need `jj split`), the parameter would carry all that risk to buy
  /// nothing at all.
  /// The message rides ATTACHED (`--message=…`), never as a detached `-m` value: jj's parser reads a
  /// detached value that begins with `-` as another flag, so `-m "-fix the parser"` dies with
  /// `error: unexpected argument '-f' found` where the attached form records it verbatim (measured,
  /// jj 0.43). git tolerates the detached form, but this side has no `--` to fall back on, so the
  /// option boundary has to live in the argument itself.
  static func jjCommitArgs(message: String) -> [String] {
    ["commit", "--message=\(message)"] + jjWriteFlags
  }

  /// Set `@`'s description and stay on it. Not an amend and not a commit — the third jj verb, which
  /// git has no equivalent of. Attached `--message=` for the reason `jjCommitArgs` records.
  static func jjDescribeArgs(message: String) -> [String] {
    ["describe", "--message=\(message)"] + jjWriteFlags
  }

  /// `@`'s full description, for prefilling the dialog.
  ///
  /// Read-only, so it carries `jjReadFlags`: without `--ignore-working-copy` this would snapshot the
  /// working copy and take its lock, ungated, just to populate a text field.
  ///
  /// The FULL description, not `JJCommitChanges.description`, which is only the first line — filling
  /// the summary from that and then running Describe would silently discard the message body.
  static func jjDescriptionArgs() -> [String] {
    ["log", "-r", "@", "--no-graph"] + jjReadFlags + ["-T", "description"]
  }

  /// The jj operation id at the head of the op log, for the same before/after comparison
  /// `gitHeadArgs` serves.
  static func jjOpHeadArgs() -> [String] {
    ["op", "log", "--no-graph"] + jjReadFlags + ["--limit", "1", "-T", "self.id().short()"]
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

  /// Signing failures. With `standardInput` on `/dev/null` gpg cannot reach a TTY pinentry, so it
  /// fails FAST with these rather than hanging — which is why the plan carries no signing preflight:
  /// predicting whether pinentry needs a terminal is undecidable (it depends on `gpg-agent.conf`,
  /// the agent's cache state and whether a smartcard is present), and this is decidable.
  static let commitSigningMarkers = [
    "gpg failed to sign the data", "failed to write commit object",
    "Inappropriate ioctl for device", "error: unable to sign the commit",
    "user.signingkey", "secret key not available",
  ]

  /// Missing `user.name`/`user.email`. git's own message tells the user exactly what to run, so the
  /// value is carried through rather than replaced.
  static let commitIdentityMarkers = [
    "Please tell me who you are", "unable to auto-detect email address",
    "empty ident name", "no email was given",
  ]

  /// git's phrasings, matched only on the FAILURE path — see `classifyCommit`. jj's exit-zero no-op
  /// is not in here on purpose; it needs the whole-line check below.
  static let commitNothingMarkers = [
    "nothing to commit", "no changes added to commit", "nothing added to commit",
  ]

  /// jj's no-op marker, as a whole line rather than a substring.
  ///
  /// jj echoes the change's description back in its `Working copy (@) now at:` and `Parent commit
  /// (@-)` lines, so a `contains` here would fire on any commit whose own message happened to carry
  /// the phrase — reporting a successful write as a no-op.
  /// Both streams are checked. jj 0.43 writes this (and everything else) to stderr, but the whole-line
  /// anchor is what makes the match safe, not the choice of stream — so covering stdout too costs
  /// nothing and survives jj moving it.
  static func saysNothingChanged(_ result: CommandResult) -> Bool {
    let lines = (result.stderr + "\n" + result.stdout).split(
      separator: "\n", omittingEmptySubsequences: false)
    return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "Nothing changed." }
  }

  static let commitUnmergedMarkers = [
    "you have unmerged files", "Committing is not possible because you have unmerged files",
    "needs merge",
  ]

  /// Hook rejection. **An explicit marker set, never the `else` branch.** A catch-all here would
  /// relabel signing failures, bad config, index corruption and message-policy errors as "a hook
  /// rejected this", which is worse than saying nothing: it sends the user to edit a hook that was
  /// never involved. Anything unmatched stays `.other`, carrying git's own words.
  static let commitHookMarkers = [
    "hook declined", "pre-commit hook", "commit-msg hook", "prepare-commit-msg hook",
    "hook exited with", "hook returned",
  ]

  /// Map a failed commit to a typed failure. `nil` means success.
  ///
  /// `movedRef` says the ref changed even though the command reported failure — the caller turns
  /// that into `.committedThenFailed` rather than a failure, because retrying would make a SECOND
  /// commit. The reachable case is a `post-commit` hook: git has already written the commit and
  /// moved `HEAD` by the time it runs, so a hook that fails or runs past the timeout leaves a
  /// perfectly good commit behind a non-zero exit.
  static func classifyCommit(_ result: CommandResult, tool: String) -> VCSCommitFailure? {
    if result.exitCode == CommandResult.commandNotFound { return .toolMissing(tool) }
    // jj says "Nothing changed." and exits ZERO, so its no-op has to be read BEFORE the success
    // guard — an untouched working copy must not be reported as a commit that happened.
    //
    // Scoped to jj, matched on a whole stderr line, and never against stdout. All three matter:
    // `git commit` echoes the SUBJECT on stdout, so the substring form this replaces classified
    // `-m "explain the nothing to commit error"` — a commit that succeeded, exit 0 — as a failure,
    // and `commit()` then upgraded it to `.committedThenFailed` because the ref had legitimately
    // moved. The dialog told the user their commit had half-worked when it was perfect. jj puts
    // everything on stderr including its own echo of the description (`Parent commit (@-) … <msg>`),
    // hence the whole-line anchor rather than `contains`. Measured on git 2.55 / jj 0.43.
    if tool == "jj", result.ok, saysNothingChanged(result) { return .nothingToCommit }
    if result.timedOut { return .timedOut }
    guard !result.ok else { return nil }

    // Only now, on a genuine failure, is matching the combined output safe: git's own
    // "nothing to commit, working tree clean" goes to stdout with a non-zero exit.
    let err = result.stderr + "\n" + result.stdout
    if commitNothingMarkers.contains(where: err.contains) { return .nothingToCommit }
    if commitIdentityMarkers.contains(where: err.contains) { return .identityMissing(err) }
    if commitSigningMarkers.contains(where: err.contains) { return .signingFailed(err) }
    if commitUnmergedMarkers.contains(where: err.contains) { return .unmergedFiles(err) }
    // Before the hook check: git phrases this one as a plain fatal, and it is a state the user must
    // finish rather than a hook they must fix.
    if err.contains("cannot do a partial commit during a") || err.contains("is in progress") {
      return .sequencerInProgress(err)
    }
    if commitHookMarkers.contains(where: err.contains) { return .hookRejected(err) }
    if err.contains("Failed to take lock") || err.contains("index.lock")
      || (err.contains(".lock")
        && (err.contains("could not be obtained") || err.contains("File exists")
          || err.contains("Unable to create")))
    {
      return .locked(lockFile(in: err))
    }
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

  /// Which multi-step git operation is parked in this worktree, named for the user, or nil if none.
  ///
  /// Checking for *conflicts* is not enough, and the difference is a real trap: resolving the
  /// conflicts in a terminal clears the conflict markers but leaves `MERGE_HEAD` sitting there, so a
  /// conflict-only guard re-enables Commit into a guaranteed `fatal: cannot do a partial commit
  /// during a merge`. The sequencer file is the durable fact; the conflict is not.
  ///
  /// Ordered by specificity: a cherry-pick and a revert both also leave `MERGE_HEAD` behind, so they
  /// are tested first or every one of them would report "merge".
  static func sequencerState(gitDir: URL?) -> String? {
    guard let gitDir else { return nil }
    let fm = FileManager.default
    let markers: [(String, String)] = [
      ("CHERRY_PICK_HEAD", "cherry-pick"),
      ("REVERT_HEAD", "revert"),
      ("rebase-merge", "rebase"),
      ("rebase-apply", "rebase"),
      ("BISECT_LOG", "bisect"),
      ("MERGE_HEAD", "merge"),
    ]
    for (file, label) in markers
    where fm.fileExists(atPath: gitDir.appendingPathComponent(file).path) {
      return label
    }
    return nil
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
  private func gated<T: Sendable>(
    _ projectRoot: String, _ body: @Sendable @escaping () async -> T
  ) async -> T? {
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

  // MARK: - Commit

  func commit(path: String, projectRoot: String, request: VCSCommitRequest) async -> VCSCommitResult
  {
    guard Self.supports(mode: request.mode, vcs: vcs) else { return .failed(.unsupportedMode) }
    let gitDir = Self.worktreeGitDir(at: path)
    // A parked merge/cherry-pick/rebase/bisect makes a path-limited commit outright invalid, and
    // finishing it is the user's call. Checked before the ref snapshot so nothing is spawned at all.
    if vcs != "jj", let sequencer = Self.sequencerState(gitDir: gitDir) {
      return .failed(.sequencerInProgress(sequencer))
    }

    // ONE gate acquisition for the whole operation, not one per command. Two would let the 15s
    // status sweep, the FSEvents lane and DiffResolver interleave between the intent-to-add and the
    // commit — contending on `index.lock` and, for jj, snapshotting `@` out from under a write.
    //
    // `before` is read INSIDE the gate, not before acquiring it. Outside, anything that moves the ref
    // while this call waits its turn — a queued status snapshot (which rewrites `@` for jj, so the op
    // head moves on every one), another window, the user's own terminal during a slow hook — would
    // make the before/after comparison below read a ref that moved for someone else's reason. A
    // commit that genuinely failed would then be reported as `.committedThenFailed`, whose copy tells
    // the user their work is saved and not to commit again. It would not be.
    let outcome = await gated(
      projectRoot,
      { [self] in
        let before = await currentRevision(path: path)
        return CommitAttempt(before: before, result: await runCommitSequence(request, in: path))
      })
    guard let attempt = outcome else { return .failed(.other("commit was cancelled")) }
    let (before, result) = (attempt.before, attempt.result)

    if let failure = Self.classifyCommit(result, tool: vcs) {
      // The command failed, but did the ref move anyway? A `post-commit` hook runs AFTER git has
      // written the commit and moved HEAD, so a hook that fails — or that we killed at the timeout —
      // leaves a real commit behind a non-zero exit. Reporting that as a plain failure invites a
      // retry, and the retry would commit a second time.
      let after = await currentRevision(path: path)
      if let after, after != before {
        return .committedThenFailed(revision: after, detail: Self.commitFailureDetail(failure))
      }
      return .failed(failure)
    }
    let after = await currentRevision(path: path)
    return .ok(summary: Self.commitSummary(request.mode, vcs: vcs), revision: after)
  }

  /// A commit's ref reading and its outcome, captured together inside one gate acquisition.
  private struct CommitAttempt: Sendable {
    let before: String?
    let result: CommandResult
  }

  /// The commands, in order, inside the caller's single gate acquisition.
  ///
  /// Returns the FIRST failing result, so the caller classifies whichever step broke. The
  /// intent-to-add step only runs when the selection actually contains paths git may not know, so the
  /// common case is one process.
  private func runCommitSequence(_ request: VCSCommitRequest, in path: String) async
    -> CommandResult
  {
    if vcs == "jj" {
      let args =
        request.mode == .describe
        ? Self.jjDescribeArgs(message: request.message)
        : Self.jjCommitArgs(message: request.message)
      return await run(args, in: path, timeout: commitTimeout)
    }

    if request.mode == .amendMessage {
      return await run(
        Self.gitAmendMessageArgs(message: request.message), in: path,
        timeout: commitTimeout)
    }

    // New sides only — see `gitPathspecPayload(literalPaths:)`.
    let unknown = Self.pathsGitMayNotKnow(in: request.files)
    if !unknown.isEmpty {
      let ita = await runner.run(
        vcs, Self.gitIntentToAddArgs(), in: path, timeout: refTimeout,
        stdin: Self.gitPathspecPayload(literalPaths: unknown))
      guard ita.ok else { return ita }
    }
    let result = await runner.run(
      vcs, Self.gitCommitOnlyArgs(message: request.message), in: path, timeout: commitTimeout,
      stdin: Self.gitPathspecPayload(request.files))

    // The commit failed, so undo the index entries we just made. Left behind, an intent-to-add marker
    // is not the harmless residue it looks like: it breaks the user's own `git stash` in the terminal
    // ("Entry 'x' not uptodate. Cannot merge.") until they find and reverse a change they never made.
    //
    // Rolled back for the untracked rows ONLY. Those were definitionally absent from the index, so
    // `rm --cached` reverses exactly our own step. A rename's new side may already be a real staged
    // entry (`git mv`), and unstaging that would destroy work the user did themselves — the wrong
    // trade for tidiness.
    if !result.ok {
      let added = Self.pathsAddedToTheIndex(in: request.files)
      if !added.isEmpty {
        _ = await runner.run(
          vcs, Self.gitUnstageArgs(), in: path, timeout: refTimeout,
          stdin: Self.gitPathspecPayload(literalPaths: added))
      }
    }
    return result
  }

  /// Selected paths git may have no index entry for, which `--only` therefore cannot commit.
  ///
  /// Untracked files are the obvious case. The one that was missing — and that broke every commit
  /// containing it — is the NEW side of a rename. `GitProvider.workingStatus` runs libgit2
  /// status with `.renamesWorkingTree`, so a plain `mv old new` (what editors, IDEs and coding agents
  /// all do; only `git mv` behaves otherwise) arrives as ONE `.renamed` row whose `path` is a file git
  /// has never seen. `git commit --only` then fails the WHOLE selection with `error: pathspec
  /// ':(literal)new.txt' did not match any file(s) known to git` — every other ticked file goes
  /// uncommitted with it, and the failure classifies as `.other` with no remedy to offer.
  ///
  /// Including paths git already tracks costs nothing: `--intent-to-add` records no content for them,
  /// so a modified tracked file stays unstaged (measured). Intent-adding the new side also lets git
  /// pair the two halves itself, so the commit records a rename (`R100`) rather than an add plus a
  /// delete.
  static func pathsGitMayNotKnow(in files: [ChangedFile]) -> [String] {
    files.filter { $0.change == .untracked || $0.change == .renamed }.map(\.path)
  }

  /// Of those, the ones the intent-to-add step definitely CREATED an index entry for, so a failed
  /// commit can put the index back exactly as it found it.
  ///
  /// Untracked rows only. Those were definitionally absent from the index, so `rm --cached` reverses
  /// precisely our own step. A rename's new side may already be a real staged entry (`git mv` stages
  /// the rename, and intent-to-add is then a no-op on it) — unstaging that would destroy work the user
  /// did themselves, which is a far worse outcome than a leftover marker.
  static func pathsAddedToTheIndex(in files: [ChangedFile]) -> [String] {
    files.filter { $0.change == .untracked }.map(\.path)
  }

  /// Selected paths whose staged content a commit would discard, for the dialog to confirm before it
  /// happens. Empty for jj, which has no index, and for a mode that takes no pathspec.
  ///
  /// A pre-flight rather than a refusal: a partially-staged file is a legitimate thing to commit from
  /// — the user just has to know that the version on disk is the one that lands. Silence is the only
  /// unacceptable option, because the loss leaves no trace (`git status` is clean afterwards).
  func stagedContentAtRisk(path: String, files: [ChangedFile]) async -> [String] {
    guard vcs != "jj", !files.isEmpty else { return [] }
    let result = await run(Self.gitStatusPorcelainArgs(), in: path, timeout: refTimeout)
    guard result.ok else { return [] }
    return Self.stagedContentAtRisk(
      porcelainZ: result.stdout, selecting: Set(files.map(\.path)))
  }

  /// The current ref, for the before/after comparison. Ungated and cheap: git's `rev-parse` touches
  /// nothing, and the jj form carries `jjReadFlags` so it cannot snapshot.
  ///
  /// Nil for an unborn branch (a repo with no commits), which is a legitimate state to commit from —
  /// `nil != "abc123"` then reads correctly as "the ref moved".
  private func currentRevision(path: String) async -> String? {
    let args = vcs == "jj" ? Self.jjOpHeadArgs() : Self.gitHeadArgs()
    let result = await run(args, in: path, timeout: refTimeout)
    guard result.ok else { return nil }
    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Which verbs each backend has. `.amendMessage` is git's and `.describe` is jj's; neither has a
  /// counterpart on the other side, so a mismatch is a programming error the writer reports rather
  /// than silently running the nearest command.
  static func supports(mode: VCSCommitMode, vcs: String) -> Bool {
    switch mode {
    case .commit: return true
    case .amendMessage: return vcs != "jj"
    case .describe: return vcs == "jj"
    }
  }

  static func commitSummary(_ mode: VCSCommitMode, vcs: String) -> String {
    switch mode {
    case .commit: return "Committed"
    case .amendMessage: return "Amended the last commit"
    case .describe: return "Set the change message"
    }
  }

  /// The stderr a `committedThenFailed` carries, so the dialog can show what went wrong *after* the
  /// commit landed.
  static func commitFailureDetail(_ failure: VCSCommitFailure) -> String {
    switch failure {
    case .toolMissing(let m), .identityMissing(let m), .signingFailed(let m), .hookRejected(let m),
      .unmergedFiles(let m), .sequencerInProgress(let m), .other(let m):
      return m
    case .timedOut: return "The command was stopped at its time limit."
    case .nothingToCommit: return "Nothing to commit."
    case .locked(let file):
      return file.map { "Blocked by \($0.filename)." } ?? "The repository was busy."
    case .unsupportedMode: return "That action isn’t available for this repository."
    }
  }
}
