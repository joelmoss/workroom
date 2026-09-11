import XCTest

@testable import Workroom

/// Popping a detail panel out into its own window (issue #172).
///
/// The design is "the tab never leaves its owning store": a detached pane's `TerminalTab` stays in
/// `TerminalSessions` and only its host view moves, so what these tests pin is that the *model* now
/// answers three different questions three different ways about the same tab.
@MainActor
final class DetachedPaneTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)
  private let other = TerminalTarget(id: "wr|/p|bar", title: "bar", path: "/tmp", isMissing: false)

  private func rootSplitID(_ s: TerminalSessions) -> UUID? {
    guard case .split(let id, _, _, _, _) = s.split(for: target) else { return nil }
    return id
  }

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    return sessions
  }

  // MARK: The three accessors, which deliberately disagree

  /// The strip and the layout lose a detached pane; the session file must not.
  ///
  /// The capture half is not tidiness — the app writes its session on `willResignActive`, so a
  /// filtered capture would drop a popped-out pane from merely ⌘-tabbing away.
  func testDetachedTabLeavesTheStripButStaysInCapture() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    let third = s.addTab(for: target)

    // The MIDDLE tab, deliberately: detaching the LAST one leaves `[first, second]` either way, so an
    // implementation that appended detached tabs to the tail would satisfy the position claim below
    // without restoring anything.
    s.detachPane(second.id, for: target, at: .zero)

    XCTAssertEqual(
      s.displayedTabIDs(for: target), [first.id, third.id],
      "a detached pane is not in the strip or the layout")
    XCTAssertEqual(
      s.normalizedTabIDs(forTargetID: target.id), [first.id, second.id, third.id],
      "the raw order keeps it in its ORIGINAL slot, not at the end")
    XCTAssertEqual(
      s.sessionCapture(forTargetID: target.id)?.tabs.map(\.id), [first.id, second.id, third.id],
      "capture reads the raw order, so a relaunch brings it back where it was")
  }

  /// The black-pane regression: `reconcileOcclusion` pauses every surface not in `visibleTabIDs`, so
  /// omitting detached panes there stops a popped-out terminal rendering the moment anything touches
  /// the store.
  func testDetachedTabStaysVisibleForOcclusion() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    s.detachPane(second.id, for: target, at: .zero)

    XCTAssertTrue(
      s.visibleTabIDs(for: target).contains(second.id),
      "a detached pane is on screen in its own window, so it must keep rendering")
    XCTAssertTrue(s.visibleTabIDs(for: target).contains(first.id))
  }

  /// A detached pane must stay visible even once the origin has moved on to another workroom — the
  /// case the outside voice raised. It holds because a detached surface never leaves its own window,
  /// but "true by construction" is exactly the kind of claim that stops being true silently.
  func testDetachedTabStaysVisibleAfterTheOriginSwitchesTarget() {
    let s = makeSessions()
    let detached = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)
    s.addTab(for: other)  // the origin window moves on

    XCTAssertTrue(
      s.visibleTabIDs(for: target).contains(detached.id),
      "switching workrooms must not pause a pane in another window")
    XCTAssertTrue(s.detachedTabIDs.contains(detached.id))
  }

  // MARK: The two guards

  /// Focusing a detached tab would make the origin render `.leaf(detached)` and `mount` would re-home
  /// the libghostty view back out of the detached window, blanking it. `setFocused` is the single
  /// write-point, so guarding it covers every route in — a surface click, `ActivateOnPress`,
  /// back/forward, notification routing, ⌃Tab, and a preview retarget.
  func testFocusingADetachedTabIsRefusedAndRaisesItsWindowInstead() {
    let s = makeSessions()
    let stay = s.addTab(for: target)
    let detached = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)
    XCTAssertEqual(s.focusedTab(for: target)?.id, stay.id, "detaching hands focus to the successor")

    var raised: [TerminalTab.ID] = []
    s.onPaneRaiseRequested = { raised.append($0) }
    s.focus(detached.id, for: target)

    XCTAssertEqual(
      s.focusedTab(for: target)?.id, stay.id, "the focus write must not land on a detached tab")
    XCTAssertEqual(raised, [detached.id], "raising its own window is the useful answer instead")
  }

  /// `previewTabID` scans the unfiltered tab dictionary, so without pinning on the way out the next
  /// Changes/Files click would rewrite the detached pane's content in place and the popped-out window
  /// would silently become a different file.
  func testDetachingPinsAPreviewTabSoItCannotBeRetargeted() {
    let s = makeSessions()
    let preview = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    s.detachPane(preview, for: target, at: .zero)

    let next = s.openDiffPreview(
      DiffDescriptor(path: "B.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)

    XCTAssertNotEqual(next, preview, "the detached pane must not be reused as the preview slot")
    XCTAssertEqual(
      s.tab(preview, for: target)?.filePath, "A.swift", "its content is unchanged")
  }

  // MARK: Split behaviour

  /// Detaching a split member runs the same removal `extractFromSplit` does, so the survivors are
  /// evened — a divider the user had dragged elsewhere is budgeting space for a pane that has left.
  ///
  /// The divider is SKEWED first on purpose: under slot-weighted `equalized()` a two-leaf split
  /// already sits at 0.5, so asserting 0.5 against an unskewed tree passes even with evening
  /// disabled. (Six such vacuous tests shipped in issue #126.)
  func testDetachingASplitMemberCollapsesAndEvensTheSurvivors() {
    let s = makeSessions()
    let a = s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    s.focus(a.id, for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let c = s.focusedTab(for: target)!

    let split = s.split(for: target)!
    XCTAssertEqual(Set(split.tabIDs), [a.id, b.id, c.id])
    let rootID = rootSplitID(s)!
    s.setRatio(0.8, forSplit: rootID, for: target)
    XCTAssertEqual(
      s.split(for: target)?.ratio(forSplit: rootID), 0.8, "skewed, so 0.5 means something")

    s.detachPane(c.id, for: target, at: .zero)

    let after = s.split(for: target)
    XCTAssertEqual(Set(after?.tabIDs ?? []), [a.id, b.id], "the detached member leaves the split")
    XCTAssertEqual(after?.ratio(forSplit: rootID), 0.5, "and the survivors are evened")
  }

  // MARK: Docking

  /// Docking with no drop target puts the pane back as the focused solo tab, in its old strip slot.
  func testDockingRestoresTheTabToTheStrip() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    let third = s.addTab(for: target)
    s.detachPane(second.id, for: target, at: .zero)
    XCTAssertEqual(s.displayedTabIDs(for: target), [first.id, third.id])

    var closed: [TerminalTab.ID] = []
    s.onPaneDocked = { closed.append($0) }
    s.dockPane(second.id, for: target)

    // The MIDDLE tab again: a dock that re-appended would read `[first, third, second]`, which is
    // exactly what "its old slot" has to rule out.
    XCTAssertEqual(
      s.displayedTabIDs(for: target), [first.id, second.id, third.id], "back in its old slot")
    XCTAssertFalse(s.detachedTabIDs.contains(second.id))
    XCTAssertEqual(closed, [second.id], "and its window is closed")
    XCTAssertEqual(
      s.focusedTab(for: target)?.id, second.id, "docking focuses what you just put back")
  }

  // MARK: Teardown — a window may never outlive its tab

  func testClosingADetachedTabClosesItsWindow() {
    let s = makeSessions()
    s.addTab(for: target)
    let detached = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)

    var closed: [TerminalTab.ID] = []
    s.onPaneDocked = { closed.append($0) }
    s.closeTab(detached.id, for: target)

    XCTAssertEqual(closed, [detached.id])
    XCTAssertFalse(s.detachedTabIDs.contains(detached.id))
    XCTAssertNil(s.tab(detached.id, for: target))
  }

  func testReapingATargetClosesItsDetachedWindows() async {
    let s = makeSessions()
    let detached = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)

    var closed: [TerminalTab.ID] = []
    s.onPaneDocked = { closed.append($0) }
    await s.reap(target.id)

    XCTAssertEqual(closed, [detached.id])
    XCTAssertTrue(s.detachedTabIDs.isEmpty)
  }

  /// Detaching reports the screen point it was dropped at, which is where the window opens.
  func testDetachReportsItsDropPoint() {
    let s = makeSessions()
    let tab = s.addTab(for: target)
    var reported: [(TerminalTarget.ID, TerminalTab.ID, CGPoint)] = []
    s.onPaneDetached = { reported.append(($0, $1, $2)) }

    s.detachPane(tab.id, for: target, at: CGPoint(x: 120, y: 340))

    XCTAssertEqual(reported.count, 1)
    XCTAssertEqual(reported.first?.1, tab.id)
    XCTAssertEqual(reported.first?.2, CGPoint(x: 120, y: 340))
  }

  // MARK: Session persistence — the durability promise

  private func terminalTab(_ key: String, title: String) -> TabSession {
    TabSession(
      key: key, kind: TabSession.terminalKind,
      terminal: TerminalPayload(defaultTitle: title, cwd: nil))
  }

  /// Quit with a pane detached, relaunch, it comes back detached at its frame. That is the feature's
  /// headline durability claim and it had no coverage at all.
  func testARestoredPaneComesBackDetachedAtItsSavedFrame() {
    let s = makeSessions()
    var restored: [(TerminalTab.ID, NSRect)] = []
    s.onPaneRestoredDetached = { _, tabID, frame in restored.append((tabID, frame)) }

    let frame = NSRect(x: 120, y: 340, width: 800, height: 560)
    var detached = terminalTab("b", title: "Terminal 2")
    detached.detachedFrame = NSStringFromRect(frame)
    _ = s.restore(
      TargetSession(
        targetID: target.id, tabs: [terminalTab("a", title: "Terminal 1"), detached]),
      for: target)

    XCTAssertEqual(restored.count, 1, "the saved window must be rebuilt")
    XCTAssertEqual(restored.first?.1, frame, "at the frame it was left at")
    let id = restored.first!.0
    XCTAssertTrue(s.detachedTabIDs.contains(id))
    XCTAssertFalse(
      s.displayedTabIDs(for: target).contains(id), "and it must not ALSO be in the strip")
    XCTAssertTrue(s.visibleTabIDs(for: target).contains(id), "it renders in its own window")
  }

  /// `NSRectFromString` returns a zero rect for anything it cannot parse, so a corrupted session file
  /// must fall back to docked rather than opening a zero-size window.
  func testAnUnparseableDetachedFrameRestoresDocked() {
    let s = makeSessions()
    var restored = 0
    s.onPaneRestoredDetached = { _, _, _ in restored += 1 }

    var detached = terminalTab("a", title: "Terminal 1")
    detached.detachedFrame = "not a rect"
    _ = s.restore(TargetSession(targetID: target.id, tabs: [detached]), for: target)

    XCTAssertEqual(restored, 0, "a zero frame must not open a zero-size window")
    XCTAssertTrue(s.detachedTabIDs.isEmpty)
    XCTAssertEqual(s.displayedTabIDs(for: target).count, 1, "it comes back docked instead")
  }

  // MARK: Splits — the two-pane case, which takes the other branch

  /// Detaching one half of a TWO-pane split dissolves the split entirely. The three-member test above
  /// only exercises the `>= 2 survivors` arm; this is the common gesture and it takes the other one.
  func testDetachingOneHalfOfATwoPaneSplitDissolvesTheSplit() {
    let s = makeSessions()
    let a = s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    XCTAssertEqual(Set(s.split(for: target)?.tabIDs ?? []), [a.id, b.id])

    s.detachPane(b.id, for: target, at: .zero)

    XCTAssertNil(s.split(for: target), "one survivor is not a split")
    XCTAssertEqual(s.displayedTabIDs(for: target), [a.id])
    XCTAssertEqual(s.focusedTab(for: target)?.id, a.id, "the survivor takes focus")
    XCTAssertTrue(s.visibleTabIDs(for: target).contains(b.id), "the detached one keeps rendering")
  }

  // MARK: Bulk close — a detached pane is still a tab

  /// `tabs(for:)` hides detached panes, so every path that means "all of this target's tabs" has to
  /// read `allTabs`. It did not, and "Close All Tabs" left a popped-out pane alive with its process.
  func testAllTabsIncludesADetachedPaneSoBulkClosesReachIt() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    s.detachPane(second.id, for: target, at: .zero)

    XCTAssertEqual(
      s.tabs(for: target).map(\.id), [first.id], "the strip hides it")
    XCTAssertEqual(
      s.allTabs(for: target).map(\.id), [first.id, second.id],
      "but it is still a tab, so a bulk close must be able to see it")
  }

  /// Docking a tab that was never detached must change nothing — the mirror of the repeated-detach
  /// no-op, and reachable in practice via the Window menu against a stale tab id.
  func testDockingATabThatIsNotDetachedIsANoOp() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    XCTAssertEqual(s.focusedTab(for: target)?.id, second.id)

    var closed = 0
    s.onPaneDocked = { _ in closed += 1 }
    s.dockPane(first.id, for: target)

    XCTAssertEqual(closed, 0, "no window exists, so nothing may be told to close one")
    XCTAssertEqual(
      s.focusedTab(for: target)?.id, second.id, "and a stale dock must not steal focus")
  }

  /// Detaching twice is a no-op, so the "one tab, one window" invariant cannot be broken by a
  /// repeated gesture.
  func testDetachingAnAlreadyDetachedTabIsANoOp() {
    let s = makeSessions()
    let tab = s.addTab(for: target)
    var reported = 0
    s.onPaneDetached = { _, _, _ in reported += 1 }

    s.detachPane(tab.id, for: target, at: .zero)
    s.detachPane(tab.id, for: target, at: .zero)

    XCTAssertEqual(reported, 1)
  }
}
