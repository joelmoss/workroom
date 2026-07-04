import AppKit
import Defaults
import SwiftUI

/// The trailing title-bar controls — the notifications bell (with unread badge) and the inspector
/// toggle — built as a plain SwiftUI `HStack` and hosted via `TitlebarAccessory`.
///
/// Why not `.toolbar`: in a `NavigationSplitView`, `.toolbar`'s `.primaryAction` is *column-scoped*
/// ("trailing edge of *this column*", which docks to the sidebar), and within a placement the only
/// ordering lever is declaration order. These two controls previously had to be split across two
/// separate toolbars to land near the right edge (see the history in `RootView`). Hosting them in a
/// title-bar accessory instead gives one `HStack` with exact spacing, a divider, and a fixed order,
/// pinned to the window's true trailing edge regardless of the split's columns.
///
/// The two controls do different things (issue #118): a plain click on the bell opens a popover
/// listing *all* notifications, newest→oldest, with a Clear action; ⌘-click walks the backlog by
/// opening the *oldest* pending notification's terminal (mirroring the ⇧⌘N "Next Notification"
/// command). The `sidebar.right` toggle shows/hides the Changes/Files/Pull Request inspector, filling
/// while open like the leading sidebar toggle. The bell is disabled when there are none.
///
/// The bell's popover is a hand-hosted `NSPopover` (via `BellPopoverController` + `BellPopoverAnchor`),
/// not a SwiftUI `.popover`: this view lives inside an `NSTitlebarAccessoryViewController`
/// (`TitlebarAccessoryHost`), where SwiftUI's `.popover` anchors unreliably. This mirrors the
/// menu-bar bell (`MenuBarController`), which hand-hosts an `NSPopover` for the same reason.
struct TitlebarControlsBar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Default(.showInspector) private var showInspector
  @State private var bellPopover = BellPopoverController()
  private let theme = ThemeService.shared

  /// The bell's accessibility label, factored out so the call site stays a single short line
  /// (a wrapped multi-line `.accessibilityLabel(…)` argument trips swift-format's line-break rule).
  private static func bellLabel(unread: Int) -> String {
    unread > 0 ? "Notifications, \(unread) unread" : "Notifications"
  }

  var body: some View {
    HStack(spacing: 10) {
      // Hairline divider separating the bell from the controls to its left (quick terminal / run /
      // open-in). Moved here from between the bell and the inspector toggle, which now read as one group.
      Rectangle()
        .fill(theme.tokens.border)
        .frame(width: 1, height: 14)

      // Notifications bell with live unread badge. Plain click opens the all-notifications popover;
      // ⌘-click walks the backlog (opens the oldest, dismissing it).
      Button {
        if NSEvent.modifierFlags.contains(.command) {
          store.openOldestNotification()
        } else {
          bellPopover.toggle(store: store, notifications: notifications)
        }
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "bell")
          UnreadBadge(count: notifications.total)
        }
      }
      // Anchors the hand-hosted NSPopover to the bell's frame (a transparent backing NSView).
      .background(BellPopoverAnchor(controller: bellPopover))
      .disabled(notifications.total == 0)
      .help(notifications.total > 0 ? "Show notifications (⌘-click for next)" : "No notifications")
      .accessibilityLabel(Self.bellLabel(unread: notifications.total))
      .accessibilityIdentifier("titlebar.notifications")

      // Inspector toggle — fills while the inspector is open so the on/off state reads at a glance,
      // mirroring the leading sidebar toggle.
      Button {
        showInspector.toggle()
      } label: {
        Image(systemName: "sidebar.right")
          .symbolVariant(showInspector ? .fill : .none)
      }
      .help(showInspector ? "Hide right sidebar" : "Show right sidebar")
      .accessibilityLabel("Right sidebar")
      .accessibilityValue(showInspector ? "shown" : "hidden")
      .accessibilityIdentifier("titlebar.toggleInspector")
      // Hovering this button (while the inspector is collapsed) peeks it via the edge-reveal overlay
      // (issue #74) — the trigger is the button alone, mirroring the leading sidebar toggle. Only
      // report while collapsed so a hover with the inspector open doesn't churn reveal state.
      .onHover { hovering in
        if !showInspector { store.hoveringRightToggle = hovering }
      }
    }
    .buttonStyle(ToolbarIconButtonStyle())
    // No leading padding: the leading divider above is the bar's first element, and the gap to its
    // left comes from TrailingTitlebarBar's 6pt HStack spacing. A leading 10 here would stack on top.
    // Trailing 10 keeps the inspector toggle off the window edge.
    .padding(.trailing, 10)
    // Fill the full-height (52pt) accessory host so the HStack centres its buttons — see LeadingTitlebarBar.
    .frame(maxHeight: .infinity)
  }
}

/// Owns the bell's transient `NSPopover` (issue #118). Hand-hosted because `TitlebarControlsBar`
/// lives in an `NSTitlebarAccessoryViewController`, where SwiftUI `.popover` anchors unreliably —
/// same rationale and shape as `MenuBarController`. Held on the view as `@State` so the one instance
/// survives re-renders; the popover content (`NotificationsPopover`) observes the store, so building
/// its hosting controller once is enough to keep it live.
@MainActor
final class BellPopoverController {
  private let popover = NSPopover()
  private var configured = false
  /// The transparent backing view the popover anchors to, supplied by `BellPopoverAnchor`.
  weak var anchor: NSView?

  func toggle(store: AppStore, notifications: NotificationCenterStore) {
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    guard let anchor else { return }
    if !configured {
      popover.behavior = .transient
      popover.contentSize = NSSize(width: 320, height: 360)
      popover.contentViewController = NSHostingController(
        rootView: NotificationsPopover(
          onActivate: { [weak self] in self?.popover.performClose(nil) }
        )
        .environmentObject(store)
        .environmentObject(notifications)
      )
      configured = true
    }
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
  }
}

/// A transparent backing `NSView` whose frame tracks the bell button, so `BellPopoverController` has a
/// concrete AppKit view to anchor its `NSPopover` to.
private struct BellPopoverAnchor: NSViewRepresentable {
  let controller: BellPopoverController

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    controller.anchor = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    controller.anchor = nsView
  }
}
