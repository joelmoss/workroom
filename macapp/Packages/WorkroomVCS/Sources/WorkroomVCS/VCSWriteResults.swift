import Foundation

/// A VCS action the toolbar can perform.
public enum VCSRemoteAction: String, Equatable, Sendable, CaseIterable {
  case fetch, push, pull, abortRebase

  public var label: String {
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
public enum VCSRemoteFailure: Equatable, Sendable {
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
  /// reachable on the daemon-routed path, where a lost connection, a client-side deadline or a
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

/// A failure raised for the user's attention, carried to the failure dialog.
///
/// Only ever raised for a **user-initiated** action. The automatic fetch deliberately doesn't raise one:
/// it's a network call nobody asked for, so failing it must stay as quiet as succeeding it
/// (`RemoteStateModel.autoFetchIfDue`). It still records `lastFailure`, so the toolbar tells the story.
///
/// `sequence` is the identity, not the failure: presenting the same failure twice — a retry that fails
/// identically, or the user re-opening the details — must count as a NEW presentation, and a `.sheet(item:)`
/// keyed on the failure's own value would silently skip the second one.
public struct VCSFailureReport: Identifiable, Equatable, Sendable {
  public let failure: VCSRemoteFailure
  /// What was attempted, so the dialog's title can name it.
  public let action: VCSRemoteAction?
  /// Where it was attempted, named ONLY when that is no longer what's selected — an action can outlive
  /// the selection it started from (a push takes as long as it takes), and an unattributed dialog
  /// arriving over a different workroom reads as a failure of the one on screen.
  public let workroom: String?
  /// True when the failure came from READING the repo rather than from an action, so the dialog titles
  /// itself accordingly instead of naming an action that never ran.
  public let isRead: Bool
  public let sequence: Int
  public var id: Int { sequence }

  public init(
    failure: VCSRemoteFailure, action: VCSRemoteAction?, workroom: String?, isRead: Bool,
    sequence: Int
  ) {
    self.failure = failure
    self.action = action
    self.workroom = workroom
    self.isRead = isRead
    self.sequence = sequence
  }
}

/// A lock file found blocking a VCS operation.
///
/// Located by parsing the path out of git's own error, which names it exactly, then stat-ing it — so the
/// file reported is the one git actually complained about rather than a guess at which lock it might be.
public struct VCSLockFile: Equatable, Sendable {
  public let path: String
  public let modifiedAt: Date
  /// False for a lock file on a remote host: its path names nothing on this Mac, so there is nothing
  /// here to reveal in Finder (`VCSSyncPresenter.lockPath`).
  public var isOnThisMac = true

  public var filename: String { (path as NSString).lastPathComponent }

  public init(path: String, modifiedAt: Date, isOnThisMac: Bool = true) {
    self.path = path
    self.modifiedAt = modifiedAt
    self.isOnThisMac = isOnThisMac
  }
}

/// What a remote-state read decided. Mirrors `CIResolution`/`PRResolution`, `keepPrior` included: a
/// transient blip must not blank a good toolbar.
public enum VCSRemoteResolution: Equatable, Sendable {
  case state(VCSRemoteState)
  /// Not a git repo, or a repo with no refs at all (a fresh `git init`).
  case absent
  case keepPrior
  case failed(VCSRemoteFailure)
}

/// What an action decided. There is deliberately no `okWithConflicts`: `RemoteStateModel` upgrades
/// a `.ok` pull to "conflicted" from the status refresh it already triggers, after the gate has
/// released.
public enum VCSRemoteActionResult: Equatable, Sendable {
  case ok(summary: String)
  case failed(VCSRemoteFailure)
}

// MARK: - Commit

/// Which commit verb to run. Deliberately NOT folded into `VCSRemoteAction`: that enum feeds
/// `VCSRemoteFailure.timedOut`, `PendingVCSAction` and the toolbar's labels, none of which mean
/// anything for a purely local write.
public enum VCSCommitMode: String, Equatable, Sendable {
  case commit, amendMessage
}

/// One commit, fully specified. `files` carries `ChangedFile` rather than `String` because a rename
/// needs BOTH sides of the pathspec — see `gitPathspecPayload`.
public struct VCSCommitRequest: Equatable, Sendable {
  public let message: String
  /// The user's selection.
  public let files: [ChangedFile]
  public let mode: VCSCommitMode

  public init(message: String, files: [ChangedFile], mode: VCSCommitMode) {
    self.message = message
    self.files = files
    self.mode = mode
  }
}

public enum VCSCommitResult: Equatable, Sendable {
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
public enum VCSCommitFailure: Equatable, Sendable {
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
public struct VCSCommitPreflight: Equatable, Sendable {
  /// A parked merge/cherry-pick/revert/rebase/bisect, named for the user. `commit`
  /// refuses outright while one is parked (`VCSCommitFailure.sequencerInProgress`), so the dialog
  /// says so up front instead of letting someone compose a whole message to be told at the click.
  public let sequencer: String?
  /// The subject of the commit `.amendMessage` would rewrite. Shown so the message being
  /// destroyed is visible BEFORE the click rather than recoverable only from the reflog.
  public let amendTarget: String?
  public static let none = VCSCommitPreflight(sequencer: nil, amendTarget: nil)

  public init(sequencer: String?, amendTarget: String?) {
    self.sequencer = sequencer
    self.amendTarget = amendTarget
  }
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
public protocol LocalVCSWriting: Sendable {
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
  public func stagedContentAtRisk(path: String, files: [ChangedFile]) async throws -> [String] {
    []
  }

  /// Default: nothing to report, so the dialog opens with empty fields.
  ///
  /// This default never throws, unlike `LocalVCSProviding.workingStatus`'s default, and the
  /// difference is deliberate.
  /// A wrong `workingStatus` default reports every workroom clean — a plausible-looking lie that
  /// survives a release. Every field here is optional and the dialog renders each one's absence
  /// honestly: no amend label, no parked-operation notice, an empty message box. A conformer that
  /// forgets this degrades visibly and cannot mislabel anything.
  public func commitPreflight(path: String) async throws -> VCSCommitPreflight { .none }
}
