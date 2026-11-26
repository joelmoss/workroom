import XCTest

@testable import Workroom

/// Popping a detail panel out into its own window (issue #172).
///
/// The design is "the tab never leaves its owning store": a detached pane's `TerminalTab` stays in
/// `TerminalPanes` and only its host view moves. Its slot stays too: its strip place, its pane in a
/// split and the focus, and the slot shows a placeholder until the pane comes back into it.
@MainActor
final class DetachedPaneTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)
  private let other = TerminalTarget(
    id: .workroom(project: "/p", name: "bar"), title: "bar", path: "/tmp", isMissing: false)

  private func rootSplitID(_ s: TerminalPanes) -> UUID? {
    guard case .split(let id, _, _, _, _) = s.split(for: target) else { return nil }
    return id
  }

  private func makeSessions() -> TerminalPanes {
    let sessions = TerminalPanes()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    return sessions
  }

  // MARK: The slot stays

  /// A popped-out pane keeps its strip slot, and the session file keeps it there too.
  ///
  /// The capture half is not tidiness — the app writes its session on `willResignActive`, so a
  /// filtered capture would drop a popped-out pane from merely ⌘-tabbing away.
  func testDetachedTabKeepsItsStripSlotAndStaysInCapture() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    let third = s.addTab(for: target)

    // The MIDDLE tab, deliberately: an implementation that moved detached tabs to the tail would
    // satisfy a claim about the last one without keeping anything in place.
    s.detachPane(second.id, for: target, at: .zero)

    XCTAssertEqual(
      s.displayedTabIDs(for: target), [first.id, second.id, third.id],
      "a popped-out pane keeps its place in the strip, where its placeholder is")
    XCTAssertEqual(
      s.sessionCapture(forTargetID: target.id)?.tabs.map(\.id), [first.id, second.id, third.id],
      "so a relaunch brings it back where it was")
  }

  /// Popping out the tab you are looking at leaves the focus on it: its slot shows the
  /// placeholder. Its surface is not this window's to act on, so `focusedSurface` says none.
  func testDetachingTheFocusedTabKeepsTheFocusOnItsSlot() {
    let s = makeSessions()
    s.addTab(for: target)
    let shown = s.addTab(for: target)
    XCTAssertEqual(s.focusedTab(for: target)?.id, shown.id)
    var focusChanges = 0
    s.onEvent = { if case .focusChanged = $0 { focusChanges += 1 } }

    s.detachPane(shown.id, for: target, at: .zero)

    XCTAssertEqual(s.focusedTab(for: target)?.id, shown.id, "the focus stays on the slot")
    XCTAssertEqual(focusChanges, 0, "nothing moved")
    XCTAssertNil(s.focusedSurface(for: target), "its surface is in its own window")
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
    XCTAssertEqual(
      s.visibleTabIDs(for: target).filter { $0 == second.id }.count, 1,
      "named once, though it is also the focused slot")
    XCTAssertFalse(
      s.visibleTabIDs(for: target).contains(first.id),
      "the focus stayed on the popped-out slot, so the other tab is off screen")
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

  // MARK: Focus

  /// Selecting a popped-out tab (its chip, its Open row) shows its placeholder: the focus lands on
  /// it, and its window is not raised.
  func testSelectingAPoppedOutTabShowsItsPlaceholderWithoutRaisingItsWindow() {
    let s = makeSessions()
    let detached = s.addTab(for: target)
    let other = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)
    XCTAssertEqual(s.focusedTab(for: target)?.id, other.id)

    var raised: [TerminalTab.ID] = []
    s.onEvent = { if case .paneRaiseRequested(let a) = $0 { raised.append(a) } }
    s.select(detached.id, for: target)

    XCTAssertEqual(s.focusedTab(for: target)?.id, detached.id, "its slot shows")
    XCTAssertTrue(raised.isEmpty, "its window stays where it is")
  }

  /// A click into the popped-out pane in its own window makes its surface first responder there.
  /// That must not move this window's selection onto the pane's placeholder.
  ///
  /// The other tab is a diff, which has no surface: with a terminal there, the window-less test
  /// surface would read as a focus still being shown, and the handler would bail for that reason
  /// instead.
  func testThePoppedOutSurfaceTakingFocusInItsWindowMovesNothingHere() throws {
    let s = makeSessions()
    let detached = s.addTab(for: target)
    let other = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    s.detachPane(detached.id, for: target, at: .zero)
    s.focus(other, for: target)
    var surfaceFocused = 0
    s.onEvent = { if case .surfaceFocused = $0 { surfaceFocused += 1 } }

    try XCTUnwrap(s.surface(of: detached.id)).onEvent?(.focused)

    XCTAssertEqual(s.focusedTab(for: target)?.id, other, "this window's selection stays")
    XCTAssertEqual(surfaceFocused, 0)
    // The negative control: a docked pane's surface taking focus still selects it.
    s.dockPane(detached.id, for: target)
    s.focus(other, for: target)
    try XCTUnwrap(s.surface(of: detached.id)).onEvent?(.focused)
    XCTAssertEqual(s.focusedTab(for: target)?.id, detached.id)
    XCTAssertEqual(surfaceFocused, 1)
  }

  /// Go to Window asks the host to raise the pane's window, and only for a popped-out pane.
  func testGoToWindowRaisesOnlyAPoppedOutPanesWindow() {
    let s = makeSessions()
    let detached = s.addTab(for: target)
    let docked = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)
    var raised: [TerminalTab.ID] = []
    s.onEvent = { if case .paneRaiseRequested(let a) = $0 { raised.append(a) } }

    s.raiseDetachedPane(detached.id, for: target)
    s.raiseDetachedPane(docked.id, for: target)

    XCTAssertEqual(raised, [detached.id])
    XCTAssertEqual(s.focusedTab(for: target)?.id, docked.id, "raising moves nothing here")
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

  /// Popping out a split member keeps its pane in the split, where its placeholder shows, and
  /// leaves every divider where the user put it.
  ///
  /// The divider is SKEWED first on purpose: an implementation that removed and re-evened the
  /// split would read 0.5, so 0.8 surviving means nothing moved.
  func testDetachingASplitMemberKeepsItsPaneAndTheDividers() {
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

    let before = s.split(for: target)
    s.detachPane(c.id, for: target, at: .zero)

    let after = s.split(for: target)
    XCTAssertEqual(after, before, "the split is exactly as it was, the popped-out pane in it")
    XCTAssertEqual(after?.ratio(forSplit: rootID), 0.8, "no divider moved")
    XCTAssertEqual(s.focusedTab(for: target)?.id, c.id, "and the focus stayed on its slot")
  }

  // MARK: Docking

  /// Docking puts the pane back, focused, in the strip slot it kept.
  func testDockingRestoresTheTabToItsStripSlot() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    let third = s.addTab(for: target)
    s.detachPane(second.id, for: target, at: .zero)
    s.focus(third.id, for: target)

    var closed: [TerminalTab.ID] = []
    s.onEvent = { if case .paneDocked(let a) = $0 { closed.append(a) } }
    s.dockPane(second.id, for: target)

    XCTAssertEqual(
      s.displayedTabIDs(for: target), [first.id, second.id, third.id], "back in its slot")
    XCTAssertFalse(s.detachedTabIDs.contains(second.id))
    XCTAssertEqual(closed, [second.id], "and its window is closed")
    XCTAssertEqual(
      s.focusedTab(for: target)?.id, second.id, "docking focuses what you just put back")
    XCTAssertNotNil(s.focusedSurface(for: target), "its surface is this window's again")
  }

  /// Pull Back Here, and the popped-out window's own Move Back, both dock: into the same pane of
  /// the same split, with the dividers where they were, focused — from wherever the focus was.
  func testDockingAPoppedOutSplitMemberPutsItBackInItsPane() {
    let s = makeSessions()
    let a = s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    let rootID = rootSplitID(s)!
    s.setRatio(0.7, forSplit: rootID, for: target)
    let solo = s.addTab(for: target)  // a tab outside the split
    s.focus(b.id, for: target)
    let before = s.split(for: target)

    s.detachPane(b.id, for: target, at: .zero)
    s.focus(solo.id, for: target)  // the user moves on to another tab
    XCTAssertNil(s.split(for: target), "the split is off screen with its placeholder")

    s.dockPane(b.id, for: target)

    XCTAssertEqual(s.split(for: target), before, "the same split, b in its own pane")
    XCTAssertEqual(s.split(for: target)?.ratio(forSplit: rootID), 0.7)
    XCTAssertEqual(s.focusedTab(for: target)?.id, b.id)
    XCTAssertEqual(s.displayedTabIDs(for: target), [a.id, b.id, solo.id])
  }

  // MARK: Closing from the placeholder

  /// ⌘W, or the ✕ on a placeholder's tab, closes the terminal itself, and its window with it.
  func testClosingAPoppedOutTabFromItsSlotClosesItAndItsWindow() {
    let s = makeSessions()
    let a = s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    s.detachPane(b.id, for: target, at: .zero)
    XCTAssertEqual(s.activeTab(for: target)?.id, b.id, "⌘W acts on the placeholder's tab")

    var closed: [TerminalTab.ID] = []
    s.onEvent = { if case .paneDocked(let id) = $0 { closed.append(id) } }
    s.closeTab(b.id, for: target)

    XCTAssertEqual(closed, [b.id], "its window goes with it")
    XCTAssertNil(s.tab(b.id, for: target), "the terminal is gone")
    XCTAssertTrue(s.detachedTabIDs.isEmpty)
    XCTAssertNil(s.split(for: target), "its pane went, so the split dissolved")
    XCTAssertEqual(s.focusedTab(for: target)?.id, a.id)
  }

  // MARK: Teardown — a window may never outlive its tab

  func testClosingADetachedTabClosesItsWindow() {
    let s = makeSessions()
    s.addTab(for: target)
    let detached = s.addTab(for: target)
    s.detachPane(detached.id, for: target, at: .zero)

    var closed: [TerminalTab.ID] = []
    s.onEvent = { if case .paneDocked(let a) = $0 { closed.append(a) } }
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
    s.onEvent = { if case .paneDocked(let a) = $0 { closed.append(a) } }
    await s.reap(target.id)

    XCTAssertEqual(closed, [detached.id])
    XCTAssertTrue(s.detachedTabIDs.isEmpty)
  }

  /// Detaching reports the screen point it was dropped at, which is where the window opens.
  func testDetachReportsItsDropPoint() {
    let s = makeSessions()
    let tab = s.addTab(for: target)
    var reported: [(TerminalTarget.ID, TerminalTab.ID, CGPoint, Bool)] = []
    s.onEvent = {
      if case .paneDetached(let a, let b, at: let c, let d) = $0 { reported.append((a, b, c, d)) }
    }

    s.detachPane(tab.id, for: target, at: CGPoint(x: 120, y: 340))

    XCTAssertEqual(reported.count, 1)
    XCTAssertEqual(reported.first?.1, tab.id)
    XCTAssertEqual(reported.first?.2, CGPoint(x: 120, y: 340))
    XCTAssertEqual(reported.first?.3, false, "a button, menu or shortcut is not a drag")
  }

  /// Only a popped-out pane can be in flight over its slot, and docking lands it.
  func testOnlyAPoppedOutPaneIsInFlightAndDockingLandsIt() {
    let s = makeSessions()
    let tab = s.addTab(for: target)
    s.setInFlight(tab.id, true)
    XCTAssertFalse(s.inFlightTabIDs.contains(tab.id), "a docked pane has no flight")

    s.detachPane(tab.id, for: target, at: .zero)
    XCTAssertTrue(s.showsPlaceholder(tab.id))
    s.setInFlight(tab.id, true)
    XCTAssertTrue(s.inFlightTabIDs.contains(tab.id))
    XCTAssertFalse(s.showsPlaceholder(tab.id), "a flight over the slot hides its placeholder")

    s.dockPane(tab.id, for: target)
    XCTAssertFalse(s.inFlightTabIDs.contains(tab.id), "docking lands it")
    XCTAssertFalse(s.showsPlaceholder(tab.id))
  }

  /// A pane let go outside its window says it was dragged, so its window scales up from the
  /// pointer rather than growing out of its slot.
  func testADropOutsideTheWindowDetachesByDrag() {
    let s = makeSessions()
    let tab = s.addTab(for: target)
    var byDrag: [Bool] = []
    s.onEvent = { if case .paneDetached(_, _, at: _, let d) = $0 { byDrag.append(d) } }

    s.dropOutside(tab.id, for: target)

    XCTAssertEqual(byDrag, [true])
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
    s.onEvent = {
      if case .paneRestoredDetached(_, let tabID, frame: let frame) = $0 {
        restored.append((tabID, frame))
      }
    }

    let frame = NSRect(x: 120, y: 340, width: 800, height: 560)
    var detached = terminalTab("b", title: "Terminal 2")
    detached.detachedFrame = NSStringFromRect(frame)
    _ = s.restore(
      TargetSession(
        targetID: target.id.encoded, tabs: [terminalTab("a", title: "Terminal 1"), detached]),
      for: target)

    XCTAssertEqual(restored.count, 1, "the saved window must be rebuilt")
    XCTAssertEqual(restored.first?.1, frame, "at the frame it was left at")
    let id = restored.first!.0
    XCTAssertTrue(s.detachedTabIDs.contains(id))
    XCTAssertEqual(
      s.displayedTabIDs(for: target).last, id, "its slot in the strip comes back with it")
    XCTAssertTrue(s.visibleTabIDs(for: target).contains(id), "it renders in its own window")
  }

  /// `NSRectFromString` returns a zero rect for anything it cannot parse, so a corrupted session file
  /// must fall back to docked rather than opening a zero-size window.
  func testAnUnparseableDetachedFrameRestoresDocked() {
    let s = makeSessions()
    var restored = 0
    s.onEvent = { if case .paneRestoredDetached = $0 { restored += 1 } }

    var detached = terminalTab("a", title: "Terminal 1")
    detached.detachedFrame = "not a rect"
    _ = s.restore(TargetSession(targetID: target.id.encoded, tabs: [detached]), for: target)

    XCTAssertEqual(restored, 0, "a zero frame must not open a zero-size window")
    XCTAssertTrue(s.detachedTabIDs.isEmpty)
    XCTAssertEqual(s.displayedTabIDs(for: target).count, 1, "it comes back docked instead")
  }

  // MARK: Splits — the two-pane case

  /// Popping out one half of a TWO-pane split keeps the split: the case that used to dissolve it.
  /// Its slot is named once among the panes that must keep rendering.
  func testDetachingOneHalfOfATwoPaneSplitKeepsTheSplit() {
    let s = makeSessions()
    let a = s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    XCTAssertEqual(Set(s.split(for: target)?.tabIDs ?? []), [a.id, b.id])

    s.detachPane(b.id, for: target, at: .zero)

    XCTAssertEqual(Set(s.split(for: target)?.tabIDs ?? []), [a.id, b.id], "still a split")
    XCTAssertEqual(s.displayedTabIDs(for: target), [a.id, b.id])
    XCTAssertEqual(s.focusedTab(for: target)?.id, b.id, "the focus stays on its slot")
    XCTAssertEqual(
      s.visibleTabIDs(for: target).sorted(by: { $0.uuidString < $1.uuidString }),
      [a.id, b.id].sorted(by: { $0.uuidString < $1.uuidString }),
      "both keep rendering, the popped-out one named once")
  }

  // MARK: Bulk close — a detached pane is still a tab

  /// Every path that means "all of this target's tabs" reads `allTabs`, which a popped-out pane is
  /// in, so "Close All Tabs" can't leave one alive with its process.
  func testAllTabsIncludesADetachedPaneSoBulkClosesReachIt() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    s.detachPane(second.id, for: target, at: .zero)

    XCTAssertEqual(s.tabs(for: target).map(\.id), [first.id, second.id], "the strip shows it")
    XCTAssertEqual(
      s.allTabs(for: target).map(\.id), [first.id, second.id],
      "and it is still a tab, so a bulk close must be able to see it")
  }

  /// The typing marker names a popped-out sender by its own window, where it is seen and typed
  /// into, though it keeps its strip slot; the tab after it keeps its strip number.
  func testATypingMarkerNamesAPoppedOutSenderByItsOwnWindow() {
    let s = makeSessions()
    let popped = s.addTab(for: target)
    let docked = s.addTab(for: target)
    let poppedSession = s.assignFixtureSession(tab: popped.id, target: target.id)
    let dockedSession = s.assignFixtureSession(tab: docked.id, target: target.id)
    s.detachPane(popped.id, for: target, at: .zero)

    XCTAssertNotNil(s.typingPlace(ofSession: poppedSession))
    XCTAssertNil(s.typingPlace(ofSession: poppedSession)?.tab, "\"own window\"")
    XCTAssertEqual(s.typingPlace(ofSession: dockedSession)?.tab, 2, "⌘2 still selects it")
  }

  // MARK: Hand-off to another window (#444)

  /// A workroom moving to another window takes its popped-out pane's slot with it: the same split,
  /// the same focus, and the pane still popped out there.
  func testAHandOffCarriesAPoppedOutSlot() throws {
    let s = makeSessions()
    let a = s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    s.detachPane(b.id, for: target, at: .zero)
    let split = s.split(for: target)

    var handOff = try XCTUnwrap(s.handOff(target))
    handOff.detached[b.id] = NSRect(x: 0, y: 0, width: 400, height: 300)
    let destination = makeSessions()
    var reopened: [TerminalTab.ID] = []
    destination.onEvent = {
      if case .paneRestoredDetached(_, let id, frame: _) = $0 { reopened.append(id) }
    }
    destination.adopt(handOff)

    XCTAssertEqual(destination.split(for: target), split, "the split arrives whole")
    XCTAssertEqual(destination.detachedTabIDs, [b.id])
    XCTAssertEqual(reopened, [b.id], "its window reopens there")
    XCTAssertEqual(destination.focusedTab(for: target)?.id, b.id, "and its slot is still focused")
    XCTAssertEqual(destination.displayedTabIDs(for: target), [a.id, b.id])
  }

  /// A hand-off whose popped-out window can't reopen in the window it joins docks the pane into
  /// its slot there, rather than strand a placeholder.
  func testAHandOffWhoseWindowDidNotReopenDocksTheSlot() throws {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.focusedTab(for: target)!
    s.detachPane(b.id, for: target, at: .zero)
    let split = s.split(for: target)

    let handOff = try XCTUnwrap(s.handOff(target))
    let destination = makeSessions()
    destination.detachedWindowExists = { _ in false }
    destination.adopt(handOff)

    XCTAssertTrue(destination.detachedTabIDs.isEmpty)
    XCTAssertEqual(destination.split(for: target), split, "docked in its pane of the split")
    XCTAssertNotNil(destination.focusedSurface(for: target), "and showing its terminal")
  }

  /// Docking a tab that was never detached must change nothing — the mirror of the repeated-detach
  /// no-op, and reachable in practice via the Window menu against a stale tab id.
  func testDockingATabThatIsNotDetachedIsANoOp() {
    let s = makeSessions()
    let first = s.addTab(for: target)
    let second = s.addTab(for: target)
    XCTAssertEqual(s.focusedTab(for: target)?.id, second.id)

    var closed = 0
    s.onEvent = { if case .paneDocked = $0 { closed += 1 } }
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
    s.onEvent = { if case .paneDetached = $0 { reported += 1 } }

    s.detachPane(tab.id, for: target, at: .zero)
    s.detachPane(tab.id, for: target, at: .zero)

    XCTAssertEqual(reported, 1)
  }
}
