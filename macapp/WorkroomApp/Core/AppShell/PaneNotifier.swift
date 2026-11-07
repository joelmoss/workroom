import AppKit
import DaemonConnection
import Foundation

/// What a `PaneNotifier` asks of the host it notifies for: where the user is looking, and how the
/// host names its terminals. Read on each use, never kept, so a host that changes its window,
/// selection or system notifier (tests stand a fake in after init) is answered live.
@MainActor
protocol PaneNotifierHost: NotifyingHost {
  /// The host's notifications and toast queue, which its notifying members forward to.
  var paneNotifier: PaneNotifier { get }
  /// Whether the host's window is the key window: the user is looking at it.
  var isHostWindowKey: Bool { get }
  /// The target the host's window shows first: its pinned one, else its selection.
  var primaryTargetID: TerminalTarget.ID? { get }
  /// The on-screen target for `targetID`, nil when it isn't shown.
  func onScreenTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget?
  /// Whether the window `tabID` is popped out into is key; nil for a docked pane (issue #172).
  func detachedWindowIsKey(forTab tabID: TerminalTab.ID) -> Bool?
  /// The origin line of an ordinary notification.
  func notificationSource(forTargetID id: TerminalTarget.ID) -> String
  /// The origin line under an alert's title, which already names the workroom.
  func placeSource(targetID: TerminalTarget.ID) -> String
}

/// A host's notifying members, answered by its `paneNotifier`.
extension PaneNotifierHost {
  /// Raise the alert for a request a program in `tabID` waits on (`PaneNotifier.raiseNeedsYou`).
  func raiseNeedsYou(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, episode: String,
    record: ProgramStatusRecord, detail: String? = nil, stillWanted: @escaping () -> Bool
  ) {
    paneNotifier.raiseNeedsYou(
      targetID: targetID, tabID: tabID, episode: episode, record: record, detail: detail,
      stillWanted: stillWanted)
  }

  /// Alert that the program in `tabID` finished its turn while nobody was looking
  /// (`PaneNotifier.raiseFinished`).
  func raiseFinished(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, record: ProgramStatusRecord,
    detail: String? = nil
  ) {
    paneNotifier.raiseFinished(targetID: targetID, tabID: tabID, record: record, detail: detail)
  }

  /// The program's own text for a request already raised (see `ProgramStatusAlerts.programNotified`).
  func mergeIntoNeedsYou(episode: String, body: String?) {
    paneNotifier.mergeIntoNeedsYou(episode: episode, body: body)
  }

  /// The request was answered, or its program ended: its alert and banner go.
  func withdrawNeedsYou(episode: String) { paneNotifier.withdrawNeedsYou(episode: episode) }

  /// Append a toast to this host's queue, dropping the oldest once past the cap (issue #31).
  func enqueueToast(_ note: WorkroomNotification) { paneNotifier.enqueueToast(note) }

  /// The host's toast queue (issue #31), `PaneNotifier.toasts`: a read here registers with the
  /// notifier's Observation, so a view reading it re-renders as toasts come and go.
  var toasts: [WorkroomNotification] { paneNotifier.toasts }

  /// Remove a toast by id — on tap (after `openTerminal`), on auto-dismiss, or when its underlying
  /// notification is dismissed elsewhere (`ToastStack` prunes those).
  func dismissToast(_ id: UUID) { paneNotifier.dismissToast(id) }

  /// Where this host's in-app toasts go instead of its own `toasts` (`PaneNotifier.forwardToast`).
  var forwardToast: ((WorkroomNotification) -> Void)? {
    get { paneNotifier.forwardToast }
    set { paneNotifier.forwardToast = newValue }
  }

  /// Whether the app is frontmost (`PaneNotifier.isAppActive`), a test seam.
  var isAppActive: () -> Bool {
    get { paneNotifier.isAppActive }
    set { paneNotifier.isAppActive = newValue }
  }
}

/// One host's notifications: it records its terminals' activity and program-status alerts in the
/// shared list, surfaces each as a toast or a banner, and keeps the host's toast queue (issue #31).
/// Each host owns one and forwards to it (`PaneNotifierHost`).
///
/// Records carry `origin`, the host's identity, never this object's: a closing host drops what it
/// raised by its own `ObjectIdentifier` (`WindowRegistry.dropNotifications(raisedBy:)`), and a
/// workroom moving between windows repoints its records by the windows' (`repoint`).
@MainActor
@Observable
final class PaneNotifier {
  /// The identity of the host this raises for, on every record. Taken from the host itself, so no
  /// host can hand in another's.
  let origin: ObjectIdentifier
  @ObservationIgnored private weak var host: (any PaneNotifierHost)?
  @ObservationIgnored private let terminals: TerminalPanes
  @ObservationIgnored private let notifications: NotificationCenterStore

  /// Bottom-right toast queue (issue #31): the foreground, inspector-*closed* surface for a new
  /// notification. FIFO, capped at `maxToasts` (a new toast beyond the cap pushes the oldest out);
  /// each toast carries the `WorkroomNotification` it mirrors so a tap can route via `openTerminal`.
  /// Rendered by `ToastStack`, overlaid bottom-right in `RootView`.
  private(set) var toasts: [WorkroomNotification] = []
  /// Max simultaneously-visible toasts; beyond this the oldest is dropped so a chatty emitter can't
  /// overflow the window (matches the "stack a few, drop oldest" decision).
  private static let maxToasts = 4
  /// Where this host's in-app toasts go instead of its own `toasts`: the front window, set by
  /// `WindowRegistry` for every window it registers and by the Quick Terminal for its host.
  @ObservationIgnored var forwardToast: ((WorkroomNotification) -> Void)?
  /// Whether the app is frontmost, which picks an in-app toast over a banner. A seam so a test can
  /// take the banner path (`ProgramStatusAlertsTests`).
  @ObservationIgnored var isAppActive: () -> Bool = { NSApp.isActive }

  init(
    host: any PaneNotifierHost, terminals: TerminalPanes, notifications: NotificationCenterStore
  ) {
    self.origin = ObjectIdentifier(host)
    self.host = host
    self.terminals = terminals
    self.notifications = notifications
  }

  // MARK: Activity

  /// Record a terminal's activity, then surface it: backgrounded ⇒ a native banner; foregrounded ⇒
  /// an in-app toast (inspector closed) or a sidebar row flash (inspector open), plus the arrival
  /// sound (issue #31). `record` drops the event entirely when the user is already looking at that
  /// terminal, so none of these fire for the focused terminal.
  func handleActivity(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, activity: TerminalActivity
  ) {
    guard let host else { return }
    // pane state (frontmost = THIS window is key)  → outcome
    //   selected + cursor                          → SEEN: suppress (you're looking at it)
    //   on-screen, not cursor (split-mate)         → pulse (locator) + notify
    //   off-screen                                 → notify (no pulse)
    //   backgrounded / another window key          → banner (no pulse)
    //   detached, its own window key               → SEEN: suppress (issue #172)
    //   detached, its own window not key           → notify (no pulse)
    //
    // `seen` (suppress?) keys on the host window's `isKeyWindow` — is THIS pane the one focused.
    // The banner-vs-in-app routing below keys on `NSApp.isActive` — is the APP frontmost at all.
    // Two different questions, deliberately different vocabulary: a frontmost-but-not-key window
    // still shows an in-app toast, never a banner. (`isKeyWindow` already implies the app is
    // active.) Per-window so a *non-key* window's selected cursor tab still notifies (issue #89,
    // multi-window) instead of being suppressed because some other window holds key.
    let appFrontmost = host.isHostWindowKey
    let onScreen = host.onScreenTarget(forID: targetID)
    let isSelectedMember = onScreen?.id == host.primaryTargetID
    let isCursorTab = onScreen.map { terminals.focusedTab(for: $0)?.id == tabID } ?? false
    let outcome = AppStore.activityOutcome(
      appFrontmost: appFrontmost, isOnScreen: onScreen != nil,
      isSelectedMember: isSelectedMember, isCursorTab: isCursorTab,
      detachedWindowKey: host.detachedWindowIsKey(forTab: tabID))
    if outcome.pulse { terminals.pulsePaneActivity(tabID) }
    let show = { [weak self] () -> (() -> Void)? in
      guard let self, outcome.record, let host = self.host,
        let note = self.notifications.record(
          targetID: targetID, tabID: tabID, source: host.notificationSource(forTargetID: targetID),
          activity: activity, focused: false, origin: self.origin)
      else { return nil }
      self.surface(note)
      return { [weak self] in self?.withdrawNotification(note) }
    }
    // A program's own notification goes through its session's requests, so one request makes one
    // notification (#358, #481): folded into its alert, held for it, or shown.
    if case .osc(let title, let body) = activity,
      let session = terminals.sessionID(forTab: tabID, inTarget: targetID)
    {
      ProgramStatusAlerts.shared.programNotified(
        session: session, title: title, body: body, show: show)
      return
    }
    _ = show()
  }

  /// A program's own notification that a "needs you" alert replaces (#481): its toast, its entry
  /// and its banner, which is keyed by tab.
  private func withdrawNotification(_ note: WorkroomNotification) {
    toasts.removeAll { $0.id == note.id }
    notifications.dismiss(notifID: note.id)
    host?.systemNotifier.withdraw(identifiers: [note.tabID.uuidString])
  }

  // MARK: Program status alerts (#358)

  /// Raise the alert for a request a program in `tabID` waits on: "Terminal 2 in fix-auth needs
  /// you" (the terminal's own name, never the title its program set, and its workroom, or project
  /// for a root), the kind sentence, then the program's own words, quoted. `stillWanted` is asked
  /// again right before a banner posts, since asking for permission can take as long as the user
  /// takes to answer.
  func raiseNeedsYou(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, episode: String,
    record: ProgramStatusRecord, detail: String?, stillWanted: @escaping () -> Bool
  ) {
    guard let host else { return }
    let name = host.terminalPlace(targetID: targetID, tabID: tabID)
    var body = ProgramStatusPresentation.sentence(record.kind)
    // A report with no message (Codex sends none) takes the program's own notification text.
    if let message = ProgramStatusPresentation.oneLine(record.message)
      ?? detail.flatMap(ProgramStatusPresentation.oneLine)
    {
      body += ": \u{201C}\(message)\u{201D}"
    }
    let note = notifications.recordNeedsYou(
      targetID: targetID, tabID: tabID, source: host.placeSource(targetID: targetID),
      title: "\(name) needs you", body: body, episode: episode, origin: origin)
    surface(note, stillWanted: stillWanted)
  }

  /// Alert that the program in `tabID` finished its turn while nobody was looking: "Terminal 2 in
  /// fix-auth finished", then what it said. An ordinary notification, so focusing the terminal
  /// dismisses it, and the next finish there replaces it: a session running turns on its own
  /// (`/loop`) leaves one entry, not one per turn.
  func raiseFinished(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, record: ProgramStatusRecord,
    detail: String?
  ) {
    guard let host else { return }
    var body = ProgramStatusPresentation.turnFinished
    if let message = ProgramStatusPresentation.oneLine(record.message)
      ?? detail.flatMap(ProgramStatusPresentation.oneLine)
    {
      body += ": \u{201C}\(message)\u{201D}"
    }
    guard
      let note = notifications.record(
        targetID: targetID, tabID: tabID, source: host.placeSource(targetID: targetID),
        activity: .osc(
          title: "\(host.terminalPlace(targetID: targetID, tabID: tabID)) finished", body: body),
        focused: false, origin: origin)
    else { return }
    if let earlier = notifications.replaceFinish(of: tabID, with: note.id) {
      notifications.dismiss(notifID: earlier)
      toasts.removeAll { $0.id == earlier }
      // Its banner too: this finish may surface as a toast, which never replaces a banner.
      host.systemNotifier.withdraw(tabIDs: [tabID])
    }
    surface(note)
  }

  /// The program's own text for a request already raised (see `ProgramStatusAlerts.programNotified`).
  func mergeIntoNeedsYou(episode: String, body: String?) {
    notifications.merge(episode: episode, body: body)
  }

  /// The request was answered, or its program ended: its alert and banner go.
  func withdrawNeedsYou(episode: String) {
    toasts.removeAll { $0.episode == episode }
    notifications.dismiss(episode: episode)
    // Even with the entry already read: its banner may still be in Notification Center.
    host?.systemNotifier.withdraw(identifiers: [episode])
  }

  /// A notice about `id` that no terminal raised ("Check where this workroom starts").
  func raiseNotice(targetID id: TerminalTarget.ID, title: String, body: String) {
    guard let host else { return }
    surface(
      notifications.recordNotice(
        targetID: id, source: host.notificationSource(forTargetID: id), title: title, body: body,
        origin: origin))
  }

  // MARK: Surfacing

  /// Present a recorded notification: an in-app toast and the arrival sound while the app is
  /// frontmost, a native banner otherwise.
  private func surface(_ note: WorkroomNotification, stillWanted: @escaping () -> Bool = { true }) {
    if NotificationGate.shouldPresentInApp(recorded: true, appActive: isAppActive()) {
      // App is focused: request a chime (bursts share one), then pop a toast. Notifications live in
      // the always-visible left-sidebar strip + the title-bar bell badge (issue #118), so the
      // transient toast is the arrival signal regardless of what else is on screen. Previously this
      // flashed the notifications row when the *right* inspector was open/edge-revealed and only
      // toasted otherwise — that gating referenced a surface that no longer shows notifications, so
      // a focused arrival with the inspector open would have silently dropped.
      NotificationSound.play()
      if let forwardToast { forwardToast(note) } else { enqueueToast(note) }
    } else if NotificationGate.shouldPostBanner(recorded: true, appActive: isAppActive()),
      let systemNotifier = host?.systemNotifier
    {
      Task { @MainActor in
        if await systemNotifier.ensureAuthorized(), stillWanted(),
          notifications.items.contains(where: { $0.id == note.id })
        {
          systemNotifier.post(note)
        }
      }
    }
  }

  // MARK: Toasts

  /// Append a toast for a freshly-recorded notification, dropping the oldest once past the cap
  /// (issue #31). `internal` so the queue behaviour is unit-testable without `NSApp`.
  func enqueueToast(_ note: WorkroomNotification) {
    toasts.append(note)
    if toasts.count > Self.maxToasts {
      toasts.removeFirst(toasts.count - Self.maxToasts)
    }
  }

  /// Remove a toast by id — on tap (after `openTerminal`), on auto-dismiss, or when its underlying
  /// notification is dismissed elsewhere (`ToastStack` prunes those).
  func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }
}
