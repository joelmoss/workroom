import AgentConnection
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

  private func blocked(_ id: String = "", episode: UInt64 = 1, notify: Bool = true)
    -> ProgramStatusRecord
  {
    ProgramStatusRecord(
      id: id, state: .blocked, kind: .permission, message: "Apply?", episode: episode,
      notify: notify)
  }

  private var requests: [WorkroomNotification] {
    store.notifications.items.filter { $0.episode != nil }
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

  /// The program's own notification about the one request just raised is folded in; with two
  /// requests waiting, or long after, it stays a notification of its own.
  func testTheProgramsOwnAlertMergesOnlyWhenUnambiguous() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    monitor.seed(id, records: [blocked()])
    clock += 6
    XCTAssertTrue(alerts.absorbsOSC(session: id, title: "Claude Code", body: "needs permission"))
    XCTAssertFalse(
      alerts.absorbsOSC(session: id, title: "Claude Code", body: "later"),
      "a request merges once")

    let other = session(store.terminals.addTab(for: target))
    monitor.seed(other, records: [blocked("a"), blocked("b", episode: 2)])
    clock += 2
    XCTAssertFalse(alerts.absorbsOSC(session: other, title: "Claude Code", body: "x"))

    let late = session(store.terminals.addTab(for: target))
    monitor.seed(late, records: [blocked()])
    clock += 11
    XCTAssertFalse(alerts.absorbsOSC(session: late, title: "Claude Code", body: "y"))
  }

  /// The same notification from two panes of one session within a second is one.
  func testARepeatFromAnotherAttachmentIsDropped() {
    alerts.start()
    let id = session(store.terminals.addTab(for: target))
    XCTAssertFalse(alerts.absorbsOSC(session: id, title: "Build", body: "done"))
    XCTAssertTrue(alerts.absorbsOSC(session: id, title: "Build", body: "done"))
    clock += 2
    XCTAssertFalse(alerts.absorbsOSC(session: id, title: "Build", body: "done"))
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
    XCTAssertFalse(alerts.absorbsOSC(session: id, title: "Claude Code", body: "x"))
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
}

private struct QuietNotifier: SystemNotifying {
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) {}
}
