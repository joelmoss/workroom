import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Any terminal moves anywhere (#660, ADR 0077): Move to lists Standalone, the user's terminal
/// groups, New Terminal Group… and the workrooms open in windows, for every terminal; a tab dropped
/// on a sidebar row, a title-bar tab or the Terminals heading moves there; and nothing moves to or
/// from a remote workroom.
@MainActor
final class PaneMoveAnywhereTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  private let sidA = SidebarID.workroom(project: "/p", name: "a")
  private let sidB = SidebarID.workroom(project: "/p", name: "b")
  private let remote = SidebarID.workroom(project: "/p", name: "far")

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [
          Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: []),
          Workroom(name: "b", path: "/p/b", vcsName: "workroom/b", warnings: []),
          Workroom(
            name: "far", path: "/p/far", vcsName: "workroom/far", warnings: [],
            host: HostDescriptor(id: UUID())),
        ])
    ]
  }

  private func makeWindow(retag: Bool = true) -> AppStore {
    let window = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    window.services.notifier = SilentNotifier()
    window.confirmOnCloseOverrideForTesting = false
    window.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    window.terminals.recordUnrecognizedTool = { _ in }
    window.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in retag })
    return window
  }

  private func target(_ window: AppStore, _ sid: SidebarID) throws -> TerminalTarget {
    try XCTUnwrap(window.target(for: sid))
  }

  /// A window showing workroom `a` with one pane, which is returned.
  private func paneInA(_ window: AppStore) throws -> (TerminalTab, TerminalTarget) {
    let from = try target(window, sidA)
    let pane = window.terminals.addTab(for: from)
    window.selectedTargetID = sidA
    return (pane, from)
  }

  private func settle(until done: () -> Bool) async {
    for _ in 0..<100 where !done() { await Task.yield() }
  }

  private var rows: [SidebarID] { section.entries.map(\.sidebarID) }

  // MARK: The choices

  /// Value: protects=Move to on any terminal lists Standalone, the Quick Terminal, the user's groups
  /// and New Terminal Group… before the workrooms open in windows (AC 1); fails_when=the builder lists only
  /// workrooms, or lists a group's or standalone terminal's title-bar tab as a workroom;
  /// why_new=#660; seam=AppStore; no_claim=menu rendering.
  func testMoveToListsTheTerminalsSectionThenTheOpenWorkrooms() throws {
    let window = makeWindow()
    let (pane, from) = try paneInA(window)
    let named = try XCTUnwrap(window.newTerminalGroup(named: "Servers"))
    window.newStandaloneTerminal()
    window.selectedTargetID = sidA

    // The panel is passed in: the no-panel overload reads the app-wide `WindowRegistry`, whose
    // Quick Terminal another test in the same process may or may not have made.
    let panel = makeQuickTerminalHost(notifications: registry.notifications, section: section)
    let groups = window.paneMoveChoices(
      pane.id, of: from, windows: [window], quickTerminal: panel)

    XCTAssertEqual(
      groups.first?.choices.map(\.title),
      ["Standalone Terminal", "Quick Terminals", "Servers", "New Terminal Group…"],
      "the Quick Terminal right after Standalone (#661)")
    XCTAssertNil(groups.first?.header)
    XCTAssertEqual(
      groups.dropFirst().flatMap(\.choices).map(\.title), ["p / a"],
      "a workroom reads \"project / workroom\", as the rest of the app writes it")
    XCTAssertEqual(groups.dropFirst().flatMap(\.choices).map(\.enabled), [false], "its own")
    XCTAssertEqual(
      groups.dropFirst().flatMap(\.choices).map(\.isCurrent), [true], "its own, checked")
    XCTAssertFalse(groups[0].choices.contains(where: \.isCurrent), "no other place is checked")
    XCTAssertTrue(groups[0].choices.allSatisfy(\.enabled))
    XCTAssertNotNil(window.terminalGroup(named))
  }

  /// Value: protects=a standalone terminal's own place is Standalone Terminal, listed checked and
  /// disabled, so it reads as where the terminal is, not a section heading;
  /// fails_when=moving a standalone terminal to Standalone churns its row, or the item is unchecked;
  /// why_new=#660;
  /// seam=AppStore; no_claim=none.
  func testAStandaloneTerminalsStandaloneChoiceIsDisabled() throws {
    let window = makeWindow()
    window.newStandaloneTerminal()
    let from = try XCTUnwrap(window.selectedTarget)
    let pane = try XCTUnwrap(window.terminals.tabs(for: from).first)

    let choices = window.paneMoveChoices(pane.id, of: from, windows: [window])[0].choices

    XCTAssertEqual(choices.first?.title, "Standalone Terminal")
    XCTAssertEqual(choices.first?.enabled, false)
    XCTAssertEqual(choices.first?.isCurrent, true, "checked: the terminal's place now")
    XCTAssertEqual(choices.filter(\.isCurrent).count, 1)
  }

  // MARK: Each destination

  /// Value: protects=Move to → Standalone makes a new standalone terminal in the source's window,
  /// keeping the shell (AC 2); fails_when=it opens a new shell, lands in another window, or leaves
  /// the pane in its workroom; why_new=#660; seam=AppStore pair; no_claim=window raise on screen.
  func testMovingToStandaloneMakesOneInTheSourcesWindow() async throws {
    let other = makeWindow()
    let window = makeWindow()
    let (pane, from) = try paneInA(window)
    let surface = window.terminals.surface(pane)

    let standalone = try XCTUnwrap(
      window.paneMoveChoices(pane.id, of: from, windows: [other, window])[0].choices.first)
    standalone.move()
    await settle { !rows.isEmpty && window.terminals.tab(pane.id, for: from) == nil }

    let sid = try XCTUnwrap(rows.first)
    guard case .standalone = sid else { return XCTFail("\(sid) is not standalone") }
    let into = try target(window, sid)
    XCTAssertTrue(window.terminals.surface(window.terminals.tab(pane.id, for: into)) === surface)
    XCTAssertEqual(window.selectedTargetID, sid)
    XCTAssertEqual(other.terminals.tabCount(forTargetID: into.id), 0)
  }

  /// Value: protects=Move to → a group moves the terminal into that group in its window (AC 1);
  /// fails_when=groups are listed but not destinations; why_new=#660; seam=AppStore;
  /// no_claim=none.
  func testMovingToAGroupJoinsIt() async throws {
    let window = makeWindow()
    let group = try XCTUnwrap(window.newTerminalGroup(named: "Servers"))
    let (pane, from) = try paneInA(window)

    let choice = try XCTUnwrap(
      window.paneMoveChoices(pane.id, of: from, windows: [window])[0].choices.first {
        $0.title == "Servers"
      })
    choice.move()
    let into = try target(window, group)
    await settle { window.terminals.tab(pane.id, for: into) != nil }

    XCTAssertNotNil(window.terminals.tab(pane.id, for: into))
    XCTAssertEqual(window.terminals.tabCount(forTargetID: into.id), 2)
    XCTAssertEqual(window.selectedTargetID, group)
  }

  /// Value: protects=New Terminal Group… makes a named group and moves the terminal into it as its
  /// only terminal (AC 2); fails_when=it reuses New Terminal Group's opening of a fresh terminal,
  /// or an empty name makes a group; why_new=#660; seam=AppStore; no_claim=the name prompt.
  func testMovingToANewGroupMakesANamedGroupWithJustThatTerminal() async throws {
    let window = makeWindow()
    let (pane, from) = try paneInA(window)

    let refused = await window.movePaneToNewGroup(
      named: "  ", pane.id, of: from, source: window.terminals,
      notifications: registry.notifications)
    XCTAssertFalse(refused)
    XCTAssertTrue(rows.isEmpty)

    let moved = await window.movePaneToNewGroup(
      named: "Logs", pane.id, of: from, source: window.terminals,
      notifications: registry.notifications)

    XCTAssertTrue(moved)
    let sid = try XCTUnwrap(rows.first)
    XCTAssertEqual(window.terminalGroup(sid)?.name, "Logs")
    let into = try target(window, sid)
    XCTAssertEqual(window.terminals.tabs(for: into).map(\.id), [pane.id])
  }

  /// Value: protects=a group's terminal moves into a workroom open in another window, and the
  /// group, left empty, goes; fails_when=only workroom panes move to workrooms, or an emptied named
  /// group stays listed; why_new=#660, and the owner's "a group goes with its last terminal";
  /// seam=AppStore pair; no_claim=none.
  func testAGroupsTerminalMovesToAnotherWindowsWorkroom() async throws {
    let first = makeWindow()
    let second = makeWindow()
    let group = try XCTUnwrap(first.newTerminalGroup(named: "Servers"))
    let from = try target(first, group)
    let pane = try XCTUnwrap(first.terminals.tabs(for: from).first)
    let into = try target(second, sidB)
    _ = second.terminals.addTab(for: into)

    let groups = first.paneMoveChoices(pane.id, of: from, windows: [first, second])
    let choice = try XCTUnwrap(groups.last?.choices.first)
    XCTAssertEqual(choice.title, second.title(for: sidB, separator: WorkroomLabel.separator))
    choice.move()
    await settle { second.terminals.tab(pane.id, for: into) != nil }

    XCTAssertNotNil(second.terminals.tab(pane.id, for: into))
    await section.regroupsSettled()
    XCTAssertNil(first.terminalGroup(group), "its last terminal moved out: the group goes")
  }

  /// Value: protects=a named group whose last terminal is dragged out to a workroom in the same
  /// window goes, and one left with a terminal stays; fails_when=an emptied named group stays
  /// listed, or one still holding a terminal goes; why_new=the owner's "a group goes with its last
  /// terminal"; seam=AppStore's drop; no_claim=hit-testing the pointer.
  func testDraggingAGroupsLastTerminalOutDeletesTheGroup() async throws {
    let window = makeWindow()
    let group = try XCTUnwrap(window.newTerminalGroup(named: "Servers"))
    let from = try target(window, group)
    window.newTerminalInSelectedTarget()
    let panes = window.terminals.tabs(for: from).map(\.id)

    let first = await window.dropPane(panes[0], of: from, on: .target(sidA))
    await section.regroupsSettled()
    XCTAssertTrue(first)
    XCTAssertNotNil(window.terminalGroup(group), "one terminal left: it stays")

    let last = await window.dropPane(panes[1], of: from, on: .target(sidA))
    await section.regroupsSettled()

    XCTAssertTrue(last)
    XCTAssertNil(window.terminalGroup(group), "its last terminal moved out: the group goes")
    XCTAssertEqual(window.terminals.tabCount(forTargetID: try target(window, sidA).id), 2)
  }

  /// Value: protects=a failed retag leaves no new standalone or group row behind; fails_when=the
  /// row is made before the move and kept when it fails; why_new=#660; seam=AppStore;
  /// no_claim=the alert.
  func testAFailedMoveLeavesNoRowBehind() async throws {
    let window = makeWindow(retag: false)
    let (pane, from) = try paneInA(window)
    window.terminals.giveSession(UUID(), toTab: pane.id, in: from)

    let standalone = await window.movePaneToStandalone(
      pane.id, of: from, source: window.terminals, notifications: registry.notifications)
    let group = await window.movePaneToNewGroup(
      named: "Logs", pane.id, of: from, source: window.terminals,
      notifications: registry.notifications)

    XCTAssertFalse(standalone)
    XCTAssertFalse(group)
    XCTAssertTrue(rows.isEmpty)
    XCTAssertNotNil(window.terminals.tab(pane.id, for: from))
  }

  // MARK: Dropping a tab

  /// Value: protects=a tab dropped on the Terminals heading becomes standalone, on a group's row
  /// joins it, and on a workroom's row or title-bar tab moves there (AC 3); fails_when=a zone is
  /// not a destination; why_new=#660; seam=AppStore; no_claim=hit-testing the pointer.
  func testDroppingATabOnEachKindOfZoneMovesIt() async throws {
    let window = makeWindow()
    let group = try XCTUnwrap(window.newTerminalGroup(named: "Servers"))
    let (pane, from) = try paneInA(window)
    let second = window.terminals.addTab(for: from)
    let third = window.terminals.addTab(for: from)

    let toHeading = await window.dropPane(pane.id, of: from, on: .standalone)
    let toGroup = await window.dropPane(second.id, of: from, on: .target(group))
    let toWorkroom = await window.dropPane(third.id, of: from, on: .target(sidB))

    XCTAssertEqual([toHeading, toGroup, toWorkroom], [true, true, true])
    let standalone = try XCTUnwrap(rows.first { if case .standalone = $0 { true } else { false } })
    XCTAssertNotNil(window.terminals.tab(pane.id, for: try target(window, standalone)))
    XCTAssertNotNil(window.terminals.tab(second.id, for: try target(window, group)))
    XCTAssertNotNil(window.terminals.tab(third.id, for: try target(window, sidB)))
  }

  /// Value: protects=a tab dropped on its own place stays; fails_when=a drop on its own row or tab
  /// moves or duplicates it; why_new=#660; seam=AppStore; no_claim=none.
  func testATabDroppedOnItsOwnPlaceStays() async throws {
    let window = makeWindow()
    let (pane, from) = try paneInA(window)

    let onOwn = await window.dropPane(pane.id, of: from, on: .target(sidA))

    XCTAssertFalse(onOwn)
    XCTAssertNotNil(window.terminals.tab(pane.id, for: from))
  }

  // MARK: Dropping a tab on a standalone terminal

  /// Whether `sid` is a group under the name the drop asked for (`TerminalGroupNaming`).
  private func isNamedGroup(_ sid: SidebarID) -> Bool {
    guard case .terminalGroup = sid, let id = sid.targetID, let group = section.group(id)
    else { return false }
    return group.name == "Group 1"
  }

  /// Value: protects=a workroom's terminal tab dropped on a standalone terminal's row or title-bar
  /// tab makes a group of the two, under the name asked for, in the standalone terminal's place, its terminal first
  /// (#652 story 21); fails_when=the drop is refused, the standalone terminal gets a second tab,
  /// or the group lands elsewhere; why_new=#659 had not landed when #660 refused it;
  /// seam=AppStore; no_claim=hit-testing the pointer.
  func testATabDroppedOnAStandaloneTerminalMakesAGroupWithIt() async throws {
    let window = makeWindow()
    window.newStandaloneTerminal()
    let held = try XCTUnwrap(window.selectedTargetID)
    window.newStandaloneTerminal()
    let other = try XCTUnwrap(window.selectedTargetID)
    let heldTab = try XCTUnwrap(window.terminals.allTabs(for: try target(window, held)).first)
    let (pane, from) = try paneInA(window)

    let dropped = await window.dropPane(pane.id, of: from, on: .target(held))

    XCTAssertTrue(dropped)
    let group = try XCTUnwrap(rows.first)
    XCTAssertTrue(isNamedGroup(group), "\(rows)")
    XCTAssertEqual(rows, [group, other], "in the standalone terminal's place")
    XCTAssertEqual(
      window.terminals.tabs(for: try target(window, group)).map(\.id), [heldTab.id, pane.id])
    XCTAssertNil(window.terminals.tab(pane.id, for: from))
  }

  /// Value: protects=a standalone terminal's tab dropped on another standalone terminal groups the
  /// two as dropping its row does; fails_when=its own row stays behind; why_new=#652;
  /// seam=AppStore; no_claim=hit-testing the pointer.
  func testAStandaloneTerminalsTabDroppedOnAnotherGroupsThem() async throws {
    let window = makeWindow()
    window.newStandaloneTerminal()
    let onto = try XCTUnwrap(window.selectedTargetID)
    window.newStandaloneTerminal()
    let moving = try XCTUnwrap(window.selectedTargetID)
    let from = try target(window, moving)
    let ontoTab = try XCTUnwrap(window.terminals.allTabs(for: try target(window, onto)).first)
    let pane = try XCTUnwrap(window.terminals.allTabs(for: from).first)

    let dropped = await window.dropPane(pane.id, of: from, on: .target(onto))

    XCTAssertTrue(dropped)
    let group = try XCTUnwrap(rows.first)
    XCTAssertTrue(isNamedGroup(group), "\(rows)")
    XCTAssertEqual(rows, [group], "the dropped terminal's row goes")
    XCTAssertEqual(
      window.terminals.tabs(for: try target(window, group)).map(\.id), [ontoTab.id, pane.id])
  }

  /// Value: protects=a tab whose session can't be retagged, dropped on a standalone terminal,
  /// stays where it was and the standalone terminal is as it was; fails_when=a one-terminal group
  /// is left behind, the row comes back as another terminal, or the tab is lost; why_new=#652;
  /// seam=AppStore; no_claim=none.
  func testATabThatCannotBeRetaggedLeavesTheStandaloneTerminalAlone() async throws {
    let window = makeWindow(retag: false)
    window.newStandaloneTerminal()
    let held = try XCTUnwrap(window.selectedTargetID)
    let heldTab = try XCTUnwrap(window.terminals.allTabs(for: try target(window, held)).first)
    let from = try target(window, sidA)
    let pane = window.terminals.addTab(for: from, sessionID: UUID())
    window.selectedTargetID = sidA

    let dropped = await window.dropPane(pane.id, of: from, on: .target(held))
    await section.regroupsSettled()

    XCTAssertFalse(dropped)
    XCTAssertEqual(rows, [held])
    XCTAssertEqual(window.terminals.tabs(for: try target(window, held)).map(\.id), [heldTab.id])
    XCTAssertNotNil(window.terminals.tab(pane.id, for: from))
  }

  /// Value: protects=only a terminal moves: a file tab dropped on the Terminals heading or a
  /// workroom's row stays, and becomes no standalone terminal; fails_when=the drag zones take any
  /// tab; why_new=#660; seam=AppStore; no_claim=none.
  func testAFileTabDroppedOnAZoneStays() async throws {
    let window = makeWindow()
    let (_, from) = try paneInA(window)
    window.openFilePreview(path: "/p/a/README.md", for: from)
    let file = try XCTUnwrap(
      window.terminals.tabs(for: from).first { if case .file = $0.content { true } else { false } })

    let toHeading = await window.dropPane(file.id, of: from, on: .standalone)
    let toWorkroom = await window.dropPane(file.id, of: from, on: .target(sidB))

    XCTAssertFalse(toHeading)
    XCTAssertFalse(toWorkroom)
    XCTAssertTrue(rows.isEmpty)
    XCTAssertNotNil(window.terminals.tab(file.id, for: from))
  }

  // MARK: Remote workrooms

  /// Value: protects=moves into a remote workroom are listed disabled with why, and such a drop is
  /// refused (AC 4); fails_when=a remote workroom is offered or accepts a local shell;
  /// why_new=#660; seam=AppStore; no_claim=the tooltip's rendering.
  func testARemoteWorkroomIsNoDestination() async throws {
    let window = makeWindow()
    let (pane, from) = try paneInA(window)
    let far = try target(window, remote)
    window.workroomTabOrder = [from.id, far.id]
    _ = window.terminals.addTab(for: far)

    let workrooms = window.paneMoveChoices(pane.id, of: from, windows: [window]).dropFirst()
    let choice = try XCTUnwrap(
      workrooms.flatMap(\.choices).first {
        $0.title == window.title(for: remote, separator: WorkroomLabel.separator)
      })
    let dropped = await window.dropPane(pane.id, of: from, on: .target(remote))

    XCTAssertFalse(choice.enabled)
    XCTAssertEqual(
      choice.help,
      "\(far.title) runs on a host, so a terminal on this Mac can't move into it.")
    XCTAssertFalse(dropped)
    XCTAssertNotNil(window.terminals.tab(pane.id, for: from))
  }

  /// Value: protects=a terminal in a remote workroom can't move anywhere: every choice disabled
  /// with why, and a drop or a direct move is refused (AC 4); fails_when=a remote shell is retagged
  /// as a local target's; why_new=#660; seam=AppStore; no_claim=the tooltip's rendering.
  func testATerminalInARemoteWorkroomMovesNowhere() async throws {
    let window = makeWindow()
    let far = try target(window, remote)
    let pane = window.terminals.addTab(for: far)
    _ = try paneInA(window)

    let choices = window.paneMoveChoices(pane.id, of: far, windows: [window]).flatMap(\.choices)
    let dropped = await window.dropPane(pane.id, of: far, on: .standalone)
    let moved = await PaneMove.move(
      pane.id, of: far, source: window.terminals, notifications: registry.notifications,
      to: window, into: try XCTUnwrap(sidA.targetID))

    XCTAssertFalse(choices.isEmpty)
    XCTAssertTrue(choices.allSatisfy { !$0.enabled })
    XCTAssertTrue(
      choices.allSatisfy {
        $0.help == "This terminal runs on a host, so it can't move to this Mac."
      })
    XCTAssertFalse(dropped)
    XCTAssertFalse(moved)
    XCTAssertTrue(rows.isEmpty)
    XCTAssertNotNil(window.terminals.tab(pane.id, for: far))
  }

  // MARK: A standalone terminal's row menu

  /// Value: protects=a standalone terminal's row menu acts on the window holding its terminal, from
  /// any window drawing the row (AC 5); fails_when=the menu acts on the drawing window, which has
  /// no such tab; why_new=#660; seam=AppStore pair; no_claim=the menu's rendering.
  func testAStandaloneRowsMenuActsOnTheWindowHoldingIt() throws {
    let holder = makeWindow()
    let other = makeWindow()
    holder.newStandaloneTerminal()
    let sid = try XCTUnwrap(holder.selectedTargetID)

    let fromOther = try XCTUnwrap(other.standaloneTerminal(sid))
    let fromHolder = try XCTUnwrap(holder.standaloneTerminal(sid))

    XCTAssertTrue(fromOther.holder === holder)
    XCTAssertTrue(fromHolder.holder === holder)
    XCTAssertEqual(fromOther.tab.id, fromHolder.tab.id)
    XCTAssertNil(other.standaloneTerminal(sidA), "only a standalone terminal's row")
  }
}
