import XCTest

@testable import Workroom

/// Store-level tests for the workroom-into-workroom split (issue #23 follow-up): the pure transforms on
/// `AppStore.workroomSplit` (insert with move-semantics, remove/collapse/dissolve, setRatio), the
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

  private func rootRatio(_ store: AppStore) -> CGFloat? {
    if case .split(_, _, let ratio, _, _) = store.workroomSplit { return ratio }
    return nil
  }

  private func rootSplitID(_ store: AppStore) -> UUID? {
    if case .split(let id, _, _, _, _) = store.workroomSplit { return id }
    return nil
  }

  // MARK: insert

  func testInsertSeedsTwoLeafSplitFromSelection() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    // right ⇒ the dropped member lands trailing, so the anchor (main) is first.
    XCTAssertEqual(store.workroomSplit?.tabIDs, [wr("main"), wr("feature")])
    XCTAssertEqual(store.selectedTargetID, wr("feature"), "the dropped member is focused")
    XCTAssertTrue(store.workroomSplitActive)
  }

  func testInsertGrowsToThreeLeaves() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    XCTAssertEqual(
      Set(store.workroomSplit?.tabIDs ?? []), [wr("main"), wr("feature"), wr("bugfix")])
    XCTAssertEqual(store.workroomSplit?.tabIDs.count, 3)
  }

  func testInsertMovingExistingMemberIsNotADuplicate() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)  // [main, feature]
    // Drag "main" (already a member) beside "feature": a move, not a duplicate.
    store.insertWorkroomSplit(wr("main"), beside: wr("feature"), edge: .right)
    XCTAssertEqual(store.workroomSplit?.tabIDs.count, 2, "move, not duplicate")
    XCTAssertEqual(Set(store.workroomSplit?.tabIDs ?? []), [wr("main"), wr("feature")])
  }

  func testInsertSelfDropIsNoOp() {
    let store = store3()
    store.insertWorkroomSplit(wr("main"), beside: wr("main"), edge: .right)
    XCTAssertNil(store.workroomSplit)
  }

  func testInsertRejectsNonResolvingLeaf() {
    let store = store3()
    // `.project` is never a target, and an unknown workroom doesn't resolve — both must be rejected.
    store.insertWorkroomSplit(.project("/a"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("ghost"), beside: wr("main"), edge: .right)
    XCTAssertNil(store.workroomSplit)
  }

  func testInsertRejectsMissingWorkroom() {
    // A workroom whose directory is gone (`isMissing`) resolves in the list but must not be draggable
    // into a split — it would render a "Directory not found" pane you can only back out of (issue #23).
    let store = makeStore([project("/a", present: ["main"], missing: ["gone"])])
    store.insertWorkroomSplit(wr("gone"), beside: wr("main"), edge: .right)
    XCTAssertNil(store.workroomSplit, "a missing workroom is rejected as a drop source")
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
    XCTAssertEqual(store.workroomSplit?.tabIDs, [wr("main", in: "/a"), wr("feature", in: "/b")])
    XCTAssertEqual(store.selectedTargetID, wr("feature", in: "/b"), "the dropped member is focused")
    XCTAssertTrue(store.workroomSplitActive)
  }

  // MARK: remove / dissolve

  func testRemoveCollapsesThreeToTwo() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.insertWorkroomSplit(wr("bugfix"), beside: wr("feature"), edge: .bottom)
    store.removeWorkroomSplitMember(wr("bugfix"))
    XCTAssertEqual(Set(store.workroomSplit?.tabIDs ?? []), [wr("main"), wr("feature")])
  }

  func testRemoveDissolvesBelowTwoAndReselectsSurvivor() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.selectedTargetID = wr("feature")
    store.removeWorkroomSplitMember(wr("feature"))
    XCTAssertNil(store.workroomSplit, "below two members → dissolve to single")
    XCTAssertEqual(
      store.selectedTargetID, wr("main"), "the removed-and-focused member yields to the survivor")
  }

  func testRemoveNonMemberIsNoOp() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.removeWorkroomSplitMember(wr("bugfix"))  // not in the split
    XCTAssertEqual(store.workroomSplit?.tabIDs.count, 2)
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
    XCTAssertNil(store.workroomSplit, "emptying a 2-member split's pane dissolves the split")
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
      Set(store.workroomSplit?.tabIDs ?? []), [a, b], "the emptied member leaves a 2-member split")
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
    XCTAssertNil(store.workroomSplit, "the split dissolves to the survivor")
    XCTAssertEqual(store.selectedTargetID, a, "selection stays on the still-focused survivor")
  }

  func testClosingLastTerminalInSoloWorkroomLeavesNoSplit() {
    let store = store3()
    let a = wr("main")
    let aTab = store.terminals.addTab(for: store.target(for: a)!)
    store.terminals.closeTab(aTab.id, for: store.target(for: a)!)  // no split active
    XCTAssertNil(store.workroomSplit, "a solo workroom has no split to close — and must not crash")
  }

  // MARK: persistence — split survives selecting a non-member (grouping like terminal tabs)

  func testSplitPersistsAndHidesWhenSelectingNonMember() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    // Split is main+feature. Select a non-member → its solo layout shows, split NOT discarded.
    store.selectedTargetID = wr("bugfix")
    XCTAssertEqual(store.visibleWorkroomLayout(for: wr("bugfix")), .leaf(wr("bugfix")))
    XCTAssertFalse(store.isWorkroomSplitVisible)
    XCTAssertNotNil(store.workroomSplit, "the split persists while a non-member is shown")
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
    XCTAssertNil(store.workroomSplit)
  }

  func testEqualizePrunesDeadLeavesFirst() {
    // A stored split holding a dead leaf (not in the project list, so `target(for:)` is nil) must be
    // pruned before weighting — otherwise it budgets space for a ghost pane and the visible panes end
    // uneven (Codex #2). Set the tree directly since `insertWorkroomSplit` rejects non-resolving leaves.
    let store = store3()
    store.workroomSplit = .split(
      id: UUID(), orientation: .horizontal, ratio: 0.9,
      first: .leaf(wr("deleted")),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.9,
        first: .leaf(wr("main")), second: .leaf(wr("feature"))))
    store.equalizeWorkroomSplit()
    XCTAssertEqual(store.workroomSplit?.tabIDs, [wr("main"), wr("feature")], "ghost leaf pruned")
    XCTAssertEqual(rootRatio(store) ?? -1, 0.5, accuracy: 0.0001, "two live panes split evenly")
  }

  func testEqualizeDissolvesWhenOneLiveLeafRemains() {
    let store = store3()
    store.workroomSplit = .split(
      id: UUID(), orientation: .horizontal, ratio: 0.7,
      first: .leaf(wr("deleted")), second: .leaf(wr("main")))
    store.equalizeWorkroomSplit()
    XCTAssertNil(store.workroomSplit, "only one live leaf → no split")
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
    XCTAssertEqual(Set(store.workroomSplit?.tabIDs ?? []), [wr("main"), wr("bugfix")])
  }

  func testPruneDissolvesWhenBelowTwoLiveAndReselects() {
    let store = store3()
    store.insertWorkroomSplit(wr("feature"), beside: wr("main"), edge: .right)
    store.selectedTargetID = nil  // mimic apply() having nilled a dead selection before prune
    store.projects = [project("/a", workrooms: ["main"])]  // only "main" survives
    store.pruneWorkroomSplitToLiveLeaves()
    XCTAssertNil(store.workroomSplit)
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
    XCTAssertNotNil(store.workroomSplit, "and the split itself is untouched — it persists")
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
}
