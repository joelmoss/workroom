import Foundation

/// Workroom VCS + CI status scheduling (issue #24). Split out of `AppStore` (already large) per
/// the `AppStore+WorkroomSplit.swift` convention. Best-effort / "last checked", NOT real-time:
/// statuses refresh on load, on app focus (via reload), on selection (debounced), and never via
/// a file watcher in Phase 1. The fan-out across all workrooms is bounded (so 50 workrooms
/// don't fork 50 git + 50 gh processes at once); CI is a second, slower stage that never blocks
/// the dirty dot, and is gated by a much longer TTL than the local git probe. Three separate lanes
/// here (this sweep, `scheduleSelectedStatusRefresh`, `handleWorkroomFileChange`) — plus a fourth
/// outside this file, the Changes panel's working-copy diff (`DiffResolver`) — can all reach a jj
/// snapshot for the same project concurrently; `JJSnapshotGate` (via `WorkroomStatusResolver`)
/// serializes same-project jj snapshots across ALL of them, not just within one lane.
extension AppStore {
  fileprivate static let localStatusTTL: TimeInterval = 15  // git/jj dirty/changed-files
  fileprivate static let ciStatusTTL: TimeInterval = 300  // gh CI (network)
  fileprivate static let ghStatusTTL: TimeInterval = 60  // `gh auth status` availability check
  fileprivate static let localConcurrency = 5
  fileprivate static let ciConcurrency = 2
  fileprivate static let selectionDebounce: TimeInterval = 0.3  // arrow-key row cycling coalesce

  struct StatusWorkItem: Sendable {
    let sid: SidebarID
    let path: String
    let vcs: String
    /// The colocated project root. Equals `path` for the root row; for a workroom it's the parent
    /// project's path — where stage-2 `gh` probes run for a jj workspace (which has no `.git`).
    let projectRoot: String
  }

  /// Every root + workroom as a status work item.
  func statusWorkItems() -> [StatusWorkItem] {
    var items: [StatusWorkItem] = []
    for p in projects {
      items.append(
        StatusWorkItem(sid: .root(project: p.id), path: p.path, vcs: p.vcs, projectRoot: p.path))
      for w in p.workrooms {
        // A workroom's VCS *type* is its project's (`p.vcs`) — a git project's workrooms are git
        // worktrees, a jj project's are jj workspaces. NOT `w.vcsName`, which is the workroom's
        // branch/workspace *name* (`workroom/<name>`); passing that as the type made resolveLocal
        // fall through to `.notRepository` for every workroom.
        items.append(
          StatusWorkItem(
            sid: .workroom(project: p.id, name: w.name), path: w.path, vcs: p.vcs,
            projectRoot: p.path))
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
      // Never sweep a workroom whose setup is still writing its worktree (issue: create-time FSEvents
      // storm) — even on `force`. Its status is refreshed once, post-setup, by `createWorkroom`.
      // Covers this window's create AND another window's, since `creatingWorkrooms` is shared.
      if isCreating(item.sid) { return false }
      // Nor one whose PROJECT has a commit in flight — see `isCommittingProject`. Also honoured on
      // `force`, because a manual Refresh during a long hook races the write just as readily as the
      // timer does.
      if isCommittingProject(item.projectRoot) { return false }
      guard !force else { return true }
      guard let checked = workroomStatuses[item.sid]?.lastChecked else { return true }
      return now.timeIntervalSince(checked) >= localTTL
    }
    // `.utility` so this background sweep yields CPU to a mounting terminal surface + its login shell.
    statusSweepTask = Task(priority: .utility) { [weak self] in
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
    // (Re)point the filesystem watcher at the newly-selected workroom so its local status stays live
    // while you edit in its terminal (issue #24 follow-up). Cheap + safe to call on every selection.
    updateSelectedWorkroomWatch()
    // Fixture mode keeps the deterministic seeded status — selecting a target must not fork a real
    // probe that would overwrite it.
    if UITestFixture.isActive { return }
    guard let sid = selectedTargetID, let item = selectedStatusWorkItem(for: sid) else { return }
    // Don't probe a workroom whose setup is still writing its worktree — the watcher is already
    // suppressed above; this skips the debounced local+CI probe too. Re-armed post-setup by
    // `createWorkroom` calling this again once `creatingWorkrooms` no longer holds the id.
    if isCreating(sid) { return }
    // By project root, not by row: a git worktree's index and refs live in the MAIN repo, so probing
    // workroom B while workroom A of the same project commits contends on the same `index.lock`.
    if isCommittingProject(item.projectRoot) { return }
    let resolver = statusResolver
    selectionStatusTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.selectionDebounce * 1_000_000_000))
      if Task.isCancelled { return }
      guard let self else { return }
      let fresh = await resolver.resolveLocal(
        path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
      if Task.isCancelled { return }
      self.mergeLocalStatus(fresh, into: sid)
      // Skip the network CI/PR probes when `gh` isn't usable (the inspector shows a warning instead).
      await self.refreshGitHubCLI(resolver: resolver)
      if Task.isCancelled { return }
      guard self.githubCLIStatus == .available else { return }
      // CI and the PR list are independent — run them concurrently. Apply CI the moment it lands so
      // the sidebar/tab glyph never waits on the PR probe.
      async let ciRes = resolver.resolveCI(
        path: item.path, vcs: item.vcs, projectRoot: item.projectRoot, branch: fresh.branchForCI)
      async let prRawRes = resolver.resolvePRRaw(
        path: item.path, vcs: item.vcs, projectRoot: item.projectRoot, branch: fresh.branchForCI)
      let ci = await ciRes
      if Task.isCancelled { return }
      self.applyCIStatus(ci, to: sid)
      let prRaw = await prRawRes
      if Task.isCancelled { return }
      self.applyPRStatus(prRaw, to: sid)
      // With the PR number in hand, fetch its checks and enrich reviewer permalinks concurrently —
      // checks must not wait behind the (conditional) reviewer-URL GraphQL round-trip (issue #75).
      guard case .info(let info) = prRaw else { return }
      async let enrichedRes = resolver.enrichPR(
        prRaw, path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
      async let checksRes = resolver.resolveChecks(
        path: item.path, vcs: item.vcs, projectRoot: item.projectRoot, number: info.number)
      let enriched = await enrichedRes
      if Task.isCancelled { return }
      self.applyPRStatus(enriched, to: sid)
      let checks = await checksRes
      if Task.isCancelled { return }
      self.applyChecksStatus(checks, to: sid)
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

  /// Run a PR write action (Phase 2b) on the selected workroom's PR: shell to `gh`, refresh the PR
  /// on success, surface `stderr` on failure. In fixture mode it optimistically updates the seeded
  /// status instead of spawning `gh`, so the actions menu is exercisable hermetically.
  func performPRAction(_ action: PRAction, number: Int, on sid: SidebarID) {
    guard let item = selectedStatusWorkItem(for: sid) else { return }
    // Flip the PR state immediately so the badge/buttons react the instant the user acts — otherwise
    // nothing visibly changes during the (multi-second) `gh` call + status re-probe, which reads as
    // "the click did nothing". Keep the prior PR to restore if `gh` fails (and in fixture mode, this
    // optimistic update *is* the result — no `gh` to confirm it).
    let priorPR = workroomStatuses[sid]?.pr
    applyOptimisticPRAction(action, on: sid)
    if UITestFixture.isActive { return }
    prActionInFlight = true
    let resolver = statusResolver
    // Run `gh pr …` where the read probes run: in-place for git, but the colocated project root for
    // a jj workspace (gitless), else the action fails / targets the wrong repo context.
    let dir = WorkroomStatusResolver.ghProbeDirectory(
      path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
    Task { [weak self] in
      let r = await resolver.runPRCommand(action.arguments(number: number), in: dir)
      guard let self else { return }
      self.prActionInFlight = false
      if r.ok {
        // Re-probe to replace the optimistic state with GitHub's authoritative one.
        self.scheduleSelectedStatusRefresh()
      } else {
        // The command failed — undo the optimistic flip so the UI doesn't lie, then surface stderr.
        if var s = self.workroomStatuses[sid] {
          s.pr = priorPR
          self.workroomStatuses[sid] = s
        }
        self.errorTitle = "Couldn’t \(action.label.lowercased())"
        let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.errorMessage = stderr.isEmpty ? "The gh command failed." : stderr
      }
    }
  }

  /// Record a commit for `sid` and refresh what it changed.
  ///
  /// Unlike `performPRAction`, there is **no optimistic update**. A PR action flips a badge whose
  /// authority is remote and slow; a commit rewrites local state the panel reads directly, and
  /// pretending it succeeded would mean showing a clean file list for a commit a hook is still able
  /// to reject. The sheet shows progress instead, and the list changes only once it really has.
  ///
  /// `sid` is captured by the caller, never re-derived: `selectedTargetID` can move while a hook
  /// runs, and every refresh below must land on the row that actually changed.
  func performCommit(
    _ request: VCSCommitRequest, on sid: SidebarID,
    completion: @escaping (VCSCommitResult) -> Void
  ) {
    guard let item = selectedStatusWorkItem(for: sid) else {
      return completion(.failed(.other("That workroom is no longer available.")))
    }
    // Fixture mode swaps the WRITER — `FixtureVCSWriter` rather than spawning git or jj, since the
    // fixture paths aren't real repos and a live write would only ever fail. Only the writer: taking
    // an early return here instead skipped the whole store-side lane (the in-flight marks, the
    // captured-sid refresh), so the one tier that drives this code end to end exercised none of it.
    // `refreshStatus(for:)` already no-ops under the fixture, so the rest is safe to run.
    let root = item.projectRoot
    committingTargets.insert(sid)
    committingProjectRoots[root, default: 0] += 1
    Task { [weak self] in
      let result: VCSCommitResult
      if UITestFixture.isActive {
        result = await FixtureVCSWriter().commit(
          path: item.path, projectRoot: root, request: request)
      } else {
        do {
          let writer = try VCS.writer(for: URL(fileURLWithPath: item.path, isDirectory: true))
          result = await writer.commit(path: item.path, projectRoot: root, request: request)
        } catch {
          result = .failed(.other("\(error)"))
        }
      }
      guard let self else { return }
      self.committingTargets.remove(sid)
      // Decremented, never cleared: a sibling workroom of the same project can be committing too, and
      // dropping the key would re-open every read lane against a write still in progress.
      let remaining = (self.committingProjectRoots[root] ?? 1) - 1
      if remaining > 0 {
        self.committingProjectRoots[root] = remaining
      } else {
        self.committingProjectRoots.removeValue(forKey: root)
      }
      switch result {
      case .ok, .committedThenFailed:
        // Refresh by the CAPTURED sid. The Changes list is the load-bearing one for jj:
        // `handleWorkroomFileChange` deliberately drops bursts that touched only `.jj/`, so a jj
        // commit never self-refreshes from the watcher.
        self.refreshStatus(for: sid)
        // History gained a commit, and the ahead count and Push button both moved. Only refresh the
        // models that are still pointed at the row we committed — otherwise switching workrooms
        // mid-commit would repoint them at the wrong repo's log.
        if self.inspectorTargetID == sid {
          self.commitHistory.refresh()
          self.remoteState.refresh()
        }
      case .failed:
        break
      }
      completion(result)
    }
  }

  /// Ask which selected paths hold staged content a commit would discard, before committing.
  ///
  /// Read-only and ungated: it runs one `git status`, which takes no lock. Returns empty on any
  /// failure so a guard that cannot answer never blocks the commit — the guard exists to inform, and
  /// a broken guard must not become a broken commit.
  func stagedContentAtRisk(
    on sid: SidebarID, files: [ChangedFile], completion: @escaping ([String]) -> Void
  ) {
    guard !UITestFixture.isActive, let item = selectedStatusWorkItem(for: sid), item.vcs != "jj"
    else { return completion([]) }
    Task {
      guard let writer = try? VCS.writer(for: URL(fileURLWithPath: item.path, isDirectory: true))
      else { return completion([]) }
      completion(await writer.stagedContentAtRisk(path: item.path, files: files))
    }
  }

  /// Optimistically reflect a PR action in the in-memory status (no `gh`): the badge/state flip
  /// immediately on click, before the command returns. The real path restores the prior PR if `gh`
  /// fails and re-probes on success; fixture mode keeps this as the final result.
  private func applyOptimisticPRAction(_ action: PRAction, on sid: SidebarID) {
    guard var s = workroomStatuses[sid], let pr = s.pr else { return }
    let state: PullRequestInfo.State
    let draft: Bool
    switch action {
    case .markReady:
      state = .open
      draft = false
    case .convertToDraft:
      state = .open
      draft = true
    case .close:
      state = .closed
      draft = pr.isDraft
    case .reopen:
      state = .open
      draft = pr.isDraft
    }
    // Carry the prior mergeability forward (the re-probe corrects it): dropping it here would flip
    // `canMerge` off and blink the Merge button away for the (multi-second) round-trip.
    s.pr = PullRequestInfo(
      number: pr.number, title: pr.title, state: state, isDraft: draft, url: pr.url,
      reviewDecision: pr.reviewDecision, reviewers: pr.reviewers,
      mergeable: pr.mergeable, mergeState: pr.mergeState)
    workroomStatuses[sid] = s
  }

  /// Merge the selected workroom's PR (issue #88) with `method`: shell to `gh pr merge`, refresh on
  /// success, surface `stderr` on failure. Mirrors `performPRAction` — same in-flight gate, same
  /// `gh` repo context, same optimistic-then-authoritative flow — but the strategy is a parameter,
  /// so it's kept separate from the state-only `PRAction` verbs. In fixture mode it optimistically
  /// flips the PR to merged instead of spawning `gh`.
  func performMerge(_ method: PRMergeMethod, number: Int, on sid: SidebarID) {
    guard let item = selectedStatusWorkItem(for: sid) else { return }
    let priorPR = workroomStatuses[sid]?.pr
    applyOptimisticMerge(on: sid)
    if UITestFixture.isActive { return }
    prActionInFlight = true
    let resolver = statusResolver
    let dir = WorkroomStatusResolver.ghProbeDirectory(
      path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
    Task { [weak self] in
      let r = await resolver.runPRCommand(method.arguments(number: number), in: dir)
      guard let self else { return }
      self.prActionInFlight = false
      if r.ok {
        self.scheduleSelectedStatusRefresh()
      } else {
        if var s = self.workroomStatuses[sid] {
          s.pr = priorPR
          self.workroomStatuses[sid] = s
        }
        self.errorTitle = "Couldn’t merge pull request"
        let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.errorMessage = stderr.isEmpty ? "The gh command failed." : stderr
      }
    }
  }

  /// Optimistically flip the PR to merged (no `gh`): the badge turns purple and the Merge button
  /// disappears the instant the user confirms. `mergeable` is cleared so `canMerge` is false too.
  /// The real path restores the prior PR if `gh` fails and re-probes on success.
  private func applyOptimisticMerge(on sid: SidebarID) {
    guard var s = workroomStatuses[sid], let pr = s.pr else { return }
    s.pr = PullRequestInfo(
      number: pr.number, title: pr.title, state: .merged, isDraft: false, url: pr.url,
      reviewDecision: pr.reviewDecision, reviewers: pr.reviewers,
      mergeable: false, mergeState: pr.mergeState)
    workroomStatuses[sid] = s
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

  /// Whether `sid` still maps to a live root/workroom. A status sweep captures its work-list up
  /// front, so a workroom can be deleted before its (slow) probe lands — without this guard the
  /// merge would write a ghost entry into `workroomStatuses` for a target that no longer exists.
  private func targetExists(_ sid: SidebarID) -> Bool {
    selectedStatusWorkItem(for: sid) != nil
  }

  /// `internal` rather than `private`: the commit sheet needs a row's path and vcs to open against it
  /// and to read `@`'s description for the prefill.
  func selectedStatusWorkItem(for sid: SidebarID) -> StatusWorkItem? {
    switch sid {
    case .root(let path):
      guard let p = projects.first(where: { $0.id == path }) else { return nil }
      return StatusWorkItem(sid: sid, path: p.path, vcs: p.vcs, projectRoot: p.path)
    case .workroom(let path, let name):
      guard let p = projects.first(where: { $0.id == path }),
        let w = p.workrooms.first(where: { $0.id == name })
      else { return nil }
      // `p.vcs` is the VCS type; `w.vcsName` is the branch name, not the type (see statusWorkItems).
      return StatusWorkItem(sid: sid, path: w.path, vcs: p.vcs, projectRoot: p.path)
    case .project:
      return nil
    }
  }

  /// Bounded fan-out: at most `cap` local probes in flight; refill as each completes. `cap` bounds
  /// cross-project parallelism and all git probes; it does NOT bound jj snapshots within one
  /// project — those additionally serialize behind each other through `WorkroomStatusResolver`'s
  /// `JJSnapshotGate` (keyed on `item.projectRoot`), since a project's workrooms share a backing
  /// repo a concurrent snapshot can contend on. Workrooms of *different* projects still run fully
  /// concurrently, up to `cap`.
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
        group.addTask {
          (
            item.sid,
            await resolver.resolveLocal(
              path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
          )
        }
      }
      while let (sid, fresh) = await group.next() {
        if Task.isCancelled { break }
        mergeLocalStatus(fresh, into: sid)
        if idx < items.count {
          let item = items[idx]
          idx += 1
          group.addTask {
            (
              item.sid,
              await resolver.resolveLocal(
                path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
            )
          }
        }
      }
    }
  }

  private func runCISweep(_ items: [StatusWorkItem], resolver: WorkroomStatusResolver, cap: Int)
    async
  {
    guard !items.isEmpty else { return }
    // The CI rollup probe (#76) needs the repo's `owner/repo`. It's per-project, so resolve it once
    // per distinct project root and reuse it across that project's workrooms — not one `gh repo view`
    // per workroom. A project that can't resolve maps to `nil` (its workrooms then report CI absent).
    var nwoCache: [String: String?] = [:]
    for root in Set(items.map(\.projectRoot)) {
      if Task.isCancelled { return }
      nwoCache[root] = await resolver.resolveNameWithOwner(in: root)
    }
    await withTaskGroup(of: (SidebarID, CIResolution).self) { group in
      var idx = 0
      let initial = min(cap, items.count)
      while idx < initial {
        let item = items[idx]
        idx += 1
        let branch = workroomStatuses[item.sid]?.branchForCI
        let nwo = nwoCache[item.projectRoot] ?? nil
        group.addTask {
          (
            item.sid,
            await resolver.resolveCI(
              path: item.path, vcs: item.vcs, projectRoot: item.projectRoot, branch: branch,
              nameWithOwner: nwo)
          )
        }
      }
      while let (sid, res) = await group.next() {
        if Task.isCancelled { break }
        applyCIStatus(res, to: sid)
        if idx < items.count {
          let item = items[idx]
          idx += 1
          let branch = workroomStatuses[item.sid]?.branchForCI
          let nwo = nwoCache[item.projectRoot] ?? nil
          group.addTask {
            (
              item.sid,
              await resolver.resolveCI(
                path: item.path, vcs: item.vcs, projectRoot: item.projectRoot, branch: branch,
                nameWithOwner: nwo)
            )
          }
        }
      }
    }
  }

  /// Merge a fresh local result into the stored snapshot, preserving the (separately-resolved)
  /// CI fields so a local refresh never wipes the CI badge. Carries the jj working-copy change set
  /// through too — it comes from the same local probe as `dirty`, so dropping it here would leave
  /// the Changes panel on the git fallback even for a jj repo.
  func mergeLocalStatus(_ fresh: WorkroomStatus, into sid: SidebarID) {
    guard targetExists(sid) else { return }  // deleted mid-sweep → don't write a ghost entry
    var s = workroomStatuses[sid] ?? .unresolved
    s.dirty = fresh.dirty
    s.conflicted = fresh.conflicted
    s.changedFiles = fresh.changedFiles
    s.insertions = fresh.insertions
    s.deletions = fresh.deletions
    s.branchForCI = fresh.branchForCI
    s.jjWorkingCopy = fresh.jjWorkingCopy
    s.failure = fresh.failure
    s.lastChecked = Date()
    workroomStatuses[sid] = s
    // This sweep is the freshest evidence anyone has for these two, so it settles both of the caches
    // that would otherwise go on asserting a record-time answer: the branch name the toolbar
    // published, and the change kind an open diff tab captured when it opened.
    pruneResolvedBranchNameIfDrifted(sid, sweptBranch: fresh.branchForCI)
    refreshOpenDiffChangeKinds(for: sid, status: s)
  }

  /// Drop the toolbar's cached branch name for `sid` when this sweep disagrees with it.
  ///
  /// `resolvedBranchNames` leads `branchName(for:)` because it is normally the freshest source — but it
  /// is written only for the focused target, and only while the inspector is showing Changes
  /// (`focusRemoteStateIfShown`). So `git switch` in a workroom's terminal left every branch-showing
  /// surface on the old name indefinitely: nothing invalidated source #1, and the sweep that DID know
  /// better sat behind it. A disagreement means the cache is no longer the freshest answer, so it
  /// yields rather than wins — and the next toolbar read republishes it.
  ///
  /// Only a non-empty swept branch counts: git reports none for a detached HEAD, and jj none for an
  /// unbookmarked `@` — neither is evidence the cached name is wrong.
  private func pruneResolvedBranchNameIfDrifted(_ sid: SidebarID, sweptBranch: String?) {
    guard let cached = resolvedBranchNames[sid], let swept = sweptBranch, !swept.isEmpty,
      cached != swept
    else { return }
    setResolvedBranchName(nil, for: sid)
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
      // Transient rate-limit / network blip. Stamp `ciCheckedAt` so the TTL throttles re-probes —
      // but ONLY if we've probed before (ciCheckedAt set). On a first-ever probe that blips, leave
      // it nil so the next sweep retries instead of hiding CI for the full TTL on one blip. Coarse
      // but cheap; true exponential backoff is a future refinement.
      if s.ciCheckedAt != nil { s.ciCheckedAt = Date() }
    }
    workroomStatuses[sid] = s
  }

  // Internal (not `private`) so `@testable` can drive the checks lifecycle (clear-on-PR-change /
  // clear-on-no-PR, issue #75) directly.
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
  /// list, stamping only if we've probed before (so a first-ever blip retries next time). Internal
  /// (not `private`) so `@testable` reaches it. The clear-on-no-PR / clear-on-PR-change paths live in
  /// `applyPRStatus` — `resolveChecks` never runs without a PR.
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

  // MARK: - Live filesystem watch (selected workroom)

  /// Whether `sid` is a workroom whose create/setup is still in flight (issue: create-time FSEvents
  /// storm). While a setup script writes the worktree (e.g. `npm install`), arming the recursive
  /// FSEvents watcher on it or probing its VCS status is pointless churn — the tree isn't settled and
  /// FSEvents floods ~70 callbacks/sec under that load. `creatingWorkrooms` (set as setup begins,
  /// cleared when it finishes) is the exact signal; this is the single conversion point from the
  /// `SidebarID`-keyed status world to the `TerminalTarget.ID`-keyed `creatingWorkrooms` set. Roots
  /// and projects are never "creating".
  func isCreating(_ sid: SidebarID) -> Bool {
    guard case .workroom(let project, let name) = sid else { return false }
    return creatingWorkrooms.contains(TerminalTarget.workroomID(project: project, name: name))
  }

  /// Whether a commit is running for this row. Suppresses the same three lanes `isCreating` does, for
  /// a closely-related reason.
  ///
  /// Necessary because `JJSnapshotGate` is not sufficient on its own here: its `maxChainWait` is 30s
  /// and a commit's timeout is far longer (a `pre-commit` hook that runs a test suite is ordinary), so
  /// a queued status probe would hit the gate's documented self-heal and run **concurrently with the
  /// commit** — snapshotting `@` mid-write for jj, contending on `index.lock` for git. Suppressing the
  /// lanes is the fix; raising the ceiling would only make every other lane wait longer.
  ///
  /// It also stops the panel rendering a half-staged tree: `git commit` moves the index and refs as it
  /// goes, and `GitProvider.workingStatus` collapses index and worktree deltas into one row, so a
  /// probe landing mid-commit shows a state that never really existed.
  func isCommitting(_ sid: SidebarID) -> Bool { committingTargets.contains(sid) }

  /// Whether ANY workroom of this project has a commit in flight.
  ///
  /// The question every read lane has to ask, rather than `isCommitting(sid)`. `JJSnapshotGate`
  /// serializes on the project root, and its `maxChainWait` self-heal (30s) is far shorter than
  /// `commitTimeout` (600s) — so a probe queued behind a slow hook stops waiting and runs anyway.
  /// Suppression is what actually keeps these lanes off a repo mid-write; the gate alone does not.
  func isCommittingProject(_ projectRoot: String) -> Bool {
    committingProjectRoots[projectRoot, default: 0] > 0
  }

  /// Re-probe ONE row's local status, named explicitly.
  ///
  /// `scheduleSelectedStatusRefresh` cannot serve a commit: it derives its target from the LIVE
  /// `selectedTargetID`, so switching workrooms while a commit is in flight would commit A and
  /// refresh B — leaving the row that actually changed stale and re-probing one that didn't. Every
  /// post-commit refresh therefore names the sid it captured when the sheet opened.
  func refreshStatus(for sid: SidebarID) {
    guard !UITestFixture.isActive, let item = selectedStatusWorkItem(for: sid) else { return }
    let resolver = statusResolver
    Task { [weak self] in
      let fresh = await resolver.resolveLocal(
        path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
      guard let self, self.targetExists(sid) else { return }
      self.mergeLocalStatus(fresh, into: sid)
    }
  }

  /// Point the filesystem watcher at the selected workroom's directory, or stop it when nothing
  /// statusable is selected — or when the selection's create is still in flight (don't watch a tree a
  /// setup script is actively writing). No-ops in fixture mode (the seeded status must stay
  /// deterministic).
  func updateSelectedWorkroomWatch() {
    guard !UITestFixture.isActive, let sid = selectedTargetID, !isCreating(sid),
      let item = selectedStatusWorkItem(for: sid)
    else {
      workroomFileWatcher.stop()
      return
    }
    workroomFileWatcher.start(path: item.path)
  }

  /// React to a filesystem change under the selected workroom: re-probe its *local* status only
  /// (dirty/ahead-behind/changed-files/jj head) and merge. CI/PR stay on their TTLs — a file save
  /// shouldn't fire a `gh` call. Cancel-and-replace so the latest change wins and at most one probe
  /// from THIS lane runs at a time — it does NOT by itself prevent this probe's jj snapshot from
  /// overlapping the sweep's or the selection-refresh's for the same project; that cross-lane
  /// ordering is `JJSnapshotGate`'s job (via `WorkroomStatusResolver.resolveLocal`).
  func handleWorkroomFileChange(_ paths: [String]) {
    guard !UITestFixture.isActive, let sid = selectedTargetID,
      let item = selectedStatusWorkItem(for: sid)
    else { return }
    // Defensive: never probe a mid-setup worktree. The watcher shouldn't be armed while creating
    // (updateSelectedWorkroomWatch stops it), but a stray in-flight FSEvents callback can land during
    // the stop transition — bail so it can't fork a probe against the tree the setup script is writing.
    if isCreating(sid) { return }
    // Same for a commit in flight, keyed by project root — a git worktree's index lives in the main
    // repo, so a sibling workroom's commit churns the very files this probe reads. This lane is the
    // one that would fire MOST during a git commit: the `.jj/` filter below saves jj from
    // self-triggering, but git's own index and ref churn is deliberately let through as real signal,
    // so `git add`/`git commit` would each fork a probe against a tree mid-write.
    if isCommittingProject(item.projectRoot) { return }
    // A jj *local* probe snapshots `@` (writes under `.jj/`), which would itself trip the watcher —
    // an endless refresh loop. So ignore a burst that touched ONLY jj-internal paths. (git probes are
    // read-only, and `.git/index` changes from `git add` are real signal, so git events pass through.)
    if item.vcs == "jj", !paths.isEmpty, paths.allSatisfy(Self.isJJInternalPath) { return }
    let resolver = statusResolver
    watchRefreshTask?.cancel()
    watchRefreshTask = Task { [weak self] in
      let fresh = await resolver.resolveLocal(
        path: item.path, vcs: item.vcs, projectRoot: item.projectRoot)
      guard let self, !Task.isCancelled, self.selectedTargetID == sid else { return }
      self.mergeLocalStatus(fresh, into: sid)
    }
  }

  /// Whether an FSEvents path is inside a jj internal dir (a `.jj` path component) — used to skip the
  /// snapshot self-trigger. Component-based so it doesn't match a working file merely named `.jj…`.
  /// `nonisolated` (pure) so it's callable off the main actor.
  nonisolated static func isJJInternalPath(_ path: String) -> Bool {
    path.split(separator: "/").contains(".jj")
  }
}
