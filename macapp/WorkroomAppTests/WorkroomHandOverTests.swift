import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Moving a workroom from one window to another (issue #444). The terminals travel live: the same
/// tab ids and the same surfaces, so nothing restarts and no history is repainted. What these pin is
/// that everything the window it leaves knew about the workroom goes with it, and that nothing of it
/// keeps answering to the old window.
@MainActor
final class WorkroomHandOverTests: XCTestCase {
  private let shared = ProjectStore()
  private let sid = SidebarID.workroom(project: "/p", name: "a")
  private let otherSid = SidebarID.workroom(project: "/p", name: "b")

  override func setUp() {
    super.setUp()
    shared.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: ["a", "b"].map {
          Workroom(name: $0, path: "/p/\($0)", vcsName: "workroom/\($0)", warnings: [])
        })
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: shared)
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
  }

  /// A surface reports to the window that holds it now. Left wired to the origin, a moved
  /// terminal's title (and focus, exits, activity) would go to a window that no longer has it.
  func testAMovedSurfaceReportsToTheDestination() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let tab = origin.terminals.addTab(for: t)

    origin.moveWorkroom(sid, to: destination)
    tab.surface?.onTitleChange?("vim notes.md")

    XCTAssertEqual(destination.terminals.tab(tab.id, for: t)?.title, "vim notes.md")
    XCTAssertNotNil(tab.surface?.onFocused, "a hand-over never tears the surface down")
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
    var t = TerminalTarget(id: "remote-\(UUID())", title: "r", path: "/r", isMissing: false)
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
  func testARunningRunCommandMovesAndItsExitReachesTheDestination() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    let run = origin.terminals.addRunTab(for: t, command: "sleep 1000", cwd: "/p/a", focus: false)
    origin.runStates[t.id] = .running(tab: run.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertNil(origin.runStates[t.id])
    XCTAssertEqual(destination.runStates[t.id], .running(tab: run.id, interrupted: false))
    run.surface?.onChildExited?(0)
    XCTAssertEqual(
      destination.runStates[t.id], .stopped(tab: run.id), "the exit was the destination's to hear")
  }

  /// The supervisor's status file is what drives a run (issue #7), and the origin's poll of it
  /// stops the moment the run leaves. The destination must take it up.
  func testTheDestinationPollsAMovedRunsSupervisor() throws {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let run = origin.terminals.addRunTab(for: t, command: "sleep 1000", cwd: "/p/a", focus: false)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pid = dir.appendingPathComponent("run.pid").path
    origin.runStates[t.id] = .running(tab: run.id, interrupted: false)
    origin.runPidFiles[t.id] = pid

    origin.moveWorkroom(sid, to: destination)
    try "stopped\n".write(
      toFile: RunCommandController.supervisorStatusPath(forPidPath: pid), atomically: true,
      encoding: .utf8)

    let stopped = expectation(description: "the destination read the status file")
    func check() {
      if destination.runStates[t.id] == .stopped(tab: run.id) {
        stopped.fulfill()
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
      }
    }
    check()
    wait(for: [stopped], timeout: 3)
    XCTAssertEqual(destination.runOutcomes[t.id], .stoppedByUser)
  }

  /// Of two run tabs for one workroom, the running one stays and a stopped one closes (Q12).
  func testIntoAWindowWithAStoppedRunTheMovedRunningOneWins() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let running = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runStates[t.id] = .running(tab: running.id, interrupted: false)
    let stopped = destination.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    destination.runStates[t.id] = .stopped(tab: stopped.id)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(destination.runStates[t.id], .running(tab: running.id, interrupted: false))
    XCTAssertNil(destination.terminals.tab(stopped.id, for: t), "the stopped run tab closed")
  }

  func testAMovedStoppedRunClosesBesideTheDestinationsRunningOne() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    let stopped = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runStates[t.id] = .stopped(tab: stopped.id)
    let running = destination.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    destination.runStates[t.id] = .running(tab: running.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(destination.runStates[t.id], .running(tab: running.id, interrupted: false))
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
    destination.scheduleRunToastDismiss = { delay, _ in
      delays.append(delay)
      return DispatchWorkItem {}
    }
    let t = target(origin)
    let run = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runStates[t.id] = .running(tab: run.id, interrupted: false)
    origin.runToastDismissWork[t.id] = DispatchWorkItem {}

    origin.moveWorkroom(sid, to: destination)

    XCTAssertEqual(delays.count, 1, "the destination starts the running toast's auto-hide")
    XCTAssertNotNil(destination.runToastDismissWork[t.id])
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
    origin.terminals.agentManager.adopt(tab.id, banner: .loading(failure), failure: failure)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertNil(origin.terminals.agentManager.banners[tab.id])
    XCTAssertEqual(
      destination.terminals.agentManager.banners[tab.id], .awaitingDiagnose(failure),
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

    XCTAssertEqual(origin.notifications.count(target: t.id), 0)
    XCTAssertEqual(destination.notifications.count(tab: tab.id), 1)
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
  /// reaching the store and toggling that pane; fails_when=wire() stops setting onToggleWindow, the
  /// event is not routed, or togglePaneWindow picks the wrong branch; why_new=no test drives the
  /// toggle at all; seam=none; no_claim=the AppKit menu item's title and shortcut.
  func testAPanesWindowToggleDetachesThenDocksIt() {
    let store = makeStore()
    let t = target(store)
    _ = store.terminals.addTab(for: t)
    let pane = store.terminals.addTab(for: t)
    defer { store.detachedPanes.closeAll() }

    pane.surface?.onToggleWindow?()
    XCTAssertTrue(store.terminals.detachedTabIDs.contains(pane.id), "first toggle tears it off")
    XCTAssertNotNil(store.detachedPanes.window(for: pane.id))

    pane.surface?.onToggleWindow?()
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

  /// Value: protects=the run toast state and investigate tabs travelling with the workroom, a
  /// moved investigate tab's exit clearing it in the new window, (flags only travel with a run, the only
  /// thing they describe); fails_when=takeHandOff/adopt drop a field or
  /// resumeAdoptedRun stops rewiring investigate tabs; why_new=existing tests cover run state and
  /// merge rules only, not the toast flags or investigate tabs; seam=none; no_claim=the toast UI.
  func testToastFlagsAndInvestigateTabsMoveWithTheRun() {
    let origin = makeOrigin()
    let destination = makeStore()
    let t = target(origin)
    _ = origin.terminals.addTab(for: t)
    let probe = origin.terminals.addTab(for: t)
    origin.investigateTabs[probe.id] = t.id
    origin.dismissedRunToasts.insert(t.id)
    origin.runningToastAutoHidden.insert(t.id)
    let run = origin.terminals.addRunTab(for: t, command: "a", cwd: "/p/a", focus: false)
    origin.runStates[t.id] = .running(tab: run.id, interrupted: false)

    origin.moveWorkroom(sid, to: destination)

    XCTAssertFalse(origin.dismissedRunToasts.contains(t.id))
    XCTAssertFalse(origin.runningToastAutoHidden.contains(t.id))
    XCTAssertNil(origin.investigateTabs[probe.id])
    XCTAssertEqual(destination.investigateTabs[probe.id], t.id)
    XCTAssertTrue(destination.dismissedRunToasts.contains(t.id))
    XCTAssertTrue(destination.runningToastAutoHidden.contains(t.id))
    probe.surface?.onChildExited?(0)
    XCTAssertNil(destination.investigateTabs[probe.id], "its exit is the destination's to hear")
  }

  // MARK: Remote host layout

  /// The keeping of a remote workroom's host layout moves with it, with what the origin knew of the
  /// host's copy. Left with the origin, its next save would write the emptied workroom as an empty
  /// layout over the host's.
  func testARemoteWorkroomsHostLayoutKeepingMoves() {
    let origin = makeOrigin()
    let destination = makeStore()
    var t = TerminalTarget(id: "remote-\(UUID())", title: "r", path: "/r", isMissing: false)
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
    var t = TerminalTarget(id: "remote-\(UUID())", title: "r", path: "/r", isMissing: false)
    let workroom = UUID()
    t.remoteHost = UUID()
    t.remoteWorkroomID = workroom
    XCTAssertTrue(HostLayoutOwners.shared.claim(workroom, targetID: t.id, by: origin))
    origin.hostLayouts.fetched.insert(t.id)
    origin.hostLayouts.revisions[t.id] = 7
    let (gate, open) = AsyncStream<Void>.makeStream()
    origin.hostLayouts.writing[t.id] = Task {
      for await _ in gate { break }
    }

    origin.handHostLayout(of: t, to: destination)
    XCTAssertNotNil(destination.hostLayouts.writing[t.id], "the destination waits on it")
    XCTAssertNil(destination.hostLayouts.revisions[t.id])
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
