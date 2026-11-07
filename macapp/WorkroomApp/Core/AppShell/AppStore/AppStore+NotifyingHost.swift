import Foundation

/// A window's store raises its terminals' notifications through its `paneNotifier`, which asks the
/// store where the user is looking and how it names its terminals.
extension AppStore: NotifyingHost, PaneNotifierHost {
  var systemNotifier: SystemNotifying { services.notifier }

  var isHostWindowKey: Bool { hostWindow?.isKeyWindow == true }

  var primaryTargetID: TerminalTarget.ID? { primaryTarget?.id }

  func detachedWindowIsKey(forTab tabID: TerminalTab.ID) -> Bool? {
    detachedPanes.window(for: tabID)?.isKeyWindow
  }
}
