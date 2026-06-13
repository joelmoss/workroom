import Foundation

/// Workroom VCS + CI status scheduling (issue #24). Split out of `AppStore` (already large) per
/// the `AppStore+WorkroomSplit.swift` convention. Best-effort / "last checked", NOT real-time:
/// statuses refresh on load, on app focus (via reload), on selection (debounced), and never via
/// a file watcher in Phase 1. The fan-out across all workrooms is bounded (so 50 workrooms
/// don't fork 50 git + 50 gh processes at once); CI is a second, slower stage that never blocks
/// the dirty dot, and is gated by a much longer TTL than the local git probe.
extension AppStore {
  fileprivate static let localStatusTTL: TimeInterval = 15  // git/jj dirty/ahead-behind
  fileprivate static let ciStatusTTL: TimeInterval = 300  // gh CI (network)
  fileprivate static let ghStatusTTL: TimeInterval = 60  // `gh auth status` availability check
  fileprivate static let localConcurrency = 5
  fileprivate static let ciConcurrency = 2

  struct StatusWorkItem: Sendable {
    let sid: SidebarID
    let path: String
    let vcs: String
  }

  /// Every root + workroom as a status work item.
  func statusWorkItems() -> [StatusWorkItem] {
    var items: [StatusWorkItem] = []
    for p in projects {
      items.append(StatusWorkItem(sid: .root(project: p.id), path: p.path, vcs: p.vcs))
      for w in p.workrooms {
        items.append(
          StatusWorkItem(sid: .workroom(project: p.id, name: w.name), path: w.path, vcs: w.vcsName))
      }
    }
    return items
  }

  /// Sweep every workroom's status. Cancels any in-flight sweep so a slow one can't write stale
  /// values over a newer one. `force` ignores the TTLs (e.g. a manual refresh). Two stages:
  /// fast local git/jj first, then the slow `gh` CI pass — so the dirty dots land immediately.
  func refreshWorkroomStatuses(force: Bool = false) {
    // Fixture mode never shells out to git/jj/gh — keep the deterministic seeded status (and let the
    // manual Refresh button re-apply it rather than wipe it to "unknown").
    if UITestFixture.isActive {
      seedFixtureStatuses()
      return
    }
    statusSweepTask?.cancel()
    let resolver = statusResolver
    let now = Date()
    let localTTL = Self.localStatusTTL
    let ciTTL = Self.ciStatusTTL
    let localItems = statusWorkItems().filter { item in
      guard !force else { return true }
      guard let checked = workroomStatuses[item.sid]?.lastChecked else { return true }
      return now.timeIntervalSince(checked) >= localTTL
    }
    statusSweepTask = Task { [weak self] in
      guard let self else { return }
      await self.runLocalSweep(localItems, resolver: resolver, cap: Self.localConcurrency)
      if Task.isCancelled { return }
      // Guard the network stage: if `gh` isn't installed/authenticated, skip the whole CI sweep
      // rather than spawn a `gh` per dirty workroom only to have each fail.
      await self.refreshGitHubCLI(resolver: resolver, force: force)
      if Task.isCancelled { return }
      guard self.githubCLIStatus == .available else { return }
      let ciItems = self.statusWorkItems().filter { item in
        guard let s = self.workroomStatuses[item.sid], s.dirty != nil, s.failure == nil else {
          return false
        }
        guard !force else { return true }
        guard let c = s.ciCheckedAt else { return true }
        return now.timeIntervalSince(c) >= ciTTL
      }
      if Task.isCancelled { return }
      await self.runCISweep(ciItems, resolver: resolver, cap: Self.ciConcurrency)
    }
  }

  /// Refresh `githubCLIStatus` if stale (own short TTL), so the warning + probe guards reflect
  /// whether `gh` is usable. No-ops in fixture mode (the fixture seeds `.available`).
  func refreshGitHubCLI(resolver: WorkroomStatusResolver, force: Bool = false) async {
    if UITestFixture.isActive { return }
    if !force, let at = ghStatusCheckedAt,
      Date().timeIntervalSince(at) < Self.ghStatusTTL
    {
      return
    }
    let status = await resolver.resolveGitHubCLI()
    githubCLIStatus = status
    ghStatusCheckedAt = Date()
  }

  /// Freshen just the selected workroom (local + CI, forced), debounced so arrow-key cycling
  /// through rows doesn't fork a probe per row. Cancels the prior pending refresh.
  func scheduleSelectedStatusRefresh() {
    selectionStatusTask?.cancel()
    // Fixture mode keeps the deterministic seeded status — selecting a target must not fork a real
    // probe that would overwrite it.
    if UITestFixture.isActive { return }
    guard let sid = selectedTargetID, let item = selectedStatusWorkItem(for: sid) else { return }
    let resolver = statusResolver
    selectionStatusTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce
      if Task.isCancelled { return }
      guard let self else { return }
      let fresh = await resolver.resolveLocal(path: item.path, vcs: item.vcs)
      if Task.isCancelled { return }
      self.mergeLocalStatus(fresh, into: sid)
      // Skip the network CI/PR probes when `gh` isn't usable (the inspector shows a warning instead).
      await self.refreshGitHubCLI(resolver: resolver)
      if Task.isCancelled { return }
      guard self.githubCLIStatus == .available else { return }
      let ci = await resolver.resolveCI(path: item.path, branch: fresh.branchForCI)
      if Task.isCancelled { return }
      self.applyCIStatus(ci, to: sid)
      let pr = await resolver.resolvePR(path: item.path, branch: fresh.branchForCI)
      if Task.isCancelled { return }
      self.applyPRStatus(pr, to: sid)
    }
  }

  /// The worst-status child of a project (root + workrooms), for the collapsed project row's
  /// aggregate badge. nil when nothing needs attention (all clean / unresolved).
  func aggregateStatus(forProject projectPath: String) -> WorkroomStatus? {
    guard let p = projects.first(where: { $0.id == projectPath }) else { return nil }
    var sids: [SidebarID] = [.root(project: p.id)]
    sids += p.workrooms.map { SidebarID.workroom(project: p.id, name: $0.name) }
    let worst = sids.compactMap { workroomStatuses[$0] }
      .max(by: { $0.aggregateWeight < $1.aggregateWeight })
    guard let worst, worst.aggregateWeight > 0 else { return nil }
    return worst
  }

  /// Seed deterministic VCS status for the UI-test fixture targets so the Changes inspector is
  /// exercisable hermetically — the fixture paths aren't real repos, so the live probe would only
  /// ever report "unknown". No-ops outside fixture mode.
  func seedFixtureStatuses() {
    guard UITestFixture.isActive, let project = projects.first else { return }
    workroomStatuses[.root(project: project.path)] = UITestFixture.rootStatus
    if let workroom = project.workrooms.first {
      workroomStatuses[.workroom(project: project.path, name: workroom.name)] =
        UITestFixture.workroomStatus
    }
  }

  // MARK: - Internals

  private func selectedStatusWorkItem(for sid: SidebarID) -> StatusWorkItem? {
    switch sid {
    case .root(let path):
      guard let p = projects.first(where: { $0.id == path }) else { return nil }
      return StatusWorkItem(sid: sid, path: p.path, vcs: p.vcs)
    case .workroom(let path, let name):
      guard let p = projects.first(where: { $0.id == path }),
        let w = p.workrooms.first(where: { $0.id == name })
      else { return nil }
      return StatusWorkItem(sid: sid, path: w.path, vcs: w.vcsName)
    case .project:
      return nil
    }
  }

  /// Bounded fan-out: at most `cap` local probes in flight; refill as each completes.
  private func runLocalSweep(_ items: [StatusWorkItem], resolver: WorkroomStatusResolver, cap: Int)
    async
  {
    guard !items.isEmpty else { return }
    await withTaskGroup(of: (SidebarID, WorkroomStatus).self) { group in
      var idx = 0
      let initial = min(cap, items.count)
      while idx < initial {
        let item = items[idx]
        idx += 1
        group.addTask { (item.sid, await resolver.resolveLocal(path: item.path, vcs: item.vcs)) }
      }
      while let (sid, fresh) = await group.next() {
        if Task.isCancelled { break }
        mergeLocalStatus(fresh, into: sid)
        if idx < items.count {
          let item = items[idx]
          idx += 1
          group.addTask { (item.sid, await resolver.resolveLocal(path: item.path, vcs: item.vcs)) }
        }
      }
    }
  }

  private func runCISweep(_ items: [StatusWorkItem], resolver: WorkroomStatusResolver, cap: Int)
    async
  {
    guard !items.isEmpty else { return }
    await withTaskGroup(of: (SidebarID, CIResolution).self) { group in
      var idx = 0
      let initial = min(cap, items.count)
      while idx < initial {
        let item = items[idx]
        idx += 1
        let branch = workroomStatuses[item.sid]?.branchForCI
        group.addTask { (item.sid, await resolver.resolveCI(path: item.path, branch: branch)) }
      }
      while let (sid, res) = await group.next() {
        if Task.isCancelled { break }
        applyCIStatus(res, to: sid)
        if idx < items.count {
          let item = items[idx]
          idx += 1
          let branch = workroomStatuses[item.sid]?.branchForCI
          group.addTask { (item.sid, await resolver.resolveCI(path: item.path, branch: branch)) }
        }
      }
    }
  }

  /// Merge a fresh local result into the stored snapshot, preserving the (separately-resolved)
  /// CI fields so a local refresh never wipes the CI badge. Carries the jj head fields
  /// (refs/description/change-id/commit-id) through too — they come from the same local probe as
  /// `dirty`, so dropping them here would leave the Changes header on the git fallback even for a
  /// jj repo.
  func mergeLocalStatus(_ fresh: WorkroomStatus, into sid: SidebarID) {
    var s = workroomStatuses[sid] ?? .unresolved
    s.dirty = fresh.dirty
    s.conflicted = fresh.conflicted
    s.ahead = fresh.ahead
    s.behind = fresh.behind
    s.changedFiles = fresh.changedFiles
    s.branchForCI = fresh.branchForCI
    s.jjRefs = fresh.jjRefs
    s.jjDescription = fresh.jjDescription
    s.jjChangeID = fresh.jjChangeID
    s.jjCommitID = fresh.jjCommitID
    s.failure = fresh.failure
    s.lastChecked = Date()
    workroomStatuses[sid] = s
  }

  private func applyCIStatus(_ res: CIResolution, to sid: SidebarID) {
    guard var s = workroomStatuses[sid] else { return }
    switch res {
    case .state(let x):
      s.ci = x
      s.ciCheckedAt = Date()
    case .absent:
      s.ci = nil
      s.ciCheckedAt = Date()
    case .keepPrior:
      // Transient rate-limit / network blip: keep the last good CI value but stamp
      // `ciCheckedAt` so the normal CI TTL applies — otherwise a rate-limited remote would be
      // re-probed on every sweep (no backoff). Coarse but cheap; true exponential backoff is a
      // future refinement.
      s.ciCheckedAt = Date()
    }
    workroomStatuses[sid] = s
  }

  private func applyPRStatus(_ res: PRResolution, to sid: SidebarID) {
    guard var s = workroomStatuses[sid] else { return }
    switch res {
    case .info(let pr):
      s.pr = pr
      s.prCheckedAt = Date()
    case .absent:
      s.pr = nil
      s.prCheckedAt = Date()
    case .keepPrior:
      // Transient blip: keep the last good PR but stamp `prCheckedAt` so the TTL/backoff applies.
      s.prCheckedAt = Date()
    }
    workroomStatuses[sid] = s
  }
}
