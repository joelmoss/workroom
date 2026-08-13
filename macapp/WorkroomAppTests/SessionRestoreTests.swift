import XCTest

@testable import Workroom

/// Rehydrating a target's panes from a saved session (issue #46).
///
/// Same factory seam as `TerminalSessionsTests`: constructing a `GhosttySurfaceView` is inert until it
/// enters a window, so nothing here spawns a shell.
@MainActor
final class SessionRestoreTests: XCTestCase {
  private let target = TerminalTarget(
    id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command)
    }
    return sessions
  }

  private func terminal(_ key: String, title: String, cwd: String? = nil) -> TabSession {
    TabSession(
      key: key, kind: TabSession.terminalKind,
      terminal: TerminalPayload(defaultTitle: title, cwd: cwd))
  }

  private func split(_ first: String, _ second: String) -> LayoutNode<String> {
    .split(
      orientation: LayoutNode<String>.vertical, ratio: 0.35, first: .leaf(first),
      second: .leaf(second))
  }

  // MARK: Restore reports what it created (issue #145)

  /// **REGRESSION.** Eligibility for a resume offer is "this pane came back from a restore", and
  /// that is answered by the list `restore` hands back — NOT by a `wasRestored` flag on the tab.
  ///
  /// A flag is state that outlives the moment it describes and has to be kept true through every
  /// future mutation path. Returning the identities at the one instant they are known means a ⌘T
  /// pane can never be mistaken for a restored one, because it was never in the list.
  func testRestoreReportsItsTerminalsAndAddTabDoesNot() {
    let sessions = makeSessions()
    let result = sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1", cwd: "/tmp"), terminal("b", title: "Terminal 2")]),
      for: target)

    XCTAssertEqual(result.terminals.count, 2)
    XCTAssertEqual(Set(result.terminals.map(\.tabID)), Set(sessions.tabs(for: target).map(\.id)))
    XCTAssertEqual(result.terminals.map(\.targetID), [target.id, target.id])

    let added = sessions.addTab(for: target)
    XCTAssertFalse(
      result.terminals.map(\.tabID).contains(added.id), "a ⌘T pane is not a restored pane")
  }

  /// The reported cwd is the one the pane actually opens in, already through `restoredCwd` — so a
  /// pane whose remembered directory is gone reports the fallback, not the dead path that would
  /// never match an agent's recorded cwd.
  func testReportedCwdIsTheResolvedOneNotTheDeadRememberedPath() {
    let sessions = makeSessions()
    let result = sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1", cwd: "/definitely/not/a/real/directory")]),
      for: target)

    XCTAssertEqual(result.terminals.first?.cwd, target.path)
  }

  /// Content tabs have no shell, so they are not terminals to resume into.
  func testContentTabsAreNotReportedAsTerminals() {
    let sessions = makeSessions()
    let result = sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [
          terminal("a", title: "Terminal 1"),
          TabSession(
            key: "f", kind: TabSession.fileKind,
            file: FilePayload(path: "README.md", isPreview: true, markdownPreview: false)),
        ]),
      for: target)

    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result.terminals.count, 1)
  }

  // MARK: Shape

  func testRestoresTabsInOrderWithTitles() {
    let sessions = makeSessions()
    let restored = sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [
          terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2"),
          terminal("c", title: "Terminal 3"),
        ], terminalCounter: 3),
      for: target)

    XCTAssertEqual(restored.count, 3)
    XCTAssertEqual(
      sessions.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 2", "Terminal 3"])
  }

  func testRestoresSplitAndFocusThroughTheKeyRemap() throws {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2")],
        split: split("a", "b"), focusedKey: "b"),
      for: target)

    let tabs = sessions.tabs(for: target)
    let live = try XCTUnwrap(sessions.split(for: target))
    XCTAssertEqual(live.tabIDs, tabs.map(\.id), "the split addresses the freshly minted ids")
    guard case .split(_, let orientation, let ratio, _, _) = live else {
      return XCTFail("expected a split")
    }
    XCTAssertEqual(orientation, .vertical)
    XCTAssertEqual(ratio, 0.35, accuracy: 0.0001)
    XCTAssertEqual(sessions.focusedTab(for: target)?.title, "Terminal 2")
  }

  /// Persisted keys are a join key inside one snapshot, never an identity: a tab id is unique across
  /// windows at runtime and OS-notification routing depends on that.
  func testRestoredTabsGetFreshUniqueIDs() {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2")]),
      for: target)

    let ids = sessions.tabs(for: target).map(\.id)
    XCTAssertEqual(Set(ids).count, 2)
    XCTAssertFalse(ids.map(\.uuidString).contains("a"))
  }

  func testRestoresContentTabsWithOverrides() throws {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [
          TabSession(
            key: "d", kind: TabSession.diffKind,
            diff: DiffPayload(
              path: "a/b.swift", change: ChangedFile.Change.modified.rawValue,
              source: DiffSourcePayload(.commit("abc")), isPreview: false,
              viewMode: DiffViewMode.sideBySide.rawValue)),
          TabSession(
            key: "f", kind: TabSession.fileKind,
            file: FilePayload(path: "README.md", isPreview: true, markdownPreview: false)),
          TabSession(
            key: "c", kind: TabSession.changesetKind,
            changeset: ChangesetPayload(
              commitID: "def", title: "Fix it", isPreview: false, selectedPath: "a/b.swift")),
        ]),
      for: target)

    let tabs = sessions.tabs(for: target)
    XCTAssertEqual(tabs.count, 3)
    guard case .diff(let diff) = tabs[0].content else { return XCTFail("expected a diff tab") }
    XCTAssertEqual(diff.path, "a/b.swift")
    XCTAssertEqual(diff.source, .commit("abc"))
    XCTAssertEqual(tabs[0].diffViewModeOverride, .sideBySide)

    guard case .file(let file) = tabs[1].content else { return XCTFail("expected a file tab") }
    XCTAssertTrue(file.isPreview)
    XCTAssertEqual(tabs[1].markdownPreviewOverride, false)

    guard case .changeset(let changeset) = tabs[2].content else {
      return XCTFail("expected a changeset tab")
    }
    XCTAssertEqual(changeset.commitID, "def")
    XCTAssertEqual(changeset.selectedPath, "a/b.swift")
  }

  /// An unknown kind is what a NEWER build writes; it costs that tab, not the target.
  func testUnknownTabKindIsSkippedAndSiblingsRestore() {
    let sessions = makeSessions()
    let restored = sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [
          terminal("a", title: "Terminal 1"), TabSession(key: "x", kind: "hologram"),
          terminal("b", title: "Terminal 2"),
        ]),
      for: target)
    XCTAssertEqual(restored.count, 2)
    XCTAssertEqual(sessions.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 2"])
  }

  // MARK: Counter, cwd, focus

  /// Without the counter, the next ⌘T after restoring "Terminal 3" would be "Terminal 1" again.
  func testCounterContinuesAfterRestore() {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id, tabs: [terminal("a", title: "Terminal 7")], terminalCounter: 7),
      for: target)
    let added = sessions.addTab(for: target)
    XCTAssertEqual(added.title, "Terminal 8")
  }

  /// libghostty cannot spawn into a directory that no longer exists, so a dead cwd must fall back.
  func testRestoredCwdFallsBackWhenTheDirectoryIsGone() {
    XCTAssertEqual(
      TerminalSessions.restoredCwd("/definitely/not/a/real/directory", fallback: "/tmp"), "/tmp")
    XCTAssertEqual(TerminalSessions.restoredCwd(nil, fallback: "/tmp"), "/tmp")
    XCTAssertEqual(TerminalSessions.restoredCwd("", fallback: "/tmp"), "/tmp")
    XCTAssertEqual(TerminalSessions.restoredCwd("/tmp", fallback: "/var"), "/tmp")
    // A file is not a directory.
    XCTAssertEqual(TerminalSessions.restoredCwd("/etc/hosts", fallback: "/tmp"), "/tmp")
  }

  /// A restore is not a navigation — seeding back/forward with it would record a place the user never
  /// went.
  func testRestoreDoesNotFireTheFocusSeam() {
    let sessions = makeSessions()
    var fired = 0
    sessions.onFocusChange = { _, _ in fired += 1 }
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2")],
        focusedKey: "b"),
      for: target)
    XCTAssertEqual(fired, 0)
    XCTAssertEqual(sessions.focusedTab(for: target)?.title, "Terminal 2")
  }

  // MARK: Guards

  /// A restore must never race or duplicate a live session.
  func testRestoreIsANoOpWhenTheTargetAlreadyHasTabs() {
    let sessions = makeSessions()
    sessions.addTab(for: target)
    let restored = sessions.restore(
      TargetSession(targetID: target.id, tabs: [terminal("a", title: "Terminal 99")]),
      for: target)
    XCTAssertEqual(restored.count, 0)
    XCTAssertEqual(sessions.tabs(for: target).map(\.title), ["Terminal 1"])
  }

  func testEmptySessionRestoresNothing() {
    let sessions = makeSessions()
    XCTAssertEqual(
      sessions.restore(TargetSession(targetID: target.id, tabs: []), for: target).count, 0)
    XCTAssertTrue(sessions.tabs(for: target).isEmpty)
  }

  /// Restoring builds tab models only. A surface creates its PTY when it enters a window, so a
  /// restored session costs views, not shells — which is what makes eager restore affordable.
  func testRestoreSpawnsNoSurfaces() {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2")]),
      for: target)
    for tab in sessions.tabs(for: target) {
      XCTAssertTrue(
        tab.surface?.canSpawnSurface == true, "no restored terminal may have spawned yet")
    }
  }

  // MARK: Round trip

  /// Capture → restore → capture must be a fixed point, or a layout would drift a little on every
  /// relaunch.
  func testCaptureRestoreCaptureIsStable() throws {
    let first = makeSessions()
    first.addTab(for: target)
    first.splitFocusedPane(for: target, orientation: .vertical)
    first.addTab(for: target)

    let captured = try XCTUnwrap(capture(first))
    let second = makeSessions()
    second.restore(captured, for: target)
    let recaptured = try XCTUnwrap(capture(second))

    XCTAssertEqual(captured.tabs.map(\.kind), recaptured.tabs.map(\.kind))
    XCTAssertEqual(
      captured.tabs.compactMap { $0.terminal?.defaultTitle },
      recaptured.tabs.compactMap { $0.terminal?.defaultTitle })
    XCTAssertEqual(captured.split?.leaves.count, recaptured.split?.leaves.count)
    XCTAssertEqual(captured.terminalCounter, recaptured.terminalCounter)
    // Keys are re-minted, so compare the POSITION of the focused tab rather than its key.
    XCTAssertEqual(
      captured.tabs.firstIndex { $0.key == captured.focusedKey },
      recaptured.tabs.firstIndex { $0.key == recaptured.focusedKey })
  }

  private func capture(_ sessions: TerminalSessions) -> TargetSession? {
    guard let captured = sessions.sessionCapture(forTargetID: target.id) else { return nil }
    var keys: [TerminalTab.ID: String] = [:]
    var tabs: [TabSession] = []
    for tab in captured.tabs {
      let key = tab.id.uuidString
      guard let session = TabSession(key: key, tab: tab) else { continue }
      keys[tab.id] = key
      tabs.append(session)
    }
    guard !tabs.isEmpty else { return nil }
    return TargetSession(
      targetID: target.id, tabs: tabs,
      split: captured.split.flatMap { LayoutNode<String>.capture($0) { keys[$0] } },
      focusedKey: captured.focused.flatMap { keys[$0] },
      terminalCounter: captured.counter)
  }
}
