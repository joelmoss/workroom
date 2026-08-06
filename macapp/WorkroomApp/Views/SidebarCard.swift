import SwiftUI

extension View {
  /// The floating-card chrome for the edge-reveal panels: a rounded `tokens.bg` card with a hairline
  /// border all the way around and a soft shadow, inset from its container by `margin`. macOS already
  /// renders the *docked* sidebar/inspector columns as inset cards, so this is applied only to the
  /// reveal overlays (which get no native card) to match that pinned look.
  // Radius + margins are tuned to match macOS's native docked sidebar card (the reveal is the only
  // caller; the docked columns use the system card). `topMargin` defaults to `margin` but can be
  // reduced so the reveal extends a little higher, to line up with the native card's top.
  // `vibrant` swaps the opaque `tokens.bg` fill for the system `.sidebar` vibrancy material (see
  // `VisualEffectView`) — the right inspector opts in so it reads as the same translucent surface
  // as the native left sidebar column. The left reveal stays opaque (it matches the native left
  // column, which is unchanged).
  // `elevated` deepens the shadow for the *unpinned* reveal panels so they read as floating above the
  // content (a popover-style drop shadow), vs the subtle inset shadow the docked card uses.
  func sidebarCard(
    cornerRadius: CGFloat = 10, margin: CGFloat = 8, topMargin: CGFloat? = nil,
    bottomMargin: CGFloat? = nil, leadingMargin: CGFloat? = nil, trailingMargin: CGFloat? = nil,
    vibrant: Bool = false, elevated: Bool = false
  )
    -> some View
  {
    let tokens = ThemeService.shared.tokens
    return
      self
      .background {
        if vibrant {
          // The `.behindWindow` material samples the desktop, not the ghostty theme — so on its own
          // it reads grey/washed and clashes with the themed chrome (worst on light themes). A wash
          // of the panel colour (the same surface as the title/tab bar) over it pulls it back onto
          // the theme palette while the material keeps the translucent frost. Opacity is the tuning
          // knob: higher = more themed / less glassy.
          VisualEffectView()
            .overlay(tokens.panel.opacity(0.7))
        } else {
          tokens.bg
        }
      }
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
