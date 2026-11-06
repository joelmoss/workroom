import Foundation
import WorkroomDomain
import WorkroomVCS

/// The status probes that follow this window's selection (issue #24): the debounced selection
/// refresh and the selected workroom's filesystem watch. The status itself, the sweep, the probe that
/// names one row and the writes in flight are the app's `VCSStatusService`; every result merges
/// there (`mergeLocalStatus`), which is where the lanes are ordered against each other.
extension AppStore {
  fileprivate static let selectionDebounce: TimeInterval = 0.3  // arrow-key row cycling coalesce

  /// Freshen the selected workroom, debounced so arrow-key cycling
  /// through rows doesn't fork a probe per row. Cancels the prior pending refresh.
  /// CI reuses a recent answer only for the exact current commit; PR details/checks stay fresh.
  func scheduleSelectedStatusRefresh() {
    selectionStatusTask?.cancel()
    // (Re)point the filesystem watcher at the newly-selected workroom so its local status stays live
    // while you edit in its terminal (issue #24 follow-up). Cheap + safe to call on every selection.
    updateSelectedWorkroomWatch()
    let vcsStatus = vcsStatus
    // Seeded statuses stay — selecting a target must not fork a real probe that would overwrite them.
    if !vcsStatus.probesRepositories { return }
    guard let sid = selectedTargetID, let item = vcsStatus.selectedStatusWorkItem(for: sid) else {
      return
    }
    // Don't probe a workroom whose setup is still writing its worktree — the watcher is already
    // suppressed above; this skips the debounced local+CI probe too. Re-armed post-setup by
    // `createWorkroom` calling this again once `creatingWorkrooms` no longer holds the id.
    if vcsStatus.isCreating(sid) { return }
    // By project root, not by row: a git worktree's index and refs live in the MAIN repo, so probing
    // workroom B while workroom A of the same project commits contends on the same `index.lock`.
    if vcsStatus.isCommittingProject(item.sharedLocation) { return }
    let resolver = vcsStatus.statusResolver
    selectionStatusTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.selectionDebounce * 1_000_000_000))
      if Task.isCancelled { return }
      guard self != nil else { return }
      let fresh = await resolver.working.resolve(item: item)
      if Task.isCancelled { return }
      guard vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      vcsStatus.mergeLocalStatus(fresh, into: sid)
      guard item.permitsGitHubAccess else { return }
      let github: RepositoryGitHub
      do {
        github = try await RepositoryRouter.shared.gitHub(
          for: try await item.resolvedLocation(), resolver: resolver)
      } catch { return }
      // Skip the network CI/PR probes when `gh` isn't usable (the inspector shows a warning instead).
      await vcsStatus.refreshGitHubCLI(resolver: resolver)
      if Task.isCancelled { return }
      guard vcsStatus.githubCLIStatus == .available else { return }
      // CI and the PR list are independent — run them concurrently. Apply CI the moment it lands so
      // the sidebar/tab glyph never waits on the PR probe.
      async let ciRes = github.ciSnapshot(branch: fresh.branchForCI)
      async let prRawRes = github.pullRequest(branch: fresh.branchForCI)
      let ci = await ciRes
      guard !Task.isCancelled, vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      vcsStatus.applyCIStatus(ci.resolution, to: sid, checkedAt: ci.checkedAt)
      let prRaw = await prRawRes
      guard !Task.isCancelled, vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      vcsStatus.applyPRStatus(prRaw, to: sid)
      // With the PR number in hand, fetch its checks and enrich reviewer permalinks concurrently —
      // checks must not wait behind the (conditional) reviewer-URL GraphQL round-trip (issue #75).
      guard case .info(let info) = prRaw else { return }
      async let enrichedRes = github.enrich(prRaw)
      async let checksRes = github.checks(number: info.number)
      let enriched = await enrichedRes
      guard !Task.isCancelled, vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      vcsStatus.applyPRStatus(enriched, to: sid)
      let checks = await checksRes
      guard !Task.isCancelled, vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      vcsStatus.applyChecksStatus(checks, to: sid)
    }
  }

  /// What this window caches from a status, settled by every local merge (`VCSStatusService.register`
  /// in `init`): the branch name its toolbar published, and the change kind an open diff tab captured
  /// when it opened. A merge is the freshest evidence anyone has for both.
  func localStatusDidMerge(_ status: WorkroomStatus, into sid: SidebarID) {
    pruneResolvedBranchNameIfDrifted(sid, sweptBranch: status.branchForCI)
    refreshOpenDiffChangeKinds(for: sid, status: status)
  }

  /// The current branch label for a terminal target, for the detail-panel status bar (issue
  /// #49). Reuses the already-resolved sidebar caches — the per-workroom local status (`branchForCI`)
  /// and the project root's `RootRef` — so it adds no new VCS calls. Nil until those resolve, or when
  /// no branch is resolvable (the status bar then just omits the segment).
  func branchLabel(for target: TerminalTarget) -> String? {
    guard let sid = sidebarID(for: target.id) else { return nil }
    return branchName(for: sid)
  }

  /// **The** answer to "what branch is this?", for every surface that shows one: the status
  /// bar (`branchLabel(for:)`), the Changes panel header, the sidebar's project root row, and the VCS
  /// toolbar. Four surfaces previously each derived it, which meant they could disagree on screen.
  ///
  /// **Reads only caches — never calls a VCS provider, and must stay that way.** Every source here is
  /// already resolved by something else on its own schedule. This is load-bearing, not incidental: the
  /// sidebar and status bar render this for every row, and the recorded pitfall
  /// `history-eager-focus-is-a-full-vcs-read` is exactly what happens when a per-row read turns out to
  /// open a repo. `BranchLabelTests` pins it with a counting stub that fails if a provider is touched.
  ///
  /// Source order, freshest first:
  /// 1. `resolvedBranchNames` — the VCS toolbar's remote-state read, which is force-refreshed the
  ///    moment anything changes it, so it leads whenever it has an answer.
  /// 2. `branchForCI` from the per-workroom status sweep (15s TTL).
  /// 3. The project root's `RootRef`, resolved by `BranchResolver`.
  func branchName(for sid: SidebarID) -> String? {
    if let resolved = resolvedBranchNames[sid], !resolved.isEmpty { return resolved }
    let status = vcsStatus.workroomStatuses[sid]
    if let branch = status?.branchForCI, !branch.isEmpty { return branch }
    if case .root(let project) = sid {
      let label = RootPresentation.make(vcsStatus.rootRefs[project] ?? .unresolved).label
      return label.isEmpty ? nil : label
    }
    return nil
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
  /// Only a non-empty swept branch counts: git reports none for a detached HEAD, which is no
  /// evidence the cached name is wrong.
  private func pruneResolvedBranchNameIfDrifted(_ sid: SidebarID, sweptBranch: String?) {
    guard let cached = resolvedBranchNames[sid], let swept = sweptBranch, !swept.isEmpty,
      cached != swept
    else { return }
    setResolvedBranchName(nil, for: sid)
  }

  // MARK: - Live filesystem watch (selected workroom)

  /// Point the filesystem watcher at the selected workroom's directory, or stop it when nothing
  /// statusable is selected — or when the selection's create is still in flight (don't watch a tree a
  /// setup script is actively writing). No-ops when statuses are seeded (they must stay
  /// deterministic).
  func updateSelectedWorkroomWatch() {
    guard vcsStatus.probesRepositories, let sid = selectedTargetID, !vcsStatus.isCreating(sid),
      let item = vcsStatus.selectedStatusWorkItem(for: sid), item.permitsLocalAccess
    else {
      workroomFileWatcher.stop()
      return
    }
    workroomFileWatcher.start(path: item.path)
  }

  /// React to a filesystem change under the selected workroom: re-probe its *local* status only
  /// (dirty/ahead-behind/changed-files) and merge. CI/PR stay on their TTLs — a file save
  /// shouldn't fire a `gh` call. Cancel-and-replace so the latest change wins and at most one probe
  /// from THIS lane runs at a time; results across lanes are ordered by `mergeLocalStatus`.
  /// `overflow` means some changes are unlisted (or the watch was interrupted and resumed), so `paths`
  /// cannot be trusted to be complete and the `.jj`-internal filter below must not apply.
  func handleWorkroomFileChange(_ paths: [String], overflow: Bool = false) {
    let vcsStatus = vcsStatus
    guard vcsStatus.probesRepositories, let sid = selectedTargetID,
      let item = vcsStatus.selectedStatusWorkItem(for: sid), item.permitsLocalAccess
    else { return }
    // Defensive: never probe a mid-setup worktree. The watcher shouldn't be armed while creating
    // (updateSelectedWorkroomWatch stops it), but a stray in-flight FSEvents callback can land during
    // the stop transition — bail so it can't fork a probe against the tree the setup script is writing.
    if vcsStatus.isCreating(sid) { return }
    // Same for a commit in flight, keyed by project root — a git worktree's index lives in the main
    // repo, so a sibling workroom's commit churns the very files this probe reads. This lane is the
    // one that would fire MOST during a git commit: git's own index and ref churn is deliberately
    // let through as real signal, so `git add`/`git commit` would each fork a probe against a tree
    // mid-write.
    if vcsStatus.isCommittingProject(item.sharedLocation) { return }
    // A colocated repo left from jj can still have `jj` run in it, which churns `.jj/`; Workroom never
    // writes there, so a burst that touched ONLY jj-internal paths says nothing about the tree.
    if !overflow, !paths.isEmpty, paths.allSatisfy(Self.isJJInternalPath) { return }
    let working = vcsStatus.statusResolver.working
    watchRefreshTask?.cancel()
    watchRefreshTask = Task { [weak self] in
      let fresh = await working.resolve(item: item)
      guard let self, !Task.isCancelled, self.selectedTargetID == sid else { return }
      guard vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      vcsStatus.mergeLocalStatus(fresh, into: sid)
    }
  }

  /// Whether an FSEvents path is inside a jj internal dir (a `.jj` path component). Component-based
  /// so it doesn't match a working file merely named `.jj…`. `nonisolated` (pure) so it's callable
  /// off the main actor.
  nonisolated static func isJJInternalPath(_ path: String) -> Bool {
    path.split(separator: "/").contains(".jj")
  }
}
