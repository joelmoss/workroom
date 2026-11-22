import DaemonConnection
import Foundation
import OSLog
import WorkroomDomain

/// The tunable values of the typing marker (#696), each with the reason for its number.
enum PaneTypingLimits {
  /// How long a sender's marker stays after its last keystroke: long enough to read who it was
  /// and where from, short enough that it never outstays the typing (#360's story 49).
  static let linger: Duration = .seconds(3)
}

/// Who is typing into which session, and since when (#696). Pure: every change takes the time it
/// happens at, on the monotonic clock (a wall-clock change never stretches or cuts the 3 s), so
/// the 3 s rule is tested with times the test picks.
///
/// A "keystroke" is one `session.input` event: the daemon tells each `terminal.send` (a `workroom
/// send` or `prompt`) once, before it types. A session's typists are kept in the order they
/// started typing, so the marker names the same sender for as long as that sender keeps typing,
/// however the others interleave.
struct PaneTypingState: Equatable {
  struct Typist: Equatable {
    /// The session the typing comes from; nil for a send from no pane (a script outside Workroom).
    let sender: UUID?
    /// When this run of typing began: what orders a session's typists.
    let started: ContinuousClock.Instant
    /// The sender's last keystroke into the session.
    var lastTyped: ContinuousClock.Instant

    var expires: ContinuousClock.Instant { lastTyped + PaneTypingLimits.linger }
  }

  private var typists: [UUID: [Typist]] = [:]

  /// `session`'s typists, in the order they started typing.
  func typists(of session: UUID) -> [Typist] { typists[session] ?? [] }

  /// Every session someone is typing into.
  var sessions: Set<UUID> { Set(typists.keys) }

  /// `sender` typed into `session` at `now`, restarting its 3 s. A session typing into itself (a
  /// send with `--allow-self`) is no one else's typing, so it marks nothing. Returns whether the
  /// session's typists changed who they are, which is all a marker shows.
  @discardableResult
  mutating func typed(into session: UUID, by sender: UUID?, at now: ContinuousClock.Instant)
    -> Bool
  {
    guard sender != session else { return false }
    var list = typists[session] ?? []
    if let index = list.firstIndex(where: { $0.sender == sender }) {
      list[index].lastTyped = max(list[index].lastTyped, now)
      typists[session] = list
      return false
    }
    list.append(Typist(sender: sender, started: now, lastTyped: now))
    typists[session] = list
    return true
  }

  /// Drops every typist whose last keystroke is `linger` old at `now`. Returns the sessions whose
  /// typists changed.
  mutating func expire(at now: ContinuousClock.Instant) -> Set<UUID> {
    var changed = Set<UUID>()
    for (session, list) in typists {
      let kept = list.filter { $0.expires > now }
      guard kept.count != list.count else { continue }
      changed.insert(session)
      typists[session] = kept.isEmpty ? nil : kept
    }
    return changed
  }

  /// When the next typist's 3 s run out, nil with nobody typing.
  var nextExpiry: ContinuousClock.Instant? { typists.values.joined().map(\.expires).min() }
}

/// Every host's typing, app-wide (#696): one `events.subscribe` per host connection, kept to
/// `session.input`, and the `session.created` and `session.ended` that `workroom new` and
/// `workroom close` ask the app through (#693, handed to `TerminalRequests`), however many
/// windows show its panes. Each send restarts its sender's 3 s, and
/// one timer drops whoever went quiet. Panes hear about the sessions that changed through a
/// listener (`GhosttySurfaceView`'s typing marker), not through their tab's state, so a keystroke
/// re-renders the one marker it concerns and nothing else.
@MainActor
final class PaneTypingMonitor {
  static let shared = PaneTypingMonitor()

  /// Connects `host` and returns its connection, as `ProgramStatusMonitor.connect` does: the
  /// shared service connection program status subscribes on too.
  var connect: @Sendable (HostID) async throws -> any HostServiceConnection = { host in
    if host == .local { return try await LocalDaemonVCS.shared.programStatus() }
    try await RemoteHosts.shared.reachability.ensureConnected(host)
    return try await HostConnectionManager.shared.programStatus(host: host)
  }
  /// Waits between reconnects. A seam so tests reconnect at once.
  var backoff: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  /// Returns once `host`'s link comes up again as a new connection, so a retry need not wait out
  /// its backoff; never for this Mac's daemon.
  var reconnected: @Sendable (HostID) async -> Void = ProgramStatusMonitor.hostReconnected
  /// The monotonic clock the 3 s are measured on, and the wait until the next typist expires.
  /// Seams, so the timing tests run on a clock the test moves.
  var now: () -> ContinuousClock.Instant = { .now }
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  /// False in a test process or a fixture launch, which must never reach the developer's daemon,
  /// as for program status: a fixture launch with a scratch daemon of its own does watch it.
  var watchesHosts: Bool = {
    #if DEBUG
      if UITestFixture.liveDaemonDirectory != nil { return true }
    #endif
    return !AppEnvironment.current.isTestProcess
  }()

  private(set) var state = PaneTypingState()
  private var tasks: [HostID: Task<Void, Never>] = [:]
  private var expiry: Task<Void, Never>?
  private var listeners: [UUID: (Set<UUID>) -> Void] = [:]
  /// Hosts already logged as having no typing to tell, so it is said once.
  private var loggedUnsupported: Set<HostID> = []
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "pane-typing")

  /// `listener` hears the sessions whose typists changed, until the token is removed.
  func addListener(_ listener: @escaping (Set<UUID>) -> Void) -> UUID {
    let id = UUID()
    listeners[id] = listener
    return id
  }

  func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

  func typists(of session: UUID) -> [PaneTypingState.Typist] { state.typists(of: session) }

  /// Starts following `host`, once.
  func watch(_ host: HostID) {
    guard watchesHosts, tasks[host] == nil else { return }
    tasks[host] = Task { [weak self] in await self?.run(host) }
  }

  /// A removed host: its subscription ends, on its daemon too. Typing it told already runs out on
  /// its own.
  func forget(_ host: HostID) {
    tasks.removeValue(forKey: host)?.cancel()
    loggedUnsupported.remove(host)
  }

  /// `sender` typed into `session` now: from the host's events, or the UI-test fixture's seam.
  func typed(into session: UUID, by sender: UUID?) {
    guard sender != session else { return }
    state.typed(into: session, by: sender, at: now())
    // Every keystroke is told, not only a new typist: a marker names its sender as the sender's
    // tab is now, and the agent in it may have been recognised since the last one. A pane whose
    // marker reads the same draws nothing.
    notify([session])
    // One timer, set for the earliest expiry. A keystroke only ever moves expiries later, so a
    // timer already set fires early at worst, drops nobody, and sets itself again.
    if expiry == nil { scheduleExpiry() }
  }

  private func scheduleExpiry() {
    guard let next = state.nextExpiry else {
      expiry = nil
      return
    }
    let delay = max(.zero, next - now())
    let sleep = self.sleep
    expiry = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      guard let self else { return }
      let changed = self.state.expire(at: self.now())
      if !changed.isEmpty { self.notify(changed) }
      self.scheduleExpiry()
    }
  }

  private func notify(_ sessions: Set<UUID>) {
    for listener in listeners.values { listener(sessions) }
  }

  // MARK: Following a host

  private func run(_ host: HostID) async {
    var wait = ProgramStatusLimits.backoffFloor
    let name = String(describing: host)
    while !Task.isCancelled {
      // Whether the host has typing to tell: one that has none is asked again only on a new
      // connection, never on a timer.
      var unsupported = false
      do {
        let connection = try await connect(host)
        let (events, continuation) = AsyncStream<TerminalInputEvent>.makeStream()
        let availability = try await connection.subscribeTerminalInput {
          continuation.yield($0)
        }
        switch availability {
        case .available(let subscription):
          wait = ProgramStatusLimits.backoffFloor
          // Ended on the daemon as well when this stops listening (the host forgotten), so its
          // place there is free at once; a stream that ends on its own (`.lost`) needs nothing.
          await withTaskCancellationHandler {
            for await event in events {
              switch event {
              case .input(let session, let sender): typed(into: session, by: sender)
              // What `workroom new` and `workroom close` ask of the app (#693), on the same
              // subscription.
              case .opened, .closed: TerminalRequests.shared.handle(event, from: host)
              case .lost: break
              }
              if case .lost = event { break }
            }
          } onCancel: {
            subscription.end()
          }
          guard !Task.isCancelled else { return }
        case .refused(let reason):
          Self.logger.error(
            "typing: \(name, privacy: .public) refused: \(reason, privacy: .public)")
        case .unsupported:
          unsupported = true
          if loggedUnsupported.insert(host).inserted {
            Self.logger.info("typing: \(name, privacy: .public) has no typing to tell")
          }
        }
      } catch is CancellationError {
        return
      } catch {
        Self.logger.info(
          "typing: \(name, privacy: .public) not followed: \(String(describing: error), privacy: .public)"
        )
      }
      guard !Task.isCancelled else { return }
      let (backoff, reconnected, delay) = (self.backoff, self.reconnected, wait)
      if unsupported {
        await reconnected(host)
      } else {
        await withTaskGroup(of: Void.self) { group in
          group.addTask { try? await backoff(delay) }
          group.addTask { await reconnected(host) }
          await group.next()
          group.cancelAll()
        }
      }
      guard !Task.isCancelled else { return }
      wait = min(wait * 2, ProgramStatusLimits.backoffCeiling)
    }
  }
}
