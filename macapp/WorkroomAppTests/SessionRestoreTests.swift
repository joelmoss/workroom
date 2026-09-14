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
    sessions.recency = SwitcherRecency()  // never write this suite's tabs into the shared MRU
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

  // MARK: Shape

  /// A pane whose remembered directory is gone opens in the target's own path instead, through
  /// `restoredCwd` — not the dead path, which would just fail on shell startup.
  func testRestoredCwdFallsBackWhenTheRememberedDirectoryIsGone() {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1", cwd: "/definitely/not/a/real/directory")]),
      for: target)

    XCTAssertEqual(sessions.tabs(for: target).first?.surface?.workingDirectory, target.path)
  }

  /// A restore is not a visit: it materialises saved panes across EVERY target at launch, so seeding
  /// the app-wide MRU with them would put a pane the user never touched at the head of ⌃Tab and of
  /// the close-successor (issue #160).
  func testRestoreDoesNotSeedRecency() {
    let sessions = makeSessions()
    sessions.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2")],
        focusedKey: "b"),
      for: target)

    XCTAssertEqual(sessions.activeTab(for: target)?.title, "Terminal 2", "saved focus is restored")
    XCTAssertTrue(sessions.recency.panes.ids.isEmpty, "…but it is not a recency touch")
  }

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
        splits: [split("a", "b")], focusedKey: "b"),
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
    // `splits`, not `split`: the legacy field is decode-only and `TargetSession.init` always nils
    // it, so comparing it here was a vacuous nil == nil that proved no round trip at all.
    XCTAssertEqual(
      captured.splits.map { $0.leaves.count }, recaptured.splits.map { $0.leaves.count })
    XCTAssertEqual(captured.terminalCounter, recaptured.terminalCounter)
    // Keys are re-minted, so compare the POSITION of the focused tab rather than its key.
    XCTAssertEqual(
      captured.tabs.firstIndex { $0.key == captured.focusedKey },
      recaptured.tabs.firstIndex { $0.key == recaptured.focusedKey })
  }

  /// The whole point of the many-groups change, through the PERSISTENCE path: a file holding two
  /// disjoint groups must come back as two disjoint groups, with every leaf remapped to a freshly
  /// minted tab id. Every other restore test builds ONE group, so nothing else covers
  /// `restore`'s `session.splits.compactMap { saved.materialize { idsByKey[$0] } }` with >1 element.
  func testRestoresTwoDisjointSplitGroups() throws {
    let s = makeSessions()
    s.restore(
      TargetSession(
        targetID: target.id,
        tabs: [
          terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2"),
          terminal("c", title: "Terminal 3"), terminal("d", title: "Terminal 4"),
        ],
        splits: [split("a", "b"), split("c", "d")], focusedKey: "c"),
      for: target)

    let tabs = s.tabs(for: target)
    XCTAssertEqual(tabs.count, 4)
    XCTAssertEqual(s.splits(for: target).count, 2, "both groups survive the round trip")
    // Leaves are remapped to the NEW ids, in strip order, and the groups stay disjoint.
    let ids = tabs.map(\.id)
    XCTAssertEqual(s.split(containing: ids[0], for: target)?.tabIDs, [ids[0], ids[1]])
    XCTAssertEqual(s.split(containing: ids[2], for: target)?.tabIDs, [ids[2], ids[3]])
    XCTAssertTrue(
      Set(s.splits(for: target)[0].tabIDs).isDisjoint(with: Set(s.splits(for: target)[1].tabIDs)))
    // `focusedKey` picked group 2, so only that one is on screen; group 1 persists off screen.
    XCTAssertEqual(s.split(for: target)?.tabIDs, [ids[2], ids[3]])
  }

  /// A saved group naming a DETACHED tab must come back without it. `splitsByTarget`'s invariant is
  /// that a detached tab is never a member: rendering a group containing one puts its surface in the
  /// origin pane tree as well as its own window, re-homing the libghostty view and blanking the
  /// detached window. `sanitized()` cannot catch the shape — the tab is live, so the group looks
  /// valid — which is why `restore` resolves detached ids to nothing.
  ///
  /// The group here has exactly two members and one is detached, so it correctly restores as NO
  /// group: `materialize` drops a tree that falls below two leaves.
  func testARestoredGroupNeverContainsADetachedTab() throws {
    let s = makeSessions()
    var detached = terminal("b", title: "Terminal 2")
    detached.detachedFrame = NSStringFromRect(NSRect(x: 0, y: 0, width: 400, height: 300))
    s.restore(
      TargetSession(
        targetID: target.id, tabs: [terminal("a", title: "Terminal 1"), detached],
        splits: [split("a", "b")], focusedKey: "a"),
      for: target)

    let docked = try XCTUnwrap(s.tabs(for: target).first).id
    XCTAssertEqual(s.allTabs(for: target).count, 2, "both tabs come back")
    XCTAssertTrue(
      s.splits(for: target).isEmpty,
      "the group held one detached member, so only one leaf resolves — that is not a group")
    XCTAssertNil(s.split(containing: docked, for: target))
    XCTAssertEqual(s.visibleTabIDs(for: target).first, docked)
  }

  /// The same rule with a group big enough to SURVIVE the exclusion: three saved members, one
  /// detached, so two resolve and the group comes back holding exactly those two.
  func testARestoredGroupKeepsItsDockedMembersWithoutTheDetachedOne() throws {
    let s = makeSessions()
    var detached = terminal("c", title: "Terminal 3")
    detached.detachedFrame = NSStringFromRect(NSRect(x: 0, y: 0, width: 400, height: 300))
    s.restore(
      TargetSession(
        targetID: target.id,
        tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2"), detached],
        splits: [
          .split(
            orientation: LayoutNode<String>.horizontal, ratio: 0.5, first: .leaf("a"),
            second: .split(
              orientation: LayoutNode<String>.vertical, ratio: 0.5, first: .leaf("b"),
              second: .leaf("c")))
        ],
        focusedKey: "a"),
      for: target)

    let docked = s.tabs(for: target).map(\.id)
    XCTAssertEqual(docked.count, 2, "the detached tab is not in the strip")
    let group = try XCTUnwrap(s.split(containing: docked[0], for: target))
    XCTAssertEqual(
      Set(group.tabIDs), Set(docked), "the group holds the docked members, and only them")
    XCTAssertEqual(s.splits(for: target).count, 1)
  }

  /// Restoring must never land focus on a DETACHED pane: focusing one renders it back in this window
  /// and re-homes its libghostty view out of its own window, which then goes blank. The ordinary flow
  /// that reached it \u2014 detach your only pane, quit, relaunch \u2014 persists no `focusedKey` at all
  /// (`closeSuccessor` returns nil for a sole tab), so the fallback had to pick, and `order`
  /// deliberately includes detached panes.
  func testRestoreNeverFocusesADetachedPane() throws {
    let s = makeSessions()
    var detached = terminal("a", title: "Terminal 1")
    detached.detachedFrame = NSStringFromRect(NSRect(x: 0, y: 0, width: 400, height: 300))
    s.restore(
      TargetSession(
        targetID: target.id, tabs: [detached, terminal("b", title: "Terminal 2")],
        focusedKey: nil),
      for: target)

    let detachedID = try XCTUnwrap(s.allTabs(for: target).first).id
    let docked = try XCTUnwrap(s.tabs(for: target).first).id
    XCTAssertNotEqual(detachedID, docked, "the detached pane is not in the strip")
    XCTAssertEqual(s.focusedTab(for: target)?.id, docked, "focus landed on the docked pane")
    XCTAssertFalse(s.visibleTabIDs(for: target).isEmpty)
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
      splits: captured.splits.compactMap { LayoutNode<String>.capture($0) { keys[$0] } },
      focusedKey: captured.focused.flatMap { keys[$0] },
      terminalCounter: captured.counter)
  }
}
