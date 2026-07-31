import XCTest

@testable import Workroom

/// Issue #80: when the last panel (terminal *or* diff) closes in the workroom you're viewing, jump to
/// the rightmost remaining workroom tab — by *displayed* (split-aware, on-screen) order, not raw
/// persisted order. When no other tab is open, do nothing. Also covers the delete-path re-point, which
/// reuses the same `selectFallbackWorkroom` helper. Drives a real isolated `AppStore` with the terminal
/// factory seam overridden (no live PTY) and close-confirm **off** (synchronous close, no AppKit modal).
///
/// The delete-path tests exercise `detachTarget` + `reselectAfterWorkroomDetached` — the synchronous
/// prefix of `deleteWorkroom` — directly, so they never touch `deleteWorkroom`'s async CLI/VCS teardown.
@MainActor
final class EmptiedWorkroomSelectionTests: XCTestCase {
  // MARK: helpers

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    // Confirm off per store, not via `Defaults` — the shared key raced the other close classes under
    // parallel workers (see `AppStore.confirmOnCloseOverrideForTesting`).
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  private func wr(_ name: String, in path: String = "/a") -> SidebarID {
    .workroom(project: path, name: name)
  }

  private func tid(_ name: String, in path: String = "/a") -> TerminalTarget.ID {
    TerminalTarget.workroomID(project: path, name: name)
  }

  private func persistentDiff(_ path: String) -> DiffDescriptor {
    DiffDescriptor(path: path, change: .modified, source: .gitWorktree, isPreview: false)
  }

  /// Project with `names` workrooms, all active in the bar in that exact left→right order, each with
  /// one terminal tab. The bar order is pinned via `workroomTabOrder` so "rightmost" is deterministic.
  private func storeWithTabs(_ names: [String]) -> AppStore {
    let store = makeStore([project("/a", workrooms: names)])
    store.workroomTabOrder = names.map { tid($0) }
    for n in names { store.terminals.addTab(for: store.target(for: wr(n))!) }
    return store
  }

  // MARK: close path

  func testClosingLastPanelInSelectedWorkroomSelectsRightmostTab() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    let target = store.target(for: wr("feature"))!
    store.selectedTargetID = wr("feature")
    let tab = store.terminals.tabs(for: target).first!

    store.terminals.closeTab(tab.id, for: target)

    XCTAssertEqual(
      store.selectedTargetID, wr("bugfix"), "lands on the rightmost remaining tab")
    XCTAssertEqual(
      store.history.current?.target, wr("bugfix"),
      "the auto-jump records a nav-history step (issue #80 decision: record)")
  }

  /// The load-bearing one (Codex): with an active split, displayed (visual) order differs from raw
  /// persisted order, so the fallback must use `displayedWorkroomTargets().last`. Bar order
  /// [main, feature, bugfix, review]; split {feature, review} regroups to displayed
  /// [main, feature, review, bugfix]. Closing solo `main` must land on the *visible* rightmost
  /// (bugfix), NOT raw-last (review).
  func testClosingLastPanelUsesDisplayedOrderNotRawOrderUnderSplit() {
    let store = storeWithTabs(["main", "feature", "bugfix", "review"])
    // Split {feature, review} → displayed regroups to [main, feature, review, bugfix].
    store.insertWorkroomSplit(wr("review"), beside: wr("feature"), edge: .right)
    store.selectedTargetID = wr("main")  // a solo, non-member tab
    let target = store.target(for: wr("main"))!
    let tab = store.terminals.tabs(for: target).first!

    store.terminals.closeTab(tab.id, for: target)

    XCTAssertEqual(
      store.selectedTargetID, wr("bugfix"),
      "rightmost = visible chip (displayedWorkroomTargets), not raw-last (review)")
  }

  func testClosingLastPanelInOnlyActiveWorkroomDoesNothing() {
    let store = storeWithTabs(["solo"])  // the only workroom with a terminal → only tab in the bar
    let target = store.target(for: wr("solo"))!
    store.selectedTargetID = wr("solo")
    let tab = store.terminals.tabs(for: target).first!

    store.terminals.closeTab(tab.id, for: target)

    XCTAssertEqual(
      store.selectedTargetID, wr("solo"),
      "no other tab → selection unchanged; the empty 'New Terminal' state stays (do nothing)")
  }

  /// Closing all tabs of the selected workroom empties the inspector (History/Changes/PR key on
  /// `inspectorTargetID`, which drops to nil when the selection has no tabs) — even though the
  /// selection itself deliberately stays. Re-opening a terminal re-populates it.
  func testInspectorEmptiesWhenSelectedWorkroomLosesAllTabs() {
    let store = storeWithTabs(["solo"])
    let target = store.target(for: wr("solo"))!
    store.selectedTargetID = wr("solo")
    XCTAssertTrue(store.selectionHasTabs)
    XCTAssertEqual(store.inspectorTargetID, wr("solo"))

    let tab = store.terminals.tabs(for: target).first!
    store.terminals.closeTab(tab.id, for: target)

    XCTAssertEqual(store.selectedTargetID, wr("solo"), "the close path leaves the selection")
    XCTAssertFalse(store.selectionHasTabs)
    XCTAssertNil(
      store.inspectorTargetID, "inspector empties when the selected workroom has no open tabs")

    store.terminals.addTab(for: target)  // re-open a terminal
    XCTAssertTrue(store.selectionHasTabs)
    XCTAssertEqual(store.inspectorTargetID, wr("solo"), "re-opening a terminal re-populates it")
  }

  func testClosingNonLastPanelDoesNotChangeSelection() {
    let store = storeWithTabs(["main", "feature"])
    let target = store.target(for: wr("main"))!
    store.terminals.addTab(for: target)  // main now has 2 tabs
    store.selectedTargetID = wr("main")
    let first = store.terminals.tabs(for: target).first!

    store.terminals.closeTab(first.id, for: target)

    XCTAssertEqual(
      store.selectedTargetID, wr("main"), "tabCount still ≥ 1 → no redirect")
  }

  func testClosingLastPanelInBackgroundWorkroomDoesNotStealFocus() {
    let store = storeWithTabs(["main", "feature"])
    store.selectedTargetID = wr("main")  // viewing main
    let featureTarget = store.target(for: wr("feature"))!
    let fTab = store.terminals.tabs(for: featureTarget).first!

    // Close the *background* workroom's last tab (we're viewing main, not feature).
    store.terminals.closeTab(fTab.id, for: featureTarget)

    XCTAssertEqual(
      store.selectedTargetID, wr("main"),
      "a background workroom emptying must not move the viewed selection")
  }

  func testClosingLastDiffPanelSelectsRightmostTab() {
    let store = makeStore([project("/a", workrooms: ["main", "docs"])])
    store.workroomTabOrder = [tid("main"), tid("docs")]
    store.terminals.addTab(for: store.target(for: wr("main"))!)  // main: a terminal
    let docsTarget = store.target(for: wr("docs"))!
    // docs: only a diff panel, no terminal.
    store.terminals.openDiffPersistent(persistentDiff("a.swift"), for: docsTarget)
    store.selectedTargetID = wr("docs")
    let diffTab = store.terminals.tabs(for: docsTarget).first!

    store.terminals.closeTab(diffTab.id, for: docsTarget)

    XCTAssertEqual(
      store.selectedTargetID, wr("main"),
      "closing the last DIFF panel triggers the jump too — 'last panel' is terminal OR diff")
  }

  func testEmptyingSelectedSplitMemberYieldsToSurvivorNotRightmost() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    // [main, feature], focuses feature.
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    let featureTarget = store.target(for: wr("feature"))!
    let fTab = store.terminals.tabs(for: featureTarget).first!

    store.terminals.closeTab(fTab.id, for: featureTarget)

    XCTAssertTrue(
      store.workroomSplits.isEmpty, "emptying a 2-member split's pane dissolves it (issue #55)")
    XCTAssertEqual(
      store.selectedTargetID, wr("main"),
      "yields to the split survivor, NOT the rightmost tab (bugfix) — no double-jump")
  }

  func testCloseAllPanelsInSelectedWorkroomSelectsRightmostTab() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    let target = store.target(for: wr("feature"))!
    store.terminals.addTab(for: target)  // feature has 2 tabs
    store.selectedTargetID = wr("feature")

    store.requestCloseAllTerminalTabs(for: target)

    XCTAssertTrue(store.terminals.tabs(for: target).isEmpty)
    XCTAssertEqual(
      store.selectedTargetID, wr("bugfix"),
      "the close-all loop also triggers the jump on whichever close empties the target")
  }

  func testCloseAllMixedTerminalAndDiffSelectsRightmostTab() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    let target = store.target(for: wr("feature"))!
    // feature: a terminal (from storeWithTabs) plus a diff.
    store.terminals.openDiffPersistent(persistentDiff("a.swift"), for: target)
    store.selectedTargetID = wr("feature")

    store.requestCloseAllTerminalTabs(for: target)

    XCTAssertTrue(store.terminals.tabs(for: target).isEmpty)
    XCTAssertEqual(
      store.selectedTargetID, wr("bugfix"),
      "a mixed terminal+diff target closed via close-all still lands on the rightmost tab")
  }

  // MARK: delete path (synchronous prefix of deleteWorkroom: removeLocally → detachTarget → reselect)

  func testDeletingSelectedSoloWorkroomSelectsRightmostTab() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    store.selectedTargetID = wr("feature")
    let wasSelected = store.selectedTargetID == wr("feature")

    // Mimic removeWorkroomLocally dropping feature from the project list.
    store.projects = [project("/a", workrooms: ["main", "bugfix"])]
    store.detachTarget(wr("feature"))
    XCTAssertNil(store.selectedTargetID, "detaching a solo selected workroom nils selection")

    store.reselectAfterWorkroomDetached(wasSelectedHere: wasSelected)
    XCTAssertEqual(
      store.selectedTargetID, wr("bugfix"),
      "deleting the selected solo workroom re-points to the rightmost remaining tab")
  }

  func testDeletingSelectedSplitMemberYieldsToSurvivorNotRightmost() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    // [main, feature], selects feature.
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    let wasSelected = store.selectedTargetID == wr("feature")

    store.projects = [project("/a", workrooms: ["main", "bugfix"])]  // drop feature
    store.detachTarget(wr("feature"))  // dissolves split → selection moves to survivor main
    XCTAssertEqual(
      store.selectedTargetID, wr("main"), "detach of a split member yields to its survivor")

    store.reselectAfterWorkroomDetached(wasSelectedHere: wasSelected)
    XCTAssertEqual(
      store.selectedTargetID, wr("main"),
      "delete of a split member keeps the survivor, not the rightmost tab (bugfix)")
  }

  func testDeletingSelectedOnlyWorkroomLeavesNilSelection() {
    let store = storeWithTabs(["solo"])
    store.selectedTargetID = wr("solo")
    let wasSelected = store.selectedTargetID == wr("solo")

    store.projects = [project("/a", workrooms: [])]  // drop the only workroom
    store.detachTarget(wr("solo"))
    store.reselectAfterWorkroomDetached(wasSelectedHere: wasSelected)

    XCTAssertNil(
      store.selectedTargetID, "no other tab to land on → selection stays nil (do nothing)")
  }

  func testDeletingNonSelectedWorkroomDoesNotMoveSelection() {
    let store = storeWithTabs(["main", "feature", "bugfix"])
    store.selectedTargetID = wr("main")  // viewing main, deleting feature
    let wasSelected = store.selectedTargetID == wr("feature")  // false

    store.projects = [project("/a", workrooms: ["main", "bugfix"])]
    store.detachTarget(wr("feature"))  // not selected → leaves selection untouched
    store.reselectAfterWorkroomDetached(wasSelectedHere: wasSelected)

    XCTAssertEqual(
      store.selectedTargetID, wr("main"), "deleting a non-selected workroom leaves selection put")
  }

  // MARK: History follows the inspector target

  /// History must load the instant its target appears. The selected workroom's `inspectorTargetID` is
  /// nil until it has a tab, so opening its first tab flips it nil→id — the store re-points
  /// `commitHistory` from `refreshSelectionHasTabs` (the tab-add hook), not the hosted panel's
  /// `.task`, which lagged until an app refocus forced a re-render (the "History delay" bug).
  func testHistoryFocusesWhenSelectedWorkroomGainsFirstTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.isolatesInspectorSectionForTesting = true  // don't leak the section to other workers
    store.isolatesInspectorLayoutForTesting = true  // …nor the collapse flag
    store.inspectorVisibleOverrideForTesting = true  // the eager focus needs a VISIBLE pane
    store.activeInspectorSection = .changes  // the pane that stacks History
    store.historySectionCollapsed = false  // …expanded, so the section counts as showing
    store.selectedTargetID = wr("main")
    XCTAssertNil(store.commitHistory.root, "no tab yet → History has no target to load")

    store.terminals.addTab(for: store.target(for: wr("main"))!)
    store.refreshSelectionHasTabs()  // the real path runs this from the tab-focus hook

    XCTAssertEqual(
      store.commitHistory.root, URL(fileURLWithPath: "/a/main"),
      "History focuses on the workroom the moment it has a tab")
  }
}
