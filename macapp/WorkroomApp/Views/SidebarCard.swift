import SwiftUI

extension View {
  /// The floating-card chrome for the edge-reveal panels: a rounded `tokens.bg` card with a hairline
  /// border all the way around and a soft shadow, inset from its container by `margin`. macOS already
  /// renders the *docked* sidebar/inspector columns as inset cards, so this is applied only to the
  /// reveal overlays (which get no native card) to match that pinned look.
  // Radius + margins are tuned to match macOS's native docked sidebar card (the reveal is the only
  // caller; the docked columns use the system card). `topMargin` defaults to `margin` but can be
  // reduced so the reveal extends a little higher, to line up with the native card's top.
  func sidebarCard(cornerRadius: CGFloat = 10, margin: CGFloat = 8, topMargin: CGFloat? = nil)
    -> some View
  {
    let tokens = ThemeService.shared.tokens
    return
      self
      .background(tokens.bg)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(tokens.border, lineWidth: 1)
      )
      .compositingGroup()
      .shadow(color: .black.opacity(0.10), radius: 5, y: 1)
      .padding(.horizontal, margin)
      .padding(.bottom, margin)
      .padding(.top, topMargin ?? margin)
  }
}
