import XCTest

@testable import Workroom

/// Lifecycle tests for the rewritten `TerminalSessions` (plan T1). The factory seam lets us exercise
/// add/close/select/move/reap without spawning real shells: a `GhosttySurfaceView` only creates its
/// PTY when it enters a window, so constructing one here is inert.
@MainActor
final class TerminalSessionsTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return sessions
  }

  // MARK: onTabContentChange — the navigation-history seam

  /// Retargeting the shared preview tab mutates content without moving focus, so `onFocusChange` never
  /// fires. This seam is the only way history can see it — the whole cause of "Back skips the files you
  /// browsed".
  func testContentSeamFiresOnPreviewRetarget() {
    let s = makeSessions()
    var fired: [TerminalTab.ID] = []
    s.onTabContentChange = { _, tabID in fired.append(tabID) }
    let first = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    XCTAssertTrue(fired.isEmpty, "a NEW preview tab changes focus, so onFocusChange covers it")

    let second = s.openDiffPreview(
      DiffDescriptor(path: "B.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)

    XCTAssertEqual(second, first, "the preview slot is retargeted in place")
    XCTAssertEqual(fired, [first], "the retarget must report itself")
  }

  /// Selecting a file inside a commit is its own location and moves no focus.
  func testContentSeamFiresOnChangesetFileSelection() {
    let s = makeSessions()
    let tab = s.openContentPreview(
      ChangesetDescriptor(commitID: "abc", title: "t", isPreview: true), for: target)
    var fired: [TerminalTab.ID] = []
    s.onTabContentChange = { _, tabID in fired.append(tabID) }

    s.setChangesetSelectedPath("one.swift", forTab: tab, in: target)
    s.setChangesetSelectedPath("one.swift", forTab: tab, in: target)  // unchanged → no event

    XCTAssertEqual(fired, [tab])
  }

  /// Pinning a tab and changing how a pane is rendered are not locations, so they must stay silent —
  /// otherwise Keep Open and the view-mode toggle would litter back/forward with phantom steps.
  ///
  /// The file preview is opened BEFORE the pin so it is a genuine retarget of the one preview slot: that
  /// is the only fire this body is allowed, and asserting the count around it proves the overrides are
  /// silent rather than proving a counter that was already zero.
  func testContentSeamStaysSilentForPinAndViewMode() {
    let s = makeSessions()
    let tab = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    var fired = 0
    s.onTabContentChange = { _, _ in fired += 1 }

    let file = s.openFilePreview(FileDescriptor(path: "R.md", isPreview: true), for: target)
    XCTAssertEqual(tab, file, "the file preview retargets the one preview slot")
    XCTAssertEqual(fired, 1, "a retarget is a location change")

    s.persist(file, for: target)
    s.setMarkdownPreview(true, forTab: file, in: target)
    s.setDiffViewMode(.sideBySide, forTab: file, in: target)

    XCTAssertEqual(fired, 1, "pin and view-mode overrides add no locations")
  }

  func testAddTabAppendsAndActivates() {
    let s = makeSessions()
    s.addTab(for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertEqual(s.activeTab(for: target)?.id, s.tabs(for: target).first?.id)
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")
  }

  func testEnsureTabIsIdempotent() {
    let s = makeSessions()
    s.ensureTab(for: target)
    s.ensureTab(for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
  }

  func testTitlesIncrementAndDoNotRenumber() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 2", "Terminal 3"])
    let second = s.tabs(for: target)[1].id
    s.closeTab(second, for: target)
    s.addTab(for: target)
    // Counter keeps climbing; titles stay stable rather than renumbering.
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 3", "Terminal 4"])
  }

  func testCloseActiveSelectsNeighborThatSlidIn() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    let first = s.tabs(for: target)[0].id
    s.select(first, for: target)
    s.closeTab(first, for: target)
    // The neighbour that slid into slot 0 (originally "Terminal 2") becomes active.
    XCTAssertEqual(s.activeTab(for: target)?.title, "Terminal 2")
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  func testCloseLastLeavesNoActive() {
    let s = makeSessions()
    s.addTab(for: target)
    let only = s.tabs(for: target)[0].id
    s.closeTab(only, for: target)
    XCTAssertTrue(s.tabs(for: target).isEmpty)
    XCTAssertNil(s.activeTab(for: target))
  }

  func testMoveTabClampsToBounds() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    let first = s.tabs(for: target)[0].id  // "Terminal 1"
    s.moveTab(first, toIndex: 99, for: target)
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 2", "Terminal 3", "Terminal 1"])
  }

  func testReapClearsTabsActiveAndCounter() async {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    await s.reap(target.id)
    XCTAssertTrue(s.tabs(for: target).isEmpty)
    XCTAssertNil(s.activeTab(for: target))
    // Counter reset: the next tab is "Terminal 1" again.
    s.addTab(for: target)
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")
  }

  // MARK: Running state (issue #28)

  /// The spinner is driven solely by OSC 9;4 progress, never the command title (matching Ghostty/Muxy).
  /// A long-lived foreground program (claude, codex) keeps a command title set the whole session, so
  /// tying "busy" to the title would spin forever — the regression this fixes.
  func testIsRunningDrivenByProgressNotTitle() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!

    // A fresh tab sits at the prompt — nothing running.
    XCTAssertFalse(s.isRunning(forTargetID: target.id))

    // Launching claude sets a command title — but the title alone must NOT mark it running.
    view.onTitleChange?("claude")
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
    XCTAssertEqual(s.tabs(for: target).first?.title, "claude")  // title still names the tab

    // Only an OSC 9;4 progress report drives the spinner: working → running…
    view.handleProgressReport(true)
    XCTAssertTrue(s.isRunning(forTargetID: target.id))
    // …and the busy state doesn't change the title text.
    XCTAssertEqual(s.tabs(for: target).first?.title, "claude")

    // …and idle (REMOVE) → not running, even though "claude" is still the title.
    view.handleProgressReport(false)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  func testCommandFinishedClearsProgress() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!

    view.handleProgressReport(true)
    XCTAssertTrue(s.isRunning(forTargetID: target.id))

    // The shell returning to the prompt stops the indicator even if the program never sent REMOVE.
    view.handleCommandFinished(rawExitCode: 0)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  /// The shipped zsh integration abbreviates a deep cwd to "…/dir/dir/dir" (`%(4~|…/%3~|%~)`). That
  /// truncated prompt title must still be recognised as a directory so it names the tab "Terminal N"
  /// rather than replacing it (issue #2 / the deep-cwd fix) — and it must never mark the tab busy.
  func testTruncatedDirectoryTitleIsTreatedAsDirectory() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!
    view.handlePwd("/var/data/dev/workroom/macapp/WorkroomApp")  // ≥4 deep → zsh truncates

    view.onTitleChange?("…/workroom/macapp/WorkroomApp")
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")  // not shown as the tab name
    XCTAssertFalse(s.isRunning(forTargetID: target.id))  // and never marks the tab busy
  }

  func testIsRunningAggregatesAcrossTabs() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)

    // Progress reported in the second tab makes the whole target "running".
    s.tabs(for: target)[1].surface!.handleProgressReport(true)
    XCTAssertTrue(s.isRunning(forTargetID: target.id))

    // It clears once that tab goes idle (the first never reported progress).
    s.tabs(for: target)[1].surface!.handleProgressReport(false)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  func testUnknownTargetIsNotRunning() {
    let s = makeSessions()
    XCTAssertFalse(s.isRunning(forTargetID: "wr|/p|never-opened"))
  }

  // MARK: Live titles (issue #2)

  func testRunningCommandShowsThenClearsWhenFinished() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!

    // A running command takes over from the default…
    view.onTitleChange?("npm run dev")
    XCTAssertEqual(s.tabs(for: target).first?.title, "npm run dev")

    // …a later command wins…
    view.onTitleChange?("vim README.md")
    XCTAssertEqual(s.tabs(for: target).first?.title, "vim README.md")

    // …and finishing the command falls back to the default "Terminal N".
    view.handleCommandFinished(rawExitCode: 0)
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")
  }

  func testDirectoryTitlesAreIgnoredSoTheCommandSurvives() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!
    view.handlePwd("/var/data/proj")  // cwd outside $HOME, so its `~` form is itself

    // The directory title the shell sets at the prompt is ignored → default stays.
    view.onTitleChange?("/var/data/proj")
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")

    // The command shows…
    view.onTitleChange?("sleep 5")
    XCTAssertEqual(s.tabs(for: target).first?.title, "sleep 5")

    // …and a directory title fired *during* the command doesn't clobber it.
    view.onTitleChange?("/var/data/proj")
    XCTAssertEqual(s.tabs(for: target).first?.title, "sleep 5")
  }

  func testSurfaceTitleIsScopedToItsOwnTab() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.tabs(for: target)[1].surface!.onTitleChange?("vim")
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 1", "vim"])
  }

  func testIsDirectoryTitleRecognizesPromptTitlesButNotCommands() {
    let home = "/Users/me"
    let cwd = "/Users/me/dev/codaset"
    // Directory / prompt titles in every form the shell emits:
    XCTAssertTrue(TerminalSessions.isDirectoryTitle(cwd, cwd: cwd, home: home))
    XCTAssertTrue(TerminalSessions.isDirectoryTitle("~/dev/codaset", cwd: cwd, home: home))
    XCTAssertTrue(
      TerminalSessions.isDirectoryTitle("me@MacBookPro:~/dev/codaset", cwd: cwd, home: home))
    // Real commands are not directory titles:
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("sleep 5", cwd: cwd, home: home))
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("vim README.md", cwd: cwd, home: home))
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("make: build failed", cwd: cwd, home: home))
    // No cwd yet → can't classify, so nothing is treated as a directory.
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("~/dev/codaset", cwd: nil, home: home))
  }

  func testIsDirectoryTitleRecognizesTruncatedPromptTitles() {
    let home = "/Users/me"
    // zsh `%(4~|…/%3~|%~)` truncates a deep path under $HOME to "…/" + the trailing 3 components.
    let deep = "/Users/me/dev/workroom/macapp/WorkroomApp"
    XCTAssertTrue(
      TerminalSessions.isDirectoryTitle("…/workroom/macapp/WorkroomApp", cwd: deep, home: home))
    // A path outside $HOME truncates the same way (absolute trailing components).
    let abs = "/var/data/dev/workroom/macapp"
    XCTAssertTrue(TerminalSessions.isDirectoryTitle("…/dev/workroom/macapp", cwd: abs, home: home))
    // bash's PROMPT_DIRTRIM uses a "..." marker — also a directory title.
    XCTAssertTrue(
      TerminalSessions.isDirectoryTitle(".../dev/workroom/macapp", cwd: abs, home: home))
    // A dot-prefixed first kept component is preserved (only the marker is stripped, not real dots).
    let hidden = "/Users/me/dev/.worktrees/bar/baz"
    XCTAssertTrue(
      TerminalSessions.isDirectoryTitle("…/.worktrees/bar/baz", cwd: hidden, home: home))
    // A command that merely starts with "…/" but isn't a suffix of the cwd is still a command.
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("…/other/path", cwd: deep, home: home))
  }

  // MARK: Splits (issue #3)

  func testSplitFocusedPaneFormsSplitAndFocusesNew() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)

    let tabs = s.tabs(for: target)
    XCTAssertEqual(tabs.count, 2)
    XCTAssertEqual(tabs.first?.id, a)  // existing pane stays first
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
    XCTAssertEqual(s.activeTab(for: target)?.id, tabs.last?.id)  // the new pane is focused
    XCTAssertTrue(s.isSplitVisible(for: target))
  }

  func testSplitInheritsFocusedPaneCwd() {
    var cwds: [String] = []
    let s = TerminalSessions()
    s.makeView = { _, cwd, _ in
      cwds.append(cwd)
      return GhosttySurfaceView(workingDirectory: cwd)
    }
    s.addTab(for: target)  // first surface spawns at the target path
    s.tabs(for: target).first!.surface!.handlePwd("/work/here")
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(cwds.count, 2)
    XCTAssertEqual(cwds.last, "/work/here")  // the split inherits the focused pane's cwd
  }

  func testSplitRefusedWhenPaneTooSmall() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)  // < 2 × either axis floor
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(s.tabs(for: target).count, 1)  // refused — no sliver
    XCTAssertNil(s.split(for: target))
  }

  /// The guard reads the floor for the axis it is dividing, so the same pane can refuse one split and
  /// permit the other. A tall, narrow pane (400 × 600) can't seat two 300pt-wide halves but seats two
  /// 120pt-tall ones — before the floors were split per axis, 400pt wide was "fine" and produced a pane
  /// too narrow to render its own tab strip.
  func testSplitRefusalFollowsTheAxisBeingDivided() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // (400-4)/2 = 198 < 300
    XCTAssertEqual(
      s.tabs(for: target).count, 1, "a 400pt-wide pane must refuse a side-by-side split")
    XCTAssertNil(s.split(for: target))
    s.splitFocusedPane(for: target, orientation: .vertical)  // (600-4)/2 = 298 ≥ 120
    XCTAssertEqual(s.tabs(for: target).count, 2, "the same pane must still stack")
    XCTAssertNotNil(s.split(for: target))
  }

  func testClosePaneCollapsesSplitToSibling() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let ids = s.tabs(for: target).map(\.id)  // [A, B], B focused
    s.closeTab(ids[1], for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertNil(s.split(for: target))  // dropped to a lone tab → no split
    XCTAssertEqual(s.activeTab(for: target)?.id, ids[0])  // sibling focused
    // The survivor is the only on-screen surface — occlusion must keep it visible (issue #3: closing
    // a split pane left the survivor blank when the view layer mishandled the re-home).
    XCTAssertEqual(s.visibleTabIDs(for: target), [ids[0]])
  }

  func testNewSplitFromSoloDissolvesPrevious() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // split [A, B]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // C solo, focused — not in the split
    XCTAssertFalse(s.isSplitVisible(for: target))
    s.splitFocusedPane(for: target, orientation: .vertical)  // new split from C
    let split = s.split(for: target)!
    XCTAssertEqual(split.tabIDs.count, 2)
    XCTAssertTrue(split.contains(c))
    XCTAssertFalse(split.contains(a))
    XCTAssertFalse(split.contains(b))  // only one split exists at a time
  }

  func testVisibleTabIDsTracksSplitVsSolo() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    XCTAssertEqual(s.visibleTabIDs(for: target), [a])
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(Set(s.visibleTabIDs(for: target)), Set(s.split(for: target)!.tabIDs))
    let c = s.addTab(for: target).id  // focusing a fresh solo tab hides the split
    XCTAssertEqual(s.visibleTabIDs(for: target), [c])
    XCTAssertFalse(s.isSplitVisible(for: target))
  }

  func testSplitMembersStayContiguousInStrip() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    _ = s.addTab(for: target)  // a second solo tab after A in the loose order
    s.focus(a, for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // split A | new
    let order = s.tabs(for: target).map(\.id)
    let memberIdxs = s.split(for: target)!.tabIDs.compactMap { order.firstIndex(of: $0) }.sorted()
    XCTAssertEqual(memberIdxs.count, 2)
    XCTAssertEqual(memberIdxs[1] - memberIdxs[0], 1)  // the two members render adjacent
  }

  // MARK: Drag-and-drop (issue #3, Phase 2)

  func testMoveTabOntoRightEdgeFormsSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(c, ontoEdge: .right, of: a, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs, [a, c])  // dropped on the right → second
    XCTAssertEqual(s.activeTab(for: target)?.id, c)  // the moved tab is focused
    XCTAssertTrue(s.isSplitVisible(for: target))
  }

  func testMoveTabOntoLeftEdgePlacesDroppedFirst() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id
    s.moveTabIntoSplit(c, ontoEdge: .left, of: a, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs, [c, a])  // left drop → leading
  }

  func testMoveTabJoinsExistingSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(c, ontoEdge: .bottom, of: b, for: target)
    XCTAssertEqual(Set(s.split(for: target)!.tabIDs), Set([a, b, c]))
    XCTAssertEqual(s.split(for: target)!.tabIDs.count, 3)
  }

  func testStartingSplitFromTwoSolosDissolvesOld() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    let d = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // fresh split (c, d)
    let split = s.split(for: target)!
    XCTAssertEqual(split.tabIDs, [c, d])
    XCTAssertFalse(split.contains(a))
    XCTAssertFalse(split.contains(b))  // single-split invariant: old split dissolved
  }

  func testExtractFromSplitMakesItSolo() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    s.splitFocusedPane(for: target, orientation: .vertical)  // [a, b, c], c focused
    let c = s.activeTab(for: target)!.id
    s.extractFromSplit(c, for: target)
    XCTAssertFalse(s.split(for: target)!.contains(c))
    XCTAssertEqual(s.split(for: target)!.tabIDs.count, 2)
    XCTAssertEqual(s.activeTab(for: target)?.id, c)  // extracted tab is solo + focused
    XCTAssertFalse(s.isSplitVisible(for: target))
  }

  func testExtractSecondToLastDissolvesSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    let b = s.activeTab(for: target)!.id
    s.extractFromSplit(b, for: target)
    XCTAssertNil(s.split(for: target))  // only one would remain → no split
    XCTAssertEqual(s.activeTab(for: target)?.id, b)
  }

  func testFocusAdjacentPaneMovesWithinSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b], b focused
    let b = s.activeTab(for: target)!.id
    XCTAssertTrue(s.focusAdjacentPane(.left, for: target))
    XCTAssertEqual(s.activeTab(for: target)?.id, a)
    XCTAssertTrue(s.focusAdjacentPane(.right, for: target))
    XCTAssertEqual(s.activeTab(for: target)?.id, b)
    XCTAssertFalse(s.focusAdjacentPane(.right, for: target))  // nothing to the right of b
  }

  func testFocusAdjacentPaneNoSplitIsNoOp() {
    let s = makeSessions()
    s.addTab(for: target)
    XCTAssertFalse(s.focusAdjacentPane(.right, for: target))
  }

  func testSplitFocusedPaneLeftPlacesNewPaneFirst() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, edge: .left)
    let split = s.split(for: target)!
    XCTAssertEqual(split.tabIDs.count, 2)
    XCTAssertEqual(split.tabIDs.last, a)  // original is now on the right
    XCTAssertEqual(split.tabIDs.first, s.activeTab(for: target)?.id)  // new pane: leading + focused
  }

  // MARK: onFocusChange seam (issue #26)

  /// The seam fires for add and the close-successor (D6) but not for `reap` (notify: false).
  func testOnFocusChangeFiresForAddAndCloseSuccessorButNotReap() async {
    let s = makeSessions()
    var events: [TerminalTab.ID?] = []
    s.onFocusChange = { _, tabID in events.append(tabID) }

    s.addTab(for: target)
    let t1 = s.tabs(for: target)[0].id
    s.addTab(for: target)
    let t2 = s.tabs(for: target)[1].id
    XCTAssertEqual(events, [t1, t2])

    events.removeAll()
    s.closeTab(t2, for: target)  // successor t1 becomes focused → fires (D6)
    XCTAssertEqual(events, [t1])

    events.removeAll()
    await s.reap(target.id)  // teardown → notify: false → must NOT fire
    XCTAssertTrue(events.isEmpty)
  }

  /// Splitting the focused pane fires the seam for the new pane.
  func testOnFocusChangeFiresForSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    var events: [TerminalTab.ID?] = []
    s.onFocusChange = { _, tabID in events.append(tabID) }
    s.splitFocusedPane(for: target, edge: .right)
    XCTAssertEqual(events, [s.activeTab(for: target)?.id])
  }

  /// Re-focusing the already-focused tab is a no-op and does not fire the seam.
  func testOnFocusChangeDoesNotFireWhenUnchanged() {
    let s = makeSessions()
    s.addTab(for: target)
    let only = s.activeTab(for: target)!.id
    var fired = 0
    s.onFocusChange = { _, _ in fired += 1 }
    s.focus(only, for: target)  // already focused → guarded no-op
    XCTAssertEqual(fired, 0)
  }

  /// onTabsRemoved fires for closeTab and reap, so history can prune dead entries (issue #26).
  func testOnTabsRemovedFiresForCloseAndReap() async {
    let s = makeSessions()
    var removed: [TerminalTab.ID] = []
    s.onTabsRemoved = { _, ids in removed.append(contentsOf: ids) }
    s.addTab(for: target)
    let t1 = s.tabs(for: target)[0].id
    s.addTab(for: target)
    let t2 = s.tabs(for: target)[1].id

    s.closeTab(t2, for: target)
    XCTAssertEqual(removed, [t2])

    removed.removeAll()
    await s.reap(target.id)  // remaining tab reaped
    XCTAssertEqual(removed, [t1])
  }

  // MARK: Content (diff) tabs (issue #66)

  private func diffDesc(_ path: String, _ source: DiffSource = .gitWorktree) -> DiffDescriptor {
    DiffDescriptor(path: path, change: .modified, source: source, isPreview: true)
  }

  func testOpenDiffPreviewCreatesAndFocusesPreviewTab() {
    let s = makeSessions()
    let id = s.openDiffPreview(diffDesc("dir/a.swift"), for: target)
    let tabs = s.tabs(for: target)
    XCTAssertEqual(tabs.count, 1)
    XCTAssertEqual(s.activeTab(for: target)?.id, id)
    XCTAssertTrue(tabs.first!.isPreview)
    XCTAssertEqual(tabs.first?.title, "a.swift")  // basename only
    XCTAssertNil(tabs.first?.surface)  // a content tab owns no surface
  }

  // MARK: File preview/persist tabs (mirror the diff mechanics; share the preview slot)

  func testOpenFilePreviewCreatesAndFocusesPreviewTab() {
    let s = makeSessions()
    let id = s.openFilePreview(FileDescriptor(path: "dir/notes.md", isPreview: false), for: target)
    let tabs = s.tabs(for: target)
    XCTAssertEqual(tabs.count, 1)
    XCTAssertEqual(s.activeTab(for: target)?.id, id)
    XCTAssertTrue(tabs.first!.isPreview)
    XCTAssertEqual(tabs.first?.title, "notes.md")  // basename only
    XCTAssertNil(tabs.first?.surface)  // a content tab owns no surface
  }

  func testSecondFilePreviewRetargetsInPlaceKeepingID() {
    let s = makeSessions()
    let first = s.openFilePreview(FileDescriptor(path: "a.txt", isPreview: false), for: target)
    let second = s.openFilePreview(FileDescriptor(path: "b.txt", isPreview: false), for: target)
    XCTAssertEqual(first, second)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertEqual(s.tabs(for: target).first?.title, "b.txt")
  }

  func testOpenFilePersistentCreatesNonPreview() {
    let s = makeSessions()
    let id = s.openFilePersistent(FileDescriptor(path: "a.txt", isPreview: false), for: target)
    XCTAssertFalse(s.tabs(for: target).first!.isPreview)
    XCTAssertEqual(s.activeTab(for: target)?.id, id)
  }

  func testReopeningAlreadyOpenFileReselectsItsTab() {
    let s = makeSessions()
    let persisted = s.openFilePersistent(
      FileDescriptor(path: "a.txt", isPreview: false), for: target)
    s.addTab(for: target)  // focus elsewhere
    let again = s.openFilePreview(FileDescriptor(path: "a.txt", isPreview: false), for: target)
    XCTAssertEqual(persisted, again, "reopening the same file reselects its tab, not a new one")
    XCTAssertFalse(s.tabs(for: target).first { $0.id == again }!.isPreview, "stays persisted")
  }

  func testPersistPromotesFilePreviewSoItIsNoLongerRetargeted() {
    let s = makeSessions()
    let id = s.openFilePreview(FileDescriptor(path: "a.txt", isPreview: false), for: target)
    s.persist(id, for: target)
    XCTAssertFalse(s.tabs(for: target).first!.isPreview)
    let next = s.openFilePreview(FileDescriptor(path: "b.txt", isPreview: false), for: target)
    XCTAssertNotEqual(id, next, "a promoted file tab is no longer the retargetable preview slot")
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  // MARK: Markdown source/preview override (tab-toolbar switch)

  func testMarkdownPreviewOverrideDefaultsNil() {
    let s = makeSessions()
    let id = s.openFilePreview(FileDescriptor(path: "notes.md", isPreview: false), for: target)
    // nil ⇒ the view falls back to its default (Markdown opens rendered).
    XCTAssertNil(s.tab(id, for: target)?.markdownPreviewOverride)
  }

  func testSetMarkdownPreviewStoresOverrideOnTab() {
    let s = makeSessions()
    let id = s.openFilePreview(FileDescriptor(path: "notes.md", isPreview: false), for: target)
    s.setMarkdownPreview(false, forTab: id, in: target)
    XCTAssertEqual(s.tab(id, for: target)?.markdownPreviewOverride, false)
    s.setMarkdownPreview(true, forTab: id, in: target)
    XCTAssertEqual(s.tab(id, for: target)?.markdownPreviewOverride, true)
  }

  func testSetMarkdownPreviewIsNoOpForNonFileTab() {
    let s = makeSessions()
    s.addTab(for: target)  // a terminal tab
    let termID = s.activeTab(for: target)!.id
    s.setMarkdownPreview(false, forTab: termID, in: target)
    XCTAssertNil(s.tab(termID, for: target)?.markdownPreviewOverride)

    let diffID = s.openDiffPreview(diffDesc("a.swift"), for: target)
    s.setMarkdownPreview(false, forTab: diffID, in: target)
    XCTAssertNil(s.tab(diffID, for: target)?.markdownPreviewOverride)
  }

  /// The key cross-type invariant: files and diffs SHARE the single preview slot. Opening a file
  /// preview retargets the lone diff preview in place (same id/slot), and vice-versa — never two
  /// preview tabs.
  func testFileAndDiffSharePreviewSlot() {
    let s = makeSessions()
    let diff = s.openDiffPreview(diffDesc("a.swift"), for: target)
    let file = s.openFilePreview(FileDescriptor(path: "b.txt", isPreview: false), for: target)
    XCTAssertEqual(diff, file, "a file preview retargets the diff preview in place")
    XCTAssertEqual(s.tabs(for: target).count, 1)
    if case .file(let f) = s.tabs(for: target).first?.content {
      XCTAssertEqual(f.path, "b.txt")
    } else {
      XCTFail("the shared preview slot should now hold the file")
    }
    // …and back the other way: a diff preview retargets the file preview.
    let diff2 = s.openDiffPreview(diffDesc("c.swift"), for: target)
    XCTAssertEqual(file, diff2)
    XCTAssertEqual(s.tabs(for: target).count, 1)
  }

  /// A second preview retargets the lone preview tab IN PLACE — same id (keeps slot), still ≤1
  /// preview (Inv A + Inv B).
  func testSecondPreviewRetargetsInPlaceKeepingID() {
    let s = makeSessions()
    let first = s.openDiffPreview(diffDesc("a.swift"), for: target)
    let second = s.openDiffPreview(diffDesc("b.swift"), for: target)
    XCTAssertEqual(first, second)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertEqual(s.tabs(for: target).first?.title, "b.swift")
    XCTAssertTrue(s.tabs(for: target).first!.isPreview)
  }

  func testPreviewTabCoexistsWithTerminalAndStaysSingle() {
    let s = makeSessions()
    s.addTab(for: target)  // a terminal
    let diff = s.openDiffPreview(diffDesc("a.swift"), for: target)
    XCTAssertEqual(s.tabs(for: target).count, 2)
    XCTAssertEqual(s.activeTab(for: target)?.id, diff)
    // Select the terminal, then preview another file → still the SAME single preview tab.
    let term = s.tabs(for: target).first { $0.surface != nil }!.id
    s.select(term, for: target)
    let diff2 = s.openDiffPreview(diffDesc("c.swift"), for: target)
    XCTAssertEqual(diff, diff2)
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  func testOpenDiffPersistentCreatesNonPreview() {
    let s = makeSessions()
    let id = s.openDiffPersistent(
      DiffDescriptor(path: "a.swift", change: .added, source: .gitWorktree, isPreview: false),
      for: target)
    XCTAssertFalse(s.tabs(for: target).first!.isPreview)
    XCTAssertEqual(s.activeTab(for: target)?.id, id)
  }

  func testPersistPromotesPreviewSoItIsNoLongerRetargeted() {
    let s = makeSessions()
    let id = s.openDiffPreview(diffDesc("a.swift"), for: target)
    s.persist(id, for: target)
    XCTAssertFalse(s.tabs(for: target).first!.isPreview)
    // No preview tab remains, so a new file opens a NEW tab instead of retargeting.
    let id2 = s.openDiffPreview(diffDesc("b.swift"), for: target)
    XCTAssertNotEqual(id, id2)
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  /// Opening a file that already has a tab re-selects it rather than duplicating (Inv C).
  func testOpeningAlreadyOpenFileReselectsIt() {
    let s = makeSessions()
    let persisted = s.openDiffPersistent(
      DiffDescriptor(path: "a.swift", change: .modified, source: .gitWorktree, isPreview: false),
      for: target)
    s.addTab(for: target)  // focus moves to a terminal
    let again = s.openDiffPreview(diffDesc("a.swift"), for: target)
    XCTAssertEqual(persisted, again)
    XCTAssertFalse(s.tabs(for: target).first { $0.id == persisted }!.isPreview)  // stays persisted
  }

  /// The same path from different revisions are distinct tabs (jj working copy vs parent).
  func testSameFileDifferentSourceAreDistinctTabs() {
    let s = makeSessions()
    let wc = s.openDiffPersistent(
      DiffDescriptor(path: "a.swift", change: .modified, source: .jjWorkingCopy, isPreview: false),
      for: target)
    let parent = s.openDiffPersistent(
      DiffDescriptor(path: "a.swift", change: .modified, source: .jjParent, isPreview: false),
      for: target)
    XCTAssertNotEqual(wc, parent)
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  func testCloseContentTabFallsBackToTerminal() {
    let s = makeSessions()
    s.addTab(for: target)
    let diff = s.openDiffPreview(diffDesc("a.swift"), for: target)  // focused
    s.closeTab(diff, for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertNotNil(s.activeTab(for: target)?.surface)  // revealed the terminal
  }

  func testReapClearsContentTabs() async {
    let s = makeSessions()
    s.openDiffPreview(diffDesc("a.swift"), for: target)
    await s.reap(target.id)
    XCTAssertTrue(s.tabs(for: target).isEmpty)
  }

  /// Splitting a diff pane opens a second view of the SAME diff as a fresh PREVIEW pane (#72) — not a
  /// terminal. The original is pinned (persisted); the new pane is the focused, un-persisted preview.
  func testSplitDiffOpensSameDiffAsPreviewPane() {
    let s = makeSessions()
    let diff = s.openDiffPreview(diffDesc("a.swift"), for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let tabs = s.tabs(for: target)
    XCTAssertEqual(tabs.count, 2)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
    XCTAssertTrue(s.split(for: target)!.contains(diff))
    // The new pane is a diff (no surface) of the SAME file, focused and un-persisted…
    let new = s.activeTab(for: target)!
    XCTAssertNotEqual(new.id, diff)
    XCTAssertNil(new.surface)
    XCTAssertEqual(new.title, "a.swift")
    XCTAssertTrue(new.isPreview)
    // …and the original anchor is now pinned (persisted) so it can't be retargeted out from under us.
    XCTAssertFalse(tabs.first { $0.id == diff }!.isPreview)
  }

  func testContentTabIsNeverRunning() {
    let s = makeSessions()
    s.openDiffPreview(diffDesc("a.swift"), for: target)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  // MARK: splitTab — split a *specific* tab (issue #72)

  /// `splitTab` acts on the given tab even when another is focused: it selects the anchor first, then
  /// splits it (the toolbar/context-menu entry point, vs `splitFocusedPane` which uses the focus).
  func testSplitTabSplitsTheGivenTabNotTheFocusedOne() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    _ = s.addTab(for: target)  // B, now focused
    s.splitTab(a, on: .right, for: target)
    XCTAssertTrue(s.split(for: target)?.contains(a) ?? false)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
    // The new pane (last in the split) is focused.
    XCTAssertEqual(s.activeTab(for: target)?.id, s.split(for: target)?.tabIDs.last)
  }

  /// Splitting a *preview* diff pins the original (review D6) and makes the NEW split pane the preview
  /// slot: a later Changes-panel single-click retargets that new pane, leaving the pinned original and
  /// adding no extra tab.
  func testSplitTabPinsOriginalAndNewPaneBecomesPreviewSlot() {
    let s = makeSessions()
    let diff = s.openDiffPreview(diffDesc("a.swift"), for: target)
    XCTAssertTrue(s.tabs(for: target).first!.isPreview)
    s.splitTab(diff, on: .right, for: target)
    // The original is pinned (persisted)…
    XCTAssertFalse(s.tabs(for: target).first { $0.id == diff }!.isPreview)
    // …and the new split pane is the preview slot: a later preview retargets IT (not the original).
    let new = s.activeTab(for: target)!.id
    XCTAssertNotEqual(new, diff)
    let retargeted = s.openDiffPreview(diffDesc("b.swift"), for: target)
    XCTAssertEqual(retargeted, new)
    XCTAssertEqual(s.tabs(for: target).count, 2)  // retargeted in place, no new tab
    XCTAssertEqual(s.tabs(for: target).first { $0.id == new }?.title, "b.swift")
  }

  /// `splitTab` no-ops for an unknown tab id.
  func testSplitTabUnknownTabIsNoOp() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitTab(UUID(), on: .right, for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertNil(s.split(for: target))
  }
}
