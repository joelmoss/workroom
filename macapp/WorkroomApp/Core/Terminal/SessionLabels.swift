import DaemonConnection
import Foundation
import OSLog
import WorkroomDomain

/// The tunable values of label sync (#694), each with the reason for its number.
enum SessionLabelLimits {
  /// How often a rename is tried before it is given up on: a hand-off answers `Busy` for well
  /// under a second, and a link coming back up takes a few; 1 + 2 + 4 + 8 s covers both.
  static let attempts = 5
  /// The wait before the first retry, doubled for each after it.
  static let firstRetry: Duration = .seconds(1)
}

/// A terminal's name and its session's label are one name (#694), kept in sync both ways: a tab
/// renamed here labels its session on its host's daemon (`session.label`), and a label the daemon
/// tells (`session.labelled`, from a script, an agent or another Mac) renames every tab of that
/// session in every window here, the Quick Terminal's and popped-out panes' included. A terminal
/// group's own name is no session's label and stays the app's.
///
/// **No loop.** A label heard from the daemon renames a tab through
/// `TerminalPanes.applySessionLabel`, which never tells the daemon, and the daemon tells nothing
/// for a label a session already has, so the app's own rename, heard back, ends there.
///
/// **Catching up.** Each subscription starts with a snapshot of every session's label, which a Mac
/// that wasn't listening (asleep, offline, or reconnecting after a hand-off) catches up from: a
/// name the daemon has wins; where it has none (null, or the numbered "Terminal 2" an older build
/// gave every session), a name a tab here has is told it. A snapshot never clears a name here, and
/// a rename of this Mac's still on its way outranks it.
@MainActor
final class SessionLabels {
  static let shared = SessionLabels()

  /// Every holder of tabs: each window's store, then the Quick Terminal's host. A seam for tests.
  var holders: () -> [any TerminalRequestHolder] = { TerminalRequests.shared.holders() }
  /// Labels `session` on `host`'s daemon, on the service connection program status and typing
  /// use. A seam so tests never reach a daemon.
  var send: @Sendable (HostID, UUID, String?) async throws -> TerminalLabelOutcome = {
    host, session, label in
    let connection: any HostServiceConnection
    if host == .local {
      connection = try await LocalDaemonVCS.shared.programStatus()
    } else {
      try await RemoteHosts.shared.reachability.ensureConnected(host)
      connection = try await HostConnectionManager.shared.programStatus(host: host)
    }
    return try await connection.labelSession(session, label: label)
  }
  /// Waits between tries of a rename. A seam so tests retry at once.
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  /// False in a test process or a fixture launch, which must never reach the developer's daemon,
  /// as for typing: a fixture launch with a scratch daemon of its own does tell it.
  var watchesHosts: Bool = {
    #if DEBUG
      if UITestFixture.liveDaemonDirectory != nil { return true }
    #endif
    return !AppEnvironment.current.isTestProcess
  }()

  /// Each session's renames: how many are on their way, and the latest one's number, which a
  /// retry of an earlier one gives way to.
  private var sending: [UUID: (count: Int, latest: Int)] = [:]
  /// The renames under way, by the order they were asked in, for `settled` to wait on.
  private var deliveries: [Int: Task<Void, Never>] = [:]
  private var asked = 0

  /// Returns once every rename asked so far has been told or given up on: for tests.
  func settled() async {
    while let next = deliveries.values.first { await next.value }
  }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "session-labels")

  /// A tab of `session` on `host` was renamed here, to `label` (nil: its name cleared): its
  /// session is labelled so, retried while the daemon is busy with a hand-off or the link is down.
  /// A rename that can't be told keeps its name here, and the next snapshot tells it.
  func renamed(_ session: UUID, on host: HostID, to label: String?) {
    guard watchesHosts else { return }
    var entry = sending[session] ?? (count: 0, latest: 0)
    entry.count += 1
    entry.latest += 1
    sending[session] = entry
    let number = entry.latest
    asked += 1
    let order = asked
    deliveries[order] = Task { [weak self] in
      await self?.deliver(label, to: session, on: host, number: number)
      self?.finished(session, order: order)
    }
  }

  private func finished(_ session: UUID, order: Int) {
    deliveries.removeValue(forKey: order)
    guard var entry = sending[session] else { return }
    entry.count -= 1
    sending[session] = entry.count > 0 ? entry : nil
  }

  private func deliver(_ label: String?, to session: UUID, on host: HostID, number: Int) async {
    let id = session.uuidString
    var wait = SessionLabelLimits.firstRetry
    for attempt in 1...SessionLabelLimits.attempts {
      // A later rename of the same session is the one to tell.
      guard sending[session]?.latest == number else { return }
      let why: String
      do {
        switch try await send(host, session, label) {
        case .labelled, .unsupported:
          return
        case .refused(let kind, _) where kind == "TargetNotFound":
          // Its session has ended: nothing to label.
          return
        case .refused(let kind, let message):
          why = "\(kind): \(message)"
        }
      } catch is CancellationError {
        return
      } catch {
        why = String(describing: error)
      }
      guard attempt < SessionLabelLimits.attempts else {
        Self.logger.error(
          "label: \(id, privacy: .public) not told after \(attempt) tries: \(why, privacy: .public)"
        )
        return
      }
      do { try await sleep(wait) } catch { return }
      wait *= 2
    }
  }

  /// One label `host`'s daemon told: live (`session.labelled`), or as a snapshot gives it.
  func handle(_ event: TerminalInputEvent, from host: HostID) {
    switch event {
    case .labelled(let session, let label): heard(label, of: session, on: host, live: true)
    case .listed(let session, let label): heard(label, of: session, on: host, live: false)
    case .input, .opened, .closed, .lost: break
    }
  }

  private func heard(_ label: String?, of session: UUID, on host: HostID, live: Bool) {
    let tabs = holders().flatMap { holder in
      holder.terminals.attachments(of: session).compactMap {
        attachment -> (
          holder: any TerminalRequestHolder, target: TerminalTarget, tab: TerminalTab.ID
        )?
        in
        guard let target = holder.terminalTarget(forID: attachment.target), target.hostID == host
        else { return nil }
        return (holder, target, attachment.tab)
      }
    }
    guard !tabs.isEmpty else { return }
    let cleaned = TerminalPanes.cleanedName(label)
    if !live {
      // A rename of this Mac's on its way is newer than any snapshot.
      guard sending[session] == nil else { return }
      if cleaned == nil || cleaned.map(TerminalState.isNumberedName) == true {
        // The daemon has no name for it: one a tab here has is told it, and none is cleared.
        let ours = tabs.lazy.compactMap { tab in
          tab.holder.terminals.sessionLabel(ofTab: tab.tab, in: tab.target)
        }.first
        if let ours, ours != label { renamed(session, on: host, to: ours) }
        return
      }
    }
    var shown: String?
    for tab in tabs {
      let now = tab.holder.terminals.applySessionLabel(label, forTab: tab.tab, in: tab.target)
      if shown == nil, case .some(.some(let name)) = now { shown = name }
    }
    // A label that names nothing these tabs show (cleared on a run tab, which shows "Run"): the
    // name they show is told, so the API names it as they do. Never a clear: a name is told only
    // where the daemon has none, which ends there.
    if let shown, shown != cleaned { renamed(session, on: host, to: shown) }
  }
}
