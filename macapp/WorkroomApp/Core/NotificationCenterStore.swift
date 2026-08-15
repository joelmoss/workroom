import Foundation

/// A notification-worthy signal a terminal emitted. Detection is explicit-only: the program (or
/// shell) asks for attention via an OSC notification escape sequence, which libghostty parses and
/// surfaces as a desktop-notification action. Plain output — and the bare bell — are deliberately
/// NOT recorded here: the bell rings the system beep via GhosttyRuntimeAdapter's RING_BELL handler
/// but is intentionally not logged as a notification (plan C1 — it's a content-free signal).
enum TerminalActivity: Equatable {
  case osc(title: String, body: String?)
}

/// One entry in the in-memory notification history. Named `WorkroomNotification` (not
/// `Notification`) to avoid clashing with `Foundation.Notification`. Identity for routing a
/// click back to a live terminal is `(targetID, tabID)`; both are session-scoped (tab ids are
/// per-launch UUIDs), so history is intentionally session-only — see `NotificationCenterStore`.
struct WorkroomNotification: Identifiable, Equatable {
  let id: UUID
  let targetID: TerminalTarget.ID
  let tabID: TerminalTab.ID
  /// Human-readable origin captured at record time — the project name (and workroom, for a
  /// workroom terminal), e.g. "platform" or "platform / fix-auth". Shown in the panel + banner.
  let source: String
  var title: String
  var body: String?
  var date: Date
  /// Number of coalesced events this entry represents (OSC entries stay distinct, so it's always
  /// 1 today; retained for the panel's ×N display).
  var count: Int
}

/// The notification spine: an in-memory, session-only history that drives every surface
/// (system banner, sidebar/tab/toolbar badges, the inspector panel). Owned by `AppStore`
/// (`let notifications = NotificationCenterStore()`), mirroring `let terminals = TerminalSessions()`.
///
/// There is no read state: a notification lives until it's dismissed — the user focuses or opens
/// its terminal, clicks it in the panel, or clears the panel — or until it's evicted at the cap.
/// Nothing lingers once seen. Counts are COMPUTED by scanning `items` (capped at 500) rather than
/// maintained as incremental tallies, so a badge can't drift (issue #10 review, tension 1).
///
/// ```
///   record(target,tab,activity, focused) ─▶ focused? drop
///                                          ─▶ osc:  append a distinct item
///                                          ─▶ trim to 500 (drop oldest)
///   count(tab|target) / total          = scan items, sum .count
///   dismiss(...) / removeForTarget     = filter the matching items out
/// ```
@MainActor
final class NotificationCenterStore: ObservableObject {
  @Published private(set) var items: [WorkroomNotification] = [] {
    didSet { onTotalChange?(total) }
  }

  /// Fired with the new aggregate `total` whenever the history changes, so a coordinator can mirror
  /// the count onto an AppKit surface (the Dock icon badge) WITHOUT coupling this store to AppKit —
  /// the same seam as `TerminalSessions.activityHandler`. Driving the Dock badge from here (the
  /// model), not a SwiftUI view, is deliberate: SwiftUI suspends a hidden/occluded window's body
  /// updates — exactly when a backgrounded terminal posts a notification and the badge must change —
  /// so a view-driven `.onChange` misses it until the app is next foregrounded (issue #32).
  var onTotalChange: ((Int) -> Void)?

  /// Bounds memory and keeps the panel list snappy under a chatty emitter (decision 4.1).
  private let cap: Int
  /// Injectable clock so coalescing/ordering is unit-testable (mirrors `BranchResolver`'s runner).
  private let now: () -> Date

  init(cap: Int = 500, now: @escaping () -> Date = Date.init) {
    self.cap = cap
    self.now = now
  }

  // MARK: Recording

  /// Record an activity event. Returns the resulting entry when something was recorded (so the
  /// caller can decide whether to also post a system banner), or `nil` when the event was
  /// dropped because the user is already looking at that terminal.
  @discardableResult
  func record(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, source: String = "",
    activity: TerminalActivity, focused: Bool
  ) -> WorkroomNotification? {
    guard !focused else { return nil }
    guard case .osc(let title, let body) = activity else { return nil }
    // OSC notifications carry a real message — keep each one distinct in the history. The title is
    // stored verbatim (empty allowed); the panel leads with the body when there's no title rather
    // than showing a placeholder.
    return append(
      WorkroomNotification(
        id: UUID(), targetID: targetID, tabID: tabID, source: source,
        title: title, body: body, date: now(), count: 1))
  }

  @discardableResult
  private func append(_ n: WorkroomNotification) -> WorkroomNotification {
    items.append(n)
    if items.count > cap {
      items.removeFirst(items.count - cap)
    }
    return n
  }

  // MARK: Derived counts (computed scans — no incremental state to drift)

  func count(tab: TerminalTab.ID) -> Int {
    items.lazy.filter { $0.tabID == tab }.reduce(0) { $0 + $1.count }
  }

  func count(target: TerminalTarget.ID) -> Int {
    items.lazy.filter { $0.targetID == target }.reduce(0) { $0 + $1.count }
  }

  var total: Int {
    items.reduce(0) { $0 + $1.count }
  }

  // MARK: Mutations

  /// Dismiss (delete) a notification once it's been seen — there is no read state to leave behind,
  /// so reading is removal. Dismissing by tab clears everything that terminal accrued.
  func dismiss(notifID: UUID) { items.removeAll { $0.id == notifID } }
  func dismiss(tab: TerminalTab.ID) { items.removeAll { $0.tabID == tab } }

  /// Drop a deleted target's items (so a removed workroom's badges/history disappear). Returns
  /// the affected tab ids so the caller can also withdraw any delivered system banners.
  @discardableResult
  func removeForTarget(_ target: TerminalTarget.ID) -> [TerminalTab.ID] {
    let dropped = Set(items.filter { $0.targetID == target }.map(\.tabID))
    items.removeAll { $0.targetID == target }
    return Array(dropped)
  }

  func clear() { items.removeAll() }

  // MARK: Test seam

  /// Replace the history wholesale with a fixed set — the UI-test fixture (`UITestFixture`) and unit
  /// tests only. The production path is `record`, which stamps `now()` and drops focused events; this
  /// exists so a test can populate the panel with the back-dated, multi-line, and coalesced (×N)
  /// entries that `record` can't synthesise. Inert unless called (only fixture mode / tests do).
  func seedForTesting(_ seed: [WorkroomNotification]) { items = seed }
}

/// Pure gates for how a recorded event should surface, split by app activation so the rules are
/// unit-testable without `NSApp` (decision 1.2). The two are mutually exclusive for a recorded
/// event: backgrounded ⇒ native banner; foregrounded ⇒ in-app (toast or sidebar flash) + sound.
enum NotificationGate {
  /// Raise a native banner only when the app is NOT frontmost (in-app surfaces carry the
  /// foreground case).
  static func shouldPostBanner(recorded: Bool, appActive: Bool) -> Bool {
    recorded && !appActive
  }

  /// Present the event in-app (toast/flash + sound) only while the app IS frontmost — the
  /// foreground counterpart of `shouldPostBanner` (issue #31).
  static func shouldPresentInApp(recorded: Bool, appActive: Bool) -> Bool {
    recorded && appActive
  }
}
