import AppKit
import DaemonConnection
import WorkroomDomain
import XCTest

@testable import Workroom

/// A standalone terminal is one terminal, so one window holds it at a time (#656, ADR 0077):
/// selecting it where it is not takes you to it, closing its window asks first and ends it, and it
/// pops out and notifies as a workroom's terminal does. Two windows share one Terminals section, as
/// they share one project list.
@MainActor
final class StandaloneAcrossWindowsTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  /// Windows the stores are hosted in, kept alive since a store holds its window weakly.
  private var windows: [NSWindow] = []

  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    let window = NSWindow()
    windows.append(window)
    store.hostWindow = window
    registry.register(window: window, store: store)
    return store
  }

  /// A window holding a standalone terminal, and its id.
  private func makeHolder() throws -> (store: AppStore, sid: SidebarID, id: TargetID) {
    let store = makeStore()
    store.newStandaloneTerminal()
    let sid = try XCTUnwrap(store.selectedTargetID)
    return (store, sid, try XCTUnwrap(sid.targetID))
  }

  // MARK: Raise

  /// Value: protects=a standalone terminal is never duplicated by selecting it elsewhere;
  /// fails_when=the second window opens a shell of its own for the same row; why_new=#656;
  /// seam=two AppStores over one section; no_claim=the sidebar view's tap
  func testSelectingItInAnotherWindowRaisesTheHolderAndOpensNoTerminal() throws {
    let (holder, sid, id) = try makeHolder()
    let other = makeStore()
    var raised: [NSWindow] = []
    holder.raiseWindow = { raised.append($0) }

    other.selectedTargetID = sid
    other.ensureInitialTerminal(for: try XCTUnwrap(other.target(for: sid)))

    XCTAssertEqual(
      raised, [try XCTUnwrap(holder.hostWindow)], "the window that holds it comes forward")
    XCTAssertEqual(holder.selectedTargetID, sid)
    XCTAssertNil(other.selectedTargetID, "the window that doesn't hold it stays where it was")
    XCTAssertEqual(other.terminals.tabCount(forTargetID: id), 0, "no second terminal")
    XCTAssertEqual(holder.terminals.tabCount(forTargetID: id), 1)
  }

  /// Value: protects=selecting a popped-out standalone terminal in another window raises the
  /// pane's own window (#664 review 4643636571); fails_when=the holder's main window comes forward
  /// instead; why_new=#664 review; seam=two AppStores over one section; no_claim=the window's
  /// activation
  func testSelectingItWhenPoppedOutRaisesThePanesWindow() throws {
    let (holder, sid, _) = try makeHolder()
    let target = try XCTUnwrap(holder.target(for: sid))
    let tab = try XCTUnwrap(holder.terminals.focusedTab(for: target))
    holder.terminals.detachPane(tab.id, for: target, at: .zero)
    let paneWindow = try XCTUnwrap(holder.detachedPanes.window(for: tab.id))
    let other = makeStore()
    var raised: [NSWindow] = []
    holder.raiseWindow = { raised.append($0) }

    other.selectedTargetID = sid
    other.ensureInitialTerminal(for: try XCTUnwrap(other.target(for: sid)))

    XCTAssertEqual(raised, [paneWindow], "the popped-out pane's window comes forward")
    paneWindow.orderOut(nil)
  }

  /// The holder focuses the terminal, also when it was showing something else.
  func testTheHolderShowsTheTerminalWhenItWasOnAnotherTarget() throws {
    let (holder, sid, _) = try makeHolder()
    holder.newStandaloneTerminal()
    XCTAssertNotEqual(holder.selectedTargetID, sid)
    let other = makeStore()
    other.selectedTargetID = .root(project: "/nowhere")
    let stayed = other.selectedTargetID

    other.selectedTargetID = sid

    XCTAssertEqual(holder.selectedTargetID, sid)
    XCTAssertEqual(other.selectedTargetID, stayed)
  }

  /// A workroom is not one terminal: each window keeps its own in it (ADR 0069).
  func testAWorkroomIsStillSelectedInEveryWindow() {
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
    let first = makeStore()
    let second = makeStore()
    let workroom = SidebarID.workroom(project: "/p", name: "a")
    first.selectedTargetID = workroom
    first.newTerminalInSelectedTarget()

    second.selectedTargetID = workroom

    XCTAssertEqual(second.selectedTargetID, workroom)
  }

  /// Once the holder lets go of it, selecting it elsewhere takes it: a terminal handed to this
  /// window is its own.
  func testMovingItToAnotherWindowMakesThatWindowTheHolder() throws {
    let (holder, sid, id) = try makeHolder()
    holder.newStandaloneTerminal()
    let other = makeStore()

    holder.moveWorkroom(sid, to: other)

    XCTAssertEqual(other.selectedTargetID, sid)
    XCTAssertEqual(other.terminals.tabCount(forTargetID: id), 1)
    XCTAssertEqual(holder.terminals.tabCount(forTargetID: id), 0)
  }

  // MARK: Closing the window

  /// Value: protects=a window's standalone terminal is not lost to a stray close; fails_when=the
  /// window closes silently with a shell in it; why_new=#656; seam=AppStore's close prompt;
  /// no_claim=the alert's look
  func testAWindowHoldingAStandaloneTerminalAsksBeforeClosing() throws {
    let (holder, _, _) = try makeHolder()
    let plain = makeStore()

    XCTAssertNotNil(holder.windowClosePrompt)
    XCTAssertNil(plain.windowClosePrompt)
  }

  /// Confirming the close ends the terminal, and its row goes. Another window's terminal is left.
  func testConfirmingTheCloseEndsTheTerminalAndDropsItsRow() async throws {
    let (holder, sid, id) = try makeHolder()
    holder.newStandaloneTerminal()
    let kept = try XCTUnwrap(holder.selectedTargetID)
    let other = makeStore()
    other.newStandaloneTerminal()
    let otherSid = try XCTUnwrap(other.selectedTargetID)

    await holder.endStandaloneTerminalsOnClose()

    XCTAssertEqual(holder.terminals.tabCount(forTargetID: id), 0)
    XCTAssertFalse(section.contains(id))
    XCTAssertFalse(section.contains(try XCTUnwrap(kept.targetID)), "every one it held")
    XCTAssertEqual(section.entries.map(\.sidebarID), [otherSid], "and only those: \(sid)")
  }

  /// A quit takes the windows down too, and must keep the rows for the next launch.
  func testAQuitsCloseKeepsTheRows() async throws {
    let (holder, sid, _) = try makeHolder()
    WindowRegistry.shared.isTerminating = true
    defer { WindowRegistry.shared.isTerminating = false }

    await holder.endStandaloneTerminalsOnClose()

    XCTAssertEqual(section.entries.map(\.sidebarID), [sid])
  }

  // MARK: Pop out, notifications

  /// Value: protects=a standalone terminal gets Pop Out like a workroom's; fails_when=the pane
  /// stays in the strip; why_new=#656; seam=AppStore; no_claim=the window's chrome
  func testItPopsOutIntoAWindowOfItsOwn() throws {
    let (holder, sid, _) = try makeHolder()
    let tab = try XCTUnwrap(
      holder.terminals.focusedTab(for: try XCTUnwrap(holder.target(for: sid))))

    holder.terminals.detachPane(
      tab.id, for: try XCTUnwrap(holder.target(for: sid)), at: .zero)

    XCTAssertTrue(holder.terminals.detachedTabIDs.contains(tab.id))
    XCTAssertTrue(
      section.terminalNames(of: try XCTUnwrap(sid.targetID)).count == 1,
      "a popped-out terminal still holds its row")
  }

  /// Value: protects=a notification from a standalone terminal opens it wherever it is;
  /// fails_when=the click selects it in the front window, opening a second shell;
  /// why_new=#656; seam=WindowRegistry.open; no_claim=the banner
  func testANotificationOpensTheTerminalInTheWindowThatHoldsIt() throws {
    let (holder, sid, id) = try makeHolder()
    let front = makeStore()
    let tab = try XCTUnwrap(
      holder.terminals.focusedTab(for: try XCTUnwrap(holder.target(for: sid))))
    holder.newStandaloneTerminal()
    XCTAssertNotEqual(holder.selectedTargetID, sid)

    registry.open(targetID: id, tabID: tab.id, notifID: nil)

    XCTAssertEqual(holder.selectedTargetID, sid)
    XCTAssertNil(front.selectedTargetID)
    XCTAssertEqual(front.terminals.tabCount(forTargetID: id), 0)
  }

  // MARK: Marks

  /// A group with one terminal in `holder`, attached to a session whose program waits on the user
  /// as `monitor` reports it, and that terminal.
  private func waitingGroup(in holder: AppStore, monitor: ProgramStatusMonitor) throws -> (
    sid: SidebarID, tab: TerminalTab.ID
  ) {
    holder.terminals.programStatus = monitor
    let sid = try XCTUnwrap(holder.newTerminalGroup(named: "Servers"))
    let session = UUID()
    let tab = holder.terminals.addTab(
      for: try XCTUnwrap(holder.target(for: sid)), sessionID: session)
    monitor.seed(
      session, records: [ProgramStatusRecord(id: "", state: .blocked, kind: .question, episode: 1)])
    return (sid, tab.id)
  }

  /// Value: protects=a terminal with no project tells you it needs you from any window (story 13);
  /// fails_when=a row reads only the terminals of the window drawing it; why_new=#652 review P3;
  /// seam=two AppStores over one section; no_claim=the row's drawing (SidebarInvalidationTests)
  func testARowShowsTheMarksOfTerminalsHeldInAnotherWindow() throws {
    let (holder, standaloneSid, standalone) = try makeHolder()
    let other = makeStore()
    let tabs = holder.terminals.tabs(for: try XCTUnwrap(holder.target(for: standaloneSid)))
    let surface = try XCTUnwrap(holder.terminals.surface(try XCTUnwrap(tabs.first)))
    let (groupSid, _) = try waitingGroup(in: holder, monitor: ProgramStatusMonitor())
    let group = try XCTUnwrap(groupSid.targetID)

    surface.handleProgressReport(true)

    XCTAssertEqual(other.terminals.tabCount(forTargetID: standalone), 0, "held in the holder")
    XCTAssertTrue(other.sectionActivity(of: standalone).running, "its agent working shows")
    XCTAssertEqual(other.sectionActivity(of: group).waiting, 1, "the group's waiting one shows")
  }

  /// Value: protects=the waiting mark on a row is a live control in every window; fails_when=its
  /// click looks only in the window drawing it, so it does nothing; why_new=#652 review P3;
  /// seam=two AppStores over one section; no_claim=the button itself
  func testItsWaitingMarkTakesYouToTheTerminalInTheWindowHoldingIt() throws {
    let holder = makeStore()
    let other = makeStore()
    let (sid, tab) = try waitingGroup(in: holder, monitor: ProgramStatusMonitor())
    let id = try XCTUnwrap(sid.targetID)
    // A second, newer terminal, focused: the mark must move the focus to the waiting one.
    let target = try XCTUnwrap(holder.target(for: sid))
    _ = holder.terminals.addTab(for: target)
    var raised: [NSWindow] = []
    holder.raiseWindow = { raised.append($0) }

    other.showWaiting(inSectionTarget: id)

    XCTAssertEqual(raised, [try XCTUnwrap(holder.hostWindow)], "the holder comes forward")
    XCTAssertEqual(holder.selectedTargetID, sid)
    XCTAssertEqual(holder.terminals.focusedTab(for: target)?.id, tab, "on the waiting terminal")
  }

  /// Its row reports what a workroom's row does: a terminal waiting on the user, and a command that
  /// failed.
  func testItsRowCarriesTheSameMarksAsAWorkroomRow() throws {
    let holder = makeStore()
    // A pane with a session of its own, which is what program status is reported against.
    holder.terminals.sessionService = PersistentSessionService.shared
    holder.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    holder.newStandaloneTerminal()
    let sid = try XCTUnwrap(holder.selectedTargetID)
    let id = try XCTUnwrap(sid.targetID)
    let tab = try XCTUnwrap(
      holder.terminals.focusedTab(for: try XCTUnwrap(holder.target(for: sid))))

    guard case .terminal(let state) = tab.content, let session = state.sessionID else {
      return XCTFail("no session")
    }
    XCTAssertEqual(holder.sidebarActivity(of: id), SidebarTargetActivity())
    holder.terminals.programStatus.seed(
      session, records: [ProgramStatusRecord(id: "", state: .blocked, kind: .question, episode: 1)])

    XCTAssertEqual(holder.sidebarActivity(of: id).waiting, 1)
  }
}
