import Defaults
import SwiftUI

/// PROTOTYPE (issue: SwiftUI vs AppKit titlebar placement). A custom trailing title-bar bar built as
/// a plain SwiftUI `HStack` and hosted via `TitlebarAccessory`, to evaluate whether an
/// `NSTitlebarAccessoryViewController` gives the placement control `.toolbar` won't.
///
/// It deliberately replicates the two trailing controls that today live in two *different* toolbars
/// (the split-view-level notifications bell + the detail-level inspector toggle — see `RootView`,
/// where a comment notes they dock to different columns and only declaration order anchors them).
/// Here they sit in one `HStack` with explicit spacing, a hairline divider, and a fixed order — so
/// you control the layout directly instead of negotiating with semantic placements.
///
/// Run it side by side with the native toolbar (this coexists; it does not replace anything) and
/// resize the window or collapse the sidebar: the native bell hops between columns while this bar
/// stays put at the window's true trailing edge. That contrast is the whole point of the prototype.
/// Toggle it off with `Defaults[.titlebarAccessoryPrototype] = false`.
struct TitlebarPrototypeBar: View {
  @EnvironmentObject var notifications: NotificationCenterStore
  @Default(.showNotifications) private var showNotifications
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 10) {
      // Notifications bell with live badge — same action as the native bell, placed by us.
      Button {
        showNotifications.toggle()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "bell")
          UnreadBadge(count: notifications.total)
        }
      }
      .help("Notifications (prototype titlebar accessory)")
      .accessibilityLabel(
        notifications.total > 0
          ? "Notifications, \(notifications.total) unread" : "Notifications")
      .accessibilityIdentifier("titlebarPrototype.notifications")

      // A hairline divider — trivial here, awkward to express between two `.toolbar` items.
      Rectangle()
        .fill(theme.tokens.border)
        .frame(width: 1, height: 14)

      // Inspector toggle, immediately adjacent to the bell in a fixed order, regardless of which
      // split column either control would otherwise belong to.
      Button {
        showNotifications.toggle()
      } label: {
        Image(systemName: "sidebar.right")
          .symbolVariant(showNotifications ? .fill : .none)
      }
      .help(showNotifications ? "Hide right sidebar (prototype)" : "Show right sidebar (prototype)")
      .accessibilityLabel("Right sidebar")
      .accessibilityValue(showNotifications ? "shown" : "hidden")
      .accessibilityIdentifier("titlebarPrototype.toggleInspector")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .frame(height: 28)
  }
}
