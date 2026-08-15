import Defaults
import Foundation

/// Store-owned state for the VCS toolbar: the selected workroom's branch, its divergence from the
/// remote, when the project last fetched, and the fetch/push/pull actions.
///
/// Modelled on `HistoryModel` — same `State`/`isSettled`, the same **pre-dispatch** trailing debounce,
/// cancel-and-replace, and the same injected-resolver seam. The debounce reasoning transfers verbatim:
/// arrow-key cycling the sidebar re-points this model per row, and each read spawns processes.
@MainActor
final class RemoteStateModel: ObservableObject {
  enum State: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isSettled: Bool {
      switch self {
      case .loaded, .failed: return true
      case .idle, .loading: return false
      }
    }
  }

  /// What the model is pointed at. Carries `projectRoot` because fetch always runs there, and `vcs`
  /// because the tool floor is scoped per backend.
  struct Target: Equatable, Sendable {
    let sid: SidebarID
    let path: String
    let vcs: VCSBackend
    let projectRoot: String
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var snapshot: VCSRemoteState?
  /// The single in-flight action, or nil. Drives the spinner on the acting segment AND disables all of
  /// them, so a second click can't double-fire and Push can't race Pull.
  @Published private(set) var inFlight: VCSRemoteAction?
  /// The last action failure. Kept SEPARATE from `state` so a failed push never blanks a good snapshot
  /// — the `keepPrior` rule the CI/PR resolvers already follow. Cleared on the next action or refresh.
  @Published private(set) var lastFailure: VCSRemoteFailure?
  /// The failure from the last READ, typed. `state.failed` carries the same thing already described into a
  /// `String`, which is a dead end: nothing renders `state`, and a description can't be classified. So a
  /// read blocked by `packed-refs.lock` reached the toolbar as a nil snapshot and rendered "No
  /// repository" — a wrong diagnosis of a healthy repo. Cleared by every settled read that isn't a
  /// failure, so it can never outlive the condition.
  @Published private(set) var readFailure: VCSRemoteFailure?
  /// Whether a USER-REQUESTED read is running — the read-failure tier's "Try Again". Distinct from
  /// `state == .loading`, which is true for every automatic read too (the 15s sweep, the metadata
  /// watcher): a spinner on those would flicker in the bar continuously. Without this the retry was the
  /// only clickable cell in the toolbar that acknowledged a click with nothing at all.
  @Published private(set) var readInFlight = false
  /// Which action produced `lastFailure`, so the segment can offer the right retry.
  @Published private(set) var lastAction: VCSRemoteAction?
  /// The failure the dialog is showing, or nil. Raised only for user-initiated actions — see
  /// `VCSFailureReport` — and cleared by `dismissFailureReport`. Separate from `lastFailure`, which is the
  /// toolbar's persistent notice: dismissing the dialog must not erase the bar's report of what happened.
  @Published private(set) var failureReport: VCSFailureReport?
  /// Set when a pull succeeded but left conflicts. jj records conflicts INSIDE commits and its rebase
  /// exits 0, so the exit code can't tell — this is raised by `noteConflictState` from the status
  /// refresh that follows a mutation, i.e. after the gate has released (re-reading inside it would
  /// deadlock the project's queue).
  @Published private(set) var lastPullConflicted = false

  private(set) var target: Target?
  private let makeWriter: @Sendable (URL) throws -> VCSWriting
  private let debounce: TimeInterval
  private let ttl: TimeInterval
  /// Minimum gap between automatic fetches for one project. An automatic fetch is a network call the
  /// user didn't ask for, so it must be rare enough to be unremarkable.
  private let autoFetchInterval: TimeInterval
  private let now: @Sendable () -> Date
  private var task: Task<Void, Never>?
  private var actionTask: Task<Void, Never>?
  /// Which workroom the in-flight action belongs to.
  ///
  /// `inFlight` is a model-WIDE lock — one action at a time, because the writer and `JJSnapshotGate` are
  /// shared — but the toolbar renders per selection, so "an action is running" and "an action is running
  /// *here*" are different questions. Without this, switching workrooms mid-push left the newly selected
  /// one showing "Pushing…" with every segment disabled until the other workroom's action finished (up to
  /// 300s for a pull).
  private var inFlightTarget: Target?
  /// When each project last auto-fetched, in-memory (a relaunch may legitimately fetch again).
  private var lastAutoFetch: [String: Date] = [:]
  /// Monotonic id for `failureReport`. See `VCSFailureReport.sequence` for why a repeat needs a new one.
  private var failureSequence = 0

  /// Fired after a successful mutation so the store can refresh everything downstream — workroom
  /// status (the dirty/conflict badge), the commit history, and this model itself. Wired post-init so
  /// the model needs no `AppStore` to be unit-tested (the `workroomFileWatcher` idiom).
  var onDidMutate: (@MainActor (VCSRemoteAction, SidebarID) -> Void)?
  /// Publishes the resolved branch name so `AppStore.branchName(for:)` — the one accessor every
  /// branch-showing surface reads — can lead with it. This model is the only writer.
  var onBranchResolved: (@MainActor (SidebarID, String?) -> Void)?
  /// Resolves a target's human label ("platform / fix-auth"), for naming the workroom a failure belongs
  /// to when it is no longer the selected one. Wired post-init to `AppStore.label(for:)` for the same
  /// reason the two callbacks above are: the model stays `AppStore`-free and unit-testable.
  var describeTarget: (@MainActor (SidebarID) -> String?)?
  /// Whether a write is already in flight for this project root, IN ANY WINDOW — `inFlight` above is
  /// only this one model's own single-action lock, which does nothing against a second window's
  /// `RemoteStateModel` (each has its own `inFlight`, as it must to render its own spinner). Checked
  /// before starting an action; a `true` result refuses with `.locked(nil)` rather than queuing into
  /// `JJSnapshotGate` and possibly racing a live write past its wedge-detection ceiling. Wired post-init
  /// to `AppStore.isWritingProject`, same `AppStore`-free reasoning as the callbacks above. Defaults to
  /// "never busy" so a model built without this wired (e.g. in isolation for a unit test) behaves as
  /// today rather than silently refusing everything.
  var canStartWrite: (@MainActor (String) -> Bool)?
  /// Marks a write starting/finishing against a project root, wired to `AppStore.beginWrite`/`endWrite`.
  /// Paired unconditionally around the action's `Task` in `perform`/`finish`, mirroring how
  /// `performCommit` pairs its own `beginWrite`/`endWrite` calls.
  var writeDidStart: (@MainActor (String) -> Void)?
  var writeDidFinish: (@MainActor (String) -> Void)?

  init(
    makeWriter: @escaping @Sendable (URL) throws -> VCSWriting = { try VCS.writer(for: $0) },
    debounce: TimeInterval = 0.3, ttl: TimeInterval = 15,
    autoFetchInterval: TimeInterval = 300,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.makeWriter = makeWriter
    self.debounce = debounce
    self.ttl = ttl
    self.autoFetchInterval = autoFetchInterval
    self.now = now
  }

  // MARK: Focus

  /// Point the model at a workroom (or clear it with `nil`). No-op if already there.
  func focus(_ target: Target?) {
    guard self.target != target else { return }
    self.target = target
    snapshot = nil
    lastFailure = nil
    readFailure = nil
    // A dialog left open over a workroom the user has moved away from is reporting someone else's
    // problem — the same reasoning that makes `finish` check the target before publishing anything.
    failureReport = nil
    lastPullConflicted = false
    guard target != nil else {
      task?.cancel()
      state = .idle
      readInFlight = false
      return
    }
    load()
  }

  /// The panel's `.task`: on a genuine re-entry (same target, a load already settled) pull fresh;
  /// otherwise defer to `focus`. The `isSettled` guard prevents a redundant second read when the store
  /// just called `focus` eagerly, and retries after a transient failure.
  func activate(_ target: Target?) {
    if self.target == target, target != nil, state.isSettled {
      refresh()
    } else {
      focus(target)
    }
  }

  /// Re-read because the USER asked — the read-failure tier's "Try Again". Always forced (the TTL is for
  /// automatic callers), never debounced, and flagged so the segment can show the read in flight.
  func retryRead() {
    guard target != nil else { return }
    load(skipDebounce: true)
  }

  /// Re-read. TTL-gated unless `force` — a watcher can fire several times for one logical change.
  func refresh(force: Bool = false) {
    guard target != nil else { return }
    if !force, let resolvedAt = snapshot?.resolvedAt, now().timeIntervalSince(resolvedAt) < ttl {
      return
    }
    load()
  }

  /// Await whatever is in flight.
  ///
  /// Order matters: an action schedules a refresh when it finishes, so the action must be awaited
  /// FIRST and the load task re-read afterwards. Awaiting `task` first captures the pre-action load and
  /// returns before the refresh the action queued has even been created.
  func awaitCurrentLoad() async {
    await actionTask?.value
    await task?.value
  }

  /// `skipDebounce` is for a read the USER asked for — the read-failure tier's "Try Again". The debounce
  /// exists to collapse a burst of selection changes, and a click is not a burst: paying it there delays
  /// the acknowledgement of the one action on that tier by 300ms for no benefit.
  private func load(skipDebounce: Bool = false) {
    guard let target else { return }
    task?.cancel()
    state = .loading
    // Only for a retry the user clicked: an automatic read must not put a spinner in the bar (the sweep
    // and the watcher fire constantly, and a flickering segment reads as instability, not as progress).
    readInFlight = skipDebounce
    let makeWriter = self.makeWriter
    let debounce = skipDebounce ? 0 : self.debounce
    task = Task { [weak self] in
      if debounce > 0 {
        try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
        if Task.isCancelled { return }
      }
      let root = URL(fileURLWithPath: target.path, isDirectory: true)
      let resolution: VCSRemoteResolution
      do {
        resolution = await (try makeWriter(root)).remoteState(
          path: target.path, projectRoot: target.projectRoot)
      } catch {
        resolution = .absent
      }
      if Task.isCancelled { return }
      self?.apply(resolution, for: target)
    }
  }

  private func apply(_ resolution: VCSRemoteResolution, for target: Target) {
    // Cleared for whatever target the read belonged to — the spinner tracks THIS read, and leaving it
    // set after a target switch would strand a "Trying again…" on a workroom that isn't reading.
    readInFlight = false
    // A read that finished after the model moved on must not overwrite the new target's state.
    guard self.target == target else { return }
    switch resolution {
    case .state(let state):
      // Merge in Workroom's own fetch record. Needed because jj's fetch is invisible: it passes
      // `--no-write-fetch-head`, and a fetch that brings nothing records NO operation at all — so the
      // op-log scan alone would mean "last fetch that changed something", and clicking Fetch with
      // nothing new would leave a stale timestamp on screen. The backend still wins when it is newer,
      // which keeps a fetch run in the user's own terminal visible.
      snapshot = Self.merging(state, ownFetch: Defaults[.vcsLastFetch][target.projectRoot])
      self.state = .loaded
      readFailure = nil
      onBranchResolved?(target.sid, state.current.name)
    case .absent:
      snapshot = nil
      self.state = .loaded
      // A definitive "not a repo" is an answer, not a failure — [2] "No repository" is the honest tier
      // for it, so any earlier read failure is over.
      readFailure = nil
      onBranchResolved?(target.sid, nil)
    case .keepPrior:
      // A transient blip — leave the last good snapshot standing rather than blanking the toolbar. Also
      // leaves `readFailure` standing: a blip is not evidence that a previous failure has cleared.
      self.state = snapshot == nil ? .idle : .loaded
    case .failed(let failure):
      snapshot = nil
      self.state = .failed(VCSSyncPresenter.describe(failure))
      readFailure = failure
      onBranchResolved?(target.sid, nil)
    }
  }

  /// Take the later of the backend's own evidence and Workroom's recorded fetch.
  static func merging(_ state: VCSRemoteState, ownFetch: Date?) -> VCSRemoteState {
    guard let ownFetch else { return state }
    let merged: VCSLastFetch
    switch state.lastFetch {
    case .at(let backend): merged = .at(max(backend, ownFetch))
    case .never, .unknown: merged = .at(ownFetch)
    }
    return VCSRemoteState(
      current: state.current, tracking: state.tracking, remotes: state.remotes,
      primaryRemote: state.primaryRemote, lastFetch: merged, resolvedAt: state.resolvedAt)
  }

  // MARK: Derived

  /// The in-flight action IF it belongs to the workroom currently on screen — what the toolbar renders.
  ///
  /// Distinct from `inFlight`, which is the model-wide lock and is what `canFetch`/`canPush`/`canPull`
  /// gate on: a second action must be blocked even when it was started from another workroom, because
  /// the writer and the gate are shared. Only the LABEL is per-target.
  var activeAction: VCSRemoteAction? { inFlightTarget == target ? inFlight : nil }

  var canFetch: Bool { snapshot?.primaryRemote != nil && inFlight == nil }
  var canPush: Bool { snapshot?.primaryRemote != nil && inFlight == nil }
  /// Pull needs something to pull FROM: a counterpart that exists on the remote.
  var canPull: Bool {
    guard snapshot?.primaryRemote != nil, inFlight == nil else { return false }
    guard let tracking = snapshot?.tracking else { return false }
    return !tracking.gone
  }

  func canPerform(_ action: VCSRemoteAction) -> Bool {
    switch action {
    case .fetch: return canFetch
    case .push: return canPush
    case .pull: return canPull
    case .abortRebase: return inFlight == nil
    }
  }

  // MARK: Actions

  /// Perform an action. Dropped if one is already in flight — the model is deliberately single-action
  /// so a double-click can't fire twice and Push can't race Pull.
  ///
  /// `anonymousRevision` matters only for a jj workroom whose `@` carries no bookmark: pushing a bare
  /// `@` fails when the working copy is empty and undescribed, which is exactly the state a fresh
  /// workroom sits in. Callers pass `CLIVCSWriter.jjPushRevision(hasChanges:hasDescription:)`.
  ///
  /// `userInitiated` decides whether a failure gets a dialog. Only `autoFetchIfDue` passes `false`.
  func perform(
    _ action: VCSRemoteAction, setUpstream: Bool = false, anonymousRevision: String = "@",
    userInitiated: Bool = true
  ) {
    guard inFlight == nil, let target, let snapshot else { return }
    // Aborting a rebase is purely local — requiring a remote would leave a workroom wedged in a rebase
    // with no way out from the UI, which is the one state where recovery matters most.
    let remote = snapshot.primaryRemote ?? ""
    if remote.isEmpty, action != .abortRebase {
      lastFailure = .noRemote
      lastAction = action
      if userInitiated { raiseFailureReport(.noRemote, action: action) }
      return
    }
    // Refuse outright rather than queue behind another write (this window or another) on the same
    // project root — see `canStartWrite`'s doc for why. `inFlight == nil` above only rules out THIS
    // model's own action; this is the cross-window half.
    if canStartWrite?(target.projectRoot) == false {
      lastFailure = .locked(nil)
      lastAction = action
      if userInitiated { raiseFailureReport(.locked(nil), action: action) }
      return
    }
    inFlight = action
    inFlightTarget = target
    lastAction = action
    lastFailure = nil
    failureReport = nil
    lastPullConflicted = false
    let makeWriter = self.makeWriter
    let current = snapshot.current
    let tracking = snapshot.tracking
    let projectRoot = target.projectRoot
    writeDidStart?(projectRoot)
    // Captured as a local NOW, not read through `self` after the `await` below: if this model (or
    // its owning `AppStore`) is deallocated before the write finishes — the window closed mid-write
    // — `self?.writeDidFinish` would silently no-op and leak the cross-window write-in-flight mark
    // forever. The closure value itself is held by this `Task`, independent of `self`'s lifetime.
    let finishWrite = writeDidFinish
    actionTask = Task { [weak self] in
      let root = URL(fileURLWithPath: target.path, isDirectory: true)
      let result: VCSRemoteActionResult
      do {
        let writer = try makeWriter(root)
        switch action {
        case .fetch:
          result = await writer.fetch(
            path: target.path, projectRoot: target.projectRoot, remote: remote)
        case .push:
          result = await writer.push(
            path: target.path, projectRoot: target.projectRoot, current: current, remote: remote,
            setUpstream: setUpstream, anonymousRevision: anonymousRevision)
        case .pull:
          result = await writer.pullRebase(
            path: target.path, projectRoot: target.projectRoot, current: current, remote: remote,
            tracking: tracking)
        case .abortRebase:
          result = await writer.abortRebase(path: target.path, projectRoot: target.projectRoot)
        }
      } catch {
        result = .failed(.other("\(error)"))
      }
      finishWrite?(projectRoot)
      self?.finish(action, result: result, for: target, userInitiated: userInitiated)
    }
  }

  private func finish(
    _ action: VCSRemoteAction, result: VCSRemoteActionResult, for target: Target,
    userInitiated: Bool
  ) {
    // Always cleared: the action really is over, and this is the model-wide single-action lock. What is
    // NOT unconditional is the RESULT, below.
    inFlight = nil
    inFlightTarget = nil
    // The work happened in `target`'s repo whatever is selected now, so the fetch stamp and the
    // downstream refresh belong to it and fire regardless.
    if case .ok = result {
      if action == .fetch || action == .pull { recordOwnFetch(projectRoot: target.projectRoot) }
      onDidMutate?(action, target.sid)
    }
    // The DIALOG is deliberately raised ahead of the identity guard below. Something the user asked for
    // failed, and that fact belongs to them, not to the current selection: with the report behind the
    // guard, starting a push and switching workrooms mid-flight reported the failure nowhere at all —
    // no dialog, no toolbar notice, no record. The spinner stopped and nothing said why. The workroom is
    // named whenever it isn't the one on screen, so the dialog can't be misread as this one's failure.
    if case .failed(let failure) = result, userInitiated {
      raiseFailureReport(
        failure, action: action,
        workroom: self.target == target ? nil : describeTarget?(target.sid))
    }
    // Everything past here writes PUBLISHED state that the toolbar renders for whatever is selected NOW,
    // so it needs the same guard `apply` has. Without it, starting a push in one workroom and switching
    // to another put the first one's failure — and its action label — on the second one's toolbar,
    // reporting a failure for a workroom where nothing was attempted.
    guard self.target == target else { return }
    switch result {
    case .ok:
      lastFailure = nil
      // Re-read immediately AND let the store refresh everything downstream. The metadata watcher
      // would get there on its own, but its coalesce window is ~1s and the toolbar should feel instant.
      refresh(force: true)
    case .failed(let failure):
      // Deliberately leaves `snapshot` intact: a failed action tells you nothing new about the repo.
      // The dialog for this failure was already raised above, ahead of the guard.
      lastFailure = failure
    }
  }

  /// Put a failure in front of the user. The toolbar's one truncating line can't carry the message, so
  /// anything the user asked for and that failed gets the dialog. `workroom` names where it happened,
  /// and is passed only when that isn't the current selection — see `VCSFailureReport.workroom`.
  private func raiseFailureReport(
    _ failure: VCSRemoteFailure, action: VCSRemoteAction?, workroom: String? = nil,
    isRead: Bool = false
  ) {
    failureSequence += 1
    failureReport = VCSFailureReport(
      failure: failure, action: action, workroom: workroom, isRead: isRead,
      sequence: failureSequence)
  }

  /// Re-open the dialog for the failure the toolbar is currently reporting — the segment's "Show Error
  /// Details…" item. No-op when there is nothing to show.
  ///
  /// Same precedence as the tier ladder: an action failure outranks a read failure, so the dialog can't
  /// describe a different failure than the bar. A read failure names no action, because none was taken.
  func presentFailureDetails() {
    if let lastFailure {
      raiseFailureReport(lastFailure, action: lastAction)
    } else if let readFailure {
      raiseFailureReport(readFailure, action: nil, isRead: true)
    }
  }

  /// Close the dialog. `lastFailure` deliberately survives: the bar goes on reporting the failure until
  /// the next action or refresh, so dismissing the dialog doesn't erase the fact that something failed.
  func dismissFailureReport() {
    failureReport = nil
  }

  /// Stamp Workroom's own fetch time for this project. See `merging` for why this exists.
  private func recordOwnFetch(projectRoot: String) {
    var stamps = Defaults[.vcsLastFetch]
    stamps[projectRoot] = now()
    Defaults[.vcsLastFetch] = stamps
  }

  /// Called by the store after the post-mutation status refresh lands: a pull that reported success may
  /// still have produced conflicts (jj writes them into commits and exits 0).
  /// `sid` is the workroom the pull ran in — checked, not trusted, for the same reason `finish` checks it:
  /// the sweep this waits on is async, so the selection can move before it lands.
  func noteConflictState(_ conflicted: Bool, for sid: SidebarID) {
    guard target?.sid == sid, lastAction == .pull, lastFailure == nil else { return }
    lastPullConflicted = conflicted
  }

  // MARK: Auto-fetch

  /// Fetch when the inspector gains focus, at most once per `autoFetchInterval` per project.
  ///
  /// Automatic, so it must be quiet: a failure sets `lastFailure` for the toolbar but raises no dialog
  /// (`userInitiated: false`) and never blocks the read path. Callers gate on the inspector being visible
  /// with the Changes section active, so a hidden toolbar never triggers a network call.
  func autoFetchIfDue() {
    guard let target, inFlight == nil, let snapshot, snapshot.primaryRemote != nil else { return }
    if let last = lastAutoFetch[target.projectRoot],
      now().timeIntervalSince(last) < autoFetchInterval
    {
      return
    }
    lastAutoFetch[target.projectRoot] = now()
    perform(.fetch, userInitiated: false)
  }
}
