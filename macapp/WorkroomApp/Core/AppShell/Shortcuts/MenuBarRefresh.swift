import Observation

/// Counts menu openings, so the menu bar's `Commands` body re-evaluates as a menu opens and reads
/// what it shows without observing (Go ▸ Terminal Tab's titles, #148). `AppDelegate` bumps it on
/// `NSMenu.didBeginTrackingNotification`.
@MainActor
@Observable
final class MenuBarRefresh {
  static let shared = MenuBarRefresh()
  private(set) var opens = 0
  func menuOpened() { opens &+= 1 }
}
