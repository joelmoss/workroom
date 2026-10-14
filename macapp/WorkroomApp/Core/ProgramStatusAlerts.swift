import AgentConnection
import AppKit
import Defaults
import Foundation

/// One request a program is waiting on the user for, as the Dock badge, the menu bar's list and
/// ⇧⌘M see it (#358).
struct WaitingRequest: Identifiable, Equatable {
  /// The attention episode: boot, session, record id and episode number.
  let id: String
  let session: UUID
  let record: ProgramStatusRecord
  let since: Date
  /// Its host's link is down: it may have been answered meanwhile.
  let stale: Bool
  /// Counted in the badge: its program answered the probe, and alerts are on.
  let counted: Bool
}

/// Alerts for terminals that need the user, app-wide (#358). It hears every program-status change
/// from `ProgramStatusMonitor`, raises one alert per attention episode in the window the user last
/// used that terminal in, folds the program's own notification into it, and keeps the list of
/// waiting requests the badge and the menu bar count.
///
/// An episode is (agent boot, session, record id, episode number): the agent numbers each entry
/// into `blocked` from one counter per session, so a request that resolves and comes back is a new
/// episode, and a hand-off, which keeps `boot`, re-alerts nothing.
@MainActor
final class ProgramStatusAlerts: ObservableObject {
  static let shared = ProgramStatusAlerts()

  /// Every request waiting in a terminal attached in an open window, oldest first.
  @Published private(set) var waiting: [WaitingRequest] = []

  var monitor: ProgramStatusMonitor = .shared
  var stores: () -> [AppStore] = { WindowRegistry.shared.allStores }
  var isEnabled: () -> Bool = { Defaults[.notifyWhenTerminalNeedsMe] }
  var now: () -> Date = Date.init
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  /// Told when `waiting` changes, so the Dock badge and the menu bar follow (`WindowRegistry`).
  var onWaitingChange: (() -> Void)?

  private var listener: UUID?
  /// Episodes now blocked, with the session and record they belong to.
  private var open: [String: (session: UUID, record: String)] = [:]
  private var notified: Set<String> = []
  private var merged: Set<String> = []
  /// Episodes Workroom has alerted, or will once a cooldown ends: only these absorb the program's own
  /// notification, so one that arrives for a request Workroom never raised is still shown.
  private var raised: Set<String> = []
  /// The last alert surfaced per terminal tab, for the rate limit.
  private var lastSurfaced: [TerminalTab.ID: (date: Date, episode: String)] = [:]
  private var deferred: [String: Task<Void, Never>] = [:]
  private var lastOSC: [UUID: (title: String, body: String?, date: Date)] = [:]

  func start() {
    guard listener == nil else { return }
    listener = monitor.addListener { [weak self] in self?.apply($0) }
  }

  static func episode(boot: String, session: UUID, record: ProgramStatusRecord) -> String {
    "\(boot)/\(session.uuidString.lowercased())/\(record.id)/\(record.episode)"
  }

  // MARK: Episodes

  func apply(_ change: ProgramStatusMonitor.Change) {
    for session in change.sessions {
      let current = monitor.sessions[session]
      let blocked = (current?.records ?? []).filter { $0.state == .blocked }
      let keys = Dictionary(
        blocked.map { (Self.episode(boot: current?.boot ?? "", session: session, record: $0), $0) },
        uniquingKeysWith: { first, _ in first })
      for (key, entry) in open where entry.session == session && keys[key] == nil {
        resolve(key)
      }
      for (key, record) in keys where open[key] == nil {
        open[key] = (session, record.id)
        if change.isLaunchSnapshot || !record.notify {
          // There before the app was, or reported by a program that never asked whether this
          // terminal supports the protocol: shown, never alerted.
          notified.insert(key)
        } else if !notified.contains(key) {
          alert(key, session: session, record: record)
        }
      }
    }
    recomputeWaiting()
  }

  /// A request left `blocked`: answered here or elsewhere, or its program ended.
  private func resolve(_ key: String) {
    open.removeValue(forKey: key)
    deferred.removeValue(forKey: key)?.cancel()
    for store in stores() { store.withdrawNeedsYou(episode: key) }
  }

  private func alert(_ key: String, session: UUID, record: ProgramStatusRecord) {
    notified.insert(key)
    guard isEnabled() else { return }
    let attachments = attachments(of: session)
    // Looking at it already, in any window: nothing to say.
    guard let destination = attachments.first, !attachments.contains(where: \.focused) else {
      return
    }
    if let last = lastSurfaced[destination.tab], open[last.episode] != nil,
      now().timeIntervalSince(last.date) < ProgramStatusLimits.notifyCooldown.seconds
    {
      // The tab's previous request is still open and alerted moments ago: a program toggling its
      // state cannot flood the user. This one surfaces when the cooldown ends, if it still waits.
      let delay = ProgramStatusLimits.notifyCooldown.seconds - now().timeIntervalSince(last.date)
      raised.insert(key)
      deferred[key] = Task { [weak self] in
        try? await self?.sleep(.seconds(delay))
        guard let self, !Task.isCancelled else { return }
        self.deferred.removeValue(forKey: key)
        self.post(key, session: session, record: record)
      }
      return
    }
    post(key, session: session, record: record)
  }

  private func post(_ key: String, session: UUID, record: ProgramStatusRecord) {
    guard open[key] != nil, isEnabled() else { return }
    let attachments = attachments(of: session)
    guard let destination = attachments.first, !attachments.contains(where: \.focused) else {
      return
    }
    lastSurfaced[destination.tab] = (now(), key)
    raised.insert(key)
    destination.store.raiseNeedsYou(
      targetID: destination.target, tabID: destination.tab, episode: key, record: record
    ) { [weak self] in self?.isStillWaiting(key, session: session) ?? false }
  }

  /// Right before a banner posts (after notification permission resolves): the request still waits,
  /// nobody is looking at its terminal, and alerts are still on.
  func isStillWaiting(_ key: String, session: UUID) -> Bool {
    open[key] != nil && isEnabled() && !attachments(of: session).contains(where: \.focused)
  }

  // MARK: The program's own notification

  /// Whether `.osc` from a terminal of `session` is absorbed rather than recorded: the same alert
  /// raised by another pane of the session a moment ago, or the program's own alert about the
  /// request Workroom has already raised. Claude Code's arrives 6.0 s after its report (measured),
  /// so it merges only when exactly one request in the session began within `mergeWindow` and has
  /// not merged yet; anything ambiguous stays a separate entry.
  func absorbsOSC(session: UUID, title: String, body: String?) -> Bool {
    let date = now()
    if let last = lastOSC[session], last.title == title, last.body == body,
      date.timeIntervalSince(last.date) < ProgramStatusLimits.attachmentDedupe.seconds
    {
      return true
    }
    lastOSC[session] = (title, body, date)
    // With alerts off, the program's own notification is all the user gets, as before.
    guard isEnabled(), let current = monitor.sessions[session] else { return false }
    let blocked = current.records.filter { $0.state == .blocked }
    guard blocked.count == 1, let record = blocked.first else { return false }
    let key = Self.episode(boot: current.boot, session: session, record: record)
    let began = current.blockedSince[ProgramStatusSession.blockedKey(record)] ?? .distantPast
    guard raised.contains(key), !merged.contains(key),
      date.timeIntervalSince(began) <= ProgramStatusLimits.mergeWindow.seconds
    else { return false }
    merged.insert(key)
    for store in stores() { store.mergeIntoNeedsYou(episode: key, body: body) }
    return true
  }

  // MARK: Waiting requests

  /// The attachments of `session` in open windows, the one the user focused last first.
  private func attachments(of session: UUID) -> [Attachment] {
    let found = stores().flatMap { store in
      store.terminals.attachments(of: session).map {
        Attachment(store: store, target: $0.target, tab: $0.tab, focused: $0.focused)
      }
    }
    let recency = SwitcherRecency.shared.panes.ids
    return found.sorted {
      (recency.firstIndex(of: $0.tab) ?? .max) < (recency.firstIndex(of: $1.tab) ?? .max)
    }
  }

  private struct Attachment {
    let store: AppStore
    let target: TerminalTarget.ID
    let tab: TerminalTab.ID
    let focused: Bool
  }

  func recomputeWaiting() {
    let enabled = isEnabled()
    let next = open.compactMap { key, entry -> WaitingRequest? in
      guard let session = monitor.sessions[entry.session],
        let record = session.records.first(where: {
          $0.id == entry.record && $0.state == .blocked
            && Self.episode(boot: session.boot, session: entry.session, record: $0) == key
        }),
        !attachments(of: entry.session).isEmpty
      else { return nil }
      return WaitingRequest(
        id: key, session: entry.session, record: record,
        since: session.blockedSince[ProgramStatusSession.blockedKey(record)] ?? .distantPast,
        stale: monitor.hosts[session.host] == .stale, counted: record.notify && enabled)
    }
    .sorted { ($0.since, $0.id) < ($1.since, $1.id) }
    guard next != waiting else { return }
    waiting = next
    onWaitingChange?()
  }

  /// How many waiting requests the badge counts.
  var countedWaiting: Int { waiting.count { $0.counted } }

  /// Where `request` is shown: "Terminal 2 in fix-auth", in the window it was last focused in.
  func place(of request: WaitingRequest) -> String? {
    guard let destination = attachments(of: request.session).first else { return nil }
    return destination.store.terminalPlace(targetID: destination.target, tabID: destination.tab)
  }

  /// Opens the terminal `request` waits in, raising its window.
  func open(_ request: WaitingRequest) {
    guard let destination = attachments(of: request.session).first else { return }
    destination.store.hostWindow?.makeKeyAndOrderFront(nil)
    destination.store.openTerminal(targetID: destination.target, tabID: destination.tab)
  }

  // MARK: ⇧⌘M

  /// Go to the terminal that has waited longest; from a waiting terminal, to the next one, wrapping.
  /// Returns false (the caller beeps) when there is nowhere else to go.
  @discardableResult
  func goToNextWaiting(from keyStore: AppStore?) -> Bool {
    var sessions: [UUID] = []
    for request in waiting where !sessions.contains(request.session) {
      sessions.append(request.session)
    }
    guard let next = Self.next(after: keyStore?.focusedTerminalSession, in: sessions),
      let destination = attachments(of: next).first
    else { return false }
    destination.store.hostWindow?.makeKeyAndOrderFront(nil)
    destination.store.openTerminal(targetID: destination.target, tabID: destination.tab)
    return true
  }

  /// The waiting session after `current` in `ordered` (oldest first), wrapping; the oldest when
  /// `current` is not waiting; nil when there is nothing else to go to.
  static func next(after current: UUID?, in ordered: [UUID]) -> UUID? {
    guard let current, let index = ordered.firstIndex(of: current) else { return ordered.first }
    let next = ordered[(index + 1) % ordered.count]
    return next == current ? nil : next
  }
}

extension Duration {
  fileprivate var seconds: TimeInterval {
    TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
