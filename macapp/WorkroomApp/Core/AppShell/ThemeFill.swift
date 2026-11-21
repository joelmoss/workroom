import AppKit
import DesignSystem
import SwiftUI

/// The one path every solid theme fill in the main window goes through (#726): the window
/// background, the root and pane-card panel, the activity bar, the footer, pane title bars, the
/// sidebar card, the inspector split's headers, the creation pane, the tabs and the text views.
/// Glass (#725) changes how these fills draw here, in one place, instead of at every surface.
///
/// A `ShapeStyle`, so it drops in wherever a token did — `.background(ThemeFill.panel)`,
/// `.background(ThemeFill.panel, ignoresSafeAreaEdges: [])`, `Rectangle().fill(ThemeFill.background)` —
/// with the same safe-area behaviour, and resolves against the theme and the Glass appearance in the
/// view's environment (`\.themeTokens`, `\.glassAppearance`), so a theme switch or a Glass change
/// re-injected at the root reaches it. AppKit drawing, which has no environment, takes `nsColor()`
/// or `nsFill()`, given the theme and the window's appearance.
///
/// Under glass every pixel carries one tint (#725): the window's own background is the theme `bg`
/// at the Glass opacity (`WindowBackgroundThemer`), so a fill here never tints at the opacity
/// again. `background` and `ground` draw nothing over that base, `panel` is the wash that turns the
/// base into the panel colour, and `raised` keeps its light wash. Opaque, every case draws exactly
/// the colour it always did.
///
/// Dialog overlays, sheets, onboarding and the Settings window stay opaque under Glass, so they
/// paint their tokens directly and never use this.
enum ThemeFill: ShapeStyle {
  /// The chrome panel around the terminals (`tokens.panel`). Under glass, the panel wash
  /// (`tokens.panelWash`), which over the window's `bg` base is the panel colour.
  case panel
  /// The panel colour under the panes: the detail column and each pane card's base, and a band
  /// inside a panel that already carries the wash. Opaque, it is `panel`. Under glass it draws
  /// nothing, so what sits on it shows the window base.
  case ground
  /// The theme background, the terminals' own colour (`tokens.bg`). Under glass it draws nothing:
  /// the window base already is `bg`.
  case background
  /// A raised wash over the panel, such as the inspector's section headers (`tokens.surface`). It is
  /// already a light translucent wash, so Glass leaves it as it is.
  case raised
  /// The `raised` wash again, inside a host that already lays `raised` (the creation log's AppKit
  /// views). Opaque, `tokens.surface`, stacked as it always was; under glass nothing, so the host's
  /// is the one wash.
  case nestedRaised
  /// The system text background (`NSColor.textBackgroundColor`), the setup log's. Under glass
  /// nothing, as `background`.
  case textBackground
  /// A selected tab in a strip: opaque, the theme background, which stands out from the panel strip
  /// around it. Under glass the base already is `bg`, so it is the selected-tab wash
  /// (`tokens.tabActive`), which reads as selected over the strip.
  case selectedTab
  /// A hovered idle tab: the faint hover wash (`tokens.hover`), Glass on or off.
  case hoveredTab
  /// An idle tab: nothing, so the strip shows through.
  case idleTab

  /// A tab's fill, for the workroom tab bar and the terminal tab strip alike.
  static func tab(active: Bool, hovered: Bool) -> ThemeFill {
    active ? .selectedTab : hovered ? .hoveredTab : .idleTab
  }

  /// The colour this fill draws under `tokens` and `glass`.
  func color(in tokens: ThemeTokens, glass: GlassAppearance = .opaque) -> Color {
    nsFill(tokens, glass: glass).map(Color.init(nsColor:)) ?? .clear
  }

  /// The AppKit form, for drawing outside a SwiftUI body: `.clear` where it draws nothing.
  @MainActor func nsColor(
    _ tokens: ThemeTokens = ThemeService.shared.tokens, glass: GlassAppearance = .opaque
  ) -> NSColor {
    nsFill(tokens, glass: glass) ?? .clear
  }

  /// What this fill paints under `tokens` and `glass`, or nil where it draws nothing, so an AppKit
  /// view can turn its own `drawsBackground` off. The one per-case mapping, opaque and under glass,
  /// for the SwiftUI and the AppKit form both.
  func nsFill(_ tokens: ThemeTokens, glass: GlassAppearance) -> NSColor? {
    switch (self, glass.isGlass) {
    case (.panel, false), (.ground, false): tokens.nsPanel
    case (.panel, true): tokens.nsPanelWash
    case (.background, false), (.selectedTab, false): tokens.nsBg
    case (.raised, _), (.nestedRaised, false): NSColor(tokens.surface)
    case (.textBackground, false): .textBackgroundColor
    case (.selectedTab, true): NSColor(tokens.tabActive)
    case (.hoveredTab, _): NSColor(tokens.hover)
    case (.ground, true), (.background, true), (.nestedRaised, true), (.textBackground, true),
      (.idleTab, _):
      nil
    }
  }

  func resolve(in environment: EnvironmentValues) -> Color {
    color(in: environment.themeTokens, glass: environment.glassAppearance)
  }
}

/// An AppKit view that paints its own background: a text view or a scroll view.
@MainActor protocol DrawsOwnBackground: AnyObject {
  var drawsBackground: Bool { get set }
  var backgroundColor: NSColor { get set }
}

extension DrawsOwnBackground {
  /// Paint `fill` (`ThemeFill.nsFill`) as this view's background, or none where it is nil.
  func paintBackground(_ fill: NSColor?) {
    drawsBackground = fill != nil
    if let fill { backgroundColor = fill }
  }
}

extension NSTextView: DrawsOwnBackground {}
extension NSScrollView: DrawsOwnBackground {}
