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
  /// How many resolves in a row couldn't tell, per folder: what spaces out its retries.
  private var undeterminedStreak: [String: Int] = [:]
  /// Wait before retrying a folder whose resolve couldn't tell `streak` times in a row: 2 s,
  /// doubling to 60 s. A seam for tests.
  var retryWait: @Sendable (_ streak: Int) async -> Void = { streak in
    try? await Task.sleep(for: FollowedFolderTracker.retryDelay(streak))
  }
  /// What each folder resolved to last, so returning to a terminal shows its repository at once,
  /// before the fresh resolve (for a branch switched meanwhile) lands.
  var cache: [String: FollowedFolder.Repository?] = [:]
  /// The canonical root of the repository the window's inspector follows, as it holds it in
  /// `vcsStatus` (`follow`/`unfollow`), so its status and watch last while some window follows it.
  // `nonisolated(unsafe)`: written on the main actor, read again only in the store's `deinit`.
  nonisolated(unsafe) var heldRepository: String?
  /// The terminal tab each Terminals-section target last focused, for when its focused tab is a
  /// content tab with no folder of its own.
  var lastFocusedTerminalTab: [TargetID: TerminalTab.ID] = [:]
  /// The innermost git repository containing a folder on this Mac, or that there is none, or that
  /// git could not tell. A seam for tests.
  var resolve: @Sendable (String) async -> GitRepositoryProbe.Discovery = { folder in
    // The user's `GIT_CEILING_DIRECTORIES` comes from the launch shell probe: a resolve before it
    // lands would read past it (a `$HOME` dotfiles repository) and cache that (re-review R3).
    await ShellEnvironment.settled()
    return await GitRepositoryProbe().discoverRepository(containing: folder)
  }

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
    cancelResolve()
  }

  /// Cancel the resolve in flight and any retry, for a new one.
  func cancelResolve() {
    task?.cancel()
    task = nil
    retryTask?.cancel()
    retryTask = nil
  }

  /// `folder` resolved: what it resolved to is cached, and its run of failures ends.
  func resolved(_ folder: String, to repository: FollowedFolder.Repository?) {
    undeterminedStreak[folder] = nil
    cache[folder] = .some(repository)
  }

  /// `folder` couldn't tell once more: how many times in a row it now has.
  func couldNotTell(_ folder: String) -> Int {
    let streak = (undeterminedStreak[folder] ?? 0) + 1
    undeterminedStreak[folder] = streak
    return streak
  }

  /// Forget what `folder`, and every folder in repository `root`, resolved to.
  func forget(_ folder: String, inRoot root: String?) {
    cache[folder] = nil
    guard let root else { return }
    cache = cache.filter { _, repository in
      // git names a root by its real path: compared as it is, with no `realpath` per entry.
      repository.flatMap { $0 }.map { $0.root != root } ?? true
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
      return path
    }
    let last = followedFolder.lastFocusedTerminalTab[target.id].flatMap { id in
      tabs.first { $0.id == id }
    }
    return folder(last) ?? tabs.lazy.compactMap(folder).first ?? target.path
  }

  /// Re-read the followed folder, and re-point History (and the toolbar) when the subject moved.
  func refreshFollowedFolder() {
    guard updateFollowedFolder() else { return }
    focusHistoryIfShown()
    focusRemoteStateIfShown()
  }

  /// Re-read the followed folder: at once from what the folder last resolved to, then from a fresh
  /// resolve off the main actor (a `git` run must not block the terminal's callback, which this
  /// runs inside). Returns whether the subject changed synchronously.
  @discardableResult
  func updateFollowedFolder() -> Bool {
    guard let folder = followedTerminalFolder(), let target = selectedTarget?.id else {
      // Left the terminal: the next return resolves again, for a branch switched meanwhile.
      followedFolder.stop()
      return false
    }
    if followedFolder.isRequested(target: target, folder: folder) { return false }
    followedFolder.request = (target, folder)
    // A folder change, or another terminal: Files snaps back to following it.
    filesBrowse = nil
    var changed = false
    // A folder seen before shows straight away. A new one keeps the target's last folder showing
    // until it resolves, so a `cd` never blanks the inspector; with none shown for the target yet
    // (a first visit), the folder shows at once, its repository pending (review C1).
    if let cached = followedFolder.cache[folder] {
      changed = setFollowedFolder(
        FollowedFolderState(
          target: target, folder: FollowedFolder(folder: folder, repository: cached)))
    } else if followedFolderState?.target != target
      || followedFolderState?.folder.repositoryPending == true
    {
      changed = setFollowedFolder(
        FollowedFolderState(
          target: target, folder: FollowedFolder(folder: folder, lookup: .pending)))
    }
    let resolve = followedFolder.resolve
    followedFolder.cancelResolve()
    followedFolder.task = Task { [weak self] in
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
      let repository: FollowedFolder.Repository?
      switch discovery {
      case .repository(let found): repository = found
      case .notARepository: repository = nil
      case .unknown:
        if current { self.followedFolderCouldNotTell(target: target, folder: folder) }
        return
      }
      self.followedFolder.resolved(folder, to: repository)
      guard current else { return }
      let state = FollowedFolderState(
        target: target, folder: FollowedFolder(folder: folder, repository: repository))
      if self.setFollowedFolder(state) {
        self.focusHistoryIfShown()
        self.focusRemoteStateIfShown()
      }
    }
    return changed
  }

  /// Resolve the followed folder's repository afresh: a command, or a change under the repository,
  /// may have moved its branch or its root (`git switch`, `git init`, `rm -rf .git`) without a `cd`.
  /// What each folder in `root` resolved to is forgotten too, so a later `cd` within it never shows
  /// the old branch. The folder keeps showing what it last resolved to until the fresh resolve lands.
  func reresolveFollowedFolder(forgetting root: String? = nil) {
    guard let request = followedFolder.request else { return }
    followedFolder.forget(request.folder, inRoot: root)
    followedFolder.request = nil
    // The same folder, re-read: a folder Files is browsing stays (a save must not snap it back).
    let browse = filesBrowse
    refreshFollowedFolder()
    filesBrowse = browse
  }

  /// Hold, in the app's status, the repository this window's inspector follows, and let go of the
  /// one it followed before: what keeps a followed repository's status and watch alive while some
  /// window follows it, and drops them when none does (#807).
  func holdFollowedRepository() {
    var root: String?
    if case .followed(let followed) = inspectorSubject, let repository = followed.repository {
      root = VCSStatusService.canonicalPath(repository.root)
    }
    guard root != followedFolder.heldRepository else { return }
    if let held = followedFolder.heldRepository { vcsStatus.unfollow(held) }
    followedFolder.heldRepository = root
    if let root { vcsStatus.follow(root) }
  }

  /// Something changed in the git directory of the repository this window follows (a commit, a
  /// ref moved, `.git` removed): re-read its branch and root, and its History, as a workroom's git
  /// directory watch does (`handleRootBranchChange`). A save in the tree reloads Changes only
  /// (through the status), as for a workroom: it can move neither the branch nor the root (review
  /// of #807, finding 3).
  func followedRepositoryDidChange(root: String, metadata: Bool) {
    guard metadata, heldFollowedRepository == root else { return }
    reresolveFollowedFolder(forgetting: root)
    guard inspectorIsVisible else { return }
    if historySectionShown { commitHistory.refresh() }
    if remoteToolbarShown { remoteState.refresh(force: true) }
  }

  /// The repository this window follows turned out unregistered: the toolbar lets go of it, as
  /// Commit and the pull request's actions already have (they read `unregisteredFollowedRoots`).
  func followedRegistrationDidFail(root: String) {
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
  func followedFolderResolved() async { await followedFolder.task?.value }

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
    return true
  }

  /// The followed folder's repository root, nil for anything else: what a commit opened from its
  /// History reads (`ChangesetDescriptor.repositoryRoot`), since the terminal's own target names
  /// only the folder it opened in.
  var followedRepositoryRoot: String? {
    guard case .followed(let followed) = inspectorSubject else { return nil }
    return followed.repository?.root
  }

  /// The target History reads: the inspector's workroom or project, or for a followed folder in a
  /// repository, that repository's root. Nil outside one.
  var inspectorHistoryTarget: TerminalTarget? {
    switch inspectorSubject {
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
