import AppKit
import Defaults
import SwiftUI

/// The right **activity bar** (issue: activity bar) — a thin vertical icon rail pinned to the
/// window's trailing edge, VSCode-style. One large icon per `ActivitySection`; clicking one shows
/// that section's pane in the inspector, clicking the active one collapses the pane (the bar stays).
///
/// Always visible (unlike the inspector content pane it drives). Flat `panel` chrome so it reads as
/// the same surface as the title bar and sidebars. Lives inside `RootView`'s
/// detail `HStack` — inside the detail-only `NavigationSplitView` — so its buttons get working
/// `.onHover` tracking (a raw content view near the title bar loses it, issue #114).
struct ActivityBar: View {
  @EnvironmentObject var store: AppStore
  @Default(.showInspector) private var showInspector
  // Bumped on `.themeDidChange` so the flat panel fill repaints live on a theme switch (tokens are
  // read from the `ThemeService` singleton, which SwiftUI doesn't observe on its own).
  @State private var themeTick = 0
  private let theme = ThemeService.shared
  private let width: CGFloat = 44

  var body: some View {
    VStack(spacing: 2) {
      ForEach(ActivitySection.allCases) { section in
        ActivityBarButton(
          section: section,
          // Active only while the pane is actually shown — a closed inspector highlights nothing
          // (VSCode behaviour), so the bar never implies content is visible when it isn't.
          active: showInspector && store.activeInspectorSection == section,
          // A dirty dot on the Changes icon so uncommitted changes are visible without opening (or
          // even leaving) the pane — same orange `warning` tint the sidebar/tab dirty dot uses.
          badged: section == .changes && changesDirty
        ) {
          store.apply(.iconClick(section))
        }
      }
      Spacer(minLength: 0)
      // The notifications bell sits at the bottom of the rail (VSCode-style, where the account/gear
      // icons live), separate from the section icons above — it opens a popover, it doesn't drive a
      // pane. Always present, like the bar itself.
      NotificationsBarButton()
    }
    .padding(.vertical, 6)
    .frame(width: width)
    .frame(maxHeight: .infinity)
    .background(theme.tokens.panel)
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
  }

  /// Whether the inspector's current target has an uncommitted working tree — drives the Changes
  /// icon's dirty dot. Keyed off `inspectorTargetID` (nil when the selection has no open tabs, so the
  /// Changes pane is empty and the dot stays hidden), matching what the pane actually shows.
  private var changesDirty: Bool {
    guard let id = store.inspectorTargetID else { return false }
    return store.workroomStatuses[id]?.dirty == true
  }
}

/// One activity-bar icon. Active state is signalled by **position** (a 2pt accent strip on the inner
/// edge) and **brightness** (`fg` vs `fgMuted` glyph), not hue alone, so it reads for red/green
/// colour-blind users too (see the `run-status-glyph-colorblind` learning). Hover gets the standard
/// `hover` wash. Every control carries a tooltip, an accessibility label, and a stable identifier.
private struct ActivityBarButton: View {
  let section: ActivitySection
  let active: Bool
  /// Draws a `warning` dirty dot at the icon's bottom-left (currently the Changes icon when the
  /// working tree has uncommitted changes) — the low corner keeps it clear of the glyph.
  var badged: Bool = false
  let action: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: section.systemImage)
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(active ? theme.tokens.fg : theme.tokens.fgMuted)
        .frame(width: 44, height: 40)
        .overlay(alignment: .bottomLeading) {
          if badged {
            // A11y-hidden — the state is announced once on the button's accessibility value ("has
            // changes"), which the UITest reads. Low corner so it never crowds the glyph.
            Circle()
              .fill(theme.tokens.warning)
              .frame(width: 7, height: 7)
              .padding(.bottom, 8)
              .padding(.leading, 9)
              .accessibilityHidden(true)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 6)
          .fill(active ? theme.tokens.accentSoft : (hovering ? theme.tokens.hover : Color.clear))
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
        if active {
          theme.tokens.accent
            .frame(width: 2)
            .clipShape(Capsule())
            .padding(.vertical, 8)
        }
      }
    }
    .onHover { hovering = $0 }
    .help(helpText)
    .accessibilityLabel(section.label)
    .accessibilityValue(badged ? "has changes" : "")
    .accessibilityIdentifier("activitySection.\(section.rawValue)")
    .accessibilityAddTraits(active ? [.isSelected] : [])
  }

  /// Tooltip: what the click does plus the View-menu shortcut that does the same thing. Names the
  /// *action*, not the state — while the pane is showing, a click collapses it, so the tooltip says
  /// "Hide" (matching the title bar's sidebar button). The Changes icon appends the dirty-tree state
  /// so the dot has words.
  private var helpText: String {
    let action = active ? "Hide \(section.label)" : "Show \(section.label)"
    let base = "\(action) (\(section.shortcutHint))"
    return badged ? "\(base) — working tree has changes" : base
  }
}

/// The notifications bell pinned to the bottom of the activity bar (moved here from the title bar).
/// Not an `ActivitySection` — it opens a popover listing all notifications rather than driving a
/// pane, so it draws no active strip. A plain click toggles the popover; ⌘-click walks the backlog
/// (opens the oldest pending notification's terminal, mirroring ⇧⌘N). Disabled with no unread; an
/// unread-count badge sits at the glyph's top-trailing corner. Because the bar lives in a normal
/// SwiftUI view (unlike the title-bar accessory), a plain `.popover` anchors reliably — no
/// hand-hosted `NSPopover` needed (contrast the old title-bar bell, which had to hand-host one).
private struct NotificationsBarButton: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @State private var hovering = false
  @State private var showPopover = false
  private let theme = ThemeService.shared

  var body: some View {
    Button {
      if NSEvent.modifierFlags.contains(.command) {
        store.openOldestNotification()
      } else {
        showPopover.toggle()
      }
    } label: {
      Image(systemName: "bell")
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(theme.tokens.fgMuted)
        .frame(width: 44, height: 40)
        .overlay(alignment: .topTrailing) {
          UnreadBadge(count: notifications.total)
            .padding(.top, 3)
            .padding(.trailing, 5)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(hovering ? theme.tokens.hover : Color.clear)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
    .onHover { hovering = $0 }
    .disabled(notifications.total == 0)
    // The popover itself has no key equivalent (⌥⌘N was retired with issue #118), so the tooltip
    // advertises ⇧⌘N — the View-menu "Next Notification" the ⌘-click mirrors.
    .help(
      notifications.total > 0
        ? "Show notifications (⌘-click or ⇧⌘N for next)"
        : "No notifications"
    )
    .accessibilityLabel(
      notifications.total > 0 ? "Notifications, \(notifications.total) unread" : "Notifications"
    )
    .accessibilityIdentifier("activityBar.notifications")
    .popover(isPresented: $showPopover, arrowEdge: .leading) {
      NotificationsPopover(onActivate: { showPopover = false })
        .environmentObject(store)
        .environmentObject(notifications)
        .frame(width: 320, height: 360)
    }
  }
}
