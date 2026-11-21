import AppKit
import DesignSystem
import SwiftUI

/// A piece of the main window's chrome, by what it draws on with Glass off.
enum ChromeRole: Equatable, Sendable {
  /// The sidebar and inspector cards, docked and edge-revealed, and a pane's status bar: the
  /// `.sidebar` vibrancy under a panel wash.
  case card
  /// A card that floats over the window's content (the edge-reveal sidebar over the terminals):
  /// `card`, laid on the window base again under glass so what it covers does not show through.
  case floatingCard
  /// A band inside a card that covers what scrolls under it, such as the sidebar's footer: the
  /// card's own backing with Glass off; nothing under glass, where the card's tint shows through.
  case cardBand
  /// The activity bar and the window footer: the flat theme panel with Glass off; nothing under
  /// glass, so they are the bare window base like the title bar and gutters, one frame colour.
  case bar
}

/// What a piece of chrome draws on (#730), and the one place the chrome's Glass rules live: every
/// chrome site draws through this, and none re-derives them. Read from the window's
/// `\.glassAppearance` and theme, so a Glass, Reduce transparency, full-screen or theme change swaps
/// it live. Used as a background, so the chrome's own safe-area behaviour is the caller's
/// (`ignoresSafeAreaEdges`).
///
/// Under glass the window's own background is the one tint, the theme `bg` at the Glass opacity
/// (`WindowBackgroundThemer`): the frame (title bar, gutters, the activity bar and footer) is that
/// base bare, and the cards add only the panel wash on it (`ThemeFill.panel`, #725). The window's
/// blur (`WindowBlur`) is the only frosting, so no chrome adds a material, which would stack into
/// near-opacity over it, or Liquid Glass, whose own pale frost read as grey patches in dark mode.
struct ChromeBackground: View {
  let role: ChromeRole
  @Environment(\.glassAppearance) private var glass
  @Environment(\.themeTokens) private var tokens

  /// The panel wash over the opaque card's vibrancy: light enough that the material reads through.
  static let cardWash = 0.7

  var body: some View {
    switch (role, glass.isGlass) {
    case (.bar, false):
      panel
    case (.card, false), (.floatingCard, false), (.cardBand, false):
      VisualEffectView().overlay(ThemeFill.panel.opacity(Self.cardWash))
    case (.card, true):
      panel
    case (.floatingCard, true):
      // The window base again under the wash, so the terminals it floats over do not show through.
      Rectangle().fill(Color(nsColor: WindowBackgroundThemer.baseColor(glass, tokens: tokens)))
        .overlay { panel }
    case (.cardBand, true), (.bar, true):
      Color.clear
    }
  }

  private var panel: some View { Rectangle().fill(ThemeFill.panel) }
}
