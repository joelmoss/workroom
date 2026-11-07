import DaemonConnection
import Synchronization
import WorkroomDomain
import XCTest

@testable import Workroom

/// Alerts, merges and the waiting count for terminals that need the user (#358).
@MainActor
final class ProgramStatusAlertsTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "al"), title: "al", path: "/tmp", isMissing: false)
  private var monitor: ProgramStatusMonitor!
  private var alerts: ProgramStatusAlerts!
  private var store: AppStore!
  private var notifier: SilentNotifier!
  private var enabled = true
  private var finishEnabled = true
  private var clock = Date(timeIntervalSince1970: 1000)

  override func setUp() async throws {
    monitor = ProgramStatusMonitor()
    monitor.now = { [unowned self] in clock }
    store = AppStore()
    notifier = SilentNotifier()
    store.services.notifier = notifier
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.terminals.programStatus = monitor
    alerts = ProgramStatusAlerts()
    alerts.monitor = monitor
    alerts.notifyingHosts = { [unowned self] in [store] }
    alerts.isEnabled = { [unowned self] in enabled }
    alerts.isFinishEnabled = { [unowned self] in finishEnabled }
    alerts.now = { [unowned self] in clock }
    alerts.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
  }

  private func session(_ tab: TerminalTab) -> UUID {
    store.terminals.sessionID(forTab: tab.id, inTarget: target.id)!
  }

  private func blocked(
    _ id: String = "", episode: UInt64 = 1, message: String = "Apply?", notify: Bool = true
  ) -> ProgramStatusRecord {
    ProgramStatusRecord(
      id: id, state: .blocked, kind: .permission, message: message, episode: episode,
      notify: notify)
  }

  /// The program's own notifications shown as ordinary ones, and those withdrawn again, by body.
  private var shown: [String] = []
  private var withdrawn: [String] = []

  private func programNotified(_ session: UUID, _ body: String, title: String = "Codex") {
    alerts.programNotified(session: session, title: title, body: body) { [unowned self] in
      shown.append(body)
      return { [unowned self] in withdrawn.append(body) }
    }
  }

  private var requests: [WorkroomNotification] {
    store.notifications.items.filter { $0.episode != nil }
  }

  /// A tab pointed at another session (Detached sessions › Active tab) takes its old session's
  /// alert with it, since the alert would open a tab showing something else; the request still
  /// waits, and lists again once a pane shows it.
  func testRepointingTheOnlyPaneWithdrawsItsOldSessionsAlert() {
    alerts.start()
    let tab = store.terminals.addTab(for: target)
    let id = session(tab)
    monitor.seed(id, records: [blocked()])
    XCTAssertEqual(requests.count, 1, "fixture: one alert")

    guard case .terminal(var state) = store.terminals.tabs(for: target)[0].content else {
      return XCTFail("not a terminal")
    }
    state.sessionID = UUID()
    var moved = store.terminals.tabs(for: target)[0]
    moved.content = .terminal(state)
    store.terminals.replace(moved, for: target)
    alerts.paneLeft(session: id)
    XCTAssertTrue(requests.isEmpty)
    XCTAssertTrue(alerts.waiting.isEmpty)

    _ = store.terminals.addTab(for: target, sessionID: id)
    alerts.recomputeWaiting()
    XCTAssertEqual(alerts.waiting.map(\.session), [id], "it still waits")
    XCTAssertTrue(requests.isEmpty, "and is not alerted twice")
  }

  /// A daemon that started again (a crash, a host reboot) numbers its requests from 1 again: the
  /// boot in the episode keeps a new request from passing for one already alerted.
  func testANewAgentBootAlertsAgainForTheSameEpisodeNumber() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()], boot: "first")
    XCTAssertEqual(requests.count, 1, "fixture: one alert")
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)], boot: "first")
    XCTAssertTrue(requests.isEmpty, "fixture: answered")

    monitor.seed(id, records: [blocked()], boot: "second")
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.episode?.hasPrefix("second/"), true)
  }

  /// One alert per request; reading it leaves the request counted; answering it drops both.
  func testARequestAlertsOnceAndCountsUntilAnswered() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()])
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.title, "Terminal 1 needs you")
    XCTAssertEqual(alerts.countedWaiting, 1)

    monitor.seed(id, records: [blocked(), ProgramStatusRecord(id: "x", state: .working)])
    XCTAssertEqual(requests.count, 1, "staying blocked never alerts again")

    store.notifications.dismiss(tab: requests[0].tabID)
    XCTAssertEqual(alerts.countedWaiting, 1, "reading the alert does not answer the request")

    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    XCTAssertEqual(alerts.countedWaiting, 0)
    XCTAssertTrue(alerts.waiting.isEmpty)
  }

  /// Two requests count apart: answering one keeps the other's alert and count.
  func testTwoRequestsResolveIndependently() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked("a")])
    clock += 40
    monitor.seed(id, records: [blocked("a"), blocked("b", episode: 2)])
    XCTAssertEqual(alerts.countedWaiting, 2)
    XCTAssertEqual(requests.count, 2)
    monitor.seed(id, records: [blocked("a"), ProgramStatusRecord(id: "b", state: .working)])
    XCTAssertEqual(alerts.countedWaiting, 1)
    XCTAssertEqual(requests.map(\.episode), [alerts.waiting.first?.id])
  }

  /// A request already there at launch, and one from a program that never asked whether the
  /// terminal supports the protocol, show but never alert; only the first counts in the badge.
  func testLaunchSnapshotAndUnprobedRequestsNeverAlert() {
    let first = session(store.terminals.addTab(for: target))
    let second = session(store.terminals.addTab(for: target))
    monitor.seed(first, records: [blocked()])  // not listening yet: this is the launch snapshot
    alerts.apply(.init(host: .local, sessions: [first], isLaunchSnapshot: true))
    alerts.start()
    monitor.seed(second, records: [blocked(notify: false)])
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(alerts.waiting.count, 2)
    XCTAssertEqual(alerts.countedWaiting, 1)
  }

  private func done(message: String = "", notify: Bool = true, exitCode: Int32? = nil)
    -> ProgramStatusRecord
  {
    ProgramStatusRecord(
      id: "", state: .done, message: message, notify: notify, exitCode: exitCode)
  }

  private var finishes: [WorkroomNotification] {
    store.notifications.items.filter { $0.title.hasSuffix(" finished") }
  }

  /// A finished turn in a terminal nobody is looking at alerts once; the next turn's finish
  /// alerts again, replacing the first, so a session looping on its own leaves one entry.
  func testAFinishedTurnAlertsOncePerTurn() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(id, records: [done(message: "Fixed the build")])
    XCTAssertEqual(finishes.map(\.title), ["Terminal 1 finished"])
    XCTAssertEqual(finishes.first?.body, "Turn finished: \u{201C}Fixed the build\u{201D}")
    XCTAssertNil(finishes.first?.episode, "an ordinary notification, not a waiting request")

    monitor.seed(id, records: [done(message: "Fixed the build")])
    monitor.seed(id, records: [])  // seen
    XCTAssertEqual(finishes.count, 1, "the same finish never alerts twice")

    let first = finishes.first?.id
    XCTAssertTrue(notifier.withdrawnTabs.isEmpty, "fixture: nothing replaced yet")
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(id, records: [done(message: "Ran the tests")])
    XCTAssertEqual(finishes.map(\.body), ["Turn finished: \u{201C}Ran the tests\u{201D}"])
    XCTAssertNotEqual(finishes.first?.id, first, "the next turn's finish alerted again")
    XCTAssertEqual(
      notifier.withdrawnTabs, [finishes.first?.tabID].compactMap { $0 },
      "the first finish's banner goes with its entry")
  }

  /// A finish already there at launch, a shell command's result, a `printf` of a report, and any
  /// finish with the setting off only show the mark.
  func testFinishesThatOnlyShowTheMark() {
    let first = session(store.terminals.addTab(for: target))
    monitor.seed(first, records: [done()])  // not listening yet: this is the launch snapshot
    alerts.apply(.init(host: .local, sessions: [first], isLaunchSnapshot: true))
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [done(exitCode: 0)])
    monitor.seed(id, records: [done(notify: false)])
    finishEnabled = false
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(id, records: [done()])
    XCTAssertTrue(finishes.isEmpty)
  }

  /// After a finish, the program's own notification (Claude Code's "waiting for your input" a
  /// minute later) is dropped, also once the finish was seen; with the setting off it shows.
  func testTheProgramsOwnNotificationAfterAFinishIsDropped() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [done()])
    programNotified(id, "Claude is waiting for your input", title: "Claude Code")
    monitor.seed(id, records: [])  // seen
    clock += 60
    programNotified(id, "Claude is waiting for your input again", title: "Claude Code")
    XCTAssertEqual(shown, [])

    finishEnabled = false
    clock += 60
    monitor.seed(id, reporting: false, records: [])  // not held: shown at once
    programNotified(id, "Claude is waiting for your input", title: "Claude Code")
    XCTAssertEqual(shown, ["Claude is waiting for your input"])
  }

  /// A finish in the terminal the user is looking at only shows the mark; once they look away, the
  /// next turn's finish alerts.
  /// Value: protects=a watched finish never alerts; fails_when=followFinish drops its focused-attachment guard; why_new=the other finish tests use unfocused panes; seam=none; no_claim=real key-window changes (AlwaysKeyWindow)
  func testAFinishInTheFocusedTerminalDoesNotAlert() {
    alerts.start()
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    let tab = store.terminals.addTab(for: target)
    let window = AlwaysKeyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView?.addSubview(store.terminals.surface(tab)!)
    window.makeFirstResponder(store.terminals.surface(tab))
    let id = session(tab)
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(id, records: [done()])
    XCTAssertTrue(finishes.isEmpty)

    window.makeFirstResponder(nil)
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(id, records: [done()])
    XCTAssertEqual(finishes.count, 1, "control: the same pane alerts once nobody is looking")
    store.terminals.surface(tab)?.removeFromSuperview()
  }

  /// Once the program that finished has gone, the next one's notifications are its own (a build
  /// with a shell notify plugin, say).
  func testANotificationAfterTheFinishedProgramExitsShows() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [done()])
    monitor.seed(id, reporting: false, records: [])
    programNotified(id, "Build finished", title: "zsh")
    XCTAssertEqual(shown, ["Build finished"])
  }

  /// A program that writes its own notification just before reporting the finish (Codex) gets
  /// one notification: the finish alert, with the program's words.
  func testAHeldNotificationFoldsIntoTheFinish() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    programNotified(id, "Done: tests pass")
    monitor.seed(id, records: [done()])
    XCTAssertEqual(shown, [])
    XCTAssertEqual(finishes.map(\.body), ["Turn finished: \u{201C}Done: tests pass\u{201D}"])
  }

  /// A program that never probed (Codex) alerts once the daemon has seen it stay running (#481):
  /// the request it already showed alerts when it turns `notify`, once, and counts from then.
  /// Value: protects=Codex requests alert at all; fails_when=apply looks only at new episodes; why_new=every other test seeds notify from the start; seam=none; no_claim=the daemon's promotion (seeded)
  func testAnUnprobedRequestAlertsOnceTheAgentPromotesIt() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked(notify: false)])
    XCTAssertTrue(requests.isEmpty, "fixture: not yet")
    monitor.seed(id, records: [blocked()])
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(alerts.countedWaiting, 1)
    monitor.seed(id, records: [blocked(notify: false)])
    monitor.seed(id, records: [blocked()])
    XCTAssertEqual(requests.count, 1, "the same request alerts once")
  }

  /// Codex posts its own notification just before it reports the request (#481): it is held, and
  /// the request it announces raises one alert at once, carrying the program's text, since Codex's
  /// report has none. The daemon's later promotion adds nothing.
  /// Value: protects=one notification per Codex request, with its detail; fails_when=the hold, the immediate raise or the detail is missing; why_new=folding needed the alert raised first; seam=none; no_claim=real cross-route timing
  func testAProgramsNotificationBeforeItsRequestRaisesOneAlertCarryingItsText() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    programNotified(id, "Approval requested: rm -rf build")
    XCTAssertEqual(shown, [], "held")
    monitor.seed(id, records: [blocked(message: "", notify: false)])
    XCTAssertEqual(requests.count, 1, "raised without waiting for the daemon")
    XCTAssertEqual(requests.first?.body?.contains("Approval requested: rm -rf build"), true)
    XCTAssertEqual(alerts.countedWaiting, 1, "counted once raised")
    monitor.seed(id, records: [blocked(message: "", notify: true)])
    XCTAssertEqual(requests.count, 1, "the daemon's promotion adds nothing")
    XCTAssertEqual(shown, [])
  }

  /// The program's own notification is folded into its session's request while the request is
  /// open, however late (Claude Code's comes 6 s after its report), and into the newest of two.
  /// Value: protects=no second notification for a request already alerted; fails_when=folding is limited to a window or to one request; why_new=the window and the one-request rule are gone (#481); seam=none; no_claim=the merged entry's text
  func testTheProgramsOwnNotificationFoldsIntoAnOpenRequest() async {
    alerts.sleep = { _ in }
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()])
    clock += 6
    programNotified(id, "needs permission", title: "Claude Code")
    clock += 60
    programNotified(id, "still waiting", title: "Claude Code")

    let other = session(store.terminals.addTab(for: target))
    monitor.seed(other, records: [blocked("a")])
    clock += 1
    monitor.seed(other, records: [blocked("a"), blocked("b", episode: 2, notify: false)])
    programNotified(other, "x")
    for _ in 0..<50 { await Task.yield() }
    XCTAssertEqual(shown, [], "folded, not held and shown")
    XCTAssertEqual(
      alerts.waiting.filter { $0.session == other && $0.counted }.count, 2,
      "the newest request is raised, not folded into the older")
  }

  /// A held notification whose request Workroom will not alert (nobody can be shown it in a
  /// window, as when its terminal is being looked at) is shown as before, not lost.
  /// Value: protects=a held notification is never swallowed; fails_when=the raise path consumes the hold without alerting; why_new=review finding on #481; seam=none; no_claim=the focused case itself (focus needs a window)
  func testAHeldNotificationIsShownWhenItsRequestCannotAlert() {
    alerts.start()
    let id = UUID()
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    programNotified(id, "Approval requested")
    XCTAssertEqual(shown, [], "fixture: held")
    monitor.seed(id, records: [blocked(message: "", notify: false)])
    XCTAssertEqual(shown, ["Approval requested"])
    XCTAssertTrue(requests.isEmpty)
  }

  /// A reporting program's notification that announces no request is shown after the hold, and
  /// the alert of a request that comes after all replaces it (a lagging remote link).
  /// Value: protects=a held notification is never lost, and a late request still makes one notification; fails_when=the hold never releases or the backstop is missing; why_new=the hold is new (#481); seam=none; no_claim=real banner withdrawal (SilentNotifier)
  func testAHeldNotificationShowsAndALateRequestReplacesIt() async {
    alerts.sleep = { _ in }
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    programNotified(id, "Build finished")
    for _ in 0..<50 where shown.isEmpty { await Task.yield() }
    XCTAssertEqual(shown, ["Build finished"], "shown once the hold ends")
    clock += 3
    monitor.seed(id, records: [blocked(message: "")])
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(withdrawn, ["Build finished"], "the alert replaces it")
    XCTAssertEqual(requests.first?.body?.contains("Build finished"), true)
  }

  /// A program's own notification shown long before its request is a different event: the alert
  /// leaves it alone.
  /// Value: protects=an earlier, unrelated notification is not withdrawn; fails_when=the backstop has no time limit; why_new=the late-request test stays inside the limit; seam=none; no_claim=real banner withdrawal
  func testALongShownNotificationIsNotWithdrawnByALaterRequest() async {
    alerts.sleep = { _ in }
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    programNotified(id, "Build finished")
    for _ in 0..<50 where shown.isEmpty { await Task.yield() }
    clock += 60
    monitor.seed(id, records: [blocked(message: "Apply?")])
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(withdrawn, [], "a minute-old notification is not its announcement")
  }

  /// The same notification from two panes of one session within a second is one; a session that
  /// reports no program status shows it at once.
  func testARepeatFromAnotherAttachmentIsDropped() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    programNotified(id, "done", title: "Build")
    programNotified(id, "done", title: "Build")
    XCTAssertEqual(shown, ["done"])
    clock += 2
    programNotified(id, "done", title: "Build")
    XCTAssertEqual(shown, ["done", "done"])
  }

  /// A program toggling its state alerts once per cooldown; a new request after the last one was
  /// answered alerts at once.
  func testTheCooldownHoldsOnlyWhileTheLastRequestIsOpen() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked("a")])
    clock += 1
    monitor.seed(id, records: [blocked("a"), blocked("b", episode: 2)])
    XCTAssertEqual(requests.count, 1, "held while the first is still open")

    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    clock += 1
    monitor.seed(id, records: [blocked("c", episode: 3)])
    XCTAssertEqual(requests.count, 1, "the earlier ones went with their answers")
    XCTAssertEqual(requests.first?.episode, alerts.waiting.first?.id)
  }

  /// With alerts off, requests still list but neither alert nor count, and the program's own
  /// notification is shown as before.
  func testAlertsOffListsButNeitherAlertsNorCounts() {
    alerts.start()
    enabled = false
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()])
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(alerts.waiting.count, 1)
    XCTAssertEqual(alerts.countedWaiting, 0)
    programNotified(id, "x", title: "Claude Code")
    XCTAssertEqual(shown, ["x"], "shown at once, not held")
  }

  /// ⇧⌘M from a waiting terminal goes to the next, wrapping; from elsewhere to the oldest.
  func testGoToNextWaitingCycles() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    XCTAssertEqual(ProgramStatusAlerts.next(after: nil, in: [a, b, c]), a)
    XCTAssertEqual(ProgramStatusAlerts.next(after: a, in: [a, b, c]), b)
    XCTAssertEqual(ProgramStatusAlerts.next(after: c, in: [a, b, c]), a)
    XCTAssertEqual(ProgramStatusAlerts.next(after: UUID(), in: [a, b]), a)
    XCTAssertNil(ProgramStatusAlerts.next(after: a, in: [a]), "only the focused one waits")
    XCTAssertNil(ProgramStatusAlerts.next(after: nil, in: []))
  }

  /// Activation reads notifications only in the key window, with its terminal focused: a window
  /// with no key status (here, none at all) keeps them. Before #358 every window read its own.
  func testActivationReadsNothingOutsideTheKeyWindow() {
    alerts.start()
    store.terminals.addTab(for: target)
    let tab = store.terminals.tabs(for: target)[0]
    store.notifications.record(
      targetID: target.id, tabID: tab.id, activity: .osc(title: "t", body: nil), focused: false)
    store.dismissFocusedTerminalNotifications()
    XCTAssertEqual(store.notifications.items.count, 1)
  }

  /// The control for the test above: in the key window, with its terminal holding focus,
  /// activation reads that terminal's notifications.
  func testActivationReadsTheKeyWindowsFocusedTerminal() {
    let sid = SidebarID.workroom(project: "/p", name: "al")
    store.projectStore.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "al", path: "/p/al", vcsName: "git", warnings: [])])
    ]
    store.selectedTargetID = sid
    let target = store.target(for: sid)!
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    let tab = store.terminals.addTab(for: target)
    let window = AlwaysKeyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView?.addSubview(store.terminals.surface(tab)!)
    // ⇧⌘M's "current" terminal is the selected one only once it has keyboard focus.
    XCTAssertNil(store.focusedTerminalSession, "selected, without keyboard focus")
    window.makeFirstResponder(store.terminals.surface(tab))
    XCTAssertEqual(
      store.focusedTerminalSession,
      store.terminals.sessionID(forTab: tab.id, inTarget: target.id))
    store.hostWindow = window
    // After focus lands, so it is the activation that reads it, not the pane gaining focus.
    store.notifications.record(
      targetID: target.id, tabID: tab.id, activity: .osc(title: "t", body: nil), focused: false)
    XCTAssertEqual(store.notifications.items.count, 1, "fixture: one unread notification")

    store.dismissFocusedTerminalNotifications()
    XCTAssertEqual(store.notifications.items.count, 0)
    store.terminals.surface(tab)?.removeFromSuperview()
  }

  /// The title names the workroom, or a root's project, so the origin line never repeats it: a
  /// workroom alert adds just its project, a root's adds nothing.
  func testANeedsYouAlertNamesItsPlaceOnce() {
    store.projectStore.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "al", path: "/p/al", vcsName: "git", warnings: [])])
    ]
    for (sid, title, source) in [
      (SidebarID.workroom(project: "/p", name: "al"), "Terminal 1 in al needs you", "p"),
      (SidebarID.root(project: "/p"), "Terminal 1 in p needs you", ""),
    ] {
      let target = store.target(for: sid)!
      let tab = store.terminals.addTab(for: target)
      store.raiseNeedsYou(
        targetID: target.id, tabID: tab.id, episode: "\(sid)", record: blocked(),
        stillWanted: { true })
      let note = requests.first { $0.episode == "\(sid)" }
      XCTAssertEqual(note?.title, title)
      XCTAssertEqual(note?.source, source)
      XCTAssertEqual(SystemNotifier.payload(for: note!).subtitle, source.isEmpty ? nil : source)
      XCTAssertEqual(resolvedNotificationSource(store, note!), source)
    }
  }

  /// The badge counts other unread notifications plus waiting requests, never an alert twice.
  func testTheBadgeNeverCountsAnAlertTwice() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()])
    store.notifications.record(
      targetID: target.id, tabID: UUID(), activity: .osc(title: "build", body: nil),
      focused: false)
    XCTAssertEqual(store.notifications.unreadExcludingRequests, 1)
    XCTAssertEqual(store.notifications.unreadExcludingRequests + alerts.countedWaiting, 2)
  }

  /// "2 requests waiting, 1 unread notification (1 may be out of date)".
  func testTheMenuBarSaysTheBreakdown() {
    let record = blocked()
    let fresh = WaitingRequest(
      id: "a", session: UUID(), record: record, since: .now, stale: false, counted: true)
    let stale = WaitingRequest(
      id: "b", session: UUID(), record: record, since: .now, stale: true, counted: true)
    XCTAssertEqual(
      MenuBarController.breakdown(waiting: [fresh, stale], unread: 1),
      "2 requests waiting, 1 unread notification (1 may be out of date)")
    XCTAssertEqual(MenuBarController.breakdown(waiting: [], unread: 2), "2 unread notifications")
    XCTAssertNil(MenuBarController.breakdown(waiting: [], unread: 0))
  }
  // MARK: A banner waiting on notification permission

  /// Asking for permission can take as long as the user takes to answer, so a banner is checked
  /// again right before it posts: posted when nothing changed; not posted once the alert was read,
  /// alerts were turned off, or the request was answered meanwhile.
  func testABannerWaitingOnPermissionIsCheckedAgainBeforeItPosts() async {
    let posted = await banner(after: { _, _ in })
    XCTAssertEqual(posted, ["Terminal 1 needs you"], "control: nothing changed, so it posts")
    let read = await banner(after: { _, tab in self.store.notifications.dismiss(tab: tab) })
    XCTAssertEqual(read, [], "read while permission was pending")
    let off = await banner(after: { _, _ in self.enabled = false })
    XCTAssertEqual(off, [], "alerts turned off while permission was pending")
    let answered = await banner(after: { id, _ in
      self.monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    })
    XCTAssertEqual(answered, [], "answered while permission was pending")
  }

  /// One request raised with the app in the background, `change` made while the permission prompt
  /// is still up, then permission granted: the banners that posted.
  private func banner(after change: (UUID, TerminalTab.ID) -> Void) async -> [String] {
    try? await setUp()
    enabled = true
    let notifier = GatedNotifier()
    store.services.notifier = notifier
    store.isAppActive = { false }
    alerts.start()
    let tab = store.terminals.addTab(for: target)
    let id = session(tab)
    monitor.seed(id, records: [blocked()])
    for _ in 0..<200 where !notifier.isAsking { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(notifier.isAsking, "fixture: the banner never asked for permission")
    change(id, tab.id)
    notifier.grant()
    try? await Task.sleep(for: .milliseconds(200))
    return notifier.posted
  }

  /// A request's banner is posted under its episode, and answering the request withdraws that
  /// banner, and only it.
  func testAnsweringARequestWithdrawsItsOwnBanner() async {
    let notifier = RecordingNotifier()
    store.services.notifier = notifier
    store.isAppActive = { false }
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()])
    for _ in 0..<200 where notifier.posted.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    let episode = ProgramStatusAlerts.episode(boot: "fixture", session: id, record: blocked())
    XCTAssertEqual(notifier.posted, [episode], "the banner's identifier is its episode")

    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    XCTAssertEqual(notifier.withdrawn, [episode])
  }

  // MARK: Windows

  /// A session attached in two windows is one waiting request and one alert; its row and count
  /// go when the last window holding it closes.
  func testASessionInTwoWindowsCountsOnceAndGoesWithItsLastWindow() {
    alerts.start()
    let other = AppStore()
    other.services.notifier = SilentNotifier()
    other.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    other.terminals.programStatus = monitor
    var open = [store!, other]
    alerts.notifyingHosts = { open }
    let id = session(store.terminals.addTab(for: target))
    other.terminals.addTab(for: target, sessionID: id)

    monitor.seed(id, records: [blocked()])
    XCTAssertEqual(alerts.countedWaiting, 1)
    let entries = open.flatMap { $0.notifications.items.filter { $0.episode != nil } }
    XCTAssertEqual(entries.count, 1, "one alert, in one window")

    open = [other]
    alerts.recomputeWaiting()
    XCTAssertEqual(alerts.countedWaiting, 1, "still attached in the other window")
    open = []
    alerts.recomputeWaiting()
    XCTAssertEqual(alerts.countedWaiting, 0)
    XCTAssertTrue(alerts.waiting.isEmpty, "no window holds it: no row")
  }

  /// Value: protects=alerts reaching a host that is not a window's store (the Quick Terminal's
  /// host will be one): its request alerts, folds in the program's own text, names its place,
  /// withdraws when answered, and its finish alerts; fails_when=ProgramStatusAlerts reaches past
  /// NotifyingHost to an AppStore; why_new=every other case's host is an AppStore; seam=a recording
  /// NotifyingHost; no_claim=what an AppStore does with each call (the cases above).
  func testAlertsReachAHostThatIsNotAWindowsStore() throws {
    let host = RecordingHost()
    host.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    host.terminals.programStatus = monitor
    alerts.notifyingHosts = { [host] }
    alerts.start()
    let tab = host.terminals.addTab(for: target)
    let id = try XCTUnwrap(host.terminals.sessionID(forTab: tab.id, inTarget: target.id))

    monitor.seed(id, records: [blocked()])
    XCTAssertEqual(host.needsYou.map(\.tab), [tab.id])
    let episode = try XCTUnwrap(host.needsYou.first?.episode)
    XCTAssertEqual(alerts.waiting.map(\.id), [episode])
    XCTAssertEqual(alerts.place(of: try XCTUnwrap(alerts.waiting.first)), "Terminal X in fake")

    programNotified(id, "needs permission", title: "Claude Code")
    XCTAssertEqual(host.merged.map(\.episode), [episode], "folded into the raised request")
    XCTAssertEqual(shown, [], "not shown apart")

    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    XCTAssertEqual(host.withdrawn, [episode], "answered: its alert goes")
    XCTAssertTrue(alerts.waiting.isEmpty)

    monitor.seed(id, records: [done(message: "Fixed it")])
    XCTAssertEqual(host.finished.map(\.tab), [tab.id])
    XCTAssertEqual(host.finished.first?.message, "Fixed it")
    XCTAssertTrue(store.notifications.items.isEmpty, "the store is not one of the hosts")
  }
}

/// A `NotifyingHost` that is no window's store: it records each call `ProgramStatusAlerts` makes.
@MainActor
private final class RecordingHost: NotifyingHost {
  let terminals = TerminalPanes()
  var focusedTerminalSession: UUID?
  let systemNotifier: SystemNotifying = SilentNotifier()
  private(set) var needsYou: [(tab: TerminalTab.ID, episode: String)] = []
  private(set) var finished: [(tab: TerminalTab.ID, message: String?)] = []
  private(set) var merged: [(episode: String, body: String?)] = []
  private(set) var withdrawn: [String] = []

  func raiseNeedsYou(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, episode: String,
    record: ProgramStatusRecord, detail: String?, stillWanted: @escaping () -> Bool
  ) {
    needsYou.append((tabID, episode))
  }

  func raiseFinished(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, record: ProgramStatusRecord,
    detail: String?
  ) {
    finished.append((tabID, record.message))
  }

  func mergeIntoNeedsYou(episode: String, body: String?) { merged.append((episode, body)) }
  func withdrawNeedsYou(episode: String) { withdrawn.append(episode) }
  func terminalPlace(targetID: TerminalTarget.ID, tabID: TerminalTab.ID) -> String {
    "Terminal X in fake"
  }
  func enqueueToast(_ note: WorkroomNotification) {}
}

/// A notifier whose permission prompt stays up until the test grants it.
private final class GatedNotifier: SystemNotifying, Sendable {
  private let gate = Mutex<CheckedContinuation<Bool, Never>?>(nil)
  private let titles = Mutex<[String]>([])

  var isAsking: Bool { gate.withLock { $0 != nil } }
  var posted: [String] { titles.withLock { $0 } }

  func ensureAuthorized() async -> Bool {
    await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
  }

  func grant() {
    let gate = self.gate.withLock { gate in
      defer { gate = nil }
      return gate
    }
    gate?.resume(returning: true)
  }

  func post(_ notification: WorkroomNotification) {
    titles.withLock { $0.append(notification.title) }
  }

  func withdraw(tabIDs: [TerminalTab.ID]) {}
}

/// A notifier that is always allowed to post, and records each banner's identifier as the native
/// request would carry it, and each identifier withdrawn.
private final class RecordingNotifier: SystemNotifying, Sendable {
  private let identifiers = Mutex<(posted: [String], withdrawn: [String])>(([], []))

  var posted: [String] { identifiers.withLock { $0.posted } }
  var withdrawn: [String] { identifiers.withLock { $0.withdrawn } }

  func ensureAuthorized() async -> Bool { true }

  func post(_ notification: WorkroomNotification) {
    let identifier = SystemNotifier.payload(for: notification).identifier
    identifiers.withLock { $0.posted.append(identifier) }
  }

  func withdraw(tabIDs: [TerminalTab.ID]) {}

  func withdraw(identifiers: [String]) {
    self.identifiers.withLock { $0.withdrawn += identifiers }
  }
}

/// A window that is key whatever the test host's activation state.
private final class AlwaysKeyWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
