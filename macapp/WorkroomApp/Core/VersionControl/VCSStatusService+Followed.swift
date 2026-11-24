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
  /// What a write captured at the click checks still stands (`followedHold(of:)`): renewed by every
  /// first follow, so a write captured before the last window let go stays refused after a
  /// re-follow inside the grace. Apart from `id`, which the watch and registration check.
  var followToken = UUID()
  /// The grace the last window's unfollow starts (`followedUnfollowGrace`): the hold keeps its
  /// watch and status while it runs, never its writes, and is let go of when it ends.
  var grace: Task<Void, Never>? = nil
  /// Whether the router hold was let go of when the grace began, so the end of the grace never
  /// lets go of it twice.
  var registrationReleased = false
  /// A change, or a probe cut short, while in the grace: what a re-follow reads again, the local
  /// status only or with GitHub. Nothing runs while no window follows.
  var staleLocal = false
  var staleGitHub = false
  /// The probe still running in each lane, cleared as it ends.
  var probeToken: UUID? = nil
  var localProbeToken: UUID? = nil
  /// Whether the full probe has reached GitHub: a later batch of the same commit (a local branch
  /// moving again) never cancels the round in flight to ask again.
  var askingGitHub = false

  /// In the grace: no window follows it, and nothing writes to it.
  var isLingering: Bool { holders == 0 }
}

/// A followed repository's status reads, one in flight at a time (`VCSStatusService.followedRead`):
/// the daemon can't cancel a `working_status`, so a superseded read still runs its git to the end,
/// and a second beside it would only double the cost.
struct FollowedStatusReads {
  /// The latest demand for a fresh read: each change that needs one, and each follow, sweep or
  /// Refresh, takes the next. A read serves every demand taken before it started.
  var demand = 0
  /// The read in flight, the demand it serves up to, and the row it read for.
  var inFlight: (task: Task<Void, Never>, demand: Int, registered: SidebarID?)?
  /// The last read to land.
  var last: (status: WorkroomStatus, demand: Int, registered: SidebarID?)?
}

/// What one watch delivery asks of a followed repository (`VCSStatusService.followedChange`).
struct FollowedRepositoryChange: Equatable {
  /// Re-read the local status: a save, an index write, a moved ref.
  var readsStatus = false
  /// Ask GitHub again: a moved ref (HEAD, a branch, a remote's, a fetch).
  var asksGitHub = false
  /// Re-resolve the folder in every window following it, and refresh History and the remote:
  /// a moved ref, or a `.git` appearing or going.
  var metadata = false
  /// Whether every ref it moved is a local branch under `refs/heads/`: a commit's later batch,
  /// which never interrupts a GitHub round in flight. Not part of its equality.
  var movesOnlyLocalBranches = false

  static let everything = FollowedRepositoryChange(
    readsStatus: true, asksGitHub: true, metadata: true)

  static func == (a: Self, b: Self) -> Bool {
    (a.readsStatus, a.asksGitHub, a.metadata) == (b.readsStatus, b.asksGitHub, b.metadata)
  }

  /// What one path under a git directory, or in the tree, is.
  enum PathKind {
    /// Nothing `git status` or GitHub sees: objects, reflogs, lock files, a sibling worktree's.
    case ignored
    /// A file in the tree, or the index.
    case status
    /// A local branch under `refs/heads/`.
    case localBranch
    /// HEAD, another ref, `packed-refs` or `FETCH_HEAD`.
    case ref
    /// A `.git` itself, appearing or going.
    case gitEntry
  }

  mutating func add(_ kind: PathKind) {
    switch kind {
    case .ignored: return
    case .status: readsStatus = true
    case .localBranch:
      if !asksGitHub { movesOnlyLocalBranches = true }
      (readsStatus, asksGitHub, metadata) = (true, true, true)
    case .ref, .gitEntry:
      (readsStatus, asksGitHub, metadata) = (true, true, true)
      movesOnlyLocalBranches = false
    }
  }
}

/// The registered project roots and local workrooms by canonical path (`VCSStatusService
/// .rebuildRegisteredIndex`): what tells a followed repository that is a registered row's apart
/// from any other, with no file system access at the read.
struct RegisteredPathIndex: Equatable {
  /// The project list it was built from.
  let projects: [Project]
  let ids: [String: SidebarID]
  /// The registered paths whose `realpath` timed out, indexed by their literal path until a build
  /// resolves them.
  let timedOut: Set<String>
  /// Which build this is (`registeredIndexGeneration`): a build lands only over an older one.
  let generation: Int
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

  /// The registered row whose canonical path is `root`, already canonical (git names a repository
  /// by its real path). A read of the last finished registered-path index, touching no file
  /// system (review of #807, finding 4; Codex on #812): until the first build lands it finds no
  /// row, and between a change to the projects and its rebuild it finds the previous list's.
  func registeredSidebarID(forCanonicalRoot root: String) -> SidebarID? {
    registeredIndex?.ids[root]
  }

  // MARK: Registered-path index

  /// Rebuild the registered-path index whenever the projects change, and once now.
  func observeRegisteredPaths() {
    withObservationTracking {
      _ = projectStore.projects
    } onChange: { [weak self] in
      // Called before the list changes: re-read it, and re-arm, once it has.
      Task { @MainActor [weak self] in self?.observeRegisteredPaths() }
    }
    rebuildRegisteredIndex()
  }

  /// Build the registered-path index for the current projects off the main actor: every path's
  /// `realpath` at once, each under the bounded read `GitRepositoryProbe.blockingRead`, so a
  /// stalled mount costs its own entry `registeredPathTimeout` and the rest of the index still
  /// builds. A path that timed out is indexed by its literal path, and the next build retries it.
  ///
  /// Nothing when a build for this list is in flight, or one landed with every path resolved.
  func rebuildRegisteredIndex() {
    let projects = projectStore.projects
    if let build = registeredIndexBuild, build.projects == projects { return }
    if let index = registeredIndex, index.projects == projects, index.timedOut.isEmpty { return }
    registeredIndexGeneration += 1
    let generation = registeredIndexGeneration
    // Reversed, so the first registration of a path wins, as the scan this replaced did.
    var entries: [(path: String, id: SidebarID)] = []
    for project in projects.reversed() {
      for workroom in project.workrooms.reversed() where !workroom.isRemote {
        entries.append((workroom.path, .workroom(project: project.id, name: workroom.name)))
      }
      entries.append((project.path, .root(project: project.id)))
    }
    let (canonicalise, timeout) = (self.canonicalise, registeredPathTimeout)
    let paths = Set(entries.map(\.path))
    let task = Task { [weak self] in
      let resolved = await withTaskGroup(of: (String, String?).self) { group in
        for path in paths {
          group.addTask {
            let real = await GitRepositoryProbe.blockingRead(
              "realpath\u{0}\(path)", timeout: timeout, { canonicalise(path) })
            return (path, real)
          }
        }
        var resolved: [String: String?] = [:]
        for await (path, real) in group { resolved[path] = real }
        return resolved
      }
      var ids: [String: SidebarID] = [:]
      for entry in entries {
        ids[(resolved[entry.path] ?? nil) ?? entry.path] = entry.id
      }
      let timedOut = Set(resolved.filter { $0.value == nil }.keys)
      self?.installRegisteredIndex(
        RegisteredPathIndex(
          projects: projects, ids: ids, timedOut: timedOut, generation: generation))
    }
    registeredIndexBuild = (projects, task)
  }

  /// A build landed: it replaces an older index, never a newer one. Every followed repository
  /// whose registered row it changes is re-routed (`rerouteFollowed`).
  private func installRegisteredIndex(_ index: RegisteredPathIndex) {
    if registeredIndexBuild?.projects == index.projects,
      index.generation == registeredIndexGeneration
    {
      registeredIndexBuild = nil
    }
    guard index.generation > (registeredIndex?.generation ?? 0) else { return }
    let before = registeredIndex
    registeredIndex = index
    for key in followedRepositories.keys where before?.ids[key] != index.ids[key] {
      rerouteFollowed(key, registered: index.ids[key])
    }
  }

  /// A followed repository's registered row changed under it: its status source switches between
  /// the row's, in place, and its own (`followedStatuses`).
  ///
  /// Its hold, its router registration and its watches stand: they are the repository's, by root,
  /// the same in either mode. Its probes in flight are cancelled and asked again for the new
  /// source, and a result from one already past its last `await` is dropped by its own check that
  /// the row it captured is still the root's (`refreshFollowedStatus`), so a stale read never lands
  /// in the source it left. A write captured at the click as `.row(sid)` resolves the row's own
  /// work item, refused once the row is gone; one captured as `.followed(root)` writes through the
  /// hold's registration, the same repository on disk. Both serialise on the same shared location
  /// (`isCommittingProject`), so a commit through either keeps the other's reads off it (ADR 0081).
  private func rerouteFollowed(_ key: String, registered: SidebarID?) {
    guard var hold = followedRepositories[key] else { return }
    hold.probe?.cancel()
    hold.probe = nil
    hold.localProbe?.cancel()
    hold.localProbe = nil
    followedRepositories[key] = hold
    if registered != nil {
      // Kept for a revisit, as an unfollow keeps it.
      if let last = followedStatuses[key], last != .unresolved {
        recentFollowedStatuses.store(last, for: key)
      }
      followedStatuses[key] = nil
    } else if followedStatuses[key] == nil {
      followedStatuses[key] = recentFollowedStatuses.value(for: key) ?? .unresolved
    }
    refreshFollowedStatus(key, gitHub: true)
    // Commit and the toolbar address the row, or the repository, now.
    for window in statusWindows { window.followedRegistrationDidChange(root: key) }
  }

  /// Wait for the registered-path index to be built for the current projects, starting the build
  /// when the change's observation hasn't yet. For tests.
  func registeredIndexSettled() async {
    rebuildRegisteredIndex()
    while let build = registeredIndexBuild { await build.task.value }
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
    followedRepositories[root].map { !$0.isLingering } ?? false
  }

  // MARK: Holding

  /// A window's inspector follows `root`: watch it, if no other window already does, and probe it.
  /// Balanced by one `unfollow(_:)`.
  func follow(_ root: String) {
    let key = root
    // A registered path that timed out last build is tried again, off the main actor.
    rebuildRegisteredIndex()
    if let hold = followedRepositories[key], hold.isLingering {
      return resumeFollowed(key)
    }
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

  /// A window's inspector stops following `root`. The last one out ends its writes at once, and
  /// starts a grace (`followedUnfollowGrace`) at whose end its watch stops and its status goes, so
  /// nothing is left to go stale: focus moving between panes in two repositories and back inside
  /// it sets up nothing again and asks GitHub nothing (#812 perf review).
  func unfollow(_ root: String) {
    let key = root
    guard var hold = followedRepositories[key], !hold.isLingering else { return }
    hold.holders -= 1
    if hold.holders > 0 {
      followedRepositories[key] = hold
      return
    }
    let grace = followedUnfollowGrace
    // A registration still running is let go of at once: a re-follow in the grace would run a
    // second beside it under the same hold, which `registering` exists to prevent.
    guard grace > 0, !hold.registering else {
      followedRepositories[key] = hold
      return letGoOfFollowed(key)
    }
    // A probe cut short is read again on a re-follow; nothing runs while no window follows.
    if hold.probeToken != nil { hold.staleGitHub = true }
    if hold.localProbeToken != nil { hold.staleLocal = true }
    hold.probe?.cancel()
    (hold.probe, hold.probeToken, hold.askingGitHub) = (nil, nil, false)
    hold.localProbe?.cancel()
    (hold.localProbe, hold.localProbeToken) = (nil, nil)
    hold.registrationRetry?.cancel()
    hold.registrationRetry = nil
    // Its writes end here: the router lets go now, and the grace keeps the watch and status only.
    releaseFollowed(hold.registration)
    hold.registrationReleased = true
    let id = hold.id
    hold.grace = Task { [weak self] in
      try? await Task.sleep(for: .seconds(grace))
      guard !Task.isCancelled, let self, let hold = self.followedRepositories[key],
        hold.id == id, hold.isLingering
      else { return }
      self.letGoOfFollowed(key)
    }
    followedRepositories[key] = hold
  }

  /// A window follows `root` again inside its grace: the watch, the status and the registration
  /// are reused, the router hold taken again from the registration already resolved (no git), and
  /// only what changed meanwhile is read.
  private func resumeFollowed(_ key: String) {
    guard var hold = followedRepositories[key], hold.isLingering else { return }
    hold.grace?.cancel()
    hold.grace = nil
    hold.holders = 1
    hold.followToken = UUID()
    let (kept, earlier, resolve) = (hold.registration, followedRelease, resolveFollowedRegistration)
    hold.registering = true
    hold.registrationReleased = false
    // After the grace's release, so the router's count balances; resolved afresh only when the
    // kept one came back empty.
    hold.registration = registerFollowed(key, hold: hold.id) { root in
      await earlier?.value
      if let registration = await kept?.value { return registration }
      return await resolve(root)
    }
    // A kept status that failed or never resolved is asked again, as a first follow would.
    let unsettled = followedStatuses[key].map { $0.failure != nil || $0.dirty == nil } ?? false
    let (local, gitHub) = (hold.staleLocal, hold.staleGitHub || unsettled)
    (hold.staleLocal, hold.staleGitHub) = (false, false)
    followedRepositories[key] = hold
    if gitHub {
      refreshFollowedStatus(key, gitHub: true, debounced: true)
    } else if local {
      refreshFollowedStatus(key, gitHub: false)
    }
  }

  /// Let go of the hold on `key`: its watch stops, its probes and router hold go, and its status
  /// is kept for a revisit, as data only.
  private func letGoOfFollowed(_ key: String) {
    guard let hold = followedRepositories[key] else { return }
    hold.probe?.cancel()
    hold.localProbe?.cancel()
    hold.registrationRetry?.cancel()
    hold.grace?.cancel()
    for watcher in hold.watchers { watcher.stop() }
    followedRepositories[key] = nil
    if let last = followedStatuses[key], last != .unresolved {
      recentFollowedStatuses.store(last, for: key)
    }
    followedStatuses[key] = nil
    unregisteredFollowedRoots.remove(key)
    if !hold.registrationReleased { releaseFollowed(hold.registration) }
    // A read in flight lands, and drops its entry, itself (`landFollowedRead`).
    if followedReads[key]?.inFlight == nil { followedReads[key] = nil }
  }

  /// Wait for every unfollow's grace to end. For tests.
  func followedGraceSettled() async {
    while let grace = followedRepositories.values.lazy.compactMap(\.grace).first {
      await grace.value
    }
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
    _ key: String, hold: UUID,
    resolving: (@Sendable (String) async -> RepositoryRouter.Registration?)? = nil
  ) -> Task<RepositoryRouter.Registration?, Never> {
    let router = RepositoryRouter.shared
    let resolve = resolving ?? resolveFollowedRegistration
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
    } else if entry.isLingering {
      // Retried on the re-follow, if one comes.
      entry.registrationFailures += 1
      changed = unregisteredFollowedRoots.insert(key).inserted
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
      !hold.registering, !hold.isLingering
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
    // Every read here is bounded: a stalled mount comes back empty, and is retried (Codex on #812).
    guard let location = await GitRepositoryProbe.localLocation(root) else { return nil }
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
        guard
          let main = await GitRepositoryProbe.localLocation(directory.deletingLastPathComponent)
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
    // In the grace nothing writes: the watch and status stay, the right to write does not.
    guard let hold = followedRepositories[root], !hold.isLingering,
      let registration = hold.registration
    else { return nil }
    let token = hold.followToken
    guard let location = await registration.value?.location else { return nil }
    // Its `.git` may be gone since it was followed, with no watch event in yet to say so: the
    // registration skips the check an unregistered read makes, so it is made here, and git is
    // never run at a root that is no repository's any more.
    let url = URL(fileURLWithPath: location.path, isDirectory: true)
    // Bounded: a stalled mount refuses the write rather than hang it (Codex on #812).
    let isRepository = await GitRepositoryProbe.blockingRead(
      "isrepo\u{0}\(location.path)", timeout: 3, { isGitRepo(at: url) })
    guard isRepository == true else { return nil }
    // Let go of while this waited, and perhaps followed again under a new hold: only the hold
    // whose registration this is may be written through.
    guard let now = followedRepositories[root], now.registration == registration,
      now.followToken == token, !now.isLingering
    else { return nil }
    return location
  }

  /// The hold on `root`, nil when no window follows it: what a write captures at the click, to tell
  /// later whether that hold still stands rather than one taken afresh. Not its registration, which
  /// a retry replaces under the same hold.
  func followedHold(of root: String) -> UUID? {
    guard let hold = followedRepositories[root], !hold.isLingering else { return nil }
    return hold.followToken
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
      // Its own git directory (`worktrees/<name>`) and the repository's, in one run.
      let r = await StatusCommandRunner().run(
        "git",
        GitCommand.hardening + [
          "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
        ],
        in: key, timeout: 3)
      let lines = r.stdout.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      // Let go of while git ran, and perhaps followed again: that hold sets up its own watch.
      guard r.ok, lines.count == 2, !lines[0].isEmpty, !lines[1].isEmpty,
        self.followedRepositories[key]?.id == hold
      else { return }
      let (own, directory) = (lines[0], lines[1])
      // Only its own HEAD, index and FETCH_HEAD, and the shared refs: a sibling worktree's or the
      // main checkout's index write, or an object, asks nothing (#812 perf review, I5).
      let metadata = self.makeRepositoryWatcher { [weak self] paths, overflow in
        self?.applyFollowedChange(
          key,
          Self.followedChange(
            paths: paths, overflow: overflow, gitDirectory: own, commonDirectory: directory))
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

  /// A followed repository's working status: its row's work item's, else its own root's.
  nonisolated static func readWorkingStatus(
    _ resolver: WorkroomStatusResolver, item: StatusWorkItem?, path: String
  ) async -> WorkroomStatus {
    if let item { return await resolver.working.resolve(item: item) }
    return await resolver.working.resolveLocal(path: path)
  }

  /// Something changed under a followed repository: re-read its local status (a save fires no `gh`
  /// call, as for the selected workroom), and tell the windows following it. `overflow` means the
  /// paths are incomplete, so it counts as a change to the git directory too. A moved ref (a
  /// `git switch`, a commit, a push or fetch) asks GitHub again too, after the probe's debounce:
  /// the branch's pull request and CI may be another's now (review of #807, finding 2).
  func handleFollowedRepositoryChange(_ root: String, paths: [String], overflow: Bool) {
    if !overflow, !paths.isEmpty, paths.allSatisfy(AppStore.isJJInternalPath) { return }
    applyFollowedChange(root, Self.followedChange(paths: paths, overflow: overflow))
  }

  /// Act on what a delivery asks of `key`. The local lane and the full probe share one read
  /// (`followedRead`), so a moved ref reads the status once (#812 perf review, I3). A later batch
  /// of the same commit (only local branches moved) leaves a GitHub round in flight to finish
  /// rather than cancel it and ask again; a second commit landing mid-round keeps that round's
  /// answer until the next ref change or the CI TTL.
  func applyFollowedChange(_ key: String, _ change: FollowedRepositoryChange) {
    guard var hold = followedRepositories[key],
      change.readsStatus || change.asksGitHub || change.metadata
    else { return }
    if hold.isLingering {
      hold.staleLocal = hold.staleLocal || change.readsStatus
      hold.staleGitHub = hold.staleGitHub || change.asksGitHub
      followedRepositories[key] = hold
      return
    }
    let demand = takeFollowedReadDemand(key)
    if change.readsStatus { refreshFollowedStatus(key, gitHub: false, demand: demand) }
    if change.asksGitHub, !(change.movesOnlyLocalBranches && hold.askingGitHub) {
      refreshFollowedStatus(key, gitHub: true, debounced: true, demand: demand)
    }
    for window in statusWindows {
      window.followedRepositoryDidChange(root: key, metadata: change.metadata)
    }
  }

  /// What a delivery from a followed repository's tree watch asks (#812 perf review, I6): a file
  /// in the tree or the index re-reads the status only; HEAD, a ref, `packed-refs` or
  /// `FETCH_HEAD` also asks GitHub and re-resolves the folder, as does a `.git` appearing or
  /// going; an object, a reflog or a lock file asks nothing. Incomplete paths ask everything.
  nonisolated static func followedChange(paths: [String], overflow: Bool)
    -> FollowedRepositoryChange
  {
    guard !overflow, !paths.isEmpty else { return .everything }
    var change = FollowedRepositoryChange()
    for path in paths {
      let parts = path.split(separator: "/")
      guard let git = parts.lastIndex(of: ".git") else {
        change.add(.status)
        continue
      }
      change.add(gitDirectoryPathKind(parts[(git + 1)...]))
    }
    return change
  }

  /// What a delivery from a linked worktree's watch on its repository's git directory asks
  /// (#812 perf review, I5): its own HEAD, `FETCH_HEAD` and index under `gitDirectory`
  /// (`worktrees/<name>`), and the shared refs and `packed-refs`. Everything else there is the
  /// main checkout's or a sibling worktree's, or objects, and asks nothing.
  nonisolated static func followedChange(
    paths: [String], overflow: Bool, gitDirectory: String, commonDirectory: String
  ) -> FollowedRepositoryChange {
    guard !overflow, !paths.isEmpty else { return .everything }
    var change = FollowedRepositoryChange()
    for path in paths {
      if path == gitDirectory || path == commonDirectory {
        change.add(.gitEntry)
      } else if gitDirectory == commonDirectory, path.hasPrefix(gitDirectory + "/") {
        // A submodule's or a `--separate-git-dir` repository's: its own, refs and all.
        let rest = path.dropFirst(gitDirectory.count + 1).split(separator: "/")
        change.add(gitDirectoryPathKind(rest[...]))
      } else if path.hasPrefix(gitDirectory + "/") {
        let rest = path.dropFirst(gitDirectory.count + 1).split(separator: "/")
        let kind = gitDirectoryPathKind(rest[...])
        change.add(["HEAD", "FETCH_HEAD", "index"].contains(rest.first) ? kind : .ignored)
      } else if path.hasPrefix(commonDirectory + "/") {
        let rest = path.dropFirst(commonDirectory.count + 1).split(separator: "/")
        let kind = gitDirectoryPathKind(rest[...])
        change.add(["refs", "packed-refs"].contains(rest.first) ? kind : .ignored)
      } else {
        // Spelled apart from what git named: rather than go deaf, it counts as everything.
        return .everything
      }
    }
    return change
  }

  /// What a path inside a git directory is, given its components below it.
  nonisolated private static func gitDirectoryPathKind(
    _ rest: ArraySlice<Substring>
  ) -> FollowedRepositoryChange.PathKind {
    guard let first = rest.first else { return .gitEntry }
    if rest.last?.hasSuffix(".lock") == true { return .ignored }
    switch first {
    case "refs": return rest.dropFirst().first == "heads" ? .localBranch : .ref
    case "HEAD", "packed-refs", "FETCH_HEAD": return .ref
    case "index": return .status
    // Objects, reflogs, a sibling worktree's own directory, and what a commit or gc leaves.
    case "objects", "logs", "worktrees", "COMMIT_EDITMSG", "ORIG_HEAD", "gc.log", "gc.pid",
      "hooks", "description":
      return .ignored
    // Anything else (config, info/exclude, a merge's state) may change what status reports.
    default: return .status
    }
  }

  /// Re-read a followed repository's local status and, with `gitHub`, its CI and pull request.
  /// Cancel-and-replace within its lane (local-only, or full), so the latest change wins; a result
  /// for a repository no window follows any more is dropped. `debounced` waits
  /// `followedProbeDebounce` first, so a burst (or a repository passed by) forks nothing.
  ///
  /// The status read itself is single-flight per repository (`followedRead`): cancelling a probe
  /// abandons its wait, never the read, which the daemon can't cancel. `demand` is the read it
  /// needs, taken by the caller when two lanes share one (`applyFollowedChange`), else here.
  /// In an unfollow's grace it runs nothing, and marks the repository for a re-follow to read.
  ///
  /// Returns the probe it started, nil when it started none, for a caller that waits on the read.
  @discardableResult
  func refreshFollowedStatus(
    _ root: String, gitHub: Bool, debounced: Bool = false, demand: Int? = nil
  ) -> Task<Void, Never>? {
    let key = root
    // Probed even under seeded statuses: a followed folder is a real repository (the UI-test
    // fixture's are throwaway ones its shell makes), where a seeded row's path is not one.
    guard var hold = followedRepositories[key] else { return nil }
    if hold.isLingering {
      if gitHub { hold.staleGitHub = true } else { hold.staleLocal = true }
      followedRepositories[key] = hold
      return nil
    }
    let registered = registeredSidebarID(forCanonicalRoot: key)
    // A registered row keeps its seeded status, as its own lanes leave it.
    if registered != nil, !probesRepositories { return nil }
    let item = registered.flatMap(selectedStatusWorkItem(for:))
    if let registered, isCreating(registered) { return nil }
    // A followed repository's own commit keeps its read lanes off it too (#808): a `git status`
    // mid-commit contends on `index.lock`, as for a workroom.
    if isCommittingProject(item?.sharedLocation ?? followedSharedLocation(key)) { return nil }
    let debounce = debounced ? followedProbeDebounce : 0
    let demand = demand ?? takeFollowedReadDemand(key)
    let token = UUID()
    let task = Task { [weak self] in
      defer { self?.followedProbeEnded(key, token: token) }
      if debounce > 0 {
        try? await Task.sleep(for: .seconds(debounce))
        if Task.isCancelled { return }
      }
      guard
        let fresh = await self?.followedRead(
          key, demand: demand, item: item, registered: registered)
      else { return }
      // Dropped once the index has moved the root to another source (`rerouteFollowed`).
      guard let self, !Task.isCancelled, self.followedRepositories[key] != nil,
        self.registeredSidebarID(forCanonicalRoot: key) == registered
      else { return }
      self.mergeFollowedStatus(fresh, root: key, registered: registered)
      guard gitHub, fresh.failure == nil, item?.permitsGitHubAccess ?? true else { return }
      if self.followedRepositories[key]?.probeToken == token {
        self.followedRepositories[key]?.askingGitHub = true
      }
      // Seeded statuses have no `gh` behind them (`refreshGitHubCLI` no-ops), so a followed
      // repository there never reaches GitHub: it settles as having no pull request.
      guard self.probesRepositories else {
        return self.applyFollowedGitHub(.pullRequest(.absent), root: key, registered: registered)
      }
      let resolved: RepositoryLocation? =
        if let item {
          try? await item.resolvedLocation()
        } else {
          await GitRepositoryProbe.localLocation(key)
        }
      guard let location = resolved else { return }
      await self.probeGitHub(
        location: location, branch: fresh.branchForCI, settlesUnreachable: true,
        isCurrent: { [weak self] in
          guard let self, !Task.isCancelled else { return false }
          return self.followedRepositories[key] != nil
            && self.registeredSidebarID(forCanonicalRoot: key) == registered
        },
        apply: { [weak self] update in
          self?.applyFollowedGitHub(update, root: key, registered: registered)
        })
    }
    if gitHub {
      hold.probe?.cancel()
      (hold.probe, hold.probeToken, hold.askingGitHub) = (task, token, false)
    } else {
      hold.localProbe?.cancel()
      (hold.localProbe, hold.localProbeToken) = (task, token)
    }
    followedRepositories[key] = hold
    return task
  }

  /// The probe `token` ended, finished or cancelled.
  private func followedProbeEnded(_ key: String, token: UUID) {
    guard var hold = followedRepositories[key] else { return }
    if hold.probeToken == token { (hold.probeToken, hold.askingGitHub) = (nil, false) }
    if hold.localProbeToken == token { hold.localProbeToken = nil }
    followedRepositories[key] = hold
  }

  /// Take the next demand for a fresh read of `key`'s status.
  func takeFollowedReadDemand(_ key: String) -> Int {
    followedReads[key, default: FollowedStatusReads()].demand += 1
    return followedReads[key]?.demand ?? 0
  }

  /// `key`'s status as read at or after `demand` was taken, for the row `registered` (or none):
  /// the last read's when it started after that, else the one in flight's when it did, else a new
  /// one, started only once no other is in flight. A probe cancelled while it waits starts none,
  /// so a burst of changes during a read costs one follow-up read (#812 perf review, I4).
  private func followedRead(
    _ key: String, demand: Int, item: StatusWorkItem?, registered: SidebarID?
  ) async -> WorkroomStatus? {
    while true {
      let reads = followedReads[key] ?? FollowedStatusReads()
      if let last = reads.last, last.demand >= demand, last.registered == registered {
        return last.status
      }
      if let running = reads.inFlight {
        await running.task.value
        continue
      }
      guard !Task.isCancelled, followedRepositories[key] != nil else { return nil }
      let (resolver, read) = (statusResolver, readFollowedWorkingStatus)
      let serves = max(reads.demand, demand)
      let task = Task { [weak self] in
        let status = await read(resolver, item, key)
        self?.landFollowedRead(key, status, demand: serves, registered: registered)
      }
      followedReads[key, default: FollowedStatusReads()].inFlight = (task, serves, registered)
      await task.value
    }
  }

  private func landFollowedRead(
    _ key: String, _ status: WorkroomStatus, demand: Int, registered: SidebarID?
  ) {
    guard followedRepositories[key] != nil else {
      followedReads[key] = nil
      return
    }
    var reads = followedReads[key] ?? FollowedStatusReads()
    reads.inFlight = nil
    reads.last = (status, demand, registered)
    followedReads[key] = reads
  }

  /// Wait for every followed repository's probe and read in flight. For tests.
  func followedStatusSettled() async {
    // A rebuild landing re-routes, and re-probes, what it moves.
    await registeredIndexSettled()
    while true {
      let probes = followedRepositories.values.flatMap { hold in
        [
          hold.probeToken == nil ? nil : hold.probe,
          hold.localProbeToken == nil ? nil : hold.localProbe,
        ]
        .compactMap { $0 }
      }
      let reads = followedReads.values.compactMap { $0.inFlight?.task }
      guard !probes.isEmpty || !reads.isEmpty else { return }
      for task in probes + reads { await task.value }
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
