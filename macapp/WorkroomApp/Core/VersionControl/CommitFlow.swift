import Foundation
import WorkroomDomain
import WorkroomVCS

/// The commit dialog's workflow: the preflight read, the staged-work check, the commit itself, and
/// the phase each of them leaves the dialog in.
///
/// `CommitSheet` holds it as `@State`, so it lives exactly as long as the sheet: closing the sheet
/// drops it, and a late completion then writes into a flow nothing shows. Every race guard below is
/// a check of `phase` (or `preflightState`) at the moment a completion lands, because the user can
/// keep pressing buttons while a read or a hook runs.
@MainActor
@Observable
final class CommitFlow {
  enum Phase: Equatable {
    case editing
    /// Selected paths whose staged content this commit would discard, awaiting confirmation.
    case confirmingStagedLoss([String])
    case committing
    case failed(VCSFailureDialog)
    /// The commit LANDED but a later step failed. Terminal: the only honest action left is to close.
    /// Distinct from `.failed` because retrying here would record the work a second time, and the
    /// notice says so — so the buttons that would do it are disabled rather than merely discouraged.
    case landedThenFailed(VCSFailureDialog)
    /// Contact was lost mid-commit and the ref could not be re-read, so whether the work landed is
    /// unknown — `VCSCommitFailure.outcomeUnknown`.
    ///
    /// Its own case rather than a `.failed`, for `.landedThenFailed`'s exact reason: the button is
    /// the hazard, not the wording. A `.failed` leaves Commit live, and one click on a commit that
    /// did land records it twice — the same defect, on the taxonomy that added a case to name it.
    /// Not folded INTO `.landedThenFailed` either: that one asserts the commit was recorded, and
    /// asserting the verdict is what this whole state exists to avoid.
    case outcomeUnknown(VCSFailureDialog)
  }

  /// What the commit is recorded from, read when the flow needs it rather than captured at the
  /// click: a commit started from a staged-work check's completion records the draft as it is
  /// then.
  struct Draft {
    let message: String
    let files: [ChangedFile]
  }

  /// Everything the flow asks of the app, handed over on each call. The store's three VCS asks
  /// (`AppStore.commitPreflight`, `stagedContentAtRisk`, `performCommit`) for one workroom, the
  /// sheet's draft, and how to close the sheet once the commit has landed cleanly.
  @MainActor
  struct Context {
    var preflight: (@escaping (Result<VCSCommitPreflight, Error>) -> Void) -> Void
    var stagedContentAtRisk: ([ChangedFile], @escaping (Result<[String], Error>) -> Void) -> Void
    var performCommit: (VCSCommitRequest, @escaping (VCSCommitResult) -> Void) -> Void
    var draft: () -> Draft
    var dismiss: () -> Void

    /// `store`'s asks for `sid`, which the caller captured: the selection can move while a hook
    /// runs, and every ask must land on the workroom the sheet was opened for.
    static func store(
      _ store: AppStore, sid: SidebarID, draft: @escaping () -> Draft,
      dismiss: @escaping () -> Void
    ) -> Context {
      Context(
        preflight: { store.commitPreflight(on: sid, completion: $0) },
        stagedContentAtRisk: { store.stagedContentAtRisk(on: sid, files: $0, completion: $1) },
        performCommit: { store.performCommit($0, on: sid, completion: $1) },
        draft: draft, dismiss: dismiss)
    }
  }

  private(set) var phase: Phase = .editing
  private(set) var preflightState = CommitPreflightState()
  /// A parked merge/rebase/cherry-pick/revert/bisect in this worktree, resolved by `prefill`.
  ///
  /// The engine refuses one of these outright, so leaving it out of the sheet's blocked reason meant
  /// composing a whole message and pressing Commit to be told. Read once: finishing a merge is
  /// something the user does in the terminal, and re-polling for it would be a timer against the
  /// filesystem for a state that changes at human speed.
  private(set) var sequencer: String?
  /// The commit `Amend last commit` would rewrite, so the message being replaced is visible BEFORE
  /// the click rather than recoverable only from the reflog afterwards.
  private(set) var amendTarget: String?

  /// Pressing again could duplicate work — either because the commit is on disk, or because nobody
  /// knows whether it is. Both disable the buttons that would do it.
  var isSpent: Bool {
    switch phase {
    case .landedThenFailed, .outcomeUnknown: return true
    default: return false
    }
  }

  /// Everything the dialog has to read from the repo before it can be honest: the amend target and
  /// any parked sequencer operation. Once, on appear, and again only after it failed.
  func prefill(_ context: Context) {
    guard phase != .committing, !isSpent, preflightState.begin() else { return }
    // The fixture's paths are not repos, so every read below would fail and the dialog would show
    // nothing — which is the state these seeds exist to keep testable. Same rationale as
    // `FixtureVCSWriter`.
    #if DEBUG
      if AppEnvironment.current.isFixture {
        _ = preflightState.finish(succeeded: true)
        amendTarget = UITestFixture.amendTargetLabel
        return
      }
    #endif
    // One ask, through the writer. This used to spawn `git` and stat a `.git` directory from the
    // sheet, which works only for a repo on this Mac — see `VCSWriting.commitPreflight`.
    context.preflight { result in
      guard self.phase != .committing, !self.isSpent else { return }
      guard case .success(let preflight) = result else {
        if case .failure(let error) = result, self.preflightState.finish(succeeded: false) {
          self.phase = .failed(
            VCSSyncPresenter.commitFailureDialog(.other(error.localizedDescription), mode: .commit))
        }
        return
      }
      guard self.preflightState.finish(succeeded: true) else { return }
      self.sequencer = preflight.sequencer
      self.amendTarget = preflight.amendTarget
    }
  }

  /// Commit, but check first whether doing so would throw away staged work.
  ///
  /// Only for the plain commit path: amend takes no pathspec. The check is
  /// skipped once confirmed so pressing "Commit anyway" cannot re-raise the same warning (that path
  /// calls `commit` directly, never this).
  ///
  /// Deliberately NOT conditioned on `phase == .editing`. It was, and that made the guard skip itself
  /// on exactly the attempt that needs it most: after a rejected hook the phase is `.failed`, so a
  /// retry fell through to `commit` unchecked — and anything the user staged with `git add -p` while
  /// fixing the rejection was discarded with no warning, unrecoverable except as a dangling blob.
  func commitChecking(mode: VCSCommitMode, _ context: Context) {
    guard preflightState.isReady else {
      prefill(context)
      return
    }
    guard mode == .commit else { return commit(mode: mode, context) }
    let files = context.draft().files
    context.stagedContentAtRisk(files) { result in
      guard self.phase != .committing, !self.isSpent else { return }
      guard case .success(let atRisk) = result else {
        if case .failure(let error) = result {
          self.phase = .failed(
            VCSSyncPresenter.commitFailureDialog(.other(error.localizedDescription), mode: mode))
        }
        return
      }
      // The sheet can move on while that `git status` runs — the secondary verb stays pressable
      // during the round-trip. Without this re-check, a late result would stamp
      // `.confirmingStagedLoss` over a commit already in flight, re-enabling the primary and letting
      // a second concurrent commit through on the same repo.
      if atRisk.isEmpty {
        self.commit(mode: mode, context)
      } else {
        self.phase = .confirmingStagedLoss(atRisk)
      }
    }
  }

  func commit(mode: VCSCommitMode, _ context: Context) {
    guard preflightState.isReady else {
      prefill(context)
      return
    }
    guard phase != .committing else { return }
    let draft = context.draft()
    phase = .committing
    let request = VCSCommitRequest(
      message: draft.message,
      files: mode == .amendMessage ? [] : draft.files, mode: mode)
    context.performCommit(request) { result in
      switch result {
      case .ok:
        context.dismiss()
      case .committedThenFailed(_, let detail):
        // The commit LANDED. Closing would be a lie by omission, and offering a retry would create a
        // second commit, so the sheet stays up saying exactly that — and `.landedThenFailed` disables
        // the buttons that would do it, rather than leaving the advice and the affordance in
        // contradiction.
        self.phase = .landedThenFailed(
          VCSFailureDialog(
            title: "Committed, but something afterwards failed",
            message:
              "The commit was recorded. A step that runs after it — usually a post-commit hook — "
              + "then failed. Do not commit again; the change is already saved.",
            details: detail, recovery: nil, lockPath: nil))
      case .failed(.outcomeUnknown(let reason)):
        // Routed away from `.failed` so `isSpent` disables Commit: the work may be on disk, and the
        // notice telling the user to check the history is worth nothing beside a live button.
        self.phase = .outcomeUnknown(
          VCSSyncPresenter.commitFailureDialog(.outcomeUnknown(reason), mode: mode))
      case .failed(let failure):
        self.phase = .failed(VCSSyncPresenter.commitFailureDialog(failure, mode: mode))
      }
    }
  }
}
