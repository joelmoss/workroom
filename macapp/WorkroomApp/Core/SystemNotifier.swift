import Foundation
import UserNotifications

/// Bridges `WorkroomNotification`s to native macOS notifications. Behind a protocol so the
/// posting decision can be exercised with a spy in tests (mirrors `CommandRunning`).
///
/// One delivered notification per tab — the request identifier IS the tab id — so repeated
/// activity in the same terminal REPLACES the banner instead of stacking. `userInfo` carries the
/// ids a click needs to route back to the terminal (consumed in `AppDelegate`).
protocol SystemNotifying: Sendable {
  /// Request authorization lazily, the first time we'd actually post (a cold launch prompt
  /// hurts grant rate — issue #10 review, tension 3). Returns whether posting is permitted.
  func ensureAuthorized() async -> Bool
  func post(_ notification: WorkroomNotification)
  func withdraw(tabIDs: [TerminalTab.ID])
}

struct SystemNotifier: SystemNotifying {
  /// Pure mapping from a notification to its request fields, so identity + `userInfo` is
  /// testable without `UNUserNotificationCenter`.
  struct Payload: Equatable {
    let identifier: String
    let title: String
    let subtitle: String?
    let body: String?
    let userInfo: [String: String]
  }

  static func payload(for n: WorkroomNotification) -> Payload {
    let body: String?
    if n.count > 1 {
      body = [n.body, "(\(n.count))"].compactMap { $0 }.joined(separator: " ")
    } else {
      body = n.body
    }
    return Payload(
      identifier: n.tabID.uuidString,
      title: n.title,
      subtitle: n.source.isEmpty ? nil : n.source,
      body: body,
      userInfo: ["targetID": n.targetID, "tabID": n.tabID.uuidString, "notifID": n.id.uuidString])
  }

  func ensureAuthorized() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional:
      return true
    case .notDetermined:
      return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    default:
      return false
    }
  }

  func post(_ notification: WorkroomNotification) {
    let p = Self.payload(for: notification)
    let content = UNMutableNotificationContent()
    content.title = p.title
    if let subtitle = p.subtitle { content.subtitle = subtitle }
    if let body = p.body { content.body = body }
    content.userInfo = p.userInfo
    content.sound = .default
    let request = UNNotificationRequest(identifier: p.identifier, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  func withdraw(tabIDs: [TerminalTab.ID]) {
    let ids = tabIDs.map(\.uuidString)
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: ids)
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }
}
