import Foundation
import WorkroomDomain
import WorkroomSystem

/// The folder a window's inspector follows for a Terminals-section target (#803, ADR 0081), and
/// which target it was resolved for, so a value never outlives its selection.
struct FollowedFolderState: Equatable {
  var target: TargetID
  var folder: FollowedFolder
}

/// How a window follows its terminal's folder (#803, ADR 0081): what it last asked git to
/// resolve, the resolve in flight and its retry, how often each folder couldn't tell, what each
/// folder resolved to, the terminal each target focused last, and the repository it holds in the
/// app's status. The subject it publishes (`AppStore.followedFolderState`) stays on the store,
/// which observes it; none of this is observed.
@MainActor
final class FollowedFolderTracker {
  /// What was last asked to resolve: the target and its terminal's folder, so a repeat (every
  /// focus or tab event re-asks) runs no `git`.
  var request: (target: TargetID, folder: String)?
  /// The resolve in flight for `request`.
  var task: Task<Void, Never>?
  /// The retry of a resolve that couldn't tell, for `request`.
  var retryTask: Task<Void, Never>?
  /// How many resolves in a row couldn't tell, per folder: what spaces out its retries. Bounded:
  /// a folder dropped from it starts its retries over at 2 s.
  private var undeterminedStreak = RecentCache<String, Int>(capacity: 64)
  /// Wait before retrying a folder whose resolve couldn't tell `streak` times in a row: 2 s,
  /// doubling to 60 s. A seam for tests.
  var retryWait: @Sendable (_ streak: Int) async -> Void = { streak in
    try? await Task.sleep(for: FollowedFolderTracker.retryDelay(streak))
  }
  /// What each folder resolved to last, so returning to a terminal shows its repository at once.
  /// An entry that is fresh, or watched (`CacheEntry.watched`), is trusted as it is, with no `git`
  /// run; any other is shown while a fresh resolve (for a branch switched meanwhile) runs.
  /// Bounded to the 64 most recently used folders.
  var cache = RecentCache<String, CacheEntry>(capacity: 64)

  /// What a folder resolved to, and since when it is known to still hold.
  struct CacheEntry {
    var repository: FollowedFolder.Repository?
    /// When it was resolved, or last known to hold (its repository's watch let go).
    var at: ContinuousClock.Instant
    /// Whether this window has held its repository, watched, since it was resolved: a change
    /// under it then forgets the entry (`forget`), so while the hold lasts it can't be stale.
    var watched = false
  }

  /// How long a cached answer is trusted with no watch to vouch for it.
  nonisolated static let cacheFreshness: Duration = .seconds(5)
  /// Folder reports closer together than this are a burst (`for d in */; do (cd $d …); done`):
  /// only the folder it settles on is resolved and held.
  nonisolated static let burstWindow: Duration = .milliseconds(150)
  /// The clock bursts and freshness are told by. A seam for tests.
  var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  /// Wait for a burst of folder reports to settle. A seam for tests.
  var burstWait: @Sendable () async -> Void = {
    try? await Task.sleep(for: FollowedFolderTracker.burstWindow)
  }
  /// When the last request was made: what tells a burst.
  var lastRequestAt: ContinuousClock.Instant?
  /// Whether holding the shown repository waits for a burst to settle, so a folder passed by
  /// subscribes and probes nothing.
  var holdDeferred = false
  /// The terminal tab whose folder `request` is: the only one whose finished command re-checks it.
  var followedTab: TerminalTab.ID?
  /// Where `task` is: waiting out a burst, or running git.
  enum Phase { case idle, waiting, resolving }
  var phase = Phase.idle
  /// A command of the followed tab finished while `task` ran git: the repository then held with a
  /// live watch, if any (`AppStore.followedWatchVouches`). Its answer re-checks once it lands,
  /// unless it lands in that repository.
  var finishedDuringResolve: String??
  /// A command of the followed tab finished while `task` waited out a burst (`cd a; cd b;
  /// git switch x`): the folder it settles on is resolved even with a fresh answer cached, since
  /// the command may have moved it (#812 perf review A, N2). Kept across the burst's further
  /// requests, cleared once it is consumed or a request ends the burst.
  var finishedDuringBurst = false
  /// The check of the answers cached before the held repository's watch went live
  /// (`AppStore.followedWatchDidGoLive`).
  var liveCheckTask: Task<Void, Never>?
  /// The cheap re-check a finished command runs (`AppStore.recheckFollowedFolder`).
  var recheckTask: Task<Void, Never>?
  /// The canonical root of the repository the window's inspector follows, as it holds it in
  /// `vcsStatus` (`follow`/`unfollow`), so its status and watch last while some window follows it.
  // `nonisolated(unsafe)`: written on the main actor, read again only in the store's `deinit`.
  nonisolated(unsafe) var heldRepository: String?
  /// The terminal tab each Terminals-section target last focused, for when its focused tab is a
  /// content tab with no folder of its own.
  var lastFocusedTerminalTab: [TargetID: TerminalTab.ID] = [:]
  /// The target the loader's delay (`loaderTask`) runs, or ran, for: nil while none is pending.
  var loaderTarget: TargetID?
  /// The innermost git repository containing a folder on this Mac, or that there is none, or that
  /// git could not tell. A seam for tests.
  var resolve: @Sendable (String) async -> GitRepositoryProbe.Discovery = { folder in
    // The user's `GIT_CEILING_DIRECTORIES` comes from the launch shell probe: a resolve before it
    // lands would read past it (a `$HOME` dotfiles repository) and cache that (re-review R3).
    await ShellEnvironment.settled()
    return await GitRepositoryProbe().discoverRepository(containing: folder)
  }

  /// The delay before the inspector's sections show their loader for a folder whose repository is
  /// still pending, running or elapsed (`AppStore.followedFolderLoaderShown`).
  var loaderTask: Task<Void, Never>?
  /// Wait before the sections show their loader for a pending repository, so a fast answer never
  /// flashes it. A seam for tests.
  var loaderWait: @Sendable () async -> Void = {
    try? await Task.sleep(for: FollowedFolderTracker.loaderDelay)
  }
  /// How long `loaderWait` waits by default.
  nonisolated static let loaderDelay: Duration = .milliseconds(300)

  /// How long `retryWait` waits by default.
  nonisolated static func retryDelay(_ streak: Int) -> Duration {
    .seconds(min(60, 2 << min(max(streak, 1) - 1, 5)))
  }

  /// Whether `request` is for `target`'s `folder`.
  func isRequested(target: TargetID, folder: String) -> Bool {
    request.map { $0.target == target && $0.folder == folder } ?? false
  }

  /// Stop following: forget the request, so the next one resolves again, and cancel its resolve
  /// and retry.
  func stop() {
    request = nil
    followedTab = nil
    holdDeferred = false
    finishedDuringBurst = false
    cancelResolve()
  }

  /// Cancel the resolve in flight, any retry and any re-check, for a new one.
  func cancelResolve() {
    task?.cancel()
    task = nil
    retryTask?.cancel()
    retryTask = nil
    recheckTask?.cancel()
    recheckTask = nil
    phase = .idle
    finishedDuringResolve = nil
  }

  /// `folder` resolved: what it resolved to is cached, and its run of failures ends. `watched`:
  /// its repository is the one this window holds, under a live watch.
  func resolved(_ folder: String, to repository: FollowedFolder.Repository?, watched: Bool) {
    undeterminedStreak[folder] = nil
    cache[folder] = CacheEntry(repository: repository, at: now(), watched: watched)
  }

  /// This window now holds `root`: an answer for it that just landed is vouched for by its watch
  /// from here on, but only when that watch is `live` already (a re-follow in the grace, another
  /// window's hold). One that isn't yet would miss a change before it starts, so its answers wait
  /// for `AppStore.followedWatchDidGoLive` to check them (#812 perf review A, N3).
  func holding(_ root: String, live: Bool) {
    guard live else { return }
    let now = now()
    cache.updateEach { _, entry in
      if entry.repository?.root == root, !entry.watched, now - entry.at < .seconds(1) {
        entry.watched = true
      }
    }
  }

  /// The answers in `root` cached while its watch was not yet live, and still fresh: what its
  /// going live checks.
  func unvouchedAnswers(in root: String) -> [String: FollowedFolder.Repository] {
    let now = now()
    var answers: [String: FollowedFolder.Repository] = [:]
    cache.updateEach { folder, entry in
      if let repository = entry.repository, repository.root == root, !entry.watched,
        now - entry.at < FollowedFolderTracker.cacheFreshness
      {
        answers[folder] = repository
      }
    }
    return answers
  }

  /// `answers` were checked once the watch went live and still hold: vouched for from here on.
  func vouch(_ answers: [String: FollowedFolder.Repository]) {
    cache.updateEach { folder, entry in
      if let repository = answers[folder], entry.repository == repository { entry.watched = true }
    }
  }

  /// A command finished in a pane at `folder`: forget its answer and every answer in a repository
  /// containing it (a `git switch` there moves them all), but those `vouched` for by a live watch,
  /// which reports the change itself (#812 perf review A, N1).
  func forgetAnswers(around folder: String, vouched: (String) -> Bool) {
    cache.removeAll { key, entry in
      guard let repository = entry.repository else { return key == folder }
      if entry.watched, vouched(repository.root) { return false }
      if key == folder { return true }
      return [repository.root, repository.displayRoot].contains {
        folder == $0 || folder.hasPrefix($0 + "/")
      }
    }
  }

  /// This window let go of `root`: its answers held until now, and are trusted only while fresh.
  func released(_ root: String) {
    let now = now()
    cache.updateEach { _, entry in
      if entry.repository?.root == root, entry.watched {
        entry = CacheEntry(repository: entry.repository, at: now)
      }
    }
  }

  /// `folder` couldn't tell once more: how many times in a row it now has.
  func couldNotTell(_ folder: String) -> Int {
    let streak = (undeterminedStreak[folder] ?? 0) + 1
    undeterminedStreak[folder] = streak
    return streak
  }

  /// Forget what `folder`, and every folder in repository `root`, resolved to.
  func forget(_ folder: String?, inRoot root: String?) {
    if let folder { cache[folder] = nil }
    guard let root else { return }
    cache.removeAll { _, entry in
      // git names a root by its real path: compared as it is, with no `realpath` per entry.
      entry.repository?.root == root
    }
  }
}

/// The inspector following the selected terminal's folder (#803, ADR 0081). The folder is the
/// focused terminal's live working directory (OSC 7), else the folder it started in. Only this
/// window's selection feeds it, and the Quick Terminal never does (its panes are its panel's).
extension AppStore {
  /// The canonical root of the repository this window's inspector holds in `vcsStatus`
  /// (`FollowedFolderTracker.heldRepository`).
  var heldFollowedRepository: String? { followedFolder.heldRepository }

  /// The resolve seam (`FollowedFolderTracker.resolve`). For tests.
  var resolveFollowedRepository: @Sendable (String) async -> GitRepositoryProbe.Discovery {
    get { followedFolder.resolve }
    set { followedFolder.resolve = newValue }
  }

  /// The loader's delay (`FollowedFolderTracker.loaderWait`). For tests.
  var followedFolderLoaderWait: @Sendable () async -> Void {
    get { followedFolder.loaderWait }
    set { followedFolder.loaderWait = newValue }
  }

  /// Whether Changes, Pull Request, History and Files show their loader: the followed folder's
  /// repository is still pending, and has been for `FollowedFolderTracker.loaderDelay`. Before
  /// that they stay blank, so a fast answer never flashes a loader.
  var followedFolderLoaderShown: Bool {
    guard followedFolderLoaderElapsedFlag,
      case .followed(let followed) = inspectorRepositorySubject
    else {
      return false
    }
    return followed.repositoryPending
  }

  /// Start the loader's delay when a lookup is pending and none runs, and end it once the lookup
  /// has answered, the terminal is left, or another target is followed. A pending lookup that is
  /// asked again (a `cd` while it runs) keeps the delay, or the loader it shows.
  private func syncFollowedFolderLoader() {
    let pending =
      followedFolder.request != nil && followedFolderState?.folder.repositoryPending == true
    let target = pending ? followedFolderState?.target : nil
    if followedFolder.loaderTarget != target {
      followedFolder.loaderTask?.cancel()
      followedFolder.loaderTask = nil
      followedFolder.loaderTarget = nil
      if followedFolderLoaderElapsedFlag { followedFolderLoaderElapsedFlag = false }
    }
    guard pending, followedFolder.loaderTarget == nil else { return }
    followedFolder.loaderTarget = target
    let wait = followedFolder.loaderWait
    followedFolder.loaderTask = Task { [weak self] in
      await wait()
      guard let self, !Task.isCancelled,
        self.followedFolderState?.folder.repositoryPending == true
      else { return }
      self.followedFolderLoaderElapsedFlag = true
    }
  }

  /// Wait for the loader's delay. For tests.
  func followedFolderLoaderElapsed() async { await followedFolder.loaderTask?.value }

  /// The retry's wait (`FollowedFolderTracker.retryWait`). For tests.
  var followedFolderRetryWait: @Sendable (_ streak: Int) async -> Void {
    get { followedFolder.retryWait }
    set { followedFolder.retryWait = newValue }
  }

  /// Whether `sid`'s inspector follows its terminal's folder: a standalone terminal, or a terminal
  /// group, which follows its focused terminal (#806). Never the Quick Terminal's group, which no
  /// window selects and `followedTerminalFolder` names on its own.
  static func followsFolder(_ sid: SidebarID) -> Bool {
    switch sid {
    case .standalone: return true
    case .terminalGroup: return sid.targetID != .quickTerminal
    default: return false
    }
  }

  /// The folder the selected target's terminal is in, nil when the inspector follows nothing.
  ///
  /// The focused tab's, else (a content tab has no folder) the terminal tab the target focused
  /// last, else its first, else the folder the target opens terminals in. The live cwd counts only
  /// while it is this Mac's: libghostty drops an `ssh` session's reports, so the last local one
  /// stands.
  func followedTerminalFolder() -> String? {
    guard let sid = selectedTargetID, Self.followsFolder(sid), let target = selectedTarget,
      target.id != .quickTerminal, terminals.tabCount(forTargetID: target.id) > 0
    else { return nil }
    let tabs = terminals.tabs(for: target)
    func folder(_ tab: TerminalTab?) -> String? {
      guard let tab, case .terminal(let state) = tab.content else { return nil }
      return state.cwd ?? state.launchDirectory
    }
    if let focused = terminals.focusedTab(for: target), let path = folder(focused) {
      followedFolder.lastFocusedTerminalTab[target.id] = focused.id
      followedFolder.followedTab = focused.id
      return path
    }
    let last = followedFolder.lastFocusedTerminalTab[target.id].flatMap { id in
      tabs.first { $0.id == id }
    }
    if let last, let path = folder(last) {
      followedFolder.followedTab = last.id
      return path
    }
    let first = tabs.first { folder($0) != nil }
    followedFolder.followedTab = first?.id
    return first.flatMap(folder) ?? target.path
  }

  /// Re-read the followed folder, and re-point History (and the toolbar) when the subject moved.
  /// `rereading`: the request a re-read (`reresolveFollowedFolder`) replaces.
  func refreshFollowedFolder(rereading: (target: TargetID, folder: String)? = nil) {
    guard updateFollowedFolder(rereading: rereading) else { return }
    focusHistoryIfShown()
    focusRemoteStateIfShown()
  }

  /// Re-read the followed folder: at once from what the folder last resolved to, then, unless that
  /// answer is fresh or watched, from a resolve off the main actor (a `git` run must not block the
  /// terminal's callback, which this runs inside). Folder reports in a burst resolve and hold only
  /// the folder they settle on; a lone one resolves at once. Returns whether the subject changed
  /// synchronously.
  @discardableResult
  func updateFollowedFolder(rereading: (target: TargetID, folder: String)? = nil) -> Bool {
    guard let folder = followedTerminalFolder(), let target = selectedTarget?.id else {
      // Left the terminal: the next return resolves again, for a branch switched meanwhile.
      followedFolder.stop()
      syncFollowedFolderLoader()
      return false
    }
    if followedFolder.isRequested(target: target, folder: folder) { return false }
    let rereads = rereading.map { $0.target == target && $0.folder == folder } ?? false
    let now = followedFolder.now()
    let burst =
      !rereads
      && (followedFolder.lastRequestAt.map { now - $0 < FollowedFolderTracker.burstWindow }
        ?? false)
    if !rereads { followedFolder.lastRequestAt = now }
    if !burst { followedFolder.finishedDuringBurst = false }
    followedFolder.request = (target, folder)
    // A folder change, or another terminal: Files snaps back to following it. A re-read of the
    // same folder keeps a folder Files is browsing (a save must not snap it back), and writes
    // nothing.
    if !rereads, filesBrowse != nil { filesBrowse = nil }
    followedFolder.cancelResolve()
    followedFolder.holdDeferred = burst
    var changed = false
    // A folder seen before shows straight away. A new one keeps the target's last folder showing
    // until it resolves, so a `cd` never blanks the inspector; with none shown for the target yet
    // (a first visit), the folder shows at once, its repository pending (review C1).
    let cached = followedFolder.cache[folder]
    if let cached {
      changed = setFollowedFolder(
        FollowedFolderState(
          target: target, folder: FollowedFolder(folder: folder, repository: cached.repository)))
    } else if followedFolderState?.target != target
      || followedFolderState?.folder.repositoryPending == true
    {
      changed = setFollowedFolder(
        FollowedFolderState(
          target: target, folder: FollowedFolder(folder: folder, lookup: .pending)))
    }
    // A focus move or a revisit to a folder whose answer is fresh, or watched: no `git` at all.
    if !burst, let cached, followedFolderCacheIsTrusted(cached) {
      syncFollowedFolderLoader()
      return changed
    }
    startFollowedResolve(target: target, folder: folder, afterBurst: burst)
    syncFollowedFolderLoader()
    return changed
  }

  /// Whether `entry` can stand for its folder with no fresh resolve: it is younger than
  /// `cacheFreshness`, or its repository is the one this window holds and a live watch covers both
  /// its git directory and its tree, so any change would have forgotten it.
  func followedFolderCacheIsTrusted(_ entry: FollowedFolderTracker.CacheEntry) -> Bool {
    if followedFolder.now() - entry.at < FollowedFolderTracker.cacheFreshness { return true }
    guard entry.watched, let root = entry.repository?.root else { return false }
    return followedWatchVouches(for: root)
  }

  /// Whether this window holds `root` and its watch reports both a change to its git directory
  /// (`git switch`, a commit, `rm -rf .git`) and one in its tree (a nested `git init`).
  func followedWatchVouches(for root: String) -> Bool {
    guard followedFolder.heldRepository == root else { return false }
    let coverage = vcsStatus.followedWatchCoverage(root)
    return coverage.gitDirectory && coverage.tree
  }

  /// Resolve `folder` for `target` off the main actor; after a burst settles when `afterBurst`.
  private func startFollowedResolve(target: TargetID, folder: String, afterBurst: Bool) {
    let resolve = followedFolder.resolve
    let burstWait = followedFolder.burstWait
    followedFolder.phase = afterBurst ? .waiting : .resolving
    followedFolder.task = Task { [weak self] in
      if afterBurst {
        await burstWait()
        guard let self, !Task.isCancelled else { return }
        // Settled here: hold what it shows, and run nothing more for an answer still good.
        self.followedFolder.holdDeferred = false
        let held = self.followedFolder.heldRepository
        self.holdFollowedRepository()
        // What acts on the held repository (the toolbar, History) re-points to it now.
        if self.followedFolder.heldRepository != held {
          self.focusHistoryIfShown()
          self.focusRemoteStateIfShown()
        }
        // A command finished meanwhile may have moved it: resolved afresh, cache or not.
        let finished = self.followedFolder.finishedDuringBurst
        self.followedFolder.finishedDuringBurst = false
        if !finished, let cached = self.followedFolder.cache[folder],
          self.followedFolderCacheIsTrusted(cached)
        {
          self.followedFolder.phase = .idle
          return
        }
        self.followedFolder.phase = .resolving
      }
      var discovery = await resolve(folder)
      // Placed off the main actor, under the probe's timeout: it reads the folder's real path, which
      // a stale mount can block. A placement that can't finish can't tell where the folder is.
      if case .repository(let found) = discovery {
        discovery =
          await GitRepositoryProbe().placed(found, in: folder).map { .repository($0) } ?? .unknown
      }
      guard let self, !Task.isCancelled else { return }
      // A later request (another folder, another target) has taken over.
      let current = self.followedFolder.isRequested(target: target, folder: folder)
      var finishedMeanwhile: String?? = nil
      if current {
        self.followedFolder.phase = .idle
        finishedMeanwhile = self.followedFolder.finishedDuringResolve
        self.followedFolder.finishedDuringResolve = nil
      }
      let repository: FollowedFolder.Repository?
      switch discovery {
      case .repository(let found): repository = found
      case .notARepository: repository = nil
      case .unknown:
        if current { self.followedFolderCouldNotTell(target: target, folder: folder) }
        return
      }
      self.followedFolder.resolved(
        folder, to: repository,
        watched: repository.map { self.followedWatchVouches(for: $0.root) } ?? false)
      guard current else { return }
      let state = FollowedFolderState(
        target: target, folder: FollowedFolder(folder: folder, repository: repository))
      if self.setFollowedFolder(state) {
        self.focusHistoryIfShown()
        self.focusRemoteStateIfShown()
      } else {
        // Unchanged, so not re-held: hold it anyway, which retries an empty registration.
        self.holdFollowedRepository()
      }
      // A command finished while git ran, which may have moved the repository after git read it
      // (`cd app && git switch topic`): re-checked, unless it landed in the repository a live watch
      // already covered then.
      if let finishedMeanwhile, repository?.root == nil || finishedMeanwhile != repository?.root {
        self.recheckFollowedFolder()
      }
    }
  }

  /// A command finished in `tab` of the selected target (OSC 133;D). It may have moved the
  /// followed repository without a `cd` (`git switch`, `git init`, `rm -rf .git`), but only the
  /// followed tab's can, and only where no live watch already reports it.
  func followedCommandFinished(tab: TerminalTab.ID) {
    guard followedFolder.request != nil else { return }
    guard tab == followedFolder.followedTab else {
      // A background pane: nothing it ran re-reads the followed folder, but the answers for its
      // folder and its repository are forgotten unless a watch vouches for them, so focusing any
      // of them resolves afresh.
      if let target = selectedTarget, let other = terminals.tab(tab, for: target),
        case .terminal(let state) = other.content
      {
        followedFolder.forgetAnswers(around: state.cwd ?? state.launchDirectory) {
          followedWatchVouches(for: $0)
        }
      }
      return
    }
    switch followedFolder.phase {
    // A resolve waiting out a burst runs after this command: it reads what it did, even where a
    // fresh answer is cached.
    case .waiting: followedFolder.finishedDuringBurst = true
    case .resolving:
      let held = followedFolder.heldRepository.flatMap { followedWatchVouches(for: $0) ? $0 : nil }
      followedFolder.finishedDuringResolve = .some(held)
    case .idle: recheckFollowedFolder()
    }
  }

  /// Re-check the followed folder after a finished command, with no `git` unless something moved:
  /// nothing at all while a live watch covers its repository; else one read off the main actor of
  /// whether `<folder>/.git` is there and of the branch HEAD names, and a resolve only when either
  /// differs from what is shown. A folder git couldn't tell about is resolved again, as before.
  func recheckFollowedFolder() {
    guard let request = followedFolder.request, let state = followedFolderState,
      state.target == request.target, state.folder.folder == request.folder
    else { return }
    let shown = state.folder
    switch shown.lookup {
    case .pending: return
    case .undetermined:
      reresolveFollowedFolder()
      return
    case .resolved: break
    }
    let repository = shown.repository
    if let repository, followedWatchVouches(for: repository.root) { return }
    let folder = request.folder
    // `.git` sits at the folder only when it is its repository's root.
    let expectsDotGit = repository.map { $0.subfolder.isEmpty } ?? false
    let gitDir = repository?.gitDir
    let branch = repository?.branch
    let timeout = GitRepositoryProbe().timeout
    followedFolder.recheckTask?.cancel()
    followedFolder.recheckTask = Task { [weak self] in
      let read = await GitRepositoryProbe.blockingRead(
        "recheck\u{0}\(folder)\u{0}\(gitDir ?? "")", timeout: timeout
      ) { () -> FollowedRecheck in
        var isDirectory: ObjCBool = false
        let dotGit = FileManager.default.fileExists(
          atPath: folder + "/.git", isDirectory: &isDirectory)
        return FollowedRecheck(
          dotGit: dotGit, head: gitDir.map { GitRepositoryProbe.headBranch(gitDir: $0) })
      }
      guard let self, !Task.isCancelled,
        self.followedFolder.isRequested(target: request.target, folder: folder)
      else { return }
      let moved: Bool
      if let read {
        let headMoved: Bool =
          switch read.head {
          case nil: repository != nil
          case .branch(let name): name != branch
          case .detached: branch != nil
          case .unreadable: true
          }
        moved = read.dotGit != expectsDotGit || (repository != nil && headMoved)
      } else {
        moved = true
      }
      guard moved else { return }
      self.reresolveFollowedFolder()
    }
  }

  /// Resolve the followed folder's repository afresh: a command, or a change under the repository,
  /// may have moved its branch or its root (`git switch`, `git init`, `rm -rf .git`) without a `cd`.
  /// What each folder in `root` resolved to is forgotten too, so a later `cd` within it never shows
  /// the old branch. The folder keeps showing what it last resolved to until the fresh resolve lands.
  func reresolveFollowedFolder(forgetting root: String? = nil) {
    guard let request = followedFolder.request else { return }
    followedFolder.forget(request.folder, inRoot: root)
    followedFolder.request = nil
    refreshFollowedFolder(rereading: request)
  }

  /// Hold, in the app's status, the repository this window's inspector follows, and let go of the
  /// one it followed before: what keeps a followed repository's status and watch alive while some
  /// window follows it, and drops them when none does (#807).
  func holdFollowedRepository() {
    // A burst of folder reports holds only the folder it settles on (`startFollowedResolve`).
    guard !followedFolder.holdDeferred else { return }
    // git's root, canonical already: no `realpath` here, on the main actor (Codex on #812).
    var root: String?
    if case .followed(let followed) = inspectorRepositorySubject,
      let repository = followed.repository
    {
      root = repository.root
    }
    guard root != followedFolder.heldRepository else {
      // The same repository, re-read (a `cd` within it, a re-resolve): a registration that came
      // back empty is asked again (lane B review M1).
      if let root { vcsStatus.retryFollowedRegistration(root) }
      return
    }
    if let held = followedFolder.heldRepository {
      vcsStatus.unfollow(held)
      followedFolder.released(held)
    }
    followedFolder.heldRepository = root
    if let root {
      vcsStatus.follow(root)
      followedFolder.holding(root, live: followedWatchVouches(for: root))
    }
  }

  /// The watch on followed repository `root` went live: the answers in it cached before then are
  /// checked once with no `git` (whether HEAD still names their branch), and vouched for when it
  /// does. When it doesn't (a `git switch` before the watch started), they are forgotten and the
  /// folder is resolved afresh (#812 perf review A, N3).
  func followedWatchDidGoLive(root: String) {
    guard followedWatchVouches(for: root) else { return }
    let answers = followedFolder.unvouchedAnswers(in: root)
    guard let gitDir = answers.values.lazy.compactMap(\.gitDir).first else {
      if !answers.isEmpty { followedRepositoryDidChange(root: root, metadata: true) }
      return
    }
    let timeout = GitRepositoryProbe().timeout
    let previous = followedFolder.liveCheckTask
    followedFolder.liveCheckTask = Task { [weak self] in
      await previous?.value
      let head = await GitRepositoryProbe.blockingRead(
        "livecheck\u{0}\(gitDir)", timeout: timeout
      ) { GitRepositoryProbe.headBranch(gitDir: gitDir) }
      guard let self else { return }
      let holds = answers.values.allSatisfy { repository in
        switch head {
        case .branch(let name): name == repository.branch
        case .detached: repository.branch == nil
        case .unreadable, nil: false
        }
      }
      if holds, self.followedWatchVouches(for: root) {
        self.followedFolder.vouch(answers)
      } else if !holds {
        self.followedRepositoryDidChange(root: root, metadata: true)
      }
    }
  }

  /// The Changes header's Refresh, for the repository this window follows (#807), which no sweep
  /// covers.
  func refreshFollowedRepository() {
    guard let root = heldFollowedRepository else { return }
    vcsStatus.retryFollowedRegistration(root)
    vcsStatus.refreshFollowedStatus(root, gitHub: true)
  }

  /// Something changed in the git directory of the repository this window follows (a commit, a
  /// ref moved, `.git` removed): re-read its branch and root, and its History, as a workroom's git
  /// directory watch does (`handleRootBranchChange`). A save in the tree reloads Changes only
  /// (through the status), as for a workroom: it can move neither the branch nor the root (review
  /// of #807, finding 3).
  func followedRepositoryDidChange(root: String, metadata: Bool) {
    guard metadata else { return }
    // Every window forgets what its folders in `root` resolved to, held or not, so a cached
    // answer is never trusted past a change some window's watch saw.
    followedFolder.forget(nil, inRoot: root)
    guard heldFollowedRepository == root else { return }
    reresolveFollowedFolder(forgetting: root)
    guard inspectorIsVisible else { return }
    if historySectionShown { commitHistory.refresh() }
    if remoteToolbarShown { remoteState.refresh(force: true) }
  }

  /// The repository this window follows turned out unregistered, or a retry registered it: the
  /// toolbar lets go of it, or takes it back, as Commit and the pull request's actions already do
  /// (they read `unregisteredFollowedRoots`).
  func followedRegistrationDidChange(root: String) {
    guard heldFollowedRepository == root else { return }
    focusRemoteStateIfShown()
  }

  /// The resolve couldn't tell which repository `folder` is in (a timeout, a repository git
  /// refused). A re-read of the folder already shown keeps what it shows; any other folder, and one
  /// still pending, shows as itself, undetermined, never as the repository the terminal was in before (re-review R1).
  /// Nothing is cached, and the request stands, so focus and tab events run nothing until a retry,
  /// spaced out the longer the folder keeps failing: a wedged mount is asked at a bounded rate.
  private func followedFolderCouldNotTell(target: TargetID, folder: String) {
    if followedFolderState?.target != target || followedFolderState?.folder.folder != folder
      || followedFolderState?.folder.repositoryPending == true
    {
      let state = FollowedFolderState(
        target: target,
        folder: FollowedFolder(folder: folder, repository: nil, lookup: .undetermined))
      if setFollowedFolder(state) {
        focusHistoryIfShown()
        focusRemoteStateIfShown()
      }
    }
    let streak = followedFolder.couldNotTell(folder)
    let wait = followedFolder.retryWait
    followedFolder.retryTask?.cancel()
    followedFolder.retryTask = Task { [weak self] in
      await wait(streak)
      guard let self, !Task.isCancelled,
        self.followedFolder.isRequested(target: target, folder: folder)
      else { return }
      self.reresolveFollowedFolder()
    }
  }

  /// Wait for the followed folder's resolve in flight. For tests.
  func followedFolderResolved() async {
    // Until nothing more is in flight: a re-check can start a resolve, and a resolve a re-check.
    while true {
      let (task, recheck, live) =
        (followedFolder.task, followedFolder.recheckTask, followedFolder.liveCheckTask)
      await task?.value
      await recheck?.value
      await live?.value
      if followedFolder.task == task, followedFolder.recheckTask == recheck,
        followedFolder.liveCheckTask == live
      {
        return
      }
    }
  }

  /// Wait for the scheduled retry of a resolve that couldn't tell, and the resolve it starts. For
  /// tests.
  func followedFolderRetried() async {
    await followedFolder.retryTask?.value
    await followedFolderResolved()
  }

  /// Publish `state` only when it differs, so an unchanged resolve re-renders nothing, and hold
  /// the repository it shows: every way the subject changes (a cached folder shown at once, a
  /// resolve landing) follows what it shows (review of #807, finding 1).
  private func setFollowedFolder(_ state: FollowedFolderState) -> Bool {
    guard followedFolderState != state else { return false }
    followedFolderState = state
    holdFollowedRepository()
    syncFollowedFolderLoader()
    return true
  }

  /// What a failure dialog calls the followed repository at canonical `root`: as the shell spells
  /// it, the way the header shows it, while this window shows it; else its root. `~`-abbreviated.
  func followedRepositoryName(_ root: String) -> String {
    var shown = root
    if case .followed(let followed) = inspectorRepositorySubject,
      let repository = followed.repository,
      repository.root == root
    {
      shown = repository.displayRoot
    }
    return (shown as NSString).abbreviatingWithTildeInPath
  }

  /// The followed folder's repository root, nil for anything else: what a commit opened from its
  /// History reads (`ChangesetDescriptor.repositoryRoot`), since the terminal's own target names
  /// only the folder it opened in.
  var followedRepositoryRoot: String? {
    guard case .followed(let followed) = inspectorRepositorySubject else { return nil }
    return followed.repository?.root
  }

  /// Whether History keeps the target's log for a revisit: a followed repository's, so going back
  /// to a terminal shows it at once (QA round 2), as its status is (`recentFollowedStatuses`).
  var historyRemembersTarget: Bool {
    if case .followed = inspectorRepositorySubject { return true }
    return false
  }

  /// The target History reads: the inspector's workroom or project, or for a followed folder in a
  /// repository, that repository's root. Nil outside one.
  var inspectorHistoryTarget: TerminalTarget? {
    switch inspectorRepositorySubject {
    case .target: return inspectorTarget
    case .followed(let followed):
      guard let repository = followed.repository, let id = selectedTargetID?.targetID else {
        return nil
      }
      return TerminalTarget(
        id: id, title: (repository.root as NSString).lastPathComponent, path: repository.root,
        unavailability: nil)
    case .nothing: return nil
    }
  }
}

/// What a finished command's re-check reads of a followed folder (`recheckFollowedFolder`).
struct FollowedRecheck: Sendable {
  /// Whether `<folder>/.git` is there.
  var dotGit: Bool
  /// What its repository's HEAD names, nil with no repository known.
  var head: GitRepositoryProbe.Head?
}
