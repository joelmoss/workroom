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
    let cA = NavLocation(target: a, tab: tab, commitID: "A", commitTitle: "a", filePath: nil)
    let cAfile = NavLocation(
      target: a, tab: tab, commitID: "A", commitTitle: "a", filePath: "x.swift")
    let cB = NavLocation(target: a, tab: tab, commitID: "B", commitTitle: "b", filePath: nil)
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
    let same = NavLocation(target: a, tab: UUID(), commitID: "A", commitTitle: "a", filePath: "x")
    var h = NavigationHistory()
    h.record(same)
    h.record(same)  // identical content → no-op
    XCTAssertEqual(h.entries, [same])
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
