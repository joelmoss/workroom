import XCTest

@testable import Workroom

/// Back/forward across *content* tabs (diffs, files, changesets) — the half of issue #26 that was
/// never wired. `AppStoreNavigationTests` covers terminal tabs only.
///
/// The first two tests were written against unmodified `master` and failed there (only 2 entries
/// recorded for two browsed files, and Back landed on the terminal), which is what proved the bug.
///
/// The governing rule these pin: **back ignores anything that was closed, and nothing is ever
/// reopened.** Replay never creates a tab — it doesn't need to, because a content tab can always be
/// retargeted back to what it was showing, pin included. Only a CLOSED tab takes its steps with it
/// (`prune`), which is the same question `isLive` asks.
@MainActor
final class AppStoreContentNavigationTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    // A GhosttySurfaceView only spawns its PTY once it enters a window, so this is inert in tests.
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
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

  @discardableResult
  private func addTerminal(_ store: AppStore, _ sid: SidebarID) -> UUID {
    store.selectedTargetID = sid
    store.newTerminalInSelectedTarget()
    return store.terminals.focusedTab(for: store.target(for: sid)!)!.id
  }

  /// Single-clicking two files in the Changes panel is two visited locations, so Back must return to
  /// the first file's diff.
  ///
  /// The original bug, and why it hid: the second click retargets the shared preview tab in place
  /// (`TerminalSessions.openContentPreview` invariant B), which moves no focus, and the diff opener
  /// recorded nothing of its own — so only ONE content entry ever existed and Back walked straight past
  /// both files to the terminal. This test failed exactly that way before the fix.
  func testBackShowsThePreviousDiff() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)  // history: [terminal]

    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)

    // The two clicks share one preview tab — that part is correct and deliberate.
    XCTAssertEqual(
      store.terminals.tabs(for: targetA).count, 2, "expected the terminal + one shared preview tab")

    XCTAssertEqual(
      store.history.entries.count, 3,
      "expected one entry per visited location (terminal, A.swift, B.swift)")

    store.navigateBack()

    let landed = store.terminals.focusedTab(for: targetA)?.content
    guard case .diff(let descriptor)? = landed else {
      return XCTFail("Back left a non-diff pane focused: \(String(describing: landed))")
    }
    XCTAssertEqual(descriptor.path, "A.swift", "Back must show the previously viewed file's diff")
  }

  /// The same gap for the Files panel: a repo file opened as a preview records no location, so Back
  /// cannot return to it.
  func testBackShowsThePreviousFile() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)

    store.openFilePreview(path: "A.swift")
    store.openFilePreview(path: "B.swift")

    XCTAssertEqual(
      store.history.entries.count, 3,
      "expected one entry per visited location (terminal, A.swift, B.swift)")

    store.navigateBack()

    let landed = store.terminals.focusedTab(for: targetA)?.content
    guard case .file(let descriptor)? = landed else {
      return XCTFail("Back left a non-file pane focused: \(String(describing: landed))")
    }
    XCTAssertEqual(descriptor.path, "A.swift", "Back must show the previously viewed file")
  }

  /// Commits already worked before this fix (their opener recorded explicitly), which is exactly why
  /// the bug looked unreproducible when tested from History rows. Kept as a regression.
  func testBackShowsThePreviousChangeset() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)

    store.openChangesetPreview(commitID: "aaa111", title: "first")
    store.openChangesetPreview(commitID: "bbb222", title: "second")

    XCTAssertEqual(store.history.entries.count, 3)

    store.navigateBack()

    let landed = store.terminals.focusedTab(for: targetA)?.content
    guard case .changeset(let descriptor)? = landed else {
      return XCTFail("Back left a non-changeset pane focused: \(String(describing: landed))")
    }
    XCTAssertEqual(descriptor.commitID, "aaa111")
  }

  /// A diff and a plain file for the same path are different panes, so Back returns to the diff.
  func testBackCrossesFromFileToDiffOnTheSamePath() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)

    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openFilePreview(path: "A.swift")  // shares the one preview slot

    store.navigateBack()

    guard case .diff(let descriptor)? = store.terminals.focusedTab(for: targetA)?.content else {
      return XCTFail("Back must return to the diff, not stay on the file viewer")
    }
    XCTAssertEqual(descriptor.path, "A.swift")
  }

  /// Preview then persist for the same file is ONE place: `isPreview` is not identity.
  func testPreviewThenPersistRecordsOneEntry() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)
    let file = ChangedFile(path: "A.swift", change: .modified)

    store.openDiffPreview(file, source: .gitWorktree)
    let afterPreview = store.history.entries.count
    store.openDiffPersistent(file, source: .gitWorktree)  // the <350ms second click

    XCTAssertEqual(store.history.entries.count, afterPreview, "pinning is not a new location")
  }

  /// THE RULE: replay never creates a tab. It doesn't need to — a content tab can always be retargeted
  /// back to what it was showing, INCLUDING a pinned one.
  ///
  /// Pinning must not strand the steps browsed before it. An earlier version required a free preview
  /// slot, which `persist` removes: every earlier entry went unreachable while `canGoBack` (a raw cursor
  /// read) stayed true, so one double-click re-armed the original bug behind an enabled-but-dead chevron.
  func testReplayRetargetsAPinnedTabRatherThanCreatingOne() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)

    // Browse two files in the shared preview tab, then pin it — no preview slot is left.
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)
    let pinned = store.terminals.focusedTab(for: targetA)!.id
    store.terminals.persist(pinned, for: targetA)
    let tabCount = store.terminals.tabs(for: targetA).count

    store.navigateBack()  // wants A.swift; the only content tab is pinned

    XCTAssertEqual(
      store.terminals.tabs(for: targetA).count, tabCount, "Back must not create a tab")
    XCTAssertEqual(
      store.terminals.focusedTab(for: targetA)?.id, pinned, "it lands in the tab it was recorded in"
    )
    guard case .diff(let d)? = store.terminals.tab(pinned, for: targetA)?.content else {
      return XCTFail("expected the pinned tab to show the recorded diff")
    }
    XCTAssertEqual(d.path, "A.swift")
    XCTAssertFalse(d.isPreview, "retargeting carries the pin over — it does not un-pin the tab")
  }

  /// Enablement and reachability must agree: whenever `canGoBack` is true, Back actually moves. The
  /// regression this pins made the chevron live while `step` silently returned nil.
  func testBackAlwaysMovesWhenEnabled() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)
    store.terminals.persist(store.terminals.focusedTab(for: targetA)!.id, for: targetA)

    var seen: [String] = []
    while store.canGoBack {
      let before = store.history.cursor
      store.navigateBack()
      XCTAssertNotEqual(
        store.history.cursor, before, "canGoBack was true but the cursor did not move")
      if case .diff(let d)? = store.terminals.focusedTab(for: targetA)?.content {
        seen.append(d.path)
      }
    }
    XCTAssertEqual(seen, ["A.swift"], "the pinned run's earlier file is still reachable")
  }

  /// Replay prefers the tab the location was recorded in, so ⌘D twins (two tabs, same content) do not
  /// send Back to the wrong pane. Also pins that replay focuses rather than duplicating.
  func testReplayPrefersTheRecordedTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)

    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    let anchor = store.terminals.focusedTab(for: targetA)!.id
    // ⌘D on a diff pane → a twin of A.swift
    store.terminals.splitFocusedPane(for: targetA, orientation: .horizontal)
    let twin = store.terminals.focusedTab(for: targetA)!.id
    XCTAssertNotEqual(anchor, twin, "⌘D on a diff pane makes a second view of the same file")
    let tabCount = store.terminals.tabs(for: targetA).count

    store.navigateBack()  // the anchor's entry

    XCTAssertEqual(store.terminals.focusedTab(for: targetA)?.id, anchor)
    XCTAssertEqual(store.terminals.tabs(for: targetA).count, tabCount)
  }

  /// Selecting files inside a commit is its own step, recorded by the content seam, and reinstated.
  func testBackReinstatesTheInCommitFileSelection() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openChangesetPreview(commitID: "aaa111", title: "first")
    let tab = store.terminals.focusedTab(for: targetA)!.id

    store.selectChangesetFile("one.swift", tab: tab, in: targetA)
    store.selectChangesetFile("two.swift", tab: tab, in: targetA)

    store.navigateBack()
    guard case .changeset(let back)? = store.terminals.focusedTab(for: targetA)?.content else {
      return XCTFail("expected the changeset pane")
    }
    XCTAssertEqual(back.selectedPath, "one.swift")

    store.navigateForward()
    guard case .changeset(let fwd)? = store.terminals.focusedTab(for: targetA)?.content else {
      return XCTFail("expected the changeset pane")
    }
    XCTAssertEqual(fwd.selectedPath, "two.swift")
  }

  /// Replay must not record. Nested suppression (`applyLocation` calls `applyLocation`) used to be able
  /// to reopen recording halfway through, so a replay logged itself.
  func testReplayAppendsNothing() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)
    store.openChangesetPreview(commitID: "aaa111", title: "first")
    let count = store.history.entries.count

    store.navigateBack()
    store.navigateBack()
    store.navigateForward()
    store.navigateForward()

    XCTAssertEqual(store.history.entries.count, count, "replay must never record")
  }

  /// Back across a workroom boundary must carry the selection AND the content together.
  func testBackCrossesWorkroomsAndReinstatesContent() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    addTerminal(store, b)  // now viewing B

    store.navigateBack()

    XCTAssertEqual(store.selectedTargetID, a)
    guard case .diff(let descriptor)? = store.terminals.focusedTab(for: targetA)?.content else {
      return XCTFail("Back must reinstate A's diff, not just select A")
    }
    XCTAssertEqual(descriptor.path, "A.swift")
  }

  /// A content change in a co-displayed but NON-selected workroom is not where the user is, so it must
  /// not record — `recordCurrentLocation` logs the *selected* target, which would be the wrong place.
  func testContentChangeInANonSelectedTargetRecordsNothing() {
    let store = makeStore([project("/a", workrooms: ["main"]), project("/b", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let b = SidebarID.workroom(project: "/b", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openChangesetPreview(commitID: "aaa111", title: "first")
    let tabInA = store.terminals.focusedTab(for: targetA)!.id
    addTerminal(store, b)  // selection moves to B; A's changeset tab stays as it was
    let count = store.history.entries.count

    store.selectChangesetFile("one.swift", tab: tabInA, in: targetA)

    XCTAssertEqual(store.history.entries.count, count)
  }

  /// Closing the tab that carried a browse run drops its steps (back ignores what was closed).
  func testClosingTheBrowsePreviewPrunesItsEntries() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)
    let preview = store.terminals.focusedTab(for: targetA)!.id
    XCTAssertTrue(store.canGoBack)

    store.terminals.closeTab(preview, for: targetA)

    XCTAssertFalse(store.canGoBack, "both browse steps went with the tab")
  }

  /// Replay step 2 — the recorded tab drifted, but ANOTHER live tab still shows the content, so focus
  /// moves there and the preview slot is left alone. Reachable via ⌘D, which pins the anchor and makes
  /// the twin the sole preview slot.
  func testReplayFocusesAnotherTabAlreadyShowingTheContent() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.terminals.splitFocusedPane(for: targetA, orientation: .horizontal)
    let pinned = store.terminals.tabs(for: targetA).first {
      if case .diff(let d) = $0.content { return d.path == "A.swift" && !d.isPreview }
      return false
    }!.id
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)
    let twin = store.terminals.focusedTab(for: targetA)!.id
    let tabCount = store.terminals.tabs(for: targetA).count

    store.navigateBack()  // the twin's A.swift entry; the twin shows B, `pinned` still shows A

    XCTAssertEqual(
      store.terminals.focusedTab(for: targetA)?.id, pinned,
      "step 2 must focus the tab that already shows the recorded content")
    XCTAssertEqual(store.terminals.tabs(for: targetA).count, tabCount)
    guard case .diff(let stillB)? = store.terminals.tab(twin, for: targetA)?.content else {
      return XCTFail("the twin should be untouched")
    }
    XCTAssertEqual(
      stillB.path, "B.swift", "replay must not retarget the slot Forward returns through")
  }

  /// Back and Forward both work through a pinned tab, and the round trip returns the content it started
  /// on — the pin is carried through every hop.
  func testBackAndForwardRoundTripThroughAPinnedTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openDiffPreview(ChangedFile(path: "A.swift", change: .modified), source: .gitWorktree)
    store.openDiffPreview(ChangedFile(path: "B.swift", change: .modified), source: .gitWorktree)
    let tab = store.terminals.focusedTab(for: targetA)!.id
    store.terminals.persist(tab, for: targetA)  // no preview slot left

    store.navigateBack()
    guard case .diff(let back)? = store.terminals.tab(tab, for: targetA)?.content else {
      return XCTFail("expected the pinned tab to hold the recorded diff")
    }
    XCTAssertEqual(back.path, "A.swift")

    store.navigateForward()
    guard case .diff(let fwd)? = store.terminals.tab(tab, for: targetA)?.content else {
      return XCTFail("expected the pinned tab to hold the recorded diff")
    }
    XCTAssertEqual(fwd.path, "B.swift", "Forward returns to where the round trip started")
    XCTAssertFalse(fwd.isPreview, "still pinned after two hops")
  }

  /// The first file in a commit has ONE spelling in history: an empty selection. Recording it by name
  /// would make a second entry that renders identically, so Back would spend a press going nowhere.
  func testTheFirstFileIsRecordedAsTheDefaultSelection() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openChangesetPreview(commitID: "aaa111", title: "first")
    let tab = store.terminals.focusedTab(for: targetA)!.id

    store.selectChangesetFile("two.swift", tab: tab, in: targetA)
    let afterTwo = store.history.entries.count
    // The view reports the first file as nil — the value the descriptor already holds by default.
    store.selectChangesetFile(nil, tab: tab, in: targetA)
    let afterFirst = store.history.entries.count
    store.selectChangesetFile(nil, tab: tab, in: targetA)  // tapping it again changes nothing

    XCTAssertEqual(afterFirst, afterTwo + 1, "returning to the default selection is one step")
    XCTAssertEqual(store.history.entries.count, afterFirst, "re-tapping it records nothing")

    store.navigateBack()
    guard case .changeset(let d)? = store.terminals.focusedTab(for: targetA)?.content else {
      return XCTFail("expected the changeset pane")
    }
    XCTAssertEqual(d.selectedPath, "two.swift")
  }

  /// A payload carries no `selectedPath` of its own — it lives on the location, where `==` can see it.
  /// Two copies would let dedup read one value while replay applied the other.
  func testChangesetPayloadCarriesNoSelectedPath() {
    let descriptor = ChangesetDescriptor(
      commitID: "aaa111", title: "first", isPreview: true, selectedPath: "two.swift")
    guard case .changeset(let stripped)? = NavPayload(.changeset(descriptor)) else {
      return XCTFail("expected a changeset payload")
    }
    XCTAssertNil(
      stripped.selectedPath, "the selection is identity, and identity lives on NavLocation")
    XCTAssertFalse(stripped.isPreview, "as with isPreview, normalised out")
  }

  /// The double-click openers lost their explicit `recordCurrentLocation()` in this change, so pin the
  /// replacement: opening NEW content persistently is exactly one new step, and Back still works.
  func testPersistentOpenOfNewContentRecordsOneStep() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openChangesetPreview(commitID: "aaa111", title: "first")
    let afterPreview = store.history.entries.count

    store.openChangesetPersistent(commitID: "bbb222", title: "second")

    XCTAssertEqual(
      store.history.entries.count, afterPreview + 1,
      "a persisted open of new content is one new place")

    store.navigateBack()
    guard case .changeset(let back)? = store.terminals.focusedTab(for: targetA)?.content else {
      return XCTFail("Back must return to the first commit")
    }
    XCTAssertEqual(back.commitID, "aaa111")
  }

  /// The seam's second rejection clause: content changing in a NON-FOCUSED tab of the SELECTED target.
  /// Reachable because `ChangesetDetailView`'s row tap does not focus its pane first.
  func testContentChangeInANonFocusedTabRecordsNothing() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let a = SidebarID.workroom(project: "/a", name: "main")
    let targetA = store.target(for: a)!
    addTerminal(store, a)
    store.openChangesetPreview(commitID: "aaa111", title: "first")
    let changesetTab = store.terminals.focusedTab(for: targetA)!.id
    addTerminal(store, a)  // same target, focus moves off the changeset tab
    let count = store.history.entries.count

    store.selectChangesetFile("one.swift", tab: changesetTab, in: targetA)

    XCTAssertEqual(
      store.history.entries.count, count, "a change in a non-focused tab is not where the cursor is"
    )
  }

  /// A replayed working-copy diff takes its change kind from live status, so Back cannot reinstate a
  /// `.modified` badge — or an enabled "Open file in…" — for a file that has since been deleted.
  func testReplayRefreshesAStaleChangeKind() {
    let recorded = NavPayload.diff(
      DiffDescriptor(
        path: "A.swift", change: .modified, source: .gitWorktree, isPreview: false))
    var status = WorkroomStatus()
    status.changedFiles = [ChangedFile(path: "A.swift", change: .deleted)]

    guard case .diff(let refreshed) = AppStore.refreshingChangeKind(recorded, from: status) else {
      return XCTFail("expected a diff payload back")
    }
    XCTAssertEqual(refreshed.change, .deleted)

    // A commit's own diff is immutable — never refreshed, even if a path happens to match.
    let commitDiff = NavPayload.diff(
      DiffDescriptor(
        path: "A.swift", change: .modified, source: .commit("abc"), isPreview: false))
    guard case .diff(let untouched) = AppStore.refreshingChangeKind(commitDiff, from: status) else {
      return XCTFail("expected a diff payload back")
    }
    XCTAssertEqual(untouched.change, .modified)

    // No status yet ⇒ keep what we recorded rather than inventing a kind.
    guard case .diff(let kept) = AppStore.refreshingChangeKind(recorded, from: nil) else {
      return XCTFail("expected a diff payload back")
    }
    XCTAssertEqual(kept.change, .modified)
  }
}
