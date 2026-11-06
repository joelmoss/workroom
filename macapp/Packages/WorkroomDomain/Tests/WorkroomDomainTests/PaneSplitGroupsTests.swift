import CoreGraphics
import WorkroomDomain
import XCTest

/// The split-group rules both splits share (`PaneSplitGroups`): the workroom split of a window and
/// the terminal split of a target. The axis rules of auto-even (issue #126) live here once; each
/// caller's suite keeps the tests of its own wiring — which edit each action makes, and the policy it
/// passes (`WorkroomSplitAutoEvenTests`, `TerminalSplitAutoEvenTests`).
///
/// Several cases here merge a pair that each caller's suite used to carry, word for word, against
/// its own copy of the rule, or moved here from one of them; the doc of each says which ("Merges",
/// "Moved from"). Where a caller's test still stands for its wiring, the doc says that instead.
final class PaneSplitGroupsTests: XCTestCase {
  private typealias Groups = PaneSplitGroups<String>

  /// Roomy enough that evening is always honourable, as both callers' auto-even suites set up.
  private let roomy = CGRect(x: 0, y: 0, width: 1800, height: 1000)

  private func policy(
    space: CGRect? = CGRect(x: 0, y: 0, width: 1800, height: 1000), autoEven: Bool = true,
    leafSlots: ((String, SplitOrientation) -> Int)? = nil,
    live: @escaping (PaneLayout<String>) -> PaneLayout<String> = { $0 }
  ) -> PaneSplitPolicy<String> {
    PaneSplitPolicy(space: space, autoEven: autoEven, leafSlots: leafSlots, live: live)
  }

  private func rootRatio(_ groups: Groups, group: Int = 0) -> CGFloat? {
    guard groups.groups.indices.contains(group),
      case .split(_, _, let ratio, _, _) = groups.groups[group]
    else { return nil }
    return ratio
  }

  private func rootSplitID(_ groups: Groups, group: Int = 0) -> UUID? {
    guard groups.groups.indices.contains(group),
      case .split(let id, _, _, _, _) = groups.groups[group]
    else { return nil }
    return id
  }

  private func settingRoot(_ ratio: CGFloat, _ groups: Groups, group: Int = 0) -> Groups {
    groups.settingRatio(ratio, forSplit: rootSplitID(groups, group: group)!)!
  }

  /// `a`, then each `(leaf, beside, edge)` inserted in turn under `policy`.
  private func built(
    _ steps: [(String, String, PaneEdge)], policy: PaneSplitPolicy<String>? = nil
  ) -> Groups {
    let policy = policy ?? self.policy()
    return steps.reduce(Groups()) { $0.inserting($1.0, beside: $1.1, edge: $1.2, policy: policy) }
  }

  /// `a | b | c`, three columns.
  private func threeColumns(policy: PaneSplitPolicy<String>? = nil) -> Groups {
    built([("b", "a", .right), ("c", "b", .right)], policy: policy)
  }

  /// `a | (b / c)` — the shape where a naive 0.5 leaves `a` at half the width.
  private func threePanes() -> Groups {
    built([("b", "a", .right), ("c", "b", .bottom)])
  }

  private func widths(
    _ groups: Groups, in rect: CGRect = CGRect(x: 0, y: 0, width: 1800, height: 1000)
  )
    -> [String: CGFloat]
  {
    PaneTreeLayout.plan(groups.groups[0], in: rect).panes.mapValues(\.width)
  }

  // MARK: Inserting

  func testInsertingBesideASoloLeafSeedsAGroupOnTheDroppedSide() {
    let right = Groups().inserting("b", beside: "a", edge: .right, policy: policy())
    XCTAssertEqual(right.groups.map(\.tabIDs), [["a", "b"]])
    let left = Groups().inserting("b", beside: "a", edge: .left, policy: policy())
    XCTAssertEqual(left.groups.map(\.tabIDs), [["b", "a"]], "a left drop lands first")
  }

  /// Merges the workroom suite's and the terminal suite's
  /// `testATopBottomSplitKeepsTheLeftRightDividers`. `a | (b / c)`: a top/bottom split divides
  /// height only, so the left/right divider the user dragged stays where it was. The skew is what
  /// makes this discriminate — at 0.5 it would pass whether or not the split touched the other axis.
  func testATopBottomSplitKeepsTheLeftRightDividers() {
    let groups = settingRoot(0.8, built([("b", "a", .right)]))
      .inserting("c", beside: "b", edge: .bottom, policy: policy())
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.8, accuracy: 0.0001)
  }

  /// Merges both suites' `testALeftRightSplitKeepsTheTopBottomDividers`: `a / (b | c)` keeps the
  /// top/bottom divider the user dragged.
  func testALeftRightSplitKeepsTheTopBottomDividers() {
    let groups = settingRoot(0.3, built([("b", "a", .bottom)]))
      .inserting("c", beside: "b", edge: .right, policy: policy())
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.3, accuracy: 0.0001)
  }

  /// The rule behind the workroom suite's `testAThirdMemberOnTheSameAxisSplitsIntoThirds` and the
  /// terminal suite's `testAThirdPaneOnTheSameAxisSplitsIntoThirds`, which stay for each caller's
  /// wiring of an add.
  func testAThirdMemberOnTheSameAxisSplitsIntoThirds() {
    XCTAssertEqual(
      rootRatio(threeColumns()) ?? -1, 1.0 / 3.0, accuracy: 0.0001,
      "three columns in one chain are thirds")
  }

  /// Moved from the terminal suite. The report that reshaped the rule (#126): split down, then split
  /// the bottom pane sideways. The top pane is in a different row and must not move.
  func testSplittingOneRowSidewaysLeavesTheOtherRowAlone() {
    let groups = built([("b", "a", .bottom), ("c", "b", .right)])  // a / (b | c)
    XCTAssertEqual(
      rootRatio(groups) ?? -1, 0.5, accuracy: 0.0001,
      "the top row keeps its half of the height; only the bottom row divides")
    let panes = PaneTreeLayout.plan(
      groups.groups[0], in: CGRect(x: 0, y: 0, width: 1200, height: 900)
    ).panes
    let heights = Set(panes.values.map { Int($0.height) })
    XCTAssertEqual(heights, [449], "both rows are the same height")
  }

  /// Moved from the workroom suite: a rearrange in one group leaves another group's dividers alone.
  func testAnInsertEvensOnlyItsOwnGroup() {
    var groups = built([("b", "a", .right), ("d", "c", .right)])  // group A, group B
    groups = settingRoot(0.9, groups, group: 0)
    groups = groups.inserting("d", beside: "c", edge: .bottom, policy: policy())  // rearrange in B
    XCTAssertEqual(rootRatio(groups, group: 0) ?? -1, 0.9, accuracy: 0.0001, "group A is untouched")
  }

  /// Weights come from the policy (the workroom split counts a workroom's terminals): a leaf
  /// showing two panes side by side takes two thirds next to one showing one.
  func testAnInsertIsWeightedByThePolicysLeafSlots() {
    let weighted = policy(leafSlots: { leaf, axis in leaf == "a" && axis == .horizontal ? 2 : 1 })
    let groups = Groups().inserting("b", beside: "a", edge: .right, policy: weighted)
    XCTAssertEqual(rootRatio(groups) ?? -1, 2.0 / 3.0, accuracy: 0.0001)
  }

  /// A leaf the policy says the renderer no longer shows (the workroom split's ghost of a workroom
  /// deleted elsewhere) is pruned before the joined group is evened.
  func testAGhostLeafIsPrunedBeforeEvening() {
    let ghostFree = policy(live: { tree in tree.removingLeaf("ghost") ?? tree })
    let groups = Groups([
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.9, first: .leaf("ghost"), second: .leaf("a"))
    ]).inserting("b", beside: "a", edge: .right, policy: ghostFree)
    XCTAssertEqual(groups.groups.first?.tabIDs, ["a", "b"], "the ghost leaf is gone")
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.5, accuracy: 0.0001, "and the live panes are even")
  }

  /// When that even is declined, the group is stored as it grew, ghost and all: only an even prunes,
  /// and the sweep that runs on the next reload drops the ghost.
  func testADeclinedEvenStoresTheGroupAsItGrew() {
    let ghostFree = policy(autoEven: false, live: { tree in tree.removingLeaf("ghost") ?? tree })
    let groups = Groups([
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.9, first: .leaf("ghost"), second: .leaf("a"))
    ]).inserting("b", beside: "a", edge: .right, policy: ghostFree)
    XCTAssertEqual(groups.groups.first?.tabIDs, ["ghost", "a", "b"])
  }

  func testPrefOffKeepsEveryDivider() {
    let off = policy(autoEven: false)
    var groups = settingRoot(0.9, built([("b", "a", .right)], policy: off))
    groups = groups.inserting("c", beside: "b", edge: .right, policy: off)
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.9, accuracy: 0.0001, "the insert left it alone")
    groups = groups.removing("c", policy: off)
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.9, accuracy: 0.0001, "and so did the removal")
  }

  /// No layout pass yet: nothing to judge, so even optimistically rather than withhold the behaviour
  /// on the very first split of a session.
  func testAnUnmeasuredContainerStillEvens() {
    let unmeasured = policy(space: nil)
    var groups = settingRoot(0.8, built([("b", "a", .right)], policy: unmeasured))
    groups = groups.inserting("c", beside: "b", edge: .right, policy: unmeasured)
    XCTAssertEqual(rootRatio(groups) ?? -1, 1.0 / 3.0, accuracy: 0.0001, "three columns are thirds")
  }

  // MARK: Moving

  /// The rule behind the workroom suite's `testASameGroupRearrangeEvensTheGroup` and the terminal
  /// suite's `testARearrangeWithinTheSplitEvensIt`, which stay for each caller's wiring of a
  /// rearrange. `a | b | c` with c dragged left of a rebuilds the tree
  /// as `(c | a) | b`; left alone that is ¼, ¼, ½. Must be tested with THREE members: a two-member
  /// same-group move dissolves and re-pairs at 0.5 regardless, so it would pass vacuously.
  func testASameGroupRearrangeEvensTheGroup() {
    let groups = threeColumns().inserting("c", beside: "a", edge: .left, policy: policy())
    XCTAssertEqual(groups.groups.count, 1)
    let widths = widths(groups)
    XCTAssertEqual(Set(widths.keys), ["a", "b", "c"])
    XCTAssertLessThanOrEqual(
      widths.values.max()! - widths.values.min()!, 1, "three even columns: \(widths)")
  }

  /// Merges the workroom suite's `testASameGroupRearrangeAlongOneAxisKeepsTheOtherAxisDividers` and
  /// the terminal suite's `testARearrangeAlongOneAxisKeepsTheOtherAxisDividers`. `a | (b / c)`:
  /// moving b below c rearranges top/bottom only, so the left/right divider the user dragged stays.
  func testASameGroupRearrangeAlongOneAxisKeepsTheOtherAxisDividers() {
    let groups = settingRoot(0.7, threePanes())
      .inserting("b", beside: "c", edge: .bottom, policy: policy())
    XCTAssertEqual(groups.groups.first?.tabIDs, ["a", "c", "b"])
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.7, accuracy: 0.0001)
  }

  /// Merges the workroom suite's `testASameGroupRearrangeAcrossAxesEvensBoth` and the terminal
  /// suite's `testARearrangeAcrossAxesEvensBoth`. `a | (b / c / d)` rows at thirds. Dragging c beside
  /// a leaves `b / d` at the old third, so evening only the axis c joined would keep b short.
  func testASameGroupRearrangeAcrossAxesEvensBoth() {
    let groups = built([("b", "a", .right), ("c", "b", .bottom), ("d", "c", .bottom)])
      .inserting("c", beside: "a", edge: .right, policy: policy())
    XCTAssertEqual(groups.groups.count, 1)
    let panes = PaneTreeLayout.plan(groups.groups[0], in: roomy).panes
    let widths = ["a", "c", "b"].map { panes[$0]!.width }
    XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1, "three even columns: \(widths)")
    XCTAssertEqual(
      panes["b"]!.height, panes["d"]!.height, accuracy: 1, "b and d split the height evenly")
  }

  func testPrefOffKeepsARearrangeAsBuilt() {
    let off = policy(autoEven: false)
    let groups = threeColumns(policy: off)  // a | (b | c) at halves: ½, ¼, ¼
      .inserting("c", beside: "a", edge: .left, policy: off)
    let widths = widths(groups)
    XCTAssertGreaterThan(
      widths.values.max()! - widths.values.min()!, 100, "left as rebuilt: \(widths)")
  }

  /// Three columns built roomy, then the window shrank: thirds of 800pt fall under the 300pt floor,
  /// so the rebuilt `(c | a) | b` keeps its dividers.
  func testACrampedRearrangeDeclinesToEven() {
    let groups = threeColumns().inserting(
      "c", beside: "a", edge: .left,
      policy: policy(space: CGRect(x: 0, y: 0, width: 800, height: 900)))
    XCTAssertEqual(groups.groups.first?.tabIDs.count, 3, "the move was made")
    let widths = widths(groups)
    XCTAssertGreaterThan(widths.values.max()! - widths.values.min()!, 100, "not evened: \(widths)")
  }

  /// The rule behind the workroom suite's `testACrossGroupMoveEvensTheSourceGroupToo`, which stays
  /// for its wiring. Dragging a member into another group REMOVES it from its own, so the survivors
  /// it leaves owe the same even-out a removal gives them.
  func testACrossGroupMoveEvensTheSourceGroupToo() {
    let groups = settingRoot(0.8, threeColumns())
      .inserting("c", beside: "d", edge: .right, policy: policy())
    let source = groups.groups.first { Set($0.tabIDs) == ["a", "b"] }
    guard case .split(_, _, let ratio, _, _) = source else { return XCTFail("expected a split") }
    XCTAssertEqual(ratio, 0.5, accuracy: 0.0001, "the survivors of the group it LEFT are evened")
    XCTAssertEqual(groups.group(containing: "c")?.tabIDs, ["d", "c"])
  }

  /// Moved from the workroom suite: c left a top/bottom split, so no width in its old group changes.
  func testACrossGroupMoveKeepsTheSourceGroupsOtherAxisDividers() {
    let groups = settingRoot(0.8, threePanes())
      .inserting("c", beside: "d", edge: .right, policy: policy())
    let source = groups.groups.first { Set($0.tabIDs) == ["a", "b"] }
    guard case .split(_, _, let ratio, _, _) = source else { return XCTFail("expected a split") }
    XCTAssertEqual(ratio, 0.8, accuracy: 0.0001)
  }

  /// A drag between groups that empties its own group re-finds the destination afterwards: removing
  /// the last-but-one member DELETES a group, and the destination's index shifts down with it.
  func testMovingOutOfATwoPaneGroupJoinsTheDestinationRatherThanSeedingAnother() {
    let groups = built([("b", "a", .right), ("d", "c", .right)])
      .inserting("a", beside: "c", edge: .bottom, policy: policy())
    XCTAssertEqual(groups.groups.count, 1, "the first group dissolved, the second grew")
    XCTAssertEqual(Set(groups.groups[0].tabIDs), ["a", "c", "d"])
    XCTAssertNil(groups.group(containing: "b"), "b is solo again")
  }

  func testAddsMemberOnlyAcrossGroupsOrFromSolo() {
    let groups = built([("b", "a", .right), ("d", "c", .right)])
    XCTAssertFalse(groups.addsMember("b", beside: "a"), "a rearrange within one group")
    XCTAssertTrue(groups.addsMember("b", beside: "c"), "across groups")
    XCTAssertTrue(groups.addsMember("e", beside: "a"), "in from solo")
    XCTAssertTrue(groups.addsMember("e", beside: "f"), "two solo leaves")
  }

  // MARK: Removing

  /// The rule behind the workroom suite's `testRemovingAMemberEvensTheSurvivors` and the terminal
  /// suite's `testClosingAPaneEvensTheSurvivors`, which stay for each caller's wiring of a removal:
  /// `a | b | c` at 0.8 collapses to `a | b`, which must not keep the 0.8 dragged for three panes.
  func testRemovingAMemberEvensTheSurvivors() {
    let groups = settingRoot(0.8, threeColumns()).removing("c", policy: policy())
    XCTAssertEqual(groups.groups.first?.tabIDs, ["a", "b"])
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.5, accuracy: 0.0001, "two survivors split evenly")
  }

  /// Moved from the workroom suite. `a | (b / c)`: removing c frees height only, so the left/right
  /// divider the user dragged stays.
  func testRemovingAMemberKeepsTheOtherAxisDividers() {
    let groups = settingRoot(0.8, threePanes()).removing("c", policy: policy())
    XCTAssertEqual(groups.groups.first?.tabIDs, ["a", "b"])
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.8, accuracy: 0.0001)
  }

  /// Moved from the terminal suite (`testClosingAPaneInAGridKeepsTheOtherAxisDividers`). Two columns
  /// each split top/bottom, then one pane closed: the left column collapses to one full-height pane,
  /// and no pane's width changes.
  func testRemovingAPaneInAGridKeepsTheOtherAxisDividers() {
    var groups = built([("b", "a", .right), ("c", "a", .bottom), ("d", "b", .bottom)])
    XCTAssertEqual(groups.groups.first?.tabIDs.count, 4)
    groups = settingRoot(0.8, groups).removing("c", policy: policy())
    XCTAssertEqual(groups.groups.first?.tabIDs.count, 3)
    XCTAssertEqual(
      rootRatio(groups) ?? -1, 0.8, accuracy: 0.0001,
      "the removal freed height only, so the left/right divider the user dragged stays")
  }

  /// Four columns built roomy, then the window shrank, then one closed: evening the three survivors
  /// wants thirds (≈266pt) against a 300pt floor, so the stored dividers survive untouched.
  func testACrampedRemovalDeclinesToEven() {
    let four = built([("b", "a", .right), ("c", "b", .right), ("d", "c", .right)])
    let groups = settingRoot(0.62, four).removing(
      "d", policy: policy(space: CGRect(x: 0, y: 0, width: 800, height: 900)))
    XCTAssertEqual(groups.groups.first?.tabIDs.count, 3, "three columns survive")
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.62, accuracy: 0.0001)
  }

  func testRemovingFromAPairDissolvesOnlyThatGroup() {
    let groups = built([("b", "a", .right), ("d", "c", .right)]).removing("b", policy: policy())
    XCTAssertEqual(groups.groups.map(\.tabIDs), [["c", "d"]])
  }

  func testRemovingASoloLeafChangesNothing() {
    let groups = threeColumns()
    XCTAssertEqual(groups.removing("z", policy: policy()), groups)
  }

  // MARK: Fit

  /// Merges both suites' `testAClampedOtherAxisDividerDoesNotBlockTheSplit`. The right column, asked
  /// for 0.2 of 1000pt, renders at the 300pt floor. Evening only the rows must not be vetoed by that
  /// untouched, clamped divider: three ~199pt rows fit in 600pt.
  func testAClampedOtherAxisDividerDoesNotBlockTheSplit() {
    let space = policy(space: CGRect(x: 0, y: 0, width: 1000, height: 600))
    var groups = settingRoot(0.8, built([("b", "a", .right)], policy: space))
    groups = groups.inserting("c", beside: "b", edge: .bottom, policy: space)
    XCTAssertEqual(groups.admits("d", beside: "c", edge: .bottom, policy: space), true)
    groups = groups.inserting("d", beside: "c", edge: .bottom, policy: space)
    XCTAssertEqual(groups.groups.first?.tabIDs.count, 4)
    XCTAssertEqual(rootRatio(groups) ?? -1, 0.8, accuracy: 0.0001, "and no width changed")
  }

  /// The floor is group-aware: an anchor too narrow to halve (448pt) may still take a third pane
  /// when evening shares 1800pt three ways.
  func testAGroupWithRoomAdmitsASplitThatTheAnchorAloneWouldRefuse() {
    let groups = built([("b", "a", .right)])
    XCTAssertFalse(
      PaneTreeLayout.canSplit(CGRect(x: 0, y: 0, width: 448, height: 900), along: .horizontal),
      "precondition: the anchor-only rule would refuse this width")
    XCTAssertEqual(groups.admits("c", beside: "b", edge: .right, policy: policy()), true)
  }

  func testACrampedContainerRefusesTheThirdColumn() {
    let cramped = policy(space: CGRect(x: 0, y: 0, width: 800, height: 900))
    let groups = built([("b", "a", .right)], policy: cramped)
    XCTAssertEqual(
      groups.admits("c", beside: "b", edge: .right, policy: cramped), false,
      "three 300pt columns cannot fit in 800pt")
  }

  /// A ghost leaf takes no room: `main | feature` fits in 700pt at 349 each once the ghost is gone.
  func testAGhostLeafDoesNotBlockASplitTheUserCanSee() {
    let ghostFree = policy(
      space: CGRect(x: 0, y: 0, width: 700, height: 900),
      live: { tree in tree.removingLeaf("ghost") ?? tree })
    let groups = Groups([
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("ghost"), second: .leaf("a"))
    ])
    XCTAssertEqual(groups.admits("b", beside: "a", edge: .right, policy: ghostFree), true)
  }

  /// Unmeasured (nil or empty space): no answer, so the caller falls back to the anchor's own rect.
  func testAnUnmeasuredContainerLeavesTheFitToTheCaller() {
    let groups = built([("b", "a", .right)])
    XCTAssertNil(groups.admits("c", beside: "b", edge: .right, policy: policy(space: nil)))
    XCTAssertNil(groups.admits("c", beside: "b", edge: .right, policy: policy(space: .zero)))
  }

  // MARK: Reading

  /// The rule behind the workroom suite's `testDisplayedWorkroomTargetsGroupsEveryGroupContiguously`
  /// and the terminal suite's `testSplitMembersStayContiguousInStrip`, which stay for each strip's own
  /// filtering: each group's members become one run, in tree order, at the slot of its earliest
  /// member.
  func testNormalizedPullsEachGroupIntoOneRunAtItsEarliestMember() {
    let groups = built([("e", "b", .left), ("d", "c", .right)])  // [e | b], [c | d]
    XCTAssertEqual(
      groups.normalized(["a", "b", "c", "x", "d", "e"]), ["a", "e", "b", "c", "d", "x"])
    XCTAssertEqual(Groups().normalized(["b", "a"]), ["b", "a"], "no groups: the order as given")
  }

  /// Members missing from the order still come out in their group's run; a caller showing only some
  /// leaves (the workroom bar, which has no chip for a member with no terminal) filters afterwards.
  func testNormalizedEmitsAMemberMissingFromTheOrderInItsRun() {
    let groups = built([("b", "a", .right)])
    XCTAssertEqual(groups.normalized(["x", "b"]), ["x", "a", "b"])
  }

  /// `member → group index`, first group winning a repeat (disjoint by construction, but a
  /// last-wins map would disagree with `group(containing:)`).
  func testGroupIndicesMapEachMemberToItsOwnGroupFirstGroupWinning() {
    let groups = Groups([
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("a"), second: .leaf("b")),
      .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("b"), second: .leaf("c")),
    ])
    XCTAssertEqual(groups.groupIndices, ["a": 0, "b": 0, "c": 1])
    XCTAssertEqual(groups.group(containing: "b")?.tabIDs, ["a", "b"])
  }

  // MARK: Ratios and re-evening

  func testSettingARatioTargetsTheGroupOwningTheNode() {
    let groups = built([("b", "a", .right), ("d", "c", .right)])
    let set = groups.settingRatio(0.7, forSplit: rootSplitID(groups, group: 1)!)
    XCTAssertEqual(rootRatio(set!, group: 0) ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(rootRatio(set!, group: 1) ?? -1, 0.7, accuracy: 0.0001)
    XCTAssertNil(groups.settingRatio(0.7, forSplit: UUID()), "no node, no new value to write")
  }

  /// A leaf's weight changed (a workroom split a terminal): its group re-evens along that axis.
  func testEveningAGroupAppliesTheCurrentWeights() {
    let groups = built([("b", "a", .right)])
    var weightOfA = 1
    let weighted = policy(leafSlots: { leaf, _ in leaf == "a" ? weightOfA : 1 })
    weightOfA = 2
    let evened = groups.evening(groupOf: "b", along: .horizontal, policy: weighted)
    XCTAssertEqual(rootRatio(evened) ?? -1, 2.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(
      groups.evening(groupOf: "z", along: nil, policy: weighted), groups, "a solo leaf: no change")
    XCTAssertEqual(
      groups.evening(groupOf: "b", along: .horizontal, policy: policy(autoEven: false)), groups,
      "the setting off: no change")
  }

  // MARK: Storing a group back

  /// A restarted run tab takes its old slot: the tree goes back over the group a survivor is still
  /// in, or comes back as a new group when the close dissolved it.
  func testStoringReplacesTheSurvivorsGroupOrAppends() {
    let three = threeColumns()
    let before = three.groups[0]
    let collapsed = three.removing("c", policy: policy(autoEven: false))
    let restored = collapsed.storing(before.replacingLeaf("c", with: "c2"), overGroupOf: "a")
    XCTAssertEqual(restored.groups.map(\.tabIDs), [["a", "b", "c2"]])

    let pair = built([("b", "a", .right)])
    let dissolved = pair.removing("b", policy: policy())
    XCTAssertTrue(dissolved.isEmpty)
    let reseeded = dissolved.storing(
      pair.groups[0].replacingLeaf("b", with: "b2"), overGroupOf: "a")
    XCTAssertEqual(reseeded.groups.map(\.tabIDs), [["a", "b2"]])
  }

  func testStoringALoneLeafDeletesTheGroup() {
    let groups = built([("b", "a", .right)]).storing(.leaf("a"), overGroupOf: "a")
    XCTAssertTrue(groups.isEmpty)
  }
}
