import AppKit
import Combine
import Defaults
import SwiftUI

/// The system menu-bar item (issue #33), hand-managed with an `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra` so a click can branch on state: with pending notifications it opens the popover
/// list (the old behaviour); with none it simply brings the app forward — there's nothing to show,
/// so the empty "No notifications" popover was just a dead end. `MenuBarExtra` (`.window` style)
/// unconditionally toggles its window on click with no hook to intercept, which is why this owns the
/// status item and popover directly.
///
/// It's still a second *surface*, not a second source of truth: the glyph + count and the popover
/// body both read from `WindowRegistry.shared` (the count aggregated across every window, issue #70),
/// and the list is the same `MenuBarNotificationsView`/`NotificationsList` the in-app bell uses.
@MainActor
final class MenuBarController {
  private let registry: WindowRegistry
  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private var cancellables: Set<AnyCancellable> = []
  private var visibilityObserver: Task<Void, Never>?

  init(registry: WindowRegistry) {
    self.registry = registry
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusItem.button {
      let icon = NSImage(named: "MenuBarIcon")
      icon?.isTemplate = true  // follow the menu bar's appearance (and dim when inactive)
      button.image = icon
      button.imagePosition = .imageLeft  // count, when shown, sits to the icon's right
      button.target = self
      button.action = #selector(handleClick)
    }

    popover.behavior = .transient  // closes when the user clicks away
    // Matches MenuBarNotificationsView's own frame.
    popover.contentSize = NSSize(width: 320, height: 360)
    popover.contentViewController = NSHostingController(
      // `@Environment(\.dismiss)` is a no-op in a hand-hosted popover (there's no SwiftUI
      // presentation to dismiss), so the close is wired explicitly back to this popover.
      rootView: MenuBarNotificationsView(registry: registry) { [weak self] in
        self?.popover.performClose(nil)
      }
    )

    // Live count → button label. `aggregateUnread` is `@Published` on the main-actor registry.
    registry.$aggregateUnread
      .receive(on: RunLoop.main)
      .sink { [weak self] total in self?.applyCount(total) }
      .store(in: &cancellables)
    // A waiting request whose count is unchanged (one answered, another arrived, or its host went
    // stale) still changes what the label says (#358).
    ProgramStatusAlerts.shared.$waiting
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self.map { $0.applyCount($0.registry.aggregateUnread) } }
      .store(in: &cancellables)
    applyCount(registry.aggregateUnread)

    // Show/hide the item live with the `showMenuBarItem` setting (issue #33) — same key as the
    // Settings checkbox. Keep the item created either way; just toggle its visibility.
    statusItem.isVisible = Defaults[.showMenuBarItem]
    visibilityObserver = Task { [weak self] in
      for await visible in Defaults.updates(.showMenuBarItem, initial: false) {
        self?.statusItem.isVisible = visible
      }
    }
  }

  deinit { visibilityObserver?.cancel() }

  /// Mirror the aggregate unread count onto the button: the bare count beside the glyph when there's
  /// one (matching the in-app `UnreadCount.label` cap), nothing otherwise.
  private func applyCount(_ total: Int) {
    guard let button = statusItem.button else { return }
    let breakdown = Self.breakdown(
      waiting: ProgramStatusAlerts.shared.waiting,
      unread: registry.allStores.reduce(0) { $0 + $1.notifications.unreadExcludingRequests })
    button.title = total > 0 ? UnreadCount.label(total) : ""
    button.toolTip = breakdown
    button.setAccessibilityLabel(breakdown.map { "Workroom, \($0)" } ?? "Workroom notifications")
  }

  /// "2 requests waiting, 1 unread notification (1 may be out of date)", or nil with neither.
  static func breakdown(waiting: [WaitingRequest], unread: Int) -> String? {
    var parts: [String] = []
    if !waiting.isEmpty {
      parts.append(waiting.count == 1 ? "1 request waiting" : "\(waiting.count) requests waiting")
    }
    if unread > 0 {
      parts.append(unread == 1 ? "1 unread notification" : "\(unread) unread notifications")
    }
    guard !parts.isEmpty else { return nil }
    let stale = waiting.count { $0.stale }
    return parts.joined(separator: ", ") + (stale > 0 ? " (\(stale) may be out of date)" : "")
  }

  @objc private func handleClick() {
    if registry.aggregateUnread > 0 || !ProgramStatusAlerts.shared.waiting.isEmpty {
      togglePopover()
    } else {
      // No notifications → nothing to list; just bring the app forward.
      if popover.isShown { popover.performClose(nil) }
      activateApp()
    }
  }

  private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }

  /// Bring Workroom forward and focus a window — the key/last-active one if we have it, else any.
  /// Mirrors the global-hotkey show path (`unhide` + `activate`) so a hidden app comes back too.
  private func activateApp() {
    NSApp.unhide(nil)
    let window = registry.keyStore?.hostWindow ?? registry.allStores.compactMap(\.hostWindow).first
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
