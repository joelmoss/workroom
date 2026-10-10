import Foundation
import WorkroomDomain

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
  /// `git` not on PATH. Distinct from `VCSToolVersions`' floor check, which runs at launch —
  /// this is the same condition caught at the point of use.
  case toolMissing(String)
  /// The command never ran — `CommandResult.launchFailed`, dominated by the working directory
  /// having vanished (e.g. the workroom was deleted mid-action) between the toolbar deciding to
  /// act and the runner trying to launch. Distinct from `toolMissing`: that means the TOOL wasn't
  /// found on PATH, which is a completely different, unrelated fact from "this folder is gone."
  case launchFailed
  /// The command's own combined stderr/stdout up to the kill, for the dialog's Details section —
  /// often the one clue to WHY it hung (a stalled host-key prompt, a slow TLS handshake) that a bare
  /// "timed out" throws away. Always at least the "\n" join separator, even when the child produced
  /// nothing before it was killed — `rawOutput(of:)` trims before checking, so that case still shows
  /// no Details section.
  case timedOut(VCSRemoteAction, String)
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
  /// A repo lock was held — `index.lock`/`packed-refs.lock`.
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
  /// The command was dispatched and we never heard back — `CommandResult.outcomeUnknown`. Only
  /// reachable on the agent-routed path, where a lost connection, a client-side deadline or a
  /// cancellation ends the round trip while the host-side `git` keeps running to completion.
  ///
  /// The whole point of the case is the recovery. This is NOT `.other`: that one's recovery is a
  /// retry of the action that failed, and retrying a push that may already have landed is the one
  /// thing this state must not offer. `retryAction` answers `.fetch` instead — idempotent, and the
  /// ahead/behind it brings back is exactly the fact that resolves the unknown.
  ///
  /// It is also NOT `.launchFailed`: that asserts nothing ran, which is the opposite falsehood.
  case outcomeUnknown(String)
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
  /// Where it was attempted, named ONLY when that is no longer what's selected — an action can outlive
  /// the selection it started from (a push takes as long as it takes), and an unattributed dialog
  /// arriving over a different workroom reads as a failure of the one on screen.
  let workroom: String?
  /// True when the failure came from READING the repo rather than from an action, so the dialog titles
  /// itself accordingly instead of naming an action that never ran.
  let isRead: Bool
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
  /// False for a lock file on a remote host: its path names nothing on this Mac, so there is nothing
  /// here to reveal in Finder (`VCSSyncPresenter.lockPath`).
  var isOnThisMac = true

  var filename: String { (path as NSString).lastPathComponent }
}

/// What a remote-state read decided. Mirrors `CIResolution`/`PRResolution`, `keepPrior` included: a
/// transient blip must not blank a good toolbar.
enum VCSRemoteResolution: Equatable, Sendable {
  case state(VCSRemoteState)
  /// Not a git repo, or a repo with no refs at all (a fresh `git init`).
  case absent
  case keepPrior
  case failed(VCSRemoteFailure)
}

/// What an action decided. There is deliberately no `okWithConflicts`: `RemoteStateModel` upgrades
/// a `.ok` pull to "conflicted" from the status refresh it already triggers, after the gate has
/// released.
enum VCSRemoteActionResult: Equatable, Sendable {
  case ok(summary: String)
  case failed(VCSRemoteFailure)
}

// MARK: - Commit

/// Which commit verb to run. Deliberately NOT folded into `VCSRemoteAction`: that enum feeds
/// `VCSRemoteFailure.timedOut`, `PendingVCSAction` and the toolbar's labels, none of which mean
/// anything for a purely local write.
enum VCSCommitMode: String, Equatable, Sendable {
  case commit, amendMessage
}

/// One commit, fully specified. `files` carries `ChangedFile` rather than `String` because a rename
/// needs BOTH sides of the pathspec — see `gitPathspecPayload`.
struct VCSCommitRequest: Equatable, Sendable {
  let message: String
  /// The user's selection.
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
  /// The command never ran — see `VCSRemoteFailure.launchFailed`'s doc for why this must not be
  /// folded into `toolMissing`.
  case launchFailed
  case timedOut
  /// Nothing staged/changed for the selection.
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
  /// The commit was dispatched and we never heard back — see `VCSRemoteFailure.outcomeUnknown`.
  ///
  /// `commit()` compares the revision before and after, so a MOVED ref answers the question outright
  /// as `.committedThenFailed` and never reaches here. What reaches here is everything else: the ref
  /// could not be re-read (the common case — a dead socket fails that request too), or it read back
  /// unchanged, which is not proof of anything because a commit host-side may simply not have
  /// finished. Hence copy that sends the user to check the history rather than asserting either way.
  case outcomeUnknown(String)
  case other(String)
}

/// What the commit dialog needs to know about a repo before it writes to it.
///
/// One value rather than three protocol methods because the dialog asks once, on appear, and every
/// field is answered from the same repo at the same moment — three calls would be three round trips
/// for one screen, and for a remote workroom that is three stream round trips.
struct VCSCommitPreflight: Equatable, Sendable {
  /// A parked merge/cherry-pick/revert/rebase/bisect, named for the user. `commit`
  /// refuses outright while one is parked (`VCSCommitFailure.sequencerInProgress`), so the dialog
  /// says so up front instead of letting someone compose a whole message to be told at the click.
  let sequencer: String?
  /// The subject of the commit `.amendMessage` would rewrite. Shown so the message being
  /// destroyed is visible BEFORE the click rather than recoverable only from the reflog.
  let amendTarget: String?
  static let none = VCSCommitPreflight(sequencer: nil, amendTarget: nil)
}

/// The seam for VCS operations that **write** — remote state reads plus fetch/push/pull.
///
/// Separate from `LocalVCSProviding` on purpose. That protocol's doc calls it "the single seam the app
/// **reads** VCS data through", and four resolvers construct providers freely and call them with no
/// gate. Putting `fetch` there would mean nothing structurally prevented a read path from firing a
/// network mutation — the opposite of what `RepositoryWriteGate` exists to guarantee. Keeping writes
/// on their own protocol also gives the injected `StatusCommandRunning` a home: `GitProvider` is a
/// stateless value type constructed at several call sites with nowhere to put one.
///
/// This is the growth surface for the rest of the VCS write phase, which is why it's a protocol with
/// a factory rather than one standalone resolver — otherwise each later operation re-derives repo
/// kind and wires its own runner.
protocol LocalVCSWriting: Sendable {
  /// Everything the toolbar renders, as ONE coherent snapshot.
  func remoteState(path: String, projectRoot: String) async -> VCSRemoteResolution
  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult
  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool
  ) async -> VCSRemoteActionResult
  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String,
    tracking: VCSTracking?
  ) async -> VCSRemoteActionResult
  /// Recover a workroom left mid-rebase.
  func abortRebase(path: String, projectRoot: String) async -> VCSRemoteActionResult

  /// Record a commit. **Local**, unlike everything above it, so it takes no `remote` and never runs
  /// through `runNetwork` — but it lands here rather than on `LocalVCSProviding` for the reason this
  /// protocol's own doc gives: writes belong behind the gate, and a read seam that could commit is
  /// exactly what that separation prevents.
  ///
  /// Always runs in the **workroom**: a commit at the project root would record the root's work, not
  /// the workroom's.
  func commit(path: String, projectRoot: String, request: VCSCommitRequest) async -> VCSCommitResult

  /// Selected paths whose STAGED content a commit would silently discard, so the caller can confirm
  /// first. Empty when there is nothing at risk. See `CLIVCSWriter.stagedContentAtRisk`.
  func stagedContentAtRisk(path: String, files: [ChangedFile]) async throws -> [String]

  /// What the commit dialog shows before it writes — see `VCSCommitPreflight`.
  ///
  /// **Here rather than on `LocalVCSProviding`, even though every field is a read.** The same reasoning
  /// that put `stagedContentAtRisk` here: these are facts about whether and how a WRITE will land,
  /// asked by the one screen that is about to perform one, and neither has meaning outside that
  /// question. It also keeps the git sequencer check — a `.git` directory listing —
  /// behind the seam rather than in a View, which is what made the dialog fail for any path not on
  /// this Mac (issue #154, Phase 2).
  func commitPreflight(path: String) async throws -> VCSCommitPreflight
}

extension LocalVCSWriting {
  /// Test doubles and the fixture have no index to put anything at risk — same reasoning as
  /// `runNetwork`'s default, so they stay short.
  func stagedContentAtRisk(path: String, files: [ChangedFile]) async throws -> [String] { [] }

  /// Default: nothing to report, so the dialog opens with empty fields.
  ///
  /// This default never throws, unlike `LocalVCSProviding.workingStatus`'s default, and the
  /// difference is deliberate.
  /// A wrong `workingStatus` default reports every workroom clean — a plausible-looking lie that
  /// survives a release. Every field here is optional and the dialog renders each one's absence
  /// honestly: no amend label, no parked-operation notice, an empty message box. A conformer that
  /// forgets this degrades visibly and cannot mislabel anything.
  func commitPreflight(path: String) async throws -> VCSCommitPreflight { .none }
}

/// `LocalVCSWriting` over the real `git` CLI.
///
/// **Why the CLI and not the libraries.** SwiftGitX 0.4.0's `fetch`/`push` pass `NULL` for the options
/// struct that would carry `git_remote_callbacks.credentials`, so they have no credential path at all —
/// HTTPS authentication is impossible through them — and it has no `pull`. Shelling the real binaries
/// means the user's own credential helpers, SSH agent and config just work, which is the same bet the
/// status layer already makes with `gh`.
///
/// Pure `static` arg-builders, parsers and classifiers carry all the semantics, so they are unit-tested
/// without spawning anything.
///
/// ```
///                 ┌──────────── every network op ────────────┐
///                 │ runNetwork: stdin=/dev/null, BatchMode,   │
///                 │ askpass off, SSH_AUTH_SOCK forwarded      │
///                 └────────────────────┬─────────────────────┘
///                                      │
///                 ┌────────────────────┴─────────────────────┐
///                 │  RepositoryWriteGate.run(projectRoot:)    │
///                 │  NEVER re-enter for the same root         │
///                 └────────────────────┬─────────────────────┘
///                                      │
///  fetch → PROJECT ROOT (FETCH_HEAD is per-worktree; the root is one shared answer)
///  push  → workroom
///  pull  → root (fetch) + workroom
///  abort → workroom
/// ```
struct CLIVCSWriter: LocalVCSWriting, Sendable {
  /// The executable every write runs, and the name failure copy uses for it.
  static let tool = "git"
  let runner: StatusCommandRunning
  /// For `currentRef` only. The app already has a canonical answer including `.detached`;
  /// re-deriving it from `%(HEAD)` would lose it.
  let makeProvider: @Sendable (URL) throws -> LocalVCSProviding
  /// Serializes writes per project root: a project's workrooms are `git worktree add` worktrees
  /// sharing one `.git`, so a lock lost mid-`pull --rebase` can leave a workroom wedged in a rebase.
  let gate: RepositoryWriteGate
  /// The host the repository is on. It keys the write gate (`gated`), so a remote path is never
  /// resolved against this disk, nor shares a queue with a local repository at the same path.
  var host: HostID = .local
  /// Where the classifier's disk facts come from for a repository on a remote host: that host's
  /// agent (`AgentVCSConnection.stat`). Nil for a local repository, which reads this Mac's disk.
  var stat: (@Sendable (_ paths: [String], _ read: [String]) async throws -> DiskSnapshot)?

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
  /// **fetch always runs at the project root**, because `FETCH_HEAD` is **per-worktree** — fetching
  /// inside a workroom would leave the project and every sibling workroom reading "never fetched"
  /// while their remote refs were perfectly fresh. At the root it's one fact every workroom of the
  /// project agrees on.
  ///
  /// **Everything except fetch runs in the workroom**: push, pull and abort act on the workroom's own
  /// branch and working tree. `opDirectoryTests` pins `path` and `projectRoot` as different.
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
  /// directory, which is where a root fetch's `FETCH_HEAD` lands — unless the project root is ITSELF
  /// a linked worktree, whose fetch writes `.git/worktrees/<name>/FETCH_HEAD` (verified, git 2.56).
  /// That case reads as stale here; `Defaults.Keys.vcsLastFetch` covers Workroom's own fetches.
  ///
  /// Pure string work, no subprocess: `git rev-parse --git-common-dir` is authoritative but costs a
  /// process for something two file reads answer.
  static func commonGitDir(at path: String, disk: any RepositoryDisk = LocalDisk()) -> URL? {
    let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
    guard let entry = disk.entry(dotGit.path) else { return nil }
    if entry.isDirectory { return dotGit }
    // A worktree's `.git` file: `gitdir: /abs/or/relative/path`.
    guard let contents = disk.text(dotGit.path) else { return nil }
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
  /// so its mtime records git fetches — including one the user ran in a terminal. Not every one: a
  /// linked-worktree root's lands elsewhere (see `commonGitDir`), and `--no-write-fetch-head` writes
  /// none.
  static func gitLastFetch(commonGitDir: URL?, disk: any RepositoryDisk = LocalDisk())
    -> VCSLastFetch
  {
    guard let dir = commonGitDir else { return .unknown }
    let head = dir.appendingPathComponent("FETCH_HEAD")
    guard let entry = disk.entry(head.path) else { return .never }
    guard let date = entry.modifiedAt else { return .unknown }
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

  /// Exits 1 with no output only when HEAD names no commit yet; any failed read exits 128.
  static func gitUnbornHeadArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + ["rev-parse", "--verify", "-q", "HEAD"]
  }

  /// The subject of the commit an amend would rewrite.
  ///
  /// Read-only and cheap. Its purpose is honesty rather than prefill: amend replaces `HEAD`'s message
  /// with whatever is in the summary field, so the dialog has to be able to show WHICH message that
  /// destroys before the click, not leave it recoverable only from the reflog. `%s` rather than `%B`
  /// deliberately — this is a label, and a multi-line body would wrap the dialog.
  static func gitHeadSubjectArgs() -> [String] {
    WorkroomStatusResolver.gitHardening + ["log", "-1", "--no-color", "--pretty=format:%h %s"]
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

  /// `"3\t1"` → (ahead: 3, behind: 1). `nil` for anything unexpected — never a misleading zero.
  static func parseCounts(_ stdout: String) -> (ahead: Int, behind: Int)? {
    let fields = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0 == "\t" || $0 == " " })
    guard fields.count == 2, let ahead = Int(fields[0]), let behind = Int(fields[1]) else {
      return nil
    }
    return (ahead, behind)
  }

  // MARK: - Classification

  /// Map a failed command to a typed failure. `nil` means success.
  ///
  /// `gitDir` lets a failed pull be upgraded to `.rebaseInProgress` — the distinction matters because
  /// that state must offer Abort, not Retry.
  static func classify(
    _ result: CommandResult, action: VCSRemoteAction, tool: String,
    gitDir: URL? = nil, disk: any RepositoryDisk = LocalDisk()
  ) -> VCSRemoteFailure? {
    // Checked BEFORE commandNotFound: launchFailed means the process never ran at all (dominated by
    // a vanished cwd), which is a different fact from commandNotFound's "env ran and searched PATH".
    if result.exitCode == CommandResult.launchFailed { return .launchFailed }
    // Refused before it ran: the reason is the whole message, and `.other` offers the Retry that is
    // safe precisely because nothing happened.
    if result.exitCode == CommandResult.refused { return .other(result.stderr) }
    // Before every output check, for `launchFailed`'s reason: this is a fact about whether we heard
    // an answer, not about what the answer said. There is no output to match on anyway — the stderr
    // is the transport's own description, and matching git's prose against it could only misfire.
    //
    // Except the DISK, which is not output and does not depend on having heard back. A pull whose
    // reply was lost after git wrote `rebase-merge` leaves the same parked rebase as one we killed
    // at its timeout, and the remedy is the same Abort — so this asks the same question the
    // `timedOut` branch below does, in the same order, rather than discarding the one piece of
    // positive evidence available. `commit()` resolves its own unknown the same way, off the ref.
    //
    // It races a host-side git that is still rebasing, and that is accepted here for the reason the
    // `timedOut` branch already accepts it: a parked rebase the user cannot see is the worse state.
    if result.exitCode == CommandResult.outcomeUnknown {
      if action == .pull, rebaseInProgress(gitDir: gitDir, disk: disk) { return .rebaseInProgress }
      return .outcomeUnknown(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if result.exitCode == CommandResult.commandNotFound { return .toolMissing(tool) }
    let err = result.stderr + "\n" + result.stdout
    // A timed-out pull may have left a rebase behind; that reads better than "timed out".
    if result.timedOut {
      if action == .pull, rebaseInProgress(gitDir: gitDir, disk: disk) { return .rebaseInProgress }
      return .timedOut(action, err)
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
      || err.contains("no such remote")
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
    if err.contains(".lock")
      && (err.contains("could not be obtained") || err.contains("File exists")
        || err.contains("Unable to create"))
    {
      return .locked(lockFile(in: err, disk: disk))
    }
    if action == .pull, rebaseInProgress(gitDir: gitDir, disk: disk) { return .rebaseInProgress }
    // A lock failure that never names a lock. git's message depends on WHICH internal step hit the lock:
    // a fast-forward pull reports `Unable to create '<path>': File exists.`, but a pull that must really
    // rebase fails in autostash first and says only `error: could not write index` / `fatal: Cannot
    // autostash` — no path, no "lock", nothing the checks above can match. That is the diverged pull,
    // i.e. exactly what the toolbar's Pull button is for, and it was landing in `.other` with raw stderr.
    //
    // So when the symptoms are lock-shaped, ask the DISK instead of the message. Deliberately last: any
    // failure git explains properly keeps its own classification, and this only speaks for the ones it
    // doesn't.
    if lockSymptom(err), let lock = existingLockFile(gitDir: gitDir, disk: disk) {
      return .locked(lock)
    }
    let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
    // Killed rather than finished, with nothing to say for itself: `exitCode` is the SIGNAL number,
    // so the fallback below would render "git exited 15" — literally the dialog `a64e4269` ("stop
    // 'exited with code 15' dialog on wake from sleep") set out to end. That fix taught
    // `WorkroomCLI.CLIResult` about signals but never reached this runner. Deliberately last, and
    // only when there is no stderr: a child that explained itself before dying keeps its real
    // classification. `.other` retries, which is the right recovery for an interrupted write.
    if trimmed.isEmpty, result.signaled { return .other("\(tool) was interrupted") }
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

  /// git's phrasings, matched only on the FAILURE path — see `classifyCommit`.
  static let commitNothingMarkers = [
    "nothing to commit", "no changes added to commit", "nothing added to commit",
  ]

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
  static func classifyCommit(
    _ result: CommandResult, tool: String, disk: any RepositoryDisk = LocalDisk()
  ) -> VCSCommitFailure? {
    if result.exitCode == CommandResult.launchFailed { return .launchFailed }
    // See `classify`.
    if result.exitCode == CommandResult.refused { return .other(result.stderr) }
    // See `classify` — a fact about the round trip, not about the command's output.
    if result.exitCode == CommandResult.outcomeUnknown {
      return .outcomeUnknown(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if result.exitCode == CommandResult.commandNotFound { return .toolMissing(tool) }
    if result.timedOut { return .timedOut }
    guard !result.ok else { return nil }

    // Only now, on a genuine failure, is matching the combined output safe: `git commit` echoes the
    // SUBJECT on stdout, so `-m "explain the nothing to commit error"` — a commit that succeeded —
    // must never be read for markers, while git's own "nothing to commit, working tree clean" goes to
    // stdout with a non-zero exit.
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
    if err.contains("index.lock")
      || (err.contains(".lock")
        && (err.contains("could not be obtained") || err.contains("File exists")
          || err.contains("Unable to create")))
    {
      return .locked(lockFile(in: err, disk: disk))
    }
    let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
    // Same reasoning as `classify`: a signal number is not an exit status, so don't print it as one.
    if trimmed.isEmpty, result.signaled { return .other("\(tool) was interrupted") }
    return .other(trimmed.isEmpty ? "\(tool) exited \(result.exitCode)" : trimmed)
  }

  /// Whether a rebase is parked in this worktree. Both directory names are checked: `rebase-merge` for
  /// an interactive/merge rebase, `rebase-apply` for the am-based one.
  static func rebaseInProgress(gitDir: URL?, disk: any RepositoryDisk = LocalDisk()) -> Bool {
    guard let gitDir else { return false }
    return disk.entry(gitDir.appendingPathComponent("rebase-merge").path) != nil
      || disk.entry(gitDir.appendingPathComponent("rebase-apply").path) != nil
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
  static func sequencerState(gitDir: URL?, disk: any RepositoryDisk = LocalDisk()) -> String? {
    guard let gitDir else { return nil }
    for (file, label) in sequencerMarkers
    where disk.entry(gitDir.appendingPathComponent(file).path) != nil {
      return label
    }
    return nil
  }

  static let sequencerMarkers: [(String, String)] = [
    ("CHERRY_PICK_HEAD", "cherry-pick"),
    ("REVERT_HEAD", "revert"),
    ("rebase-merge", "rebase"),
    ("rebase-apply", "rebase"),
    ("BISECT_LOG", "bisect"),
    ("MERGE_HEAD", "merge"),
  ]

  /// The lock file a failure is complaining about, or nil if we can't point at one.
  ///
  /// The path is taken from git's OWN message rather than guessed: git names the exact file it couldn't
  /// create (`fatal: Unable to create '<path>': File exists.`), and a repo has several lock files that
  /// mean different things — `index.lock`, `packed-refs.lock`, `HEAD.lock`, `config.lock`. Naming the
  /// wrong one would send someone to delete a file that isn't the problem.
  ///
  /// Returns nil when git's message carries no path, and — deliberately — when the named file no
  /// longer exists: a lock that cleared between the failure and this check WAS
  /// transient contention, which is exactly the case where Retry is the right offer.
  static func lockFile(in stderr: String, disk: any RepositoryDisk = LocalDisk()) -> VCSLockFile? {
    guard let path = parseLockPath(stderr), let modified = disk.entry(path)?.modifiedAt else {
      return nil
    }
    return VCSLockFile(path: path, modifiedAt: modified, isOnThisMac: disk is LocalDisk)
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
  static func existingLockFile(gitDir: URL?, disk: any RepositoryDisk = LocalDisk())
    -> VCSLockFile?
  {
    for candidate in lockCandidates(gitDir: gitDir) {
      guard let modified = disk.entry(candidate.path)?.modifiedAt else { continue }
      return VCSLockFile(
        path: candidate.path, modifiedAt: modified, isOnThisMac: disk is LocalDisk)
    }
    return nil
  }

  /// Where a lock file can be, in the order `existingLockFile` checks.
  static func lockCandidates(gitDir: URL?) -> [URL] {
    guard let gitDir else { return [] }
    var dirs = [gitDir]
    // `<common>/worktrees/<name>` → `<common>`. Cheap and string-only; `commonGitDir` does the same trip
    // from a path rather than from an already-resolved git dir.
    if gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
      dirs.append(gitDir.deletingLastPathComponent().deletingLastPathComponent())
    }
    return dirs.flatMap { dir in knownLockNames.map { dir.appendingPathComponent($0) } }
  }

  /// Every path the classifier can read for a command run in the worktree whose git directories
  /// these are, and whose stderr this is: the set a remote host's `stat` must report, so a
  /// `DiskSnapshot` answers each probe above. A probe that reads a path not listed here traps in
  /// a debug build.
  static func classificationPaths(gitDir: URL?, commonGitDir: URL?, stderr: String) -> [String] {
    var paths: [URL] = lockCandidates(gitDir: gitDir)
    if let gitDir {
      paths += sequencerMarkers.map { gitDir.appendingPathComponent($0.0) }
    }
    if let commonGitDir { paths.append(commonGitDir.appendingPathComponent("FETCH_HEAD")) }
    var unique = paths.map(\.path)
    if let lock = parseLockPath(stderr) { unique.append(lock) }
    var seen = Set<String>()
    return unique.filter { seen.insert($0).inserted }
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
  static func worktreeGitDir(at path: String, disk: any RepositoryDisk = LocalDisk()) -> URL? {
    let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
    guard let entry = disk.entry(dotGit.path) else { return nil }
    if entry.isDirectory { return dotGit }
    guard let contents = disk.text(dotGit.path) else { return nil }
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
      ? await runner.runNetwork(Self.tool, args, in: directory, timeout: timeout)
      : await runner.run(Self.tool, args, in: directory, timeout: timeout)
  }

  /// Run a write through the per-project gate.
  ///
  /// `RepositoryWriteGate`'s doc warns against timing the innermost call, because `withTimeout`
  /// cannot cancel the call and the gate would release while the abandoned call still held the lock.
  /// That reasoning does **not** apply to a subprocess run by the runner's own timeout: `StatusCommandRunner` SIGTERMs at
  /// `+timeout` and `ProcessTree.killTree`s at `+timeout+2`, so the process is genuinely gone and its
  /// locks genuinely released. Hence the runner's own timeout with no outer `withTimeout` — this looks
  /// like a violation of that doc and isn't.
  private func gated<T: Sendable>(
    _ projectRoot: String, _ body: @Sendable @escaping () async -> T
  ) async -> T? {
    guard case .remote(let id) = host else {
      return try? await gate.run(projectRoot: projectRoot, body)
    }
    // Keyed as the remote location it is: validated, not resolved against this disk.
    guard let repository = try? RepositoryLocation.remote(host: id, path: projectRoot) else {
      return nil
    }
    return try? await gate.run(repository: repository, body)
  }

  // MARK: - Disk facts

  /// The disk a classification reads, and the worktree's git directory on it, read AFTER the command
  /// it explains: a parked rebase or a leftover lock exists only once that command has failed.
  ///
  /// Locally, this Mac's disk, live. On a remote host, two round trips to its agent: the worktree's
  /// `.git` says where its git directories are, then everything in them at once. A host that cannot
  /// be asked reads as no evidence (`DiskSnapshot.unknown`), as a missing file would.
  ///
  /// The git directories come from the FIRST read, and are what the second was built for: resolved
  /// again from the second, a `.git` that changed in between would name paths it never asked about.
  private func disk(at path: String, stderr: String = "") async -> (
    disk: any RepositoryDisk, gitDir: URL?, commonGitDir: URL?
  ) {
    guard let stat else {
      return (LocalDisk(), Self.worktreeGitDir(at: path), Self.commonGitDir(at: path))
    }
    let dotGit = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git").path
    guard let pointer = try? await stat([dotGit], [dotGit]) else {
      return (DiskSnapshot.unknown, nil, nil)
    }
    let gitDir = Self.worktreeGitDir(at: path, disk: pointer)
    let commonGitDir = Self.commonGitDir(at: path, disk: pointer)
    let paths =
      [dotGit]
      + Self.classificationPaths(gitDir: gitDir, commonGitDir: commonGitDir, stderr: stderr)
    guard let facts = try? await stat(paths, [dotGit]) else {
      return (DiskSnapshot.unknown, gitDir, commonGitDir)
    }
    return (facts, gitDir, commonGitDir)
  }

  private func parkedOperation(at path: String) async -> String? {
    let facts = await disk(at: path)
    return Self.sequencerState(gitDir: facts.gitDir, disk: facts.disk)
  }

  /// `Self.classify`, reading the disk of wherever this repository lives. `withGitDir: false` for a
  /// command whose classification never consulted the worktree's git directory.
  private func classify(
    _ result: CommandResult, action: VCSRemoteAction, tool: String, at path: String,
    withGitDir: Bool = true
  ) async -> VCSRemoteFailure? {
    // Nothing on disk explains a success, so a remote host is not asked about one.
    if result.ok { return Self.classify(result, action: action, tool: tool) }
    let facts = await disk(at: path, stderr: result.stderr + "\n" + result.stdout)
    return Self.classify(
      result, action: action, tool: tool, gitDir: withGitDir ? facts.gitDir : nil,
      disk: facts.disk)
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
    return await gitRemoteState(path: path, current: current)
  }

  private func gitRemoteState(path: String, current: VCSRef) async -> VCSRemoteResolution {
    let refs = await run(Self.gitRemoteRefsArgs(), in: path, timeout: refTimeout)
    if let failure = await classify(
      refs, action: .fetch, tool: Self.tool, at: path, withGitDir: false)
    {
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
    let facts = await disk(at: path)
    return .state(
      VCSRemoteState(
        current: current, tracking: tracking, remotes: remotes, primaryRemote: primary,
        lastFetch: Self.gitLastFetch(commonGitDir: facts.commonGitDir, disk: facts.disk),
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

  // MARK: - Actions

  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult {
    let dir = Self.opDirectory(.fetch, path: path, projectRoot: projectRoot)
    let args = Self.gitFetchArgs(remote: remote)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: fetchTimeout, network: true)
        })
    else { return .failed(.other("fetch was cancelled")) }
    if let failure = await classify(result, action: .fetch, tool: Self.tool, at: path) {
      return .failed(failure)
    }
    return .ok(summary: "Fetched \(remote)")
  }

  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool
  ) async -> VCSRemoteActionResult {
    let dir = Self.opDirectory(.push, path: path, projectRoot: projectRoot)
    guard let branch = current.name, current.kind == .branch else {
      return .failed(.other("HEAD is detached — check out a branch before pushing."))
    }
    let args = Self.gitPushArgs(branch: branch, remote: remote, setUpstream: setUpstream)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: pushTimeout, network: true)
        })
    else { return .failed(.other("push was cancelled")) }
    if let failure = await classify(result, action: .push, tool: Self.tool, at: path) {
      return .failed(failure)
    }
    return .ok(summary: "Pushed to \(remote)")
  }

  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String,
    tracking: VCSTracking?
  ) async -> VCSRemoteActionResult {
    // Fetch first, at the project root, for the reasons `opDirectory` documents. `pull` would fetch
    // too, but doing it explicitly at the root keeps `FETCH_HEAD` — and so the "last fetched" label —
    // correct for every workroom of the project.
    let fetchDir = Self.opDirectory(.fetch, path: path, projectRoot: projectRoot)
    let fetchArgs = Self.gitFetchArgs(remote: remote)
    guard
      let fetched = await gated(
        projectRoot,
        { [self] in
          await run(fetchArgs, in: fetchDir, timeout: fetchTimeout, network: true)
        })
    else { return .failed(.other("pull was cancelled")) }
    // Both steps classify against the worktree's git directory, since a lock can block either one.
    if let failure = await classify(fetched, action: .pull, tool: Self.tool, at: path) {
      return .failed(failure)
    }

    let dir = Self.opDirectory(.pull, path: path, projectRoot: projectRoot)
    guard let branch = Self.pullBranch(current: current, tracking: tracking) else {
      return .failed(.other("no remote branch to pull from."))
    }
    let args = Self.gitPullArgs(remote: remote, branch: branch)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(args, in: dir, timeout: pullTimeout, network: true)
        })
    else { return .failed(.other("pull was cancelled")) }
    if let failure = await classify(result, action: .pull, tool: Self.tool, at: path) {
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
    let dir = Self.opDirectory(.abortRebase, path: path, projectRoot: projectRoot)
    guard
      let result = await gated(
        projectRoot,
        { [self] in
          await run(Self.gitAbortRebaseArgs(), in: dir, timeout: refTimeout)
        })
    else { return .failed(.other("abort was cancelled")) }
    if let failure = await classify(
      result, action: .abortRebase, tool: Self.tool, at: path, withGitDir: false)
    {
      return .failed(failure)
    }
    return .ok(summary: "Rebase aborted")
  }

  // MARK: - Commit

  func commit(path: String, projectRoot: String, request: VCSCommitRequest) async -> VCSCommitResult
  {
    // A parked merge/cherry-pick/rebase/bisect makes a path-limited commit outright invalid, and
    // finishing it is the user's call. Checked before the ref snapshot so nothing is spawned at all.
    if let sequencer = await parkedOperation(at: path) {
      return .failed(.sequencerInProgress(sequencer))
    }

    // ONE gate acquisition for the whole operation, not one per command. Two would let the 15s
    // status sweep, the FSEvents lane and DiffResolver interleave between the intent-to-add and the
    // commit — contending on `index.lock`.
    //
    // `before` is read INSIDE the gate, not before acquiring it. Outside, anything that moves the ref
    // while this call waits its turn — another window, the user's own terminal during a slow hook — would
    // make the before/after comparison below read a ref that moved for someone else's reason. A
    // commit that genuinely failed would then be reported as `.committedThenFailed`, whose copy tells
    // the user their work is saved and not to commit again. It would not be.
    let outcome = await gated(
      projectRoot,
      { [self] in
        let before = await currentRevision(path: path)
        return CommitAttempt(
          before: before, result: await runCommitSequence(request, in: path, before: before))
      })
    guard let attempt = outcome else { return .failed(.other("commit was cancelled")) }
    let (before, result) = (attempt.before, attempt.result)

    // Read only for a failure, as `classify` does.
    let commitDisk: any RepositoryDisk =
      stat == nil
      ? LocalDisk()
      : result.ok
        ? DiskSnapshot.unknown
        : await disk(at: path, stderr: result.stderr + "\n" + result.stdout).disk
    if let failure = Self.classifyCommit(result, tool: Self.tool, disk: commitDisk) {
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
    return .ok(summary: Self.commitSummary(request.mode), revision: after)
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
  private func runCommitSequence(
    _ request: VCSCommitRequest, in path: String, before: String?
  ) async -> CommandResult {
    if request.mode == .amendMessage {
      return await run(
        Self.gitAmendMessageArgs(message: request.message), in: path,
        timeout: commitTimeout)
    }

    // The commit failed, so undo the index entries we just made. Left behind, an intent-to-add marker
    // is not the harmless residue it looks like: it breaks the user's own `git stash` in the terminal
    // ("Entry 'x' not uptodate. Cannot merge.") until they find and reverse a change they never made.
    //
    // Rolled back for the untracked rows ONLY. Those were definitionally absent from the index, so
    // `rm --cached` reverses exactly our own step. A rename's new side may already be a real staged
    // entry (`git mv`), and unstaging that would destroy work the user did themselves — the wrong
    // trade for tidiness.
    func rollBackIntentToAdd() async {
      let added = Self.pathsAddedToTheIndex(in: request.files)
      guard !added.isEmpty else { return }
      _ = await runner.run(
        Self.tool, Self.gitUnstageArgs(), in: path, timeout: refTimeout,
        stdin: Self.gitPathspecPayload(literalPaths: added))
    }

    // New sides only — see `gitPathspecPayload(literalPaths:)`.
    let unknown = Self.pathsGitMayNotKnow(in: request.files)
    if !unknown.isEmpty {
      let ita = await runner.run(
        Self.tool, Self.gitIntentToAddArgs(), in: path, timeout: refTimeout,
        stdin: Self.gitPathspecPayload(literalPaths: unknown))
      guard ita.ok else {
        // Rolled back HERE too, not only after a failed commit. A killed intent-to-add writes
        // nothing, but a `CommandResult.outcomeUnknown` one may have written every entry before the
        // connection dropped — so the branch that skipped the rollback was the one that most needed
        // it, leaving exactly the `git stash` breakage the comment above documents.
        await rollBackIntentToAdd()
        // Relabelled as its own step, so the copy downstream ("The commit was sent…") cannot claim
        // a commit was attempted when only the staging was. The exit code is carried through
        // unchanged, so `classifyCommit` still reaches the same case — except an unknown outcome,
        // which is the STAGING's: the commit was never sent, so it is known not to have happened,
        // and reporting "may have been written" disabled Commit over a commit nobody attempted.
        let lost = ita.exitCode == CommandResult.outcomeUnknown
        return CommandResult(
          stdout: ita.stdout,
          stderr: ita.stderr.isEmpty
            ? "git could not stage the new files"
            : lost
              ? "Lost contact while staging the new files; nothing was committed. \(ita.stderr)"
              : "Staging the new files failed: \(ita.stderr)",
          exitCode: lost ? CommandResult.refused : ita.exitCode, timedOut: ita.timedOut,
          signaled: ita.signaled)
      }
    }
    let result = await runner.run(
      Self.tool, Self.gitCommitOnlyArgs(message: request.message), in: path, timeout: commitTimeout,
      stdin: Self.gitPathspecPayload(request.files))

    // Only a commit that definitely did not land. One killed in a `post-commit` hook has already
    // moved HEAD, and `rm --cached` would then stage the deletion of every file it just added. An
    // unknown outcome may still be running on the agent, and a HEAD that moved or can no longer be
    // read may hold the commit, so all three keep the marker: residue the user can clear beats a
    // deletion their next commit records.
    if !result.ok, result.exitCode != CommandResult.outcomeUnknown,
      await headIsStill(before, path: path)
    {
      await rollBackIntentToAdd()
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
  /// happens. Empty for a mode that takes no pathspec.
  ///
  /// A pre-flight rather than a refusal: a partially-staged file is a legitimate thing to commit from
  /// — the user just has to know that the version on disk is the one that lands. Silence is the only
  /// unacceptable option, because the loss leaves no trace (`git status` is clean afterwards).
  func stagedContentAtRisk(path: String, files: [ChangedFile]) async throws -> [String] {
    guard !files.isEmpty else { return [] }
    let result = await run(Self.gitStatusPorcelainArgs(), in: path, timeout: refTimeout)
    guard result.ok else { throw VCSError.io("Could not check staged content: \(result.stderr)") }
    return Self.stagedContentAtRisk(
      porcelainZ: result.stdout, selecting: Set(files.map(\.path)))
  }

  /// What the commit dialog shows before it writes. Ungated and read-only: a `rev-parse`-class
  /// read plus a directory listing.
  func commitPreflight(path: String) async throws -> VCSCommitPreflight {
    let head = await run(Self.gitHeadSubjectArgs(), in: path, timeout: refTimeout)
    if !head.ok {
      // An unborn branch is a valid preflight. A missing/corrupt repository or failed runner isn't.
      let unborn = await run(["symbolic-ref", "--quiet", "HEAD"], in: path, timeout: refTimeout)
      let refs = await run(
        [
          "show-ref", "--verify", "--quiet",
          unborn.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
        ], in: path, timeout: refTimeout)
      guard unborn.ok, refs.exitCode == 1, !refs.timedOut, !refs.signaled,
        refs.exitCode != CommandResult.launchFailed
      else {
        throw VCSError.io("Could not read commit preflight: \(head.stderr)")
      }
    }
    let subject =
      head.ok ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return VCSCommitPreflight(
      sequencer: await parkedOperation(at: path),
      // Empty on an unborn branch — a repo with no commits has nothing to amend.
      amendTarget: subject.isEmpty ? nil : subject)
  }

  /// Whether HEAD provably still reads `before`. `currentRevision`'s nil is either an unborn branch
  /// or a failed read, so a nil `before` needs HEAD proved unborn now: a first commit that landed
  /// and whose re-read then failed would otherwise compare `nil == nil`.
  private func headIsStill(_ before: String?, path: String) async -> Bool {
    guard before == nil else { return await currentRevision(path: path) == before }
    let result = await run(Self.gitUnbornHeadArgs(), in: path, timeout: refTimeout)
    // A killed probe reports its signal as the exit code, and SIGHUP is 1.
    return result.exitCode == 1 && !result.signaled && !result.timedOut && result.stdout.isEmpty
  }

  /// The current ref, for the before/after comparison. Ungated and cheap: `rev-parse` touches
  /// nothing.
  ///
  /// Nil for an unborn branch (a repo with no commits), which is a legitimate state to commit from —
  /// `nil != "abc123"` then reads correctly as "the ref moved".
  private func currentRevision(path: String) async -> String? {
    let result = await run(Self.gitHeadArgs(), in: path, timeout: refTimeout)
    guard result.ok else { return nil }
    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  static func commitSummary(_ mode: VCSCommitMode) -> String {
    switch mode {
    case .commit: return "Committed"
    case .amendMessage: return "Amended the last commit"
    }
  }

  /// The stderr a `committedThenFailed` carries, so the dialog can show what went wrong *after* the
  /// commit landed.
  static func commitFailureDetail(_ failure: VCSCommitFailure) -> String {
    switch failure {
    case .toolMissing(let m), .identityMissing(let m), .signingFailed(let m), .hookRejected(let m),
      .unmergedFiles(let m), .sequencerInProgress(let m), .other(let m):
      return m
    // Reached when contact was lost AND the ref moved anyway — so the doubt is already resolved,
    // and this says which half of it survived rather than repeating the "may have completed" copy.
    case .outcomeUnknown(let m):
      return "Lost contact after the commit was written: \(m)"
    case .timedOut: return "The command was stopped at its time limit."
    case .nothingToCommit: return "Nothing to commit."
    case .locked(let file):
      return file.map { "Blocked by \($0.filename)." } ?? "The repository was busy."
    case .launchFailed: return "This workroom’s folder is no longer there."
    }
  }
}
