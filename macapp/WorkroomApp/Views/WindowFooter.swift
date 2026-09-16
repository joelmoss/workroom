import SwiftUI

/// Always mounted below the window content, independent of selection and sidebar visibility.
struct WindowFooter: View {
  static let height: CGFloat = 26

  @ObservedObject private var registry = WindowRegistry.shared
  @State private var themeTick = 0
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 20) {
      ForEach(
        AgentBackend.allCases.filter { registry.activeAgentBackends.contains($0) }, id: \.self
      ) {
        AgentUsageSegment(backend: $0)
      }
      Spacer(minLength: 8)
      NotificationsBarButton()
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
