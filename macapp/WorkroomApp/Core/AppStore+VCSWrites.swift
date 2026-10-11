import Foundation
import WorkroomDomain

/// The VCS write actions the status inspector offers: PR actions and merges through `gh`, and
/// commits with their preflight. Moved out of `AppStore+WorkroomStatus.swift` as is, so that file
/// only reads status. Coupling points: these write into `workroomStatuses` (optimistically, then
/// from a fresh probe) and use `selectedStatusWorkItem(for:)`, `refreshStatus(for:)` and the
/// `beginWrite`/`endWrite` bookkeeping, which stay with the status code.
extension AppStore {
  /// Run a PR write action (Phase 2b) on the selected workroom's PR: shell to `gh`, refresh the PR
  /// on success, surface `stderr` on failure. In fixture mode it optimistically updates the seeded
  /// status instead of spawning `gh`, so the actions menu is exercisable hermetically. Delegates the
  /// whole lifecycle to `performPRWrite`, shared with `performMerge`.
  func performPRAction(_ action: PRAction, number: Int, on sid: SidebarID) {
    guard let item = selectedStatusWorkItem(for: sid) else { return }
    performPRAction(action, number: number, on: item)
  }

  func performPRAction(_ action: PRAction, number: Int, on item: StatusWorkItem) {
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
  /// `UITestFixture.isActive` must be checked AFTER `applyOptimistic` but BEFORE `prActionInFlight`
  /// flips — fixture-mode tests rely on seeing the optimistic update with no in-flight flag ever set.
  private func performPRWrite(
    arguments: [String], on item: StatusWorkItem,
    applyOptimistic: (SidebarID) -> Void, errorTitle: String
  ) {
    let sid = item.sid
    guard item.permitsGitHubAccess else {
      self.errorTitle = errorTitle
      self.errorMessage =
        RepositoryRoutingError.unavailable(item.location?.host ?? .local).localizedDescription
      return
    }
    let github: RepositoryGitHub?
    if UITestFixture.isActive {
      github = nil
    } else {
      do {
        guard let location = item.location else {
          throw RepositoryRoutingError.registrationRequired
        }
        github = try RepositoryRouter.shared.registeredGitHub(
          for: location, resolver: statusResolver)
      } catch {
        self.errorTitle = errorTitle
        self.errorMessage = error.localizedDescription
        return
      }
    }
    // Flip the PR state immediately so the badge/buttons react the instant the user acts — otherwise
    // nothing visibly changes during the (multi-second) `gh` call + status re-probe, which reads as
    // "the click did nothing". Keep the prior PR to restore if `gh` fails (and in fixture mode, this
    // optimistic update *is* the result — no `gh` to confirm it).
    let priorPR = workroomStatuses[sid]?.pr
    applyOptimistic(sid)
    if UITestFixture.isActive { return }
    prActionInFlight = true
    Task { [weak self] in
      guard let github else { return }
      let r = await github.run(arguments)
      guard let self else { return }
      self.prActionInFlight = false
      guard self.selectedStatusWorkItem(for: sid) == item else { return }
      if r.ok {
        // Re-probe to replace the optimistic state with GitHub's authoritative one.
        self.scheduleSelectedStatusRefresh()
      } else {
        // The command failed — undo the optimistic flip so the UI doesn't lie, then surface stderr.
        if var s = self.workroomStatuses[sid] {
          s.pr = priorPR
          self.workroomStatuses[sid] = s
        }
        self.errorTitle = errorTitle
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
    // Fixture mode swaps the WRITER — `FixtureVCSWriter` rather than spawning git, since the
    // fixture paths aren't real repos and a live write would only ever fail. Only the writer: taking
    // an early return here instead skipped the whole store-side lane (the in-flight marks, the
    // captured-sid refresh), so the one tier that drives this code end to end exercised none of it.
    // `refreshStatus(for:)` already no-ops under the fixture, so the rest is safe to run.
    Task { [weak self] in
      guard let self else { return }
      let root: RepositoryLocation
      let writer: VCSWriting?
      do {
        if UITestFixture.isActive {
          root = try await RepositoryLocation.local(item.projectRoot)
          writer = nil
        } else {
          let location = try await item.resolvedLocation()
          let captured = try await RepositoryRouter.shared.writer(for: location)
          root = try captured.context.requireOwnership()
          writer = captured
        }
      } catch { return completion(.failed(.other(error.localizedDescription))) }
      // Refuse outright rather than queue behind another write (commit/fetch/push/pull, this window
      // or another) on the same project root — see `isWritingProject`'s doc for why queuing into
      // `RepositoryWriteGate` here would risk racing it past the gate's own wedge-detection ceiling.
      guard !isWritingProject(root) else {
        return completion(.failed(.locked(nil)))
      }
      committingTargets.insert(sid)
      committingProjectRoots[root, default: 0] += 1
      beginWrite(projectRoot: root)
      // Captured STRONGLY, not through `self`: `committingProjectRoots`/`writingProjectRoots` live on
      // this shared, cross-window store, and their release below must run even if THIS window's
      // `AppStore` is deallocated before the write finishes (e.g. the window is closed mid-commit). A
      // release gated on `self` staying alive would leak both counters — `writingProjectRoots`
      // permanently, since nothing else ever decrements it, refusing every future write for this
      // project, in every window, until the app restarts.
      let projectStore = self.projectStore
      let result: VCSCommitResult
      if UITestFixture.isActive {
        result = await FixtureVCSWriter().commit(
          path: item.path, projectRoot: root.path, request: request)
      } else {
        do {
          guard let writer else { throw RepositoryRoutingError.registrationRequired }
          result = await writer.commit(request: request)
        } catch {
          result = .failed(.other("\(error)"))
        }
      }
      // Decremented, never cleared: a sibling workroom of the same project can be committing too, and
      // dropping the key would re-open every read lane against a write still in progress.
      let remainingCommits = (projectStore.committingProjectRoots[root] ?? 1) - 1
      if remainingCommits > 0 {
        projectStore.committingProjectRoots[root] = remainingCommits
      } else {
        projectStore.committingProjectRoots.removeValue(forKey: root)
      }
      Self.releaseWrite(projectRoot: root, in: projectStore)
      self.committingTargets.remove(sid)
      switch result {
      case .ok, .committedThenFailed:
        // Refresh by the CAPTURED sid: the watcher lane is suppressed while the commit runs
        // (`isCommittingProject`), so the commit's own churn never refreshes the Changes list.
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
  /// Read-only and ungated. A failed staged-content check is an explicit failure: the sheet must
  /// not authorize a commit when it cannot determine whether staged work would be discarded.
  func stagedContentAtRisk(
    on sid: SidebarID, files: [ChangedFile], completion: @escaping (Result<[String], Error>) -> Void
  ) {
    if UITestFixture.isActive { return completion(.success([])) }
    guard let item = selectedStatusWorkItem(for: sid) else {
      return completion(.failure(RepositoryRoutingError.registrationRequired))
    }
    Task {
      do {
        let location = try await item.resolvedLocation()
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
  /// The fixture is NOT short-circuited here — `CommitSheet` seeds its own values.
  func commitPreflight(
    on sid: SidebarID, completion: @escaping (Result<VCSCommitPreflight, Error>) -> Void
  ) {
    guard let item = selectedStatusWorkItem(for: sid) else {
      return completion(.failure(RepositoryRoutingError.registrationRequired))
    }
    Task {
      do {
        let location = try await item.resolvedLocation()
        let writer = try await RepositoryRouter.shared.writer(for: location)
        completion(.success(try await writer.commitPreflight()))
      } catch { completion(.failure(error)) }
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
  /// `gh` repo context, same optimistic-then-authoritative flow, both via `performPRWrite` — but the
  /// strategy is a parameter, so it's kept separate from the state-only `PRAction` verbs. In fixture
  /// mode it optimistically flips the PR to merged instead of spawning `gh`.
  func performMerge(_ method: PRMergeMethod, number: Int, on sid: SidebarID) {
    guard let item = selectedStatusWorkItem(for: sid) else { return }
    performPRWrite(
      arguments: method.arguments(number: number), on: item,
      applyOptimistic: { self.applyOptimisticMerge(on: $0) },
      errorTitle: "Couldn’t merge pull request")
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
}
