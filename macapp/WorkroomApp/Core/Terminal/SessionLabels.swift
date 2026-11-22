import DaemonConnection
import Foundation
import OSLog
import WorkroomDomain

/// The tunable values of label sync (#694), each with the reason for its number.
enum SessionLabelLimits {
  /// How often a rename is tried before it is left for the next snapshot: a hand-off answers
  /// `Busy` for well under a second, and a link coming back up takes a few; 1 + 2 + 4 + 8 s covers
  /// both.
  static let attempts = 5
  /// The wait before the first retry, doubled for each after it.
  static let firstRetry: Duration = .seconds(1)
  /// The most labels kept heard of one host's sessions (`SessionLabels.heardLabels`): far more
  /// than a host holds sessions at once, so only ended ones are ever forgotten.
  static let heardPerHost = 4096
}

/// What a Mac does with a label its daemon told it (#694), from what one of its tabs of the
/// session shows and the label that tab last agreed with the daemon (`TerminalState.syncedLabel`).
/// Pure, so each rule is tested on its own.
enum SessionLabelRule {
  enum Action: Equatable {
    /// The tab takes the daemon's label, and agrees with it.
    case take
    /// The tab keeps its name, and tells the daemon it.
    case tell(String?)
    /// Nothing changes: the tab already shows it.
    case agree
    /// Nothing changes, and nothing is told.
    case nothing
  }

  /// `heard` is the daemon's label, cleaned; `local` the tab's session label, `applied` the one it
  /// would have with `heard` taken, `synced` what it last agreed; `live` for `session.labelled`,
  /// false for a snapshot's.
  ///
  /// - The tab shows it already: agreed.
  /// - The tab last agreed with the daemon on another label: when the tab hasn't changed since
  ///   (`local` is what it agreed), the daemon's changed, so it wins, a clear too; when the tab
  ///   has (renamed while the daemon couldn't be told), the tab's name is told.
  /// - The tab never agreed on one (from before #694): a live label wins; a snapshot's wins when it
  ///   is a name, and where the daemon has none (null, or the numbered "Terminal 2" an older build
  ///   gave every session) the tab's name is told, and none is cleared.
  static func action(
    heard: String?, live: Bool, local: String?, applied: String?, synced: SyncedLabel?
  ) -> Action {
    if applied == local { return .agree }
    if let synced {
      return local == synced.label ? .take : .tell(local)
    }
    if live { return .take }
    if heard.map(TerminalState.isNumberedName) ?? true {
      return local == nil ? .nothing : .tell(local)
    }
    return .take
  }
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
/// **Catching up.** Each tab keeps the label it last agreed with the daemon, saved with it. Each
/// subscription starts with a snapshot of every session's label, and every label heard is kept
/// for tabs that mount later (a workroom opened after it); each is weighed by `SessionLabelRule`:
/// a label set while this Mac wasn't listening wins over a name it never changed, a clear too, and
/// a name this Mac changed while the daemon couldn't be told is told it, however long ago its
/// tries gave up. A rename of this Mac's still on its way outranks any snapshot.
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
  /// The renames and catch-ups under way, by the order they were asked in, for `settled`.
  private var deliveries: [Int: Task<Void, Never>] = [:]
  private var asked = 0
  /// The last label each host's daemon told of each session, live or in a snapshot, for a tab
  /// that mounts after it (`mounted`).
  private var heardLabels: [HostID: [UUID: String?]] = [:]

  /// Returns once every rename and catch-up asked so far has finished: for tests.
  func settled() async {
    while let next = deliveries.values.first { await next.value }
  }

  /// Forgets every label heard: for a test, so the next one starts from nothing.
  func forgetHeard() { heardLabels.removeAll() }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "session-labels")

  private func track(_ work: @escaping @MainActor () async -> Void) {
    asked += 1
    let order = asked
    deliveries[order] = Task { [weak self] in
      await work()
      self?.deliveries.removeValue(forKey: order)
    }
  }

  /// A tab of `session` on `host` was renamed here, to `label` (nil: its name cleared): its
  /// session is labelled so, retried while the daemon is busy with a hand-off or the link is down.
  /// Once the daemon takes it, the tabs agree with it; until then the name stays this Mac's, and
  /// the next label heard of the session has it told (`SessionLabelRule`).
  func renamed(_ session: UUID, on host: HostID, to label: String?) {
    guard watchesHosts else { return }
    var entry = sending[session] ?? (count: 0, latest: 0)
    entry.count += 1
    entry.latest += 1
    sending[session] = entry
    let number = entry.latest
    track { [weak self] in
      await self?.deliver(label, to: session, on: host, number: number)
      self?.finished(session)
    }
  }

  private func finished(_ session: UUID) {
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
        case .labelled:
          for tab in tabs(of: session, on: host) {
            tab.holder.terminals.markLabelSynced(label, forTab: tab.tab, in: tab.target)
          }
          return
        case .unsupported:
          return
        case .refused(let kind, _) where kind == "TargetNotFound" || kind == "SessionEnded":
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
          "label: \(id, privacy: .public) not told after \(attempt) tries, told again once its daemon is heard: \(why, privacy: .public)"
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

  /// A tab of `session` on `host` mounted onto a session that already was: caught up from the
  /// label last heard of it, as a snapshot's is, once the tab is in its holder.
  func mounted(_ session: UUID, on host: HostID) {
    guard let heard = heardLabels[host]?[session] else { return }
    track { [weak self] in self?.weigh(heard, of: session, on: host, live: false) }
  }

  private func tabs(of session: UUID, on host: HostID) -> [(
    holder: any TerminalRequestHolder, target: TerminalTarget, tab: TerminalTab.ID
  )] {
    holders().flatMap { holder in
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
  }

  private func heard(_ label: String?, of session: UUID, on host: HostID, live: Bool) {
    var kept = heardLabels[host] ?? [:]
    if kept.count >= SessionLabelLimits.heardPerHost, kept[session] == nil { kept.removeAll() }
    kept[session] = .some(label)
    heardLabels[host] = kept
    weigh(label, of: session, on: host, live: live)
  }

  private func weigh(_ label: String?, of session: UUID, on host: HostID, live: Bool) {
    let tabs = tabs(of: session, on: host)
    guard let first = tabs.first,
      let sync = first.holder.terminals.labelSync(ofTab: first.tab, in: first.target),
      case .some(let applied) = first.holder.terminals.sessionLabel(
        ofTab: first.tab, in: first.target, applying: label)
    else { return }
    // A rename of this Mac's on its way is newer than any snapshot.
    if !live, sending[session] != nil { return }
    let cleaned = TerminalPanes.cleanedName(label)
    let local = sync.local
    switch SessionLabelRule.action(
      heard: cleaned, live: live, local: local, applied: applied, synced: sync.synced)
    {
    case .agree:
      for tab in tabs {
        tab.holder.terminals.markLabelSynced(cleaned, forTab: tab.tab, in: tab.target)
      }
      // A run tab's "Run", which a cleared label leaves it showing: told, so the terminal API
      // names it as the tab does.
      if let local, local != cleaned { renamed(session, on: host, to: local) }
    case .take:
      for tab in tabs {
        tab.holder.terminals.applySessionLabel(label, forTab: tab.tab, in: tab.target)
      }
      if let applied, applied != cleaned { renamed(session, on: host, to: applied) }
    case .tell(let name):
      renamed(session, on: host, to: name)
    case .nothing:
      break
    }
  }
}
