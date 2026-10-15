import AgentConnection
import WorkroomVCS
import XCTest

@testable import Workroom

/// A host connection that only speaks program status: events are pushed by the test, `seen` and
/// `clear` are recorded.
final class FakeProgramStatusConnection: HostServiceConnection, @unchecked Sendable {
  let disconnection = AsyncStream<Void> { _ in }
  private let lock = NSLock()
  private var handler: (@Sendable (ProgramStatusEvent) -> Void)?
  private var _requests: [String] = []
  let availability: ProgramStatusAvailability

  init(availability: ProgramStatusAvailability = .available) { self.availability = availability }

  var requests: [String] { lock.withLock { _requests } }

  func push(_ event: ProgramStatusEvent) { lock.withLock { handler }?(event) }

  func reader(context: RepositoryContext) throws -> VCSProviding { throw VCSError.io("unused") }
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    throw VCSError.io("unused")
  }
  func subscribeProgramStatus(
    onEvent: @escaping @Sendable (ProgramStatusEvent) -> Void
  ) async throws -> ProgramStatusAvailability {
    lock.withLock { handler = onEvent }
    return availability
  }
  func programStatusSeen(session: UUID, revision: UInt64, states: [String]?) async throws {
    lock.withLock { _requests.append("seen \(revision) \(states ?? [])") }
  }
  func programStatusClear(session: UUID) async throws {
    lock.withLock { _requests.append("clear") }
  }
  func close() async {}
}

@MainActor
final class ProgramStatusMonitorTests: XCTestCase {
  let session = UUID()

  /// A monitor whose host connects to whatever the test hands over, in order, one per connect.
  private func makeMonitor() -> (ProgramStatusMonitor, ConnectionQueue) {
    let monitor = ProgramStatusMonitor()
    monitor.watchesHosts = true
    monitor.sleep = { _ in }
    let gate = ConnectionQueue()
    monitor.connect = { _ in try await gate.next() }
    return (monitor, gate)
  }

  func blocked(_ id: String = "", episode: UInt64 = 1, notify: Bool = true, progress: Int = -1)
    -> ProgramStatusRecord
  {
    ProgramStatusRecord(
      id: id, state: .blocked, kind: .permission, progress: progress, app: "claude-code",
      message: "Apply?", episode: episode, notify: notify)
  }

  func status(_ records: [ProgramStatusRecord], revision: UInt64 = 1, reporting: Bool = true)
    -> ProgramStatusEvent
  {
    .status(boot: "b", session: session, revision: revision, reporting: reporting, records: records)
  }

  func until(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line)
    async
  {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  /// The snapshot is held until `snapshot-complete`, then replaces the host's records; the first
  /// one since launch says so, so its waiting requests never notify.
  func testTheSnapshotReplacesTheHostAtItsEndAndOnlyTheFirstIsTheLaunchSnapshot() async {
    let (monitor, gate) = makeMonitor()
    var changes: [ProgramStatusMonitor.Change] = []
    _ = monitor.addListener { changes.append($0) }
    let first = FakeProgramStatusConnection()
    gate.yield(first)
    monitor.watch(.local)
    await until(
      {
        first.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[.local] == .live
      }())
    first.push(status([blocked()]))
    await until(monitor.rollup(for: session)?.blocked.count == 1)
    XCTAssertEqual(changes.first?.isLaunchSnapshot, true)
    XCTAssertEqual(changes.last?.isLaunchSnapshot, false)

    // The link drops: the records stay, and the host goes stale after the grace.
    first.push(.lost)
    await until(monitor.hosts[.local] == .stale)
    XCTAssertEqual(monitor.rollup(for: session)?.stale, true)
    XCTAssertEqual(monitor.rollup(for: session)?.blocked.count, 1)

    // The reconnect's snapshot no longer holds the session: it goes, and the host is live again.
    let second = FakeProgramStatusConnection()
    gate.yield(second)
    await until(
      {
        second.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[.local] == .live
      }())
    XCTAssertNil(monitor.rollup(for: session))
    XCTAssertEqual(changes.last?.isLaunchSnapshot, false)
  }

  /// `progress` is never shown, so a change to it alone publishes nothing; a state change does.
  func testAProgressOnlyChangePublishesNothing() async {
    let (monitor, gate) = makeMonitor()
    var count = 0
    _ = monitor.addListener { _ in count += 1 }
    let connection = FakeProgramStatusConnection()
    gate.yield(connection)
    monitor.watch(.local)
    await until(
      {
        connection.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[.local] == .live
      }())
    let working = ProgramStatusRecord(id: "", state: .working, progress: 10)
    connection.push(status([working], revision: 2))
    await until(monitor.rollup(for: session)?.working == true)
    let published = count
    connection.push(
      status([ProgramStatusRecord(id: "", state: .working, progress: 60)], revision: 3))
    // Claude's activity line on a working record is not shown either.
    connection.push(
      status([ProgramStatusRecord(id: "", state: .working, message: "Reading…")], revision: 3))
    connection.push(status([blocked()], revision: 4))
    await until(monitor.rollup(for: session)?.blocked.count == 1)
    XCTAssertEqual(count, published + 1, "only the state change published")
    // `seen` still names the latest revision.
    monitor.seen(session)
    await until(connection.requests == ["seen 4 []"])
  }

  /// An agent before protocol 8, or one without terminal state, is unavailable, and what was kept
  /// for the host goes.
  func testAnUnsupportedAgentClearsTheHost() async {
    let (monitor, gate) = makeMonitor()
    monitor.seed(session, records: [blocked()])
    gate.yield(FakeProgramStatusConnection(availability: .unsupported))
    monitor.watch(.local)
    await until(monitor.rollup(for: session) == nil)
    guard case .unavailable = monitor.hosts[.local] else {
      return XCTFail("\(String(describing: monitor.hosts[.local]))")
    }
  }

  /// A removed host's records go at once, and late events for it change nothing.
  func testForgettingAHostDropsItsRecords() async {
    let (monitor, gate) = makeMonitor()
    let host = HostID.remote(UUID())
    let connection = FakeProgramStatusConnection()
    gate.yield(connection)
    monitor.watch(host)
    await until(
      {
        connection.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[host] == .live
      }())
    connection.push(status([blocked()]))
    await until(monitor.rollup(for: session) != nil)
    monitor.forget(host)
    XCTAssertNil(monitor.rollup(for: session))
    connection.push(status([blocked()], revision: 2))
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(monitor.rollup(for: session))
  }

  /// The oldest waiting request leads the rollup, and a request that resolves and comes back is a
  /// new one, stamped again.
  func testWaitingRequestsAreOrderedByWhenTheyWereFirstSeen() {
    let monitor = ProgramStatusMonitor()
    var clock = Date(timeIntervalSince1970: 100)
    monitor.now = { clock }
    monitor.seed(session, records: [blocked("b")])
    clock = Date(timeIntervalSince1970: 200)
    monitor.seed(session, records: [blocked("a"), blocked("b")])
    XCTAssertEqual(monitor.rollup(for: session)?.blocked.map(\.id), ["b", "a"])
    XCTAssertEqual(monitor.rollup(for: session)?.blockedSince, Date(timeIntervalSince1970: 100))
  }

  /// Value: protects=a command result whose only change is its exit code is republished, so the tooltip never says the old code (#473); fails_when=`visible` drops exitCode; why_new=no other test compares exit codes; seam=none
  func testACommandResultThatOnlyChangesItsExitCodeIsPublished() {
    func session(_ exitCode: Int32) -> ProgramStatusSession {
      ProgramStatusSession(
        host: .local, boot: "b", revision: 1, reporting: false,
        records: [
          ProgramStatusRecord(
            id: "shell command", state: .error, message: "npm test", exitCode: exitCode)
        ])
    }
    XCTAssertTrue(session(2).differsVisibly(from: session(1)))
    XCTAssertFalse(session(1).differsVisibly(from: session(1)))
  }

  /// A session that ends takes its records with it, and its panes hear which session went.
  func testAnEndedSessionGoesAndItsPanesAreTold() async {
    let (monitor, gate) = makeMonitor()
    var changes: [ProgramStatusMonitor.Change] = []
    _ = monitor.addListener { changes.append($0) }
    let connection = FakeProgramStatusConnection()
    gate.yield(connection)
    monitor.watch(.local)
    await until(
      {
        connection.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[.local] == .live
      }())
    connection.push(status([blocked()]))
    await until(monitor.rollup(for: session) != nil)
    let before = changes.count

    connection.push(.ended(boot: "b", session: session))
    await until(changes.count > before)
    XCTAssertNil(monitor.rollup(for: session))
    XCTAssertEqual(changes.last?.sessions, [session])
  }

  /// A host whose link comes back (a pane reattached after it woke) is retried at once, not after
  /// its backoff, which can have reached 30 s.
  func testAHostWhoseLinkComesBackIsRetriedWithoutWaitingOutTheBackoff() async {
    let monitor = ProgramStatusMonitor()
    monitor.watchesHosts = true
    monitor.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    let back = SleepGate()
    monitor.reconnected = { _ in await back.wait() }
    let attempts = Attempts()
    let connection = FakeProgramStatusConnection()
    monitor.connect = { _ in
      if attempts.next() == 1 { throw VCSError.io("the host is asleep") }
      return connection
    }
    monitor.watch(.local)
    await until(back.isWaiting)
    XCTAssertEqual(attempts.count, 1, "fixture: one failed attempt, now backing off")

    back.release()
    await until(attempts.count == 2)
    await until(
      {
        connection.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[.local] == .live
      }())
  }

  /// Looking at a finished terminal while its host's link is down is not lost: the `seen` goes to
  /// the host once it is back, after its snapshot.
  func testASeenWhileTheLinkIsDownIsSentOnceTheHostIsBack() async {
    let (monitor, gate) = makeMonitor()
    let done = ProgramStatusRecord(id: "", state: .done)
    let first = FakeProgramStatusConnection()
    gate.yield(first)
    monitor.watch(.local)
    await until(
      {
        first.push(status([done]))
        first.push(.snapshotComplete(boot: "b", sessions: [session]))
        return monitor.rollup(for: session)?.done != nil
      }())

    first.push(.lost)
    await until(monitor.hosts[.local] != .live)
    monitor.seen(session)
    XCTAssertEqual(first.requests, [], "nothing to send it on")

    let second = FakeProgramStatusConnection()
    gate.yield(second)
    await until(
      {
        second.push(status([done]))
        second.push(.snapshotComplete(boot: "b", sessions: [session]))
        return !second.requests.isEmpty
      }())
    XCTAssertEqual(second.requests, ["seen 1 []"])
  }

  /// A link that drops and comes back within the stale grace, as every app update's hand-off
  /// does, never shows its host stale.
  func testADisconnectShorterThanTheGraceNeverGoesStale() async {
    let (monitor, gate) = makeMonitor()
    let grace = SleepGate()
    monitor.sleep = { duration in
      if duration == ProgramStatusLimits.staleGrace { await grace.wait() }
    }
    var changes: [ProgramStatusMonitor.Change] = []
    _ = monitor.addListener { changes.append($0) }
    let first = FakeProgramStatusConnection()
    gate.yield(first)
    monitor.watch(.local)
    await until(
      {
        first.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.hosts[.local] == .live
      }())

    first.push(.lost)
    await until(grace.isWaiting)
    let second = FakeProgramStatusConnection()
    gate.yield(second)
    let working = ProgramStatusRecord(id: "", state: .working)
    await until(
      {
        second.push(status([working]))
        second.push(.snapshotComplete(boot: "b", sessions: []))
        return monitor.rollup(for: session)?.working == true
      }())
    let published = changes.count

    grace.release()
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(monitor.hosts[.local], .live)
    XCTAssertEqual(monitor.rollup(for: session)?.stale, false)
    XCTAssertEqual(changes.count, published, "no stale change published")
  }
}

/// Holds every sleep handed to `wait` until the test releases them.
/// How many times a monitor tried to connect, from its `connect` closure.
private final class Attempts: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

private final class SleepGate: @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

  func wait() async {
    await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
  }

  func release() {
    let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      defer { waiters = [] }
      return waiters
    }
    for waiter in held { waiter.resume() }
  }
}

/// Connections handed to a monitor's `connect` one at a time, as the test releases them.
private final class ConnectionQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [any HostServiceConnection] = []

  func yield(_ connection: any HostServiceConnection) { lock.withLock { items.append(connection) } }

  func next() async throws -> any HostServiceConnection {
    while true {
      if let item = lock.withLock({ items.isEmpty ? nil : items.removeFirst() }) { return item }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// What program status does to a pane's indicators (#358).
@MainActor
final class ProgramStatusPaneTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|ps", title: "ps", path: "/tmp", isMissing: false)

  private func makeSessions(_ monitor: ProgramStatusMonitor) -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    sessions.programStatus = monitor
    return sessions
  }

  private func session(of tab: TerminalTab) -> UUID {
    guard case .terminal(let state) = tab.content, let id = state.sessionID else {
      XCTFail("no session")
      return UUID()
    }
    return id
  }

  /// One working and one waiting terminal: the workroom needs you and is running; once the request
  /// is answered it no longer needs you.
  func testAWorkroomNeedsYouWhileAnyTerminalWaits() {
    let monitor = ProgramStatusMonitor()
    let s = makeSessions(monitor)
    let working = s.addTab(for: target)
    let waiting = s.addTab(for: target)
    monitor.seed(session(of: working), records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(
      session(of: waiting),
      records: [ProgramStatusRecord(id: "", state: .blocked, kind: .question, episode: 1)])

    XCTAssertTrue(s.needsAttention(forTargetID: target.id))
    XCTAssertTrue(s.isRunning(forTargetID: target.id))
    XCTAssertEqual(s.blockedTerminalCount(forTargetID: target.id), 1)
    XCTAssertEqual(s.blockedTabs(forTargetID: target.id).map(\.tab), [waiting.id])

    monitor.seed(session(of: waiting), records: [ProgramStatusRecord(id: "", state: .working)])
    XCTAssertFalse(s.needsAttention(forTargetID: target.id))
  }

  /// A waiting terminal on a host whose link is down marks its workroom's glyph stale; Clear status
  /// takes the glyph away at once and leaves nothing reported.
  func testAStaleWaitingTerminalAndClearStatus() {
    let monitor = ProgramStatusMonitor()
    let s = makeSessions(monitor)
    let live = s.addTab(for: target)
    let stale = s.addTab(for: target)
    let waiting = ProgramStatusRecord(id: "", state: .blocked, kind: .permission, episode: 1)
    monitor.seed(session(of: live), records: [waiting])
    XCTAssertFalse(s.isWaitingStale(forTargetID: target.id))

    monitor.seed(
      session(of: stale), host: .remote(UUID()), records: [waiting], stale: true)
    XCTAssertTrue(s.isWaitingStale(forTargetID: target.id))
    XCTAssertEqual(s.blockedTerminalCount(forTargetID: target.id), 2)

    s.clearProgramStatus(tab: stale.id, target: target.id)
    XCTAssertFalse(s.isWaitingStale(forTargetID: target.id))
    XCTAssertEqual(s.blockedTerminalCount(forTargetID: target.id), 1)
    XCTAssertEqual(s.tabs(for: target)[1].programStatus?.hasReport, false)
  }

  /// A reporting program decides the pane, over OSC 9;4. Once it stops reporting, OSC 9;4 decides
  /// again, and a surviving error only adds its mark.
  func testPrecedenceBetweenProgramStatusAndOSC94() {
    let monitor = ProgramStatusMonitor()
    let s = makeSessions(monitor)
    let tab = s.addTab(for: target)
    let view = tab.surface!
    let id = session(of: tab)
    func indicator() -> PaneIndicator { s.tabs(for: target)[0].indicator }

    view.handleProgressReport(true)
    monitor.seed(id, records: [ProgramStatusRecord(id: "", state: .blocked, episode: 1)])
    XCTAssertEqual(indicator(), .blocked, "a waiting program beats 9;4 progress")

    monitor.seed(
      id,
      records: [
        ProgramStatusRecord(id: "a", state: .blocked, episode: 1),
        ProgramStatusRecord(id: "b", state: .error),
      ])
    XCTAssertEqual(indicator(), .blocked, "blocked beats error")

    monitor.seed(id, reporting: false, records: [ProgramStatusRecord(id: "", state: .error)])
    XCTAssertEqual(indicator(), .running(failed: true), "9;4 decides; the old error adds its mark")

    view.handleProgressReport(false)
    XCTAssertEqual(indicator(), .error)

    monitor.seed(id, reporting: false, records: [ProgramStatusRecord(id: "", state: .done)])
    XCTAssertEqual(indicator(), .done)
    view.handleProgressReport(true)
    XCTAssertEqual(indicator(), .running(failed: false), "a finished turn never hides progress")

    monitor.seed(id, reporting: true, records: [ProgramStatusRecord(id: "", state: .done)])
    XCTAssertEqual(indicator(), .running(failed: false), "running beats done")
  }

  /// Value: protects=a failed shell command never reddens what runs next in the pane (#473); fails_when=a command result outranks working or 9;4 progress as a program's error does; why_new=the precedence test covers only a program's own error; seam=none
  func testAFailedCommandRanksBelowAnythingRunning() {
    let monitor = ProgramStatusMonitor()
    let s = makeSessions(monitor)
    let tab = s.addTab(for: target)
    let view = tab.surface!
    let id = session(of: tab)
    func indicator() -> PaneIndicator { s.tabs(for: target)[0].indicator }
    let failed = ProgramStatusRecord(id: "shell command", state: .error, exitCode: 1)

    monitor.seed(
      id, reporting: true, records: [failed, ProgramStatusRecord(id: "", state: .working)])
    XCTAssertEqual(indicator(), .running(failed: false), "claude after failing tests is working")
    monitor.seed(id, reporting: true, records: [failed])
    XCTAssertEqual(indicator(), .error, "back once nothing runs, until seen")

    monitor.seed(id, reporting: false, records: [failed])
    view.handleProgressReport(true)
    XCTAssertEqual(
      indicator(), .running(failed: false), "the next command's progress is not failed")
    view.handleProgressReport(false)
    XCTAssertEqual(indicator(), .error)
    XCTAssertTrue(s.hasProgramError(forTargetID: target.id))
  }

  /// Value: protects=whichever of a command result and a program's report came last shows (#473); fails_when=an older command failure outranks claude's newer finished turn, or a newer failure hides behind an older one; why_new=the rank test seeds no order between the two; seam=none
  func testTheLaterOfACommandResultAndAProgramReportShows() {
    let monitor = ProgramStatusMonitor()
    let s = makeSessions(monitor)
    let tab = s.addTab(for: target)
    let id = session(of: tab)
    func indicator() -> PaneIndicator { s.tabs(for: target)[0].indicator }
    let failed = ProgramStatusRecord(id: "shell command", state: .error, exitCode: 1)
    let turn = ProgramStatusRecord(id: "", state: .done)

    monitor.seed(id, reporting: true, records: [failed, turn])
    XCTAssertEqual(indicator(), .done, "claude's turn after the failing tests")
    XCTAssertNil(s.tabs(for: target)[0].programStatus?.error)
    monitor.seed(id, reporting: false, records: [turn, failed])
    XCTAssertEqual(indicator(), .error, "tests failing again after claude stopped")
  }

  /// A pane swapped out for a diff or file tab leaves its window without resigning first
  /// responder; it must stop counting as the one the user is looking at.
  func testAPaneLeavingItsWindowLosesEffectiveFocus() {
    let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
    let window = AlwaysKeyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView?.addSubview(view)
    window.makeFirstResponder(view)
    XCTAssertTrue(view.isEffectivelyFocused)
    var changes: [Bool] = []
    view.onEffectiveFocusChange = { changes.append($0) }
    view.removeFromSuperview()
    XCTAssertFalse(view.isEffectivelyFocused)
    XCTAssertEqual(changes, [false])
  }

  /// Focus moving into a pane marks its finished records seen; a finish that arrives while the pane
  /// already has focus is marked seen only when focus leaves, and only as finished.
  func testFocusMarksFinishedRecordsSeen() async {
    let monitor = ProgramStatusMonitor()
    monitor.watchesHosts = true
    let connection = FakeProgramStatusConnection()
    monitor.connect = { _ in connection }
    monitor.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    let s = makeSessions(monitor)
    let tab = s.addTab(for: target)
    let view = tab.surface!
    let id = session(of: tab)
    for _ in 0..<200 where monitor.hosts[.local] != .live {
      connection.push(.snapshotComplete(boot: "b", sessions: []))
      try? await Task.sleep(for: .milliseconds(10))
    }
    let done = ProgramStatusRecord(id: "", state: .done)
    connection.push(.status(boot: "b", session: id, revision: 5, reporting: true, records: [done]))
    for _ in 0..<200 where s.tabs(for: target)[0].indicator != .done {
      try? await Task.sleep(for: .milliseconds(10))
    }

    view.onEffectiveFocusChange?(true)
    for _ in 0..<200 where connection.requests.isEmpty {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(connection.requests, ["seen 5 []"])
  }

  /// A finish the user watched happen, in the focused pane, is marked seen when focus leaves, and
  /// only as finished.
  func testAFinishWatchedInTheFocusedPaneIsSeenWhenFocusLeaves() async {
    let monitor = ProgramStatusMonitor()
    monitor.watchesHosts = true
    let connection = FakeProgramStatusConnection()
    monitor.connect = { _ in connection }
    monitor.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    let s = makeSessions(monitor)
    s.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false) }
    let tab = s.addTab(for: target)
    let view = tab.surface!
    let id = session(of: tab)
    for _ in 0..<200 where monitor.hosts[.local] != .live {
      connection.push(.snapshotComplete(boot: "b", sessions: []))
      try? await Task.sleep(for: .milliseconds(10))
    }
    let window = AlwaysKeyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView?.addSubview(view)
    window.makeFirstResponder(view)
    XCTAssertTrue(view.isEffectivelyFocused, "fixture: the pane has focus")

    let done = ProgramStatusRecord(id: "", state: .done)
    connection.push(.status(boot: "b", session: id, revision: 5, reporting: true, records: [done]))
    for _ in 0..<200 where s.tabs(for: target)[0].indicator != .done {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(connection.requests, [], "not seen while it is being watched")

    view.removeFromSuperview()
    for _ in 0..<200 where connection.requests.isEmpty {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(connection.requests, [#"seen 5 ["done"]"#])
  }

  /// A tab pointed at another session shows that session's status at once, not the old one's
  /// until the new session next changes.
  func testATabPointedAtAnotherSessionShowsItsStatusAtOnce() {
    let monitor = ProgramStatusMonitor()
    let s = makeSessions(monitor)
    monitor.seed(
      session(of: s.addTab(for: target)),
      records: [ProgramStatusRecord(id: "", state: .blocked, kind: .question, episode: 1)])
    let other = UUID()
    monitor.seed(other, records: [ProgramStatusRecord(id: "", state: .done)])
    XCTAssertTrue(s.needsAttention(forTargetID: target.id), "fixture: the tab's own session waits")

    var tab = s.tabs(for: target)[0]
    guard case .terminal(var state) = tab.content else { return XCTFail("not a terminal") }
    state.sessionID = other
    tab.content = .terminal(state)
    s.replace(tab, for: target)
    s.refreshProgramStatus(tab: tab.id, target: target.id)

    XCTAssertEqual(s.tabs(for: target)[0].programStatus, monitor.rollup(for: other))
    XCTAssertEqual(s.tabs(for: target)[0].indicator, .done)
    XCTAssertFalse(s.needsAttention(forTargetID: target.id))
  }
}

/// A window that is key whatever the test host's activation state.
private final class AlwaysKeyWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
