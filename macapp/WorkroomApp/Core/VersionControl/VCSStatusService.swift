import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS

/// Every workroom's VCS and CI status (issue #24), one for the whole app: the status every window
/// shows, the sweep that refreshes it, `gh`'s availability, and the commits and writes in flight
/// against each project, which every window's read lanes stand clear of.
///
/// Best-effort / "last checked", NOT real-time: statuses refresh on load, on app focus (via reload),
/// on selection (debounced), and never via a file watcher in Phase 1. The fan-out across all
/// workrooms is bounded (so 50 workrooms don't fork 50 git + 50 gh processes at once); CI is a
/// second, slower stage that never blocks the dirty dot, and is gated by a much longer TTL than the
/// local git probe. Several lanes (this sweep, and each window's `scheduleSelectedStatusRefresh` and
/// `handleWorkroomFileChange` in `AppStore+WorkroomStatus`) can all read the same project
/// concurrently, and nothing orders their RESULTS — a slow probe still lands after a faster one that
/// read the tree later — so `WorkingStatusResolver.resolve(location:)` stamps each read's completion
/// and `mergeLocalStatus` drops a result stamped earlier than the one already recorded.
///
/// The probes that follow a window's selection stay with that window. Each window registers here
/// (`register`) so that what it caches from a status, the toolbar's branch name and an open diff
/// tab's change kind, is settled by every merge, whichever lane made it.
///
/// Production builds every window's store with `.shared`; tests build an isolated `AppStore()` with
/// its own, over its own `ProjectStore`.
@MainActor
@Observable
// `ObservableObject` only so views can take it as an `@EnvironmentObject`, as they take the store;
// Observation tracks the reads.
final class VCSStatusService: ObservableObject {
  static let shared = VCSStatusService(projectStore: .shared)

  fileprivate static let localStatusTTL: TimeInterval = 15  // git dirty/changed-files
  fileprivate static let ciStatusTTL = GitHubCIResultCache.defaultTTL  // gh CI (network)
  // The `gh auth status` TTL lives in `GitHubAuthCache`, which owns that probe's freshness outright.
  static let localConcurrency = 5
  static let ciConcurrency = 2

  /// The projects whose status this is.
  @ObservationIgnored let projectStore: ProjectStore
  /// The creates and deletes of those projects' workrooms, whose creates in flight the probes stand
  /// clear of (`isCreating`). Set by the lifecycle made over this status; a window's store made with
  /// this status takes that lifecycle too.
  @ObservationIgnored weak var lifecycle: WorkroomLifecycle?
  /// The services' seeded statuses (the UI-test fixture's), read once: the process chooses its
  /// services before any window exists.
  @ObservationIgnored private let seededStatuses: (@MainActor () -> AppServices.SeededStatuses)?

  init(projectStore: ProjectStore) {
    self.projectStore = projectStore
    seededStatuses = AppServices.current.seededStatuses
    let ciResultCache = GitHubCIResultCache()
    self.ciResultCache = ciResultCache
    statusResolver = WorkroomStatusResolver(ciCache: ciResultCache)
  }

  // MARK: Status

  /// Per-project resolved root branch labels, hydrated asynchronously after each load (see
  /// `AppStore.resolveBranches`). Absent ⇒ the root row shows a dim "root" until resolved.
  ///
  /// This and the other status collections are computed over private stored ones so that a write
  /// which changes nothing notifies no one: `@Observable` skips an equal whole-value assignment, but
  /// an in-place write (`workroomStatuses[sid] = s`, `insert(_:)`) to a stored property always
  /// notifies. The setter makes every write the first kind, as `AppStore`'s forwarding proxies once
  /// did; a status sweep that finds nothing new must not redraw the sidebar.
  var rootRefs: [Project.ID: RootRef] {
    get { storedRootRefs }
    set { storedRootRefs = newValue }
  }
  private var storedRootRefs: [Project.ID: RootRef] = [:]

  /// Per-workroom (and per-root) VCS + CI status driving the ambient badges and the Changes panel
  /// (issue #24), keyed by `SidebarID`. Resolved app-side, best-effort/"last checked". Shared so two
  /// windows showing the same workroom report a consistent badge and don't double the probes.
  /// Deliberately NOT persisted. Hydrated after each load, on selection, and on focus.
  var workroomStatuses: [SidebarID: WorkroomStatus] {
    get { storedWorkroomStatuses }
    set { storedWorkroomStatuses = newValue }
  }
  private var storedWorkroomStatuses: [SidebarID: WorkroomStatus] = [:]

  /// Whether the GitHub CLI is usable for the PR/CI probes (machine-global). Optimistic default so
  /// no warning flashes before the first check; refreshed by `refreshGitHubCLI`. Drives the Pull
  /// Request section's warning and gates the `gh` probes when not available.
  var githubCLIStatus: GitHubCLIStatus = .available

  /// Owns the `gh auth status` probe: its freshness clock AND its single-flight, so N windows share
  /// one `gh` and the staleness check can't interleave with the write the way a bare timestamp on
  /// this class did. `githubCLIStatus` above is the SwiftUI-observable mirror of what it decided.
  ///
  /// A `var` purely so tests can swap in an instance with millisecond TTLs; production never
  /// reassigns it.
  var ghAuthCache = GitHubAuthCache()
  /// Commit-keyed CI facts shared by windows, with the same five-minute lifetime as the sweep.
  let ciResultCache: GitHubCIResultCache

  /// Owns the `git --version` probe: its freshness clock AND its single-flight, so N windows share
  /// one probe rather than racing two. `vcsToolReport` on `AppStore` mirrors what
  /// this decided (per-window, since `apply(projects)` runs per-window even though the underlying
  /// facts are machine-wide).
  ///
  /// A `var` for the same reason `ghAuthCache` is: tests swap in an instance with millisecond TTLs;
  /// production never reassigns it.
  var vcsToolVersionCache = VCSToolVersionCache()

  /// Sidebar rows with a commit in flight, for the per-row button state.
  ///
  /// App-wide for the reason `creatingWorkrooms` is shared: `AppStore` is per WINDOW, but
  /// `RepositoryWriteGate` and the `index.lock` contention it exists to prevent are per PROCESS. Held
  /// on the window's own store, a second window's 15s sweep, FSEvents lane and Refresh button all saw
  /// an empty set and kept probing a repo mid-write.
  var committingTargets: Set<SidebarID> {
    get { storedCommittingTargets }
    set { storedCommittingTargets = newValue }
  }
  private var storedCommittingTargets: Set<SidebarID> = []

  /// How many commits are in flight against each project root, which is what the read lanes actually
  /// have to stand clear of.
  ///
  /// Keyed by project root, not by row: the gate serializes on the project root, and a git worktree's
  /// index and refs live in the MAIN repo — so a commit in workroom A contends with a status probe of
  /// workroom B of the same project, which a per-row check waved straight through. Counted rather than
  /// a `Set` because the app's premise is N parallel workrooms, so two of one project can legitimately
  /// commit at once and the first to finish must not clear the other's suppression.
  var committingProjectRoots: [RepositoryLocation: Int] {
    get { storedCommittingProjectRoots }
    set { storedCommittingProjectRoots = newValue }
  }
  private var storedCommittingProjectRoots: [RepositoryLocation: Int] = [:]

  /// How many writes (commit, fetch, push, or pull) are in flight against each project root,
  /// across every window. Checked by the write ACTIONS THEMSELVES before starting — not just
  /// by read lanes — so a second write on the same project root is refused outright rather than
  /// queuing into `RepositoryWriteGate` and possibly racing a live one past its wedge-detection
  /// ceiling (VCS-foundation eng-review: the gate's `maxChainWait` self-heal is far shorter than
  /// fetch/pull's own timeouts, so two windows could otherwise both queue a write and run them
  /// concurrently on the shared `.git`). Distinct from `committingProjectRoots`, which exists for
  /// a different reason (suppressing READ lanes during a commit specifically) and keeps its own
  /// narrower role unchanged; this counter is the umbrella that all four write kinds share.
  var writingProjectRoots: [RepositoryLocation: Int] {
    get { storedWritingProjectRoots }
    set { storedWritingProjectRoots = newValue }
  }
  private var storedWritingProjectRoots: [RepositoryLocation: Int] = [:]

  /// The resolvers every lane reads through. `var` (not `let`) so tests can inject one with a mock
  /// command runner.
  var statusResolver: WorkroomStatusResolver
  /// The in-flight sweep, cancelled and replaced by the next one so a slow sweep can't write stale
  /// values over a newer one.
  var statusSweepTask: Task<Void, Never>?

  // MARK: Windows

  private struct Window {
    weak var owner: AnyObject?
    let didMerge: @MainActor (SidebarID, WorkroomStatus) -> Void
  }

  /// The windows that cache what a local status says, in the order they registered.
  @ObservationIgnored private var windows: [Window] = []

  /// Call `didMerge` with every local status merged while `owner` lives. Idempotent per owner.
  func register(
    _ owner: AnyObject, didMerge: @escaping @MainActor (SidebarID, WorkroomStatus) -> Void
  ) {
    windows.removeAll { $0.owner == nil || $0.owner === owner }
    windows.append(Window(owner: owner, didMerge: didMerge))
  }

  // MARK: Work items

  struct StatusWorkItem: Sendable, Equatable {
    let sid: SidebarID
    let path: String
    /// The project root. Equals `path` for the root row; for a workroom it's the parent project's
    /// path — the shared repository its writes are keyed by.
    let projectRoot: String
    let location: RepositoryLocation?

    init(
      sid: SidebarID, path: String, projectRoot: String,
      location: RepositoryLocation? = nil
    ) {
      self.sid = sid
      self.path = path
      self.projectRoot = projectRoot
      self.location = location ?? RepositoryRouter.shared.localLocation(for: path)
    }

    func resolvedLocation() async throws -> RepositoryLocation {
      if let location { return location }
      return try await RepositoryLocation.local(path)
    }

    var permitsLocalAccess: Bool { location == nil || location?.host == .local }
    /// Whether GitHub status may be read for, or written through, this item: a local one, or a
    /// remote one registered with a GitHub identity (`gh` stays on this Mac — only the repository's
    /// NAME comes from the registration). A remote item without one is still refused.
    var permitsGitHubAccess: Bool {
      permitsLocalAccess
        || location.flatMap { RepositoryRouter.shared.entry(for: $0)?.github } != nil
    }
    var sharedLocation: RepositoryLocation? {
      location.flatMap { RepositoryRouter.shared.entry(for: $0)?.sharedLocation }
    }
  }

  /// Every root + workroom as a status work item.
  func statusWorkItems() -> [StatusWorkItem] {
    var items: [StatusWorkItem] = []
    for p in projectStore.projects {
      items.append(
        StatusWorkItem(sid: .root(project: p.id), path: p.path, projectRoot: p.path))
      // A remote workroom's path is not a path on this Mac: a reachable one is probed on its host,
      // and any other has nothing to probe.
      for w in p.workrooms where w.isRemote {
        if let item = remoteStatusWorkItem(w, in: p) { items.append(item) }
      }
      for w in p.workrooms where !w.isRemote {
        items.append(
          StatusWorkItem(
            sid: .workroom(project: p.id, name: w.name), path: w.path, projectRoot: p.path))
      }
    }
    return items
  }

  /// `sid`'s work item, or nil when it names no live root or workroom (or a remote one this app
  /// can't reach). The commit sheet needs a row's path to open against it.
  func selectedStatusWorkItem(for sid: SidebarID) -> StatusWorkItem? {
    switch sid {
    case .root(let path):
      guard let p = projectStore.projects.first(where: { $0.id == path }) else { return nil }
      return StatusWorkItem(sid: sid, path: p.path, projectRoot: p.path)
    case .workroom(let path, let name):
      guard let p = projectStore.projects.first(where: { $0.id == path }),
        let w = p.workrooms.first(where: { $0.id == name })
      else { return nil }
      // A remote workroom's item is on its host. One this app can't reach has none, which also
      // makes `targetExists` false, so commits, PR actions and late status merges skip it.
      if w.isRemote { return remoteStatusWorkItem(w, in: p) }
      return StatusWorkItem(sid: sid, path: w.path, projectRoot: p.path)
    case .project, .creation:
      return nil
    }
  }

  /// Whether `sid` still maps to a live root/workroom. A status sweep captures its work-list up
  /// front, so a workroom can be deleted before its (slow) probe lands — without this guard the
  /// merge would write a ghost entry into `workroomStatuses` for a target that no longer exists.
  func targetExists(_ sid: SidebarID) -> Bool {
    selectedStatusWorkItem(for: sid) != nil
  }

  /// A reachable remote workroom's item (#253): read via its daemon at its location on its host,
  /// and its own shared root there (`RemoteWorkrooms.registrations`).
  private func remoteStatusWorkItem(_ w: Workroom, in p: Project) -> StatusWorkItem? {
    guard let host = w.reachableHost,
      let location = try? RepositoryLocation.remote(host: host, path: w.path)
    else { return nil }
    return StatusWorkItem(
      sid: .workroom(project: p.id, name: w.name), path: w.path, projectRoot: w.path,
      location: location)
  }

  // MARK: The sweep

  /// Sweep every workroom's status. Cancels any in-flight sweep so a slow one can't write stale
  /// values over a newer one. `force` ignores the TTLs (e.g. a manual refresh). Two stages:
  /// fast local git first, then the slow `gh` CI pass — so the dirty dots land immediately.
  func refreshWorkroomStatuses(force: Bool = false) {
    // Seeded statuses never shell out to git/gh — keep them (and let the manual Refresh button
    // re-apply them rather than wipe them to "unknown").
    if !probesRepositories {
      seedStatuses()
      return
    }
    statusSweepTask?.cancel()
    let resolver = statusResolver
    let now = Date()
    let localTTL = Self.localStatusTTL
    let ciTTL = Self.ciStatusTTL
    let localItems = statusWorkItems().filter { item in
      // Never sweep a workroom whose setup is still writing its worktree (issue: create-time FSEvents
      // storm) — even on `force`. Its status is refreshed once, post-setup, by `createWorkroom`.
      // Covers every window's create, since `creatingWorkrooms` is shared.
      if isCreating(item.sid) { return false }
      // Nor one whose PROJECT has a commit in flight — see `isCommittingProject`. Also honoured on
      // `force`, because a manual Refresh during a long hook races the write just as readily as the
      // timer does.
      if isCommittingProject(item.sharedLocation) { return false }
      guard !force else { return true }
      guard let checked = workroomStatuses[item.sid]?.lastChecked else { return true }
      return now.timeIntervalSince(checked) >= localTTL
    }
    // `.utility` so this background sweep yields CPU to a mounting terminal surface + its login shell.
    statusSweepTask = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      let interval = LaunchSignposts.begin("Workroom status sweep")
      defer { LaunchSignposts.end("Workroom status sweep", interval) }
      await self.runLocalSweep(localItems, resolver: resolver, cap: Self.localConcurrency)
      if Task.isCancelled { return }
      // Guard the network stage: if `gh` isn't installed/authenticated, skip the whole CI sweep
      // rather than spawn a `gh` per dirty workroom only to have each fail.
      await self.refreshGitHubCLI(resolver: resolver, force: force)
      if Task.isCancelled { return }
      guard self.githubCLIStatus == .available else { return }
      let ciItems = self.statusWorkItems().filter { item in
        guard let s = self.workroomStatuses[item.sid], s.dirty != nil, s.failure == nil
        else {
          return false
        }
        guard !force else { return true }
        guard let c = s.ciCheckedAt else { return true }
        return now.timeIntervalSince(c) >= ciTTL
      }
      if Task.isCancelled { return }
      await self.runCISweep(ciItems, resolver: resolver, cap: Self.ciConcurrency, force: force)
    }
  }

  /// Mirror the `gh` verdict onto the observable service so the warning + probe guards reflect
  /// whether `gh` is usable. Freshness, single-flight and the `force` contract all belong to
  /// `GitHubAuthCache`; this function only decides whether to paint what it says. No-ops in fixture
  /// mode (the fixture seeds the status directly).
  ///
  /// **This is the one status mutation that happens INSIDE an awaited function**, so the callers' own
  /// `Task.isCancelled` checks run too late to protect it — the guard has to live here. It was
  /// missing, and that was the false, sticky "GitHub CLI not signed in": a superseded sweep or a
  /// workroom switched mid-probe SIGKILLs the `gh` child, `StatusCommandRunner`'s non-throwing
  /// continuation still hands back `exitCode: 9` with empty stdout, and the classifier read that as a
  /// logout. Publishing it also stamped the freshness clock, so the staleness gate turned every lane
  /// that would have healed the value into an early return for a full minute — the wrong answer
  /// suppressing its own repair, escapable only via the Refresh button's `force`.
  ///
  /// The tempting instinct — "gh's auth state is machine-global, so record it even from a cancelled
  /// task" — is wrong: a cancelled probe holds no fact at all. A `nil` here means the same thing (the
  /// probe told us nothing and there was no prior verdict), so leave the mirror alone in both cases.
  func refreshGitHubCLI(resolver: WorkroomStatusResolver, force: Bool = false) async {
    if !probesRepositories { return }
    guard let status = await ghAuthCache.status(force: force, resolver: resolver.gitHub)
    else { return }
    if Task.isCancelled { return }
    githubCLIStatus = status
  }

  /// Bounded fan-out: at most `cap` local probes in flight; refill as each completes.
  private func runLocalSweep(_ items: [StatusWorkItem], resolver: WorkroomStatusResolver, cap: Int)
    async
  {
    guard !items.isEmpty else { return }
    let working = resolver.working
    await withTaskGroup(of: (StatusWorkItem, WorkroomStatus).self) { group in
      var idx = 0
      let initial = min(cap, items.count)
      while idx < initial {
        let item = items[idx]
        idx += 1
        group.addTask {
          (
            item,
            await working.resolve(item: item)
          )
        }
      }
      while let (item, fresh) = await group.next() {
        if Task.isCancelled { break }
        if selectedStatusWorkItem(for: item.sid) == item { mergeLocalStatus(fresh, into: item.sid) }
        if idx < items.count {
          let item = items[idx]
          idx += 1
          group.addTask {
            (
              item,
              await working.resolve(item: item)
            )
          }
        }
      }
    }
  }

  private func runCISweep(
    _ items: [StatusWorkItem], resolver: WorkroomStatusResolver, cap: Int, force: Bool
  )
    async
  {
    var services: [(StatusWorkItem, RepositoryGitHub)] = []
    // One repository lookup per PROJECT, shared by all its workrooms — and the whole answer, not just
    // a found repo: a `keepPrior` blip must reach every workroom's CI probe or the project's badges
    // blank. (Each workroom has its own `RepositoryGitHub`, so its per-instance lookup cannot span
    // them.)
    var repositories: [RepositoryLocation: GitHubRepositoryResolution] = [:]
    for item in items where item.permitsGitHubAccess {
      if Task.isCancelled { return }
      do {
        let location: RepositoryLocation
        if let supplied = item.location {
          location = supplied
        } else {
          location = try await RepositoryLocation.local(item.path)
        }
        let service = try await RepositoryRouter.shared.gitHub(for: location, resolver: resolver)
        let key = service.context.sharedLocation ?? service.context.location
        if repositories[key] == nil { repositories[key] = await service.repository() }
        services.append((item, service))
      } catch { continue }
    }
    let branches = workroomStatuses.mapValues(\.branchForCI)
    await withTaskGroup(of: (StatusWorkItem, CIStatusSnapshot).self) { group in
      var index = 0
      func enqueue() {
        guard index < services.count else { return }
        let (item, service) = services[index]
        index += 1
        let branch = branches[item.sid] ?? nil
        let key = service.context.sharedLocation ?? service.context.location
        let repository = repositories[key]
        group.addTask {
          (item, await service.ciSnapshot(branch: branch, repository: repository, force: force))
        }
      }
      for _ in 0..<min(cap, services.count) { enqueue() }
      while let (item, result) = await group.next() {
        if Task.isCancelled { break }
        if selectedStatusWorkItem(for: item.sid) == item {
          applyCIStatus(result.resolution, to: item.sid, checkedAt: result.checkedAt)
        }
        enqueue()
      }
    }
  }

  // MARK: Seeded statuses

  /// Whether statuses, branches and history come from probing the repositories, rather than the
  /// services' seeded statuses (the UI-test fixture's, whose paths are not repositories).
  var probesRepositories: Bool { seededStatuses == nil }

  /// Put the services' seeded statuses on the first project's root and first workroom, so the
  /// Changes inspector is exercisable hermetically — the fixture paths aren't real repos, so the
  /// live probe would only ever report "unknown". No-ops when the services probe instead.
  func seedStatuses() {
    guard let seededStatuses, let project = projectStore.projects.first else {
      return
    }
    let seed = seededStatuses()
    workroomStatuses[.root(project: project.path)] = seed.root
    if let workroom = project.workrooms.first {
      workroomStatuses[.workroom(project: project.path, name: workroom.name)] = seed.workroom
    }
    // Seed here — not only at load — because this runs again on the manual Refresh button, and
    // `refreshGitHubCLI` no-ops when statuses are seeded, so a re-seed is the only thing that can
    // restate the value. Left alone when there is none, so the optimistic `.available` default
    // stands and every existing fixture test still sees no warning.
    if let gitHubCLI = seed.gitHubCLI { githubCLIStatus = gitHubCLI }
  }

  // MARK: Merging results

  /// The worst-status child of a project (root + workrooms), for the collapsed project row's
  /// aggregate badge. nil when nothing needs attention (all clean / unresolved).
  func aggregateStatus(forProject projectPath: String) -> WorkroomStatus? {
    guard let p = projectStore.projects.first(where: { $0.id == projectPath }) else { return nil }
    var sids: [SidebarID] = [.root(project: p.id)]
    sids += p.workrooms.map { SidebarID.workroom(project: p.id, name: $0.name) }
    let worst = sids.compactMap { workroomStatuses[$0] }
      .max(by: { $0.aggregateWeight < $1.aggregateWeight })
    guard let worst, worst.aggregateWeight > 0 else { return nil }
    return worst
  }

  /// Merge a fresh local result into the stored snapshot, preserving the (separately-resolved)
  /// CI fields so a local refresh never wipes the CI badge.
  /// Ordering comes from `fresh.localReadAt`, which `WorkingStatusResolver.resolve(location:)` stamps
  /// when the read FINISHED. Deliberately not a caller-supplied invocation time: a read can queue for
  /// a while before it observes anything, so invocation time would call a probe older when it
  /// actually saw a later tree. A result with no stamp (a hand-built status in a test)
  /// cannot be ordered, so it merges.
  ///
  /// The five local lanes (this file's sweep, selection refresh, post-commit refresh, file-watcher
  /// refresh, and the post-create probe) cancel-and-replace within themselves but are NOT ordered
  /// against each other, so a slow probe routinely lands after a faster one that read the tree later.
  /// Ordering on merge time cannot fix that — by then both results exist and the timestamps say
  /// nothing about which tree each one saw. So the ordering lives here, on the read: a result whose
  /// read began before the recorded one's is dropped. That is what keeps a stale answer off the dirty
  /// dot no matter which lane wins the race, rather than each lane guarding itself and getting the
  /// comparison subtly wrong.
  func mergeLocalStatus(_ fresh: WorkroomStatus, into sid: SidebarID) {
    guard targetExists(sid) else { return }  // deleted mid-sweep → don't write a ghost entry
    if let readAt = fresh.localReadAt, let prior = workroomStatuses[sid]?.localReadAt,
      prior > readAt
    {
      return
    }
    var s = workroomStatuses[sid] ?? .unresolved
    s.dirty = fresh.dirty
    s.conflicted = fresh.conflicted
    s.changedFiles = fresh.changedFiles
    s.insertions = fresh.insertions
    s.deletions = fresh.deletions
    s.branchForCI = fresh.branchForCI
    s.failure = fresh.failure
    s.localReadAt = fresh.localReadAt
    s.lastChecked = Date()
    workroomStatuses[sid] = s
    // This merge is the freshest evidence anyone has, so each window settles what it caches from a
    // status: the branch name its toolbar published, and the change kind an open diff tab captured.
    for window in windows where window.owner != nil { window.didMerge(sid, s) }
  }

  func applyCIStatus(_ res: CIResolution, to sid: SidebarID, checkedAt: Date) {
    guard var s = workroomStatuses[sid] else { return }
    switch res {
    case .state(let x):
      s.ci = x
      s.ciCheckedAt = checkedAt
    case .absent:
      s.ci = nil
      s.ciCheckedAt = checkedAt
    case .keepPrior:
      // Transient rate-limit / network blip. Stamp `ciCheckedAt` so the TTL throttles re-probes —
      // but ONLY if we've probed before (ciCheckedAt set). On a first-ever probe that blips, leave
      // it nil so the next sweep retries instead of hiding CI for the full TTL on one blip. Coarse
      // but cheap; true exponential backoff is a future refinement.
      if s.ciCheckedAt != nil { s.ciCheckedAt = checkedAt }
    }
    workroomStatuses[sid] = s
  }

  func applyPRStatus(_ res: PRResolution, to sid: SidebarID) {
    guard var s = workroomStatuses[sid] else { return }
    switch res {
    case .info(let pr):
      // Checks are keyed to a PR's identity (issue #75). If the PR changed (different number), the
      // old PR's checks are stale — drop them so they can't render under the new PR until
      // `resolveChecks` refills them. Same number ⇒ keep them (e.g. the raw→enriched re-apply).
      if s.pr?.number != pr.number {
        s.checks = nil
        s.checksCheckedAt = nil
      }
      s.pr = pr
      s.prCheckedAt = Date()
    case .absent:
      // No PR ⇒ `resolveChecks` won't run, so the checks must be cleared here (not only in
      // `applyChecksStatus`) or a disappearing PR would leave its checks rendered.
      s.pr = nil
      s.checks = nil
      s.checksCheckedAt = nil
      s.prCheckedAt = Date()
    case .keepPrior:
      // Transient blip: keep the last good PR. Stamp `prCheckedAt` so the TTL throttles re-probes,
      // but only if we've probed before — a first-ever blip leaves it nil so the next sweep retries.
      if s.prCheckedAt != nil { s.prCheckedAt = Date() }
    }
    workroomStatuses[sid] = s
  }

  /// Apply a PR-checks probe result (issue #75). `.list` (including `[]` for "loaded, no checks")
  /// sets the rows and stamps `checksCheckedAt`. `.absent` (no checks reported / gh error) is *also*
  /// a loaded state — it stamps with an empty list, distinct from the not-loaded `nil`, so the panel
  /// stops falling back to the run-list aggregate. `.keepPrior` (transient blip) keeps the last good
  /// list, stamping only if we've probed before (so a first-ever blip retries next time). The
  /// clear-on-no-PR / clear-on-PR-change paths live in `applyPRStatus` — `resolveChecks` never runs
  /// without a PR.
  func applyChecksStatus(_ res: ChecksResolution, to sid: SidebarID) {
    guard var s = workroomStatuses[sid] else { return }
    switch res {
    case .list(let checks):
      s.checks = checks
      s.checksCheckedAt = Date()
    case .absent:
      s.checks = []
      s.checksCheckedAt = Date()
    case .keepPrior:
      if s.checksCheckedAt != nil { s.checksCheckedAt = Date() }
    }
    workroomStatuses[sid] = s
  }

  // MARK: Creates, commits and writes in flight

  /// Whether `sid` is a workroom whose create/setup is still in flight (issue: create-time FSEvents
  /// storm). While a setup script writes the worktree (e.g. `npm install`), arming the recursive
  /// FSEvents watcher on it or probing its VCS status is pointless churn — the tree isn't settled and
  /// FSEvents floods ~70 callbacks/sec under that load. The lifecycle's `creatingWorkrooms` (set as
  /// setup begins, cleared when it finishes) is the exact signal; this is the single conversion
  /// point from the `SidebarID`-keyed status world to the `TerminalTarget.ID`-keyed
  /// `creatingWorkrooms` set. Roots and projects are never "creating".
  func isCreating(_ sid: SidebarID) -> Bool {
    guard case .workroom(let project, let name) = sid else { return false }
    return lifecycle?.creatingWorkrooms.contains(.workroom(project: project, name: name)) ?? false
  }

  /// Whether a commit is running for this row. Suppresses the same three lanes `isCreating` does, for
  /// a closely-related reason.
  ///
  /// Status probes are reads and never queue behind the write gate, so without this a probe would
  /// run **concurrently with the commit** — contending on `index.lock`. Suppressing the lanes is the
  /// fix.
  ///
  /// It also stops the panel rendering a half-staged tree: `git commit` moves the index and refs as it
  /// goes, and `GitProvider.workingStatus` collapses index and worktree deltas into one row, so a
  /// probe landing mid-commit shows a state that never really existed.
  func isCommitting(_ sid: SidebarID) -> Bool { committingTargets.contains(sid) }

  /// Whether ANY workroom of this project has a commit in flight.
  ///
  /// The question every read lane has to ask, rather than `isCommitting(sid)`: a project's workrooms
  /// share one repository, so a sibling's commit churns the files this workroom's probe reads.
  /// Suppression is what keeps these lanes off a repo mid-write; reads are not gated.
  func isCommittingProject(_ repository: RepositoryLocation?) -> Bool {
    guard let repository else { return false }
    return committingProjectRoots[repository, default: 0] > 0
  }

  func isCommittingProject(_ projectRoot: String) -> Bool {
    guard let location = RepositoryRouter.shared.localLocation(for: projectRoot) else {
      return false
    }
    return committingProjectRoots[location, default: 0] > 0
  }

  /// Whether ANY write (commit, fetch, push, or pull) is in flight against this project root, in
  /// any window. Checked by the write actions themselves BEFORE they start — the
  /// umbrella `isCommittingProject` above never was, and neither was any fetch/push/pull call
  /// site, which is what let two windows each queue a write on the same project and run them
  /// concurrently once `RepositoryWriteGate`'s self-heal ceiling passed. A write that finds this true
  /// refuses outright (surfaced as `.locked(nil)` — "The repository was busy. Try again.") rather
  /// than queuing into the gate and racing the one already running.
  func isWritingProject(_ projectRoot: String) -> Bool {
    guard let location = RepositoryRouter.shared.localLocation(for: projectRoot) else {
      return false
    }
    return isWritingProject(location)
  }

  func isWritingProject(_ repository: RepositoryLocation) -> Bool {
    writingProjectRoots[repository, default: 0] > 0
  }

  /// Mark a write starting against `projectRoot`. Pair with `endWrite(projectRoot:)` — always in a
  /// `defer` or an equivalent unconditional cleanup, mirroring how `committingProjectRoots` is
  /// incremented/decremented around `AppStore.performCommit`'s own write.
  func beginWrite(projectRoot: RepositoryLocation) {
    writingProjectRoots[projectRoot, default: 0] += 1
  }

  /// Mark a write finishing against `projectRoot`. Decremented rather than cleared, matching
  /// `committingProjectRoots`'s own shape: in steady state this should only ever be 0 or 1, since
  /// `isWritingProject` refuses a second write before `beginWrite` is ever called for it — but
  /// decrementing (not clearing) is the robust form if that invariant is ever violated by a future
  /// caller, the same defensive reasoning `committingProjectRoots` already applies.
  ///
  /// Needs no window: `performCommit`'s Task and the `writeDidFinish` closure wired in `AppStore.init`
  /// both hold this service strongly and call it after the `AppStore`/`RemoteStateModel` that started
  /// the write may be gone.
  func endWrite(projectRoot: RepositoryLocation) {
    let remaining = (writingProjectRoots[projectRoot] ?? 1) - 1
    if remaining > 0 {
      writingProjectRoots[projectRoot] = remaining
    } else {
      writingProjectRoots.removeValue(forKey: projectRoot)
    }
  }
}

/// The three resolvers a status sweep and `RepositoryGitHub` use, built over one command runner so a
/// test stands in for git and gh in one place: working status through the router, GitHub through
/// `gh`, and the git probe of a local checkout.
struct WorkroomStatusResolver: Sendable {
  let working: WorkingStatusResolver
  let gitHub: GitHubStatusResolver
  let git: GitRepositoryProbe

  init(
    runner: StatusCommandRunning = StatusCommandRunner(), timeout: TimeInterval = 3,
    ciTimeout: TimeInterval = 10, router: RepositoryRouter = .shared,
    ciCache: GitHubCIResultCache = GitHubCIResultCache()
  ) {
    working = WorkingStatusResolver(timeout: timeout, router: router)
    gitHub = GitHubStatusResolver(runner: runner, ciTimeout: ciTimeout, ciCache: ciCache)
    git = GitRepositoryProbe(runner: runner, timeout: timeout, networkTimeout: ciTimeout)
  }
}
