import Defaults
import WorkroomSessionProtocol
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

  /// Recovery's gate when every target may reattach.
  private static let every: (TerminalTarget.ID) -> Bool = { _ in true }

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

  func testRecoveryRestoresAgentUsageWithoutAnOSCTitle() async {
    for command in ["claude", "codex", "zsh", "nvim", ""] {
      let sessions = makeSessions()
      sessions.makeView = { _, cwd, _ in
        GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
      }
      let sessionID = UUID()
      sessions.restore(
        TargetSession(
          targetID: target.id,
          tabs: [terminal("a", title: "Terminal 1")]), for: target)
      var tab = sessions.tabs(for: target).first!
      guard case .terminal(var state) = tab.content else { return XCTFail("expected terminal") }
      state.sessionID = sessionID
      tab.content = .terminal(state)
      sessions.replace(tab, for: target)
      let descriptor = SessionDescriptor(
        identifier: SessionIdentifier(sessionID), shellProcessID: 123, ttyDevice: 0,
        workingDirectory: "/tmp", isAttached: false,
        metadata: [SessionEnvironmentEntry(key: "command", value: command)])

      await sessions.materializeLivePersistentSessions(reattaches: Self.every) { [] }
      XCTAssertTrue(sessions.activeAgentBackends.isEmpty, "lost sessions must not restore usage")
      await sessions.materializeLivePersistentSessions(reattaches: Self.every) { [descriptor] }
      let expected: Set<AgentBackend> =
        command == "claude" ? [.claude] : command == "codex" ? [.codex] : []
      XCTAssertEqual(sessions.activeAgentBackends, expected, command)
      XCTAssertFalse(sessions.isRunning(forTargetID: target.id), "recovery must not imply activity")
      tab.surface?.handleCommandFinished(rawExitCode: 0)
      XCTAssertTrue(sessions.activeAgentBackends.isEmpty, "agent exit must clear recovered usage")

      // A provider title may arrive before discovery completes; keep it and recover recognition.
      await sessions.materializeLivePersistentSessions(reattaches: Self.every) {
        tab.surface?.onTitleChange?("✻ Planning…")
        return [descriptor]
      }
      XCTAssertEqual(sessions.activeAgentBackends, expected)
      XCTAssertEqual(sessions.tabs(for: target).first?.title, "✻ Planning…")
      tab.surface?.handleCommandFinished(rawExitCode: 0)

      // A finish during discovery invalidates the captured command, even without a live title.
      await sessions.materializeLivePersistentSessions(reattaches: Self.every) {
        tab.surface?.handleCommandFinished(rawExitCode: 0)
        return [descriptor]
      }
      XCTAssertTrue(sessions.activeAgentBackends.isEmpty, "must not resurrect an exited agent")

      // Reassigning this same pane during discovery must not apply another session's metadata.
      var reassigned = sessions.tabs(for: target).first!
      guard case .terminal(var reassignedState) = reassigned.content else { return }
      reassignedState.sessionID = UUID()
      reassigned.content = .terminal(reassignedState)
      sessions.replace(reassigned, for: target)
      await sessions.materializeLivePersistentSessions(reattaches: Self.every) {
        reassignedState.sessionID = sessionID
        reassigned.content = .terminal(reassignedState)
        sessions.replace(reassigned, for: target)
        return [descriptor]
      }
      XCTAssertTrue(sessions.activeAgentBackends.isEmpty, "must not hydrate a reassigned pane")
    }
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

  // MARK: Gating (#253)

  /// A remote workroom this app can't reach waits (#253): nothing of its saved session is built,
  /// since its terminals would be shells on this Mac, but the session is written back with every
  /// save. Once the workroom is reachable, its first pane restores the whole session rather than
  /// opening a fresh shell.
  func testAnUnreachableRemoteWorkroomsSessionWaitsUntilItIsReachable() throws {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    let hostID = UUID()
    func project(_ state: String?) -> Project {
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
            host: HostDescriptor(state: state, provisioner: RemoteWorkrooms.provisioner, id: hostID)
          )
        ])
    }
    // Still being created, so not reachable yet.
    store.projects = [project("creating")]
    let id = TerminalTarget.workroomID(project: "/proj", name: "r")
    let session = TargetSession(
      targetID: id,
      tabs: [
        terminal("a", title: "Terminal 1"),
        TabSession(
          key: "f", kind: TabSession.fileKind,
          file: FilePayload(path: "README.md", isPreview: false, markdownPreview: false)),
      ])
    store.pendingSessionRestore = WindowSession(
      windowKey: UUID().uuidString, targets: [session], expandedTargets: [id])

    store.restorePersistedSessionIfPending(in: store.projects)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 0, "an unreachable pane was built")
    XCTAssertEqual(store.captureWindowSession().targets, [session], "its session was not kept")
    XCTAssertEqual(store.captureWindowSession().expandedTargets, [id], "its expansion was lost")
    store.selectedTargetID = .workroom(project: "/proj", name: "r")

    store.projects = [project(nil)]
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    store.ensureInitialTerminal(for: target)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 2, "the session was not restored")
    XCTAssertEqual(
      store.terminals.tabs(for: target).first?.surface?.workingDirectory, NSHomeDirectory(),
      "its terminal is not a pane on the host")
    XCTAssertTrue(store.deferredTargetSessions.isEmpty)
    XCTAssertTrue(store.selectionHasTabs, "the inspector was not told the workroom has tabs")
  }

  /// A remote workroom whose host keeps its layout (#255, D4) waits for the host's copy instead of
  /// restoring its own at once or opening a fresh shell; a host that cannot answer in time gets this
  /// Mac's own copy, whole. A second window showing the same workroom does not ask (D10).
  func testARemoteWorkroomWaitsForItsHostsLayoutThenFallsBackToItsOwn() async throws {
    let workroom = Workroom(
      name: "h", path: "/home/workroom/h", vcsName: "workroom/h", warnings: [],
      host: HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: UUID()))
    func store() -> AppStore {
      let store = AppStore()
      store.terminals.makeView = { _, cwd, _ in
        GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
      }
      store.projects = [Project(path: "/proj", vcs: "git", workrooms: [workroom])]
      return store
    }
    let id = TerminalTarget.workroomID(project: "/proj", name: "h")
    let saved = TargetSession(
      targetID: id, tabs: [terminal("a", title: "Terminal 1"), terminal("b", title: "Terminal 2")])

    let first = store()
    first.pendingSessionRestore = WindowSession(windowKey: UUID().uuidString, targets: [saved])
    first.restorePersistedSessionIfPending(in: first.projects)
    XCTAssertEqual(
      first.terminals.tabCount(forTargetID: id), 0, "restored before the host answered")
    XCTAssertTrue(first.hostLayouts.fetching.contains(id))
    let target = try XCTUnwrap(first.terminalTarget(forID: id))
    first.ensureInitialTerminal(for: target)
    XCTAssertEqual(
      first.terminals.tabCount(forTargetID: id), 0, "a fresh shell opened while waiting")
    // A tab asked for meanwhile is held, so it cannot stop the restore (and have the next save
    // write it alone over the host's layout); it opens after it.
    first.openFilePreview(path: "/home/workroom/h/README.md", for: target)
    XCTAssertEqual(first.terminals.tabCount(forTargetID: id), 0, "a tab opened while waiting")
    // The pane says it is waiting, and a new terminal asked for three times meanwhile is one.
    XCTAssertTrue(first.waitingForHostLayout.contains(id))
    for _ in 0..<3 { first.newTerminal(in: target) }
    XCTAssertEqual(first.terminals.tabCount(forTargetID: id), 0, "a terminal opened while waiting")

    // A second window showing the workroom meanwhile restores from this Mac alone.
    let second = store()
    XCTAssertFalse(second.fetchHostLayoutIfNeeded(for: target), "two windows asked one host")

    // No host is reachable here, so the fetch gives up and this Mac's copy comes back whole.
    let restored = expectation(description: "restored")
    func poll() {
      if first.terminals.tabCount(forTargetID: id) > 0 { return restored.fulfill() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
    await fulfillment(of: [restored], timeout: AppStore.hostLayoutTimeout + 3)
    XCTAssertEqual(
      first.terminals.tabCount(forTargetID: id), 4, "the copy, then the held file and one terminal")
    XCTAssertFalse(first.waitingForHostLayout.contains(id))
    XCTAssertTrue(first.deferredTargetSessions.isEmpty)
    XCTAssertTrue(first.hostLayouts.fetched.contains(id))
    XCTAssertFalse(first.fetchHostLayoutIfNeeded(for: target), "asked twice in one launch")

    // The host never answered, so its layout was never read: a change goes up only at the
    // revision this Mac last saw, and one that does not get there is not marked stale, which would
    // make it win over the host's at the next open.
    XCTAssertTrue(first.hostLayouts.unanswered.contains(id))
    XCTAssertFalse(first.hostLayouts.readOnly.contains(id))
    let writes = first.writeHostLayouts()
    XCTAssertEqual(writes.count, 1, "the held tabs are a change")
    for write in writes { await write.value }
    XCTAssertFalse(first.hostLayouts.stale.contains(id))
    XCTAssertNil(first.hostLayouts.revisions[id])
    XCTAssertNil(first.captureWindowSession().targets.first?.hostLayoutStale)
    // It never reached the host, so the next save tries again.
    let again = first.writeHostLayouts()
    XCTAssertEqual(again.count, 1, "a write that never reached the host is not tried again")
    for write in again { await write.value }
  }

  /// What a window writes to a remote workroom's host after a save (#255): nothing before the host
  /// has answered, nothing unchanged, an empty layout only over one the host had (D11), and a
  /// write that cannot reach the host leaves this Mac's copy stale, to win at the next open.
  func testWhatAWindowWritesToItsHosts() async throws {
    let workroomID = UUID()
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/workroom/w", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: workroomID))
        ])
    ]
    let id = TerminalTarget.workroomID(project: "/proj", name: "w")
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroomID, targetID: id, by: store))

    // Not answered yet: nothing is written, whatever the window shows.
    store.terminals.restore(
      TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    XCTAssertTrue(store.writeHostLayouts().isEmpty)

    // Answered, and the host already has exactly this: nothing is written.
    store.hostLayouts.fetched.insert(id)
    let current = try XCTUnwrap(store.captureWindowSession().targets.first)
    store.hostLayouts.written[id] = try HostLayout.encode(current, key: workroomID.uuidString)
    XCTAssertTrue(store.writeHostLayouts().isEmpty)

    // Changed: written, and with no host to reach, left stale.
    store.hostLayouts.written[id] = "something older"
    store.hostLayouts.revisions[id] = 3
    let writes = store.writeHostLayouts()
    XCTAssertEqual(writes.count, 1)
    for write in writes { await write.value }
    XCTAssertTrue(store.hostLayouts.stale.contains(id))
    XCTAssertEqual(store.hostLayouts.revisions[id], 3)
    XCTAssertEqual(store.captureWindowSession().targets.first?.hostLayoutStale, true)

    // No tabs, and the host never had a layout: not "closed", nothing to write.
    for tab in store.terminals.allTabs(for: target) {
      store.terminals.closeTab(tab.id, for: target)
    }
    XCTAssertEqual(store.terminals.tabCount(forTargetID: id), 0)
    store.hostLayouts.written[id] = nil
    XCTAssertTrue(store.writeHostLayouts().isEmpty)
    // No tabs over a layout the host had: the empty layout goes up.
    store.hostLayouts.written[id] = "a layout with tabs"
    let empty = store.writeHostLayouts()
    XCTAssertEqual(empty.count, 1)
    for write in empty { await write.value }

    // At quit, a write already in flight, which starts nothing new, is waited on for the budget
    // and then marked stale, so the session written next keeps this Mac's copy as the newer (D14).
    store.hostLayouts.stale.remove(id)
    let inFlight = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }
    store.hostLayouts.writing[id] = inFlight
    await AppStore.flushHostLayouts(budget: 0.2, stores: [store])
    XCTAssertTrue(store.hostLayouts.stale.contains(id))
    inFlight.cancel()
    store.hostLayouts.writing[id] = nil

    // One that finished, with a newer change behind it that the budget ran out before sending, is
    // marked stale too: its revision is the host's, so unmarked it would read as already there.
    store.hostLayouts.stale.remove(id)
    store.hostLayouts.written[id] = "the snapshot that just landed"
    store.hostLayouts.writing[id] = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 50_000_000)
      store.hostLayouts.writing[id] = nil
    }
    let elsewhere = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }
    store.hostLayouts.writing["another workroom"] = elsewhere
    await AppStore.flushHostLayouts(budget: 0.2, stores: [store])
    XCTAssertNil(store.hostLayouts.writing[id])
    XCTAssertTrue(store.hostLayouts.stale.contains(id))
    elsewhere.cancel()
  }

  /// A copy restored because its host did not answer is what the host had, as far as this Mac
  /// knows, so it is not written back until something changes, although the restore re-minted
  /// every tab's key.
  func testAnUnansweredWorkroomsUnchangedCopyIsNotWrittenBack() async throws {
    let workroom = Workroom(
      name: "u", path: "/home/workroom/u", vcsName: "workroom/u", warnings: [],
      host: HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: UUID()))
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [Project(path: "/proj", vcs: "git", workrooms: [workroom])]
    let id = TerminalTarget.workroomID(project: "/proj", name: "u")
    var saved = TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")])
    saved.hostRevision = 4
    store.pendingSessionRestore = WindowSession(windowKey: UUID().uuidString, targets: [saved])
    store.restorePersistedSessionIfPending(in: store.projects)
    XCTAssertTrue(store.hostLayouts.fetching.contains(id))
    let restored = expectation(description: "restored")
    func poll() {
      if store.terminals.tabCount(forTargetID: id) > 0 { return restored.fulfill() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
    await fulfillment(of: [restored], timeout: AppStore.hostLayoutTimeout + 3)
    XCTAssertTrue(store.hostLayouts.unanswered.contains(id))
    XCTAssertFalse(store.hostLayouts.readOnly.contains(id), "restored, not skipped")
    XCTAssertNotNil(store.hostLayouts.written[id])
    XCTAssertEqual(store.hostLayouts.revisions[id], 4)
    XCTAssertTrue(store.writeHostLayouts().isEmpty, "an unchanged copy written back")
  }

  /// A stale copy whose host did not answer stays marked stale, to win at the next open where the
  /// host's layout is read first, but meanwhile it too writes only once, at the revision this Mac
  /// last saw: the host's layout was not read, and could be a newer build's.
  func testAStaleCopyWhoseHostDidNotAnswerNeverRetriesOverIt() async throws {
    final class MovedHost: HostLayoutStore, @unchecked Sendable {
      var puts = 0
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 9, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts += 1
        guard expected == 9 else { throw AgentLayoutError.stale(revision: 9) }
        return 10
      }
    }
    let workroom = Workroom(
      name: "s", path: "/home/workroom/s", vcsName: "workroom/s", warnings: [],
      host: HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: UUID()))
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [Project(path: "/proj", vcs: "git", workrooms: [workroom])]
    let id = TerminalTarget.workroomID(project: "/proj", name: "s")
    var saved = TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")])
    saved.hostRevision = 4
    saved.hostLayoutStale = true
    store.pendingSessionRestore = WindowSession(windowKey: UUID().uuidString, targets: [saved])
    store.restorePersistedSessionIfPending(in: store.projects)
    let restored = expectation(description: "restored")
    func poll() {
      if store.terminals.tabCount(forTargetID: id) > 0 { return restored.fulfill() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
    await fulfillment(of: [restored], timeout: AppStore.hostLayoutTimeout + 3)
    XCTAssertTrue(store.hostLayouts.unanswered.contains(id))
    XCTAssertTrue(store.hostLayouts.stale.contains(id))

    let host = MovedHost()
    let saved2 = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { _ in host }
    defer { AppStore.hostLayoutStore = saved2 }
    for write in store.writeHostLayouts() { await write.value }
    XCTAssertEqual(host.puts, 1, "retried past the refusal")
    XCTAssertTrue(store.hostLayouts.stale.contains(id), "no longer wins at the next open")
  }

  /// A workroom whose host never answered this launch writes at the revision this Mac last saw,
  /// once: a host that has moved on refuses it, and that refusal is final, not retried at the
  /// host's revision over a layout this Mac never read, and not marked stale (review D1).
  func testAnUnansweredWorkroomNeverWritesOverALayoutItNeverRead() async throws {
    final class MovedHost: HostLayoutStore, @unchecked Sendable {
      var puts = 0
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 5, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts += 1
        guard expected == 5 else { throw AgentLayoutError.stale(revision: 5) }
        return 6
      }
    }
    let host = MovedHost()
    let saved = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { _ in host }
    defer { AppStore.hostLayoutStore = saved }
    let workroomID = UUID()
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/workroom/w", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: workroomID))
        ])
    ]
    let id = TerminalTarget.workroomID(project: "/proj", name: "w")
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroomID, targetID: id, by: store))
    store.terminals.restore(
      TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    store.hostLayouts.fetched.insert(id)
    store.hostLayouts.unanswered.insert(id)
    store.hostLayouts.revisions[id] = 3
    store.hostLayouts.written[id] = "what this Mac last saw"

    for write in store.writeHostLayouts() { await write.value }
    XCTAssertEqual(host.puts, 1, "retried past the refusal")
    XCTAssertFalse(store.hostLayouts.stale.contains(id))
    XCTAssertEqual(store.hostLayouts.revisions[id], 3)
    XCTAssertTrue(store.writeHostLayouts().isEmpty, "the refused layout sent again unchanged")
  }

  /// A reload that gives a remote workroom another host while its first host is asked drops that
  /// answer: nothing is restored through it, and the new host is asked at once, with what was
  /// opened meanwhile held for its answer.
  func testAnAnswerFromAHostTheWorkroomNoLongerHasIsDropped() async throws {
    final class OneLayout: HostLayoutStore, @unchecked Sendable {
      let blob: String
      let delay: UInt64
      init(_ title: String, delay: UInt64 = 0) throws {
        blob = try HostLayout.encode(
          TargetSession(
            targetID: "x",
            tabs: [
              TabSession(
                key: "k", kind: TabSession.terminalKind,
                terminal: TerminalPayload(defaultTitle: title))
            ]),
          key: "x")
        self.delay = delay
      }
      func get(_ key: String) async throws -> AgentLayout {
        try await Task.sleep(nanoseconds: delay)
        return AgentLayout(revision: 3, blob: blob)
      }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        expected + 1
      }
    }
    let first = UUID()
    let second = UUID()
    let stores: [UUID: OneLayout] = [
      first: try OneLayout("from the first host", delay: 300_000_000),
      second: try OneLayout("from the second host"),
    ]
    let saved = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { host in
      guard case .remote(let id) = host, let store = stores[id] else {
        throw RepositoryRoutingError.unavailable(host)
      }
      return store
    }
    defer { AppStore.hostLayoutStore = saved }
    let workroomID = UUID()
    func project(host: UUID) -> Project {
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "m", path: "/home/workroom/m", vcsName: "workroom/m", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: host, workroomID: workroomID))
        ])
    }
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [project(host: first)]
    let id = TerminalTarget.workroomID(project: "/proj", name: "m")
    store.pendingSessionRestore = WindowSession(
      windowKey: UUID().uuidString,
      targets: [TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")])])
    store.restorePersistedSessionIfPending(in: store.projects)
    XCTAssertTrue(store.hostLayouts.fetching.contains(id))
    store.newTerminal(in: try XCTUnwrap(store.terminalTarget(forID: id)))
    store.projects = [project(host: second)]

    let restored = expectation(description: "restored")
    func poll() {
      if store.terminals.tabCount(forTargetID: id) > 0 { return restored.fulfill() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
    await fulfillment(of: [restored], timeout: AppStore.hostLayoutTimeout + 3)
    let titles = store.captureWindowSession().targets.first { $0.targetID == id }?.tabs
      .compactMap { $0.terminal?.defaultTitle }
    XCTAssertEqual(titles?.first, "from the second host", "restored through the old host")
    XCTAssertEqual(titles?.count, 2, "the terminal asked for meanwhile was lost")
    XCTAssertFalse(store.waitingForHostLayout.contains(id))
    // And it opened on the workroom's host as it is now, not the one it was asked for under.
    let held = try XCTUnwrap(
      store.captureWindowSession().targets.first { $0.targetID == id }?.tabs.last?.terminal?
        .sessionID.flatMap(UUID.init(uuidString:)))
    XCTAssertEqual(store.terminals.sessionService.remoteHost(of: held), .remote(second))
  }

  /// A workroom a reload moves to another host after its layout was read writes nothing over the
  /// new host's layout: what this window knew was the old host's, so the new host is written once,
  /// at revision 0, and a layout there refuses it.
  func testAWorkroomMovedToAnotherHostNeverWritesOverItsLayout() async throws {
    final class FullHost: HostLayoutStore, @unchecked Sendable {
      var puts: [UInt64] = []
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 9, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts.append(expected)
        guard expected == 9 else { throw AgentLayoutError.stale(revision: 9) }
        return 10
      }
    }
    let host = FullHost()
    let saved = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { _ in host }
    defer { AppStore.hostLayoutStore = saved }
    let workroomID = UUID()
    let first = UUID()
    func project(host: UUID) -> Project {
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "v", path: "/home/workroom/v", vcsName: "workroom/v", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: host, workroomID: workroomID))
        ])
    }
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [project(host: first)]
    let id = TerminalTarget.workroomID(project: "/proj", name: "v")
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroomID, targetID: id, by: store))
    store.terminals.restore(
      TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    store.hostLayouts.fetched.insert(id)
    store.hostLayouts.hosts[id] = (first, workroomID)
    store.hostLayouts.revisions[id] = 3
    store.hostLayouts.written[id] = "the first host's layout"

    store.projects = [project(host: UUID())]
    for write in store.writeHostLayouts() { await write.value }
    XCTAssertEqual(host.puts, [0], "written over the new host's layout")
    XCTAssertFalse(store.hostLayouts.stale.contains(id))
    XCTAssertTrue(store.hostLayouts.unanswered.contains(id))
  }

  /// A write still on its way to a workroom's old host when a reload moves the workroom is not
  /// taken as the new host's: its revision is not kept, and the workroom stays unanswered for the
  /// new host, so no later write retries over a layout it never read.
  func testAWriteToAWorkroomsOldHostIsNotTakenAsTheNewOnes() async throws {
    final class SlowHost: HostLayoutStore, @unchecked Sendable {
      var puts: [UInt64] = []
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 9, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts.append(expected)
        try await Task.sleep(nanoseconds: 200_000_000)
        guard expected == 3 else { throw AgentLayoutError.stale(revision: 9) }
        return 4
      }
    }
    let host = SlowHost()
    let saved = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { _ in host }
    defer { AppStore.hostLayoutStore = saved }
    let workroomID = UUID()
    let first = UUID()
    func project(host: UUID) -> Project {
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "o", path: "/home/workroom/o", vcsName: "workroom/o", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: host, workroomID: workroomID))
        ])
    }
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [project(host: first)]
    let id = TerminalTarget.workroomID(project: "/proj", name: "o")
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroomID, targetID: id, by: store))
    store.terminals.restore(
      TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    store.hostLayouts.fetched.insert(id)
    store.hostLayouts.hosts[id] = (first, workroomID)
    store.hostLayouts.revisions[id] = 3
    store.hostLayouts.written[id] = "the first host's layout"

    let toOldHost = store.writeHostLayouts()
    XCTAssertEqual(toOldHost.count, 1)
    store.projects = [project(host: UUID())]
    XCTAssertTrue(store.writeHostLayouts().isEmpty, "raced the write in flight")
    for write in toOldHost { await write.value }
    if let next = store.hostLayouts.writing[id] { await next.value }
    XCTAssertNotEqual(store.hostLayouts.revisions[id], 4, "the old host's revision was kept")
    XCTAssertTrue(store.hostLayouts.unanswered.contains(id))
    XCTAssertEqual(host.puts, [3, 0], "the new host was not written as unanswered")
  }

  /// A host whose layout resolves in time but whose session list is late keeps the resolution:
  /// the layout may already have been written there, so the workroom is not treated as unanswered.
  func testALateSessionListKeepsTheResolvedLayout() async throws {
    final class EmptyHost: HostLayoutStore, @unchecked Sendable {
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 0, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        expected + 1
      }
    }
    let savedStore = AppStore.hostLayoutStore
    let savedSessions = AppStore.hostSessions
    AppStore.hostLayoutStore = { _ in EmptyHost() }
    AppStore.hostSessions = { _ in
      try await Task.sleep(nanoseconds: 30_000_000_000)
      return []
    }
    defer {
      AppStore.hostLayoutStore = savedStore
      AppStore.hostSessions = savedSessions
    }
    let workroom = Workroom(
      name: "l", path: "/home/workroom/l", vcsName: "workroom/l", warnings: [],
      host: HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: UUID()))
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [Project(path: "/proj", vcs: "git", workrooms: [workroom])]
    let id = TerminalTarget.workroomID(project: "/proj", name: "l")
    store.pendingSessionRestore = WindowSession(
      windowKey: UUID().uuidString,
      targets: [TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")])])
    store.restorePersistedSessionIfPending(in: store.projects)
    let restored = expectation(description: "restored")
    func poll() {
      if store.terminals.tabCount(forTargetID: id) > 0 { return restored.fulfill() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
    await fulfillment(of: [restored], timeout: AppStore.hostLayoutTimeout + 3)
    XCTAssertEqual(store.hostLayouts.revisions[id], 1, "the seed this Mac wrote was forgotten")
    XCTAssertFalse(store.hostLayouts.unanswered.contains(id))
  }

  /// A host that keeps no layouts gives the workroom this Mac's own copy back, reattached to its
  /// saved session, whether the restore or the workroom's pane asks the host first.
  func testAHostKeepingNoLayoutsRestoresThisMacsCopy() async throws {
    for paneFirst in [false, true] {
      let saved = AppStore.hostLayoutStore
      AppStore.hostLayoutStore = { _ in
        throw AgentLayoutError.unsupported("this agent keeps no layouts")
      }
      defer { AppStore.hostLayoutStore = saved }
      let workroom = Workroom(
        name: "n", path: "/home/workroom/n", vcsName: "workroom/n", warnings: [],
        host: HostDescriptor(
          provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: UUID()))
      let store = AppStore()
      store.terminals.makeView = { _, cwd, _ in
        GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
      }
      store.projects = [Project(path: "/proj", vcs: "git", workrooms: [workroom])]
      let id = TerminalTarget.workroomID(project: "/proj", name: "n")
      let session = UUID()
      var tab = terminal("a", title: "Terminal 1")
      tab.terminal?.sessionID = session.uuidString
      store.pendingSessionRestore = WindowSession(
        windowKey: UUID().uuidString, targets: [TargetSession(targetID: id, tabs: [tab])])
      if paneFirst, let target = store.terminalTarget(forID: id) {
        store.ensureInitialTerminal(for: target)
      }
      store.restorePersistedSessionIfPending(in: store.projects)
      let restored = expectation(description: "restored")
      func poll() {
        if store.terminals.tabCount(forTargetID: id) > 0 { return restored.fulfill() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
      }
      poll()
      await fulfillment(of: [restored], timeout: AppStore.hostLayoutTimeout + 3)
      let sessions = store.captureWindowSession().targets.first { $0.targetID == id }?.tabs
        .compactMap { $0.terminal?.sessionID }
      XCTAssertEqual(sessions, [session.uuidString], "pane first: \(paneFirst)")
    }
  }

  /// An unanswered workroom whose own seed landed after the wait gave up finds it on the host when
  /// its first write is refused, and writes again at that seed's revision rather than leave the
  /// seed to win at the next launch.
  func testAnUnansweredWorkroomFindingItsOwnLateSeedWritesOverIt() async throws {
    final class SeededHost: HostLayoutStore, @unchecked Sendable {
      let seed: String
      var puts: [UInt64] = []
      init(seed: String) { self.seed = seed }
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 1, blob: seed) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts.append(expected)
        guard expected == 1 else { throw AgentLayoutError.stale(revision: 1) }
        return 2
      }
    }
    let workroomID = UUID()
    let host = SeededHost(seed: "the seed this Mac wrote")
    let saved = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { _ in host }
    defer { AppStore.hostLayoutStore = saved }
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "z", path: "/home/workroom/z", vcsName: "workroom/z", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: workroomID))
        ])
    ]
    let id = TerminalTarget.workroomID(project: "/proj", name: "z")
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroomID, targetID: id, by: store))
    store.terminals.restore(
      TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    store.hostLayouts.fetched.insert(id)
    store.hostLayouts.unanswered.insert(id)
    store.hostLayouts.unansweredWrite[id] = "the seed this Mac wrote"
    store.hostLayouts.written[id] = "the seed this Mac wrote"

    for write in store.writeHostLayouts() { await write.value }
    XCTAssertEqual(host.puts, [0, 1])
    XCTAssertEqual(store.hostLayouts.revisions[id], 2)
    XCTAssertFalse(store.hostLayouts.unanswered.contains(id))
  }

  /// A change saved while an unanswered workroom's write is in flight is sent once that write is
  /// refused, not left until some later change; and only once, however that one goes.
  func testAChangeBehindAnUnansweredWriteIsSentAfterIt() async throws {
    final class SlowMovedHost: HostLayoutStore, @unchecked Sendable {
      var puts = 0
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 5, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        throw AgentLayoutError.stale(revision: 5)
      }
    }
    let host = SlowMovedHost()
    let saved = AppStore.hostLayoutStore
    AppStore.hostLayoutStore = { _ in host }
    defer { AppStore.hostLayoutStore = saved }
    let workroomID = UUID()
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "q", path: "/home/workroom/q", vcsName: "workroom/q", warnings: [],
            host: HostDescriptor(
              provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: workroomID))
        ])
    ]
    let id = TerminalTarget.workroomID(project: "/proj", name: "q")
    let target = try XCTUnwrap(store.terminalTarget(forID: id))
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroomID, targetID: id, by: store))
    store.terminals.restore(
      TargetSession(targetID: id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    store.hostLayouts.fetched.insert(id)
    store.hostLayouts.unanswered.insert(id)
    store.hostLayouts.revisions[id] = 3
    store.hostLayouts.written[id] = "what this Mac last saw"

    let first = store.writeHostLayouts()
    XCTAssertEqual(first.count, 1)
    _ = store.terminals.addTab(for: target)
    XCTAssertTrue(store.writeHostLayouts().isEmpty, "raced the write in flight")
    for write in first { await write.value }
    let next = try XCTUnwrap(store.hostLayouts.writing[id], "the change behind it never sent")
    await next.value
    XCTAssertEqual(host.puts, 2)
    XCTAssertNil(store.hostLayouts.writing[id], "sent again in a loop")
  }

  /// Recovery reattaches only the targets it is told may: a pane of any other is left alone, its
  /// agent not recovered and no surface made for it.
  func testRecoveryLeavesATargetThatMayNotReattach() async {
    let sessions = makeSessions()
    sessions.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    let sessionID = UUID()
    sessions.restore(
      TargetSession(targetID: target.id, tabs: [terminal("a", title: "Terminal 1")]), for: target)
    var tab = sessions.tabs(for: target).first!
    guard case .terminal(var state) = tab.content else { return XCTFail("expected terminal") }
    state.sessionID = sessionID
    tab.content = .terminal(state)
    sessions.replace(tab, for: target)
    let descriptor = SessionDescriptor(
      identifier: SessionIdentifier(sessionID), shellProcessID: 123, ttyDevice: 0,
      workingDirectory: "/tmp", isAttached: false,
      metadata: [SessionEnvironmentEntry(key: "command", value: "claude")])

    let none: (TerminalTarget.ID) -> Bool = { _ in false }
    let this: (TerminalTarget.ID) -> Bool = { [target] in $0 == target.id }
    await sessions.materializeLivePersistentSessions(reattaches: none) { [descriptor] }
    XCTAssertTrue(sessions.activeAgentBackends.isEmpty, "a gated pane was reattached")

    await sessions.materializeLivePersistentSessions(reattaches: this) {
      [descriptor]
    }
    XCTAssertEqual(sessions.activeAgentBackends, [.claude])
  }

  /// The app lets a target's panes reattach only while it is local and opens here: not a missing
  /// directory, not a remote workroom (reachable or not), not one that no longer exists.
  func testOnlyALocalTargetThatOpensReattaches() {
    let store = AppStore()
    let here = FileManager.default.temporaryDirectory.path
    store.projects = [
      Project(
        path: here, vcs: "git",
        workrooms: [
          Workroom(name: "local", path: here, vcsName: "workroom/local", warnings: []),
          Workroom(
            name: "remote", path: "/home/workroom/r", vcsName: "workroom/remote", warnings: [],
            host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID())),
        ])
    ]
    XCTAssertTrue(store.reattachesLocally(TerminalTarget.rootID(project: here)))
    XCTAssertTrue(
      store.reattachesLocally(TerminalTarget.workroomID(project: here, name: "local")))
    XCTAssertFalse(
      store.reattachesLocally(TerminalTarget.workroomID(project: here, name: "remote")))
    XCTAssertFalse(
      store.reattachesLocally(TerminalTarget.workroomID(project: here, name: "gone")))
    XCTAssertFalse(store.reattachesLocally(TerminalTarget.rootID(project: "/no/such/project")))
    // The first load reads config only, so a missing directory carries no warning yet.
    store.projects[0] = Project(
      path: here, vcs: "git",
      workrooms: [
        Workroom(name: "moved", path: "/no/such/workroom", vcsName: "workroom/moved", warnings: [])
      ])
    XCTAssertFalse(
      store.reattachesLocally(TerminalTarget.workroomID(project: here, name: "moved")))
  }
}
