import Foundation
import WorkroomDomain
import WorkroomGit
import WorkroomSystem
import WorkroomVCS

/// A watch on a directory tree: what a followed repository's watch needs of `HostFileWatcher`, so a
/// test can stand in for it.
@MainActor
protocol RepositoryWatching: AnyObject {
  func start(path: String)
  func stop()
}

extension HostFileWatcher: RepositoryWatching {}

/// A repository some window's inspector follows (#807), held for as long as any window does: how
/// many hold it, and the watches that keep its status live while they do.
struct FollowedRepositoryHold {
  var holders: Int
  /// The working tree's watch, and for a linked worktree a second one on its repository's git
  /// directory, where its HEAD and refs live, outside the tree.
  var watchers: [any RepositoryWatching]
  /// The full probe (local, then GitHub) in flight, cancelled and replaced by the next full one.
  var probe: Task<Void, Never>? = nil
  /// The local-only probe a change under the tree runs: its own lane, so a save never cancels the
  /// pull request's probe (as the selected workroom's watch lane is apart from its selection's).
  var localProbe: Task<Void, Never>? = nil
}

/// One GitHub probe result, for whichever status it lands in.
enum GitHubStatusUpdate {
  case ci(CIResolution, checkedAt: Date)
  case pullRequest(PRResolution)
  case checks(ChecksResolution)
}

/// The repositories the windows' inspectors follow for their terminals (#807, ADR 0081), and their
/// status: what Changes and Pull Request show for a followed folder. App-wide, as the status is:
/// every window following one repository shares one entry, one probe and one watch, and the last
/// window to stop following it releases them.
///
/// A followed repository that is a registered workroom's or project root's path reads that row's
/// own status, in place: the probes merge there, the sidebar shows what they find, and nothing
/// changes the selection. Any other repository's status lives in `followedStatuses`, which no
/// sidebar row reads.
extension VCSStatusService {
  /// `path` as the file system names it: symlinks resolved (`/tmp` → `/private/tmp`), as git names a
  /// repository's root. Unchanged when it does not exist.
  nonisolated static func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// The registered project root or local workroom whose path is `root`, compared canonically.
  func registeredSidebarID(forRepositoryRoot root: String) -> SidebarID? {
    let root = Self.canonicalPath(root)
    for project in projectStore.projects {
      if Self.canonicalPath(project.path) == root { return .root(project: project.id) }
      for workroom in project.workrooms where !workroom.isRemote {
        if Self.canonicalPath(workroom.path) == root {
          return .workroom(project: project.id, name: workroom.name)
        }
      }
    }
    return nil
  }

  /// A followed repository's status: its registered row's when it has one, else its own.
  func status(forFollowedRoot root: String) -> WorkroomStatus? {
    if let sid = registeredSidebarID(forRepositoryRoot: root) { return workroomStatuses[sid] }
    return followedStatuses[Self.canonicalPath(root)]
  }

  /// Whether some window follows `root`.
  func isFollowing(_ root: String) -> Bool {
    followedRepositories[Self.canonicalPath(root)] != nil
  }

  // MARK: Holding

  /// A window's inspector follows `root`: watch it, if no other window already does, and probe it.
  /// Balanced by one `unfollow(_:)`.
  func follow(_ root: String) {
    let key = Self.canonicalPath(root)
    if var hold = followedRepositories[key] {
      hold.holders += 1
      followedRepositories[key] = hold
    } else {
      followedRepositories[key] = FollowedRepositoryHold(holders: 1, watchers: [])
      if registeredSidebarID(forRepositoryRoot: key) == nil, followedStatuses[key] == nil {
        followedStatuses[key] = .unresolved
      }
      startWatching(key)
    }
    // A window coming to it re-reads it, as selecting a workroom does.
    refreshFollowedStatus(key, gitHub: true)
  }

  /// A window's inspector stops following `root`. The last one out stops its watch and drops its
  /// status, so nothing is left to go stale.
  func unfollow(_ root: String) {
    let key = Self.canonicalPath(root)
    guard var hold = followedRepositories[key] else { return }
    hold.holders -= 1
    if hold.holders > 0 {
      followedRepositories[key] = hold
      return
    }
    hold.probe?.cancel()
    hold.localProbe?.cancel()
    for watcher in hold.watchers { watcher.stop() }
    followedRepositories[key] = nil
    followedStatuses[key] = nil
  }

  private func startWatching(_ key: String) {
    guard probesRepositories else { return }
    let tree = makeRepositoryWatcher { [weak self] paths, overflow in
      self?.handleFollowedRepositoryChange(key, paths: paths, overflow: overflow)
    }
    tree.start(path: key)
    followedRepositories[key]?.watchers.append(tree)
    // A linked worktree's `.git` is a file naming a git directory inside its main repository, which
    // holds the worktree's HEAD and the refs a commit or `git switch` moves.
    guard Self.gitDirectoryIsOutsideTree(key) else { return }
    Task { [weak self] in
      let r = await StatusCommandRunner().run(
        "git",
        GitCommand.hardening + ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        in: key, timeout: 3)
      let directory = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      guard r.ok, !directory.isEmpty, let self,
        self.followedRepositories[key] != nil
      else { return }
      let metadata = self.makeRepositoryWatcher { [weak self] _, _ in
        self?.handleFollowedRepositoryChange(key, paths: [], overflow: true)
      }
      metadata.start(path: directory)
      self.followedRepositories[key]?.watchers.append(metadata)
    }
  }

  nonisolated private static func gitDirectoryIsOutsideTree(_ root: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: root + "/.git", isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }

  // MARK: Probing

  /// Something changed under a followed repository: re-read its local status (a save fires no `gh`
  /// call, as for the selected workroom), and tell the windows following it. `overflow` means the
  /// paths are incomplete, so it counts as a change to the git directory too.
  func handleFollowedRepositoryChange(_ root: String, paths: [String], overflow: Bool) {
    let key = Self.canonicalPath(root)
    guard followedRepositories[key] != nil else { return }
    if !overflow, !paths.isEmpty, paths.allSatisfy(AppStore.isJJInternalPath) { return }
    refreshFollowedStatus(key, gitHub: false)
    let metadata =
      overflow || paths.isEmpty || paths.contains { $0.split(separator: "/").contains(".git") }
    for window in statusWindows {
      window.followedRepositoryDidChange(root: key, metadata: metadata)
    }
  }

  /// Re-read a followed repository's local status and, with `gitHub`, its CI and pull request.
  /// Cancel-and-replace within its lane (local-only, or full), so the latest change wins; a result
  /// for a repository no window follows any more is dropped.
  func refreshFollowedStatus(_ root: String, gitHub: Bool) {
    let key = Self.canonicalPath(root)
    guard probesRepositories, var hold = followedRepositories[key] else { return }
    let registered = registeredSidebarID(forRepositoryRoot: key)
    let item = registered.flatMap(selectedStatusWorkItem(for:))
    if let registered, isCreating(registered) { return }
    if isCommittingProject(item?.sharedLocation) { return }
    let resolver = statusResolver
    let task = Task { [weak self] in
      let fresh =
        if let item {
          await resolver.working.resolve(item: item)
        } else {
          await resolver.working.resolveLocal(path: key)
        }
      guard let self, !Task.isCancelled, self.followedRepositories[key] != nil else { return }
      self.mergeFollowedStatus(fresh, root: key, registered: registered)
      guard gitHub, fresh.failure == nil, item?.permitsGitHubAccess ?? true else { return }
      let location: RepositoryLocation
      do {
        if let item {
          location = try await item.resolvedLocation()
        } else {
          location = try await RepositoryLocation.local(key)
        }
      } catch { return }
      await self.probeGitHub(
        location: location, branch: fresh.branchForCI, settlesUnreachable: true,
        isCurrent: { [weak self] in
          !Task.isCancelled && self?.followedRepositories[key] != nil
        },
        apply: { [weak self] update in
          self?.applyFollowedGitHub(update, root: key, registered: registered)
        })
    }
    if gitHub {
      hold.probe?.cancel()
      hold.probe = task
    } else {
      hold.localProbe?.cancel()
      hold.localProbe = task
    }
    followedRepositories[key] = hold
  }

  /// Wait for every followed repository's probe in flight. For tests.
  func followedStatusSettled() async {
    for hold in followedRepositories.values {
      await hold.probe?.value
      await hold.localProbe?.value
    }
  }

  private func mergeFollowedStatus(_ fresh: WorkroomStatus, root: String, registered: SidebarID?) {
    if let registered { return mergeLocalStatus(fresh, into: registered) }
    var status = followedStatuses[root] ?? .unresolved
    guard status.mergeLocal(fresh) else { return }
    followedStatuses[root] = status
  }

  private func applyFollowedGitHub(
    _ update: GitHubStatusUpdate, root: String, registered: SidebarID?
  ) {
    if let registered { return applyGitHub(update, to: registered) }
    guard var status = followedStatuses[root] else { return }
    status.apply(update)
    followedStatuses[root] = status
  }

  func applyGitHub(_ update: GitHubStatusUpdate, to sid: SidebarID) {
    switch update {
    case .ci(let resolution, let checkedAt):
      applyCIStatus(resolution, to: sid, checkedAt: checkedAt)
    case .pullRequest(let resolution): applyPRStatus(resolution, to: sid)
    case .checks(let resolution): applyChecksStatus(resolution, to: sid)
    }
  }

  /// The GitHub stage of a status probe for `location` on `branch`: CI and the pull request
  /// concurrently, then the pull request's checks and reviewer links. Each lands through `apply` as
  /// it arrives, while `isCurrent()` holds. With `settlesUnreachable`, a repository GitHub can't
  /// be asked about (no GitHub remote) settles as having no pull request, so its section never
  /// stays on "Checking…".
  func probeGitHub(
    location: RepositoryLocation, branch: String?, settlesUnreachable: Bool = false,
    isCurrent: @escaping @MainActor () -> Bool,
    apply: @escaping @MainActor (GitHubStatusUpdate) -> Void
  ) async {
    let resolver = statusResolver
    let github: RepositoryGitHub
    do {
      github = try await RepositoryRouter.shared.gitHub(for: location, resolver: resolver)
    } catch {
      if settlesUnreachable, isCurrent() { apply(.pullRequest(.absent)) }
      return
    }
    // Skip the network CI/PR probes when `gh` isn't usable (the inspector shows a warning instead).
    await refreshGitHubCLI(resolver: resolver)
    guard isCurrent(), githubCLIStatus == .available else { return }
    // CI and the PR list are independent: run them concurrently, and apply CI the moment it lands
    // so the sidebar/tab glyph never waits on the PR probe.
    async let ciRes = github.ciSnapshot(branch: branch)
    async let prRawRes = github.pullRequest(branch: branch)
    let ci = await ciRes
    guard isCurrent() else { return }
    apply(.ci(ci.resolution, checkedAt: ci.checkedAt))
    let prRaw = await prRawRes
    guard isCurrent() else { return }
    apply(.pullRequest(prRaw))
    // With the PR number in hand, fetch its checks and enrich reviewer permalinks concurrently:
    // checks must not wait behind the (conditional) reviewer-URL GraphQL round-trip (issue #75).
    guard case .info(let info) = prRaw else { return }
    async let enrichedRes = github.enrich(prRaw)
    async let checksRes = github.checks(number: info.number)
    let enriched = await enrichedRes
    guard isCurrent() else { return }
    apply(.pullRequest(enriched))
    let checks = await checksRes
    guard isCurrent() else { return }
    apply(.checks(checks))
  }
}

extension VCSStatusFailure {
  /// The read found no repository where one was: deleted, moved, or its `.git` removed. A followed
  /// folder's sections then say "Not a git repository" rather than an error (#807).
  var meansNoRepository: Bool { self == .missingPath || self == .notRepository }
}

extension WorkroomStatus {
  /// Take a local read's fields. False, changing nothing, for a read older than the one recorded
  /// (see `VCSStatusService.mergeLocalStatus`).
  mutating func mergeLocal(_ fresh: WorkroomStatus) -> Bool {
    if let readAt = fresh.localReadAt, let prior = localReadAt, prior > readAt { return false }
    dirty = fresh.dirty
    conflicted = fresh.conflicted
    changedFiles = fresh.changedFiles
    insertions = fresh.insertions
    deletions = fresh.deletions
    branchForCI = fresh.branchForCI
    failure = fresh.failure
    localReadAt = fresh.localReadAt
    lastChecked = Date()
    return true
  }

  mutating func apply(_ update: GitHubStatusUpdate) {
    switch update {
    case .ci(let resolution, let checkedAt): applyCI(resolution, checkedAt: checkedAt)
    case .pullRequest(let resolution): applyPR(resolution)
    case .checks(let resolution): applyChecks(resolution)
    }
  }

  mutating func applyCI(_ res: CIResolution, checkedAt: Date) {
    switch res {
    case .state(let x):
      ci = x
      ciCheckedAt = checkedAt
    case .absent:
      ci = nil
      ciCheckedAt = checkedAt
    case .keepPrior:
      // Transient rate-limit / network blip. Stamp `ciCheckedAt` so the TTL throttles re-probes —
      // but ONLY if we've probed before (ciCheckedAt set). On a first-ever probe that blips, leave
      // it nil so the next sweep retries instead of hiding CI for the full TTL on one blip. Coarse
      // but cheap; true exponential backoff is a future refinement.
      if ciCheckedAt != nil { ciCheckedAt = checkedAt }
    }
  }

  mutating func applyPR(_ res: PRResolution) {
    switch res {
    case .info(let pr):
      // Checks are keyed to a PR's identity (issue #75). If the PR changed (different number), the
      // old PR's checks are stale — drop them so they can't render under the new PR until
      // `resolveChecks` refills them. Same number ⇒ keep them (e.g. the raw→enriched re-apply).
      if self.pr?.number != pr.number {
        checks = nil
        checksCheckedAt = nil
      }
      self.pr = pr
      prCheckedAt = Date()
    case .absent:
      // No PR ⇒ `resolveChecks` won't run, so the checks must be cleared here (not only in
      // `applyChecks`) or a disappearing PR would leave its checks rendered.
      pr = nil
      checks = nil
      checksCheckedAt = nil
      prCheckedAt = Date()
    case .keepPrior:
      // Transient blip: keep the last good PR. Stamp `prCheckedAt` so the TTL throttles re-probes,
      // but only if we've probed before — a first-ever blip leaves it nil so the next sweep retries.
      if prCheckedAt != nil { prCheckedAt = Date() }
    }
  }

  /// Apply a PR-checks probe result (issue #75). `.list` (including `[]` for "loaded, no checks")
  /// sets the rows and stamps `checksCheckedAt`. `.absent` (no checks reported / gh error) is *also*
  /// a loaded state — it stamps with an empty list, distinct from the not-loaded `nil`, so the panel
  /// stops falling back to the run-list aggregate. `.keepPrior` (transient blip) keeps the last good
  /// list, stamping only if we've probed before (so a first-ever blip retries next time). The
  /// clear-on-no-PR / clear-on-PR-change paths live in `applyPR` — `resolveChecks` never runs
  /// without a PR.
  mutating func applyChecks(_ res: ChecksResolution) {
    switch res {
    case .list(let checks):
      self.checks = checks
      checksCheckedAt = Date()
    case .absent:
      checks = []
      checksCheckedAt = Date()
    case .keepPrior:
      if checksCheckedAt != nil { checksCheckedAt = Date() }
    }
  }
}
