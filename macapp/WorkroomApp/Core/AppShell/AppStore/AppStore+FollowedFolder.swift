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
  /// Whether `sid`'s inspector follows its terminal's folder: a standalone terminal.
  static func followsFolder(_ sid: SidebarID) -> Bool {
    if case .standalone = sid { return true }
    return false
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
    followedFolderTask = Task { [weak self] in
      var repository = await resolve(folder)
      // Placed off the main actor: it reads the folder's real path.
      if let found = repository {
        repository = (try? await runBlocking { found.placed(in: folder) }) ?? found
      }
      guard let self, !Task.isCancelled else { return }
      self.followedRepositoryCache[folder] = .some(repository)
      // A later request (another folder, another target) has taken over.
      guard let request = self.followedFolderRequest, request.target == target,
        request.folder == folder
      else { return }
      let state = FollowedFolderState(
        target: target, folder: FollowedFolder(folder: folder, repository: repository))
      if self.setFollowedFolder(state) {
        self.focusHistoryIfShown()
        self.focusRemoteStateIfShown()
      }
    }
    return changed
  }

  /// Wait for the followed folder's resolve in flight. For tests.
  func followedFolderResolved() async { await followedFolderTask?.value }

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
