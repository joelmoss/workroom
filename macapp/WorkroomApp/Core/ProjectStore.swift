import Foundation
import WorkroomDomain
import WorkroomVCS

/// Shared, app-wide project data: the project list plus everything derived from it that is
/// identical across windows — root branch labels, the VCS/CI status cache, GitHub-CLI
/// availability, and the in-flight project busy set. Extracted from `AppStore` (issue #70) so that
/// multiple per-window `AppStore`s can share one project list while each keeps its own selection,
/// terminals, splits, history, and run state.
///
/// `AppStore` proxies these properties; Observation tracks them through it. List requests are
/// ordered here across windows; each `AppStore` reconciles its own window after an accepted read.
@MainActor
@Observable
final class ProjectStore {
  /// The shared instance used in production (every window's `AppStore` points at it). Tests
  /// construct an isolated `AppStore()`, which gets its own fresh `ProjectStore`, so they never
  /// pollute this singleton or each other.
  static let shared = ProjectStore()

  /// The list of configured projects (from the CLI's `~/.config/workroom/config.json`). The one
  /// piece of state shared across all windows.
  var projects: [Project] = []
  /// The app-wide base branch for projects that name none; nil means origin's default branch.
  var globalBaseBranch: String?

  /// A read is stamped when issued, across all windows (#170). Superseded callers await
  /// the newest read too. Success publishes its result; failure leaves the project list unchanged.
  struct Load {
    let generation: UInt64
    let task: Task<ListResponse, Error>
  }

  var prepareRepositories: @Sendable ([Project]) async throws -> [RepositoryRouter.Registration] = {
    try await RepositoryRouter.prepare($0)
  }

  private(set) var latestLoad: Load?
  private var loadGeneration: UInt64 = 0
  private var publishedLoadGeneration: UInt64 = 0

  func beginLoad(cli: WorkroomCLIProtocol, warnings: String) -> Load {
    loadGeneration += 1
    let load = Load(
      generation: loadGeneration,
      task: Task { try await cli.list(warnings: warnings, project: nil) })
    latestLoad = load
    return load
  }

  /// Called synchronously with publication on the main actor. Other waiters reconcile their
  /// own window against `projects` without republishing the same raw CLI snapshot.
  func claimPublication(of load: Load) -> Bool {
    guard load.generation == loadGeneration, load.generation > publishedLoadGeneration else {
      return false
    }
    publishedLoadGeneration = load.generation
    return true
  }

  /// Per-project resolved root branch labels, hydrated asynchronously after each load.
  var rootRefs: [Project.ID: RootRef] = [:]

  /// Per-workroom (and per-root) VCS + CI status driving the ambient badges and the Changes panel
  /// (issue #24), keyed by `SidebarID`. Resolved app-side, best-effort/"last checked". Shared so two
  /// windows showing the same workroom report a consistent badge and don't double the probes.
  var workroomStatuses: [SidebarID: WorkroomStatus] = [:]

  /// Whether the GitHub CLI is usable for the PR/CI probes (machine-global). Optimistic default so
  /// no warning flashes before the first check.
  var githubCLIStatus: GitHubCLIStatus = .available

  /// Owns the `gh auth status` probe: its freshness clock AND its single-flight, so N windows share
  /// one `gh` and the staleness check can't interleave with the write the way a bare timestamp on
  /// this class did. `githubCLIStatus` above is the SwiftUI-observable mirror of what it decided.
  ///
  /// A `var` purely so tests can swap in an instance with millisecond TTLs; production never
  /// reassigns it.
  var ghAuthCache = GitHubAuthCache()

  /// Owns the `git --version` probe: its freshness clock AND its single-flight, so N windows share
  /// one probe rather than racing two. `vcsToolReport` on `AppStore` mirrors what
  /// this decided (per-window, since `apply(projects)` runs per-window even though the underlying
  /// facts are machine-wide).
  ///
  /// A `var` for the same reason `ghAuthCache` is: tests swap in an instance with millisecond TTLs;
  /// production never reassigns it.
  var vcsToolVersionCache = VCSToolVersionCache()

  /// Target ids of workrooms whose create process is still running — from the moment the workroom
  /// has a name until the CLI or the provisioning returns (issue #116, #483). A workroom here must not
  /// be deleted: its setup is running against it. Shared across windows so a delete from ANY window
  /// is blocked, not just the creating one.
  var creatingWorkrooms: Set<TerminalTarget.ID> = []

  /// Every create's progress, running or failed, by run id (#483). Shared, so every window that
  /// shows a create shows the same checklist.
  var creationRuns: [UUID: CreationRun] = [:]

  /// The run each pane belongs to: its provisional `TerminalTarget.creationID`, then its workroom's
  /// own id once it has a name. A target here keeps its terminal withheld in every window until the
  /// run ends (issue #167), which is why the named id goes in before the reload that publishes it.
  var creationRunForTarget: [TerminalTarget.ID: UUID] = [:]

  /// Creates waiting on a provider's setup, one entry per provider, in the order they began waiting
  /// (R2, #483). Only the first has its sheet up, one sheet at a time across every window.
  var remoteSetupWaits: [RemoteSetupWait] = []

  /// Sidebar rows with a commit in flight, for the per-row button state.
  ///
  /// Shared across windows for the reason `creatingWorkrooms` is: `AppStore` is per WINDOW, but
  /// `RepositoryWriteGate` and the `index.lock` contention it exists to prevent are per PROCESS. Held on
  /// the window's own store, a second window's 15s sweep, FSEvents lane and Refresh button all saw an
  /// empty set and kept probing a repo mid-write.
  var committingTargets: Set<SidebarID> = []

  /// How many commits are in flight against each project root, which is what the read lanes actually
  /// have to stand clear of.
  ///
  /// Keyed by project root, not by row: the gate serializes on the project root, and a git worktree's
  /// index and refs live in the MAIN repo — so a commit in workroom A contends with a status probe of
  /// workroom B of the same project, which a per-row check waved straight through. Counted rather than
  /// a `Set` because the app's premise is N parallel workrooms, so two of one project can legitimately
  /// commit at once and the first to finish must not clear the other's suppression.
  var committingProjectRoots: [RepositoryLocation: Int] = [:]

  /// How many writes (commit, fetch, push, or pull) are in flight against each project root,
  /// across every window. Checked by the write ACTIONS THEMSELVES before starting — not just
  /// by read lanes — so a second write on the same project root is refused outright rather than
  /// queuing into `RepositoryWriteGate` and possibly racing a live one past its wedge-detection
  /// ceiling (VCS-foundation eng-review: the gate's `maxChainWait` self-heal is far shorter than
  /// fetch/pull's own timeouts, so two windows could otherwise both queue a write and run them
  /// concurrently on the shared `.git`). Distinct from `committingProjectRoots`, which exists for
  /// a different reason (suppressing READ lanes during a commit specifically) and keeps its own
  /// narrower role unchanged; this counter is the umbrella that all four write kinds share.
  var writingProjectRoots: [RepositoryLocation: Int] = [:]

  /// Target ids of workrooms with an in-flight optimistic deletion — dropped from the sidebar but
  /// their teardown (worktree/config removal) not yet finished. `AppStore.apply` filters these out of
  /// every incoming CLI `list`, so a stale snapshot taken before the teardown persisted can't
  /// resurrect a just-deleted workroom (the create/delete reload race). Cleared when teardown ends.
  var deletingWorkrooms: Set<TerminalTarget.ID> = []

  /// Paths of projects with an in-flight Delete Project — the project-level counterpart of
  /// `deletingWorkrooms` (#287). Tearing down a project's remote hosts can take minutes, and a
  /// reload in that window would otherwise republish it with half-destroyed workrooms.
  var deletingProjects: Set<String> = []

  /// Whether the persisted last-session selection is still up for grabs (issue #70). The first
  /// window to launch with `restore == true` consumes it and restores the saved selection; every
  /// other window — including every ⌘N window — gets `false` and so starts blank.
  private var pendingInitialRestore = true

  /// Claim the one-time launch restore. Returns true exactly once (for the first restoring window).
  func consumeInitialRestore() -> Bool {
    defer { pendingInitialRestore = false }
    return pendingInitialRestore
  }

  // MARK: Saved session (issue #46)

  /// Windows from the saved session that no window has adopted yet. Loaded once, lazily, by the first
  /// claim — which is also the moment saves are suspended, so a restoring window cannot overwrite the
  /// file before the rest of it has been claimed.
  private var unclaimedSessionWindows: [WindowSession] = []
  private var didLoadSession = false
  /// Injectable so tests drive a temp session file instead of the developer's real one.
  var sessionCoordinator: SessionCoordinator = .shared
  /// True between loading the session and finishing the restore, so the suspend/resume is balanced
  /// exactly once however many windows take part.
  private var isRestoringSession = false

  /// Sessions already handed to a window, by the key that window now owns. Makes claiming idempotent:
  /// `WindowAccessor` can resolve the same window more than once, and a repeat claim must return the
  /// same session rather than consume a second one.
  private var claimedSessions: [UUID: WindowSession] = [:]

  /// Every helper session the saved session file names, claimed or not: a window that has not
  /// opened or applied yet will still reattach to these.
  var savedSessionIDs: Set<UUID> {
    (unclaimedSessionWindows + claimedSessions.values)
      .reduce(into: Set<UUID>()) { ids, window in
        for target in window.targets { ids.formUnion(target.sessionIDs) }
      }
  }
  /// Keys handed to `openWindow` whose window has not claimed yet. Dispatched once so a `.task`
  /// re-fire cannot open a second copy of the same window.
  private var dispatchedSessionKeys: Set<UUID> = []
  /// How many windows have claimed a session and not yet finished restoring it. Saving resumes when
  /// this reaches zero AND nothing is still awaiting a window.
  private var outstandingRestores = 0
  /// The key of the window that was key at the last quit, so focus lands where the user left it once
  /// every window is back.
  private var keyWindowSessionKey: UUID?

  /// Adopt a saved window for this store, or nil when there is nothing to adopt.
  ///
  /// Loading is lazy so the read happens at the first claim rather than at app init — the claim is
  /// made from `AppStore.attachWindow`, when a real `NSWindow` exists but before it is shown, which is
  /// both early enough for the frame and late enough that a speculative SwiftUI view init cannot
  /// consume a session no window ever uses.
  ///
  /// The launch window adopts the first unclaimed session (its own seed id is freshly minted, so it
  /// cannot match anything on disk) and takes that session's key as its own. A sibling was opened FOR
  /// a specific key and claims exactly that one — never another window's.
  func claimSession(for key: UUID, isLaunchWindow: Bool) -> WindowSession? {
    loadSessionIfNeeded()
    if let already = claimedSessions[key] { return already }

    let claimed: WindowSession?
    if isLaunchWindow {
      claimed = unclaimedSessionWindows.isEmpty ? nil : unclaimedSessionWindows.removeFirst()
    } else if let index = unclaimedSessionWindows.firstIndex(
      where: { $0.windowKey == key.uuidString })
    {
      claimed = unclaimedSessionWindows.remove(at: index)
    } else {
      claimed = nil
    }

    guard let claimed else { return nil }
    let ownedKey = UUID(uuidString: claimed.windowKey) ?? key
    claimedSessions[ownedKey] = claimed
    dispatchedSessionKeys.remove(ownedKey)
    outstandingRestores += 1
    if claimed.isKey { keyWindowSessionKey = ownedKey }
    return claimed
  }

  /// Keys of saved windows nobody has claimed yet, marked as dispatched so they are handed out once.
  /// The launch window opens one window per key.
  func pendingSessionKeys() -> [UUID] {
    loadSessionIfNeeded()
    let keys = unclaimedSessionWindows.compactMap { UUID(uuidString: $0.windowKey) }
      .filter { !dispatchedSessionKeys.contains($0) }
    dispatchedSessionKeys.formUnion(keys)
    return keys
  }

  /// One window finished restoring. Saving resumes only once every window has, so a half-restored
  /// document is never written over a full one.
  ///
  /// The `unclaimedSessionWindows` check is load-bearing, not belt and braces: the launch window
  /// finishes its own restore INSIDE `bootstrap`, which returns before `pendingSessionKeys` has handed
  /// anything out. Ending the restore on "nothing outstanding, nothing dispatched" alone would
  /// therefore fire while the siblings were still only on disk — clearing them, so the fan-out found
  /// nothing to open and only one window ever came back.
  func finishSessionRestore() {
    guard isRestoringSession else { return }
    outstandingRestores = max(0, outstandingRestores - 1)
    guard outstandingRestores == 0, dispatchedSessionKeys.isEmpty,
      unclaimedSessionWindows.isEmpty
    else { return }
    endSessionRestore()
  }

  /// Bring the window that was key at the last quit back to the front, then resume saving.
  ///
  /// `timedOut` is the watchdog calling, and it changes the ending: see below.
  private func endSessionRestore(timedOut: Bool = false) {
    guard isRestoringSession else { return }
    // **A restore that never finished must not resume saving.** `AppStore.load` swallows a CLI
    // failure and returns WITHOUT calling `apply`, so `restorePersistedSessionIfPending` never runs
    // and this window's restore stays outstanding forever. Resuming here would then rebuild the
    // document from a window holding nothing and overwrite the file — one `workroom list` timing out
    // on a cold machine would silently destroy the user's whole saved session, ~16 seconds into a
    // launch that was supposed to bring it back. Freezing keeps the file intact for the next launch.
    let incomplete = outstandingRestores > 0 || !unclaimedSessionWindows.isEmpty
    isRestoringSession = false
    unclaimedSessionWindows.removeAll()
    dispatchedSessionKeys.removeAll()
    claimedSessions.removeAll()
    keyWindowSessionKey = timedOut && incomplete ? nil : keyWindowSessionKey
    if timedOut && incomplete {
      sessionCoordinator.freezeWithoutWriting()
      return
    }
    if let keyWindowSessionKey,
      let store = WindowRegistry.shared.allStores.first(where: {
        $0.sessionKey == keyWindowSessionKey
      })
    {
      store.hostWindow?.makeKeyAndOrderFront(nil)
    }
    keyWindowSessionKey = nil
    sessionCoordinator.resumeSaves()
  }

  private func loadSessionIfNeeded() {
    guard !didLoadSession else { return }
    didLoadSession = true
    guard case .restored(let file, _) = sessionCoordinator.read() else { return }
    unclaimedSessionWindows = file.windows
    isRestoringSession = true
    // Suspended until `finishSessionRestore`. Without this the first window's restore marks the
    // session dirty, and that write would rebuild the document from the windows that exist SO FAR —
    // overwriting the file and discarding the ones still to be claimed.
    sessionCoordinator.suspendSaves()
    // Watchdog: a dispatched window that never opens (a scene SwiftUI declines to create, a window
    // closed mid-restore) would otherwise leave saving suspended for the whole run — the app would
    // silently stop persisting anything. Restoring is a launch-time operation measured in
    // milliseconds, so anything still outstanding this much later is not coming.
    DispatchQueue.main.asyncAfter(deadline: .now() + sessionRestoreTimeout) { [weak self] in
      MainActor.assumeIsolated { self?.endSessionRestore(timedOut: true) }
    }
  }

  /// How long to wait for every dispatched window before giving up. Instance-level so a test can
  /// shorten it and exercise the real watchdog rather than a stand-in for it.
  var sessionRestoreTimeout: TimeInterval = ProjectStore.defaultSessionRestoreTimeout
  static let defaultSessionRestoreTimeout: TimeInterval = 15
}
