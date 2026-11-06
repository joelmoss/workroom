import AppKit
import DaemonConnection
import WorkroomDomain
import WorkroomWire
import XCTest

@testable import Workroom

/// Moving a workroom from one window to another (issue #444). The terminals travel live: the same
/// tab ids and the same surfaces, so nothing restarts and no history is repainted. What these pin is
/// that everything the window it leaves knew about the workroom goes with it, and that nothing of it
/// keeps answering to the old window.
@MainActor
final class WorkroomHandOverTests: XCTestCase {
  private let shared = ProjectStore()
  /// The windows, and the app's one notification list they share (ADR 0064).
  private let registry = WindowRegistry()
  private var notifications: NotificationCenterStore { registry.notifications }
  private let notifier = WithdrawingNotifier()
  private let sid = SidebarID.workroom(project: "/p", name: "a")
  private let otherSid = SidebarID.workroom(project: "/p", name: "b")

  override func setUp() {
    super.setUp()
    shared.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: ["a", "b", "c"].map {
          Workroom(name: $0, path: "/p/\($0)", vcsName: "workroom/\($0)", warnings: [])
        })
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: shared, notifications: notifications)
    store.services.notifier = notifier
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    return store
  }

  /// A window with a terminal open in the other workroom, so the one under test is not its only
  /// workroom, which never moves.
  private func makeOrigin() -> AppStore {
    let store = makeStore()
    _ = store.terminals.addTab(for: target(store, otherSid))
    return store
  }

  private func target(_ store: AppStore, _ sid: SidebarID? = nil) -> TerminalTarget {
    store.target(for: sid ?? self.sid)!
  }

  // MARK: The tabs themselves

  /// The whole point of a live hand-over: the destination holds the very same tabs and surfaces, in
  /// the same order, split and focus, and the origin holds none of them.
  func testTheSameLiveTabsArriveWithTheirLayout() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let first = origin.terminals.addTab(for: t)
    let second = origin.terminals.addTab(for: t)
    let third = origin.terminals.addTab(for: t)
    origin.terminals.splitTab(third.id, on: .right, for: t)
    let splits = origin.terminals.splits(for: t)
    let focused = origin.terminals.focusedTab(for: t)?.id

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(origin.terminals.tabCount(forTargetID: t.id), 0)
    XCTAssertEqual(
      destination.terminals.normalizedTabIDs(forTargetID: t.id).count, 4,
      "three tabs and the pane the split made")
    XCTAssertEqual(
      destination.terminals.allTabs(for: t).prefix(2).map(\.id), [first.id, second.id],
      "the same tab ids, in the same order")
    XCTAssertTrue(
      destination.terminals.tab(first.id, for: t)?.surface === first.surface,
      "the same surface, not a new one reattached")
    XCTAssertEqual(destination.terminals.splits(for: t), splits)
    XCTAssertEqual(destination.terminals.focusedTab(for: t)?.id, focused)
    XCTAssertEqual(destination.selectedTargetID, sid, "the moved workroom is selected")
    XCTAssertFalse(destination.pendingSessionRecovery, "fresh tabs need no restore recovery")
  }

  func testPendingRestoredAttachmentsFollowAMove() {
    let origin = makeOrigin()
    let destination = makeStore()
    origin.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated handover test") }, ownership: { _ in .notOwned })
    let t = target(origin)
    origin.terminals.restore(
      TargetSession(
        targetID: t.id.encoded,
        tabs: [
          TabSession(
            key: "hidden", kind: TabSession.terminalKind,
            terminal: TerminalPayload(defaultTitle: "Terminal 1", sessionID: UUID().uuidString))
        ]),
      for: t)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertTrue(
      destination.pendingSessionRecovery, "the new owner must finish hidden attachments")
    XCTAssertFalse(
      destination.hasDisplayedWindow, "recovery still waits for the destination display")
    XCTAssertEqual(origin.terminals.tabCount(forTargetID: t.id), 0)
    XCTAssertEqual(destination.terminals.tabCount(forTargetID: t.id), 1)
  }

  /// A surface reports to the window that holds it now. Left wired to the origin, a moved
  /// terminal's title (and focus, exits, activity) would go to a window that no longer has it.
  func testAMovedSurfaceReportsToTheDestination() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)

    origin.moveWorkroom(sid, to: destination)
    tab.surface?.handleTitleChange("vim notes.md")

    XCTAssertEqual(destination.terminals.tab(tab.id, for: t)?.title, "vim notes.md")
    XCTAssertNotNil(tab.surface?.onEvent, "a hand-over never tears the surface down")
  }

  /// Value: protects=a move ends no session, so its programs keep running (Q2); fails_when=the
  /// hand-off starts ending sessions as a close does; why_new=no test watched the session service
  /// across a move; seam=none; no_claim=local sessions (a remote pane stands in: its end is the one
  /// the service reports).
  func testAMoveEndsNoSessionWhereACloseWould() async throws {
    var ended: [UUID] = []
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "none here") }, ownership: { _ in .notOwned },
      endRemote: { session, _ in
        ended.append(session)
        return true
      })
    let (from, to) = (TerminalSessions(), TerminalSessions())
    for sessions in [from, to] {
      sessions.sessionService = service
      sessions.makeView = { _, cwd, command in
        GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
      }
      sessions.recordUnrecognizedTool = { _ in }
      sessions.recency = SwitcherRecency()
    }
    var t = TerminalTarget(
      id: .workroom(project: "/r", name: "remote-\(UUID())"), title: "r", path: "/r",
      isMissing: false)
    t.remoteHost = UUID()
    let tab = from.addTab(for: t)
    let session = try XCTUnwrap(from.sessionID(forTab: tab.id, inTarget: t.id))

    to.adopt(try XCTUnwrap(from.handOff(t)))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(ended, [], "a move ends no session")

    // The control: closing it does end it, so the check above can see an end.
    to.closeTab(tab.id, for: t)
    for _ in 0..<40 where ended.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(ended, [session])
  }

  /// Into a window that already shows the workroom, the moved terminals come after its own, and its
  /// own layout stays (Q12).
  func testIntoAWindowShowingTheWorkroomTheTabsJoinItsOwn() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let moved = origin.terminals.addTab(for: t)
    let own = destination.terminals.addTab(for: t)
    let ownSplit = destination.terminals.addTab(for: t)
    destination.terminals.splitTab(ownSplit.id, on: .right, for: t)
    let layout = destination.terminals.splits(for: t)

    origin.moveWorkroom(sid, to: destination)

    let ids = destination.terminals.normalizedTabIDs(forTargetID: t.id)
    XCTAssertEqual(ids.first, own.id)
    XCTAssertEqual(ids.last, moved.id, "after the window's own tabs")
    XCTAssertEqual(destination.terminals.splits(for: t), layout, "its own layout stays")
  }

  // MARK: Run command

  /// A live run tab and its bookkeeping move, and its supervisor's exit reaches the new window.
  /// Value (T2 of the 2026-11 architecture plan): protects=a moved run tab whose child then exits
  /// still reports its run's end, so the run is not shown running forever; fails_when=the surface's
  /// events stay with the window it left (adopt stops re-wiring it); why_new=the run's exit used to be
  /// a closure window moves overwrote; seam=none; no_claim=a real supervisor's timing.
  func testARunningRunCommandMovesAndItsExitReachesTheDestination() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    let run = origin.terminals.addRunTab(for: t, command: "sleep 1000", cwd: "/p/a", focus: false)
    origin.runCommand.runStates[t.id] = .running(tab: run.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertNil(origin.runCommand.runStates[t.id])
    XCTAssertEqual(
      destination.runCommand.runStates[t.id], .running(tab: run.id, interrupted: false))
    run.surface?.onEvent?(.childExited(0))
    XCTAssertEqual(
      destination.runCommand.runStates[t.id], .stopped(tab: run.id),
      "the exit was the destination's to hear")
  }

  /// Value: protects=a window's own run, replaced by the running run moved in over it (Q12) and
  /// still stopping, ending its process without ending the moved run; fails_when=a run-tab exit
  /// ends the target's run whichever tab it came from; why_new=the merge used to clear that tab's
  /// exit closure by hand, now the exit's tab is matched; seam=none; no_claim=the stop's timing.
  func testAReplacedRunsExitDoesNotEndTheRunMovedInOverIt() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let moved = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runCommand.runStates[t.id] = .running(tab: moved.id, interrupted: false)
    let replaced = destination.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    destination.runCommand.runStates[t.id] = .running(tab: replaced.id, interrupted: false)
    // Its supervisor is still up, so its close waits for it to exit.
    replaced.surface?.liveProcessOverrideForTesting = true

    origin.moveWorkroom(sid, to: destination)
    XCTAssertNotNil(destination.terminals.tab(replaced.id, for: t), "still stopping")
    replaced.surface?.liveProcessOverrideForTesting = false
    replaced.surface?.onEvent?(.childExited(0))

    XCTAssertEqual(
      destination.runCommand.runStates[t.id], .running(tab: moved.id, interrupted: false))
    XCTAssertNil(destination.runCommand.runOutcomes[t.id], "the moved run has not ended")
  }

  /// A run's state comes with its session's program status to whichever window holds its tab
  /// (#522), so once the run moves the destination hears it and the origin, which no longer
  /// holds the run, changes nothing.
  func testTheDestinationHearsAMovedRunsStatus() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let run = origin.terminals.addRunTab(
      for: t, command: "sleep 1000", cwd: "/p/a", focus: false, runSession: true)
    origin.runCommand.runStates[t.id] = .running(tab: run.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)
    origin.terminals.onEvent?(.runStatus(t.id, run.id, "stopped"))
    XCTAssertNil(origin.runCommand.runStates[t.id])
    destination.terminals.onEvent?(.runStatus(t.id, run.id, "stopped"))

    XCTAssertEqual(destination.runCommand.runStates[t.id], .stopped(tab: run.id))
    XCTAssertEqual(destination.runCommand.runOutcomes[t.id], .stoppedByUser)
  }

  /// Of two run tabs for one workroom, the running one stays and a stopped one closes (Q12).
  func testIntoAWindowWithAStoppedRunTheMovedRunningOneWins() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let running = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runCommand.runStates[t.id] = .running(tab: running.id, interrupted: false)
    let stopped = destination.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    destination.runCommand.runStates[t.id] = .stopped(tab: stopped.id)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(
      destination.runCommand.runStates[t.id], .running(tab: running.id, interrupted: false))
    XCTAssertNil(destination.terminals.tab(stopped.id, for: t), "the stopped run tab closed")
  }

  func testAMovedStoppedRunClosesBesideTheDestinationsRunningOne() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let stopped = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runCommand.runStates[t.id] = .stopped(tab: stopped.id)
    let running = destination.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    destination.runCommand.runStates[t.id] = .running(tab: running.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(
      destination.runCommand.runStates[t.id], .running(tab: running.id, interrupted: false))
    XCTAssertNil(destination.terminals.tab(stopped.id, for: t))
  }

  /// Value: protects=a run toast whose timer was pending when the workroom moved still hides in the
  /// new window; fails_when=the hand-off cancels the timer and nothing restarts it; why_new=nothing
  /// checked toast timers across a move; seam=none (the store's existing scheduleRunToastDismiss);
  /// no_claim=the toast's rendering.
  func testAPendingRunToastTimerStartsAgainInTheDestination() {
    let origin = makeOrigin()
    let destination = makeStore()
    var delays: [TimeInterval] = []
    destination.runCommand.scheduleRunToastDismiss = { delay, _ in
      delays.append(delay)
      return DispatchWorkItem {}
    }
    let t = target(origin)
    let run = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runCommand.runStates[t.id] = .running(tab: run.id, interrupted: false)
    origin.runCommand.runToastDismissWork[t.id] = DispatchWorkItem {}

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(delays.count, 1, "the destination starts the running toast's auto-hide")
    XCTAssertNotNil(destination.runCommand.runToastDismissWork[t.id])
  }

  // MARK: What else moves

  /// Value: protects=a failed command's coding-agent banner travels with its terminal, and a
  /// diagnosis cut short by the move comes back as the Diagnose offer; fails_when=the hand-off drops
  /// the manager's state as a close does; why_new=no test covered agent state across a move;
  /// seam=none; no_claim=the banner's rendering and a real diagnosis run.
  func testACodingAgentBannerMovesWithItsTerminal() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)
    let failure = FailedCommand(
      command: "make", cwd: "/p/a", exitCode: 2, shell: "zsh", output: "boom", isRunTab: false,
      isRemote: false)
    origin.terminals.codingAgentManager.adopt(tab.id, banner: .loading(failure), failure: failure)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertNil(origin.terminals.codingAgentManager.banners[tab.id])
    XCTAssertEqual(
      destination.terminals.codingAgentManager.banners[tab.id], .awaitingDiagnose(failure),
      "the diagnosis the move cancelled is offered again")
  }

  /// Value: protects=a remote workroom whose host is still being asked for its layout stays put;
  /// fails_when=canMoveWorkroom stops consulting hostLayouts.fetching, so the answer restores the
  /// workroom into the old window beside the moved terminals; why_new=no guard test covered it;
  /// seam=none; no_claim=a real host's fetch.
  func testAWorkroomWhoseHostLayoutIsStillBeingFetchedDoesNotMove() {
    let origin = makeOrigin()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    XCTAssertTrue(origin.canMoveWorkroom(sid))

    origin.hostLayouts.fetching.insert(t.id)

    XCTAssertFalse(origin.canMoveWorkroom(sid))
  }

  func testNotificationsMoveStillUnread() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)
    origin.notifications.record(
      targetID: t.id, tabID: tab.id, activity: .osc(title: "done", body: nil), focused: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(destination.notifications.count(tab: tab.id), 1, "a move keeps them unread")
  }

  // MARK: Opening and closing across windows (#573)

  /// Value: protects=opening a notification in the window that has its pane, not the one showing the
  /// row (decision 1); fails_when=a surface opens through its own store again; why_new=only the banner
  /// path resolved the owner; seam=none; no_claim=window raise on screen.
  func testOpeningANotificationGoesToTheWindowThatHasItsPane() {
    let a = makeOrigin()
    let b = makeStore()
    registry.register(window: NSWindow(), store: a)
    registry.register(window: NSWindow(), store: b)
    let t = target(b)
    let tab = b.terminals.addTab(for: t)
    let note = notifications.record(
      targetID: t.id, tabID: tab.id, activity: .osc(title: "done", body: nil), focused: false)!

    registry.open(note)

    XCTAssertEqual(b.selectedTargetID, sid, "the window with the pane opens it")
    XCTAssertNotEqual(a.selectedTargetID, sid, "the front window does not")
    XCTAssertTrue(notifications.items.isEmpty, "opening dismisses it")
  }

  /// Value: protects=a banner a Quick Terminal pane raised before it moved into a window opens the
  /// pane there, not the Quick Terminal (whose payload it still names); fails_when=open routes on
  /// the payload's Quick Terminal target before asking who has the tab; why_new=found in /ship's
  /// Codex review of PR #577; seam=none; no_claim=the delivered banner itself.
  func testABannerFromAMovedQuickTerminalPaneOpensItInItsWindow() async {
    let (quick, pane, window) = makeQuickTerminalMove()
    let other = makeStore()
    registry.register(window: NSWindow(), store: other)
    registry.register(window: NSWindow(), store: window)
    await quick.moveQuickTerminalPane(
      pane.id, of: QuickTerminalController.target(), to: window, into: sid)
    window.selectedTargetID = otherSid

    registry.open(targetID: QuickTerminalController.targetID, tabID: pane.id, notifID: nil)

    XCTAssertEqual(window.selectedTargetID, sid, "the window with the pane opens its workroom")
    XCTAssertEqual(window.terminals.focusedTab(for: target(window))?.id, pane.id)
  }

  /// Value: protects=the front-window fallback for a pane no window has, and a gone workroom's row
  /// going (decision 1); fails_when=open does nothing or leaves the row; why_new=new path;
  /// seam=none; no_claim=window raise on screen.
  func testANotificationWhosePaneIsGoneOpensItsWorkroomInTheFrontWindow() {
    let a = makeStore()
    registry.register(window: NSWindow(), store: a)
    let t = target(a)
    let note = notifications.record(
      targetID: t.id, tabID: UUID(), activity: .osc(title: "done", body: nil), focused: false)!
    let gone = notifications.record(
      targetID: .root(project: "/deleted"), tabID: UUID(), activity: .osc(title: "x", body: nil),
      focused: false)!

    registry.open(note)
    XCTAssertEqual(a.selectedTargetID, sid)
    registry.open(gone)

    XCTAssertTrue(notifications.items.isEmpty, "both rows go once opened")
  }

  /// Value: protects=closing a window removes every notification it raised, from open panes, closed
  /// panes and notices, with their banners (#573 D3); fails_when=only live tabs are matched or another
  /// window's rows go; why_new=new behaviour; seam=none; no_claim=UNUserNotificationCenter.
  func testClosingAWindowRemovesEverythingItRaised() {
    let a = makeOrigin()
    let b = makeStore()
    let windowA = NSWindow()
    registry.register(window: windowA, store: a)
    registry.register(window: NSWindow(), store: b)
    let t = target(a)
    let open = a.terminals.addTab(for: t)
    a.raiseFinished(targetID: t.id, tabID: open.id, record: .init(id: "", state: .idle))
    a.raiseFinished(targetID: t.id, tabID: UUID(), record: .init(id: "", state: .idle))
    a.noticeStaleStart(of: t.id, "fetch failed")
    b.raiseFinished(
      targetID: target(b, otherSid).id, tabID: UUID(), record: .init(id: "", state: .idle))

    registry.unregister(window: windowA)

    XCTAssertEqual(notifications.items.count, 1, "only the other window's notification stays")
    XCTAssertEqual(notifications.items.first?.origin, ObjectIdentifier(b))
    XCTAssertTrue(notifier.withdrawn.contains(open.id.uuidString), "its banners go too")
  }

  /// Value: protects=windows closing during a quit leaving the list and delivered banners alone;
  /// fails_when=dropNotifications loses its isTerminating guard; why_new=the close test runs only
  /// outside a quit; seam=none; no_claim=UNUserNotificationCenter.
  func testClosingAWindowDuringAQuitLeavesItsNotifications() {
    let a = makeOrigin()
    let windowA = NSWindow()
    registry.register(window: windowA, store: a)
    let t = target(a)
    let tab = a.terminals.addTab(for: t)
    a.raiseFinished(targetID: t.id, tabID: tab.id, record: .init(id: "", state: .idle))
    registry.isTerminating = true

    registry.unregister(window: windowA)

    XCTAssertEqual(notifications.count(tab: tab.id), 1)
    XCTAssertFalse(notifier.withdrawn.contains(tab.id.uuidString))
  }

  /// Value: protects=a moved workroom's notifications going with it, so the old window's close leaves
  /// them (#573 D3), and only the ones its old window raised; fails_when=repoint is dropped or
  /// matches the wrong target or window; why_new=new behaviour;
  /// seam=none; no_claim=dragging the workroom on screen.
  func testAMovedWorkroomsNotificationsCloseWithItsNewWindow() {
    let origin = makeOrigin()
    let destination = makeStore()
    let windowOrigin = NSWindow()
    let windowDestination = NSWindow()
    registry.register(window: windowOrigin, store: origin)
    registry.register(window: windowDestination, store: destination)
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)
    origin.raiseFinished(targetID: t.id, tabID: tab.id, record: .init(id: "", state: .idle))
    // A third window showing the same workroom, whose notification is not part of the move.
    let other = makeOrigin()
    registry.register(window: NSWindow(), store: other)
    let otherTab = UUID()
    other.raiseFinished(targetID: t.id, tabID: otherTab, record: .init(id: "", state: .idle))

    origin.moveWorkroom(sid, to: destination)
    registry.unregister(window: windowOrigin)
    XCTAssertEqual(notifications.count(tab: tab.id), 1, "the old window's close leaves it")
    registry.unregister(window: windowDestination)
    XCTAssertEqual(notifications.count(tab: tab.id), 0, "its new window's close takes it")
    XCTAssertEqual(notifications.count(tab: otherTab), 1, "another window's own stays with it")
  }

  /// Value: protects=a toast showing in the front window, whichever window raised it (#573);
  /// fails_when=a toast lands in the raising window again; why_new=new behaviour; seam=none;
  /// no_claim=the toast's rendering.
  func testAToastShowsInTheFrontWindow() {
    let front = makeStore()
    let behind = makeOrigin()
    registry.register(window: NSWindow(), store: front)
    registry.register(window: NSWindow(), store: behind)
    behind.isAppActive = { true }

    behind.raiseFinished(
      targetID: target(behind, otherSid).id, tabID: UUID(), record: .init(id: "", state: .idle))

    XCTAssertEqual(front.toasts.count, 1)
    XCTAssertTrue(behind.toasts.isEmpty)
  }

  func testAWorkroomInASplitLeavesTheGroupItCameFrom() {
    let origin = makeOrigin()
    let destination = makeStore()
    _ = origin.terminals.addTab(for: target(origin))
    _ = origin.terminals.addTab(for: target(origin, otherSid))
    origin.selectedTargetID = otherSid
    origin.insertWorkroomSplit(
      sid, beside: otherSid, edge: .right,
      destinationRect: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertFalse(origin.workroomSplits.isEmpty, "precondition: the two are in a split")

    origin.moveWorkroom(sid, to: destination)

    XCTAssertTrue(origin.workroomSplits.isEmpty, "a group of one is no group")
    XCTAssertTrue(destination.workroomSplits.isEmpty, "it arrives on its own")
  }

  /// A torn-off pane goes with its workroom and stays torn off, its window now the destination's.
  func testATornOffPaneMovesStillInItsOwnWindow() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    let torn = origin.terminals.addTab(for: t)
    origin.terminals.detachPane(torn.id, for: t, at: .zero)
    XCTAssertNotNil(origin.detachedPanes.window(for: torn.id), "precondition: it has a window")
    defer { destination.detachedPanes.closeAll() }

    origin.moveWorkroom(sid, to: destination)

    XCTAssertNil(origin.detachedPanes.window(for: torn.id))
    XCTAssertNotNil(destination.detachedPanes.window(for: torn.id))
    XCTAssertTrue(destination.terminals.detachedTabIDs.contains(torn.id))
  }

  // MARK: When a move applies

  /// A window's only workroom never moves, by drag or menu: it would leave an empty window behind.
  /// The second one can, and the first then can too.
  func testAWindowsOnlyWorkroomDoesNotMove() {
    let origin = makeStore()
    let destination = makeStore()
    let tab = origin.terminals.addTab(for: target(origin))
    XCTAssertFalse(origin.canMoveWorkroom(sid))

    origin.moveWorkroom(sid, to: destination)
    XCTAssertTrue(origin.terminals.containsTab(tab.id), "it stays where it is")
    XCTAssertFalse(destination.terminals.containsTab(tab.id))

    _ = origin.terminals.addTab(for: target(origin, otherSid))
    XCTAssertTrue(origin.canMoveWorkroom(sid))
  }

  func testAWorkroomWithNoTerminalsHereDoesNotMove() {
    let origin = makeOrigin()
    let destination = makeStore()
    XCTAssertFalse(origin.canMoveWorkroom(sid))

    origin.moveWorkroom(sid, to: destination)

    XCTAssertNil(destination.selectedTargetID)
  }

  /// A new window carries only the request's id and pulls the workroom when it is up, so a window
  /// that never appears moves nothing.
  func testAHandOffRequestMovesTheWorkroomOnlyWhenTheWindowCompletesIt() {
    let origin = makeOrigin()
    let destination = makeStore()
    let tab = origin.terminals.addTab(for: target(origin))
    let id = WorkroomHandOffs.shared.request(
      .init(origin: origin, sid: sid, topLeft: CGPoint(x: 10, y: 20)))
    XCTAssertEqual(WorkroomHandOffs.shared.request(for: id)?.topLeft, CGPoint(x: 10, y: 20))
    XCTAssertTrue(origin.terminals.containsTab(tab.id), "nothing moves until the window is up")

    WorkroomHandOffs.shared.complete(id, into: destination)

    XCTAssertTrue(destination.terminals.containsTab(tab.id))
    XCTAssertNil(WorkroomHandOffs.shared.request(for: id), "a request completes once")
  }

  // MARK: Gaps closed in the coverage audit

  /// Value: protects=a workroom is never moved out from under a create that is still setting it up
  /// (Q18); fails_when=canMoveWorkroom stops consulting isCreationBlocking; why_new=the other
  /// guard tests only cover "no terminals" and "only workroom"; seam=none; no_claim=the menu
  /// item's disabled rendering.
  func testAWorkroomStillBeingCreatedDoesNotMove() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)
    origin.creationRunForTarget[t.id] = UUID()
    defer { origin.creationRunForTarget[t.id] = nil }

    XCTAssertFalse(origin.canMoveWorkroom(sid))
    origin.moveWorkroom(sid, to: destination)

    XCTAssertTrue(origin.terminals.containsTab(tab.id), "it stays where it is")
    XCTAssertFalse(destination.terminals.containsTab(tab.id))
  }

  /// Value: protects=the pane's own right-click "Move to New Window" / "Move Back to Main Window"
  /// reaching the store and toggling that pane; fails_when=wire() stops setting onEvent, the
  /// event is not routed, or togglePaneWindow picks the wrong branch; why_new=no test drives the
  /// toggle at all; seam=none; no_claim=the AppKit menu item's title and shortcut.
  func testAPanesWindowToggleDetachesThenDocksIt() {
    let store = makeStore()
    let t = target(store)
    _ = store.terminals.addTab(for: t)
    let pane = store.terminals.addTab(for: t)
    defer { store.detachedPanes.closeAll() }

    pane.surface?.onEvent?(.windowToggleRequested)
    XCTAssertTrue(store.terminals.detachedTabIDs.contains(pane.id), "first toggle tears it off")
    XCTAssertNotNil(store.detachedPanes.window(for: pane.id))

    pane.surface?.onEvent?(.windowToggleRequested)
    XCTAssertFalse(store.terminals.detachedTabIDs.contains(pane.id), "second toggle docks it")
  }

  /// Value: protects=where a dropped workroom's tab lands (Q21); fails_when=placeWorkroomTab
  /// ignores the index or the nil-means-end rule; why_new=the slot maths is tested but not that
  /// the destination's tab order honours it; seam=none; no_claim=the drag gap animation.
  func testAMovedWorkroomsTabLandsAtTheDropSlotOrTheEnd() {
    // Each destination already shows `sid`, so the moved `otherSid` lands before it only if the
    // index is honoured, and after it when there is none.
    let atSlot = makeStore()
    _ = atSlot.terminals.addTab(for: target(atSlot))
    let atEnd = makeStore()
    _ = atEnd.terminals.addTab(for: target(atEnd))
    let origin = makeOrigin()
    _ = origin.terminals.addTab(for: target(origin))
    let origin2 = makeOrigin()
    _ = origin2.terminals.addTab(for: target(origin2))

    origin.moveWorkroom(otherSid, to: atSlot, at: 0)
    XCTAssertEqual(atSlot.displayedWorkroomTargets().map(\.sid), [otherSid, sid])

    origin2.moveWorkroom(otherSid, to: atEnd)
    XCTAssertEqual(atEnd.displayedWorkroomTargets().map(\.sid), [sid, otherSid], "nil: at the end")
  }

  /// Value: protects=a drop on a window that already shows the workroom lands under the cursor;
  /// fails_when=the slot, which counted that window's own tab of it, is used unchanged after the tab
  /// is lifted out (one slot right of the cursor); why_new=the slot tests had no merge; seam=none;
  /// no_claim=the drag gap.
  func testADropOnAWindowShowingTheWorkroomLandsUnderTheCursor() {
    let destination = makeStore()
    let third = SidebarID.workroom(project: "/p", name: "c")
    for sid in [sid, otherSid, third] {
      _ = destination.terminals.addTab(for: target(destination, sid))
    }
    XCTAssertEqual(destination.displayedWorkroomTargets().map(\.sid), [sid, otherSid, third])
    let origin = makeOrigin()
    _ = origin.terminals.addTab(for: target(origin))

    // Dropped between b and c: slot 2, counting the window's own `a` at 0.
    origin.moveWorkroom(sid, to: destination, at: 2)

    XCTAssertEqual(destination.displayedWorkroomTargets().map(\.sid), [otherSid, sid, third])
  }

  /// Value: protects=a workroom keeps at most one preview tab when two windows' copies merge;
  /// fails_when=the moved preview arrives still a preview beside the window's own, so the next
  /// Changes/Files click retargets an arbitrary one; why_new=merges were tested with terminals only;
  /// seam=none; no_claim=the inspector's clicks.
  func testAMergeKeepsOnePreviewAndPinsTheMovedOne() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    let moved = origin.terminals.openFilePreview(
      FileDescriptor(path: "a.swift", isPreview: true), for: t)
    _ = destination.terminals.addTab(for: t)
    let own = destination.terminals.openFilePreview(
      FileDescriptor(path: "b.swift", isPreview: true), for: t)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(
      destination.terminals.tab(own, for: t)?.isPreview, true, "its own stays the preview")
    XCTAssertEqual(
      destination.terminals.tab(moved, for: t)?.isPreview, false, "the moved one is pinned")
  }

  /// Value: protects=find closes with the selected workroom's content pane leaving, rather than
  /// lingering in the old window with a stale query; fails_when=the hand-off leaves it open (its
  /// silent focus clear skips the focus-change close); why_new=find was never checked across a move;
  /// seam=none; no_claim=the find bar's rendering.
  func testMovingTheSelectedWorkroomClosesItsFind() {
    let origin = makeOrigin()
    let destination = makeStore()
    _ = origin.terminals.addTab(for: target(origin))
    origin.selectedTargetID = sid
    origin.contentFind.open()

    origin.moveWorkroom(sid, to: destination)

    XCTAssertFalse(origin.contentFind.isOpen)
  }

  /// Value: protects=a moved terminal's next finished-turn notification replaces its last one rather
  /// than adding a second; fails_when=the finish index lives with a window again; why_new=only the
  /// notifications themselves were checked; seam=none; no_claim=a finish raised by a real program.
  func testAMovedTerminalsNextFinishReplacesItsLastOne() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)
    origin.raiseFinished(targetID: t.id, tabID: tab.id, record: .init(id: "", state: .idle))

    origin.moveWorkroom(sid, to: destination)
    destination.raiseFinished(targetID: t.id, tabID: tab.id, record: .init(id: "", state: .idle))

    XCTAssertEqual(notifications.count(tab: tab.id), 1, "the second finish replaced the first")
  }

  /// Value: protects=the run toast state and investigate tabs travelling with the workroom, a
  /// moved investigate tab's exit clearing it in the new window, (flags only travel with a run, the only
  /// thing they describe); fails_when=takeHandOff/adopt drop a field or
  /// adopt stops re-wiring the moved surfaces' events; why_new=existing tests cover run state and
  /// merge rules only, not the toast flags or investigate tabs; seam=none; no_claim=the toast UI.
  func testToastFlagsAndInvestigateTabsMoveWithTheRun() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    let probe = origin.terminals.addTab(for: t)
    origin.runCommand.investigateTabs[probe.id] = t.id
    origin.runCommand.dismissedRunToasts.insert(t.id)
    origin.runCommand.runningToastAutoHidden.insert(t.id)
    let run = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runCommand.runStates[t.id] = .running(tab: run.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertFalse(origin.runCommand.dismissedRunToasts.contains(t.id))
    XCTAssertFalse(origin.runCommand.runningToastAutoHidden.contains(t.id))
    XCTAssertNil(origin.runCommand.investigateTabs[probe.id])
    XCTAssertEqual(destination.runCommand.investigateTabs[probe.id], t.id)
    XCTAssertTrue(destination.runCommand.dismissedRunToasts.contains(t.id))
    XCTAssertTrue(destination.runCommand.runningToastAutoHidden.contains(t.id))
    probe.surface?.onEvent?(.childExited(0))
    XCTAssertNil(
      destination.runCommand.investigateTabs[probe.id], "its exit is the destination's to hear")
  }

  // MARK: Remote host layout

  /// The keeping of a remote workroom's host layout moves with it, with what the origin knew of the
  /// host's copy. Left with the origin, its next save would write the emptied workroom as an empty
  /// layout over the host's.
  func testARemoteWorkroomsHostLayoutKeepingMoves() {
    let origin = makeOrigin()
    let destination = makeStore()
    var t = TerminalTarget(
      id: .workroom(project: "/r", name: "remote-\(UUID())"), title: "r", path: "/r",
      isMissing: false)
    let workroom = UUID()
    t.remoteHost = UUID()
    t.remoteWorkroomID = workroom
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroom, targetID: t.id, by: origin))
    origin.hostLayouts.fetched.insert(t.id)
    origin.hostLayouts.revisions[t.id] = 7
    origin.hostLayouts.written[t.id] = "blob"

    origin.handHostLayout(of: t, to: destination)

    XCTAssertTrue(HostLayoutOwners.shared.owns(workroom, destination))
    XCTAssertFalse(origin.hostLayouts.fetched.contains(t.id))
    XCTAssertNil(origin.hostLayouts.written[t.id])
    XCTAssertTrue(destination.hostLayouts.fetched.contains(t.id))
    XCTAssertEqual(destination.hostLayouts.revisions[t.id], 7)
    XCTAssertEqual(destination.hostLayouts.written[t.id], "blob")
  }

  /// A write already on its way when the workroom moves finishes into the origin; the destination
  /// waits for it and takes the revision it left, rather than writing at a stale one.
  func testAnInFlightHostWriteFinishesBeforeTheDestinationTakesOver() async {
    let origin = makeOrigin()
    let destination = makeStore()
    var t = TerminalTarget(
      id: .workroom(project: "/r", name: "remote-\(UUID())"), title: "r", path: "/r",
      isMissing: false)
    let workroom = UUID()
    t.remoteHost = UUID()
    t.remoteWorkroomID = workroom
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroom, targetID: t.id, by: origin))
    origin.hostLayouts.fetched.insert(t.id)
    origin.hostLayouts.revisions[t.id] = 7
    // The host never answered this launch: the destination must keep that guard while it waits.
    origin.hostLayouts.unanswered.insert(t.id)
    let (gate, open) = AsyncStream<Void>.makeStream()
    origin.hostLayouts.writing[t.id] = Task {
      for await _ in gate { break }
    }

    origin.handHostLayout(of: t, to: destination)
    XCTAssertNotNil(destination.hostLayouts.writing[t.id], "the destination waits on it")
    XCTAssertNil(destination.hostLayouts.revisions[t.id])
    XCTAssertTrue(
      destination.hostLayouts.unanswered.contains(t.id),
      "a quit meanwhile must not mark its copy as the newer one")
    // The write lands, in the origin, as `finishHostWrite` records it.
    origin.hostLayouts.revisions[t.id] = 8
    origin.hostLayouts.writing[t.id] = nil
    open.yield()
    open.finish()
    await destination.hostLayouts.writing[t.id]?.value

    XCTAssertEqual(destination.hostLayouts.revisions[t.id], 8)
    XCTAssertNil(origin.hostLayouts.revisions[t.id])
    XCTAssertNil(destination.hostLayouts.writing[t.id])
  }

  // MARK: Where a drop lands

  func testADropOverTheTabRowLandsInTheSlotUnderTheCursor() {
    let frames = [
      CGRect(x: 100, y: 8, width: 120, height: 24), CGRect(x: 224, y: 8, width: 120, height: 24),
    ]
    XCTAssertEqual(AppStore.workroomTabSlot(at: CGPoint(x: 90, y: 20), frames: frames), 0)
    XCTAssertEqual(AppStore.workroomTabSlot(at: CGPoint(x: 230, y: 20), frames: frames), 1)
    XCTAssertEqual(AppStore.workroomTabSlot(at: CGPoint(x: 400, y: 20), frames: frames), 2)
    XCTAssertNil(
      AppStore.workroomTabSlot(at: CGPoint(x: 230, y: 300), frames: frames),
      "off the tab row it goes at the end")
    XCTAssertNil(AppStore.workroomTabSlot(at: CGPoint(x: 230, y: 20), frames: []))
  }

  /// Value: protects=the gap a drop shows is where the tab lands, never inside a split group's run
  /// (which would regroup it to the far side); fails_when=a slot between two grouped tabs is kept;
  /// why_new=slot maths had no groups; seam=none; no_claim=the gap animation.
  func testADropSlotInsideASplitGroupMovesToItsNearerEdge() {
    // Tabs: solo, [group 0, group 0, group 0], solo.
    let groups: [Int?] = [nil, 0, 0, 0, nil]
    XCTAssertEqual(AppStore.workroomTabSlot(1, outside: groups), 1, "before the group")
    XCTAssertEqual(AppStore.workroomTabSlot(2, outside: groups), 1, "nearer its start")
    XCTAssertEqual(AppStore.workroomTabSlot(3, outside: groups), 4, "nearer its end")
    XCTAssertEqual(AppStore.workroomTabSlot(4, outside: groups), 4, "after the group")
    XCTAssertEqual(AppStore.workroomTabSlot(5, outside: groups), 5)
    XCTAssertEqual(AppStore.workroomTabSlot(1, outside: [0, 0]), 0, "a group at the start")
  }

  /// Value: protects=a drop on another window's tab bar lands in the slot under the cursor;
  /// fails_when=the screen point is mapped into the wrong space (the window's, not the tab row's)
  /// or the y flip is lost; why_new=only the pure slot maths was tested; seam=none; no_claim=a real
  /// title-bar accessory's layout (a plain window and view stand in).
  func testAScreenPointMapsOntoTheTabRowItIsOver() {
    let store = makeStore()
    _ = store.terminals.addTab(for: target(store))
    _ = store.terminals.addTab(for: target(store, otherSid))
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 600, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: true)
    let row = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    window.contentView?.addSubview(row)
    store.workroomTabRun = row
    let order = store.displayedWorkroomTargets().map(\.sid)
    store.workroomTabFrames = [
      order[0]: CGRect(x: 10, y: 8, width: 120, height: 24),
      order[1]: CGRect(x: 134, y: 8, width: 120, height: 24),
    ]

    // Row top-left is screen (100, 200): 20pt down the row is screen y 180, and 80pt down (off the
    // tabs) is 120. Asymmetric on purpose, so a lost y flip reads one as the other.
    XCTAssertEqual(store.incomingWorkroomSlot(at: CGPoint(x: 105, y: 180)), 0)
    XCTAssertEqual(store.incomingWorkroomSlot(at: CGPoint(x: 240, y: 180)), 1)
    XCTAssertEqual(store.incomingWorkroomSlot(at: CGPoint(x: 600, y: 180)), 2)
    XCTAssertNil(
      store.incomingWorkroomSlot(at: CGPoint(x: 240, y: 120)), "off the tabs: at the end")
  }

  /// Value: protects=a moved workroom's window opens at the standard size with its top-left at the
  /// drop point, whatever window it left; fails_when=the size or the placement is dropped or taken
  /// from the old window; why_new=nothing checked the new window's frame; seam=none;
  /// no_claim=SwiftUI's own placement after show (the re-application is what covers that).
  func testAMovedWorkroomsWindowOpensAtTheStandardSizeWhereItWasDropped() throws {
    let store = makeStore()
    let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    let drop = CGPoint(x: screen.minX + 40, y: screen.maxY - 40)
    store.pendingInitialWindowTopLeft = drop

    store.placeHandOffWindow(window)

    XCTAssertEqual(
      window.contentRect(forFrameRect: window.frame).size, AppStore.newWindowContentSize)
    XCTAssertEqual(window.frame.minX, drop.x, accuracy: 1)
    XCTAssertEqual(window.frame.maxY, drop.y, accuracy: 1)
  }

  // MARK: A Quick Terminal pane into a window

  /// The Quick Terminal's store and its one pane, and a window with workroom `a` selected and open.
  private func makeQuickTerminalMove(
    retag: ((UUID, String) async -> Bool)? = nil
  ) -> (quick: AppStore, pane: TerminalTab, window: AppStore) {
    let quick = makeStore()
    quick.terminals.allowsDetach = false
    quick.terminals.moveToWorkroomChoices = { _, _ in [] }
    quick.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned }, retag: retag)
    let pane = quick.terminals.addTab(for: QuickTerminalController.target())
    let window = makeStore()
    _ = window.terminals.addTab(for: target(window))
    window.selectedTargetID = sid
    return (quick, pane, window)
  }

  /// Value: protects=a Quick Terminal pane joins the workroom the window shows, live, as its newest
  /// tab, and leaves the Quick Terminal; fails_when=the hand-off reattaches, lands elsewhere or leaves
  /// a copy behind; why_new=new path; seam=none; no_claim=window raise on screen.
  func testAQuickTerminalPaneJoinsTheWorkroomTheWindowShows() async {
    let (quick, pane, window) = makeQuickTerminalMove()
    let t = target(window)
    var emptied = false
    quick.onTargetEmptied = { _ in emptied = true }

    await quick.moveQuickTerminalPane(
      pane.id, of: QuickTerminalController.target(), to: window, into: sid)

    XCTAssertEqual(quick.terminals.tabCount(forTargetID: QuickTerminalController.targetID), 0)
    XCTAssertTrue(emptied, "its last pane leaving closes the Quick Terminal")
    XCTAssertTrue(
      window.terminals.tab(pane.id, for: t)?.surface === pane.surface, "the same surface")
    XCTAssertEqual(window.terminals.allTabs(for: t).last?.id, pane.id, "after the workroom's own")
    XCTAssertEqual(window.terminals.focusedTab(for: t)?.id, pane.id)
    XCTAssertEqual(
      pane.surface?.sessionMetadata.first { $0.key == SessionMetadataKey.workroom }?.value,
      t.sessionWorkroomKey, "a reattach names its new workroom")
    pane.surface?.handleTitleChange("vim")
    XCTAssertEqual(window.terminals.tab(pane.id, for: t)?.title, "vim", "it reports to the window")
    XCTAssertNil(pane.surface?.moveToWorkroomChoices, "no Move to Workroom once it is a workroom's")
  }

  /// Value: protects=the shell is retagged as the workroom's before it moves, and a refusal moves
  /// nothing (a moved shell still tagged as the Quick Terminal's would be ended at the next launch);
  /// fails_when=the move skips or ignores the retag; why_new=new path; seam=the retag answer;
  /// no_claim=the daemon's own handling (vcs/crates/workroomd tests).
  func testAPaneMovesOnlyOnceItsShellIsTheWorkroomsAndStaysWhenThatFails() async {
    var asked: [(UUID, String)] = []
    var answer = false
    let (quick, pane, window) = makeQuickTerminalMove { session, workroom in
      asked.append((session, workroom))
      return answer
    }
    let session = UUID()
    pane.surface?.persistentSessionID = session
    let quickTarget = QuickTerminalController.target()

    await quick.moveQuickTerminalPane(pane.id, of: quickTarget, to: window, into: sid)

    XCTAssertEqual(asked.map(\.0), [session])
    XCTAssertEqual(asked.first?.1, target(window).sessionWorkroomKey)
    XCTAssertEqual(quick.terminals.tabCount(forTargetID: quickTarget.id), 1, "refused: it stays")
    XCTAssertNotNil(window.modals.errorMessage, "and the window says why")

    answer = true
    await quick.moveQuickTerminalPane(pane.id, of: quickTarget, to: window, into: sid)
    XCTAssertEqual(quick.terminals.tabCount(forTargetID: quickTarget.id), 0)
    XCTAssertNotNil(window.terminals.tab(pane.id, for: target(window)))
  }

  /// Value: protects=a workroom that can't take a Quick Terminal pane (gone, on a host, being
  /// created) takes none, and the pane stays; fails_when=the gate goes; why_new=new path;
  /// seam=none; no_claim=the menu's disabled rendering.
  func testAWorkroomThatCannotTakeAPaneTakesNone() async {
    let (quick, pane, window) = makeQuickTerminalMove()
    let gone = SidebarID.workroom(project: "/p", name: "gone")

    await quick.moveQuickTerminalPane(
      pane.id, of: QuickTerminalController.target(), to: window, into: gone)

    XCTAssertNil(window.quickTerminalPaneTarget(gone))
    XCTAssertEqual(quick.terminals.tabCount(forTargetID: QuickTerminalController.targetID), 1)
  }

  /// Value: protects=the Move to Workroom list offers a workroom whose create is in flight but
  /// disabled, beside the window's ordinary workroom, enabled; fails_when=the choice's enabled flag
  /// ignores the gate; why_new=the choice path was only covered through the target gate; seam=none;
  /// no_claim=the menu's disabled rendering, or a host's workroom.
  func testAWorkroomBeingCreatedIsListedDisabledForAQuickTerminalPane() {
    let (quick, pane, window) = makeQuickTerminalMove()
    _ = window.terminals.addTab(for: target(window, otherSid))
    window.creationRunForTarget[target(window, otherSid).id] = UUID()

    let choices = quick.quickTerminalPaneWorkroomChoices(
      pane.id, of: QuickTerminalController.target(), windows: [window]
    ).flatMap(\.choices)

    XCTAssertEqual(choices.map(\.enabled), [true, false], "a, then b (being created)")
  }

  /// Value: protects=a drop on a window with workrooms side by side picks the workroom drawn under
  /// the pointer, laid out as the renderer lays them out (its pane space's offset included);
  /// fails_when=the hit-test ignores the offset or the split; why_new=new path; seam=none;
  /// no_claim=screen-to-window conversion (needs a real window).
  func testADropPicksTheWorkroomDrawnUnderThePointer() {
    let layout = PaneLayout<SidebarID>.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(sid), second: .leaf(otherSid))
    let space = CGRect(x: 10, y: 50, width: 800, height: 600)

    XCTAssertEqual(AppStore.workroom(at: CGPoint(x: 100, y: 300), in: layout, space: space), sid)
    XCTAssertEqual(
      AppStore.workroom(at: CGPoint(x: 700, y: 300), in: layout, space: space), otherSid)
    XCTAssertNil(
      AppStore.workroom(at: CGPoint(x: 700, y: 20), in: layout, space: space),
      "above the panes (the tab bar): none, so the selected one takes it")
  }

  /// Value: protects=a pane dropped on a split's other workroom joins that one, which then has the
  /// focus; fails_when=the move ignores the drop's workroom; why_new=owner asked 2026-11-04;
  /// seam=the destination resolved, not the screen point (needs a real window); no_claim=geometry.
  func testAPaneMovedIntoAnotherWorkroomOfTheWindowFocusesIt() async {
    let (quick, pane, window) = makeQuickTerminalMove()
    let other = target(window, otherSid)

    await quick.moveQuickTerminalPane(
      pane.id, of: QuickTerminalController.target(), to: window, into: otherSid)

    XCTAssertNotNil(window.terminals.tab(pane.id, for: other))
    XCTAssertEqual(window.selectedTargetID, otherSid)
  }

  /// Value: protects=the "Move to Workroom" icon draws both its symbols at every scale, with the
  /// arrow's ring cut out of the terminal; fails_when=a symbol name stops resolving (an empty image)
  /// or the cut-out stops clearing; why_new=a composed image; seam=none; no_claim=how it looks.
  func testTheMoveToWorkroomIconDrawsATerminalWithAnArrow() throws {
    try assertBadgedIcon(.moveTerminal)
    try assertBadgedIcon(.moveToNewWindow)
  }

  private func assertBadgedIcon(_ icon: NSImage) throws {
    XCTAssertTrue(icon.isTemplate)
    XCTAssertEqual(icon.representations.count, 3)
    let rep = try XCTUnwrap(icon.representations.compactMap { $0 as? NSBitmapImageRep }.last)
    func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    // Bitmap rows run top-down: the arrow badge is bottom-right, the terminal's top-left corner
    // stroke top-left.
    XCTAssertGreaterThan(alpha(w - 3 * 7 / 2, h - 3 * 7 / 2), 0.5, "the arrow badge")
    XCTAssertGreaterThan(
      (0..<w / 3).map { alpha($0, h / 2) }.max() ?? 0, 0.5, "the terminal's left side")
  }

  /// Value: protects="Move to Workroom" lists every workroom open in every window, each window's in
  /// its tab order under the window's name, and moves into the one chosen in its own window;
  /// fails_when=it lists only selected workrooms or one window, or moves to the wrong window;
  /// why_new=owner asked 2026-11-04; seam=the window list; no_claim=menu rendering.
  func testMoveToWorkroomListsEveryOpenWorkroomInEveryWindow() async {
    let (quick, pane, first) = makeQuickTerminalMove()
    _ = first.terminals.addTab(for: target(first, otherSid))
    let second = makeStore()
    let third = SidebarID.workroom(project: "/p", name: "c")
    _ = second.terminals.addTab(for: target(second, third))
    second.selectedTargetID = third
    let quickTarget = QuickTerminalController.target()

    let groups = quick.quickTerminalPaneWorkroomChoices(
      pane.id, of: quickTarget, windows: [first, second])

    XCTAssertEqual(groups.map(\.choices.count), [2, 1], "the unselected `b` too")
    XCTAssertEqual(
      groups.map(\.header), [first.defaultWindowTitle, second.defaultWindowTitle],
      "two windows: each named")
    XCTAssertEqual(
      groups.first?.choices.map(\.title), [first.title(for: sid), first.title(for: otherSid)])
    XCTAssertNil(
      quick.quickTerminalPaneWorkroomChoices(pane.id, of: quickTarget, windows: [first]).first?
        .header, "one window: no header")

    groups[1].choices[0].move()
    for _ in 0..<50 where second.terminals.tab(pane.id, for: target(second, third)) == nil {
      await Task.yield()
    }
    XCTAssertNotNil(second.terminals.tab(pane.id, for: target(second, third)))
    XCTAssertNil(first.terminals.tab(pane.id, for: target(first)))
  }

  /// Value: protects=an Investigate tab moved out of the Quick Terminal stays an Investigate session
  /// in its workroom, so deleting the workroom still asks first (#146), and its exit still ends it;
  /// fails_when=the move drops the registration or leaves the exit wired to the Quick Terminal;
  /// why_new=found in /ship review of PR #577; seam=none; no_claim=the delete prompt's rendering.
  func testAMovedInvestigateTabStaysAnInvestigateSession() async {
    let (quick, pane, window) = makeQuickTerminalMove()
    quick.runCommand.investigateTabs[pane.id] = QuickTerminalController.targetID

    await quick.moveQuickTerminalPane(
      pane.id, of: QuickTerminalController.target(), to: window, into: sid)

    XCTAssertNil(quick.runCommand.investigateTabs[pane.id])
    XCTAssertEqual(
      window.runCommand.investigateTabs[pane.id], target(window).id,
      "what WindowRegistry.hasLiveInvestigateSession reads before a delete")
    pane.surface?.onEvent?(.childExited(0))
    XCTAssertNil(window.runCommand.investigateTabs[pane.id], "its exit ends it there")
  }

  /// Value: protects=a moved pane's notifications follow it, so opening one finds the pane in its
  /// new window and closing the Quick Terminal doesn't drop them; fails_when=repoint is skipped or
  /// runs after the Quick Terminal closes; why_new=new path; seam=none; no_claim=banner text.
  func testAMovedPanesNotificationsFollowIt() async {
    let (quick, pane, window) = makeQuickTerminalMove()
    let quickTarget = QuickTerminalController.target()
    quick.notifications.record(
      targetID: quickTarget.id, tabID: pane.id, activity: .osc(title: "done", body: nil),
      focused: false, origin: ObjectIdentifier(quick))

    await quick.moveQuickTerminalPane(pane.id, of: quickTarget, to: window, into: sid)
    registry.dropNotifications(raisedBy: quick)

    let moved = notifications.items.filter { $0.tabID == pane.id }
    XCTAssertEqual(moved.count, 1, "closing the Quick Terminal leaves it")
    XCTAssertEqual(moved.first?.targetID, target(window).id)
    XCTAssertEqual(moved.first?.origin, ObjectIdentifier(window))
  }

  /// Value: protects=a workroom that goes while the daemon is asked to retag leaves the shell the
  /// Quick Terminal's again (retagged back) and the pane in place; fails_when=the check after the
  /// wait or the retag back goes (the shell would stay tagged to a workroom that no longer exists);
  /// why_new=the only path through the post-await guard; seam=the retag answer;
  /// no_claim=the daemon's own handling (vcs/crates/workroomd tests).
  func testAWorkroomGoneWhileTheShellIsRetaggedGivesTheShellBack() async {
    var asked: [String] = []
    let (quick, pane, window) = makeQuickTerminalMove { _, workroom in
      asked.append(workroom)
      if asked.count == 1 { self.shared.projects = [] }
      return true
    }
    pane.surface?.persistentSessionID = UUID()
    let quickTarget = QuickTerminalController.target()
    let key = target(window).sessionWorkroomKey

    await quick.moveQuickTerminalPane(pane.id, of: quickTarget, to: window, into: sid)

    XCTAssertEqual(asked, [key, quickTarget.sessionWorkroomKey], "tagged, then given back")
    XCTAssertEqual(quick.terminals.tabCount(forTargetID: quickTarget.id), 1, "the pane stays")
  }

  /// Value: protects=moving one of several Quick Terminal panes leaves the rest in place with the
  /// focus on a neighbour, and the Quick Terminal open; fails_when=the hand-off leaves the moved tab
  /// in the order or focus, or empties the target; why_new=the other test moves a lone pane;
  /// seam=none; no_claim=window raise on screen.
  func testMovingOneOfSeveralQuickTerminalPanesLeavesTheRest() async {
    let (quick, first, window) = makeQuickTerminalMove()
    let quickTarget = QuickTerminalController.target()
    let second = quick.terminals.addTab(for: quickTarget)
    var emptied = false
    quick.onTargetEmptied = { _ in emptied = true }
    XCTAssertEqual(quick.terminals.focusedTab(for: quickTarget)?.id, second.id)

    await quick.moveQuickTerminalPane(second.id, of: quickTarget, to: window, into: sid)

    XCTAssertFalse(emptied, "a pane is left")
    XCTAssertEqual(quick.terminals.allTabs(for: quickTarget).map(\.id), [first.id])
    XCTAssertEqual(quick.terminals.focusedTab(for: quickTarget)?.id, first.id)
    XCTAssertNotNil(window.terminals.tab(second.id, for: target(window)))
  }

  /// Value: protects=the "Move to Workroom" menu re-reads its windows when one opens or closes;
  /// fails_when=register or unregister stops bumping `windowsChanged` (the menu lists a closed
  /// window's workrooms, or misses a new one's); why_new=new publisher; seam=none;
  /// no_claim=the menu observing it.
  func testTheRegistryAnnouncesWindowsComingAndGoing() async {
    let window = NSWindow()
    let before = registry.windowsChanged

    registry.register(window: window, store: makeStore())
    await Task.yield()  // `register` bumps it a turn later
    XCTAssertGreaterThan(registry.windowsChanged, before)
    let opened = registry.windowsChanged

    registry.unregister(window: window)
    XCTAssertGreaterThan(registry.windowsChanged, opened)
  }

  /// The drag's own ghost sits under the cursor: a drop must look past it to the window beneath,
  /// or every drop would open a new window.
  func testTheWindowUnderADropIsFoundPastTheGhost() {
    let below: [Int: Int] = [0: 9, 9: 4, 4: 0]
    let found = WindowRegistry.frontmostDropWindow(
      skipping: [9], numberBelow: { below[$0] ?? 0 },
      resolve: { $0 == 4 ? .store(self.makeStore()) : .none })
    guard case .store = found else { return XCTFail("the window under the ghost was missed") }

    let nothing = WindowRegistry.frontmostDropWindow(
      skipping: [9], numberBelow: { $0 == 0 ? 9 : 0 }, resolve: { _ in .none })
    guard case .none = nothing else { return XCTFail("only the ghost is there") }
  }
}

/// Posts nothing; keeps the banner identifiers withdrawn.
private final class WithdrawingNotifier: SystemNotifying, @unchecked Sendable {
  var withdrawn: [String] = []
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) { withdrawn += tabIDs.map(\.uuidString) }
  func withdraw(identifiers: [String]) { withdrawn += identifiers }
}
