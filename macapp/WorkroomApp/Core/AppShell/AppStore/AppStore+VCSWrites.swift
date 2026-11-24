import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS

/// The VCS write actions the status inspector offers: PR actions and merges through `gh`, and
/// commits with their preflight. Moved out of `AppStore+WorkroomStatus.swift` as is, so that file
/// only reads status. Coupling points: these write into `vcsStatus`'s statuses through its
/// write-side lookups (`canAddress(_:)`, `writeLocation(for:)`, `setPullRequest(_:on:)`) and use its
/// `beginCommit`/`endCommit` bookkeeping and its local and followed refreshes.
extension AppStore {
  /// Whether `target` has anything a commit could record, and none is in flight: the Changes
  /// header's commit button and Room ▸ Commit… both ask this. A followed repository's (#808)
  /// answers from its own status, which is there only while a window follows it.
  func canCommit(_ target: VCSActionTarget?) -> Bool {
    guard let target, let status = vcsStatus.status(for: target), !vcsStatus.isCommitting(target)
    else { return false }
    return !(status.isClean || status.isUnknown)
  }

  /// Open the commit dialog for `target`, when it has something to commit.
  func requestCommit(_ target: VCSActionTarget?) {
    guard let target, canCommit(target), vcsStatus.canAddress(target) else { return }
    modals.pendingCommit = PendingCommit(target: target)
  }

  /// What a local version-control write in the inspector (a commit, the toolbar's fetch, push and
  /// pull) acts on: its workroom or project root, or the repository a terminal's inspector follows
  /// (#808). A followed repository that is a registered row's acts as that row, in place. Nil when
  /// there is no repository to act on: nothing selected, a folder outside a repository, one git
  /// couldn't tell about, a repository this window no longer holds, one whose registration came
  /// back empty, or one the app can't write to.
  var inspectorActionTarget: VCSActionTarget? { inspectorTarget(writingLocally: true) }

  /// What a pull request action in the inspector acts on: `inspectorActionTarget`'s, and a followed
  /// repository the app can't write to as well, since `gh` writes only on GitHub, as the same
  /// repository's registered row offers them (review of #808, finding 6).
  var inspectorPullRequestTarget: VCSActionTarget? { inspectorTarget(writingLocally: false) }

  private func inspectorTarget(writingLocally: Bool) -> VCSActionTarget? {
    switch inspectorSubject {
    case .target(let sid): return .row(sid)
    case .followed(let followed):
      return followedActionTarget(followed, writingLocally: writingLocally)
    case .nothing: return nil
    }
  }

  /// What a write to `followed`'s repository addresses: one this window holds, and, for a local
  /// write, one the app can write to. A registered row's is that row, in place, which writes
  /// through its own work item; any other only once its registration hasn't come back empty (one
  /// still resolving is offered: its write awaits the registration). Commit, the pull request and
  /// the toolbar all ask it, so they can't disagree.
  func followedActionTarget(_ followed: FollowedFolder, writingLocally: Bool) -> VCSActionTarget? {
    guard let repository = followed.repository, let root = heldFollowedRepository,
      root == repository.root
    else { return nil }
    if writingLocally, !repository.isWritable { return nil }
    if let sid = vcsStatus.registeredSidebarID(forCanonicalRoot: root) { return .row(sid) }
    guard !vcsStatus.unregisteredFollowedRoots.contains(root) else { return nil }
    return .followed(root: root)
  }

  /// The repository this window follows, when it is `sid`'s: a registered row followed in place
  /// (#808), which no selection refresh reaches, so its followed lane is re-read after a write.
  func rootFollowedInPlace(_ sid: SidebarID) -> String? {
    guard let held = heldFollowedRepository,
      vcsStatus.registeredSidebarID(forCanonicalRoot: held) == sid
    else { return nil }
    return held
  }

  /// The followed lane a write to `target` changed: a followed repository's own, or a registered
  /// row's this window follows in place. Nil for a row no window here follows.
  func followedRoot(touchedBy target: VCSActionTarget) -> String? {
    target.followedRoot ?? target.sidebarID.flatMap(rootFollowedInPlace)
  }

  /// Run a PR write action on `target`'s PR: a row's, or a followed repository's (#808). `target`
  /// and `number` are captured at the click, so the write goes to the PR the user acted on or is
  /// refused, wherever the terminal has gone since. In fixture mode it optimistically updates the
  /// seeded status instead of spawning `gh`, so the actions menu is exercisable hermetically.
  func performPRAction(_ action: PRAction, number: Int, on target: VCSActionTarget) {
    let title = "Couldn’t \(action.label.lowercased())"
    guard let write = prWrite(on: target, errorTitle: title) else { return }
    performPRWrite(
      write, arguments: action.arguments(number: number), number: number,
      optimistic: { Self.optimisticPR(after: action, $0) }, errorTitle: title)
  }

  /// `performPRAction(_:number:on:)` for a work item the caller built, which need not be the
  /// row's own (a remote location, in tests).
  func performPRAction(
    _ action: PRAction, number: Int, on item: VCSStatusService.StatusWorkItem
  ) {
    let title = "Couldn’t \(action.label.lowercased())"
    guard let write = prWrite(on: item, errorTitle: title) else { return }
    performPRWrite(
      write, arguments: action.arguments(number: number), number: number,
      optimistic: { Self.optimisticPR(after: action, $0) }, errorTitle: title)
  }

  /// Merge `target`'s PR (issue #88), a row's or a followed repository's (#808), with `method`,
  /// captured at the click with its number, as `performPRAction(_:number:on:)` is. The strategy is
  /// a parameter, so it's kept apart from the state-only `PRAction` verbs. In fixture mode it
  /// optimistically flips the PR to merged instead of spawning `gh`.
  func performMerge(_ method: PRMergeMethod, number: Int, on target: VCSActionTarget) {
    let title = "Couldn’t merge pull request"
    guard let write = prWrite(on: target, errorTitle: title) else { return }
    performPRWrite(
      write, arguments: method.arguments(number: number), number: number,
      optimistic: Self.optimisticMergedPR, errorTitle: title)
  }

  /// What one pull request write needs of its target, set up at the click. A row's and a followed
  /// repository's differ only here; `performPRWrite` runs them both.
  private struct PRWrite {
    let target: VCSActionTarget
    /// A row may act with no pull request in its status; a followed repository's must show the one
    /// acted on.
    let requiresShownPR: Bool
    /// A row's GitHub service is built before the optimistic flip, so a routing failure flips
    /// nothing; a followed repository's resolves through its registration when the write runs.
    let prepare: @MainActor () throws -> @MainActor () async throws -> RepositoryGitHub
    /// Whether the status the click saw still stands: the row's work item, or the followed hold.
    let isCurrent: @MainActor () -> Bool
    /// A row's result for a work item that changed is dropped; a followed repository's failure is
    /// still the user's to see.
    let reportsStaleFailure: Bool
  }

  /// `target`'s write, or nil once it is refused (reported, but for a row with no work item).
  private func prWrite(on target: VCSActionTarget, errorTitle: String) -> PRWrite? {
    switch target {
    case .row(let sid):
      guard let item = vcsStatus.selectedStatusWorkItem(for: sid) else { return nil }
      return prWrite(on: item, errorTitle: errorTitle)
    case .followed(let root):
      guard vcsStatus.isFollowing(root) else {
        failPRWrite(errorTitle, FollowedRepositoryGone().localizedDescription, on: target)
        return nil
      }
      let vcsStatus = self.vcsStatus
      let hold = vcsStatus.followedRegistration(of: root)
      return PRWrite(
        target: target, requiresShownPR: true,
        prepare: {
          let resolver = vcsStatus.statusResolver
          return {
            let location = try await vcsStatus.writeLocation(for: target)
            return try RepositoryRouter.shared.registeredGitHub(for: location, resolver: resolver)
          }
        },
        isCurrent: { hold != nil && vcsStatus.followedRegistration(of: root) == hold },
        reportsStaleFailure: true)
    }
  }

  private func prWrite(on item: VCSStatusService.StatusWorkItem, errorTitle: String) -> PRWrite? {
    let target = VCSActionTarget.row(item.sid)
    guard item.permitsGitHubAccess else {
      let host = item.location?.host ?? .local
      failPRWrite(
        errorTitle, RepositoryRoutingError.unavailable(host).localizedDescription, on: target)
      return nil
    }
    let vcsStatus = self.vcsStatus
    return PRWrite(
      target: target, requiresShownPR: false,
      prepare: {
        guard let location = item.location else {
          throw RepositoryRoutingError.registrationRequired
        }
        let github = try RepositoryRouter.shared.registeredGitHub(
          for: location, resolver: vcsStatus.statusResolver)
        return { github }
      },
      isCurrent: { vcsStatus.selectedStatusWorkItem(for: item.sid) == item },
      reportsStaleFailure: false)
  }

  /// The gh-write lifecycle shared by `performPRAction` and `performMerge` (issue #88): refuse a PR
  /// whose number moved on since the click, capture the prior PR to restore on failure, apply the
  /// optimistic update, then — UNLESS in fixture mode, where the optimistic flip is itself the
  /// final result — flip the in-flight flag, resolve the GitHub service for the registered
  /// location (bound to its repository identity), and run the command. On success re-probe for
  /// GitHub's authoritative state; on failure revert the optimistic flip and surface `stderr`. The
  /// status is touched afterwards only while the one the click saw stands: a followed status let go
  /// of is never re-created, and one followed afresh since was re-read anyway.
  ///
  /// Fixture mode applies the optimistic update and stops there, before `prActionInFlight` flips —
  /// fixture-mode tests rely on seeing the optimistic update with no in-flight flag ever set.
  private func performPRWrite(
    _ write: PRWrite, arguments: [String], number: Int,
    optimistic: (PullRequestInfo) -> PullRequestInfo, errorTitle: String
  ) {
    let target = write.target
    let priorPR = vcsStatus.status(for: target)?.pr
    // The PR on screen moved on since the click: never act on a number it no longer shows.
    if priorPR.map({ $0.number != number }) ?? write.requiresShownPR {
      return failPRWrite(errorTitle, Self.pullRequestChanged, on: target)
    }
    // Seeded statuses have no `gh` behind them: the optimistic update below *is* the result.
    guard vcsStatus.probesRepositories else {
      return vcsStatus.setPullRequest(priorPR.map(optimistic), on: target)
    }
    let github: () async throws -> RepositoryGitHub
    do { github = try write.prepare() } catch {
      return failPRWrite(errorTitle, error.localizedDescription, on: target)
    }
    // Flip the PR state immediately so the badge/buttons react the instant the user acts — otherwise
    // nothing visibly changes during the (multi-second) `gh` call + status re-probe, which reads as
    // "the click did nothing". Keep the prior PR to restore if `gh` fails.
    vcsStatus.setPullRequest(priorPR.map(optimistic), on: target)
    prActionInFlight = true
    Task { [weak self] in
      let r: CommandResult
      do {
        r = try await github().run(arguments)
      } catch {
        r = CommandResult(
          stdout: "", stderr: error.localizedDescription, exitCode: 1, timedOut: false)
      }
      guard let self else { return }
      self.prActionInFlight = false
      let current = write.isCurrent()
      guard current || write.reportsStaleFailure else { return }
      if r.ok {
        guard current else { return }
        // Re-probe to replace the optimistic state with GitHub's authoritative one: the selection's
        // for a row, and the followed lane for a followed repository or a row followed in place.
        if target.sidebarID != nil { self.scheduleSelectedStatusRefresh() }
        if let root = self.followedRoot(touchedBy: target) {
          self.vcsStatus.refreshFollowedStatus(root, gitHub: true)
        }
      } else {
        // The command failed — undo the optimistic flip so the UI doesn't lie, then surface stderr.
        if current, let priorPR { self.vcsStatus.setPullRequest(priorPR, on: target) }
        self.failPRWrite(errorTitle, Self.stderrMessage(r), on: target)
      }
    }
  }

  /// A PR the inspector no longer shows: its number moved on between the click and the write.
  private static let pullRequestChanged =
    "That pull request changed since it was shown. Check it and try again."

  /// Report a failed PR write. A followed repository the inspector no longer shows is named, as
  /// the toolbar's dialog names it: gh's stderr often names only `#N` (review of #808, finding 7).
  private func failPRWrite(_ title: String, _ message: String, on target: VCSActionTarget) {
    if let name = target.followedName, target.followedRoot != heldFollowedRepository {
      modals.errorTitle = "\(title) in \(name)"
    } else {
      modals.errorTitle = title
    }
    modals.errorMessage = message
  }

  private static func stderrMessage(_ r: CommandResult) -> String {
    let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return stderr.isEmpty ? "The gh command failed." : stderr
  }

  /// Record a commit for `target`, a row or a followed repository (#808), captured by the caller: a
  /// terminal can `cd` to another repository while a hook runs, and the commit and every refresh
  /// below belong to the repository the sheet was opened for.
  ///
  /// Unlike `performPRAction`, there is **no optimistic update**. A PR action flips a badge whose
  /// authority is remote and slow; a commit rewrites local state the panel reads directly, and
  /// pretending it succeeded would mean showing a clean file list for a commit a hook is still able
  /// to reject. The sheet shows progress instead, and the list changes only once it really has.
  func performCommit(
    _ request: VCSCommitRequest, on target: VCSActionTarget,
    completion: @escaping (VCSCommitResult) -> Void
  ) {
    guard vcsStatus.canAddress(target) else {
      let gone =
        target.sidebarID == nil
        ? FollowedRepositoryGone().localizedDescription : "That workroom is no longer available."
      return completion(.failed(.other(gone)))
    }
    let item = target.sidebarID.flatMap(vcsStatus.selectedStatusWorkItem(for:))
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
          let location = try await self.vcsStatus.writeLocation(for: target)
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
        // (`isCommittingProject`), so the commit's own churn never refreshes the Changes list. A
        // followed repository's lane too, or a registered row's this window follows in place, which
        // is the one that reads it while no workroom is selected.
        if let sid = target.sidebarID {
          vcsStatus.refreshLocalStatus(for: sid, skippingCreatesAndCommits: false)
        }
        if let root = self.followedRoot(touchedBy: target) {
          vcsStatus.refreshFollowedStatus(root, gitHub: false)
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
    on target: VCSActionTarget, files: [ChangedFile],
    completion: @escaping (Result<[String], Error>) -> Void
  ) {
    guard vcsStatus.probesRepositories else { return completion(.success([])) }
    Task {
      do {
        let location = try await self.vcsStatus.writeLocation(for: target)
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
    on target: VCSActionTarget, completion: @escaping (Result<VCSCommitPreflight, Error>) -> Void
  ) {
    Task {
      do {
        let location = try await self.vcsStatus.writeLocation(for: target)
        let writer = try await RepositoryRouter.shared.writer(for: location)
        completion(.success(try await writer.commitPreflight()))
      } catch { completion(.failure(error)) }
    }
  }

  /// Optimistically reflect a PR action in the in-memory status (no `gh`): the badge/state flip
  /// immediately on click, before the command returns. The real path restores the prior PR if `gh`
  /// fails and re-probes on success; fixture mode keeps this as the final result.
  private static func optimisticPR(after action: PRAction, _ pr: PullRequestInfo)
    -> PullRequestInfo
  {
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
    return PullRequestInfo(
      number: pr.number, title: pr.title, state: state, isDraft: draft, url: pr.url,
      reviewDecision: pr.reviewDecision, reviewers: pr.reviewers,
      mergeable: pr.mergeable, mergeState: pr.mergeState)
  }

  /// Optimistically flip the PR to merged (no `gh`): the badge turns purple and the Merge button
  /// disappears the instant the user confirms. `mergeable` is cleared so `canMerge` is false too.
  /// The real path restores the prior PR if `gh` fails and re-probes on success.
  private static func optimisticMergedPR(_ pr: PullRequestInfo) -> PullRequestInfo {
    PullRequestInfo(
      number: pr.number, title: pr.title, state: .merged, isDraft: false, url: pr.url,
      reviewDecision: pr.reviewDecision, reviewers: pr.reviewers,
      mergeable: false, mergeState: pr.mergeState)
  }
}
