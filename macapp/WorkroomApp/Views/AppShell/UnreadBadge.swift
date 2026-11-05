import SwiftUI

/// The displayed form of an unread count, capped at `99+`. Pure so the badge and the menu bar item
/// share one cap and can't drift (mirrors `NotificationGate`'s extract-and-test seam).
enum UnreadCount {
  static func label(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}

/// A small unread-count pill. Used by the toolbar button (a single aggregate total reads well as
/// a number). Renders nothing when `count` is 0.
struct UnreadBadge: View {
  let count: Int
  /// Contrast-corrected colours, for a host that has measured its own surface. Defaults to the raw accent
  /// pair — the switcher rail passes `SwitcherRailLayout.Palette`'s, whose ink is chosen by measurement
  /// rather than by `contrastingForeground`'s luminance-0.6 switch, and whose fill matches the rail's
  /// cursor ring so one card can't show two different "accents" (D14).
  var fill: Color?
  var ink: Color?
  private let theme = ThemeService.shared

  var body: some View {
    if count > 0 {
      Text(UnreadCount.label(count))
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(ink ?? theme.tokens.accentForeground)
        .monospacedDigit()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(fill ?? theme.tokens.accent))
        .accessibilityLabel("\(count) unread")
    }
  }
}

/// A small accent dot marking unread activity, used on sidebar rows (project / root / workroom)
/// where a count is too noisy — presence is what matters. Renders nothing when `count` is 0.
struct UnreadDot: View {
  let count: Int
  private let theme = ThemeService.shared

  var body: some View {
    if count > 0 {
      Circle()
        .fill(theme.tokens.accent)
        .frame(width: 7, height: 7)
        .accessibilityLabel("Unread notifications")
    }
  }
}
