import DaemonConnection
import Foundation

/// A host whose terminals raise notifications: what `ProgramStatusAlerts` and `WindowRegistry` ask
/// of it, so a host need not be a whole window's `AppStore` (#358, #573). Each window's store is
/// one. A host whose own `PaneNotifier` raises them is a `PaneNotifierHost`, which forwards these
/// to it.
///
/// The host's own identity is the origin on every notification it raises, so dropping what a
/// closing host raised (`WindowRegistry.dropNotifications(raisedBy:)`) finds them by
/// `ObjectIdentifier(host)`.
@MainActor
protocol NotifyingHost: AnyObject {
  /// The host's panes, where `ProgramStatusAlerts` finds the panes attached to a session.
  var terminals: TerminalPanes { get }
  /// The program-status session of the terminal focused in this host, for ⇧⌘M.
  var focusedTerminalSession: UUID? { get }
  /// Where this host's banners post and are withdrawn.
  var systemNotifier: SystemNotifying { get }

  func raiseNeedsYou(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, episode: String,
    record: ProgramStatusRecord, detail: String?, stillWanted: @escaping () -> Bool)
  func raiseFinished(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, record: ProgramStatusRecord,
    detail: String?)
  func mergeIntoNeedsYou(episode: String, body: String?)
  func withdrawNeedsYou(episode: String)
  /// "Terminal 2 in fix-auth": how alerts and the menu bar's waiting list name a terminal.
  func terminalPlace(targetID: TerminalTarget.ID, tabID: TerminalTab.ID) -> String
  /// Show a toast here, whichever host raised it (`WindowRegistry.showToast`).
  func enqueueToast(_ note: WorkroomNotification)
}
