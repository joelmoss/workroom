import Foundation

@testable import Workroom

/// Posts nothing, and never gets permission to. Keeps the tab ids it is asked to withdraw banners
/// for, so a test can see a banner replaced.
final class SilentNotifier: SystemNotifying, @unchecked Sendable {
  private(set) var withdrawnTabs: [TerminalTab.ID] = []
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) { withdrawnTabs += tabIDs }
  func withdraw(identifiers: [String]) {}
}
