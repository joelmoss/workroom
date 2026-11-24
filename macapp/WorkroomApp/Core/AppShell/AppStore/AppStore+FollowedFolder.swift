import Foundation
import WorkroomDomain
import WorkroomSystem

/// The folder a window's inspector follows for a Terminals-section target (#803, ADR 0081), and
/// which target it was resolved for, so a value never outlives its selection.
struct FollowedFolderState: Equatable {
  var target: TargetID
  var folder: FollowedFolder
}

/// The inspector following the selected terminal's folder (#803, ADR 0081). The folder is the
/// focused terminal's live working directory (OSC 7), else the folder it started in. Only this
/// window's selection feeds it, and the Quick Terminal never does (its panes are its panel's).
extension AppStore {
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
      lastFocusedTerminalTab[target.id] = focused.id
      return path
    }
    let last = lastFocusedTerminalTab[target.id].flatMap { id in tabs.first { $0.id == id } }
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
      followedFolderRequest = nil
      followedFolderTask?.cancel()
      followedFolderTask = nil
      followedFolderRetryTask?.cancel()
      followedFolderRetryTask = nil
      return false
    }
    if let request = followedFolderRequest, request.target == target, request.folder == folder {
      return false
    }
    followedFolderRequest = (target, folder)
    // A folder change, or another terminal: Files snaps back to following it.
    filesBrowse = nil
    var changed = false
    // A folder seen before shows straight away. A new one keeps the target's last folder showing
    // until it resolves, so a `cd` never blanks the inspector.
    if let cached = followedRepositoryCache[folder] {
      changed = setFollowedFolder(
        FollowedFolderState(
          target: target, folder: FollowedFolder(folder: folder, repository: cached)))
    }
    let resolve = resolveFollowedRepository
    followedFolderTask?.cancel()
    followedFolderRetryTask?.cancel()
    followedFolderRetryTask = nil
    followedFolderTask = Task { [weak self] in
      var discovery = await resolve(folder)
      // Placed off the main actor, under the probe's timeout: it reads the folder's real path, which
      // a stale mount can block. A placement that can't finish can't tell where the folder is.
      if case .repository(let found) = discovery {
        discovery =
          await GitRepositoryProbe().placed(found, in: folder).map { .repository($0) } ?? .unknown
      }
      guard let self, !Task.isCancelled else { return }
      // A later request (another folder, another target) has taken over.
      let current = self.followedFolderRequest.map { $0.target == target && $0.folder == folder }
      let repository: FollowedFolder.Repository?
      switch discovery {
      case .repository(let found): repository = found
      case .notARepository: repository = nil
      case .unknown:
        if current == true { self.followedFolderCouldNotTell(target: target, folder: folder) }
        return
      }
      self.followedFolderUndeterminedStreak[folder] = nil
      self.followedRepositoryCache[folder] = .some(repository)
      guard current == true else { return }
      let state = FollowedFolderState(
        target: target, folder: FollowedFolder(folder: folder, repository: repository))
      if self.setFollowedFolder(state) {
        self.holdFollowedRepository()
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
    guard let request = followedFolderRequest else { return }
    followedRepositoryCache[request.folder] = nil
    if let root {
      followedRepositoryCache = followedRepositoryCache.filter { _, repository in
        repository.flatMap { $0 }.map { VCSStatusService.canonicalPath($0.root) != root } ?? true
      }
    }
    followedFolderRequest = nil
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
    guard root != heldFollowedRepository else { return }
    if let held = heldFollowedRepository { vcsStatus.unfollow(held) }
    heldFollowedRepository = root
    if let root { vcsStatus.follow(root) }
  }

  /// Something changed under the repository this window follows: re-read its branch and root, and
  /// for a change to its git directory (a commit, a ref moved), its History, as a workroom's git
  /// directory watch does (`handleRootBranchChange`). A save in the tree reloads Changes only
  /// (through the status), as for a workroom.
  func followedRepositoryDidChange(root: String, metadata: Bool) {
    guard heldFollowedRepository == root else { return }
    reresolveFollowedFolder(forgetting: root)
    guard metadata, inspectorIsVisible else { return }
    if historySectionShown { commitHistory.refresh() }
    if remoteToolbarShown { remoteState.refresh(force: true) }
  }

  /// The resolve couldn't tell which repository `folder` is in (a timeout, a repository git
  /// refused). A re-read of the folder already shown keeps what it shows; any other folder shows as
  /// itself, undetermined, never as the repository the terminal was in before (re-review R1).
  /// Nothing is cached, and the request stands, so focus and tab events run nothing until a retry,
  /// spaced out the longer the folder keeps failing: a wedged mount is asked at a bounded rate.
  private func followedFolderCouldNotTell(target: TargetID, folder: String) {
    if followedFolderState?.target != target || followedFolderState?.folder.folder != folder {
      let state = FollowedFolderState(
        target: target,
        folder: FollowedFolder(folder: folder, repository: nil, repositoryUndetermined: true))
      if setFollowedFolder(state) {
        holdFollowedRepository()
        focusHistoryIfShown()
        focusRemoteStateIfShown()
      }
    }
    let streak = (followedFolderUndeterminedStreak[folder] ?? 0) + 1
    followedFolderUndeterminedStreak[folder] = streak
    let delay = followedFolderRetryDelay(streak)
    followedFolderRetryTask?.cancel()
    followedFolderRetryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, let request = self.followedFolderRequest,
        request.target == target, request.folder == folder
      else { return }
      self.reresolveFollowedFolder()
    }
  }

  /// Wait for the followed folder's resolve in flight. For tests.
  func followedFolderResolved() async { await followedFolderTask?.value }

  /// Wait for the scheduled retry of a resolve that couldn't tell, and the resolve it starts. For
  /// tests.
  func followedFolderRetried() async {
    await followedFolderRetryTask?.value
    await followedFolderResolved()
  }

  /// Publish `state` only when it differs, so an unchanged resolve re-renders nothing.
  private func setFollowedFolder(_ state: FollowedFolderState) -> Bool {
    guard followedFolderState != state else { return false }
    followedFolderState = state
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
