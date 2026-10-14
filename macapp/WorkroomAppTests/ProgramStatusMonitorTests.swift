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
}
