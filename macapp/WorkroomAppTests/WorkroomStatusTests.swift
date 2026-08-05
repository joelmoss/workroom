import Defaults
import XCTest

@testable import Workroom

/// Pure status-model + presentation tests (issue #24): the glyph/label mapping and the
/// aggregate-priority ordering the project-row badge and the badge views depend on.
final class WorkroomStatusTests: XCTestCase {

  // MARK: - isUnknown / isClean (unknown ≠ clean)

  func testUnknownIsNotClean() {
    let s = WorkroomStatus(dirty: nil, failure: .timeout)
    XCTAssertTrue(s.isUnknown)
    XCTAssertFalse(s.isClean)
  }

  func testCleanIsClean() {
    let s = WorkroomStatus(dirty: false)
    XCTAssertFalse(s.isUnknown)
    XCTAssertTrue(s.isClean)
  }

  func testConflictedIsNotClean() {
    let s = WorkroomStatus(dirty: true, conflicted: true)
    XCTAssertFalse(s.isClean)
  }

  // MARK: - aggregateWeight priority: conflicted > dirty > unknown(missing/notRepo) > clean

  func testAggregatePriorityOrdering() {
    let conflicted = WorkroomStatus(dirty: true, conflicted: true)
    let dirty = WorkroomStatus(dirty: true)
    let unknown = WorkroomStatus(dirty: nil, failure: .missingPath)
    let clean = WorkroomStatus(dirty: false)
    let unresolved = WorkroomStatus.unresolved
    XCTAssertGreaterThan(conflicted.aggregateWeight, dirty.aggregateWeight)
    XCTAssertGreaterThan(dirty.aggregateWeight, unknown.aggregateWeight)
    XCTAssertGreaterThan(unknown.aggregateWeight, clean.aggregateWeight)
    XCTAssertEqual(clean.aggregateWeight, unresolved.aggregateWeight)  // both 0 → nothing to show
  }

  // MARK: - VCSStatusPresentation.dot

  func testDotCleanIsNil() {
    XCTAssertNil(VCSStatusPresentation.dot(WorkroomStatus(dirty: false)))
  }

  func testDotDirty() {
    let dot = VCSStatusPresentation.dot(WorkroomStatus(dirty: true))
    XCTAssertEqual(dot?.symbol, "circle.fill")
    XCTAssertEqual(dot?.semantic, .dirty)
  }

  func testDotConflictBeatsDirty() {
    // conflicted + dirty must render the conflict glyph, not the dirty dot.
    let dot = VCSStatusPresentation.dot(WorkroomStatus(dirty: true, conflicted: true))
    XCTAssertEqual(dot?.symbol, "exclamationmark.triangle.fill")
    XCTAssertEqual(dot?.semantic, .conflict)
  }

  func testDotUnknownIsQuestionNeverRed() {
    let dot = VCSStatusPresentation.dot(WorkroomStatus(dirty: nil, failure: .notRepository))
    XCTAssertEqual(dot?.symbol, "questionmark.circle")
    XCTAssertEqual(dot?.semantic, .unknown)  // never .conflict/.dirty → never alarming
  }

  /// The two retryable backend failures must SAY what they are. Both used to arrive as
  /// `.notRepository`, so a busy or out-of-date working copy read as "not a repository" — a wrong
  /// diagnosis for a repo that is fine and will answer on the next refresh. The glyph stays the quiet
  /// unknown one; only the (tooltip / VoiceOver) text differentiates.
  func testDotBusyAndStaleExplainThemselves() {
    let busy = VCSStatusPresentation.dot(WorkroomStatus(dirty: nil, failure: .busy))
    XCTAssertEqual(busy?.symbol, "questionmark.circle")
    XCTAssertEqual(busy?.semantic, .unknown)
    XCTAssertEqual(busy?.accessibility, "status unavailable, repository is busy")

    let stale = VCSStatusPresentation.dot(WorkroomStatus(dirty: nil, failure: .staleWorkingCopy))
    XCTAssertEqual(stale?.accessibility, "status unavailable, working copy is out of date")
    XCTAssertNotEqual(
      stale?.accessibility,
      VCSStatusPresentation.dot(WorkroomStatus(dirty: nil, failure: .notRepository))?.accessibility)
  }

  // MARK: - VCSStatusPresentation.lineCountsHelp (the Changes header's +/- text)

  func testLineCountsHelpNilWithoutADelta() {
    // Only untracked files, or a clean tree: the header shows its status dot instead.
    XCTAssertNil(VCSStatusPresentation.lineCountsHelp(WorkroomStatus(dirty: true)))
    XCTAssertNil(
      VCSStatusPresentation.lineCountsHelp(
        WorkroomStatus(dirty: true, insertions: 0, deletions: 0)))
  }

  func testLineCountsHelpReadsTheDelta() {
    let help = VCSStatusPresentation.lineCountsHelp(
      WorkroomStatus(dirty: true, insertions: 12, deletions: 4))
    XCTAssertEqual(help, "12 insertions, 4 deletions")
  }

  /// A conflicted working copy's counts INCLUDE its materialized conflict markers (jj, git and our own
  /// changeset header all count them), so a one-line conflict can read as many. The number is left
  /// alone and explained — this string is the whole reason the count is allowed to stay inclusive, so
  /// it has to name the markers, not just say "conflicted".
  func testLineCountsHelpNamesTheConflictMarkers() {
    let help = VCSStatusPresentation.lineCountsHelp(
      WorkroomStatus(dirty: true, conflicted: true, insertions: 30, deletions: 2))
    XCTAssertEqual(help, "conflicted — counts include conflict markers, 30 insertions, 2 deletions")
    XCTAssertTrue(
      help?.contains("conflict markers") == true, "the marker caveat must be spelled out")
  }

  /// A busy/stale row must count toward the project aggregate the same way the other probe failures
  /// do — unknown outranks clean, dirty outranks unknown.
  func testAggregateWeightCoversTheNewFailures() {
    let dirty = WorkroomStatus(dirty: true)
    let clean = WorkroomStatus(dirty: false)
    for failure in [VCSStatusFailure.busy, .staleWorkingCopy] {
      let unknown = WorkroomStatus(dirty: nil, failure: failure)
      XCTAssertGreaterThan(dirty.aggregateWeight, unknown.aggregateWeight, "\(failure)")
      XCTAssertGreaterThan(unknown.aggregateWeight, clean.aggregateWeight, "\(failure)")
    }
  }

  // MARK: - VCSStatusPresentation.ci

  func testCIGlyphs() {
    XCTAssertNil(VCSStatusPresentation.ci(WorkroomStatus(dirty: false, ci: nil)))
    XCTAssertEqual(
      VCSStatusPresentation.ci(WorkroomStatus(dirty: false, ci: .passing))?.symbol,
      "checkmark.circle.fill")
    XCTAssertEqual(
      VCSStatusPresentation.ci(WorkroomStatus(dirty: false, ci: .failing))?.symbol,
      "xmark.octagon.fill")
    XCTAssertEqual(
      VCSStatusPresentation.ci(WorkroomStatus(dirty: false, ci: .running))?.symbol,
      "clock.arrow.circlepath")
    let neutral = VCSStatusPresentation.ci(WorkroomStatus(dirty: false, ci: .neutral))
    XCTAssertEqual(neutral?.symbol, "minus.circle")
    XCTAssertEqual(neutral?.semantic, .neutral)
  }

  // MARK: - composed accessibility label

  func testAccessibilityLabelComposition() {
    let s = WorkroomStatus(dirty: true, ci: .failing)
    XCTAssertEqual(VCSStatusPresentation.accessibilityLabel(s), "dirty, CI failing")
  }

  func testAccessibilityLabelCleanIsEmpty() {
    XCTAssertEqual(VCSStatusPresentation.accessibilityLabel(WorkroomStatus(dirty: false)), "clean")
  }

  func testAccessibilityLabelUnknown() {
    let s = WorkroomStatus(dirty: nil, failure: .timeout)
    XCTAssertEqual(VCSStatusPresentation.accessibilityLabel(s), "status unavailable, timed out")
  }

  // MARK: - AppStore.aggregateStatus (project-row badge: worst child wins)

  @MainActor
  func testAggregateStatusPicksWorstChild() {
    let store = AppStore()
    let project = Project(
      path: "/p", vcs: "git",
      workrooms: [
        Workroom(name: "a", path: "/p/a", vcsName: "git", warnings: []),
        Workroom(name: "b", path: "/p/b", vcsName: "git", warnings: []),
      ])
    store.projects = [project]

    // clean + dirty → dirty wins
    store.workroomStatuses[.workroom(project: "/p", name: "a")] = WorkroomStatus(dirty: false)
    store.workroomStatuses[.workroom(project: "/p", name: "b")] = WorkroomStatus(dirty: true)
    XCTAssertEqual(store.aggregateStatus(forProject: "/p")?.dirty, true)

    // a conflicted root outranks a dirty workroom
    store.workroomStatuses[.root(project: "/p")] = WorkroomStatus(dirty: true, conflicted: true)
    XCTAssertEqual(store.aggregateStatus(forProject: "/p")?.conflicted, true)

    // everything clean → nothing to show
    store.workroomStatuses[.root(project: "/p")] = WorkroomStatus(dirty: false)
    store.workroomStatuses[.workroom(project: "/p", name: "b")] = WorkroomStatus(dirty: false)
    XCTAssertNil(store.aggregateStatus(forProject: "/p"))
  }

  /// Regression: a workroom's status work item must carry the project's VCS *type* (`p.vcs`), not
  /// the workroom's `vcsName` — which is the branch/workspace name (`workroom/<name>`), not a type.
  /// Passing the branch name made `resolveLocal` fall through to `.notRepository`, so every (jj or
  /// git) workroom's Changes panel showed "not a repository" with a "detached" header.
  @MainActor
  func testStatusWorkItemsUseProjectVCSTypeForWorkrooms() {
    let store = AppStore()
    store.projects = [
      Project(
        path: "/p", vcs: "jj",
        workrooms: [
          Workroom(name: "feat", path: "/p/feat", vcsName: "workroom/feat", warnings: [])
        ])
    ]
    let items = store.statusWorkItems()
    let workroomItem = items.first { $0.sid == .workroom(project: "/p", name: "feat") }
    XCTAssertEqual(workroomItem?.vcs, "jj")  // the project's type, NOT "workroom/feat"
    // Must be the PROJECT's path ("/p"), not the workroom's own path ("/p/feat") — this is the
    // JJSnapshotGate key, so a copy-paste regression here would silently defeat cross-workroom
    // jj snapshot serialization.
    XCTAssertEqual(workroomItem?.projectRoot, "/p")
    let rootItem = items.first { $0.sid == .root(project: "/p") }
    XCTAssertEqual(rootItem?.vcs, "jj")
  }

  // MARK: - mergeLocalStatus carries the full local probe forward

  /// Regression: `mergeLocalStatus` once copied only a subset of the fresh fields and dropped the
  /// jj head (refs/description/change-id/commit-id), so a jj repo's Changes header fell back to
  /// the git branch label ("main"). The merge must carry every local-probe field.
  @MainActor
  func testMergeLocalStatusCarriesJJHeadFields() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "jj", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    let fresh = WorkroomStatus(
      dirty: true,
      changedFiles: [ChangedFile(path: "a.rb", change: .added)],
      branchForCI: nil,
      jjWorkingCopy: JJCommitChanges(
        changeID: "pw", commitID: "7d74470b", refs: ["mybook"], description: "feat: x",
        files: [ChangedFile(path: "a.rb", change: .added)]))
    store.mergeLocalStatus(fresh, into: sid)
    let stored = store.workroomStatuses[sid]
    XCTAssertEqual(stored?.dirty, true)
    XCTAssertEqual(stored?.jjWorkingCopy?.refs, ["mybook"])
    XCTAssertEqual(stored?.jjWorkingCopy?.description, "feat: x")
    XCTAssertEqual(stored?.jjWorkingCopy?.changeID, "pw")
    XCTAssertEqual(stored?.jjWorkingCopy?.commitID, "7d74470b")
  }

  /// The merge preserves the separately-resolved CI fields (a fast local refresh must never wipe
  /// the slower CI badge), while a jj→git switch clears the now-stale jj head.
  @MainActor
  func testMergeLocalStatusPreservesCIAndClearsStaleJJOnGitResult() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "jj", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    // Seed: a prior jj snapshot with CI already resolved.
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: true, ci: .passing,
      jjWorkingCopy: JJCommitChanges(changeID: "aaaa", refs: ["old"]))
    // A fresh GIT probe (no jj head) lands.
    let gitFresh = WorkroomStatus(dirty: false, branchForCI: "main")
    store.mergeLocalStatus(gitFresh, into: sid)
    let stored = store.workroomStatuses[sid]
    XCTAssertEqual(stored?.ci, .passing)  // CI preserved across the local refresh
    XCTAssertEqual(stored?.branchForCI, "main")
    XCTAssertNil(stored?.jjWorkingCopy)  // stale jj working copy cleared
  }

  // MARK: - Inspector layout (global, persisted to Defaults)

  /// Section collapse state lives on the store (so the `.inspector` content re-renders) and is
  /// GLOBAL — one layout shared across all workrooms, persisted to `inspectorLayout`. Switching
  /// workrooms changes only the inspector's content, never its section collapse.
  @MainActor
  func testInspectorCollapseIsGlobalAcrossWorkrooms() {
    let original = Defaults[.inspectorLayout]
    defer { Defaults[.inspectorLayout] = original }
    Defaults[.inspectorLayout] = .default

    let store = AppStore()
    let a = SidebarID.workroom(project: "/p", name: "a")
    let b = SidebarID.workroom(project: "/p", name: "b")

    store.selectedTargetID = a
    store.changesSectionCollapsed = true
    store.filesSectionCollapsed = true

    // Switching to a different workroom must NOT change the (global) section collapse.
    store.selectedTargetID = b
    XCTAssertTrue(
      store.changesSectionCollapsed, "collapse is global — unchanged by a workroom switch")
    XCTAssertTrue(store.filesSectionCollapsed)

    // …and back: still exactly as left.
    store.selectedTargetID = a
    XCTAssertTrue(store.changesSectionCollapsed)
    XCTAssertTrue(store.filesSectionCollapsed)
    XCTAssertFalse(store.prSectionCollapsed)
  }

  /// Pane size weights (set by a divider drag) are global too: a workroom switch doesn't change
  /// them, and the change persists to `inspectorLayout`.
  @MainActor
  func testInspectorSizeWeightsAreGlobalAcrossWorkrooms() {
    let original = Defaults[.inspectorLayout]
    defer { Defaults[.inspectorLayout] = original }
    Defaults[.inspectorLayout] = .default

    let store = AppStore()
    let a = SidebarID.workroom(project: "/p", name: "a")
    let b = SidebarID.workroom(project: "/p", name: "b")

    store.selectedTargetID = a
    store.updateInspectorSizeWeights([300, 100, 200, 150])

    store.selectedTargetID = b
    XCTAssertEqual(
      store.inspectorSizeWeights, [300, 100, 200, 150],
      "weights are global — a workroom switch does not reset them")
    XCTAssertEqual(
      Defaults[.inspectorLayout].weights, [300, 100, 200, 150], "and are persisted globally")
  }

  /// A fresh store hydrates its live collapse/size from the persisted global layout at launch. Each
  /// flag is asserted against its OWN `storeIndex` slot — History sits at 3 (appended last so the
  /// changes/files/pullRequest indices stayed stable), and it's the slot a mis-mapped load would
  /// silently swap, since the vector is four bools with no names in it.
  @MainActor
  func testInspectorLayoutHydratesFromGlobalStateAtLaunch() {
    let original = Defaults[.inspectorLayout]
    defer { Defaults[.inspectorLayout] = original }
    Defaults[.inspectorLayout] = InspectorPaneState(
      collapsed: [true, false, true, true], weights: [300, 100, 200, 150])

    let store = AppStore()
    XCTAssertTrue(store.changesSectionCollapsed)
    XCTAssertFalse(store.filesSectionCollapsed)
    XCTAssertTrue(store.prSectionCollapsed)
    XCTAssertTrue(store.historySectionCollapsed)
    XCTAssertEqual(store.inspectorSizeWeights, [300, 100, 200, 150])
  }

  /// …and the write side round-trips to the same slot. Asserted through `storeIndex` rather than a
  /// literal 3 so the test follows the canonical order instead of re-encoding it: a reorder of
  /// `InspectorSectionKind.allCases` then fails the *load* test (which pins the literal vector)
  /// rather than passing both by moving in lockstep with the bug.
  @MainActor
  func testHistoryCollapsePersistsToItsOwnSlot() {
    let original = Defaults[.inspectorLayout]
    defer { Defaults[.inspectorLayout] = original }
    Defaults[.inspectorLayout] = .default

    let store = AppStore()
    store.historySectionCollapsed = true

    let stored = Defaults[.inspectorLayout].collapsed
    XCTAssertEqual(stored.count, InspectorSectionKind.allCases.count)
    XCTAssertTrue(stored[InspectorSectionKind.history.storeIndex])
    XCTAssertFalse(
      stored[InspectorSectionKind.pullRequest.storeIndex],
      "collapsing History must not touch its neighbour's slot")
  }

  // MARK: - PRPresentation (Phase 2 pull-request badge)

  private func pr(_ state: PullRequestInfo.State, draft: Bool = false) -> PullRequestInfo {
    PullRequestInfo(
      number: 1, title: "t", state: state, isDraft: draft, url: "u", reviewDecision: nil,
      reviewers: [])
  }

  func testPRBadgeStates() {
    XCTAssertEqual(PRPresentation.badge(pr(.open)).semantic, .open)
    XCTAssertEqual(PRPresentation.badge(pr(.open)).label, "Open")
    // a draft is still OPEN, but the badge surfaces "Draft" — the more useful signal
    XCTAssertEqual(PRPresentation.badge(pr(.open, draft: true)).semantic, .draft)
    XCTAssertEqual(PRPresentation.badge(pr(.open, draft: true)).label, "Draft")
    XCTAssertEqual(PRPresentation.badge(pr(.merged)).semantic, .merged)
    XCTAssertEqual(PRPresentation.badge(pr(.closed)).semantic, .closed)
  }

  func testPRReviewLabel() {
    XCTAssertEqual(PRPresentation.reviewLabel(.approved), "Approved")
    XCTAssertEqual(PRPresentation.reviewLabel(.changesRequested), "Changes requested")
    XCTAssertEqual(PRPresentation.reviewLabel(.reviewRequired), "Review required")
    XCTAssertNil(PRPresentation.reviewLabel(nil))
  }

  // MARK: - PRPresentation.reviewers (issue #52: per-reviewer rows)

  private func prWithReviewers(_ reviewers: [Reviewer]) -> PullRequestInfo {
    PullRequestInfo(
      number: 1, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: nil,
      reviewers: reviewers)
  }

  func testReviewersEmpty() {
    XCTAssertTrue(PRPresentation.reviewers(prWithReviewers([])).isEmpty)
  }

  func testReviewersStateMapping() {
    let badges = PRPresentation.reviewers(
      prWithReviewers([
        Reviewer(identity: .user(login: "a"), state: .approved),
        Reviewer(identity: .user(login: "b"), state: .changesRequested),
        Reviewer(identity: .user(login: "c"), state: .commented),
        Reviewer(identity: .user(login: "d"), state: .dismissed),
        Reviewer(identity: .user(login: "e"), state: .requested),
      ]))
    func badge(_ login: String) -> PRPresentation.ReviewerBadge {
      badges.first { $0.id == "user:\(login)" }!
    }
    XCTAssertEqual(badge("a").symbol, "checkmark.circle.fill")
    XCTAssertEqual(badge("a").semantic, .approved)
    XCTAssertEqual(badge("a").stateLabel, "approved")
    XCTAssertEqual(badge("b").symbol, "xmark.circle.fill")
    XCTAssertEqual(badge("b").semantic, .changesRequested)
    XCTAssertEqual(badge("b").stateLabel, "changes requested")
    XCTAssertEqual(badge("c").symbol, "text.bubble")
    XCTAssertEqual(badge("c").stateLabel, "commented")
    XCTAssertEqual(badge("d").symbol, "minus.circle")
    XCTAssertEqual(badge("d").stateLabel, "dismissed")
    XCTAssertEqual(badge("e").symbol, "clock.arrow.circlepath")
    XCTAssertEqual(badge("e").stateLabel, "review requested")  // human pending
    XCTAssertEqual(badge("a").accessibility, "a approved")
  }

  /// Sort: changes-requested → requested → commented → approved → dismissed, then id A–Z.
  func testReviewersSortOrder() {
    let badges = PRPresentation.reviewers(
      prWithReviewers([
        Reviewer(identity: .user(login: "z"), state: .approved),
        Reviewer(identity: .user(login: "a"), state: .dismissed),
        Reviewer(identity: .user(login: "m"), state: .changesRequested),
        Reviewer(identity: .user(login: "n"), state: .requested),
        Reviewer(identity: .user(login: "p"), state: .commented),
      ]))
    XCTAssertEqual(badges.map(\.id), ["user:m", "user:n", "user:p", "user:z", "user:a"])
  }

  func testReviewersSortTieBrokenByID() {
    let badges = PRPresentation.reviewers(
      prWithReviewers([
        Reviewer(identity: .user(login: "bob"), state: .approved),
        Reviewer(identity: .user(login: "amy"), state: .approved),
      ]))
    XCTAssertEqual(badges.map(\.id), ["user:amy", "user:bob"])
  }

  func testReviewersBotLabelAndName() {
    let copilot = PRPresentation.reviewers(
      prWithReviewers([
        Reviewer(identity: .user(login: "copilot-pull-request-reviewer"), state: .requested)
      ])
    ).first!
    XCTAssertEqual(copilot.displayName, "Copilot")
    XCTAssertEqual(copilot.stateLabel, "in progress")  // bot pending → in progress
    XCTAssertEqual(copilot.accessibility, "Copilot in progress")

    let appBot = PRPresentation.reviewers(
      prWithReviewers([
        Reviewer(identity: .user(login: "dependabot[bot]"), state: .requested)
      ])
    ).first!
    XCTAssertEqual(appBot.displayName, "dependabot")
    XCTAssertEqual(appBot.stateLabel, "in progress")
  }

  func testReviewersTeamDisplay() {
    let team = PRPresentation.reviewers(
      prWithReviewers([Reviewer(identity: .team(slug: "platform"), state: .requested)])
    ).first!
    XCTAssertEqual(team.id, "team:platform")
    XCTAssertEqual(team.displayName, "platform")
    XCTAssertEqual(team.stateLabel, "review requested")  // teams are non-bot
  }

  /// A team slug and a user login sharing a string must NOT collide into one row.
  func testReviewerIdentityNoCollision() {
    let badges = PRPresentation.reviewers(
      prWithReviewers([
        Reviewer(identity: .user(login: "octo"), state: .approved),
        Reviewer(identity: .team(slug: "octo"), state: .requested),
      ]))
    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(Set(badges.map(\.id)), ["user:octo", "team:octo"])
  }

  /// A local refresh must preserve the separately-probed PR (like CI) — mergeLocalStatus must not
  /// drop it.
  @MainActor
  func testMergeLocalStatusPreservesPR() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: true,
      pr: PullRequestInfo(
        number: 5, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: .approved,
        reviewers: [Reviewer(identity: .user(login: "iainad"), state: .approved)]))
    store.mergeLocalStatus(WorkroomStatus(dirty: false, branchForCI: "main"), into: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.pr?.number, 5)  // PR survives the local refresh
    XCTAssertEqual(store.workroomStatuses[sid]?.pr?.reviewers.count, 1)  // …with its reviewers
  }

  /// The deleted-mid-sweep guard: a status sweep captures its work-list up front, so a workroom
  /// can be deleted before its (slow) probe lands. The merge must NOT write a ghost entry for a
  /// sid that no longer maps to a live project/workroom.
  @MainActor
  func testMergeLocalStatusSkipsDeletedTarget() {
    let store = AppStore()
    store.projects = []  // the project the sweep captured has since been deleted
    let sid = SidebarID.root(project: "/gone")
    store.mergeLocalStatus(WorkroomStatus(dirty: true, branchForCI: "main"), into: sid)
    XCTAssertNil(store.workroomStatuses[sid])  // no ghost entry created
  }

  // MARK: - PRAction (Phase 2b: gh command mapping + state availability)

  func testPRActionArguments() {
    XCTAssertEqual(PRAction.markReady.arguments(number: 7), ["pr", "ready", "7"])
    XCTAssertEqual(PRAction.convertToDraft.arguments(number: 7), ["pr", "ready", "7", "--undo"])
    XCTAssertEqual(PRAction.close.arguments(number: 7), ["pr", "close", "7"])
    XCTAssertEqual(PRAction.reopen.arguments(number: 7), ["pr", "reopen", "7"])
  }

  func testPRActionCloseConfirms() {
    XCTAssertTrue(PRAction.close.needsConfirmation)
    XCTAssertTrue(PRAction.close.isDestructive)
    XCTAssertFalse(PRAction.markReady.needsConfirmation)
    XCTAssertFalse(PRAction.reopen.needsConfirmation)
  }

  func testPRActionAvailability() {
    func pr(_ state: PullRequestInfo.State, draft: Bool = false) -> PullRequestInfo {
      PullRequestInfo(
        number: 1, title: "t", state: state, isDraft: draft, url: "u", reviewDecision: nil,
        reviewers: [])
    }
    XCTAssertEqual(PRAction.available(for: pr(.open)), [.convertToDraft, .close])
    XCTAssertEqual(PRAction.available(for: pr(.open, draft: true)), [.markReady, .close])
    XCTAssertEqual(PRAction.available(for: pr(.closed)), [.reopen])
    XCTAssertEqual(PRAction.available(for: pr(.merged)), [])  // nothing to do on a merged PR
  }

  // MARK: - PRMergeMethod (issue #88: split Merge button)

  func testPRMergeMethodLabels() {
    // The button says just "Merge" for a merge commit; the dropdown item spells it out.
    XCTAssertEqual(PRMergeMethod.merge.buttonLabel, "Merge")
    XCTAssertEqual(PRMergeMethod.merge.menuLabel, "Create a merge commit")
    XCTAssertEqual(PRMergeMethod.squash.buttonLabel, "Squash and merge")
    XCTAssertEqual(PRMergeMethod.squash.menuLabel, "Squash and merge")
    XCTAssertEqual(PRMergeMethod.rebase.buttonLabel, "Rebase and merge")
    XCTAssertEqual(PRMergeMethod.rebase.menuLabel, "Rebase and merge")
  }

  func testPRMergeMethodArguments() {
    XCTAssertEqual(PRMergeMethod.merge.arguments(number: 42), ["pr", "merge", "42", "--merge"])
    XCTAssertEqual(PRMergeMethod.squash.arguments(number: 7), ["pr", "merge", "7", "--squash"])
    XCTAssertEqual(PRMergeMethod.rebase.arguments(number: 9), ["pr", "merge", "9", "--rebase"])
  }

  // MARK: - PullRequestInfo.canMerge (issue #88)

  private func mergePR(
    _ state: PullRequestInfo.State = .open, draft: Bool = false, mergeable: Bool?,
    mergeState: PullRequestInfo.MergeState?
  ) -> PullRequestInfo {
    PullRequestInfo(
      number: 1, title: "t", state: state, isDraft: draft, url: "u", reviewDecision: nil,
      reviewers: [], mergeable: mergeable, mergeState: mergeState)
  }

  func testCanMergeCleanMergeable() {
    XCTAssertTrue(mergePR(mergeable: true, mergeState: .clean).canMerge)
    // GitHub still enables the button for unstable (non-required check failing), has-hooks, behind.
    XCTAssertTrue(mergePR(mergeable: true, mergeState: .unstable).canMerge)
    XCTAssertTrue(mergePR(mergeable: true, mergeState: .hasHooks).canMerge)
    XCTAssertTrue(mergePR(mergeable: true, mergeState: .behind).canMerge)
  }

  func testCanMergeBlockedStatesHideButton() {
    // Blocked by branch protection, conflicts (dirty), a draft, or GitHub still computing.
    XCTAssertFalse(mergePR(mergeable: true, mergeState: .blocked).canMerge)
    XCTAssertFalse(mergePR(mergeable: false, mergeState: .dirty).canMerge)
    XCTAssertFalse(mergePR(mergeable: true, mergeState: .unknown).canMerge)
    XCTAssertFalse(mergePR(mergeable: true, mergeState: nil).canMerge)  // not probed
    XCTAssertFalse(mergePR(mergeable: nil, mergeState: .clean).canMerge)  // mergeability unknown
  }

  func testCanMergeRequiresOpenNonDraft() {
    XCTAssertFalse(mergePR(.open, draft: true, mergeable: true, mergeState: .clean).canMerge)
    XCTAssertFalse(mergePR(.merged, mergeable: true, mergeState: .clean).canMerge)
    XCTAssertFalse(mergePR(.closed, mergeable: true, mergeState: .clean).canMerge)
  }

  // MARK: - ChangesPanel.splitPath (filename + dimmed directory rendering)

  func testSplitPath() {
    // root-level file → no directory
    XCTAssertEqual(ChangesPanel.splitPath(".gitignore").dir, "")
    XCTAssertEqual(ChangesPanel.splitPath(".gitignore").name, ".gitignore")
    // nested path → directory is everything before the last slash
    let nested = ChangesPanel.splitPath("app/controllers/mcp/server_controller.rb")
    XCTAssertEqual(nested.dir, "app/controllers/mcp")
    XCTAssertEqual(nested.name, "server_controller.rb")
    // single directory
    let single = ChangesPanel.splitPath("config/routes.rb")
    XCTAssertEqual(single.dir, "config")
    XCTAssertEqual(single.name, "routes.rb")
  }

  // MARK: - PRPresentation.checks / checksSummary (issue #75: per-check rows)

  private func check(
    _ name: String, _ state: CICheck.State, workflow: String? = nil, link: String? = nil
  ) -> CICheck {
    CICheck(name: name, state: state, workflow: workflow, link: link)
  }

  func testChecksEmpty() {
    XCTAssertTrue(PRPresentation.checks([]).isEmpty)
    XCTAssertNil(PRPresentation.checksSummary([]))
  }

  func testChecksStateMapping() {
    let badges = PRPresentation.checks([
      check("a", .passing), check("b", .failing), check("c", .pending),
      check("d", .skipped), check("e", .cancelled),
    ])
    func badge(_ n: String) -> PRPresentation.CheckBadge { badges.first { $0.name == n }! }
    XCTAssertEqual(badge("a").symbol, "checkmark.circle.fill")
    XCTAssertEqual(badge("a").semantic, .passing)
    XCTAssertEqual(badge("a").stateLabel, "passing")
    XCTAssertEqual(badge("b").symbol, "xmark.octagon.fill")
    XCTAssertEqual(badge("b").semantic, .failing)
    XCTAssertEqual(badge("b").stateLabel, "failing")
    XCTAssertEqual(badge("c").symbol, "clock.arrow.circlepath")
    XCTAssertEqual(badge("c").stateLabel, "running")
    XCTAssertEqual(badge("d").symbol, "minus.circle")
    XCTAssertEqual(badge("d").stateLabel, "skipped")
    XCTAssertEqual(badge("e").symbol, "minus.circle")
    XCTAssertEqual(badge("e").stateLabel, "cancelled")
    XCTAssertEqual(badge("a").accessibility, "a passing")
  }

  /// Sort: failing → pending → passing → skipped → cancelled; within a band, by workflow then name.
  func testChecksSortBySeverityThenWorkflowThenName() {
    let badges = PRPresentation.checks([
      check("build", .passing, workflow: "ci"),
      check("test-b", .failing, workflow: "ci"),
      check("test-a", .failing, workflow: "ci"),
      check("deploy", .pending, workflow: "cd"),
      check("lint", .passing, workflow: "ci"),
    ])
    XCTAssertEqual(badges.map(\.name), ["test-a", "test-b", "deploy", "build", "lint"])
  }

  /// Within a severity band, same-workflow jobs group together (workflow ordered before name).
  func testChecksSortGroupsByWorkflow() {
    let badges = PRPresentation.checks([
      check("z-job", .passing, workflow: "zoo"),
      check("a-job", .passing, workflow: "zoo"),
      check("m-job", .passing, workflow: "apple"),
    ])
    XCTAssertEqual(badges.map(\.name), ["m-job", "a-job", "z-job"])
  }

  /// Link passthrough drives row tappability: a non-empty link survives, nil stays nil.
  func testChecksLinkPassthrough() {
    let badges = PRPresentation.checks([
      check("a", .passing, link: "https://x/a"), check("b", .passing, link: nil),
    ])
    XCTAssertEqual(badges.first { $0.name == "a" }?.link, "https://x/a")
    XCTAssertNil(badges.first { $0.name == "b" }?.link)
  }

  func testChecksSummaryPrecedence() {
    // fail dominates everything
    XCTAssertEqual(
      PRPresentation.checksSummary([
        check("a", .passing), check("b", .failing), check("c", .pending),
      ])?
      .semantic, .ciFail)
    // pending over passing
    XCTAssertEqual(
      PRPresentation.checksSummary([check("a", .passing), check("b", .pending)])?.semantic,
      .ciRunning)
    // passing over neutral
    XCTAssertEqual(
      PRPresentation.checksSummary([check("a", .passing), check("b", .skipped)])?.semantic, .ciPass)
    // neutral only
    XCTAssertEqual(
      PRPresentation.checksSummary([check("a", .skipped), check("b", .cancelled)])?.semantic,
      .neutral)
  }

  /// `isFailing` (issue #77, the red header number badge): once checks are loaded, the per-check
  /// list is authoritative; before then it falls back to the branch CI aggregate.
  func testIsFailing() {
    // checks loaded + a failing one → failing (the aggregate is ignored)
    XCTAssertTrue(
      PRPresentation.isFailing(
        WorkroomStatus(ci: .passing, checks: [check("a", .failing)], checksCheckedAt: .distantPast))
    )
    // checks loaded, none failing → not failing even if the (stale) aggregate says failing
    XCTAssertFalse(
      PRPresentation.isFailing(
        WorkroomStatus(ci: .failing, checks: [check("a", .passing)], checksCheckedAt: .distantPast))
    )
    // checks loaded but empty → not failing
    XCTAssertFalse(
      PRPresentation.isFailing(WorkroomStatus(checks: [], checksCheckedAt: .distantPast)))
    // checks not yet loaded → fall back to the branch CI aggregate
    XCTAssertTrue(PRPresentation.isFailing(WorkroomStatus(ci: .failing)))
    XCTAssertFalse(PRPresentation.isFailing(WorkroomStatus(ci: .passing)))
    XCTAssertFalse(PRPresentation.isFailing(WorkroomStatus()))
  }

  // MARK: - applyChecksStatus + checks lifecycle (issue #75)

  @MainActor
  func testApplyChecksStatusListAbsentKeepPrior() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(dirty: false)

    // .list → rows set + loaded marker stamped
    store.applyChecksStatus(.list([check("a", .passing)]), to: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.checks?.count, 1)
    XCTAssertNotNil(store.workroomStatuses[sid]?.checksCheckedAt)

    // .absent → loaded-empty ([]), NOT nil — so the panel won't fall back to the run-list aggregate
    store.applyChecksStatus(.absent, to: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.checks, [])
    XCTAssertNotNil(store.workroomStatuses[sid]?.checksCheckedAt)

    // .keepPrior after a prior load → keeps the last good list (doesn't blank)
    store.applyChecksStatus(.list([check("z", .failing)]), to: sid)
    store.applyChecksStatus(.keepPrior, to: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.checks?.map(\.name), ["z"])
  }

  /// keepPrior on a first-ever probe (never loaded) leaves the marker nil so the next probe retries.
  @MainActor
  func testApplyChecksStatusKeepPriorFirstProbeStaysUnloaded() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(dirty: false)
    store.applyChecksStatus(.keepPrior, to: sid)
    XCTAssertNil(store.workroomStatuses[sid]?.checks)
    XCTAssertNil(store.workroomStatuses[sid]?.checksCheckedAt)
  }

  /// REGRESSION (issue #75): selecting a row whose PR number changed must drop the old PR's checks
  /// so they can't render under the new PR until `resolveChecks` refills them.
  @MainActor
  func testApplyPRStatusClearsChecksOnPRNumberChange() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: false,
      pr: PullRequestInfo(
        number: 5, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: nil,
        reviewers: []),
      checks: [check("old", .passing)])
    store.workroomStatuses[sid]?.checksCheckedAt = Date()
    store.applyPRStatus(
      .info(
        PullRequestInfo(
          number: 9, title: "t2", state: .open, isDraft: false, url: "u2", reviewDecision: nil,
          reviewers: [])), to: sid)
    XCTAssertNil(store.workroomStatuses[sid]?.checks)
    XCTAssertNil(store.workroomStatuses[sid]?.checksCheckedAt)
  }

  /// The same PR number (e.g. the raw→enriched re-apply) keeps the checks.
  @MainActor
  func testApplyPRStatusKeepsChecksOnSamePRNumber() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: false,
      pr: PullRequestInfo(
        number: 5, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: nil,
        reviewers: []),
      checks: [check("keep", .passing)])
    store.workroomStatuses[sid]?.checksCheckedAt = Date()
    store.applyPRStatus(
      .info(
        PullRequestInfo(
          number: 5, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: .approved,
          reviewers: [Reviewer(identity: .user(login: "a"), state: .approved)])), to: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.checks?.map(\.name), ["keep"])
  }

  /// REGRESSION (issue #75): a disappearing PR (.absent) must clear checks — `resolveChecks` won't
  /// run without a PR, so the clearing has to happen on the PR path.
  @MainActor
  func testApplyPRStatusAbsentClearsChecks() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: false,
      pr: PullRequestInfo(
        number: 5, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: nil,
        reviewers: []),
      checks: [check("old", .passing)])
    store.workroomStatuses[sid]?.checksCheckedAt = Date()
    store.applyPRStatus(.absent, to: sid)
    XCTAssertNil(store.workroomStatuses[sid]?.pr)
    XCTAssertNil(store.workroomStatuses[sid]?.checks)
    XCTAssertNil(store.workroomStatuses[sid]?.checksCheckedAt)
  }

  // MARK: - performPRAction optimistic update + revert-on-failure (issue #77 follow-up)

  /// A PR write action flips the PR state immediately (so the badge/buttons react on click), then —
  /// when the `gh` command fails — reverts to the prior state and surfaces the error, so the UI
  /// never lies about a change that didn't land.
  @MainActor
  func testPerformPRActionRevertsOnFailure() async {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    store.statusResolver = WorkroomStatusResolver(
      runner: StubPRRunner { _, _ in
        CommandResult(stdout: "", stderr: "pr already ready", exitCode: 1, timedOut: false)
      })
    let sid = SidebarID.root(project: "/p")
    let draft = PullRequestInfo(
      number: 5, title: "t", state: .open, isDraft: true, url: "u", reviewDecision: nil,
      reviewers: [])
    store.workroomStatuses[sid] = WorkroomStatus(dirty: false, pr: draft)

    store.performPRAction(.markReady, number: 5, on: sid)
    // Optimistic: the draft flag is cleared the instant the action is invoked, before `gh` returns.
    XCTAssertEqual(store.workroomStatuses[sid]?.pr?.isDraft, false)
    XCTAssertTrue(store.prActionInFlight)

    await waitUntilIdle(store)

    // gh failed → reverted to the original draft, with the error surfaced.
    XCTAssertEqual(store.workroomStatuses[sid]?.pr, draft)
    XCTAssertEqual(store.errorTitle, "Couldn\u{2019}t ready for review")
    XCTAssertEqual(store.errorMessage, "pr already ready")
  }

  /// Convert-to-draft also flips optimistically (open → draft) the instant it's invoked.
  @MainActor
  func testPerformPRActionConvertToDraftIsOptimistic() {
    let store = AppStore()
    store.projects = [Project(path: "/p", vcs: "git", workrooms: [])]
    store.statusResolver = WorkroomStatusResolver(
      runner: StubPRRunner { _, _ in
        CommandResult(stdout: "", stderr: "boom", exitCode: 1, timedOut: false)
      })
    let sid = SidebarID.root(project: "/p")
    store.workroomStatuses[sid] = WorkroomStatus(
      dirty: false,
      pr: PullRequestInfo(
        number: 7, title: "t", state: .open, isDraft: false, url: "u", reviewDecision: nil,
        reviewers: []))

    store.performPRAction(.convertToDraft, number: 7, on: sid)
    XCTAssertEqual(store.workroomStatuses[sid]?.pr?.isDraft, true)
    XCTAssertEqual(store.workroomStatuses[sid]?.pr?.state, .open)
  }

  // MARK: - refreshGitHubCLI must never publish a non-answer

  /// REGRESSION: the false, sticky "GitHub CLI not signed in".
  ///
  /// A cancelled probe's child is SIGKILLed, and `StatusCommandRunner`'s continuation is
  /// NON-throwing, so it still resumes with `exitCode: 9` and empty stdout. The classifier read that
  /// as `.notAuthenticated`, and publishing it painted every window's PR panel.
  ///
  /// The double deliberately returns a CLEAN, verdict-producing payload rather than the signalled
  /// shape (see `GatedGHRunner`), so `Task.isCancelled` is the only thing under test here — the
  /// signalled path is `.keepPrior`'s job and is covered separately. Deleting the guard must fail
  /// this test (verified by mutation).
  @MainActor
  func testCancelledGitHubCLIProbePublishesNothing() async {
    let store = AppStore()
    let runner = GatedGHRunner()
    store.statusResolver = WorkroomStatusResolver(runner: runner)
    store.githubCLIStatus = .available

    let resolver = store.statusResolver
    let task = Task { await store.refreshGitHubCLI(resolver: resolver) }
    // Cancel only once the probe is genuinely in flight, or the guard under test never runs.
    let deadline = Date().addingTimeInterval(2)
    while !runner.enteredGHProbe && Date() < deadline {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTAssertTrue(runner.enteredGHProbe, "the gh auth probe never started")
    task.cancel()
    await task.value

    XCTAssertEqual(store.githubCLIStatus, .available, "a cancelled probe published a verdict")
  }

  /// `.keepPrior` (a killed or crashed child that was never cancelled — jetsam, SIGSEGV, a signal
  /// around sleep/wake) must not erase a correct warning. With nothing cached, the cache reports
  /// `nil` and the mirror is left exactly as it was.
  @MainActor
  func testKeepPriorGitHubCLIProbeLeavesTheStatusUntouched() async {
    let store = AppStore()
    store.statusResolver = WorkroomStatusResolver(
      runner: StubPRRunner { _, _ in
        CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
      })
    store.githubCLIStatus = .notAuthenticated  // a TRUE warning that must not be erased

    await store.refreshGitHubCLI(resolver: store.statusResolver)

    XCTAssertEqual(
      store.githubCLIStatus, .notAuthenticated,
      "an uninformative probe erased a correct warning — the inverse false claim")
  }

  /// Spin until the in-flight `gh` task settles (the stub returns promptly), with a bound so a hang
  /// fails the test rather than wedging it.
  @MainActor
  private func waitUntilIdle(_ store: AppStore) async {
    let deadline = Date().addingTimeInterval(2)
    while store.prActionInFlight && Date() < deadline {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTAssertFalse(store.prActionInFlight, "PR action did not settle")
  }
}

/// A `StatusCommandRunning` returning a canned result for the `gh pr …` write command, so
/// `performPRAction`'s success/failure handling is exercised without spawning real `gh`.
private struct StubPRRunner: StatusCommandRunning {
  let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    handler(executable, args)
  }
}

/// Blocks inside the `gh auth status` probe until the awaiting Task is cancelled, then returns a
/// result that WOULD produce a real verdict.
///
/// Two details make this test the cancellation guard's test rather than a duplicate of the
/// `.keepPrior` one:
///
/// 1. It RETURNS rather than throws. `StatusCommandRunner` resolves a **non-throwing**
///    `withCheckedContinuation`, so its `terminationHandler` always resumes with a value even when
///    the child was SIGKILLed out from under it. A double that threw `CancellationError` would model
///    a runner we don't have, and would pass against the buggy code.
/// 2. It returns a **parseable, verdict-producing** payload (`{"hosts":{}}` with exit 0), NOT the
///    signalled shape. The signalled shape is already caught by `.keepPrior`, so using it here would
///    make the test pass even with the cancellation guard deleted — green for the wrong reason. With
///    a clean verdict, `Task.isCancelled` is the ONLY thing standing between a cancelled probe and a
///    published `.notAuthenticated`.
private final class GatedGHRunner: StatusCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false

  var enteredGHProbe: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entered
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    guard executable == "gh", args.contains("auth") else {
      return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }
    lock.lock()
    entered = true
    lock.unlock()
    // Sleeps until cancelled (then throws immediately, which `try?` drops). Long enough that the
    // test's own deadline fails first if cancellation never propagates.
    try? await Task.sleep(nanoseconds: 60_000_000_000)
    return CommandResult(stdout: #"{"hosts":{}}"#, stderr: "", exitCode: 0, timedOut: false)
  }
}
