import AgentConnection
import Foundation
import OSLog
import WorkroomVCS

/// The tunable values of program status (#358), each with the reason for its number. The agent's
/// side lives in `program_status::limits`.
enum ProgramStatusLimits {
  /// A disconnect shorter than this is not shown: every app update hands the agent off.
  static let staleGrace: Duration = .seconds(5)
  /// Reconnect backoff for a host whose link dropped: 1 s doubling to 30 s.
  static let backoffFloor: Duration = .seconds(1)
  static let backoffCeiling: Duration = .seconds(30)
  /// How long after a request begins a program's own notification still belongs to it. Claude
  /// Code's arrives 6.0 s after its `blocked` report (measured, Step 0 of #358).
  static let mergeWindow: Duration = .seconds(10)
  /// At most one surfaced "needs you" per tab in this long, so a program toggling its state cannot
  /// flood the user.
  static let notifyCooldown: Duration = .seconds(30)
  /// The same notification raised by several panes of one session within this is one entry.
  static let attachmentDedupe: Duration = .seconds(1)
  /// After this long blocked, the tooltip says how to clear a status that is stuck.
  static let stuckHint: Duration = .seconds(600)
}

/// What one session's records mean for its pane: the precedence blocked > error > working > done,
/// worked out once here and read by every indicator.
struct ProgramStatusRollup: Equatable {
  /// A program reported in the current run. While false, the pane's live OSC 9;4 decides whether
  /// it is running, and a surviving `done` or `error` only adds its mark.
  var reporting: Bool
  /// Waiting records, oldest request first.
  var blocked: [ProgramStatusRecord]
  var error: ProgramStatusRecord?
  var working: Bool
  var done: ProgramStatusRecord?
  /// The session's revision, for `seen`.
  var revision: UInt64
  /// Its host's link is down: the last known state, which may be out of date.
  var stale: Bool
  /// When the oldest waiting request began, as this app first saw it.
  var blockedSince: Date?
}

/// One session's records as the agent last sent them.
struct ProgramStatusSession: Equatable {
  let host: HostID
  var boot: String
  var revision: UInt64
  var reporting: Bool
  var records: [ProgramStatusRecord]
  /// When this app first saw each waiting request, by (record id, episode).
  var blockedSince: [String: Date] = [:]

  /// Whether the two differ in anything an indicator or notification reads: `progress` alone is
  /// never shown, so a change only to it is not published.
  func differsVisibly(from other: ProgramStatusSession) -> Bool {
    reporting != other.reporting || boot != other.boot
      || records.map(Self.visible) != other.records.map(Self.visible)
  }

  /// What is shown of a record: a working or idle one's text is not (Claude Code sends a new
  /// activity line every few seconds), so only its state counts.
  private static func visible(_ record: ProgramStatusRecord) -> ProgramStatusRecord {
    let shown = record.state != .working && record.state != .idle
    return ProgramStatusRecord(
      id: record.id, state: record.state, kind: record.kind, app: record.app,
      title: shown ? record.title : "", message: shown ? record.message : "",
      episode: record.episode, notify: record.notify, exitCode: record.exitCode)
  }

  static func blockedKey(_ record: ProgramStatusRecord) -> String {
    "\(record.id)#\(record.episode)"
  }

  func rollup(stale: Bool) -> ProgramStatusRollup {
    // A command result (#473) a program has reported since is out of date: whichever came last
    // shows. The agent sends the records oldest change first.
    let lastProgram = records.lastIndex { $0.exitCode == nil } ?? -1
    let records = records.enumerated()
      .filter { $0.element.exitCode == nil || $0.offset > lastProgram }.map(\.element)
    let blocked = records.filter { $0.state == .blocked }.sorted {
      (blockedSince[Self.blockedKey($0)] ?? .distantFuture)
        < (blockedSince[Self.blockedKey($1)] ?? .distantFuture)
    }
    return ProgramStatusRollup(
      reporting: reporting, blocked: blocked,
      error: records.last { $0.state == .error },
      working: records.contains { $0.state == .working },
      done: records.last { $0.state == .done }, revision: revision, stale: stale,
      blockedSince: blocked.first.flatMap { blockedSince[Self.blockedKey($0)] })
  }
}

/// Every host's program status, app-wide (#358): one subscription per host connection, however
/// many windows show its panes. A host is watched once a pane on it asks (`watch`), and its records
/// are kept across a dropped link (shown stale) until the reconnect's snapshot replaces them.
@MainActor
final class ProgramStatusMonitor: ObservableObject {
  static let shared = ProgramStatusMonitor()

  enum HostState: Equatable {
    /// Watched, never connected yet.
    case connecting
    case live
    /// The link dropped more than `staleGrace` ago; the records are the last known.
    case stale
    /// The host's agent predates the service or keeps no terminal state.
    case unavailable(String)
  }

  /// What changed, for the panes that show it.
  struct Change {
    let host: HostID
    let sessions: Set<UUID>
    /// The first snapshot of this host since launch: every waiting request in it was there before
    /// the app was, so none of them notifies.
    let isLaunchSnapshot: Bool
  }

  /// Not `@Published`: panes get it through their tab's state, by listener, and the sidebar and tab
  /// strip, which observe this for `hosts`, would otherwise re-render on every session's change.
  private(set) var sessions: [UUID: ProgramStatusSession] = [:]
  @Published private(set) var hosts: [HostID: HostState] = [:]

  /// Connects `host` and returns its connection: `LocalAgentVCS` for this Mac, which may start the
  /// agent, and `RemoteHosts` for a remote one, which never wakes a sleeping box.
  var connect: @Sendable (HostID) async throws -> any HostServiceConnection = { host in
    if host == .local { return try await LocalAgentVCS.shared.programStatus() }
    try await RemoteHosts.shared.ensureConnected(host)
    return try await HostConnectionManager.shared.programStatus(host: host)
  }
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  /// Returns once `host`'s link comes up as a new connection (its workroom opened, or a boxd host
  /// woken), so a retry need not wait out its backoff; never for this Mac's agent. A link that is
  /// already up does not count, or a host whose agent has no program status would be retried
  /// without pause. A background host that was unreachable is not reconnected early: `RemoteHosts`
  /// holds its retry window, which this monitor's own failed connects keep open.
  var reconnected: @Sendable (HostID) async -> Void = { host in
    guard host != .local else {
      while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
      return
    }
    var baseline: HostConnectionManager.Snapshot?
    for await snapshot in await HostConnectionManager.shared.updates(for: host) {
      guard let before = baseline else {
        baseline = snapshot
        continue
      }
      if snapshot.status == .connected,
        before.status != .connected || snapshot.lease != before.lease
      {
        return
      }
      baseline = snapshot
    }
  }
  var now: () -> Date = Date.init

  /// Each session's latest revision, for `seen`. Apart from `sessions` so a progress-only event,
  /// which moves it, publishes nothing.
  private var revisions: [UUID: UInt64] = [:]
  private var tasks: [HostID: Task<Void, Never>] = [:]
  private var connections: [HostID: any HostServiceConnection] = [:]
  private var pendingSeen: [UUID: (host: HostID, revision: UInt64, states: [String]?)] = [:]
  private var snapshotted: Set<HostID> = []
  private var listeners: [UUID: (Change) -> Void] = [:]
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "program-status")

  /// `listener` hears every change until the returned token is dropped from `removeListener`.
  func addListener(_ listener: @escaping (Change) -> Void) -> UUID {
    let id = UUID()
    listeners[id] = listener
    return id
  }

  func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

  /// False in a test process or a fixture launch, which must never reach the developer's agent:
  /// tests drive their own monitor, and the fixture seeds records straight in (`seed`). A fixture
  /// launch with a scratch agent of its own (`UITestFixture.liveAgentDirectory`) does watch it.
  var watchesHosts =
    !AppEnvironment.current.isTestProcess || UITestFixture.liveAgentDirectory != nil

  /// Starts following `host`, once.
  func watch(_ host: HostID) {
    guard watchesHosts, tasks[host] == nil else { return }
    hosts[host] = .connecting
    tasks[host] = Task { [weak self] in await self?.run(host) }
  }

  /// A removed host: everything about it goes now, and late events for it are ignored.
  func forget(_ host: HostID) {
    tasks.removeValue(forKey: host)?.cancel()
    connections.removeValue(forKey: host)
    pendingSeen = pendingSeen.filter { $0.value.host != host }
    snapshotted.remove(host)
    hosts.removeValue(forKey: host)
    let gone = Set(sessions.filter { $0.value.host == host }.keys)
    for id in gone { sessions.removeValue(forKey: id) }
    notify(Change(host: host, sessions: gone, isLaunchSnapshot: false))
  }

  /// Puts `session`'s records in with no agent: the UI-test fixture's seam (`UITestFixture`).
  func seed(
    _ session: UUID, host: HostID = .local, reporting: Bool = true,
    records: [ProgramStatusRecord], stale: Bool = false, boot: String = "fixture"
  ) {
    hosts[host] = stale ? .stale : .live
    _ = store(
      ProgramStatusSession(
        host: host, boot: boot, revision: 1, reporting: reporting, records: records),
      for: session)
    notify(Change(host: host, sessions: [session], isLaunchSnapshot: false))
  }

  func rollup(for session: UUID) -> ProgramStatusRollup? {
    guard let record = sessions[session] else { return nil }
    return record.rollup(stale: hosts[record.host] == .stale)
  }

  /// The user has looked at `session`: its finished and failed records up to now go. With the link
  /// down it is sent once the host is back, after its snapshot; the revision keeps anything newer.
  func seen(_ session: UUID, states: [String]? = nil) {
    guard let record = sessions[session] else { return }
    let revision = revisions[session] ?? record.revision
    guard let connection = connections[record.host] else {
      pendingSeen[session] = (record.host, revision, states)
      return
    }
    Task {
      try? await connection.programStatusSeen(session: session, revision: revision, states: states)
    }
  }

  /// Clear status: every record of `session` goes, on the host and here at once.
  func clear(_ session: UUID) {
    guard var record = sessions[session] else { return }
    record.records = []
    record.reporting = false
    sessions[session] = record
    notify(Change(host: record.host, sessions: [session], isLaunchSnapshot: false))
    guard let connection = connections[record.host] else { return }
    Task { try? await connection.programStatusClear(session: session) }
  }

  // MARK: Following a host

  private func run(_ host: HostID) async {
    var backoff = ProgramStatusLimits.backoffFloor
    while !Task.isCancelled {
      let lost = Date()
      do {
        let connection = try await connect(host)
        let (events, continuation) = AsyncStream<ProgramStatusEvent>.makeStream()
        let availability = try await connection.subscribeProgramStatus {
          continuation.yield($0)
        }
        guard !Task.isCancelled else { return }
        switch availability {
        case .available:
          backoff = ProgramStatusLimits.backoffFloor
          connections[host] = connection
          var pending: [UUID: ProgramStatusSession] = [:]
          var inSnapshot = true
          for await event in events {
            guard !Task.isCancelled else { return }
            if case .lost = event { break }
            if inSnapshot,
              case .status(let boot, let session, let revision, let reporting, let records) = event
            {
              pending[session] = ProgramStatusSession(
                host: host, boot: boot, revision: revision, reporting: reporting, records: records)
              continue
            }
            if inSnapshot, case .snapshotComplete = event {
              inSnapshot = false
              replace(host: host, with: pending)
              continue
            }
            apply(event, host: host)
          }
          connections.removeValue(forKey: host)
          markStaleAfterGrace(host, since: lost)
        case .unsupported, .unavailable:
          let reason: String
          if case .unavailable(let why) = availability {
            reason = why
          } else {
            reason = "Program status: unavailable on this host"
          }
          hosts[host] = .unavailable(reason)
          let gone = Set(sessions.filter { $0.value.host == host }.keys)
          for id in gone { sessions.removeValue(forKey: id) }
          if !gone.isEmpty { notify(Change(host: host, sessions: gone, isLaunchSnapshot: false)) }
          // An agent is replaced only by an app update, which relaunches this monitor too; a
          // remote host's may be upgraded by a later connect, so look again now and then.
          backoff = ProgramStatusLimits.backoffCeiling
        }
      } catch {
        if hosts[host] == .live { markStaleAfterGrace(host, since: lost) }
      }
      let (sleep, reconnected, wait) = (self.sleep, self.reconnected, backoff)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { try? await sleep(wait) }
        group.addTask { await reconnected(host) }
        await group.next()
        group.cancelAll()
      }
      guard !Task.isCancelled else { return }
      backoff = min(backoff * 2, ProgramStatusLimits.backoffCeiling)
    }
  }

  private func markStaleAfterGrace(_ host: HostID, since: Date) {
    Task { [weak self] in
      guard let self else { return }
      try? await self.sleep(ProgramStatusLimits.staleGrace)
      guard self.connections[host] == nil, self.hosts[host] == .live else { return }
      self.hosts[host] = .stale
      Self.logger.info("program status: \(String(describing: host), privacy: .public) is stale")
      let affected = Set(self.sessions.filter { $0.value.host == host }.keys)
      self.notify(Change(host: host, sessions: affected, isLaunchSnapshot: false))
    }
  }

  /// The snapshot after a subscribe: it replaces whatever was kept for the host.
  private func replace(host: HostID, with snapshot: [UUID: ProgramStatusSession]) {
    let launch = snapshotted.insert(host).inserted
    var changed = Set<UUID>()
    for (id, old) in sessions where old.host == host && snapshot[id] == nil {
      sessions.removeValue(forKey: id)
      changed.insert(id)
    }
    for (id, new) in snapshot where store(new, for: id) { changed.insert(id) }
    let wasStale = hosts[host] == .stale
    hosts[host] = .live
    if wasStale {
      Self.logger.info("program status: \(String(describing: host), privacy: .public) is live")
      changed.formUnion(sessions.filter { $0.value.host == host }.keys)
    }
    notify(Change(host: host, sessions: changed, isLaunchSnapshot: launch))
    for (session, seen) in pendingSeen where seen.host == host {
      pendingSeen.removeValue(forKey: session)
      guard sessions[session] != nil, let connection = connections[host] else { continue }
      Task {
        try? await connection.programStatusSeen(
          session: session, revision: seen.revision, states: seen.states)
      }
    }
  }

  private func apply(_ event: ProgramStatusEvent, host: HostID) {
    switch event {
    case .status(let boot, let session, let revision, let reporting, let records):
      let new = ProgramStatusSession(
        host: host, boot: boot, revision: revision, reporting: reporting, records: records)
      if store(new, for: session) {
        notify(Change(host: host, sessions: [session], isLaunchSnapshot: false))
      }
    case .ended(_, let session):
      revisions.removeValue(forKey: session)
      guard sessions.removeValue(forKey: session) != nil else { return }
      notify(Change(host: host, sessions: [session], isLaunchSnapshot: false))
    case .snapshotComplete, .lost:
      break
    }
  }

  /// Stores `new`, stamping when each waiting request was first seen, and says whether anything
  /// shown changed. A change to `progress` alone updates nothing on the main actor.
  private func store(_ new: ProgramStatusSession, for id: UUID) -> Bool {
    var new = new
    let old = sessions[id]
    let stamp = now()
    for record in new.records where record.state == .blocked {
      let key = ProgramStatusSession.blockedKey(record)
      new.blockedSince[key] = old?.blockedSince[key] ?? stamp
    }
    revisions[id] = new.revision
    if let old, !new.differsVisibly(from: old) { return false }
    sessions[id] = new
    return true
  }

  private func notify(_ change: Change) {
    for listener in listeners.values { listener(change) }
  }
}
