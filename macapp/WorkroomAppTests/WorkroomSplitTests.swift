import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// Store-level tests for the workroom-into-workroom split (issue #23 follow-up): the pure transforms on
/// `AppStore.workroomSplits` (insert with move-semantics, remove/collapse/dissolve, setRatio), the
/// resolve-to-live-leaves self-heal, and the focused-member ⇄ selection coupling. Drives a real,
/// non-singleton `AppStore` with the terminal factory seam overridden (no live PTY). The split only
/// cares that a leaf's `SidebarID` resolves via `target(for:)` (project list), so no terminals are
/// needed here; the drag gesture + renderer are manual QA.
@MainActor
final class WorkroomSplitTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
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

  /// A project where the `missing` workrooms carry a `DirectoryMissing` warning (so `target.isMissing`
  /// is true — the workroom resolves in the list, but its directory is gone).
  private func project(_ path: String, present: [String], missing: [String]) -> Project {
    let live = present.map {
      Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
    }
    let gone = missing.map {
      Workroom(
        name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)",
        warnings: [Warning(kind: "DirectoryMissing", message: "gone", path: nil, vcs: nil)])
    }
    return Project(path: path, vcs: "git", workrooms: live + gone)
  }

  private func wr(_ name: String, in path: String = "/a") -> SidebarID {
    .workroom(project: path, name: name)
  }

  private func store3() -> AppStore {
    makeStore([project("/a", workrooms: ["main", "feature", "bugfix"])])
  }

  /// The window's single split group — most of these tests exercise one group, so this reads as "the
  /// split". nil ⇒ nothing is grouped (`workroomSplits` is empty). The multi-group tests below index
  /// `store.workroomSplits` directly.
  private func onlySplit(_ store: AppStore) -> PaneLayout<SidebarID>? { store.workroomSplits.first }

  private func rootRatio(_ store: AppStore, group: Int = 0) -> CGFloat? {
    guard store.workroomSplits.indices.contains(group) else { return nil }
    if case .split(_, _, let ratio, _, _) = store.workroomSplits[group] { return ratio }
    return nil
  }

  private func rootSplitID(_ store: AppStore, group: Int = 0) -> UUID? {
    guard store.workroomSplits.indices.contains(group) else { return nil }
    if case .split(let id, _, _, _, _) = store.workroomSplits[group] { return id }
    return nil
  }

  /// Leaf sets of every group, in `workroomSplits` order — the shape assertions the multi-group tests
  /// make ("two groups, these members each") without depending on tree structure.
  private func groupSets(_ store: AppStore) -> [Set<SidebarID>] {
    store.workroomSplits.map { Set($0.tabIDs) }
  }

  // MARK: insert

  func testInsertSeedsTwoLeafSplitFromSelection() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    // right ⇒ the dropped member lands trailing, so the anchor (main) is first.
    XCTAssertEqual(onlySplit(store)?.tabIDs, [wr("main"), wr("feature")])
    XCTAssertEqual(store.selectedTargetID, wr("feature"), "the dropped member is focused")
    XCTAssertTrue(store.workroomSplitActive)
  }

  func testInsertGrowsToThreeLeaves() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    XCTAssertEqual(
      Set(onlySplit(store)?.tabIDs ?? []), [wr("main"), wr("feature"), wr("bugfix")])
    XCTAssertEqual(onlySplit(store)?.tabIDs.count, 3)
  }

  // MARK: pane floor (`destinationRect`)

  /// A pane too narrow to yield two floor-width halves must refuse the drop outright, rather than
  /// nesting a split that trips `lengths`' even-split fallback and leaves two 172pt panes. The width
  /// floor is set by the toolbar furniture a pane must render — since issue #150 that is the pane's
  /// own `PaneTitleBar` (~190pt of controls on a diff pane); see `TerminalSessions.minPaneWidth`.
  private func tooNarrow() -> CGRect { CGRect(x: 0, y: 0, width: 348, height: 800) }
  private func roomy() -> CGRect { CGRect(x: 0, y: 0, width: 1200, height: 800) }

  func testDropIsRefusedWhenThePaneCannotHoldTwoHalves() {
    let store = store3()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("main"), edge: .right, destinationRect: tooNarrow())
    XCTAssertTrue(store.workroomSplits.isEmpty, "the split must not be created at all")
    XCTAssertFalse(store.workroomSplitActive)
  }

  func testDropIsAllowedWhenThePaneIsWideEnough() {
    let store = store3()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("main"), edge: .right, destinationRect: roomy())
    XCTAssertEqual(onlySplit(store)?.tabIDs, [wr("main"), wr("feature")])
  }

  func testTheFloorIsPerAxis() {
    // The same 348pt-wide pane is plenty tall, so a top/bottom drop onto it is fine.
    let store = store3()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("main"), edge: .bottom, destinationRect: tooNarrow())
    XCTAssertEqual(onlySplit(store)?.tabIDs.count, 2, "a vertical split reads height, not width")
  }

  func testRearrangingWithinAGroupIsNotBlockedByTheFloor() {
    // Moving a member that is ALREADY in the group leaves the pane count unchanged, so the floor
    // must not apply — the same policy `TerminalSessions.moveTabIntoSplit` applies via `addsAMember`.
    let store = store3()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("main"), edge: .right, destinationRect: roomy())
    store.insertWorkroomSplit(
      wr("main"), beside: wr("feature"), edge: .right, destinationRect: tooNarrow())
    XCTAssertEqual(onlySplit(store)?.tabIDs.count, 2, "a rearrangement must still go through")
    XCTAssertEqual(Set(onlySplit(store)?.tabIDs ?? []), [wr("main"), wr("feature")])
  }

  func testAnUnmeasuredCallerKeepsThePreFloorBehaviour() {
    // `destinationRect: nil` is the default — no measurement available, so no floor is applied.
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    XCTAssertEqual(onlySplit(store)?.tabIDs.count, 2)
  }

  // MARK: insert's return value (issue #163)

  /// Every keyboard/menu caller uses the `Bool` as its ONLY guard and falls back to a plain open
  /// when it's false, so each reject branch has to report itself accurately — a reject that
  /// returned true would swallow the workroom instead of opening it.
  func testInsertReportsWhetherItActuallySplit() {
    let store = store3()
    XCTAssertTrue(
      store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right),
      "seeding a new group")
    XCTAssertTrue(
      store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .right),
      "growing an existing group")
  }

  func testInsertReportsFalseOnEveryRejectBranch() {
    let store = makeStore([project("/a", present: ["main", "feature"], missing: ["gone"])])
    XCTAssertFalse(
      store.insertWorkroomSplit(wr("main"), beside: wr("main"), edge: .right), "self-drop")
    XCTAssertFalse(
      store.insertWorkroomSplit(wr("nope"), beside: wr("main"), edge: .right),
      "leaf that doesn't resolve")
    XCTAssertFalse(
      store.insertWorkroomSplit(wr("gone"), beside: wr("main"), edge: .right),
      "missing directory")
    XCTAssertFalse(
      store.insertWorkroomSplit(
        wr("feature"), beside: wr("main"), edge: .right, destinationRect: tooNarrow()),
      "below the pane floor")
    XCTAssertTrue(store.workroomSplits.isEmpty, "none of those may have changed the model")
  }

  // MARK: workroomPaneRect (issue #163)

  func testPaneRectIsNilWithoutAMeasuredContainer() {
    let store = store3()
    XCTAssertNil(store.workroomPaneRect(for: wr("main")), "nothing laid out yet")
  }

  func testPaneRectIsNilForALeafThatDoesNotResolve() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    XCTAssertNil(store.workroomPaneRect(for: wr("nope")))
  }

  func testSoloAnchorGetsTheWholeContainer() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    XCTAssertEqual(store.workroomPaneRect(for: wr("main"))?.width, roomy().width)
  }

  func testGroupedAnchorGetsItsOwnSlotNotTheWholeContainer() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("main"), edge: .right, destinationRect: roomy())
    let width = store.workroomPaneRect(for: wr("main"))?.width
    XCTAssertNotNil(width)
    XCTAssertLessThan(width ?? .infinity, roomy().width, "a member occupies half, not the whole")
  }

  /// The regression that killed the per-pane-cache design: the renderer only lays out the CURRENT
  /// selection's layout, so a remembered map holds nothing for an anchor the user has navigated
  /// away from — which is exactly the create-then-select-elsewhere path. Deriving per call means
  /// the anchor's rect stays available regardless of what is selected.
  func testPaneRectIsDerivableForAnAnchorThatIsNotSelected() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    store.selectedTargetID = wr("bugfix")
    XCTAssertEqual(
      store.workroomPaneRect(for: wr("main"))?.width, roomy().width,
      "an unselected solo anchor still measures as a full-width pane")
  }

  // MARK: openExistingAsSplit (issue #163)

  func testOpenAsSplitLandsToTheRightOfTheSelectionAndFocusesIt() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    store.selectedTargetID = wr("main")
    store.openExistingAsSplit(wr("feature"))
    // Order, not just membership: `.right` must put the anchor first and the newcomer second.
    XCTAssertEqual(onlySplit(store)?.tabIDs, [wr("main"), wr("feature")])
    if case .split(_, let orientation, _, _, _) = onlySplit(store) {
      XCTAssertEqual(orientation, .horizontal, "side by side, not stacked")
    } else {
      XCTFail("expected a split node")
    }
    XCTAssertEqual(store.selectedTargetID, wr("feature"), "focus follows the newly opened member")
  }

  /// A refused split must NOT fall back to a plain open. `openExisting` REPLACES the selection, so
  /// falling back cost the user the pane they were looking at — right after the picker promised a
  /// split. A refusal is a no-op (with a beep); `canOpenAsSplit` keeps the menu item away.
  func testOpenAsSplitWithNoSelectionDoesNothing() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    store.selectedTargetID = nil
    store.openExistingAsSplit(wr("feature"))
    XCTAssertTrue(store.workroomSplits.isEmpty)
    XCTAssertNil(store.selectedTargetID, "no anchor ⇒ no split AND no replacement")
    XCTAssertFalse(store.canOpenAsSplit(wr("feature")), "…and the affordance is hidden")
  }

  func testOpenAsSplitOnTheSelectionItselfDoesNothing() {
    let store = store3()
    store.workroomPaneSpace = roomy()
    store.selectedTargetID = wr("main")
    store.openExistingAsSplit(wr("main"))
    XCTAssertTrue(store.workroomSplits.isEmpty)
    XCTAssertEqual(store.selectedTargetID, wr("main"))
    XCTAssertFalse(store.canOpenAsSplit(wr("main")), "you cannot split a workroom beside itself")
  }

  /// The common case: a window too narrow for the floor. Replacing here is the worst outcome —
  /// the user loses their current pane and gains one they didn't ask to swap to.
  func testOpenAsSplitBelowThePaneFloorKeepsTheCurrentPane() {
    let store = store3()
    store.workroomPaneSpace = tooNarrow()
    store.selectedTargetID = wr("main")
    store.openExistingAsSplit(wr("feature"))
    XCTAssertTrue(store.workroomSplits.isEmpty, "too narrow to split")
    XCTAssertEqual(store.selectedTargetID, wr("main"), "and the current pane is NOT replaced")
    XCTAssertFalse(store.canOpenAsSplit(wr("feature")), "…and the affordance is hidden")
  }

  /// `insertWorkroomSplit` rejects a missing directory because a missing leaf "can only be backed
  /// out of again" (issue #23) — so falling back to a plain open did exactly what that guard
  /// prevents, at full-frame size, and cost the user their pane.
  func testOpenAsSplitOfAMissingWorkroomNeitherSplitsNorNavigates() {
    let store = makeStore([project("/a", present: ["main"], missing: ["gone"])])
    store.workroomPaneSpace = roomy()
    store.selectedTargetID = wr("main")
    store.openExistingAsSplit(wr("gone"))
    XCTAssertTrue(store.workroomSplits.isEmpty)
    XCTAssertEqual(store.selectedTargetID, wr("main"), "a missing workroom must not take the pane")
    XCTAssertFalse(store.canOpenAsSplit(wr("gone")), "…and the affordance is hidden for it")
  }

  /// Accepted semantics (issue #163): opening a member of a BACKGROUND group detaches it, which
  /// dissolves that group when it drops below two — the same thing dragging it already does.
  /// Pinned so a later change here is a deliberate decision rather than a silent drift.
  func testOpenAsSplitOfABackgroundGroupMemberDissolvesThatGroup() {
    let store = makeStore([project("/a", workrooms: ["main", "feature", "bugfix", "docs"])])
    store.workroomPaneSpace = roomy()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("docs"), edge: .right, destinationRect: roomy())
    XCTAssertEqual(groupSets(store), [[wr("docs"), wr("feature")]])
    store.selectedTargetID = wr("main")
    store.openExistingAsSplit(wr("feature"))
    XCTAssertEqual(
      groupSets(store), [[wr("main"), wr("feature")]],
      "feature moved out; its old pair dropped below two and dissolved")
  }

  // MARK: picker split intent (issue #163)

  func testRaiseWorkroomPickerSetsTheMatchingRequestFlag() {
    let store = store3()
    store.raiseWorkroomPicker(.new, split: true)
    XCTAssertTrue(store.requestNewWorkroomPicker)
    XCTAssertFalse(store.requestOpenWorkroomPicker)
    store.requestNewWorkroomPicker = false
    store.raiseWorkroomPicker(.open)
    XCTAssertTrue(store.requestOpenWorkroomPicker)
    XCTAssertFalse(store.requestNewWorkroomPicker)
  }

  func testConsumingTheSplitIntentReturnsItOnce() {
    let store = store3()
    store.raiseWorkroomPicker(.open, split: true)
    XCTAssertTrue(store.consumePickerSplitIntent())
    XCTAssertFalse(store.consumePickerSplitIntent(), "consumed — a second read is false")
  }

  /// REGRESSION GUARD: ⌥⌘N → Esc → the title bar's + button must CREATE, not split. Every raise
  /// site goes through `raiseWorkroomPicker`, and each raise consumes exactly once, so a cancelled
  /// split intent cannot survive into the next plain raise.
  func testACancelledSplitIntentDoesNotLeakIntoTheNextPlainRaise() {
    let store = store3()
    store.raiseWorkroomPicker(.new, split: true)
    _ = store.consumePickerSplitIntent()  // the picker goes up…
    store.requestNewWorkroomPicker = false  // …and is cancelled without a pick
    store.raiseWorkroomPicker(.new)  // the title bar's + button
    XCTAssertFalse(store.consumePickerSplitIntent(), "the plain raise must not inherit split mode")
  }

  /// The indicator and the commit must agree — `dropHighlight` gates the accent band on exactly this
  /// predicate, so a divergence here is a band that previews a drop the store then refuses.
  func testAdmissibilityMatchesWhatInsertActuallyDoes() {
    for (rect, edge, expected) in [
      (tooNarrow(), PaneEdge.right, false),
      (tooNarrow(), PaneEdge.bottom, true),  // narrow but tall — the other axis is fine
      (roomy(), PaneEdge.right, true),
      (CGRect?.none, PaneEdge.right, true),  // unmeasured ⇒ admitted, as insert defaults
    ] as [(CGRect?, PaneEdge, Bool)] {
      let store = store3()
      XCTAssertEqual(
        store.canInsertWorkroomSplit(
          wr("feature"), beside: wr("main"), edge: edge, destinationRect: rect),
        expected, "predicate disagreed for \(String(describing: rect)) / \(edge)")
      store.insertWorkroomSplit(
        wr("feature"), beside: wr("main"), edge: edge, destinationRect: rect)
      XCTAssertEqual(
        !store.workroomSplits.isEmpty, expected,
        "insert disagreed with the predicate for \(String(describing: rect)) / \(edge)")
    }
  }

  func testAdmissibilityAllowsARearrangementTheFloorWouldOtherwiseBlock() {
    let store = store3()
    store.insertWorkroomSplit(
      wr("feature"), beside: wr("main"), edge: .right, destinationRect: roomy())
    XCTAssertTrue(
      store.canInsertWorkroomSplit(
        wr("main"), beside: wr("feature"), edge: .right, destinationRect: tooNarrow()),
      "the band must still show for a rearrangement, which the floor does not gate")
  }

  func testInsertMovingExistingMemberIsNotADuplicate() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // [main, feature]
    // Drag "main" (already a member) beside "feature": a move, not a duplicate.
    store.insertWorkroomSplit(wr("main"), beside: wr("feature"), edge: .right)
    XCTAssertEqual(onlySplit(store)?.tabIDs.count, 2, "move, not duplicate")
    XCTAssertEqual(Set(onlySplit(store)?.tabIDs ?? []), [wr("main"), wr("feature")])
  }

  func testInsertSelfDropIsNoOp() {
    let store = store3()
    store.insertWorkroomSplit(wr("main"), beside: wr("main"), edge: .right)
    XCTAssertNil(onlySplit(store))
  }

  func testInsertRejectsNonResolvingLeaf() {
    let store = store3()
    // `.project` is never a target, and an unknown workroom doesn't resolve — both must be rejected.
    store.insertWorkroomSplit(.project("/a"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("ghost"), beside: wr("main"), edge: .right)
    XCTAssertNil(onlySplit(store))
  }

  func testInsertRejectsMissingWorkroom() {
    // A workroom whose directory is gone (`isMissing`) resolves in the list but must not be draggable
    // into a split — it would render a "Directory not found" pane you can only back out of (issue #23).
    let store = makeStore([project("/a", present: ["main"], missing: ["gone"])])
    store.insertWorkroomSplit(wr("gone"), beside: wr("main"), edge: .right)
    XCTAssertNil(onlySplit(store), "a missing workroom is rejected as a drop source")
  }

  func testInsertAllowsCrossProjectSplit() {
    // The sidebar drag (issue #101) exposes every project's rows, so a workroom from one project can be
    // dropped beside a pane from another — cross-project splits are intended (the tab bar, scoped to the
    // current workroom, never allowed this). Both leaves resolve via `target(for:)`, so there is no
    // same-project guard; pin that here so a future guard can't silently regress the behavior.
    let store = makeStore([
      project("/a", workrooms: ["main"]),
      project("/b", workrooms: ["feature"]),
    ])
    store.insertWorkroomSplit(wr("feature", in: "/b"), beside: wr("main", in: "/a"), edge: .right)
    XCTAssertEqual(onlySplit(store)?.tabIDs, [wr("main", in: "/a"), wr("feature", in: "/b")])
    XCTAssertEqual(store.selectedTargetID, wr("feature", in: "/b"), "the dropped member is focused")
    XCTAssertTrue(store.workroomSplitActive)
  }

  // MARK: remove / dissolve

  func testRemoveCollapsesThreeToTwo() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    store.removeWorkroomSplitMember(wr("bugfix"))
    XCTAssertEqual(Set(onlySplit(store)?.tabIDs ?? []), [wr("main"), wr("feature")])
  }

  func testRemoveDissolvesBelowTwoAndReselectsSurvivor() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.selectedTargetID = wr("feature")
    store.removeWorkroomSplitMember(wr("feature"))
    XCTAssertNil(onlySplit(store), "below two members → dissolve to single")
    XCTAssertEqual(
      store.selectedTargetID, wr("main"), "the removed-and-focused member yields to the survivor")
  }

  func testRemoveNonMemberIsNoOp() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.removeWorkroomSplitMember(wr("bugfix"))  // not in the split
    XCTAssertEqual(onlySplit(store)?.tabIDs.count, 2)
  }

  // MARK: auto-close — emptying a split member's terminals drops its pane (issue #55)

  func testClosingLastTerminalInSplitMemberDissolvesSplit() {
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)
    let bTab = store.terminals.addTab(for: store.target(for: b)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b], focuses b
    store.terminals.closeTab(bTab.id, for: store.target(for: b)!)
    XCTAssertNil(onlySplit(store), "emptying a 2-member split's pane dissolves the split")
    XCTAssertEqual(
      store.selectedTargetID, a, "the emptied-and-focused member yields to the survivor")
  }

  func testClosingLastTerminalInSplitMemberCollapsesThreeToTwo() {
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    let c = wr("bugfix")
    store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.addTab(for: store.target(for: b)!)
    let cTab = store.terminals.addTab(for: store.target(for: c)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)
    store.insertWorkroomSplit(c, beside: b, edge: .bottom)  // split [a, b, c]
    store.terminals.closeTab(cTab.id, for: store.target(for: c)!)
    XCTAssertEqual(
      Set(onlySplit(store)?.tabIDs ?? []), [a, b], "the emptied member leaves a 2-member split")
  }

  func testClosingLastTerminalInNonFocusedMemberKeepsSelectionOnSurvivor() {
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)
    let bTab = store.terminals.addTab(for: store.target(for: b)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)
    store.selectedTargetID = a  // focus a → b is the co-displayed, non-selected member
    store.terminals.closeTab(bTab.id, for: store.target(for: b)!)
    XCTAssertNil(onlySplit(store), "the split dissolves to the survivor")
    XCTAssertEqual(store.selectedTargetID, a, "selection stays on the still-focused survivor")
  }

  func testClosingLastTerminalInSoloWorkroomLeavesNoSplit() {
    let store = store3()
    let a = wr("main")
    let aTab = store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.closeTab(aTab.id, for: store.target(for: a)!)  // no split active
    XCTAssertNil(onlySplit(store), "a solo workroom has no split to close — and must not crash")
  }

  // MARK: persistence — split survives selecting a non-member (grouping like terminal tabs)

  func testSplitPersistsAndHidesWhenSelectingNonMember() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    // Split is main+feature. Select a non-member → its solo layout shows, split NOT discarded.
    store.selectedTargetID = wr("bugfix")
    XCTAssertEqual(store.visibleWorkroomLayout(for: wr("bugfix")), .leaf(wr("bugfix")))
    XCTAssertFalse(store.isWorkroomSplitVisible)
    XCTAssertNotNil(onlySplit(store), "the split persists while a non-member is shown")
    // Reselect a member → the split is shown again.
    store.selectedTargetID = wr("main")
    XCTAssertTrue(store.isWorkroomSplitVisible)
    XCTAssertEqual(
      store.visibleWorkroomLayout(for: wr("main")).tabIDs, [wr("main"), wr("feature")])
  }

  func testVisibleWorkroomLayoutPrunesDeadLeafForRenderer() {
    // A 3-leaf split with one workroom deleted out-of-band (no prune yet): the layout the renderer
    // uses must already drop the dead leaf, so it never lays out a rect + divider-to-nowhere for a
    // hole before `pruneWorkroomSplitToLiveLeaves` runs in `apply(_:)`.
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)  // 3 leaves
    store.projects = [project("/a", workrooms: ["main", "bugfix"])]  // "feature" deleted
    let layout = store.visibleWorkroomLayout(for: wr("main"))
    XCTAssertEqual(
      Set(layout.tabIDs), [wr("main"), wr("bugfix")],
      "the dead leaf is pruned from the render layout")
  }

  func testVisibleWorkroomLayoutFallsToLeafWhenPruneLeavesOne() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // [main, feature]
    store.projects = [project("/a", workrooms: ["main"])]  // delete "feature" → one live leaf
    XCTAssertEqual(
      store.visibleWorkroomLayout(for: wr("main")), .leaf(wr("main")),
      "a lone surviving leaf renders solo, not a one-pane split")
  }

  func testDisplayedWorkroomTargetsGroupsMembersContiguously() {
    // Bar order [main, feature, bugfix]; split {main, bugfix} (non-adjacent). The display pulls them
    // into a contiguous run at main's slot: [main, bugfix, feature].
    let store = makeStore([project("/a", workrooms: ["main", "feature", "bugfix"])])
    store.workroomTabOrder = [
      TerminalTarget.workroomID(project: "/a", name: "main"),
      TerminalTarget.workroomID(project: "/a", name: "feature"),
      TerminalTarget.workroomID(project: "/a", name: "bugfix"),
    ]
    for name in ["main", "feature", "bugfix"] {
      store.terminals.addTab(for: store.target(for: wr(name))!)  // make all three active in the bar
    }
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("main"), edge: .right)  // split: main+bugfix
    XCTAssertEqual(
      store.displayedWorkroomTargets().map(\.sid), [wr("main"), wr("bugfix"), wr("feature")])
  }

  // MARK: setRatio

  func testSetRatioTargetsTheNode() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    let id = rootSplitID(store)!
    store.setWorkroomSplitRatio(0.3, forSplit: id)
    XCTAssertEqual(rootRatio(store) ?? -1, 0.3, accuracy: 0.0001)
  }

  // MARK: equalize (issue #83 — "Resize Workroom Splits Evenly")

  func testEqualizeWeightsByLeafCount() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    // tree: main | (feature / bugfix). Skew the outer divider, then equalize.
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store)!)
    store.equalizeWorkroomSplit()
    XCTAssertEqual(rootRatio(store) ?? -1, 1.0 / 3.0, accuracy: 0.0001, "main is 1 of 3 leaves")
  }

  func testEqualizeNoOpWithoutSplit() {
    let store = store3()
    store.equalizeWorkroomSplit()
    XCTAssertNil(onlySplit(store))
  }

  func testEqualizePrunesDeadLeavesFirst() {
    // A stored split holding a dead leaf (not in the project list, so `target(for:)` is nil) must be
    // pruned before weighting — otherwise it budgets space for a ghost pane and the visible panes end
    // uneven (Codex #2). Set the tree directly since `insertWorkroomSplit` rejects non-resolving leaves.
    let store = store3()
    store.workroomSplits = [
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.9,
        first: .leaf(wr("deleted")),
        second: .split(
          id: UUID(), orientation: .horizontal, ratio: 0.9,
          first: .leaf(wr("main")), second: .leaf(wr("feature"))))
    ]
    store.selectedTargetID = wr("main")  // equalize acts on the VISIBLE group
    store.equalizeWorkroomSplit()
    XCTAssertEqual(onlySplit(store)?.tabIDs, [wr("main"), wr("feature")], "ghost leaf pruned")
    XCTAssertEqual(rootRatio(store) ?? -1, 0.5, accuracy: 0.0001, "two live panes split evenly")
  }

  func testEqualizeDissolvesWhenOneLiveLeafRemains() {
    let store = store3()
    store.workroomSplits = [
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.7,
        first: .leaf(wr("deleted")), second: .leaf(wr("main")))
    ]
    store.selectedTargetID = wr("main")
    store.equalizeWorkroomSplit()
    XCTAssertNil(onlySplit(store), "only one live leaf → no split")
  }

  // MARK: resolve / self-heal

  func testResolvedSplitLeavesDropsDeletedAndNilsBelowTwo() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    XCTAssertEqual(store.resolvedSplitLeaves()?.count, 2)
    // Remove "feature" from the project list → only "main" resolves → <2 live → nil.
    store.projects = [project("/a", workrooms: ["main", "bugfix"])]
    XCTAssertNil(store.resolvedSplitLeaves())
    XCTAssertFalse(store.workroomSplitActive)
  }

  func testPruneDropsDeadLeafKeepingSplit() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)  // → 3 leaves
    store.projects = [project("/a", workrooms: ["main", "bugfix"])]  // delete "feature"
    store.pruneWorkroomSplitToLiveLeaves()
    XCTAssertEqual(Set(onlySplit(store)?.tabIDs ?? []), [wr("main"), wr("bugfix")])
  }

  func testPruneDissolvesWhenBelowTwoLiveAndReselects() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.selectedTargetID = nil  // mimic apply() having nilled a dead selection before prune
    store.projects = [project("/a", workrooms: ["main"])]  // only "main" survives
    store.pruneWorkroomSplitToLiveLeaves()
    XCTAssertNil(onlySplit(store))
    XCTAssertEqual(store.selectedTargetID, wr("main"), "dissolve re-selects the live survivor")
  }

  // MARK: surface-focus routing (issue #23 F2 / T3)

  func testSurfaceFocusRoutesSelectionWithinSplitWithoutHistory() {
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)  // recordCurrentLocation needs a focused tab
    store.terminals.addTab(for: store.target(for: b)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b]
    store.selectedTargetID = a  // focus a (deliberate — records history)
    let before = store.history.entries.count

    // A click into b's terminal surface routes selection to b — but does NOT record nav history (T3).
    store.terminals.onSurfaceFocused?(store.target(for: b)!.id)
    XCTAssertEqual(store.selectedTargetID, b, "surface focus retargets the focused workroom (F2)")
    XCTAssertEqual(
      store.history.entries.count, before, "intra-split focus is history-suppressed (T3)")
  }

  func testSelectingTabInCoDisplayedMemberFocusesThatWorkroom() {
    // Clicking a tab chip in a co-displayed but non-focused split member must promote that workroom to
    // the focused member (so its surface takes keyboard focus) — the bug was that the chip highlighted
    // while the terminal stayed unfocused. Uses b's already-focused tab, the trickiest case: `focus`
    // early-returns there, so the promotion must happen in `select` ahead of it.
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)
    let bTarget = store.target(for: b)!
    store.terminals.addTab(for: bTarget)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b]
    store.selectedTargetID = a  // focus a → b is co-displayed but not focused
    let bTab = store.terminals.tabs(for: bTarget).first!

    store.terminals.select(bTab.id, for: bTarget)
    XCTAssertEqual(
      store.selectedTargetID, b, "selecting a tab in a co-displayed member focuses that workroom")
  }

  func testSelectingTabInFocusedMemberKeepsSelection() {
    // The common case must not regress: selecting a tab in the already-focused member is a no-op for
    // the workroom selection.
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    let aTarget = store.target(for: a)!
    store.terminals.addTab(for: aTarget)
    store.terminals.addTab(for: store.target(for: b)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b]
    store.selectedTargetID = a
    let aTab = store.terminals.tabs(for: aTarget).first!

    store.terminals.select(aTab.id, for: aTarget)
    XCTAssertEqual(
      store.selectedTargetID, a, "selecting within the focused member keeps it selected")
  }

  func testSurfaceFocusIsIgnoredWhileTheSplitIsHidden() {
    // The reported two-clicks-to-select fault. The split PERSISTS while a non-member workroom is shown
    // solo, so a member pane's `applyFocus` block — queued by the previous render, drained from a nested
    // run loop after the selection already moved — still reports its surface as focused. That must NOT
    // read as a workroom choice: it yanked the selection back to the split member, so selecting a
    // non-member chip only stuck on the second click.
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    let outsider = wr("bugfix")
    store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.addTab(for: store.target(for: b)!)
    store.terminals.addTab(for: store.target(for: outsider)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b]
    store.selectedTargetID = outsider  // a non-member → the split is hidden, `bugfix` shows solo
    XCTAssertFalse(store.isWorkroomSplitVisible, "precondition: the split is off screen")

    store.terminals.onSurfaceFocused?(store.target(for: b)!.id)

    XCTAssertEqual(
      store.selectedTargetID, outsider,
      "a hidden split member's stale focus must not steal the selection back")
    XCTAssertNotNil(onlySplit(store), "and the split itself is untouched — it persists")
  }

  func testSurfaceFocusIsNoOpWithoutSplit() {
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.addTab(for: store.target(for: b)!)
    store.selectedTargetID = a  // no split active
    store.terminals.onSurfaceFocused?(store.target(for: b)!.id)
    XCTAssertEqual(
      store.selectedTargetID, a, "no split → a surface focus must not retarget the workroom")
  }

  // MARK: on-screen targets (notification suppression for co-displayed members — issue #23)

  func testOnScreenTargetIncludesCoDisplayedSplitMember() {
    // With the split shown, the focused member is `selectedTarget` AND the other members render beside
    // it — so a co-displayed non-selected member must read as on screen, so `handleActivity` can
    // border-pulse its visible panes (issue #82) and tell on-screen activity from off-screen when
    // deciding whether the event is "seen" (issue #89).
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.addTab(for: store.target(for: b)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b]; focuses b
    store.selectedTargetID = a  // focus a → b is the co-displayed, non-selected member
    XCTAssertEqual(
      store.onScreenTarget(forID: store.target(for: b)!.id)?.id, store.target(for: b)!.id,
      "the co-displayed split member is on screen")
    XCTAssertEqual(
      store.onScreenTarget(forID: store.target(for: a)!.id)?.id, store.target(for: a)!.id,
      "the focused member is on screen")
  }

  func testOnScreenTargetExcludesHiddenSplitMember() {
    let store = store3()
    let a = wr("main")
    let b = wr("feature")
    store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.addTab(for: store.target(for: b)!)
    store.insertWorkroomSplit(b, beside: a, edge: .right)  // split [a, b]
    store.selectedTargetID = wr("bugfix")  // a non-member is selected → the split is hidden
    XCTAssertNil(
      store.onScreenTarget(forID: store.target(for: b)!.id),
      "a hidden split member's panes are not on screen")
    XCTAssertNotNil(
      store.onScreenTarget(forID: store.target(for: wr("bugfix"))!.id),
      "the selected solo target is on screen")
  }

  // MARK: many groups — a window holds SEVERAL split groups at once

  /// Four workrooms + a bar order + a tab each, so grouping two pairs is possible and the chips are all
  /// active in the bar (what `displayedWorkroomTargets` reads).
  private func store4() -> AppStore {
    let names = ["main", "feature", "docs", "review"]
    let store = makeStore([project("/a", workrooms: names)])
    store.workroomTabOrder = names.map { TerminalTarget.workroomID(project: "/a", name: $0) }
    for name in names { store.terminals.addTab(for: store.target(for: wr(name))!) }
    return store
  }

  func testSecondGroupDoesNotDissolveTheFirst() {
    // The reported fault: grouping two solo workrooms un-split the existing group, because the store
    // held ONE layout. Groups are a list now — both survive.
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)
    XCTAssertEqual(
      groupSets(store), [[wr("main"), wr("feature")], [wr("docs"), wr("review")]],
      "both groups coexist")
    XCTAssertEqual(store.selectedTargetID, wr("review"), "the newly dropped member is focused")
    XCTAssertTrue(store.workroomSplitActive)
  }

  func testMovingAMemberOutOfALargerGroupCollapsesItAndSeedsANewOne() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    // → one group of [main, feature, docs]
    store.insertWorkroomSplit(wr("docs"), beside: wr("feature"), edge: .bottom)
    // Drag "docs" beside the ungrouped "review": it leaves its group (which keeps two members) and
    // seeds a second group — the move semantics, now across groups.
    store.insertWorkroomSplit(wr("docs"), beside: wr("review"), edge: .right)
    XCTAssertEqual(
      groupSets(store), [[wr("main"), wr("feature")], [wr("review"), wr("docs")]],
      "the old group collapsed to two, the new one holds the moved member — no duplicate leaf")
  }

  func testMovingAMemberOutOfAPairDissolvesOnlyThatGroup() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B
    // Drag A's "feature" into B: A drops below two members and dissolves; B grows to three.
    store.insertWorkroomSplit(wr("feature"), beside: wr("docs"), edge: .bottom)
    XCTAssertEqual(
      groupSets(store), [[wr("docs"), wr("review"), wr("feature")]],
      "the emptied group is gone, the joined one holds three — and no duplicate leaf")
    XCTAssertEqual(store.selectedTargetID, wr("feature"))
  }

  func testRemoveMemberTouchesOnlyItsOwnGroup() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B
    store.removeWorkroomSplitMember(wr("review"))  // dissolves B only
    XCTAssertEqual(groupSets(store), [[wr("main"), wr("feature")]], "group A is untouched")
    XCTAssertEqual(store.selectedTargetID, wr("docs"), "the removed member yields to B's survivor")
  }

  func testDisplayedWorkroomTargetsGroupsEveryGroupContiguously() {
    // Bar order [main, docs, feature, review]; groups {main, feature} and {docs, review} interleave.
    // Each group is pulled into a contiguous run at its own earliest member's slot.
    let store = store4()
    store.workroomTabOrder = ["main", "docs", "feature", "review"].map {
      TerminalTarget.workroomID(project: "/a", name: $0)
    }
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)
    XCTAssertEqual(
      store.displayedWorkroomTargets().map(\.sid),
      [wr("main"), wr("feature"), wr("docs"), wr("review")])
  }

  func testVisibleSplitFollowsSelectionAcrossGroups() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B (selected)
    XCTAssertEqual(
      Set(store.visibleWorkroomLayout(for: wr("review")).tabIDs), [wr("docs"), wr("review")],
      "the selected member's OWN group renders")
    XCTAssertTrue(store.isWorkroomSplitVisible)
    XCTAssertEqual(
      Set(store.resolvedSplitLeaves()?.map(\.sid) ?? []), [wr("docs"), wr("review")],
      "resolved leaves are the visible group's, not every group's")

    store.selectedTargetID = wr("main")  // hop to group A
    XCTAssertEqual(
      Set(store.visibleWorkroomLayout(for: wr("main")).tabIDs), [wr("main"), wr("feature")])
    XCTAssertEqual(store.workroomSplits.count, 2, "hopping between groups dissolves neither")
  }

  func testSetRatioTargetsTheOwningGroup() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)
    store.setWorkroomSplitRatio(0.25, forSplit: rootSplitID(store, group: 1)!)
    XCTAssertEqual(rootRatio(store, group: 1) ?? -1, 0.25, accuracy: 0.0001)
    XCTAssertEqual(rootRatio(store, group: 0) ?? -1, 0.5, accuracy: 0.0001, "group A untouched")
  }

  func testEqualizeResizesOnlyTheVisibleGroup() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B, selected
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store, group: 0)!)  // skew group A
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store, group: 1)!)  // skew group B

    store.equalizeWorkroomSplit()  // selection is in group B
    XCTAssertEqual(
      rootRatio(store, group: 1) ?? -1, 0.5, accuracy: 0.0001, "the visible group evens")
    XCTAssertEqual(
      rootRatio(store, group: 0) ?? -1, 0.9, accuracy: 0.0001,
      "an off-screen group keeps its dividers — the menu item acts on what you see")
  }

  func testEqualizeIsNoOpWhenSelectionIsUngrouped() {
    // Selection outside every group with groups still stored: nothing is on screen to even out, so no
    // group may be touched (the old code would have equalized "the" split regardless of selection).
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store, group: 0)!)
    store.selectedTargetID = wr("docs")  // ungrouped
    store.equalizeWorkroomSplit()
    XCTAssertEqual(
      rootRatio(store, group: 0) ?? -1, 0.9, accuracy: 0.0001, "the hidden group is untouched")
    XCTAssertEqual(store.workroomSplits.count, 1, "and it isn't dissolved either")
  }

  func testPrunePrunesEveryGroup() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B
    // Delete "feature" and "review" out of the project list: BOTH groups drop to one live leaf, so both
    // dissolve — the prune walks every group, not just the visible one.
    store.projects = [project("/a", workrooms: ["main", "docs"])]
    store.selectedTargetID = nil  // mimic apply() nilling a dead selection before the prune
    store.pruneWorkroomSplitToLiveLeaves()
    XCTAssertTrue(store.workroomSplits.isEmpty, "both groups dissolved to a lone live leaf")
    XCTAssertEqual(store.selectedTargetID, wr("main"), "a dissolve re-selects a live survivor")
  }

  func testPruneMixesCollapseAndDissolveAcrossGroups() {
    // One call, two outcomes: group A loses a leaf but keeps two live members (prune, group survives),
    // group B drops to one live member (dissolve). Both must land in the same pass — a single-group
    // prune could never produce this mix.
    let names = ["main", "feature", "spike", "docs", "review"]
    let store = makeStore([project("/a", workrooms: names)])
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("spike"), beside: wr("feature"), edge: .bottom)  // A: 3 members
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // B: 2 members
    XCTAssertEqual(
      groupSets(store), [[wr("main"), wr("feature"), wr("spike")], [wr("docs"), wr("review")]],
      "precondition: a 3-member group and a pair")

    // "feature" (in A) and "review" (in B) deleted out of band.
    store.projects = [project("/a", workrooms: ["main", "spike", "docs"])]
    store.selectedTargetID = nil  // mimic apply() nilling a dead selection before the prune
    store.pruneWorkroomSplitToLiveLeaves()
    XCTAssertEqual(
      groupSets(store), [[wr("main"), wr("spike")]],
      "A pruned down to its two live members and survived; B dissolved")
    XCTAssertEqual(
      store.selectedTargetID, wr("docs"), "the dissolved group's survivor takes the nil selection")
  }

  func testPruneReSelectsInTheGroupTheUserWasViewing() {
    // Two groups, selection in the SECOND. A reload deletes one member of each — so both dissolve, and
    // the naive "first survivor in array order" would drop the user into group A, a split they were
    // never looking at. They must land on their OWN group's survivor.
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B, selected
    let former = store.selectedTargetID
    XCTAssertEqual(former, wr("review"), "precondition: viewing group B")

    store.projects = [project("/a", workrooms: ["main", "docs"])]  // feature + review deleted
    store.selectedTargetID = nil  // apply() nils the dead selection before pruning
    store.pruneWorkroomSplitToLiveLeaves(formerSelection: former)
    XCTAssertEqual(
      store.selectedTargetID, wr("docs"),
      "lands on group B's survivor, not group A's (which comes first in the array)")
  }

  func testPruneReSelectsInTheFormerGroupEvenWhenItSurvives() {
    // The other half of the same fault: the user's group merely loses the selected member and keeps ≥2
    // live ones, so it contributes no "dissolve survivor" — the re-point must still stay inside it
    // instead of jumping to an unrelated group that did dissolve.
    let names = ["main", "feature", "spike", "docs", "review"]
    let store = makeStore([project("/a", workrooms: names)])
    store.insertWorkroomSplit(wr("main"), beside: wr("docs"), edge: .right)  // A = [docs, main]
    store.insertWorkroomSplit(wr("spike"), beside: wr("feature"), edge: .right)  // group B
    store.insertWorkroomSplit(wr("review"), beside: wr("spike"), edge: .bottom)  // B = 3 members
    let former = store.selectedTargetID
    XCTAssertEqual(former, wr("review"), "precondition: viewing group B")

    // Kill B's selected member (B keeps feature + spike) and one of A's (A dissolves to docs).
    store.projects = [project("/a", workrooms: ["feature", "spike", "docs"])]
    store.selectedTargetID = nil
    store.pruneWorkroomSplitToLiveLeaves(formerSelection: former)
    XCTAssertEqual(
      Set(store.workroomSplits.first?.tabIDs ?? []), [wr("feature"), wr("spike")],
      "group B survived with its two live members")
    XCTAssertTrue(
      [wr("feature"), wr("spike")].contains(store.selectedTargetID),
      "selection stays inside the split the user was viewing, not on group A's leftover")
  }

  func testPruneFallsBackToAnySurvivorWithoutAFormerSelection() {
    // No former selection (or it was a solo workroom): the old behaviour — any dissolved group's
    // survivor — is still the right answer.
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.projects = [project("/a", workrooms: ["main", "docs", "review"])]  // feature deleted
    store.selectedTargetID = nil
    store.pruneWorkroomSplitToLiveLeaves()
    XCTAssertEqual(store.selectedTargetID, wr("main"))
  }

  func testOnScreenTargetExcludesAnotherGroupsMembers() {
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B, selected
    XCTAssertNotNil(
      store.onScreenTarget(forID: store.target(for: wr("docs"))!.id),
      "the visible group's co-displayed member is on screen")
    XCTAssertNil(
      store.onScreenTarget(forID: store.target(for: wr("feature"))!.id),
      "another group's panes are off screen — its activity is not 'seen'")
  }

  func testSurfaceFocusFromAnotherGroupIsIgnored() {
    // The stale-focus fault across groups: a member of the OTHER (hidden) group reporting first
    // responder must not select it — same reasoning as the hidden-split case above.
    let store = store4()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B, selected
    store.terminals.onSurfaceFocused?(store.target(for: wr("feature"))!.id)
    XCTAssertEqual(store.selectedTargetID, wr("review"), "a hidden group's focus claim is ignored")
    XCTAssertEqual(store.workroomSplits.count, 2)
  }

  // MARK: leaf-agnostic geometry (drop-planning math over SidebarID — issue #23 follow-up)

  func testPlanAndDropTargetResolveOverSidebarIDLeaves() {
    let a = wr("main")
    let b = wr("feature")
    let layout: PaneLayout<SidebarID> = .split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    let plan = PaneTreeLayout.plan(layout, in: CGRect(x: 0, y: 0, width: 400, height: 100))
    XCTAssertNotNil(plan.panes[a])
    XCTAssertNotNil(plan.panes[b])
    // A point deep in the right pane resolves to `b`, nearest edge `.right` — the same geometry the
    // terminal split uses, now proven leaf-agnostic at `SidebarID`.
    let hit = PaneTreeLayout.dropTarget(at: CGPoint(x: 380, y: 50), panes: plan.panes)
    XCTAssertEqual(hit?.tab, b)
    XCTAssertEqual(hit?.edge, .right)
  }

  // MARK: pane card frame (the focused member's primary cue)

  /// Tokens with a known foreground, so the hairline/neutral alphas are checkable. No palette, so
  /// `accent` is the system control accent — distinct from anything derived from the foreground.
  private var frameTokens: ThemeTokens {
    ThemeTokens(preview: nil, fallbackBackground: .black, fallbackForeground: .white)
  }

  func testFocusedPaneFrameIsAccentOnAKeyWindow() {
    let t = frameTokens
    XCTAssertEqual(
      WorkroomPaneCardBorder.tint(highlighted: true, active: true, tokens: t), t.accent,
      "the focused member's frame is the full-strength accent")
  }

  func testFocusedPaneFrameGoesNeutralOnABackgroundWindow() {
    let t = frameTokens
    let tint = WorkroomPaneCardBorder.tint(highlighted: true, active: false, tokens: t)
    XCTAssertEqual(
      tint, t.focused, "an inactive window drops the saturated accent, as the fill does")
    XCTAssertNotEqual(tint, t.accent)
    XCTAssertEqual(NSColor(tint).usingColorSpace(.sRGB)!.alphaComponent, 0.3, accuracy: 0.01)
  }

  func testUnfocusedPaneFrameIsTheNeutralHairline() {
    let t = frameTokens
    for active in [true, false] {
      let tint = WorkroomPaneCardBorder.tint(highlighted: false, active: active, tokens: t)
      XCTAssertEqual(tint, t.border, "unfocused members keep a faint edge (active: \(active))")
      XCTAssertEqual(NSColor(tint).usingColorSpace(.sRGB)!.alphaComponent, 0.12, accuracy: 0.01)
    }
  }

  // MARK: the highlight gate (the treatment is split-only)

  /// A solo pane is ALWAYS the model-focused one, so `focused` alone would hand it the accent frame,
  /// fill and deeper shadow — a selection cue with nothing to select among.
  func testASoloPaneIsNeverHighlighted() {
    XCTAssertFalse(
      WorkroomPaneCardBorder.isHighlighted(focused: true, multi: false),
      "a lone workroom has no peer to be picked out from")
    let t = frameTokens
    for active in [true, false] {
      let highlighted = WorkroomPaneCardBorder.isHighlighted(focused: true, multi: false)
      XCTAssertEqual(
        WorkroomPaneCardBorder.tint(highlighted: highlighted, active: active, tokens: t), t.border,
        "so it takes the neutral resting hairline, not the accent (active: \(active))")
    }
  }

  func testTheFocusedSplitMemberIsHighlighted() {
    XCTAssertTrue(WorkroomPaneCardBorder.isHighlighted(focused: true, multi: true))
    XCTAssertEqual(
      WorkroomPaneCardBorder.tint(highlighted: true, active: true, tokens: frameTokens),
      frameTokens.accent)
  }

  func testAnUnfocusedSplitMemberIsNotHighlighted() {
    XCTAssertFalse(WorkroomPaneCardBorder.isHighlighted(focused: false, multi: true))
  }
}

/// Auto-even on add/remove (issue #126). The gate is INTENT — each of these functions already knows
/// whether it is adding a member, removing one, or merely rearranging — so these tests drive the
/// real store functions rather than the pure transform, which `PaneGroupFitTests` covers.
///
/// `autoEvenSplits` is set directly rather than through `Defaults`: a parallel test worker shares
/// (and wipes) that domain cross-process, which is how `Defaults`-driven assertions turn flaky.
@MainActor
final class WorkroomSplitAutoEvenTests: XCTestCase {

  private func makeStore(_ names: [String]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: "/a", vcs: "git",
        workrooms: names.map {
          Workroom(name: $0, path: "/a/\($0)", vcsName: "workroom/\($0)", warnings: [])
        })
    ]
    // Roomy enough that evening is always honourable — the clamp interaction is covered by
    // `PaneGroupFitTests`, and a cramped default would make every assertion here read as a no-op.
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    return store
  }

  private func wr(_ name: String) -> SidebarID { .workroom(project: "/a", name: name) }

  private func rootRatio(_ store: AppStore, group: Int = 0) -> CGFloat? {
    guard store.workroomSplits.indices.contains(group) else { return nil }
    if case .split(_, _, let ratio, _, _) = store.workroomSplits[group] { return ratio }
    return nil
  }

  private func rootSplitID(_ store: AppStore, group: Int = 0) -> UUID? {
    guard store.workroomSplits.indices.contains(group) else { return nil }
    if case .split(let id, _, _, _, _) = store.workroomSplits[group] { return id }
    return nil
  }

  /// `main | (feature / bugfix)` — the shape where a naive 0.5 leaves `main` at half the window and
  /// the other two at a quarter each.
  private func threePaneStore() -> AppStore {
    let store = makeStore(["main", "feature", "bugfix"])
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    return store
  }

  func testAThirdMemberEvensTheGroup() {
    let store = threePaneStore()
    XCTAssertEqual(
      rootRatio(store) ?? -1, 1.0 / 3.0, accuracy: 0.0001,
      "main is 1 of 3 leaves, so it gets a third of the width")
  }

  func testAnInsertEvensAwayASkewedDivider() {
    let store = makeStore(["main", "feature", "bugfix"])
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store)!)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    XCTAssertEqual(rootRatio(store) ?? -1, 1.0 / 3.0, accuracy: 0.0001)
  }

  func testRemovingAMemberEvensTheSurvivors() {
    // `main | (feature / bugfix)` at root 1/3: dropping bugfix collapses it to `main | feature`,
    // which would otherwise KEEP the 1/3 budgeted for three panes and leave a 33/67 pair.
    let store = threePaneStore()
    store.removeWorkroomSplitMember(wr("bugfix"))
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [wr("main"), wr("feature")])
    XCTAssertEqual(rootRatio(store) ?? -1, 0.5, accuracy: 0.0001, "two survivors split evenly")
  }

  /// THE defect the leaf-count design had. `insertWorkroomSplit` detaches before it inserts, so a
  /// count-delta gate fires on both halves of a same-group move and evens a pure rearrange twice.
  /// Must be tested with THREE members: a two-member same-group move dissolves and re-appends at
  /// 0.5 regardless, so it would pass vacuously.
  func testASameGroupRearrangeKeepsItsDividers() {
    let store = threePaneStore()
    store.setWorkroomSplitRatio(0.7, forSplit: rootSplitID(store)!)
    let before = store.workroomSplits
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .right)
    XCTAssertEqual(
      rootRatio(store) ?? -1, 0.7, accuracy: 0.0001,
      "a rearrange within the group must not even — the panes are the same ones")
    XCTAssertEqual(
      Set(store.workroomSplits.first?.tabIDs ?? []), Set(before.first?.tabIDs ?? []),
      "and the same members remain")
  }

  func testAnInsertEvensOnlyItsOwnGroup() {
    let store = makeStore(["main", "feature", "docs", "review"])
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // group A
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .right)  // group B
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store, group: 0)!)
    store.insertWorkroomSplit(wr("review"), beside: wr("docs"), edge: .bottom)  // rearrange in B
    XCTAssertEqual(
      rootRatio(store, group: 0) ?? -1, 0.9, accuracy: 0.0001, "group A is untouched")
  }

  func testAGhostLeafIsPrunedBeforeEvening() {
    // A group still holding a leaf for a deleted workroom: the renderer hides it, but evening the
    // raw tree would budget a third of the width for a pane nobody can see.
    let store = makeStore(["main", "feature"])
    store.workroomSplits = [
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.9,
        first: .leaf(wr("deleted")), second: .leaf(wr("main")))
    ]
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    XCTAssertEqual(
      store.workroomSplits.first?.tabIDs, [wr("main"), wr("feature")], "the ghost leaf is gone")
    XCTAssertEqual(rootRatio(store) ?? -1, 0.5, accuracy: 0.0001, "and the live panes are even")
  }

  func testTheSweepEvensAGroupThatLostAWorkroom() {
    // An EXTERNAL delete (CLI, another window): the workroom vanishes from the project list, so the
    // reload's sweep prunes the leaf — and the survivors are left budgeted for three panes.
    let store = threePaneStore()
    store.selectedTargetID = wr("main")
    store.projects = [
      Project(
        path: "/a", vcs: "git",
        workrooms: ["main", "feature"].map {
          Workroom(name: $0, path: "/a/\($0)", vcsName: "workroom/\($0)", warnings: [])
        })
    ]
    store.pruneWorkroomSplitToLiveLeaves(formerSelection: wr("main"))
    XCTAssertEqual(store.workroomSplits.first?.tabIDs, [wr("main"), wr("feature")])
    XCTAssertEqual(rootRatio(store) ?? -1, 0.5, accuracy: 0.0001)
  }

  func testPrefOffKeepsEveryDivider() {
    let store = makeStore(["main", "feature", "bugfix"])
    store.autoEvenSplits = { false }
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store)!)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    XCTAssertEqual(rootRatio(store) ?? -1, 0.9, accuracy: 0.0001, "the insert left it alone")
    store.removeWorkroomSplitMember(wr("bugfix"))
    XCTAssertEqual(rootRatio(store) ?? -1, 0.9, accuracy: 0.0001, "and so did the removal")
  }

  func testTheMenuActionStillEvensWithThePrefOff() {
    // An explicit command must work regardless of the setting — that's what the setting turns off,
    // the automatic behaviour, not the feature.
    let store = makeStore(["main", "feature"])
    store.autoEvenSplits = { false }
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.setWorkroomSplitRatio(0.9, forSplit: rootSplitID(store)!)
    store.selectedTargetID = wr("main")
    store.equalizeWorkroomSplit()
    XCTAssertEqual(rootRatio(store) ?? -1, 0.5, accuracy: 0.0001)
  }

  func testACrampedContainerKeepsTheDividersInstead() {
    // Too narrow for three panes to render evenly (the renderer's per-axis floor clamp would
    // override the evened ratios), so the honourable move is to leave the dividers alone.
    let store = makeStore(["main", "feature", "bugfix"])
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 800, height: 900)
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.setWorkroomSplitRatio(0.6, forSplit: rootSplitID(store)!)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    XCTAssertEqual(rootRatio(store) ?? -1, 0.6, accuracy: 0.0001)
  }

  func testAGroupWithRoomAdmitsASplitThatTheAnchorAloneWouldRefuse() {
    // The floor is group-aware now (TD1): the anchor pane is well under 2 × 300pt, but evening
    // redistributes the whole 1800pt group, so all three panes clear the floor and the split stands.
    let store = makeStore(["main", "feature", "bugfix"])
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.setWorkroomSplitRatio(0.75, forSplit: rootSplitID(store)!)  // feature ≈ 448pt
    XCTAssertTrue(
      store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .right),
      "the group has room for a third pane even though the anchor can't be halved")
    XCTAssertEqual(store.workroomSplits.first?.tabIDs.count, 3)
  }

  func testAGroupWithNoRoomStillRefuses() {
    let store = makeStore(["main", "feature", "bugfix"])
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 700, height: 900)
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    XCTAssertFalse(
      store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .right),
      "three 300pt panes cannot fit in 700pt, however the space is shared out")
    XCTAssertEqual(store.workroomSplits.first?.tabIDs.count, 2)
  }
}
