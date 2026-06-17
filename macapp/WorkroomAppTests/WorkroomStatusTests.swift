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

  // MARK: - aheadBehind

  func testAheadBehindZeroIsNil() {
    XCTAssertNil(
      VCSStatusPresentation.aheadBehind(WorkroomStatus(dirty: false, ahead: 0, behind: 0)))
  }

  func testAheadBehindNoUpstreamIsNil() {
    // ahead/behind both nil (no upstream resolved)
    XCTAssertNil(VCSStatusPresentation.aheadBehind(WorkroomStatus(dirty: false)))
  }

  func testAheadBehindCounts() {
    let ab = VCSStatusPresentation.aheadBehind(WorkroomStatus(dirty: true, ahead: 2, behind: 1))
    XCTAssertEqual(ab?.ahead, 2)
    XCTAssertEqual(ab?.behind, 1)
    XCTAssertEqual(ab?.accessibility, "ahead 2, behind 1")
  }

  // MARK: - composed accessibility label

  func testAccessibilityLabelComposition() {
    let s = WorkroomStatus(dirty: true, ahead: 2, behind: 1, ci: .failing)
    XCTAssertEqual(
      VCSStatusPresentation.accessibilityLabel(s), "dirty, ahead 2, behind 1, CI failing")
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
      jjRefs: ["mybook"], jjDescription: "feat: x",
      jjChangeID: "pw", jjCommitID: "7d74470b")
    store.mergeLocalStatus(fresh, into: sid)
    let stored = store.workroomStatuses[sid]
    XCTAssertEqual(stored?.dirty, true)
    XCTAssertEqual(stored?.jjRefs, ["mybook"])
    XCTAssertEqual(stored?.jjDescription, "feat: x")
    XCTAssertEqual(stored?.jjChangeID, "pw")
    XCTAssertEqual(stored?.jjCommitID, "7d74470b")
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
      dirty: true, ci: .passing, jjRefs: ["old"], jjChangeID: "aaaa")
    // A fresh GIT probe (no jj head) lands.
    let gitFresh = WorkroomStatus(dirty: false, branchForCI: "main")
    store.mergeLocalStatus(gitFresh, into: sid)
    let stored = store.workroomStatuses[sid]
    XCTAssertEqual(stored?.ci, .passing)  // CI preserved across the local refresh
    XCTAssertEqual(stored?.branchForCI, "main")
    XCTAssertNil(stored?.jjRefs)  // stale jj head cleared
    XCTAssertNil(stored?.jjChangeID)
  }

  // MARK: - Inspector section collapse (store-backed, persisted to Defaults)

  /// The collapse state lives on the store (so the `.inspector` content re-renders) and persists to
  /// Defaults via `didSet`. Guards that store↔Defaults wiring.
  @MainActor
  func testInspectorSectionCollapsePersistsToDefaults() {
    let original = Defaults[.changesSectionCollapsed]
    defer { Defaults[.changesSectionCollapsed] = original }
    let store = AppStore()
    store.changesSectionCollapsed = true
    XCTAssertTrue(Defaults[.changesSectionCollapsed])
    store.changesSectionCollapsed = false
    XCTAssertFalse(Defaults[.changesSectionCollapsed])
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
}
