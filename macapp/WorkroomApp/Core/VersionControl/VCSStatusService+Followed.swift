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
  /// This hold, apart from one let go of and taken again for the same repository: what a watch set
  /// up after an `await`, or a registration that came back empty, checks it still belongs to
  /// (review of #807, finding 6).
  let id = UUID()
  var holders: Int
  /// The working tree's watch, and for a linked worktree a second one on its repository's git
  /// directory, where its HEAD and refs live, outside the tree.
  var watchers: [any RepositoryWatching]
  /// The full probe (local, then GitHub) in flight, cancelled and replaced by the next full one.
  var probe: Task<Void, Never>? = nil
  /// The local-only probe a change under the tree runs: its own lane, so a save never cancels the
  /// pull request's probe (as the selected workroom's watch lane is apart from its selection's).
  var localProbe: Task<Void, Never>? = nil
  /// Its registration with the repository router (#808), held from the first window's follow to
  /// the last one's unfollow: what lets a write address it. Nil inside when its location couldn't
  /// be told, until a retry (`retryFollowedRegistration`) replaces it with one that could.
  var registration: Task<RepositoryRouter.Registration?, Never>? = nil
  /// Whether `registration` is still running: a retry never replaces one that is, since it may yet
  /// take a router hold that only its own release lets go of.
  var registering = false
  /// How many registrations in a row came back empty: what spaces out its retries.
  var registrationFailures = 0
  /// The wait before the next retry of a registration that came back empty.
  var registrationRetry: Task<Void, Never>? = nil
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
    registeredSidebarID(forCanonicalRoot: canonicalise(root))
  }

  /// The registered row whose canonical path is `root`, already canonical (git names a repository
  /// by its real path). Reads an index of the registered paths, built once per change to the
  /// projects, so the inspector's reads run no `realpath` (review of #807, finding 4).
  func registeredSidebarID(forCanonicalRoot root: String) -> SidebarID? {
    let projects = projectStore.projects
    if let index = registeredIndex, index.projects == projects { return index.ids[root] }
    var ids: [String: SidebarID] = [:]
    // Reversed, so the first registration of a path wins, as the scan this replaced did.
    for project in projects.reversed() {
      for workroom in project.workrooms.reversed() where !workroom.isRemote {
        ids[canonicalise(workroom.path)] = .workroom(project: project.id, name: workroom.name)
      }
      ids[canonicalise(project.path)] = .root(project: project.id)
    }
    registeredIndex = (projects, ids)
    return ids[root]
  }

  /// A followed repository's status: its registered row's when it has one, else its own. `root` is
  /// git's, so canonical already: a read touches no file system.
  func status(forFollowedRoot root: String) -> WorkroomStatus? {
    if let sid = registeredSidebarID(forCanonicalRoot: root) { return workroomStatuses[sid] }
    return followedStatuses[root]
  }

  /// Whether some window follows `root`.
  ///
  /// Every root this extension takes (here and in `follow`, `unfollow` and the refreshes) is git's,
  /// so canonical already, and is the key as given: none runs `realpath` on the main actor, where a
  /// stalled network mount would freeze every window (Codex on #812).
  func isFollowing(_ root: String) -> Bool {
    followedRepositories[root] != nil
  }

  // MARK: Holding

  /// A window's inspector follows `root`: watch it, if no other window already does, and probe it.
  /// Balanced by one `unfollow(_:)`.
  func follow(_ root: String) {
    let key = root
    if var hold = followedRepositories[key] {
      hold.holders += 1
      followedRepositories[key] = hold
      // Another window coming to it asks again, rather than inherit a registration that came back
      // empty (lane B review M1).
      retryFollowedRegistration(key)
    } else {
      var hold = FollowedRepositoryHold(holders: 1, watchers: [])
      hold.registering = true
      hold.registration = registerFollowed(key, hold: hold.id)
      followedRepositories[key] = hold
      if registeredSidebarID(forCanonicalRoot: key) == nil, followedStatuses[key] == nil {
        // One followed lately shows what it last showed at once; the probe below refreshes it.
        followedStatuses[key] = recentFollowedStatuses.value(for: key) ?? .unresolved
      }
      startWatching(key)
    }
    // A window coming to it re-reads it, as selecting a workroom does, after the same debounce.
    refreshFollowedStatus(key, gitHub: true, debounced: true)
  }

  /// A window's inspector stops following `root`. The last one out stops its watch and drops its
  /// status, so nothing is left to go stale.
  func unfollow(_ root: String) {
    let key = root
    guard var hold = followedRepositories[key] else { return }
    hold.holders -= 1
    if hold.holders > 0 {
      followedRepositories[key] = hold
      return
    }
    hold.probe?.cancel()
    hold.localProbe?.cancel()
    hold.registrationRetry?.cancel()
    for watcher in hold.watchers { watcher.stop() }
    followedRepositories[key] = nil
    // Kept for a revisit, as data only: the hold, its registration and its watch all go.
    if let last = followedStatuses[key], last != .unresolved {
      recentFollowedStatuses.store(last, for: key)
    }
    followedStatuses[key] = nil
    unregisteredFollowedRoots.remove(key)
    releaseFollowed(hold.registration)
  }

  // MARK: Registration

  /// Register a followed repository with the router, so a commit, push, pull or fetch in it routes
  /// as a workroom's does (#808). One hold on the router per hold here, taken once its location is
  /// known and released by `releaseFollowed` only after that, so the two always balance: a
  /// repository let go and followed again while this runs ends with exactly the new hold's.
  ///
  /// One that comes back empty is recorded in `unregisteredFollowedRoots` while `hold` stands, and
  /// the windows are told, so they stop offering the writes it would refuse; it is retried after
  /// a backoff, and sooner on a window's follow, `cd` or Refresh (`retryFollowedRegistration`).
  private func registerFollowed(
    _ key: String, hold: UUID
  ) -> Task<RepositoryRouter.Registration?, Never> {
    let router = RepositoryRouter.shared
    let resolve = resolveFollowedRegistration
    return Task { [weak self] in
      let registration = await resolve(key)
      // Taken even when the hold is gone meanwhile: its release awaits this and lets go of it.
      if let registration { router.holdFollowed(registration) }
      self?.followedRegistrationSettled(key, hold: hold, registered: registration != nil)
      return registration
    }
  }

  /// `hold`'s registration came back: registered, or empty again, so retried after a wait that
  /// doubles with each empty one (`followedRegistrationRetryWait`). Either way the windows are told
  /// when the root's standing changed, so they offer, or stop offering, its writes.
  private func followedRegistrationSettled(_ key: String, hold: UUID, registered: Bool) {
    guard var entry = followedRepositories[key], entry.id == hold else { return }
    entry.registering = false
    entry.registrationRetry?.cancel()
    entry.registrationRetry = nil
    let changed: Bool
    if registered {
      entry.registrationFailures = 0
      changed = unregisteredFollowedRoots.remove(key) != nil
    } else {
      entry.registrationFailures += 1
      let (wait, streak) = (followedRegistrationRetryWait, entry.registrationFailures)
      entry.registrationRetry = Task { [weak self] in
        await wait(streak)
        guard !Task.isCancelled else { return }
        self?.retryFollowedRegistration(key)
      }
      changed = unregisteredFollowedRoots.insert(key).inserted
    }
    followedRepositories[key] = entry
    guard changed else { return }
    for window in statusWindows { window.followedRegistrationDidChange(root: key) }
  }

  /// Ask again for the registration of `root`, followed, whose last one came back empty: at once,
  /// in place of the backoff's wait. Nothing while one is running, or once it is registered. Its
  /// writes stay refused until the new one is in.
  func retryFollowedRegistration(_ root: String) {
    let key = root
    guard unregisteredFollowedRoots.contains(key), var hold = followedRepositories[key],
      !hold.registering
    else { return }
    hold.registrationRetry?.cancel()
    hold.registrationRetry = nil
    hold.registering = true
    hold.registration = registerFollowed(key, hold: hold.id)
    followedRepositories[key] = hold
  }

  /// Release what `registration` took, once it has taken it: nothing, when it registered nothing.
  private func releaseFollowed(_ registration: Task<RepositoryRouter.Registration?, Never>?) {
    guard let registration else { return }
    let router = RepositoryRouter.shared
    let earlier = followedRelease
    followedRelease = Task {
      await earlier?.value
      if let held = await registration.value { router.releaseFollowed(held.location) }
    }
  }

  /// A followed repository's registration: itself as the repository its writes are serialised on,
  /// or for a linked worktree its main working tree, whose refs and objects it shares. A submodule
  /// or a worktree of a bare repository (a git directory that is no `<tree>/.git`) is its own.
  ///
  /// Nil when git can't say which repository a linked worktree's git directory belongs to (a
  /// timeout, a dangling `gitdir:`): registered as its own, its writes and its main repository's
  /// would stop refusing each other, so it is not registered at all. Its writes, and the toolbar's
  /// reads, are refused until a retry registers it.
  nonisolated static func followedRegistration(root: String) async
    -> RepositoryRouter.Registration?
  {
    guard let location = try? await RepositoryLocation.local(root) else { return nil }
    var shared = location
    let path = location.path
    // Bounded and joined with the watch setup's stat of the same `.git` (`gitFileReadKey`).
    let outside = await GitRepositoryProbe.blockingRead(
      gitFileReadKey(path), timeout: 3, { gitDirectoryIsOutsideTree(path) })
    if outside == true {
      let r = await StatusCommandRunner().run(
        "git",
        GitCommand.hardening + ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        in: path, timeout: 3)
      let directory = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
      guard r.ok, directory.length > 0 else { return nil }
      if directory.lastPathComponent == ".git" {
        guard let main = try? await RepositoryLocation.local(directory.deletingLastPathComponent)
        else { return nil }
        shared = main
      }
    }
    return try? RepositoryRouter.Registration(
      location: location, sharedLocation: shared, localSourcePath: root)
  }

  /// Where a write to the followed repository at `root` lands: its registered location, once its
  /// registration is in. Nil when no window follows it (any more): a write then addresses nothing,
  /// never whichever repository the terminal has moved to.
  func followedWriteLocation(_ root: String) async -> RepositoryLocation? {
    guard let registration = followedRepositories[root]?.registration else { return nil }
    guard let location = await registration.value?.location else { return nil }
    // Its `.git` may be gone since it was followed, with no watch event in yet to say so: the
    // registration skips the check an unregistered read makes, so it is made here, and git is
    // never run at a root that is no repository's any more.
    let url = URL(fileURLWithPath: location.path, isDirectory: true)
    guard (try? await runBlocking({ isGitRepo(at: url) })) == true else { return nil }
    // Let go of while this waited, and perhaps followed again under a new hold: only the hold
    // whose registration this is may be written through.
    guard followedRepositories[root]?.registration == registration else { return nil }
    return location
  }

  /// The hold on `root`, nil when no window follows it: what a write captures at the click, to tell
  /// later whether that hold still stands rather than one taken afresh. Not its registration, which
  /// a retry replaces under the same hold.
  func followedHold(of root: String) -> UUID? {
    followedRepositories[root]?.id
  }

  // MARK: Writes

  /// Whether a write to `target` has something to address: a row's work item, or a repository some
  /// window follows. The write side's `status(for:)`.
  func canAddress(_ target: VCSActionTarget) -> Bool {
    switch target {
    case .row(let sid): return selectedStatusWorkItem(for: sid) != nil
    case .followed(let root): return isFollowing(root)
    }
  }

  /// Where a write to `target` lands, resolved when the write runs from what was captured at the
  /// click. A followed repository's is its registration's, awaited: refused once no window follows
  /// it, rather than sent wherever the terminal has gone since.
  func writeLocation(for target: VCSActionTarget) async throws -> RepositoryLocation {
    switch target {
    case .row(let sid):
      guard let item = selectedStatusWorkItem(for: sid) else {
        throw RepositoryRoutingError.registrationRequired
      }
      return try await item.resolvedLocation()
    case .followed(let root):
      guard let location = await followedWriteLocation(root) else {
        // Still followed, but its registration came back empty: the terminal hasn't gone anywhere.
        if unregisteredFollowedRoots.contains(root) { throw FollowedRepositoryUnregistered() }
        throw FollowedRepositoryGone()
      }
      return location
    }
  }

  /// Set `target`'s pull request in its status, when it has a status: a row's, or a followed
  /// repository's own.
  func setPullRequest(_ pr: PullRequestInfo?, on target: VCSActionTarget) {
    switch target {
    case .row(let sid):
      guard var status = workroomStatuses[sid] else { return }
      status.pr = pr
      workroomStatuses[sid] = status
    case .followed(let root):
      guard var status = followedStatuses[root] else { return }
      status.pr = pr
      followedStatuses[root] = status
    }
  }

  /// The repository a followed root's writes are serialised on, once it is registered: what the
  /// read lanes stand clear of while a commit runs there.
  func followedSharedLocation(_ root: String) -> RepositoryLocation? {
    let router = RepositoryRouter.shared
    return router.localLocation(for: root).flatMap { router.entry(for: $0)?.sharedLocation }
  }

  /// Wait for every followed repository's registration, and every release, in flight. For tests.
  func followedRegistrationsSettled() async {
    for hold in followedRepositories.values { _ = await hold.registration?.value }
    await followedRelease?.value
  }

  /// Wait for every scheduled registration retry, and the registration it starts. For tests.
  func followedRegistrationRetriesSettled() async {
    for hold in followedRepositories.values { await hold.registrationRetry?.value }
    await followedRegistrationsSettled()
  }

  private func startWatching(_ key: String) {
    guard let hold = followedRepositories[key]?.id else { return }
    // A repository at the home folder (dotfiles) or a disk's root is a tree that never rests
    // (`~/Library`): watch only its git directory, so a commit or `git switch` still lands, and a
    // save shows on the next probe or Refresh (review of #807, finding 3).
    let broad = HostFileWatcher.isTooBroadToWatch(key, home: watchHome)
    if !broad { watchFollowedTree(key, at: key) }
    let (stat, timeout) = (followedGitFileStat, followedStatTimeout)
    followedWatchSetups[hold] = Task { [weak self] in
      defer { self?.followedWatchSetups[hold] = nil }
      // Whether `.git` is a file: a stat, which a stalled network mount blocks, so it is read off
      // the main actor, bounded and joined (Codex on #812). One that can't tell is taken as a
      // `.git` directory's, as a stat that fails is.
      let outside =
        await GitRepositoryProbe.blockingRead(
          Self.gitFileReadKey(key), timeout: timeout, { stat(key) }) ?? false
      // Let go of while it ran, and perhaps followed again: that hold sets up its own watch.
      guard let self, self.followedRepositories[key]?.id == hold else { return }
      if broad, !outside { self.watchFollowedTree(key, at: key + "/.git") }
      // A linked worktree's `.git` is a file naming a git directory inside its main repository,
      // which holds the worktree's HEAD and the refs a commit or `git switch` moves.
      guard outside else { return }
      let r = await StatusCommandRunner().run(
        "git",
        GitCommand.hardening + ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        in: key, timeout: 3)
      let directory = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      // Let go of while git ran, and perhaps followed again: that hold sets up its own watch.
      guard r.ok, !directory.isEmpty, self.followedRepositories[key]?.id == hold else { return }
      let metadata = self.makeRepositoryWatcher { [weak self] _, _ in
        self?.handleFollowedRepositoryChange(key, paths: [], overflow: true)
      }
      metadata.start(path: directory)
      self.followedRepositories[key]?.watchers.append(metadata)
    }
  }

  /// Watch `path` for the followed repository at `key`: its tree, or only its git directory.
  private func watchFollowedTree(_ key: String, at path: String) {
    let tree = makeRepositoryWatcher { [weak self] paths, overflow in
      self?.handleFollowedRepositoryChange(key, paths: paths, overflow: overflow)
    }
    tree.start(path: path)
    followedRepositories[key]?.watchers.append(tree)
  }

  /// The `blockingRead` key of `root`'s `.git` stat, which the watch setup and the registration
  /// share, so a stalled mount holds one GCD thread for both.
  nonisolated private static func gitFileReadKey(_ root: String) -> String {
    "gitfile\u{0}\(root)"
  }

  /// Wait for every followed repository's watch being set up. For tests.
  func followedWatchesSettled() async {
    while let setup = followedWatchSetups.values.first { await setup.value }
  }

  nonisolated static func gitDirectoryIsOutsideTree(_ root: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: root + "/.git", isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }

  // MARK: Probing

  /// Something changed under a followed repository: re-read its local status (a save fires no `gh`
  /// call, as for the selected workroom), and tell the windows following it. `overflow` means the
  /// paths are incomplete, so it counts as a change to the git directory too. A moved ref (a
  /// `git switch`, a commit, a push or fetch) asks GitHub again too, after the probe's debounce:
  /// the branch's pull request and CI may be another's now (review of #807, finding 2).
  func handleFollowedRepositoryChange(_ root: String, paths: [String], overflow: Bool) {
    let key = root
    guard followedRepositories[key] != nil else { return }
    if !overflow, !paths.isEmpty, paths.allSatisfy(AppStore.isJJInternalPath) { return }
    let incomplete = overflow || paths.isEmpty
    refreshFollowedStatus(key, gitHub: false)
    if incomplete || paths.contains(where: Self.isGitRefPath) {
      refreshFollowedStatus(key, gitHub: true, debounced: true)
    }
    let metadata = incomplete || paths.contains { $0.split(separator: "/").contains(".git") }
    for window in statusWindows {
      window.followedRepositoryDidChange(root: key, metadata: metadata)
    }
  }

  /// Whether `path` is one of a git directory's refs: `HEAD`, `FETCH_HEAD`, `packed-refs`, or under
  /// `refs/`. Not `index`, which a `git status` itself can rewrite.
  nonisolated static func isGitRefPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    guard let git = parts.lastIndex(of: ".git"), git + 1 < parts.count else { return false }
    return ["HEAD", "FETCH_HEAD", "packed-refs", "refs"].contains(parts[git + 1])
  }

  /// Re-read a followed repository's local status and, with `gitHub`, its CI and pull request.
  /// Cancel-and-replace within its lane (local-only, or full), so the latest change wins; a result
  /// for a repository no window follows any more is dropped. `debounced` waits
  /// `followedProbeDebounce` first, so a burst (or a repository passed by) forks nothing.
  ///
  /// Returns the probe it started, nil when it started none, for a caller that waits on the read.
  @discardableResult
  func refreshFollowedStatus(
    _ root: String, gitHub: Bool, debounced: Bool = false
  ) -> Task<Void, Never>? {
    let key = root
    // Probed even under seeded statuses: a followed folder is a real repository (the UI-test
    // fixture's are throwaway ones its shell makes), where a seeded row's path is not one.
    guard var hold = followedRepositories[key] else { return nil }
    let registered = registeredSidebarID(forCanonicalRoot: key)
    // A registered row keeps its seeded status, as its own lanes leave it.
    if registered != nil, !probesRepositories { return nil }
    let item = registered.flatMap(selectedStatusWorkItem(for:))
    if let registered, isCreating(registered) { return nil }
    // A followed repository's own commit keeps its read lanes off it too (#808): a `git status`
    // mid-commit contends on `index.lock`, as for a workroom.
    if isCommittingProject(item?.sharedLocation ?? followedSharedLocation(key)) { return nil }
    let resolver = statusResolver
    let debounce = debounced ? followedProbeDebounce : 0
    let task = Task { [weak self] in
      if debounce > 0 {
        try? await Task.sleep(for: .seconds(debounce))
        if Task.isCancelled { return }
      }
      let fresh =
        if let item {
          await resolver.working.resolve(item: item)
        } else {
          await resolver.working.resolveLocal(path: key)
        }
      guard let self, !Task.isCancelled, self.followedRepositories[key] != nil else { return }
      self.mergeFollowedStatus(fresh, root: key, registered: registered)
      guard gitHub, fresh.failure == nil, item?.permitsGitHubAccess ?? true else { return }
      // Seeded statuses have no `gh` behind them (`refreshGitHubCLI` no-ops), so a followed
      // repository there never reaches GitHub: it settles as having no pull request.
      guard self.probesRepositories else {
        return self.applyFollowedGitHub(.pullRequest(.absent), root: key, registered: registered)
      }
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
    return task
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
