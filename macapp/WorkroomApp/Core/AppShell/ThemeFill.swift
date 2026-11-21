import AppKit
import DesignSystem
import SwiftUI

/// The one path every solid theme fill in the main window goes through (#726): the window
/// background, the root and pane-card panel, the activity bar, the footer, pane title bars, the
/// sidebar card, the inspector split's headers and the creation pane. Glass (#725) changes how
/// these fills draw here, in one place, instead of at every surface.
///
/// A `ShapeStyle`, so it drops in wherever a token did — `.background(ThemeFill.panel)`,
/// `.background(ThemeFill.panel, ignoresSafeAreaEdges: [])`, `Rectangle().fill(ThemeFill.background)` —
/// with the same safe-area behaviour, and resolves against the theme in the view's environment
/// (`\.themeTokens`), so a theme switch re-injected at the root reaches it. AppKit drawing, which
/// has no environment, takes `nsColor()`, read from `ThemeService`.
///
/// Dialog overlays, sheets, onboarding and the Settings window stay opaque under Glass, so they
/// paint their tokens directly and never use this.
enum ThemeFill: ShapeStyle {
  /// The chrome panel around the terminals (`tokens.panel`).
  case panel
  /// The theme background, the terminals' own colour (`tokens.bg`).
  case background
  /// A raised wash over the panel, such as the inspector's section headers (`tokens.surface`).
  case raised

  /// The colour this fill draws under `tokens`.
  func color(in tokens: ThemeTokens) -> Color {
    switch self {
    case .panel: tokens.panel
    case .background: tokens.bg
    case .raised: tokens.surface
    }
  }

  /// The AppKit form, for drawing outside a SwiftUI body (the window background).
  @MainActor func nsColor(_ tokens: ThemeTokens = ThemeService.shared.tokens) -> NSColor {
    switch self {
    case .panel: tokens.nsPanel
    case .background: tokens.nsBg
    case .raised: NSColor(tokens.surface)
    }
  }

  func resolve(in environment: EnvironmentValues) -> Color {
    color(in: environment.themeTokens)
  }
}
