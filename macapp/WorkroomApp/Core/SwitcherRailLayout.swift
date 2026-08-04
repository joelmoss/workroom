import AppKit
import SwiftUI

/// The rail's geometry and colour decisions, kept pure so the parts that are easy to get *silently*
/// wrong are unit-testable without a panel on screen (issue #132, T11 / design decisions D9, D14, D15).
///
/// Nothing here draws. `SwitcherRailView` reads these; `SwitcherPanel` reads `viewportWidth`.
enum SwitcherRailLayout {

  // MARK: Card geometry (D9)

  /// The comfortable card width, used while the whole rail fits.
  ///
  /// Cards are **stacked** — well above label, the way ⌘Tab and the Dock put an icon above its name —
  /// rather than well-beside-label. That change alone nearly halved the card: a side-by-side card has to
  /// pay for the well's width *and* a label column beside it, while a stacked one gives the full card
  /// width to the label. Roughly twice as many workrooms now fit before the row has to scroll.
  static let maxCardWidth: CGFloat = 120
  /// The floor. The label spans the whole card here, so ~96pt of 12pt text survives — comfortably more
  /// than the side-by-side layout had at 180pt, where a 52pt well and its gap came off the top first.
  static let minCardWidth: CGFloat = 104
  static let cardHeight: CGFloat = 104
  static let cardSpacing: CGFloat = 8
  /// Inset from the rail's own edge to the first card.
  static let railPadding: CGFloat = 12
  /// The well. Small on purpose: at 52pt it dominated a card whose *label* is the thing you read, and a
  /// mark only has to be recognisable, not large. This is close to a Dock icon's proportion of its label.
  static let wellSize = CGSize(width: 38, height: 38)

  /// Card width for `count` items in `available` points: the comfortable width while everything fits,
  /// shrinking no further than the floor. Past the floor the row scrolls instead (never a second row).
  static func cardWidth(count: Int, available: CGFloat) -> CGFloat {
    guard count > 0 else { return maxCardWidth }
    let gaps = CGFloat(max(0, count - 1)) * cardSpacing
    let perCard = (available - gaps - railPadding * 2) / CGFloat(count)
    return min(maxCardWidth, max(minCardWidth, perCard))
  }

  /// Does `count` cards at `available` width overflow the single row? When true the rail scrolls and
  /// draws its edge fades.
  static func scrolls(count: Int, available: CGFloat) -> Bool {
    contentWidth(count: count, cardWidth: cardWidth(count: count, available: available)) > available
  }

  static func contentWidth(count: Int, cardWidth: CGFloat) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(count) * cardWidth + CGFloat(count - 1) * cardSpacing + railPadding * 2
  }

  // MARK: Viewport (D15)

  /// Hard cap on the rail's own width, so a very wide display doesn't stretch it edge to edge.
  static let maxViewportWidth: CGFloat = 1100
  /// Clearance kept between the rail and the screen edge.
  static let screenMargin: CGFloat = 24

  /// The widest the rail may be on a given screen: capped, and never wider than the usable frame. This
  /// is the space available for cards, NOT the panel's width — see `panelWidth`.
  static func viewportWidth(visibleFrame: CGRect) -> CGFloat {
    min(maxViewportWidth, max(minCardWidth, visibleFrame.width - screenMargin * 2))
  }

  /// The panel's actual width: **snug around its cards**, not the full viewport.
  ///
  /// Sizing the panel to the viewport left the glass extending far past the last card, so a rail of four
  /// looked left-aligned inside a wide slab even though the slab itself was centred. Fitting the panel to
  /// its content is what makes the *cards* look centred, which is the thing anyone actually perceives.
  /// Once the cards overflow, the panel takes the whole viewport and the row scrolls inside it.
  static func panelWidth(count: Int, visibleFrame: CGRect) -> CGFloat {
    let viewport = viewportWidth(visibleFrame: visibleFrame)
    let content = contentWidth(
      count: count, cardWidth: cardWidth(count: count, available: viewport))
    return min(content, viewport)
  }

  /// Where to place a `size` panel for a key window on a screen: centred on the **window**, then
  /// pushed back inside `visibleFrame` if that overhangs. Centring on the window rather than the
  /// screen is what keeps the rail where the user is looking with Stage Manager or an off-centre
  /// window; the clamp is what keeps it on screen anyway.
  static func panelOrigin(size: CGSize, windowFrame: CGRect, visibleFrame: CGRect) -> CGPoint {
    let centred = CGPoint(
      x: windowFrame.midX - size.width / 2, y: windowFrame.midY - size.height / 2)
    let minX = visibleFrame.minX + screenMargin
    let maxX = max(minX, visibleFrame.maxX - screenMargin - size.width)
    let minY = visibleFrame.minY + screenMargin
    let maxY = max(minY, visibleFrame.maxY - screenMargin - size.height)
    return CGPoint(
      x: min(max(centred.x, minX), maxX), y: min(max(centred.y, minY), maxY))
  }

  // MARK: Contrast floors (D14)

  /// Every text and indicator role on a card, resolved against the card's own fill.
  ///
  /// The cursor ring clearing 3:1 says nothing about the rest, and the rail's surface is
  /// vibrancy + `panel.opacity(0.7)` over a *user-supplied* ghostty theme — a theme whose foreground
  /// sits close to its background washes out the name, the subtitle and the diff bars while the ring
  /// still passes. So each role gets its own floor: 4.5:1 for text (11–13pt body), 3:1 for indicators,
  /// the ring and the drawn miniatures.
  ///
  /// Resolved as **`NSColor`**, with `Color` accessors on top. Never the other way round: converting a
  /// SwiftUI `Color` back with `NSColor(_:)` yields a lazily-resolved, SwiftUI-backed colour whose
  /// `usingColorSpace` returns nil outside a view update — so a contrast check silently no-ops and
  /// re-wrapping the result in a `Color` crashes in `Color._apply` during layout. Every input here
  /// starts from a `ns*` token.
  struct Palette {
    let nsName: NSColor
    let nsSubtitle: NSColor
    let nsRing: NSColor
    let nsDot: NSColor
    let nsDiffAdd: NSColor
    let nsDiffRemove: NSColor
    /// True when a floor could not be met by nudging alone, so the card drops vibrancy for an opaque
    /// fill. Legibility outranks the material.
    let needsOpaqueFill: Bool

    var name: Color { Color(nsColor: nsName) }
    var subtitle: Color { Color(nsColor: nsSubtitle) }
    var ring: Color { Color(nsColor: nsRing) }
    var dot: Color { Color(nsColor: nsDot) }
    var diffAdd: Color { Color(nsColor: nsDiffAdd) }
    var diffRemove: Color { Color(nsColor: nsDiffRemove) }

    static let textTarget: CGFloat = 4.5
    static let indicatorTarget: CGFloat = 3.0
  }

  static func palette(for tokens: ThemeTokens) -> Palette {
    let base = tokens.nsPanel
    let fg = tokens.nsFg
    func fix(_ color: NSColor, _ target: CGFloat) -> NSColor {
      ThemeTokens.legible(color, on: base, towards: fg, target: target)
    }
    let name = fix(fg, Palette.textTarget)
    // `fgDim` is fg at 40% — flattened against the card fill first, because `legible` reasons about
    // opaque colours and a translucent one would measure as its own alpha-less form.
    let dim = base.blended(withFraction: 0.55, of: fg) ?? fg
    let accent = fix(tokens.nsAccent, Palette.indicatorTarget)
    return Palette(
      nsName: name,
      nsSubtitle: fix(dim, Palette.textTarget),
      nsRing: accent,
      nsDot: accent,
      nsDiffAdd: fix(tokens.nsDiffAddFg, Palette.indicatorTarget),
      nsDiffRemove: fix(tokens.nsDiffRemoveFg, Palette.indicatorTarget),
      // `legible` walks towards the foreground and stops at 100%; if even the pure foreground can't
      // clear the text floor against this fill, the fill itself is the problem.
      needsOpaqueFill: ThemeTokens.contrastRatio(name, base) < Palette.textTarget
    )
  }
}
