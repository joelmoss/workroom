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
    // Defaults to a no-op so a future test setting `foregroundProcessNameForTesting` to an
    // unrecognized name doesn't silently write to the developer's real `Application Support` file
    // (review finding) — the same reasoning `makeView` above already applies to spawning real shells.
    sessions.recordUnrecognizedTool = { _ in }
    // A fresh recency list per test, so close-successor order never depends on (or pollutes) the
    // app-wide singleton the quick switcher uses.
    sessions.recency = SwitcherRecency()
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

  /// Issue #160: closing the active tab lands you back on the tab you were last in, not on whichever
  /// tab happens to slide into the closed one's slot.
  func testCloseActiveSelectsLastFocusedTab() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)  // focus order so far: 1 → 2 → 3
    let first = s.tabs(for: target)[0].id
    s.select(first, for: target)
    s.closeTab(first, for: target)
    // "Terminal 2" slid into slot 0, but "Terminal 3" is where the user was before this tab.
    XCTAssertEqual(s.activeTab(for: target)?.title, "Terminal 3")
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  /// Tabs recency has never seen (a restored session) keep the old rule: the neighbour that slides
  /// into the closed tab's slot.
  func testCloseActiveFallsBackToNeighbourWithoutRecency() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    let first = s.tabs(for: target)[0].id
    s.select(first, for: target)
    s.recency = SwitcherRecency()  // as if none of these tabs had ever been focused
    s.closeTab(first, for: target)
    XCTAssertEqual(s.activeTab(for: target)?.title, "Terminal 2")
  }

  /// A split that survives the close keeps focus inside itself — `isSplitVisible` follows focus, so a
  /// most-recent tab from outside would take the whole split off screen.
  func testCloseSplitMemberStaysInsideASurvivingSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .vertical)
    let members = s.split(for: target)!.tabIDs
    XCTAssertEqual(members.count, 3)
    let outsider = s.addTab(for: target).id  // solo, and now the most recent tab
    let closing = members[2]
    s.select(closing, for: target)  // a split member is focused again
    s.closeTab(closing, for: target)

    let successor = s.activeTab(for: target)?.id
    XCTAssertNotEqual(successor, outsider, "focusing the outsider would hide the surviving split")
    XCTAssertTrue(s.split(for: target)!.contains(successor!))
    XCTAssertTrue(s.isSplitVisible(for: target))
  }

  /// A two-member split dissolves when one member closes, but its lone survivor was on screen beside
  /// the closed pane — so it wins over a more-recently-focused tab from outside the split.
  func testCloseTwoMemberSplitPrefersTheSurvivingSibling() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let members = s.split(for: target)!.tabIDs
    XCTAssertEqual(members.count, 2)
    let outsider = s.addTab(for: target).id  // solo, and more recent than the sibling
    s.select(members[1], for: target)
    s.closeTab(members[1], for: target)

    XCTAssertNil(s.split(for: target), "a 2-member split dissolves when one member closes")
    XCTAssertEqual(s.activeTab(for: target)?.id, members[0], "the sibling that was on screen")
    XCTAssertNotEqual(s.activeTab(for: target)?.id, outsider)
  }

  /// `recency.panes` is app-wide, so the successor must be filtered to this target: a more-recent
  /// pane in another workroom is not somewhere this close can land.
  func testCloseSuccessorIgnoresMoreRecentPaneFromAnotherTarget() {
    let s = makeSessions()
    let other = TerminalTarget(id: "wr|/p|other", title: "other", path: "/tmp", isMissing: false)
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)  // focus order: 1 → 2 → 3
    let first = s.tabs(for: target)[0].id
    s.select(first, for: target)
    let elsewhere = s.addTab(for: other).id  // the most recent pane app-wide
    s.closeTab(first, for: target)

    let successor = s.activeTab(for: target)?.id
    XCTAssertNotEqual(successor, elsewhere)
    XCTAssertEqual(
      s.activeTab(for: target)?.title, "Terminal 3", "the last tab focused in THIS target")
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

    // Claude is identified from the PTY foreground process even when its first visible OSC title is
    // already provider-owned rather than the shell's command line.
    view.foregroundProcessNameForTesting = "claude"
    view.onTitleChange?("✳ Claude Code")
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
    XCTAssertEqual(s.tabs(for: target).first?.title, "✳ Claude Code")
    XCTAssertEqual(activeAgent(in: s), .claude)

    // Later title repaints while waiting or working must not hide quota.
    view.onTitleChange?("✻ Planning…")
    XCTAssertEqual(s.tabs(for: target).first?.title, "✻ Planning…")
    XCTAssertEqual(activeAgent(in: s), .claude)

    // Only an OSC 9;4 progress report drives the spinner: working → running…
    view.handleProgressReport(true)
    XCTAssertTrue(s.isRunning(forTargetID: target.id))
    // …and the busy state doesn't change the title text.
    XCTAssertEqual(s.tabs(for: target).first?.title, "✻ Planning…")

    // …and idle (REMOVE) → not running, even though "claude" is still the title.
    view.handleProgressReport(false)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
    XCTAssertEqual(activeAgent(in: s), .claude, "OSC progress does not end the agent command")
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
    XCTAssertNil(activeAgent(in: s), "command_finished removes quota immediately")
  }

  func testActiveAgentsIncludeBackgroundTargetsAndDeduplicateProviders() {
    let sessions = makeSessions()
    let other = TerminalTarget(id: "wr|/p|other", title: "other", path: "/tmp", isMissing: false)
    sessions.addTab(for: target)
    let first = sessions.tabs(for: target)[0].surface!
    first.foregroundProcessNameForTesting = "codex"
    first.onTitleChange?("Codex")
    sessions.addTab(for: target)
    let second = sessions.tabs(for: target)[1].surface!
    second.foregroundProcessNameForTesting = "codex"
    second.onTitleChange?("Codex")
    sessions.addTab(for: other)
    let claude = sessions.tabs(for: other)[0].surface!
    claude.foregroundProcessNameForTesting = "claude"
    claude.onTitleChange?("Claude")
    sessions.addTab(for: other)  // The focused tab is an ordinary shell.
    XCTAssertEqual(sessions.activeAgentBackends, [.codex, .claude])

    first.handleCommandFinished(rawExitCode: 0)
    XCTAssertEqual(sessions.activeAgentBackends, [.codex, .claude])
    second.handleCommandFinished(rawExitCode: 0)
    XCTAssertEqual(sessions.activeAgentBackends, [.claude])
    claude.handleCommandFinished(rawExitCode: 0)
    XCTAssertTrue(sessions.activeAgentBackends.isEmpty)
  }

  func testCodexAgentSurvivesProviderTitleRepaint() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!

    view.foregroundProcessNameForTesting = "codex"
    view.onTitleChange?("Implement the requested changes")
    XCTAssertEqual(activeAgent(in: s), .codex)

    view.onTitleChange?("Reviewing files")
    XCTAssertEqual(activeAgent(in: s), .codex)

    view.handleCommandFinished(rawExitCode: 0)
    XCTAssertNil(activeAgent(in: s))
  }

  /// The curated tool favicon (issue #141) is a broader, data-driven sibling of `activeAgentBackend`
  /// — same latch-until-`command_finished` lifecycle, same first-wins semantics. Modeled directly on
  /// `testCodexAgentSurvivesProviderTitleRepaint` above.
  func testRecognizedToolLatchesSurvivesRepaintAndClears() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!

    view.foregroundProcessNameForTesting = "git"
    view.onTitleChange?("git status")
    XCTAssertEqual(s.tabs(for: target).first?.recognizedTool?.id, "git")

    // A later, unrelated title repaint must not clear or re-derive the latch (first-wins).
    view.onTitleChange?("vim README.md")
    XCTAssertEqual(
      s.tabs(for: target).first?.recognizedTool?.id, "git",
      "the icon swaps between commands, not mid-repaint")

    view.handleCommandFinished(rawExitCode: 0)
    XCTAssertNil(s.tabs(for: target).first?.recognizedTool, "command_finished clears the icon")
  }

  /// A foreground command not in the curated `ToolLogoRegistry` (issue #141 follow-up) is tallied
  /// exactly once per new title — not per repaint of the same still-unrecognized command — and a
  /// recognized command (e.g. "git") is never tallied at all.
  func testUnrecognizedForegroundCommandIsRecordedOncePerNewTitleNotRecognizedOnes() {
    let s = makeSessions()
    var recorded: [String] = []
    s.recordUnrecognizedTool = { recorded.append($0) }
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.surface!

    view.foregroundProcessNameForTesting = "some-random-tool"
    view.onTitleChange?("some-random-tool --flag")
    view.onTitleChange?("some-random-tool --flag")  // repaint of the same command: no re-count
    XCTAssertEqual(recorded, ["some-random-tool"])

    view.foregroundProcessNameForTesting = "git"
    view.onTitleChange?("git status")
    XCTAssertEqual(recorded, ["some-random-tool"], "a recognized command is never tallied")
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

  /// The `home` default must be the cached value, not a fresh `NSHomeDirectory()` per call: this is
  /// on the terminal title-change path (`handleTitleChange` on every `ghostty_app_tick`), and
  /// WORKROOM-3P sampled the main thread inside `NSHomeDirectoryForUser` → `CFURLCopyFileSystemPath`
  /// → malloc reached from exactly here.
  ///
  /// Read at the SOURCE level, the same way `DefaultsIsolationTests` enforces `suite: .app`. A
  /// behavioural assertion cannot see this: both spellings of the default return the identical
  /// string, so `isDirectoryTitle` gives byte-identical answers either way and a test built on its
  /// return value passes against the un-fixed code (measured — it did). The declaration is the only
  /// place the regression is observable.
  func testIsDirectoryTitleDefaultsToTheCachedHomeDirectory() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WorkroomAppTests
        .deletingLastPathComponent()  // macapp
        .appendingPathComponent("WorkroomApp/Core/TerminalSessions.swift"), encoding: .utf8)

    guard
      let declaration = source.components(separatedBy: "func isDirectoryTitle").dropFirst().first
    else { return XCTFail("parse looks wrong — `isDirectoryTitle` not found") }
    // Collapse whitespace before matching. The declaration sits a few characters under
    // swift-format's 100-column limit, so a slightly longer parameter name would wrap the default
    // onto its own line and fail this against correct code.
    let signature = declaration.prefix { $0 != "{" }
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")

    XCTAssertTrue(
      signature.contains("home: String = cachedHomeDirectory"),
      "`isDirectoryTitle` must default `home:` to the cached value; resolving NSHomeDirectory() per "
        + "call allocates through CFURLCopyFileSystemPath on every terminal title change")
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

  /// The laid-out pane rect wins over the surface's own bounds when both are available — the
  /// measurement `fits(splitting:)` was normalized to in issue #150.
  ///
  /// This is the case nothing covered before: a TERMINAL tab has a surface, so it used to be measured
  /// by `surface.bounds` while a diff tab (no surface) was measured by `paneRects`. Those are two
  /// different rectangles — a surface excludes the pane's chrome, a pane rect includes it — and the
  /// gap is now 56pt (title bar + status bar), so two identically-sized panes disagreed about whether
  /// the same split fit. Seeding the two deliberately in conflict is the only way to prove which one
  /// the guard reads; with both agreeing, either order passes.
  func testPaneRectBeatsSurfaceBoundsOnceLaidOut() {
    let s = makeSessions()
    s.addTab(for: target)
    let tab = s.tabs(for: target).first!
    // The surface alone would REFUSE: (200-4)/2 = 98 < 300.
    tab.surface!.frame = CGRect(x: 0, y: 0, width: 200, height: 600)
    // The pane the renderer actually laid out PERMITS: (1000-4)/2 = 498 ≥ 300.
    s.paneRects[target.id] = [tab.id: CGRect(x: 0, y: 0, width: 1000, height: 600)]
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(
      s.tabs(for: target).count, 2,
      "the laid-out pane rect is authoritative once layout has run, not the surface's bounds")
    XCTAssertNotNil(s.split(for: target))
  }

  /// The surface remains the PRE-LAYOUT fallback: before the renderer has laid the tree out once,
  /// `paneRects` is empty and a live surface is the only thing that knows its size. Without this, the
  /// normalization above would have made every first split unguarded.
  func testSurfaceBoundsStillGuardBeforeFirstLayout() {
    let s = makeSessions()
    s.addTab(for: target)
    s.tabs(for: target).first!.surface!.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    XCTAssertNil(s.paneRects[target.id], "no layout has run yet")
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(s.tabs(for: target).count, 1, "refused on the surface's bounds alone")
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

  /// The ⌘D seed path's half of the reported bug (the drag path is covered above): splitting a solo
  /// tab while another group exists must leave that group alone. Asserted through `splits(for:)` and
  /// `split(containing:for:)` — `split(for:)` alone cannot tell "dissolved" from "alive off screen",
  /// which is why the old version of this test passed under BOTH models.
  func testNewSplitFromSoloLeavesThePreviousGroupIntact() {
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
    XCTAssertFalse(split.contains(b))  // the new group holds c + its new pane, not a/b
    // …and the first group is still there, off screen, intact.
    XCTAssertEqual(s.splits(for: target).count, 2)
    XCTAssertEqual(s.split(containing: a, for: target)?.tabIDs, [a, b])
  }

  /// `setRatio` is addressed by the split NODE's id, so it has to find the right group among several.
  /// Both halves are asserted: the targeted group actually moves, and its sibling does not \u2014 asserting
  /// only "the sibling is still 0.5" would pass against a `setRatio` that did nothing at all.
  func testSetRatioOnlyTouchesItsOwnGroup() throws {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 1
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 2

    let groupOne = try XCTUnwrap(s.split(containing: a, for: target))
    let groupTwo = try XCTUnwrap(s.split(containing: c, for: target))
    guard case .split(let twoID, _, _, _, _) = groupTwo,
      case .split(let oneID, _, _, _, _) = groupOne
    else { return XCTFail("both groups are split nodes") }

    s.setRatio(0.8, forSplit: twoID, for: target)
    XCTAssertEqual(
      s.split(containing: c, for: target)?.ratio(forSplit: twoID) ?? -1, 0.8, accuracy: 0.0001,
      "the addressed group moved")
    XCTAssertEqual(
      s.split(containing: a, for: target)?.ratio(forSplit: oneID) ?? -1, 0.5, accuracy: 0.0001,
      "its sibling group did not")
  }

  /// "Resize Splits Evenly" acts on what is ON SCREEN. With the focused tab solo there is no visible
  /// group, so an off-screen group must keep the divider the user dragged rather than being evened
  /// behind their back. Skewed to 0.8 first \u2014 asserting the even value would pass either way.
  func testEqualizeSplitIsANoOpWhenTheFocusedTabIsSolo() throws {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let group = try XCTUnwrap(s.split(containing: a, for: target))
    guard case .split(let rootID, _, _, _, _) = group else { return XCTFail("expected a split") }
    s.setRatio(0.8, forSplit: rootID, for: target)

    let solo = s.addTab(for: target).id  // focus leaves the group
    XCTAssertEqual(s.activeTab(for: target)?.id, solo)
    XCTAssertFalse(s.isSplitVisible(for: target))

    s.equalizeSplit(for: target)
    XCTAssertEqual(
      s.split(containing: a, for: target)?.ratio(forSplit: rootID) ?? -1, 0.8, accuracy: 0.0001,
      "an off-screen group keeps its dividers")

    // ...and with a member focused again, the same call DOES even it \u2014 so the no-op above is the
    // solo-focus branch, not a broken equalizeSplit.
    s.focus(a, for: target)
    s.equalizeSplit(for: target)
    XCTAssertEqual(
      s.split(containing: a, for: target)?.ratio(forSplit: rootID) ?? -1, 0.5, accuracy: 0.0001)
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

  func testDraggingCurrentTabSplitsWithMostRecentTab() {
    for edge in [PaneEdge.left, .right, .top, .bottom] {
      let s = makeSessions()
      let previous = s.addTab(for: target).id
      let current = s.addTab(for: target).id
      let surface = s.tab(current, for: target)?.surface
      s.dropTabFromStrip(current, ontoEdge: edge, of: current, for: target)
      XCTAssertEqual(
        s.split(for: target)?.tabIDs,
        edge.placesDroppedFirst ? [current, previous] : [previous, current])
      XCTAssertEqual(s.activeTab(for: target)?.id, current)
      XCTAssertEqual(s.tabs(for: target).count, 2)
      XCTAssertTrue(s.tab(current, for: target)?.surface === surface)
    }
  }

  func testDraggingOnlyTabOntoItselfDoesNothing() {
    let s = makeSessions()
    let current = s.addTab(for: target).id
    XCTAssertNil(s.tabStripSplitDestination(moving: current, over: current, for: target))
    s.dropTabFromStrip(current, ontoEdge: .right, of: current, for: target)
    XCTAssertNil(s.split(for: target))
    XCTAssertEqual(s.tabs(for: target).count, 1)
  }

  func testDraggingCurrentTabRespectsVisiblePaneSize() {
    let s = makeSessions()
    let previous = s.addTab(for: target).id
    let current = s.addTab(for: target).id
    s.paneRects[target.id] = [current: CGRect(x: 0, y: 0, width: 200, height: 600)]
    s.dropTabFromStrip(current, ontoEdge: .right, of: current, for: target)
    XCTAssertNil(s.split(for: target))
    XCTAssertEqual(s.activeTab(for: target)?.id, current)
    XCTAssertEqual(s.tabs(for: target).map(\.id), [previous, current])
  }

  func testDraggingSplitMemberOntoItselfDoesNotRearrangeGroup() {
    let s = makeSessions()
    let first = s.addTab(for: target).id
    s.splitFocusedPane(for: target, edge: .right)
    let current = s.activeTab(for: target)!.id
    XCTAssertNil(s.tabStripSplitDestination(moving: current, over: current, for: target))
    s.dropTabFromStrip(current, ontoEdge: .left, of: current, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs, [first, current])
  }

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

  /// The reported bug, exactly: four terminals, split two together, then split the OTHER two — which
  /// worked, but also unsplit the first pair. Groups are disjoint and additive now, so both survive.
  func testStartingSplitFromTwoSolosKeepsTheExistingGroup() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 1: [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    let d = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 2: [c, d]

    XCTAssertEqual(s.splits(for: target).count, 2, "grouping c+d must not dissolve a+b")
    XCTAssertEqual(s.split(containing: a, for: target)?.tabIDs, [a, b])
    XCTAssertEqual(s.split(containing: c, for: target)?.tabIDs, [c, d])
    // Only the group holding the focused tab is on screen; the other persists off screen.
    XCTAssertEqual(s.split(for: target)?.tabIDs, [c, d])
    XCTAssertEqual(s.visibleTabIDs(for: target), [c, d])
    // Each group is one contiguous run in the strip, so each gets its own bracket. Reorder FIRST so
    // the loose order interleaves the groups — asserting against [a, b, c, d] straight after the
    // split would pass even if `normalizedTabIDs` returned the raw order untouched.
    // loose order becomes [c, a, b, d] — group 2 now straddles group 1.
    s.moveTab(c, toIndex: 0, for: target)
    XCTAssertEqual(
      s.displayedTabIDs(for: target), [c, d, a, b],
      "each group is pulled contiguous at its earliest member's slot")
    // Selecting back into the first group brings it back — nothing was destroyed.
    s.focus(a, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs, [a, b])
    XCTAssertEqual(s.splits(for: target).count, 2)
  }

  /// The groups stay disjoint when a member is dragged from one into the other: it LEAVES the first.
  func testMovingAMemberBetweenGroupsLeavesTheFirst() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 1: [a, b, c]
    let c = s.activeTab(for: target)!.id
    let d = s.addTab(for: target).id
    let e = s.addTab(for: target).id
    s.moveTabIntoSplit(e, ontoEdge: .right, of: d, for: target)  // group 2: [d, e]

    s.moveTabIntoSplit(c, ontoEdge: .right, of: d, for: target)
    XCTAssertEqual(s.splits(for: target).count, 2)
    XCTAssertFalse(s.split(containing: a, for: target)!.contains(c), "c left the first group")
    XCTAssertEqual(s.split(containing: a, for: target)!.tabIDs.count, 2)
    XCTAssertEqual(Set(s.split(containing: d, for: target)!.tabIDs), Set([c, d, e]))
  }

  /// A group whose last-but-one member leaves is deleted, and the OTHER groups keep their indices
  /// usable — the array shifts under a stale index, which is why every mutation re-resolves by id.
  func testDissolvingOneGroupLeavesTheOthersIntact() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 1: [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 2: [c, d]
    XCTAssertEqual(s.splits(for: target).count, 2, "precondition: both groups exist")

    s.closeTab(b, for: target)  // group 1 falls to one leaf → gone
    XCTAssertEqual(s.splits(for: target).count, 1)
    XCTAssertNil(s.split(containing: a, for: target), "a is solo again")
    XCTAssertEqual(s.split(containing: c, for: target)?.tabIDs, [c, d])
  }

  /// **REGRESSION.** `moveTabIntoSplit` re-resolves the destination group AFTER the detach, because
  /// removing the last-but-one member DELETES that group and shifts every later index down. Nothing
  /// else reaches the shift: the cross-group drag above leaves a three-pane group, which survives.
  /// Holding the pre-detach index here would hand `setSplit` an index that no longer addresses
  /// anything, and it appends there — seeding a SECOND group over leaves the first already owns.
  func testMovingOutOfATwoPaneGroupReindexesTheDestination() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 0: [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 1: [c, d]

    s.moveTabIntoSplit(a, ontoEdge: .right, of: c, for: target)  // group 0 dies → group 1 becomes 0

    XCTAssertEqual(s.splits(for: target).count, 1, "one group, not a second at a stale index")
    XCTAssertNil(s.split(containing: b, for: target), "b is solo — its group fell below two")
    XCTAssertEqual(Set(s.split(containing: c, for: target)?.tabIDs ?? []), Set([a, c, d]))
  }

  /// ⌘D on a member of a group that is NOT the first one. `splitFocusedPane` grows the FOCUSED pane's
  /// own group, addressed by index; every other growth test in this file owns exactly one group, where
  /// "grow group 0" and "grow the focused pane's group" are the same answer and so prove nothing.
  func testSplittingAMemberOfALaterGroupGrowsOnlyThatGroup() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 0: [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 1: [c, d], d focused

    s.splitFocusedPane(for: target, orientation: .vertical)

    XCTAssertEqual(s.splits(for: target).count, 2)
    XCTAssertEqual(s.split(containing: c, for: target)?.tabIDs.count, 3, "the focused group grew")
    XCTAssertEqual(s.split(containing: a, for: target)?.tabIDs, [a, b], "the first group did not")
  }

  /// Closing a split member lands focus on a survivor of THAT group — `closeSuccessor` narrows its
  /// candidates through `splitRemoving`, now an index-addressed lookup among several groups. Recency
  /// is seeded to prefer a tab in the OTHER group, so a successor that skipped the narrowing would
  /// land there and sweep the pane beside the closed one off screen.
  func testCloseSuccessorStaysInsideTheClosedTabsOwnGroup() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 0: [a, b]
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 1: [c, d]
    s.focus(a, for: target)  // a is the most recent…
    s.focus(d, for: target)  // …behind d, so recency's next pick is a

    s.closeTab(d, for: target)
    XCTAssertEqual(s.activeTab(for: target)?.id, c, "d's own survivor, not recency's a")
    XCTAssertNil(s.split(containing: c, for: target), "and that group is gone — c is solo")
  }

  /// The tab strip's only view of the split model: `member → group index`, which is what lets it draw
  /// one bracket per group and tell a group boundary from an interior one. Asserted as two DISTINCT
  /// indices addressing `splits(for:)`'s own positions — "both tabs are grouped" would pass against a
  /// map that put every member in group 0 and so drew one bracket across both groups.
  func testSplitGroupIndicesMapsEachMemberToItsOwnGroup() throws {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)
    let solo = s.addTab(for: target).id

    let groupOf = s.splitGroupIndices(for: target)
    let first = try XCTUnwrap(groupOf[a])
    let second = try XCTUnwrap(groupOf[c])
    XCTAssertEqual(groupOf[b], first)
    XCTAssertEqual(groupOf[d], second)
    XCTAssertNotEqual(first, second, "two groups, two brackets — not one drawn over both")
    XCTAssertNil(groupOf[solo], "an ungrouped chip gets no bracket")
    let groups = s.splits(for: target)
    XCTAssertEqual(groups[first].tabIDs, [a, b])
    XCTAssertEqual(Set(groups[second].tabIDs), Set([c, d]))
  }

  /// "Resize Splits Evenly" is addressed by the FOCUSED tab's group index, so among several groups it
  /// must even that one and leave the rest at the dividers the user dragged. BOTH groups are skewed to
  /// 0.8 first — asserting the even value on the untouched group would pass either way.
  func testEqualizeSplitOnlyEvensTheFocusedGroup() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // group 0: [a, b]
    let c = s.addTab(for: target).id
    let d = s.addTab(for: target).id
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // group 1: [c, d], d focused

    guard case .split(let firstID, _, _, _, _) = s.split(containing: a, for: target),
      case .split(let secondID, _, _, _, _) = s.split(containing: c, for: target)
    else { return XCTFail("both groups are split nodes") }
    s.setRatio(0.8, forSplit: firstID, for: target)
    s.setRatio(0.8, forSplit: secondID, for: target)

    s.equalizeSplit(for: target)

    XCTAssertEqual(
      s.split(containing: c, for: target)?.ratio(forSplit: secondID) ?? -1, 0.5, accuracy: 0.0001,
      "the group holding the focused tab is evened")
    XCTAssertEqual(
      s.split(containing: a, for: target)?.ratio(forSplit: firstID) ?? -1, 0.8, accuracy: 0.0001,
      "the off-screen group keeps the divider the user dragged")
  }

  func testExtractFromSplitMakesItSolo() throws {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    s.splitFocusedPane(for: target, orientation: .vertical)  // [a, b, c], c focused
    let c = s.activeTab(for: target)!.id
    let a = s.tabs(for: target).first!.id
    s.extractFromSplit(c, for: target)
    // `split(for:)` is the VISIBLE group and focus followed the extracted tab, so ask by membership.
    let remaining = try XCTUnwrap(s.split(containing: a, for: target))
    XCTAssertFalse(remaining.contains(c))
    XCTAssertEqual(remaining.tabIDs.count, 2)
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

  private func activeAgent(in sessions: TerminalSessions) -> AgentBackend? {
    guard case .terminal(let state)? = sessions.tabs(for: target).first?.content else { return nil }
    return state.activeAgentBackend
  }
}

/// The pane floor as it applies to a CONTENT pane (diff / file / changeset). These own no
/// `GhosttySurfaceView`, so `fits` used to exempt them outright (`guard let surface else { return
/// true }`) — which meant ⌘D on a diff pane in a 400pt split produced two ~198pt panes, in the one
/// place the floor exists *for*: a diff pane's own toolbar is ~190pt of the 300pt `minPaneWidth`
/// (issue #150 moved it out of the tab strip and into the pane's title bar).
///
/// The measurement now comes from `paneRects`, the rects the renderer last laid out and hands to the
/// store through a preference. Seeding it directly here is exactly what `PaneTreeView` does after
/// layout.
@MainActor
final class ContentPaneFloorTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    // A fresh recency list per test, so close-successor order never depends on (or pollutes) the
    // app-wide singleton the quick switcher uses.
    sessions.recency = SwitcherRecency()
    return sessions
  }

  /// A diff pane, focused, with `rect` reported as its laid-out size (nil ⇒ never measured).
  private func sessionsWithFocusedDiff(rect: CGRect?) -> (TerminalSessions, TerminalTab.ID) {
    let s = makeSessions()
    let tab = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    if let rect { s.paneRects[target.id] = [tab: rect] }
    return (s, tab)
  }

  private let tooNarrow = CGRect(x: 0, y: 0, width: 400, height: 900)
  private let roomy = CGRect(x: 0, y: 0, width: 1200, height: 900)

  func testSplittingATooNarrowDiffPaneIsRefused() {
    let (s, _) = sessionsWithFocusedDiff(rect: tooNarrow)
    s.splitFocusedPane(for: target, edge: .right)
    XCTAssertEqual(s.tabs(for: target).count, 1, "no second pane may be created")
    XCTAssertNil(s.split(for: target), "and no split layout")
  }

  func testSplittingAWideEnoughDiffPaneIsAllowed() {
    let (s, _) = sessionsWithFocusedDiff(rect: roomy)
    s.splitFocusedPane(for: target, edge: .right)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
  }

  /// The floor is per-axis: the same pane too narrow to split side-by-side is plenty tall to stack.
  func testTheOtherAxisIsStillAllowed() {
    let (s, _) = sessionsWithFocusedDiff(rect: tooNarrow)
    s.splitFocusedPane(for: target, edge: .bottom)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
  }

  /// Before first layout there is nothing to measure, so the split proceeds and the renderer's own
  /// points-based clamp sizes it — the pre-existing behaviour, deliberately preserved.
  func testAnUnmeasuredContentPaneStillSplits() {
    let (s, _) = sessionsWithFocusedDiff(rect: nil)
    s.splitFocusedPane(for: target, edge: .right)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
  }

  /// `splitTab` checks the fit BEFORE `select`, so a refused split must not have moved focus either.
  func testARefusedSplitTabLeavesSelectionAlone() {
    let s = makeSessions()
    s.addTab(for: target)
    let terminal = s.activeTab(for: target)!.id
    let diff = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    s.select(terminal, for: target)
    s.paneRects[target.id] = [diff: tooNarrow]

    s.splitTab(diff, on: .right, for: target)

    XCTAssertEqual(s.tabs(for: target).count, 2, "the refused split created nothing")
    XCTAssertEqual(
      s.activeTab(for: target)?.id, terminal, "and must not have stolen the selection")
  }
}

/// Auto-even for the in-workroom pane split (issue #126). Same intent gate as the workroom side:
/// `splitFocusedPane`, `closeTab` and `extractFromSplit` always change the pane count, while
/// `moveTabIntoSplit` consults the `addsAMember` predicate it already used for the pane floor.
///
/// `autoEvenSplits` is set directly, never through `Defaults` — a parallel worker wipes that domain
/// cross-process.
@MainActor
final class TerminalSplitAutoEvenTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions(space: CGRect = CGRect(x: 0, y: 0, width: 1800, height: 1000))
    -> TerminalSessions
  {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    // Roomy by default so evening is always honourable; the clamp case gets its own container.
    sessions.paneSpace[target.id] = space
    return sessions
  }

  // `splits(for:).first`, not `split(for:)`: this class builds exactly one group, but two of its
  // cases move focus OUT of it (an extract, and adding a solo tab), and `split(for:)` answers the
  // narrower "which group is on screen".
  private func rootRatio(_ s: TerminalSessions) -> CGFloat? {
    guard case .split(_, _, let ratio, _, _) = s.splits(for: target).first else { return nil }
    return ratio
  }

  private func rootSplitID(_ s: TerminalSessions) -> UUID? {
    guard case .split(let id, _, _, _, _) = s.splits(for: target).first else { return nil }
    return id
  }

  /// `a | (b / c)` — three panes, the shape where a naive 0.5 leaves `a` at half the width.
  private func threePanes(_ s: TerminalSessions) {
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .vertical)
  }

  /// `a | (b / c)`: the stacked pair is ONE column, so `a` keeps half the width. The skew matters —
  /// this shape sits at 0.5 with or without evening, so asserting 0.5 on a fresh tree would pass
  /// against code that never evens at all (measured: it did).
  func testAThirdPaneEvensTheSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)
    s.splitFocusedPane(for: target, orientation: .vertical)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.5, accuracy: 0.0001)
  }

  func testAThirdPaneOnTheSameAxisSplitsIntoThirds() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(
      rootRatio(s) ?? -1, 1.0 / 3.0, accuracy: 0.0001, "three columns in one chain are thirds")
  }

  /// The report that reshaped the rule (#126): split down, then split the bottom pane sideways. The
  /// top pane is in a different row and must not move.
  func testSplittingOneRowSidewaysLeavesTheOtherRowAlone() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .vertical)  // a / b, halves
    s.splitFocusedPane(for: target, orientation: .horizontal)  // a / (b | c)
    XCTAssertEqual(
      rootRatio(s) ?? -1, 0.5, accuracy: 0.0001,
      "the top row keeps its half of the height; only the bottom row divides")
    let panes = PaneTreeLayout.plan(
      s.splits(for: target).first!, in: CGRect(x: 0, y: 0, width: 1200, height: 900)
    ).panes
    let heights = Set(panes.values.map { Int($0.height) })
    XCTAssertEqual(heights, [449], "both rows are the same height")
  }

  func testASplitEvensAwayASkewedDivider() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)
    s.splitFocusedPane(for: target, orientation: .vertical)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.5, accuracy: 0.0001)
  }

  func testClosingAPaneEvensTheSurvivors() {
    let s = makeSessions()
    threePanes(s)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)  // or 0.5 would hold either way
    let closed = s.focusedTab(for: target)!.id
    s.closeTab(closed, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
    XCTAssertEqual(
      rootRatio(s) ?? -1, 0.5, accuracy: 0.0001,
      "the survivors must not keep the 1/3 budgeted for three panes")
  }

  func testExtractingAPaneEvensTheSurvivors() {
    let s = makeSessions()
    threePanes(s)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)  // or 0.5 would hold either way
    let extracted = s.focusedTab(for: target)!.id
    s.extractFromSplit(extracted, for: target)
    XCTAssertEqual(s.splits(for: target).first?.tabIDs.count, 2)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.5, accuracy: 0.0001)
  }

  func testARearrangeWithinTheSplitKeepsItsDividers() {
    // `moveTabIntoSplit` with a tab that is ALREADY a member changes no pane count — it just moves
    // one pane to another edge — so the dividers the user dragged must survive it.
    let s = makeSessions()
    threePanes(s)
    s.setRatio(0.7, forSplit: rootSplitID(s)!, for: target)
    let ids = s.splits(for: target).first!.tabIDs
    s.moveTabIntoSplit(ids[2], ontoEdge: .right, of: ids[1], for: target)
    XCTAssertEqual(
      rootRatio(s) ?? -1, 0.7, accuracy: 0.0001, "same panes, new edge — not an addition")
  }

  func testDraggingASoloTabInEvensTheSplit() {
    // The other half of `moveTabIntoSplit`: a tab from outside the split IS an addition.
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)
    let solo = s.addTab(for: target).id
    let member = s.splits(for: target).first!.tabIDs[0]
    s.moveTabIntoSplit(solo, ontoEdge: .bottom, of: member, for: target)
    XCTAssertEqual(s.splits(for: target).first?.tabIDs.count, 3)
    // The drop stacked the solo tab under the FIRST member. That subtree divides its own height,
    // so as a COLUMN it is still one of two — the outer divider returns to a half.
    XCTAssertEqual(rootRatio(s) ?? -1, 0.5, accuracy: 0.0001)
  }

  func testPrefOffKeepsEveryDivider() {
    let s = makeSessions()
    s.autoEvenSplits = { false }
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)
    s.splitFocusedPane(for: target, orientation: .vertical)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.8, accuracy: 0.0001, "the split left it alone")
    s.closeTab(s.focusedTab(for: target)!.id, for: target)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.8, accuracy: 0.0001, "and so did the close")
  }

  /// Evening must decline when the container cannot render the result evenly — and the path that
  /// actually REACHES that decision is a removal, not an insert. Asserting it through an insert was
  /// vacuous: the floor refuses the insert outright, so the ratio never moves for an entirely
  /// different reason and the test passes whether the honourability check exists or not.
  func testACrampedContainerKeepsTheDividersInstead() {
    let s = makeSessions(space: CGRect(x: 0, y: 0, width: 800, height: 900))
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .vertical)  // a | (b / c), all three admitted
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 3, "precondition: three panes exist")
    s.setRatio(0.62, forSplit: rootSplitID(s)!, for: target)

    // Close one of the stacked pair. The survivors are `a | b` — two columns of 800pt, which evening
    // would split 50/50 at 399 each, above the floor… so this one IS honourable and evens.
    let closed = s.focusedTab(for: target)!.id
    s.closeTab(closed, for: target)
    XCTAssertEqual(
      rootRatio(s) ?? -1, 0.5, accuracy: 0.0001,
      "800pt holds two 399pt columns, so the even-out is honoured")
  }

  /// The other half, where the container genuinely cannot honour it. Reaching it takes a window that
  /// SHRANK after the tree was built — the floor would refuse creating a third column in 800pt, but
  /// it cannot un-create one that was made when there was room. Four columns built roomy, then
  /// shrunk, then one closed: evening the three survivors wants thirds (≈266pt) against a 300pt
  /// floor, so the stored dividers must survive untouched.
  func testACrampedRemovalDeclinesToEven() {
    let s = makeSessions()  // roomy: 1800pt
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // four columns
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 4, "precondition: four columns")
    s.setRatio(0.62, forSplit: rootSplitID(s)!, for: target)

    s.paneSpace[target.id] = CGRect(x: 0, y: 0, width: 800, height: 900)  // the window shrank
    s.closeTab(s.focusedTab(for: target)!.id, for: target)

    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 3, "three columns survive")
    XCTAssertEqual(
      rootRatio(s) ?? -1, 0.62, accuracy: 0.0001,
      "thirds of 800pt would clamp against the 300pt floor, so the dividers stay as they are")
  }

  func testAnUnmeasuredContainerStillEvens() {
    // No layout pass yet (no `paneSpace` entry): nothing to judge, so even optimistically rather
    // than withhold the behaviour on the very first split of a session.
    let s = makeSessions()
    s.paneSpace[target.id] = nil
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)  // or 0.5 would hold either way
    s.splitFocusedPane(for: target, orientation: .vertical)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.5, accuracy: 0.0001)
  }

  /// The shape manual QA produced: two columns, each split vertically, then one pane closed. The
  /// left column collapses to a single full-height pane and the root ratio is still the 0.5 that
  /// budgeted two columns — so the survivor keeps half the width where three leaves want a third.
  func testClosingAPaneInATwoColumnGridEvensTheSurvivors() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // t1 | t2
    let ids = s.split(for: target)!.tabIDs
    s.focus(ids[0], for: target)
    s.splitFocusedPane(for: target, orientation: .vertical)  // (t1 / t4) | t2
    s.focus(ids[1], for: target)
    s.splitFocusedPane(for: target, orientation: .vertical)  // (t1 / t4) | (t2 / t3)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 4)
    s.setRatio(0.8, forSplit: rootSplitID(s)!, for: target)  // or 0.5 would hold either way

    let bottomLeft = s.split(for: target)!.tabIDs.first { $0 != ids[0] && $0 != ids[1] }!
    s.closeTab(bottomLeft, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 3)
    XCTAssertEqual(
      rootRatio(s) ?? -1, 0.5, accuracy: 0.0001,
      "still two columns — the left one just stopped being divided")
  }

  func testTheMenuActionStillEvensWithThePrefOff() {
    let s = makeSessions()
    s.autoEvenSplits = { false }
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    s.setRatio(0.9, forSplit: rootSplitID(s)!, for: target)
    s.equalizeSplit(for: target)
    XCTAssertEqual(rootRatio(s) ?? -1, 0.5, accuracy: 0.0001)
  }

  // MARK: Theme sweep (WORKROOM-3R)

  /// Forward guard: `applyThemeToAll` must never touch APP-GLOBAL ghostty state (the config
  /// rebuild + color-scheme push). That half moved to `ThemeService.applyActiveTheme`, which now
  /// runs it exactly once regardless of how many windows are registered — doing it here again,
  /// inside the per-window loop, is the N-windows-N-config-writes stall this signature change
  /// (dropping `force:`, adding `isDark:`) exists to prevent. Also exercises the content-tab
  /// `continue` branch (a diff-preview tab has no surface) mixed with a real terminal tab, so the
  /// sweep must not crash on the mix.
  func testApplyThemeToAllTouchesNoAppGlobalGhosttyState() throws {
    try XCTSkipUnless(
      GhosttyApp.shared.isReady, "libghostty must be up to observe its config pointer")
    let s = makeSessions()
    s.addTab(for: target)
    _ = s.openDiffPreview(
      DiffDescriptor(path: "A.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    XCTAssertEqual(s.tabs(for: target).count, 2, "one terminal tab + one content tab")

    let configBefore = GhosttyApp.shared.config
    s.applyThemeToAll(isDark: true)

    XCTAssertEqual(
      GhosttyApp.shared.config, configBefore,
      "applyThemeToAll rebuilt the app-global config — that now happens once in applyActiveTheme")
  }
}
