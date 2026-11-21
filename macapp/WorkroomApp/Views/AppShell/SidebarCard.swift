import SwiftUI

extension View {
  /// The floating-card chrome for the edge-reveal panels: a rounded card on `ChromeBackground` with a hairline
  /// border all the way around and a soft shadow, inset from its container by `margin`. macOS already
  /// renders the *docked* sidebar/inspector columns as inset cards, so this is applied only to the
  /// reveal overlays (which get no native card) to match that pinned look.
  // Radius + margins are tuned to match macOS's native docked sidebar card (the reveal is the only
  // caller; the docked columns use the system card). `topMargin` defaults to `margin` but can be
  // reduced so the reveal extends a little higher, to line up with the native card's top.
  // The fill is `ChromeBackground`: the card vibrancy, or Glass's chrome backing under glass (#730).
  // `elevated` deepens the shadow for the *unpinned* reveal panels so they read as floating above the
  // content (a popover-style drop shadow), vs the subtle inset shadow the docked card uses.
  // Under Glass an elevated card also lays the window base under itself (`ChromeRole.floatingCard`),
  // so the terminals it floats over do not show through its wash.
  func sidebarCard(
    cornerRadius: CGFloat = 10, margin: CGFloat = 8, topMargin: CGFloat? = nil,
    bottomMargin: CGFloat? = nil, leadingMargin: CGFloat? = nil, trailingMargin: CGFloat? = nil,
    elevated: Bool = false
  )
    -> some View
  {
    modifier(
      SidebarCard(
        cornerRadius: cornerRadius, margin: margin, topMargin: topMargin,
        bottomMargin: bottomMargin, leadingMargin: leadingMargin, trailingMargin: trailingMargin,
        elevated: elevated))
  }
}

private struct SidebarCard: ViewModifier {
  let cornerRadius: CGFloat
  let margin: CGFloat
  let topMargin: CGFloat?
  let bottomMargin: CGFloat?
  let leadingMargin: CGFloat?
  let trailingMargin: CGFloat?
  let elevated: Bool
  @Environment(\.themeTokens) private var tokens

  func body(content: Content) -> some View {
    content
      .background(ChromeBackground(role: elevated ? .floatingCard : .card))
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(tokens.border, lineWidth: 1)
      )
      .compositingGroup()
      .shadow(
        color: .black.opacity(elevated ? 0.28 : 0.10), radius: elevated ? 10 : 5,
        y: elevated ? 5 : 1
      )
      // `leadingMargin` overrides only the leading inset (defaults to `margin`) — the docked inspector
      // tightens the gap to the detail panel without pulling its outer (trailing) edge off the window.
      .padding(.leading, leadingMargin ?? margin)
      .padding(.trailing, trailingMargin ?? margin)
      // `bottomMargin`, like `topMargin`, overrides one edge only: the docked columns match the
      // workroom pane card's gutter top AND bottom so the three columns' cards share both lines,
      // while their outer (window-facing) edges keep the wider `margin`.
      .padding(.bottom, bottomMargin ?? margin)
      .padding(.top, topMargin ?? margin)
  }
}
