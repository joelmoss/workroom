import AgentConnection
import WorkroomDomain
import XCTest

@testable import Workroom

/// Alerts, merges and the waiting count for terminals that need the user (#358).
@MainActor
final class ProgramStatusAlertsTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|al", title: "al", path: "/tmp", isMissing: false)
  private var monitor: ProgramStatusMonitor!
  private var alerts: ProgramStatusAlerts!
  private var store: AppStore!
  private var enabled = true
  private var clock = Date(timeIntervalSince1970: 1000)

  override func setUp() async throws {
    monitor = ProgramStatusMonitor()
    monitor.now = { [unowned self] in clock }
    store = AppStore()
    store.systemNotifier = QuietNotifier()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.terminals.programStatus = monitor
    alerts = ProgramStatusAlerts()
    alerts.monitor = monitor
    alerts.stores = { [unowned self] in [store] }
    alerts.isEnabled = { [unowned self] in enabled }
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

  /// An agent that started again (a crash, a host reboot) numbers its requests from 1 again: the
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

  /// A program that never probed (Codex) alerts once the agent has seen it stay running (#481):
  /// the request it already showed alerts when it turns `notify`, once, and counts from then.
  /// Value: protects=Codex requests alert at all; fails_when=apply looks only at new episodes; why_new=every other test seeds notify from the start; seam=none; no_claim=the agent's promotion (seeded)
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
  /// report has none. The agent's later promotion adds nothing.
  /// Value: protects=one notification per Codex request, with its detail; fails_when=the hold, the immediate raise or the detail is missing; why_new=folding needed the alert raised first; seam=none; no_claim=real cross-route timing
  func testAProgramsNotificationBeforeItsRequestRaisesOneAlertCarryingItsText() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .working)])
    programNotified(id, "Approval requested: rm -rf build")
    XCTAssertEqual(shown, [], "held")
    monitor.seed(id, records: [blocked(message: "", notify: false)])
    XCTAssertEqual(requests.count, 1, "raised without waiting for the agent")
    XCTAssertEqual(requests.first?.body?.contains("Approval requested: rm -rf build"), true)
    XCTAssertEqual(alerts.countedWaiting, 1, "counted once raised")
    monitor.seed(id, records: [blocked(message: "", notify: true)])
    XCTAssertEqual(requests.count, 1, "the agent's promotion adds nothing")
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
    monitor.seed(other, records: [blocked("a"), blocked("b", episode: 2)])
    programNotified(other, "x", title: "Claude Code")
    for _ in 0..<50 { await Task.yield() }
    XCTAssertEqual(shown, [], "folded, not held and shown")
  }

  /// A reporting program's notification that announces no request is shown after the hold, and
  /// the alert of a request that comes after all replaces it (a lagging remote link).
  /// Value: protects=a held notification is never lost, and a late request still makes one notification; fails_when=the hold never releases or the backstop is missing; why_new=the hold is new (#481); seam=none; no_claim=real banner withdrawal (QuietNotifier)
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
    store.projects = [
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
    window.contentView?.addSubview(tab.surface!)
    // ⇧⌘M's "current" terminal is the selected one only once it has keyboard focus.
    XCTAssertNil(store.focusedTerminalSession, "selected, without keyboard focus")
    window.makeFirstResponder(tab.surface)
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
    tab.surface?.removeFromSuperview()
  }

  /// The title names the workroom, or a root's project, so the origin line never repeats it: a
  /// workroom alert adds just its project, a root's adds nothing.
  func testANeedsYouAlertNamesItsPlaceOnce() {
    store.projects = [
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
    store.systemNotifier = notifier
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
    store.systemNotifier = notifier
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
    other.systemNotifier = QuietNotifier()
    other.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    other.terminals.programStatus = monitor
    var open = [store!, other]
    alerts.stores = { open }
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
}

/// A notifier whose permission prompt stays up until the test grants it.
private final class GatedNotifier: SystemNotifying, @unchecked Sendable {
  private let lock = NSLock()
  private var gate: CheckedContinuation<Bool, Never>?
  private var _posted: [String] = []

  var isAsking: Bool { lock.withLock { gate != nil } }
  var posted: [String] { lock.withLock { _posted } }

  func ensureAuthorized() async -> Bool {
    await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
  }

  func grant() {
    let gate = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      defer { self.gate = nil }
      return self.gate
    }
    gate?.resume(returning: true)
  }

  func post(_ notification: WorkroomNotification) {
    lock.withLock { _posted.append(notification.title) }
  }

  func withdraw(tabIDs: [TerminalTab.ID]) {}
}

/// A notifier that is always allowed to post, and records each banner's identifier as the native
/// request would carry it, and each identifier withdrawn.
private final class RecordingNotifier: SystemNotifying, @unchecked Sendable {
  private let lock = NSLock()
  private var _posted: [String] = []
  private var _withdrawn: [String] = []

  var posted: [String] { lock.withLock { _posted } }
  var withdrawn: [String] { lock.withLock { _withdrawn } }

  func ensureAuthorized() async -> Bool { true }

  func post(_ notification: WorkroomNotification) {
    lock.withLock { _posted.append(SystemNotifier.payload(for: notification).identifier) }
  }

  func withdraw(tabIDs: [TerminalTab.ID]) {}

  func withdraw(identifiers: [String]) { lock.withLock { _withdrawn += identifiers } }
}

/// A window that is key whatever the test host's activation state.
private final class AlwaysKeyWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

private struct QuietNotifier: SystemNotifying {
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) {}
}
