import XCTest

@testable import Workroom

/// Pure-type tests for the back/forward stack (issue #26). Liveness is supplied as a synthetic
/// predicate — `NavigationHistory` never touches `AppStore`/`targetExists`.
final class NavigationHistoryTests: XCTestCase {

  private let alwaysLive: (NavLocation) -> Bool = { _ in true }

  private func loc(_ target: SidebarID = .root(project: "/p"), _ tab: UUID = UUID()) -> NavLocation
  {
    NavLocation(target: target, tab: tab)
  }

  /// A changeset location: identity is the commit + the in-commit file. `title` rides in the payload
  /// only, so it can drift without inventing a step.
  private func changeset(
    _ target: SidebarID, _ tab: UUID, commit: String, title: String = "t", file: String? = nil
  ) -> NavLocation {
    NavLocation(
      target: target, tab: tab, contentID: .changeset(commitID: commit), selectedPath: file,
      payload: .changeset(
        ChangesetDescriptor(commitID: commit, title: title, isPreview: false, selectedPath: file)))
  }

  /// A working-copy diff location: identity is path + source; `change` rides in the payload only.
  private func diff(
    _ target: SidebarID, _ tab: UUID, path: String, change: ChangedFile.Change = .modified
  ) -> NavLocation {
    NavLocation(
      target: target, tab: tab, contentID: .diff(path: path, source: .gitWorktree),
      payload: .diff(
        DiffDescriptor(path: path, change: change, source: .gitWorktree, isPreview: false)))
  }

  /// The exact issue #26 example at the stack level: T1 of A → new terminal (Tnew, in A) →
  /// T2 of B → Back lands Tnew → Back lands T1 → Forward lands Tnew.
  func testIssueExampleTrace() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    let t1 = loc(a)
    let tNew = loc(a)
    let t2 = loc(b)

    var h = NavigationHistory()
    h.record(t1)
    h.record(tNew)
    h.record(t2)
    XCTAssertEqual(h.entries, [t1, tNew, t2])
    XCTAssertEqual(h.current, t2)

    XCTAssertEqual(h.step(-1, isLive: alwaysLive), tNew)
    XCTAssertEqual(h.step(-1, isLive: alwaysLive), t1)
    XCTAssertEqual(h.step(+1, isLive: alwaysLive), tNew)
    XCTAssertEqual(h.current, tNew)
  }

  func testDedupAgainstCurrentOnly() {
    let same = loc()
    var h = NavigationHistory()
    h.record(same)
    h.record(same)  // identical to current → no-op
    XCTAssertEqual(h.entries, [same])
    XCTAssertEqual(h.cursor, 0)
  }

  /// Browsing commits in one preview tab (same target+tab): different commit or file → distinct
  /// back/forward steps, so Back walks file→file then commit→commit (the commit-browser contract).
  func testCommitAndFileAreDistinctSteps() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = UUID()
    let cA = changeset(a, tab, commit: "A")
    let cAfile = changeset(a, tab, commit: "A", file: "x.swift")
    let cB = changeset(a, tab, commit: "B")
    var h = NavigationHistory()
    h.record(cA)
    h.record(cAfile)
    h.record(cB)
    XCTAssertEqual(h.entries, [cA, cAfile, cB])
    XCTAssertEqual(h.step(-1, isLive: alwaysLive), cAfile)
    XCTAssertEqual(h.step(-1, isLive: alwaysLive), cA)
    XCTAssertEqual(h.step(+1, isLive: alwaysLive), cAfile)
  }

  func testSameCommitAndFileDedups() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let same = changeset(a, UUID(), commit: "A", file: "x")
    var h = NavigationHistory()
    h.record(same)
    h.record(same)  // identical content → no-op
    XCTAssertEqual(h.entries, [same])
  }

  // MARK: Identity excludes the drifting payload fields

  /// A commit's title is rebuilt from a fallback on replay, so it must not make a new location —
  /// otherwise revisiting one commit piles up steps that look identical on screen.
  func testChangesetTitleDriftDedups() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = UUID()
    var h = NavigationHistory()
    h.record(changeset(a, tab, commit: "A", title: "written at record time"))
    h.record(changeset(a, tab, commit: "A", title: "A"))  // replay's `commitTitle ?? commitID`
    XCTAssertEqual(h.entries.count, 1, "a title change is not a new place")
  }

  /// A file's change kind flips as it is staged, reverted or deleted. Same file, same place.
  func testDiffChangeKindDriftDedups() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = UUID()
    var h = NavigationHistory()
    h.record(diff(a, tab, path: "x.swift", change: .modified))
    h.record(diff(a, tab, path: "x.swift", change: .deleted))
    XCTAssertEqual(h.entries.count, 1, "a change-kind flip is not a new place")
  }

  /// Keep Open flips `isPreview`; the location is unchanged. (`NavPayload.init` normalises it, and
  /// `==` ignores the payload anyway — this pins both.)
  func testPreviewToPersistDedups() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = UUID()
    let preview = DiffDescriptor(
      path: "x.swift", change: .modified, source: .gitWorktree, isPreview: true)
    var h = NavigationHistory()
    h.record(
      NavLocation(
        target: a, tab: tab, contentID: .diff(path: "x.swift", source: .gitWorktree),
        payload: NavPayload(.diff(preview))))
    h.record(diff(a, tab, path: "x.swift"))
    XCTAssertEqual(h.entries.count, 1, "pinning a preview is not a new place")
  }

  /// The same path viewed as a diff and as a plain file are different panes, so different steps.
  func testDiffAndFileOnTheSamePathAreDistinctSteps() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = UUID()
    let asDiff = diff(a, tab, path: "x.swift")
    let asFile = NavLocation(
      target: a, tab: tab, contentID: .file(path: "x.swift"),
      payload: .file(FileDescriptor(path: "x.swift", isPreview: false)))
    var h = NavigationHistory()
    h.record(asDiff)
    h.record(asFile)
    XCTAssertEqual(h.entries, [asDiff, asFile])
    XCTAssertEqual(h.step(-1, isLive: alwaysLive), asDiff)
  }

  /// A terminal pane and a content pane in the same tab are different places.
  func testTerminalAndContentAreDistinctSteps() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let tab = UUID()
    let term = NavLocation(target: a, tab: tab)  // contentID nil ⇒ a terminal
    let content = diff(a, tab, path: "x.swift")
    var h = NavigationHistory()
    h.record(term)
    h.record(content)
    XCTAssertEqual(h.entries, [term, content])
  }

  /// `prune`'s adjacent-duplicate collapse is the one place the hand-written `==` runs during removal,
  /// and for content entries in the SAME tab only the content can tell two steps apart. Both directions:
  /// identical content collapses, a different path does not.
  func testPruneCollapseIsContentAware() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let preview = UUID()
    let term = UUID()

    var same = NavigationHistory()
    same.record(diff(a, preview, path: "x.swift"))
    same.record(NavLocation(target: a, tab: term))
    same.record(diff(a, preview, path: "x.swift"))
    same.prune(removing: [term])
    XCTAssertEqual(same.entries.count, 1, "revisiting the same file in one tab is one place")

    var differing = NavigationHistory()
    differing.record(diff(a, preview, path: "x.swift"))
    differing.record(NavLocation(target: a, tab: term))
    differing.record(diff(a, preview, path: "y.swift"))
    differing.prune(removing: [term])
    XCTAssertEqual(
      differing.entries.count, 2, "two files browsed in one preview tab are two distinct steps")
    XCTAssertEqual(
      differing.step(-1, isLive: alwaysLive)?.contentID,
      .diff(path: "x.swift", source: .gitWorktree))
  }

  /// Pruning keys on the tab id even for content entries — back ignores what was closed, and nothing
  /// is reopened. Browsing several files in ONE preview tab therefore loses every step when that tab
  /// closes. Deliberate; see `prune`'s doc comment.
  func testPruneDropsContentEntriesOfAClosedTab() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let preview = UUID()
    let pinned = UUID()
    var h = NavigationHistory()
    h.record(diff(a, pinned, path: "kept.swift"))
    h.record(diff(a, preview, path: "one.swift"))
    h.record(diff(a, preview, path: "two.swift"))
    XCTAssertEqual(h.entries.count, 3)

    h.prune(removing: [preview])
    XCTAssertEqual(h.entries.count, 1, "both browse steps die with the tab that carried them")
    // The cursor was ON a removed entry, so it parks just past the last survivor (existing contract:
    // `current` is nil, and Back lands on that survivor rather than skipping it).
    XCTAssertTrue(h.canGoBack)
    XCTAssertEqual(
      h.step(-1, isLive: alwaysLive)?.tab, pinned, "the entry naming a still-open tab survives")
  }

  func testRecordAfterBackTruncatesForward() {
    let l0 = loc()
    let l1 = loc()
    let l2 = loc()
    let l3 = loc()
    var h = NavigationHistory()
    for l in [l0, l1, l2] { h.record(l) }
    XCTAssertEqual(h.step(-1, isLive: alwaysLive), l1)  // cursor → 1
    h.record(l3)  // navigated somewhere new from the middle
    XCTAssertEqual(h.entries, [l0, l1, l3])  // l2 (forward) dropped
    XCTAssertEqual(h.current, l3)
    XCTAssertFalse(h.canGoForward)
  }

  func testStepSkipsDeadEntries() {
    let l0 = loc()
    let l1 = loc()
    let l2 = loc()
    let l3 = loc()
    var h = NavigationHistory()
    for l in [l0, l1, l2, l3] { h.record(l) }  // cursor = 3
    let dead: Set<UUID> = [l1.tab, l2.tab]
    let isLive: (NavLocation) -> Bool = { !dead.contains($0.tab) }

    XCTAssertEqual(h.step(-1, isLive: isLive), l0)  // skip l2, l1
    XCTAssertEqual(h.cursor, 0)
  }

  func testStepReturnsNilAndKeepsCursorWhenNoLiveEntry() {
    let l0 = loc()
    let l1 = loc()
    var h = NavigationHistory()
    for l in [l0, l1] { h.record(l) }  // cursor = 1
    let isLive: (NavLocation) -> Bool = { $0.tab == l1.tab }  // only current is live

    XCTAssertNil(h.step(-1, isLive: isLive))
    XCTAssertEqual(h.cursor, 1)  // unchanged
  }

  func testBoundariesAndEmpty() {
    var h = NavigationHistory()
    XCTAssertFalse(h.canGoBack)
    XCTAssertFalse(h.canGoForward)
    XCTAssertNil(h.current)

    let only = loc()
    h.record(only)
    XCTAssertFalse(h.canGoBack)
    XCTAssertFalse(h.canGoForward)
    XCTAssertNil(h.step(-1, isLive: alwaysLive))
    XCTAssertNil(h.step(+1, isLive: alwaysLive))
  }

  func testCapDropsOldestAndAdjustsCursor() {
    var h = NavigationHistory()
    let all = (0..<(NavigationHistory.maxEntries + 5)).map { _ in loc() }
    for l in all { h.record(l) }

    XCTAssertEqual(h.entries.count, NavigationHistory.maxEntries)
    XCTAssertEqual(h.cursor, NavigationHistory.maxEntries - 1)
    XCTAssertEqual(h.entries.first, all[5])  // first 5 dropped
    XCTAssertEqual(h.entries.last, all.last)
    XCTAssertEqual(h.current, all.last)
  }

  // MARK: Prune — honest enablement (issue #26)

  func testPruneKeepsCursorOnSurvivingCurrent() {
    let l0 = loc()
    let l1 = loc()
    let l2 = loc()
    var h = NavigationHistory()
    for l in [l0, l1, l2] { h.record(l) }  // cursor 2 (l2)
    h.prune(removing: [l1.tab])
    XCTAssertEqual(h.entries, [l0, l2])
    XCTAssertEqual(h.current, l2)
    XCTAssertTrue(h.canGoBack)
  }

  func testPruneDisablesBackWhenAllEarlierRemoved() {
    let l0 = loc()
    let l1 = loc()
    let l2 = loc()
    var h = NavigationHistory()
    for l in [l0, l1, l2] { h.record(l) }  // cursor 2
    h.prune(removing: [l0.tab, l1.tab])
    XCTAssertEqual(h.entries, [l2])
    XCTAssertEqual(h.current, l2)
    XCTAssertFalse(h.canGoBack)
    XCTAssertFalse(h.canGoForward)
  }

  func testPruneOfCurrentLetsBackLandOnNearestSurvivor() {
    let l0 = loc()
    let l1 = loc()
    var h = NavigationHistory()
    for l in [l0, l1] { h.record(l) }  // cursor 1 (l1 current)
    h.prune(removing: [l1.tab])  // current removed
    XCTAssertEqual(h.entries, [l0])
    XCTAssertNil(h.current)  // cursor parked just past the survivor
    XCTAssertTrue(h.canGoBack)
    XCTAssertEqual(h.step(-1, isLive: alwaysLive), l0)
  }

  func testPruneCollapsesAdjacentDuplicate() {
    let a = SidebarID.workroom(project: "/a", name: "main")
    let t1 = loc(a)
    let t2 = loc(a)
    let t1again = NavLocation(target: a, tab: t1.tab)
    var h = NavigationHistory()
    for l in [t1, t2, t1again] { h.record(l) }  // [t1, t2, t1] cursor 2
    h.prune(removing: [t2.tab])  // exposes [t1, t1] → collapses to [t1]
    XCTAssertEqual(h.entries, [t1])
    XCTAssertEqual(h.cursor, 0)
    XCTAssertFalse(h.canGoBack)
  }
}
