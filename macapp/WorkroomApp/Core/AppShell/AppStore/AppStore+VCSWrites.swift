import Foundation
import WorkroomDomain
import WorkroomVCS

/// The VCS write actions the status inspector offers: PR actions and merges through `gh`, and
/// commits with their preflight. Moved out of `AppStore+WorkroomStatus.swift` as is, so that file
/// only reads status. Coupling points: these write into `vcsStatus.workroomStatuses`
/// (optimistically, then from a fresh probe) and use its `selectedStatusWorkItem(for:)`, its
/// `beginCommit`/`endCommit` bookkeeping and its `refreshLocalStatus(for:skippingCreatesAndCommits:)`.
extension AppStore {
  /// Whether `sid` has anything a commit could record, and none is in flight: the Changes header's
  /// commit button and Room ▸ Commit… both ask this.
  @_disfavoredOverload
  func canCommit(_ sid: SidebarID?) -> Bool { canCommit(sid.map(VCSActionTarget.row)) }

  /// Whether `target` has anything a commit could record, and none is in flight. A followed
  /// repository's (#808) answers from its own status, which is there only while a window follows it.
  func canCommit(_ target: VCSActionTarget?) -> Bool {
    guard let target, let status = vcsStatus.status(for: target), !vcsStatus.isCommitting(target)
    else { return false }
    return !(status.isClean || status.isUnknown)
  }

  /// Open the commit dialog for `sid`, when it has something to commit.
  @_disfavoredOverload
  func requestCommit(_ sid: SidebarID?) { requestCommit(sid.map(VCSActionTarget.row)) }

  /// Open the commit dialog for `target`, when it has something to commit.
  func requestCommit(_ target: VCSActionTarget?) {
    guard let target, canCommit(target) else { return }
    switch target {
    case .row(let sid): guard vcsStatus.selectedStatusWorkItem(for: sid) != nil else { return }
    case .followed(let root): guard vcsStatus.followedRepositories[root] != nil else { return }
    }
    modals.pendingCommit = PendingCommit(target: target)
  }

  /// What a version-control action in the inspector acts on: its workroom or project root, or the
  /// repository a terminal's inspector follows (#808). A followed repository that is a registered
  /// row's acts as that row, in place. Nil when there is no repository to act on: nothing selected,
  /// a folder outside a repository, one git couldn't tell about, a repository this window no longer
  /// holds, or one the app can't write to.
  var inspectorActionTarget: VCSActionTarget? {
    switch inspectorSubject {
    case .target(let sid): return .row(sid)
    case .followed(let followed):
      guard let repository = followed.repository, repository.isWritable,
        let root = heldFollowedRepository, root == repository.root
      else { return nil }
      if let sid = vcsStatus.registeredSidebarID(forCanonicalRoot: root) { return .row(sid) }
      return .followed(root: root)
    case .nothing: return nil
    }
  }

  /// Where a write to `target` lands, resolved when the write runs from what was captured at the
  /// click. A followed repository's is its registration's, awaited: nil once no window follows it,
  /// so the write is refused rather than sent wherever the terminal has gone since.
  private func writeLocation(for target: VCSActionTarget) async throws -> RepositoryLocation {
    switch target {
    case .row(let sid):
      guard let item = vcsStatus.selectedStatusWorkItem(for: sid) else {
        throw RepositoryRoutingError.registrationRequired
      }
      return try await item.resolvedLocation()
    case .followed(let root):
      guard let location = await vcsStatus.followedWriteLocation(root) else {
        throw FollowedRepositoryGone()
      }
      return location
    }
  }

  /// Run a PR write action (Phase 2b) on the selected workroom's PR: shell to `gh`, refresh the PR
  /// on success, surface `stderr` on failure. In fixture mode it optimistically updates the seeded
  /// status instead of spawning `gh`, so the actions menu is exercisable hermetically. Delegates the
  /// whole lifecycle to `performPRWrite`, shared with `performMerge`.
  func performPRAction(_ action: PRAction, number: Int, on sid: SidebarID) {
    guard let item = vcsStatus.selectedStatusWorkItem(for: sid) else { return }
    performPRAction(action, number: number, on: item)
  }

  func performPRAction(
    _ action: PRAction, number: Int, on item: VCSStatusService.StatusWorkItem
  ) {
    performPRWrite(
      arguments: action.arguments(number: number), on: item,
      applyOptimistic: { self.applyOptimisticPRAction(action, on: $0) },
      errorTitle: "Couldn’t \(action.label.lowercased())")
  }

  /// The gh-write lifecycle shared by `performPRAction` and `performMerge` (issue #88): guard the
  /// selected item, capture the prior PR to restore on failure, apply the optimistic update, then —
  /// UNLESS in fixture mode, where the optimistic flip is itself the final result — flip the
  /// in-flight flag, build the GitHub service for the registered location (bound to its repository
  /// identity), and run the command. On success re-probe for
  /// GitHub's authoritative state; on failure revert the optimistic flip and surface `stderr`.
  ///
  /// Fixture mode applies the optimistic update and stops there, before `prActionInFlight` flips —
  /// fixture-mode tests rely on seeing the optimistic update with no in-flight flag ever set.
  private func performPRWrite(
    arguments: [String], on item: VCSStatusService.StatusWorkItem,
    applyOptimistic: (SidebarID) -> Void, errorTitle: String
  ) {
    let sid = item.sid
    guard item.permitsGitHubAccess else {
      self.modals.errorTitle = errorTitle
      self.modals.errorMessage =
        RepositoryRoutingError.unavailable(item.location?.host ?? .local).localizedDescription
      return
    }
    // Seeded statuses have no `gh` behind them: the optimistic update below *is* the result.
    guard vcsStatus.probesRepositories else { return applyOptimistic(sid) }
    let github: RepositoryGitHub
    do {
      guard let location = item.location else {
        throw RepositoryRoutingError.registrationRequired
      }
      github = try RepositoryRouter.shared.registeredGitHub(
        for: location, resolver: vcsStatus.statusResolver)
    } catch {
      self.modals.errorTitle = errorTitle
      self.modals.errorMessage = error.localizedDescription
      return
    }
    // Flip the PR state immediately so the badge/buttons react the instant the user acts — otherwise
    // nothing visibly changes during the (multi-second) `gh` call + status re-probe, which reads as
    // "the click did nothing". Keep the prior PR to restore if `gh` fails.
    let priorPR = vcsStatus.workroomStatuses[sid]?.pr
    applyOptimistic(sid)
    prActionInFlight = true
    Task { [weak self] in
      let r = await github.run(arguments)
      guard let self else { return }
      self.prActionInFlight = false
      guard self.vcsStatus.selectedStatusWorkItem(for: sid) == item else { return }
      if r.ok {
        // Re-probe to replace the optimistic state with GitHub's authoritative one.
        self.scheduleSelectedStatusRefresh()
      } else {
        // The command failed — undo the optimistic flip so the UI doesn't lie, then surface stderr.
        if var s = self.vcsStatus.workroomStatuses[sid] {
          s.pr = priorPR
          self.vcsStatus.workroomStatuses[sid] = s
        }
        self.modals.errorTitle = errorTitle
        let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modals.errorMessage = stderr.isEmpty ? "The gh command failed." : stderr
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
    performCommit(request, on: .row(sid), completion: completion)
  }

  /// Record a commit for `target`, a row or a followed repository (#808), captured by the caller: a
  /// terminal can `cd` to another repository while a hook runs, and the commit and every refresh
  /// below belong to the repository the sheet was opened for.
  func performCommit(
    _ request: VCSCommitRequest, on target: VCSActionTarget,
    completion: @escaping (VCSCommitResult) -> Void
  ) {
    let item: VCSStatusService.StatusWorkItem?
    switch target {
    case .row(let sid):
      guard let found = vcsStatus.selectedStatusWorkItem(for: sid) else {
        return completion(.failed(.other("That workroom is no longer available.")))
      }
      item = found
    case .followed(let root):
      guard vcsStatus.followedRepositories[root] != nil else {
        return completion(.failed(.other(FollowedRepositoryGone().localizedDescription)))
      }
      item = nil
    }
    // The services' local writer, when they have one (the fixture's `FixtureVCSWriter`, since its
    // paths aren't real repos and a live write would only ever fail), replaces only the WRITER:
    // taking an early return here instead skipped the whole store-side lane (the in-flight marks, the
    // captured-sid refresh), so the one tier that drives this code end to end exercised none of it.
    // `refreshLocalStatus(for:skippingCreatesAndCommits:)` already no-ops when statuses are seeded,
    // so the rest is safe to run.
    let localWriter = services.vcsWriter
    Task { [weak self] in
      guard let self else { return }
      let root: RepositoryLocation
      let commit: () async -> VCSCommitResult
      do {
        if let localWriter, let item {
          let local = try await RepositoryLocation.local(item.projectRoot)
          let writer = try localWriter(try local.requireLocalURL())
          root = local
          commit = {
            await writer.commit(path: item.path, projectRoot: local.path, request: request)
          }
        } else {
          let location = try await self.writeLocation(for: target)
          let writer = try await RepositoryRouter.shared.writer(for: location)
          root = try writer.context.requireOwnership()
          commit = { await writer.commit(request: request) }
        }
      } catch { return completion(.failed(.other(error.localizedDescription))) }
      // Refuse outright rather than queue behind another write (commit/fetch/push/pull, this window
      // or another) on the same project root — see `isWritingProject`'s doc for why queuing into
      // `RepositoryWriteGate` here would risk racing it past the gate's own wedge-detection ceiling.
      guard !self.vcsStatus.isWritingProject(root) else {
        return completion(.failed(.locked(nil)))
      }
      // Captured STRONGLY, not through `self`: `committingProjectRoots`/`writingProjectRoots` live on
      // the app-wide `VCSStatusService`, and their release below must run even if THIS window's
      // `AppStore` is deallocated before the write finishes (e.g. the window is closed mid-commit). A
      // release gated on `self` staying alive would leak both counters — `writingProjectRoots`
      // permanently, since nothing else ever decrements it, refusing every future write for this
      // project, in every window, until the app restarts.
      let vcsStatus = self.vcsStatus
      vcsStatus.beginCommit(target, root: root)
      let result = await commit()
      vcsStatus.endCommit(target, root: root)
      switch result {
      case .ok, .committedThenFailed:
        // Refresh by the CAPTURED target: the watcher lane is suppressed while the commit runs
        // (`isCommittingProject`), so the commit's own churn never refreshes the Changes list.
        switch target {
        case .row(let sid):
          vcsStatus.refreshLocalStatus(for: sid, skippingCreatesAndCommits: false)
          // A registered row a terminal's inspector follows in place: its followed lane too, which
          // is the one that reads it while no workroom is selected.
          if let held = self.heldFollowedRepository,
            vcsStatus.registeredSidebarID(forCanonicalRoot: held) == sid
          {
            vcsStatus.refreshFollowedStatus(held, gitHub: false)
          }
        case .followed(let followed):
          vcsStatus.refreshFollowedStatus(followed, gitHub: false)
        }
        // History gained a commit, and the ahead count and Push button both moved. Only refresh the
        // models that are still pointed at what we committed — otherwise switching workrooms, or a
        // `cd` to another repository, mid-commit would repoint them at the wrong repo's log.
        if self.inspectorActionTarget == target {
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
  /// Read-only and ungated. A failed staged-content check is an explicit failure: the sheet must
  /// not authorize a commit when it cannot determine whether staged work would be discarded.
  func stagedContentAtRisk(
    on sid: SidebarID, files: [ChangedFile], completion: @escaping (Result<[String], Error>) -> Void
  ) {
    stagedContentAtRisk(on: .row(sid), files: files, completion: completion)
  }

  func stagedContentAtRisk(
    on target: VCSActionTarget, files: [ChangedFile],
    completion: @escaping (Result<[String], Error>) -> Void
  ) {
    guard vcsStatus.probesRepositories else { return completion(.success([])) }
    Task {
      do {
        let location = try await self.writeLocation(for: target)
        let writer = try await RepositoryRouter.shared.writer(for: location)
        completion(.success(try await writer.stagedContentAtRisk(files: files)))
      } catch { completion(.failure(error)) }
    }
  }

  /// Ask what the commit dialog should show before it writes — the amend target and any parked git
  /// operation.
  ///
  /// Read-only and ungated, for `stagedContentAtRisk`'s reasons. Routed through `RepositoryRouter` rather
  /// than spawning `git` from the dialog, which is what made these reads work only for a repo
  /// on this Mac (issue #154, Phase 2).
  ///
  /// Failures remain explicit and block the write until preflight succeeds.
  /// The fixture is NOT short-circuited here — `CommitFlow.prefill` seeds its own values.
  func commitPreflight(
    on sid: SidebarID, completion: @escaping (Result<VCSCommitPreflight, Error>) -> Void
  ) {
    commitPreflight(on: .row(sid), completion: completion)
  }

  func commitPreflight(
    on target: VCSActionTarget, completion: @escaping (Result<VCSCommitPreflight, Error>) -> Void
  ) {
    Task {
      do {
        let location = try await self.writeLocation(for: target)
        let writer = try await RepositoryRouter.shared.writer(for: location)
        completion(.success(try await writer.commitPreflight()))
      } catch { completion(.failure(error)) }
    }
  }

  /// Optimistically reflect a PR action in the in-memory status (no `gh`): the badge/state flip
  /// immediately on click, before the command returns. The real path restores the prior PR if `gh`
  /// fails and re-probes on success; fixture mode keeps this as the final result.
  private func applyOptimisticPRAction(_ action: PRAction, on sid: SidebarID) {
    guard var s = vcsStatus.workroomStatuses[sid], let pr = s.pr else { return }
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
    vcsStatus.workroomStatuses[sid] = s
  }

  /// Merge the selected workroom's PR (issue #88) with `method`: shell to `gh pr merge`, refresh on
  /// success, surface `stderr` on failure. Mirrors `performPRAction` — same in-flight gate, same
  /// `gh` repo context, same optimistic-then-authoritative flow, both via `performPRWrite` — but the
  /// strategy is a parameter, so it's kept separate from the state-only `PRAction` verbs. In fixture
  /// mode it optimistically flips the PR to merged instead of spawning `gh`.
  func performMerge(_ method: PRMergeMethod, number: Int, on sid: SidebarID) {
    guard let item = vcsStatus.selectedStatusWorkItem(for: sid) else { return }
    performPRWrite(
      arguments: method.arguments(number: number), on: item,
      applyOptimistic: { self.applyOptimisticMerge(on: $0) },
      errorTitle: "Couldn’t merge pull request")
  }

  /// Optimistically flip the PR to merged (no `gh`): the badge turns purple and the Merge button
  /// disappears the instant the user confirms. `mergeable` is cleared so `canMerge` is false too.
  /// The real path restores the prior PR if `gh` fails and re-probes on success.
  private func applyOptimisticMerge(on sid: SidebarID) {
    guard var s = vcsStatus.workroomStatuses[sid], let pr = s.pr else { return }
    s.pr = PullRequestInfo(
      number: pr.number, title: pr.title, state: .merged, isDraft: false, url: pr.url,
      reviewDecision: pr.reviewDecision, reviewers: pr.reviewers,
      mergeable: false, mergeState: pr.mergeState)
    vcsStatus.workroomStatuses[sid] = s
  }
}
