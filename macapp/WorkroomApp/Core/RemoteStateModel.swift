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
    let vcs: String
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
  /// Which action produced `lastFailure`, so the segment can offer the right retry.
  @Published private(set) var lastAction: VCSRemoteAction?
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
  /// When each project last auto-fetched, in-memory (a relaunch may legitimately fetch again).
  private var lastAutoFetch: [String: Date] = [:]

  /// Fired after a successful mutation so the store can refresh everything downstream — workroom
  /// status (the dirty/conflict badge), the commit history, and this model itself. Wired post-init so
  /// the model needs no `AppStore` to be unit-tested (the `workroomFileWatcher` idiom).
  var onDidMutate: (@MainActor (VCSRemoteAction) -> Void)?
  /// Publishes the resolved branch name so `AppStore.branchName(for:)` — the one accessor every
  /// branch-showing surface reads — can lead with it. This model is the only writer.
  var onBranchResolved: (@MainActor (SidebarID, String?) -> Void)?

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
    lastPullConflicted = false
    guard target != nil else {
      task?.cancel()
      state = .idle
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

  private func load() {
    guard let target else { return }
    task?.cancel()
    state = .loading
    let makeWriter = self.makeWriter
    let debounce = self.debounce
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
      onBranchResolved?(target.sid, state.current.name)
    case .absent:
      snapshot = nil
      self.state = .loaded
      onBranchResolved?(target.sid, nil)
    case .keepPrior:
      // A transient blip — leave the last good snapshot standing rather than blanking the toolbar.
      self.state = snapshot == nil ? .idle : .loaded
    case .failed(let failure):
      snapshot = nil
      self.state = .failed(VCSSyncPresenter.describe(failure))
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
  func perform(
    _ action: VCSRemoteAction, setUpstream: Bool = false, anonymousRevision: String = "@"
  ) {
    guard inFlight == nil, let target, let snapshot else { return }
    // Aborting a rebase is purely local — requiring a remote would leave a workroom wedged in a rebase
    // with no way out from the UI, which is the one state where recovery matters most.
    let remote = snapshot.primaryRemote ?? ""
    if remote.isEmpty, action != .abortRebase {
      lastFailure = .noRemote
      lastAction = action
      return
    }
    inFlight = action
    lastAction = action
    lastFailure = nil
    lastPullConflicted = false
    let makeWriter = self.makeWriter
    let current = snapshot.current
    let tracking = snapshot.tracking
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
      self?.finish(action, result: result, for: target)
    }
  }

  private func finish(_ action: VCSRemoteAction, result: VCSRemoteActionResult, for target: Target)
  {
    inFlight = nil
    switch result {
    case .ok:
      lastFailure = nil
      if action == .fetch || action == .pull { recordOwnFetch(projectRoot: target.projectRoot) }
      // Re-read immediately AND let the store refresh everything downstream. The metadata watcher
      // would get there on its own, but its coalesce window is ~1s and the toolbar should feel instant.
      refresh(force: true)
      onDidMutate?(action)
    case .failed(let failure):
      // Deliberately leaves `snapshot` intact: a failed action tells you nothing new about the repo.
      lastFailure = failure
    }
  }

  /// Stamp Workroom's own fetch time for this project. See `merging` for why this exists.
  private func recordOwnFetch(projectRoot: String) {
    var stamps = Defaults[.vcsLastFetch]
    stamps[projectRoot] = now()
    Defaults[.vcsLastFetch] = stamps
  }

  /// Called by the store after the post-mutation status refresh lands: a pull that reported success may
  /// still have produced conflicts (jj writes them into commits and exits 0).
  func noteConflictState(_ conflicted: Bool) {
    guard lastAction == .pull, lastFailure == nil else { return }
    lastPullConflicted = conflicted
  }

  // MARK: Auto-fetch

  /// Fetch when the inspector gains focus, at most once per `autoFetchInterval` per project.
  ///
  /// Automatic, so it must be quiet: a failure sets `lastFailure` for the tooltip but raises no alert
  /// and never blocks the read path. Callers gate on the inspector being visible with the Changes
  /// section active, so a hidden toolbar never triggers a network call.
  func autoFetchIfDue() {
    guard let target, inFlight == nil, let snapshot, snapshot.primaryRemote != nil else { return }
    if let last = lastAutoFetch[target.projectRoot],
      now().timeIntervalSince(last) < autoFetchInterval
    {
      return
    }
    lastAutoFetch[target.projectRoot] = now()
    perform(.fetch)
  }
}
