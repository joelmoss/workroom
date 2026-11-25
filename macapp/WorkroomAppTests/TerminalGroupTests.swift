import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Named terminal groups in a window (#658, ADR 0077): New Terminal Group… makes one, a window uses
/// it as it does a workroom (one title-bar tab, its own tabs, ⌘T, ⌘W and splits inside it), and
/// deleting it makes its terminals standalone in its place. Two windows share one section and each
/// keeps its own terminals in a group.
@MainActor
final class TerminalGroupTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  /// Whether the (daemon-less) retag of a moved terminal's session succeeds.
  private var retagSucceeds = true

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: projects, terminalsSection: section)
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { [weak self] _, _ in self?.retagSucceeds ?? false })
    return store
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  private func tabCount(_ store: AppStore, _ sid: SidebarID) -> Int {
    sid.targetID.map(store.terminals.tabCount(forTargetID:)) ?? 0
  }

  private func group(_ store: AppStore, named name: String = "Ops") throws -> SidebarID {
    let sid = try XCTUnwrap(store.newTerminalGroup(named: name))
    guard case .terminalGroup = sid else {
      XCTFail("\(sid) is not a terminal group")
      return sid
    }
    return sid
  }

  // MARK: Making one

  /// Value: protects=New Terminal Group… makes a named group a window uses like a workroom;
  /// fails_when=it lists no row, opens no terminal, or has no title-bar tab named for it;
  /// why_new=terminal groups (#658); seam=AppStore; no_claim=the name prompt itself
  func testNewTerminalGroupMakesANamedGroupWithItsFirstTerminal() throws {
    let store = makeStore()

    let sid = try group(store)

    XCTAssertEqual(rows, [sid])
    XCTAssertEqual(store.selectedTargetID, sid)
    XCTAssertEqual(tabCount(store, sid), 1)
    XCTAssertEqual(store.selectedTarget?.title, "Ops")
    XCTAssertEqual(store.selectedTarget?.path, TerminalsSection.newTerminalDirectory())
    XCTAssertEqual(store.orderedWorkroomTargets().map(\.target.id), [sid.targetID])
    XCTAssertEqual(store.orderedWorkroomTargets().map(\.target.title), ["Ops"])
  }

  /// A name that is only spaces makes nothing: New Terminal Group… makes a *named* group.
  func testAnEmptyNameMakesNoGroup() {
    let store = makeStore()

    XCTAssertNil(store.newTerminalGroup(named: "  "))
    XCTAssertTrue(rows.isEmpty)
  }

  /// A new group lands just below the selected row of the section.
  func testANewGroupLandsBelowTheSelectedRow() throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    let first = try XCTUnwrap(store.selectedTargetID)
    store.newStandaloneTerminal()
    let second = try XCTUnwrap(store.selectedTargetID)
    store.selectedTargetID = first

    let sid = try group(store)

    XCTAssertEqual(rows, [first, sid, second])
  }

  // MARK: Using one

  /// Value: protects=⌘T, splits and ⌘W inside a group act on its own tabs, as in a workroom, and
  /// closing its last terminal deletes the group, named or not; fails_when=⌘T opens a standalone
  /// terminal, a split leaves the group, or an empty named group stays listed; why_new=#658, and
  /// the owner's "a group goes with its last terminal"; seam=AppStore; no_claim=the tab strip
  func testTerminalsOpenSplitAndCloseInsideTheGroupWhichGoesWithItsLastTerminal() async throws {
    let store = makeStore()
    let sid = try group(store)

    store.newTerminalInSelectedTarget()
    XCTAssertEqual(tabCount(store, sid), 2, "⌘T opens a tab in the group")
    store.splitFocusedRight()
    XCTAssertEqual(tabCount(store, sid), 3, "⌘D splits inside it")
    XCTAssertEqual(rows, [sid], "and no standalone terminal appears")

    for _ in 0..<2 { store.closeCurrentTerminalTab() }
    await section.regroupsSettled()
    XCTAssertEqual(rows, [sid], "a named group with one terminal stays")

    store.closeCurrentTerminalTab()
    await section.regroupsSettled()

    XCTAssertEqual(tabCount(store, sid), 0)
    XCTAssertTrue(rows.isEmpty, "the group goes with its last terminal")
    XCTAssertNil(store.liveSelection(sid, in: projects.projects))
  }

  /// Value: protects=a group goes only once no window holds any of its terminals, counted across
  /// every window as the unnamed rule is; fails_when=closing the last terminal in one window drops
  /// a group another window still holds, or the last window's close keeps it; why_new=the owner's
  /// "a group goes with its last terminal"; seam=two AppStores over one section; no_claim=none
  func testAGroupGoesOnlyWhenNoWindowHoldsItsTerminals() async throws {
    let first = makeStore()
    let second = makeStore()
    let sid = try group(first)
    second.selectedTargetID = sid
    second.ensureInitialTerminal(for: try XCTUnwrap(second.selectedTarget))

    first.closeCurrentTerminalTab()
    await section.regroupsSettled()
    XCTAssertEqual(rows, [sid], "the second window still holds one of its terminals")
    XCTAssertEqual(first.terminalGroup(sid)?.name, "Ops")

    second.closeCurrentTerminalTab()
    await section.regroupsSettled()
    XCTAssertTrue(rows.isEmpty, "none is left in any window")
  }

  /// Value: protects=closing the window that holds a group's only terminals deletes the group, as
  /// closing them by hand does, while a quit's teardown never does; fails_when=the close leaves an
  /// empty group listed, or a quit drops one; why_new=the owner's "a group goes with its last
  /// terminal"; seam=AppStore's window close; no_claim=the close prompt
  func testClosingTheWindowHoldingAGroupsOnlyTerminalsDeletesIt() async throws {
    let holder = makeStore()
    let other = makeStore()
    let sid = try group(holder)
    holder.newTerminalInSelectedTarget()
    let kept = try XCTUnwrap(other.newTerminalGroup(named: "Kept"))

    await holder.endStandaloneTerminalsOnClose()
    await section.regroupsSettled()

    XCTAssertEqual(rows, [kept], "only the group no other window holds goes: \(sid)")
  }

  func testAQuitsWindowTeardownKeepsTheGroup() async throws {
    let holder = makeStore()
    let sid = try group(holder)
    WindowRegistry.shared.isTerminating = true
    defer { WindowRegistry.shared.isTerminating = false }

    await holder.terminals.reapAll()
    await holder.endStandaloneTerminalsOnClose()
    await section.regroupsSettled()

    XCTAssertEqual(rows, [sid])
  }

  /// Value: protects=each window keeps its own terminals in a group (story 33); fails_when=a
  /// second window selecting the group shows none, or takes the first window's;
  /// why_new=#658; seam=two AppStores over one section; no_claim=raising a holder (#656)
  func testEachWindowKeepsItsOwnTerminalsInAGroup() throws {
    let first = makeStore()
    let second = makeStore()
    let sid = try group(first)

    second.selectedTargetID = sid
    second.ensureInitialTerminal(for: try XCTUnwrap(second.selectedTarget))

    XCTAssertEqual(tabCount(second, sid), 1, "a window with none of its terminals opens one")
    XCTAssertEqual(tabCount(first, sid), 1, "and the first keeps its own")
    second.ensureInitialTerminal(for: try XCTUnwrap(second.selectedTarget))
    XCTAssertEqual(tabCount(second, sid), 1, "once")
  }

  /// Value: protects=a group's terminals start in its own folder (story 7), else in "New terminals
  /// open in"; fails_when=the folder is ignored, or a gone folder leaves its terminals homeless;
  /// why_new=#658; seam=AppStore; no_claim=the folder picker
  func testAGroupsTerminalsStartInItsStartingFolder() async throws {
    let store = makeStore()
    let sid = try group(store)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("group-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    store.setTerminalGroupStartingFolder(sid, to: folder.path)

    XCTAssertEqual(store.target(for: sid)?.path, folder.path)
    let tab = store.terminals.addTab(for: try XCTUnwrap(store.target(for: sid)))
    XCTAssertEqual(tab.terminal?.launchDirectory, folder.path)

    try FileManager.default.removeItem(at: folder)
    // Once its folder is checked again, off the main actor (`FolderPresence`).
    await section.folderPresence.check(folder.path)
    XCTAssertEqual(store.target(for: sid)?.path, TerminalsSection.newTerminalDirectory())

    store.setTerminalGroupStartingFolder(sid, to: nil)
    XCTAssertNil(store.terminalGroup(sid)?.startingFolder)
  }

  /// Value: protects=renaming a group from the sidebar, in every window; fails_when=the row or the
  /// title-bar tab keeps the old name; why_new=#658; seam=AppStore; no_claim=dissolving an
  /// unnamed group (UnnamedTerminalGroupTests)
  func testRenamingAGroupRetitlesItEverywhere() throws {
    let first = makeStore()
    let second = makeStore()
    let sid = try group(first)

    first.renameTerminalGroup(sid, to: "  Servers ")

    XCTAssertEqual(second.target(for: sid)?.title, "Servers")
    XCTAssertEqual(first.orderedWorkroomTargets().map(\.target.title), ["Servers"])

    first.newTerminalInSelectedTarget()
    first.renameTerminalGroup(sid, to: "")
    XCTAssertNil(first.terminalGroup(sid)?.name, "an empty name clears it")
    let folder = TerminalState.programAndFolder(
      program: TerminalState.shellName, folder: try XCTUnwrap(first.target(for: sid)).path
    ).text
    XCTAssertEqual(
      first.target(for: sid)?.title, "\(folder) + 1 more", "labelled by its first terminal")
  }

  /// Value: protects=a group's terminal row selects the group and focuses that terminal;
  /// fails_when=the click selects nothing, or the wrong terminal; why_new=#658; seam=AppStore;
  /// no_claim=the row's drawing
  func testATerminalsRowSelectsTheGroupAndFocusesIt() throws {
    let store = makeStore()
    let sid = try group(store)
    let target = try XCTUnwrap(store.target(for: sid))
    let first = try XCTUnwrap(store.terminals.tabs(for: target).first)
    store.newTerminalInSelectedTarget()
    store.selectedTargetID = workroom

    store.revealTerminal(first.id, at: sid)

    XCTAssertEqual(store.selectedTargetID, sid)
    XCTAssertEqual(store.terminals.focusedTab(for: target)?.id, first.id)
  }

  // MARK: Deleting one

  /// Value: protects=deleting a group never loses a shell (story 26): its terminals become
  /// standalone in its place, in order, and the window selects the first; fails_when=a terminal
  /// closes, lands elsewhere in the section, or is left in an unlisted group; why_new=#658;
  /// seam=AppStore; no_claim=the confirmation dialog
  func testDeletingAGroupMakesItsTerminalsStandaloneInItsPlace() async throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    let before = try XCTUnwrap(store.selectedTargetID)
    let sid = try group(store)
    store.newTerminalInSelectedTarget()
    let groupTarget = try XCTUnwrap(store.target(for: sid))
    let tabs = store.terminals.tabs(for: groupTarget).map(\.id)
    store.newStandaloneTerminal()
    let after = try XCTUnwrap(store.selectedTargetID)
    XCTAssertEqual(rows, [before, sid, after])
    store.selectedTargetID = sid
    XCTAssertTrue(store.terminalGroupDeleteAsks(sid))

    await store.deleteTerminalGroup(sid)

    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(rows.first, before)
    XCTAssertEqual(rows.last, after)
    let made = Array(rows[1...2])
    for (row, tab) in zip(made, tabs) {
      guard case .standalone = row else { return XCTFail("\(row) is not standalone") }
      let target = try XCTUnwrap(store.target(for: row))
      XCTAssertEqual(store.terminals.tabs(for: target).map(\.id), [tab], "the same terminal")
    }
    XCTAssertNil(store.terminalGroup(sid))
    XCTAssertEqual(store.selectedTargetID, made.first)
  }

  /// An empty group (one no window has opened a terminal in yet) is deleted without asking.
  func testAnEmptyGroupIsDeletedWithoutAsking() async throws {
    let store = makeStore()
    let sid = try XCTUnwrap(section.addGroup(named: "Ops").sidebarID)
    store.selectedTargetID = sid

    XCTAssertFalse(store.terminalGroupDeleteAsks(sid))
    await store.deleteTerminalGroup(sid)

    XCTAssertTrue(rows.isEmpty)
    XCTAssertNil(
      store.liveSelection(sid, in: projects.projects), "the window showing it shows nothing")
  }

  /// Every window's terminals in the group become standalone, each in its own window.
  func testDeletingAGroupReachesEveryWindowsTerminals() async throws {
    let first = makeStore()
    let second = makeStore()
    let sid = try group(first)
    second.selectedTargetID = sid
    second.ensureInitialTerminal(for: try XCTUnwrap(second.selectedTarget))

    await first.deleteTerminalGroup(sid)

    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map { tabCount(first, $0) }, [1, 0])
    XCTAssertEqual(rows.map { tabCount(second, $0) }, [0, 1])
    XCTAssertEqual(second.selectedTargetID, rows[1])
  }

  /// Value: protects=a group whose terminal couldn't be handed over keeps it listed, so its shell
  /// is never in an unlisted target the launch sweep would end; fails_when=the group goes anyway,
  /// or a dead standalone row is left; why_new=#658; seam=AppStore over a failing retag;
  /// no_claim=the error shown
  func testAGroupWhoseTerminalCannotMoveStays() async throws {
    let store = makeStore()
    let sid = try group(store)
    let target = try XCTUnwrap(store.target(for: sid))
    let session = UUID()
    _ = store.terminals.addTab(for: target, sessionID: session)
    retagSucceeds = false

    await store.deleteTerminalGroup(sid)

    XCTAssertEqual(rows.count, 2, "the group, and the terminal that did move")
    XCTAssertEqual(rows.first, sid)
    XCTAssertEqual(
      store.terminals.tabs(for: target).compactMap(\.terminal?.sessionID), [session])
  }

  // MARK: Reordering

  /// Value: protects=dragging rows within the section (story 12) keeps that order; fails_when=a
  /// row moves to the wrong place or another row is lost; why_new=#658; seam=the section;
  /// no_claim=the drag gesture
  func testRowsReorder() throws {
    let store = makeStore()
    store.newStandaloneTerminal()
    let a = try XCTUnwrap(store.selectedTargetID)
    let g = try group(store)
    store.newStandaloneTerminal()
    let b = try XCTUnwrap(store.selectedTargetID)
    XCTAssertEqual(rows, [a, g, b])

    section.move(try XCTUnwrap(b.targetID), before: a.targetID)
    XCTAssertEqual(rows, [b, a, g])
    section.move(try XCTUnwrap(b.targetID), before: nil)
    XCTAssertEqual(rows, [a, g, b])
    section.move(try XCTUnwrap(a.targetID), before: b.targetID)
    XCTAssertEqual(rows, [g, a, b])
    section.move(try XCTUnwrap(a.targetID), before: a.targetID)
    XCTAssertEqual(rows, [g, a, b], "onto itself, it stays")
  }

  // MARK: Nothing project-shaped

  /// Value: protects=no sidebar-keyed version control or Run for a group (story 48–49); its
  /// inspector follows its focused terminal instead (#806, ADR 0081,
  /// TerminalGroupFollowsFocusTests); fails_when=any of them resolves for it; why_new=#658;
  /// seam=AppStore; no_claim=the menus' rendering
  func testAGroupHasNoProjectVersionControlOrRun() async throws {
    let store = makeStore()
    let sid = try group(store)
    await store.followedFolderResolved()

    XCTAssertTrue(store.selectionHasTabs)
    guard case .followed = store.inspectorSubject else {
      return XCTFail("the inspector follows its focused terminal, not \(store.inspectorSubject)")
    }
    XCTAssertNil(store.inspectorTargetID, "a followed folder is no sidebar item")
    XCTAssertNil(store.remoteTarget())
    XCTAssertFalse(store.vcsStatus.targetExists(sid))
    XCTAssertNil(AppStore.projectPath(of: sid))
    XCTAssertNil(store.project(forTargetID: try XCTUnwrap(sid.targetID)))
  }

  /// Value: protects=a group's sessions outlive the launch sweep; fails_when=its tag doesn't
  /// resolve, so the sweep ends them; why_new=#658; seam=the sweep's resolver; no_claim=none
  func testTheLaunchSweepSparesAGroupsSessions() throws {
    let store = makeStore()
    let sid = try group(store)
    let target = try XCTUnwrap(store.selectedTarget)
    guard case .terminalGroup(let id) = sid else { return XCTFail("\(sid)") }

    XCTAssertEqual(target.sessionWorkroomKey, "group:\(id.uuidString)")
    XCTAssertTrue(store.sessionTagResolves(target.sessionWorkroomKey))
    XCTAssertFalse(store.sessionTagResolves(TargetID.terminalGroup(UUID()).encoded))
  }

  /// With nothing listed, a group's session is judged by the section alone, as a standalone
  /// terminal's is: a listed group's is spared, a gone one's ended.
  func testWithNothingListedTheSweepJudgesAGroupBySection() throws {
    let store = makeStore()
    let sid = try group(store)

    XCTAssertTrue(store.sessionSurvivesSweep(try XCTUnwrap(sid.targetID).encoded, in: []))
    XCTAssertFalse(store.sessionSurvivesSweep(TargetID.terminalGroup(UUID()).encoded, in: []))
  }

  /// Value: protects=the launch's prune drops a group none of whose terminals came back, named or
  /// not, and keeps one a window holds; fails_when=an empty named group lingers after a launch, or
  /// a held one goes; why_new=the owner's "a group goes with its last terminal" over #658's prune;
  /// seam=the section with a registered window; no_claim=unnamed groups (UnnamedTerminalGroupTests)
  func testTheLaunchPruneDropsANamedGroupNoWindowHolds() throws {
    let store = makeStore()
    let held = try group(store)
    let empty = try XCTUnwrap(section.addGroup(named: "Gone").sidebarID)
    section.addStandalone()

    let pruned = section.pruneUnheld()

    XCTAssertEqual(rows, [held], "the held group stays; the empty one and the unheld row go")
    XCTAssertTrue(pruned.contains(try XCTUnwrap(empty.targetID)))
  }

  func testAnUnnamedGroupIsLabelledByBothOfTwoNamesElseTheFirstAndHowManyMore() {
    let group = TerminalGroup(id: UUID())
    XCTAssertEqual(group.title(terminalNames: []), TerminalGroup.untitled)
    XCTAssertEqual(group.title(terminalNames: ["zsh"]), "zsh")
    XCTAssertEqual(group.title(terminalNames: ["zsh", "htop"]), "zsh + htop")
    XCTAssertEqual(group.title(terminalNames: ["zsh", "zsh"]), "zsh + 1 more", "two the same")
    XCTAssertEqual(group.title(terminalNames: ["zsh", "htop", "vim"]), "zsh + 2 more")
    XCTAssertEqual(
      TerminalGroup(id: UUID(), name: "Servers").title(terminalNames: ["zsh"]), "Servers")
  }
}
