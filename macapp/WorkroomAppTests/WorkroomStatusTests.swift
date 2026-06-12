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

  // MARK: - mergeLocalStatus carries the full local probe forward

  /// Regression: `mergeLocalStatus` once copied only a subset of the fresh fields and dropped the
  /// jj head (refs/description/change-id/commit-id), so a jj repo's Changes header fell back to
  /// the git branch label ("main"). The merge must carry every local-probe field.
  @MainActor
  func testMergeLocalStatusCarriesJJHeadFields() {
    let store = AppStore()
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
