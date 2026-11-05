import Defaults
import SwiftUI

/// Always mounted below the window content, independent of selection and sidebar visibility.
struct WindowFooter: View {
  static let height: CGFloat = 26
  /// The gap below which the divider before the notifications button shows (#480).
  static let dividerGap: CGFloat = 24

  @Default(.usageInWindowFooter) private var showsUsage
  @State private var themeTick = 0
  /// The free space between the usage row and the notifications button.
  @State private var gap: CGFloat = .infinity
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 20) {
      // Every coding agent's usage, whatever is running (#480).
      if showsUsage { CodingAgentUsageRow() }
      Color.clear
        .frame(minWidth: 8, maxWidth: .infinity, maxHeight: 0)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { gap = $0 }
      // Always laid out, so showing it moves nothing; visible only once the usage row runs close.
      HStack(spacing: 10) {
        theme.tokens.border.frame(width: 1, height: 14)
          .opacity(showsUsage && gap <= Self.dividerGap ? 1 : 0)
          .accessibilityHidden(true)
        NotificationsBarButton()
      }
    }
    .padding(.leading, 10)
    .font(.subheadline)
    .foregroundStyle(theme.tokens.fgMuted)
    .lineLimit(1)
    .frame(height: Self.height)
    .padding(.bottom, 4)
    .background(theme.tokens.panel)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("window.footer")
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
  }
}
