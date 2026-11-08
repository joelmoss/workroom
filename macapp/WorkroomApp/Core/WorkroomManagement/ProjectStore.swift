import Foundation
import WorkroomDomain
import WorkroomVCS

/// Shared, app-wide project data: the project list plus what is identical across windows about it —
/// the saved session. Extracted from `AppStore` (issue #70) so that multiple per-window `AppStore`s
/// can share one project list while each keeps its own selection, terminals, splits, history, and
/// run state.
///
/// Views take it from the environment and the store reaches it as `projectStore`. Each project's
/// run config is the app's `RunCommands`', its VCS status the app's `VCSStatusService`', and its
/// workrooms' creates and deletes in flight the app's `WorkroomLifecycle`'. List requests are
/// ordered here across windows; each `AppStore` reconciles its own window after an accepted read.
@MainActor
@Observable
// `ObservableObject` only so views can take it as an `@EnvironmentObject`, as they take the store;
// Observation tracks the reads.
final class ProjectStore: ObservableObject {
  /// The shared instance used in production (every window's `AppStore` points at it). Tests
  /// construct an isolated `AppStore()`, which gets its own fresh `ProjectStore`, so they never
  /// pollute this singleton or each other.
  static let shared = ProjectStore()

  /// The list of configured projects (from the CLI's `~/.config/workroom/config.json`). The one
  /// piece of state shared across all windows.
  ///
  /// Computed over a private stored list, like the status collections below, so an in-place write
  /// that changes nothing (`projects[i] = p`, a `removeAll` that matches nothing) notifies no one,
  /// as it did when `AppStore` forwarded the list.
  var projects: [Project] {
    get { storedProjects }
    set {
      storedProjects = newValue
      recheckMissingRoots()
    }
  }
  private var storedProjects: [Project] = []

  /// The listed projects whose root folder is gone, by id, as of the last publish of `projects` or
  /// the last `recheckMissingRoot`. The filesystem can't be observed, so the sidebar reads this
  /// (`rootTarget(path:name:)`) instead of `stat`ing: a reload (the app becoming active, a create
  /// or delete) re-checks every root, even when the list is unchanged, and an unchanged set
  /// notifies no one, so a reload of an unchanged list re-runs no row.
  private(set) var missingRoots: Set<Project.ID> = []

  /// The root target of the project at `path`, named `name`, missing as of `missingRoots`, so
  /// nothing is `stat`ed. `Project.rootTarget` is the live check.
  func rootTarget(path: String, name: String) -> TerminalTarget {
    Project.rootTarget(path: path, name: name, isMissing: missingRoots.contains(path))
  }

  /// Re-checks which listed roots are gone, writing `missingRoots` only if that changed.
  private func recheckMissingRoots() {
    let missing = Set(
      storedProjects.lazy.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
    if missing != missingRoots { missingRoots = missing }
  }

  /// Re-checks whether one listed project's root is gone, as its metadata watcher fires, writing
  /// `missingRoots` only if that changed. A project no longer listed is left out.
  func recheckMissingRoot(projectID: Project.ID) {
    guard let project = storedProjects.first(where: { $0.id == projectID }) else { return }
    let missing = !FileManager.default.fileExists(atPath: project.path)
    guard missing != missingRoots.contains(projectID) else { return }
    if missing {
      missingRoots.insert(projectID)
    } else {
      missingRoots.remove(projectID)
    }
  }

  /// The listed project at `path` (its `id`), if any.
  func project(at path: String) -> Project? {
    projects.first { $0.path == path }
  }

  /// `id`'s sidebar row while it is still listed, else nil (always nil for a create's pane and the
  /// Quick Terminal, which have no row).
  func sidebarID(for id: TargetID) -> SidebarID? {
    AppStore.validatedSelection(id.sidebarID, in: projects)
  }

  /// The app-wide base branch for projects that name none; nil means origin's default branch.
  var globalBaseBranch: String?

  /// The base branch `project`'s new workrooms start from: its own, else the app-wide one, else nil
  /// for origin's default branch. The CLI applies the same rule to a local create.
  func effectiveBaseBranch(for project: Project) -> String? {
    project.baseBranch ?? globalBaseBranch
  }

  /// A read is stamped when issued, across all windows (#170). Superseded callers await
  /// the newest read too. Success publishes its result; failure leaves the project list unchanged.
  struct Load {
    let generation: UInt64
    let task: Task<ListResponse, Error>
  }

  var prepareRepositories: @Sendable ([Project]) async throws -> [RepositoryRouter.Registration] = {
    let interval = LaunchSignposts.begin("Prepare repositories")
    defer { LaunchSignposts.end("Prepare repositories", interval) }
    return try await RepositoryRouter.prepare($0)
  }

  private(set) var latestLoad: Load?
  private var loadGeneration: UInt64 = 0
  private var publishedLoadGeneration: UInt64 = 0

  func beginLoad(cli: WorkroomCLIProtocol, warnings: String) -> Load {
    loadGeneration += 1
    let load = Load(
      generation: loadGeneration,
      task: Task {
        let interval = LaunchSignposts.begin("Project list")
        defer { LaunchSignposts.end("Project list", interval) }
        return try await cli.list(warnings: warnings, project: nil)
      })
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

  /// Whether the persisted last-session selection is still up for grabs (issue #70). The first
  /// window to launch with `restore == true` consumes it and restores the saved selection; every
  /// other window — including every ⌘N window — gets `false` and so starts blank.
  private var pendingInitialRestore = true

  /// Claim the one-time launch restore. Returns true exactly once (for the first restoring window).
  func consumeInitialRestore() -> Bool {
    defer { pendingInitialRestore = false }
    return pendingInitialRestore
  }

  private var launchRoleTaken = false

  /// Claim the launch window's role (restore the session, open its siblings). True exactly once,
  /// for the first window that attaches — whatever seed it carries: macOS can bring a window back
  /// from an older build's saved state with a sibling or ⌘N seed, and no `.launch` window opens then.
  func takeLaunchRole() -> Bool {
    defer { launchRoleTaken = true }
    return !launchRoleTaken
  }

  // MARK: Saved session (issue #46)

  /// Windows from the saved session that no window has adopted yet. Loaded once, lazily, by the first
  /// claim — which is also the moment saves are suspended, so a restoring window cannot overwrite the
  /// file before the rest of it has been claimed.
  private var unclaimedSessionWindows: [WindowSession] = []
  private var didLoadSession = false
  /// Injectable so tests drive a temp session file instead of the developer's real one.
  var sessionCoordinator: SavedLayoutCoordinator = .shared
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
  /// A window claims the session saved under its own key. The launch window's seed id is normally
  /// freshly minted, so it matches nothing and it adopts the first unclaimed session, taking that
  /// session's key as its own. Matching first matters when macOS restored the launch window with a
  /// sibling's seed: the fan-out reopens every unclaimed key, and SwiftUI answers a seed that is
  /// already on screen by focusing that window, so a key left unclaimed here would never open.
  func claimSession(for key: UUID, isLaunchWindow: Bool) -> WindowSession? {
    loadSessionIfNeeded()
    if let already = claimedSessions[key] { return already }

    let claimed: WindowSession?
    if let index = unclaimedSessionWindows.firstIndex(where: { $0.windowKey == key.uuidString }) {
      claimed = unclaimedSessionWindows.remove(at: index)
    } else if isLaunchWindow, !unclaimedSessionWindows.isEmpty {
      claimed = unclaimedSessionWindows.removeFirst()
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
