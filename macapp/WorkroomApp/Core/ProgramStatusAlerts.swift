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
  /// Counted in the badge: alerts are on, and its program answered the probe, or the agent saw
  /// it stay running, or Workroom alerted it (#481).
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
  /// Episodes Workroom has alerted, or will once a cooldown ends: only these absorb the program's own
  /// notification, so one that arrives for a request Workroom never raised is still shown.
  private var raised: Set<String> = []
  /// The last alert surfaced per terminal tab, for the rate limit.
  private var lastSurfaced: [TerminalTab.ID: (date: Date, episode: String)] = [:]
  private var deferred: [String: Task<Void, Never>] = [:]
  private var lastOSC: [UUID: (title: String, body: String?, date: Date)] = [:]
  /// A reporting program's own notification, waiting for the request it may announce (#481).
  private var held: [UUID: (body: String?, show: Show, task: Task<Void, Never>)] = [:]
  /// The program's own notification last shown per session, until a request's alert replaces it.
  private var shown: [UUID: (date: Date, body: String?, withdraw: () -> Void)] = [:]

  /// Records and surfaces a program's own notification as an ordinary one, and returns how to
  /// withdraw it; nil when nothing was shown (its pane is the one being looked at).
  typealias Show = () -> (() -> Void)?

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
      for (key, record) in keys {
        if open[key] == nil {
          open[key] = (session, record.id)
          // There before the app was: shown, never alerted.
          if change.isLaunchSnapshot { notified.insert(key) }
        }
        // A program that never probed alerts once the agent has seen it stay running, or once
        // its own notification announced the request (#481).
        if !notified.contains(key), record.notify || held[session] != nil {
          let held = takeHeldEntry(session)
          // Workroom will not alert it (its terminal is being looked at): the program's own
          // notification is shown as before.
          if !alert(key, session: session, record: record, detail: held?.body), let held {
            showNow(session, body: held.body, held.show)
          }
        }
      }
    }
    recomputeWaiting()
  }

  /// A pane stopped showing `session` (Detached sessions › Active tab) while it still runs: once
  /// no pane shows it, its alerts go, since they would open a pane showing another session. The
  /// requests stay open, so a pane attaching to it again lists them as waiting.
  func paneLeft(session: UUID) {
    guard attachments(of: session).isEmpty else { return }
    for (key, entry) in open where entry.session == session {
      deferred.removeValue(forKey: key)?.cancel()
      for store in stores() { store.withdrawNeedsYou(episode: key) }
    }
    recomputeWaiting()
  }

  /// A request left `blocked`: answered here or elsewhere, or its program ended.
  private func resolve(_ key: String) {
    open.removeValue(forKey: key)
    deferred.removeValue(forKey: key)?.cancel()
    for store in stores() { store.withdrawNeedsYou(episode: key) }
  }

  /// `detail` is the program's own notification text, for a request whose report has no message.
  /// False when it will not alert: alerts are off, or someone is looking at the terminal.
  @discardableResult
  private func alert(
    _ key: String, session: UUID, record: ProgramStatusRecord, detail: String? = nil
  ) -> Bool {
    notified.insert(key)
    guard isEnabled() else { return false }
    let attachments = attachments(of: session)
    // Looking at it already, in any window: nothing to say.
    guard let destination = attachments.first, !attachments.contains(where: \.focused) else {
      return false
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
        self.post(key, session: session, record: record, detail: detail)
      }
      return true
    }
    post(key, session: session, record: record, detail: detail)
    return true
  }

  private func post(
    _ key: String, session: UUID, record: ProgramStatusRecord, detail: String?
  ) {
    guard open[key] != nil, isEnabled() else { return }
    let attachments = attachments(of: session)
    guard let destination = attachments.first, !attachments.contains(where: \.focused) else {
      return
    }
    lastSurfaced[destination.tab] = (now(), key)
    raised.insert(key)
    var detail = detail
    // The program's own notification, shown moments ago because its request came late: the alert
    // replaces it rather than following it.
    if let earlier = shown.removeValue(forKey: session),
      now().timeIntervalSince(earlier.date) <= ProgramStatusLimits.notificationBackstop.seconds
    {
      earlier.withdraw()
      detail = detail ?? earlier.body
    }
    destination.store.raiseNeedsYou(
      targetID: destination.target, tabID: destination.tab, episode: key, record: record,
      detail: detail
    ) { [weak self] in self?.isStillWaiting(key, session: session) ?? false }
  }

  /// Right before a banner posts (after notification permission resolves): the request still waits,
  /// nobody is looking at its terminal, and alerts are still on.
  func isStillWaiting(_ key: String, session: UUID) -> Bool {
    open[key] != nil && isEnabled() && !attachments(of: session).contains(where: \.focused)
  }

  // MARK: The program's own notification

  /// A program's own notification (`.osc`) from a terminal of `session`: one request, one
  /// notification (#481). Dropped when another pane of the session raised the same one a moment
  /// ago; folded into its session's newest open request when Workroom has alerted it, whenever it
  /// comes (Claude Code's comes 6 s after its report), or raising it, with its text, when it has
  /// not alerted yet; held for `notificationHold` when the program reports but has no request yet
  /// (Codex writes its own just before its report); otherwise shown through `show`.
  func programNotified(session: UUID, title: String, body: String?, show: @escaping Show) {
    let date = now()
    if let last = lastOSC[session], last.title == title, last.body == body,
      date.timeIntervalSince(last.date) < ProgramStatusLimits.attachmentDedupe.seconds
    {
      return
    }
    lastOSC[session] = (title, body, date)
    // With alerts off, the program's own notification is all the user gets, as before.
    guard isEnabled(), let current = monitor.sessions[session] else {
      return showNow(session, body: body, show)
    }
    let requests = current.records
      .filter { $0.state == .blocked }
      .map { (key: Self.episode(boot: current.boot, session: session, record: $0), record: $0) }
      .filter { open[$0.key] != nil }
      .sorted {
        let since = { current.blockedSince[ProgramStatusSession.blockedKey($0)] ?? .distantPast }
        return since($0.record) > since($1.record)
      }
    if let request = requests.first {
      if raised.contains(request.key) {
        for store in stores() { store.mergeIntoNeedsYou(episode: request.key, body: body) }
      } else if notified.contains(request.key)
        || !alert(request.key, session: session, record: request.record, detail: body)
      {
        // A request Workroom does not alert (its terminal is being looked at): shown as before.
        showNow(session, body: body, show)
      }
      recomputeWaiting()
    } else if current.reporting {
      if let earlier = takeHeldEntry(session) { showNow(session, body: earlier.body, earlier.show) }
      let task = Task { [weak self] in
        try? await self?.sleep(ProgramStatusLimits.notificationHold)
        guard let self, !Task.isCancelled, let held = self.takeHeldEntry(session) else { return }
        self.showNow(session, body: held.body, held.show)
      }
      held[session] = (body, show, task)
    } else {
      showNow(session, body: body, show)
    }
  }

  private func showNow(_ session: UUID, body: String?, _ show: Show) {
    guard let withdraw = show() else { return }
    shown[session] = (now(), body, withdraw)
  }

  private func takeHeldEntry(_ session: UUID) -> (body: String?, show: Show)? {
    guard let entry = held.removeValue(forKey: session) else { return nil }
    entry.task.cancel()
    return (entry.body, entry.show)
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
        stale: monitor.hosts[session.host] == .stale,
        counted: (record.notify || raised.contains(key)) && enabled)
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
