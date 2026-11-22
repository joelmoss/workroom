import AppKit
import DesignSystem
import SwiftUI

/// A few lines of terminal in the active theme, set in the chosen font, size and line height, with
/// the chosen cursor, blinking if it blinks: what a terminal will look like.
struct TerminalTypographyPreview: View {
  let typography: TerminalTypography

  var body: some View {
    // `generation` is observed, `activePreview` is not: reading the first repaints on a theme change.
    let _ = ThemeService.shared.generation
    let theme = ThemeService.shared.activePreview
    let font = typography.previewFont()
    let boldFont = typography.previewFont(bold: true)
    let metrics = CellMetrics(font: font, lineHeight: typography.lineHeight)
    func ansi(_ index: Int) -> Color { theme?.ansi(index) ?? .secondary }
    let foreground = theme.map { Color(nsColor: $0.foreground) } ?? .primary
    let prompt =
      Text("~/app ").foregroundColor(ansi(6)) + Text("main ").foregroundColor(ansi(5))
      + Text("❯ ").foregroundColor(ansi(2))

    return VStack(alignment: .leading, spacing: 0) {
      line(metrics) { prompt + Text("git status").foregroundColor(foreground) }
      line(metrics) {
        Text("On branch ").foregroundColor(foreground)
          + Text("main").foregroundColor(ansi(6)).font(Font(boldFont))
      }
      line(metrics) {
        Text("  modified: ").foregroundColor(ansi(1))
          + Text("Sources/Terminal.swift").foregroundColor(ansi(1))
      }
      line(metrics) {
        Text("  new file: ").foregroundColor(ansi(2))
          + Text("Tests/FontTests.swift").foregroundColor(ansi(2))
      }
      HStack(spacing: 0) {
        line(metrics) { prompt }
        PreviewCursor(
          shape: typography.cursorShape, blinks: typography.cursorBlinks, metrics: metrics,
          color: foreground)
      }
    }
    .font(Font(font))
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, Spacing.l)
    .padding(.vertical, Spacing.m)
    .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
    .clipped()
    .background(
      theme.map { Color(nsColor: $0.background) } ?? Color.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    )
    .animation(.easeOut(duration: 0.15), value: typography)
  }

  /// One terminal row: the text centred in a cell of the line height, as libghostty centres it.
  private func line(_ metrics: CellMetrics, @ViewBuilder _ content: () -> Text) -> some View {
    content().frame(height: metrics.height, alignment: .center)
  }
}

extension TerminalTypography {
  /// The face regular (or `bold`) text is drawn in, resolved as the config resolves it
  /// (`face(bold:italicText:in:)`). A family this Mac lacks falls back to the system's monospaced
  /// font, near enough what libghostty's own fallback looks like.
  func previewFont(bold: Bool = false) -> NSFont {
    let size = CGFloat(Self.clamp(size, to: Self.sizeRange))
    let family = effectiveFamily
    var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: family]
    if let face = face(bold: bold, italicText: false, in: TerminalFontCatalog.faces(of: family)) {
      attributes[.face] = face.styleName
      if let wght = face.variationWeight {
        attributes[.variation] = [
          NSNumber(value: TerminalFontCatalog.weightAxisTag): NSNumber(value: wght)
        ]
      }
    }
    if let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size),
      font.familyName == family
    {
      return font
    }
    let weight = bold ? Self.boldWeight(for: self.weight) : self.weight
    let fallback: NSFont.Weight = weight >= 600 ? .semibold : weight <= 300 ? .light : .regular
    return .monospacedSystemFont(ofSize: size, weight: fallback)
  }
}

/// A terminal cell's size for a font and line height.
private struct CellMetrics: Equatable {
  var width: CGFloat
  var height: CGFloat
  /// The glyph box's own height, which the cursor keeps when the line height grows (libghostty
  /// sizes the cursor to the font, not the cell).
  var glyphHeight: CGFloat

  init(font: NSFont, lineHeight: Double) {
    let natural = ceil(font.ascender - font.descender + font.leading)
    glyphHeight = natural
    height = ceil(natural * CGFloat(lineHeight))
    width = font.advancement(forGlyph: font.glyph(withName: "M")).width
    if width <= 0 { width = font.pointSize * 0.6 }
  }
}

/// The preview's cursor, drawn in the chosen shape, blinking at libghostty's pace when it blinks.
private struct PreviewCursor: View {
  /// A filled block lets the glyph under it show a little, as a terminal's inverted cell reads.
  private static let blockOpacity = 0.85

  let shape: TerminalCursorShape
  let blinks: Bool
  let metrics: CellMetrics
  let color: Color

  var body: some View {
    if blinks {
      let interval = TerminalTypography.blinkInterval
      TimelineView(.periodic(from: .now, by: interval)) { context in
        let phase = Int(context.date.timeIntervalSinceReferenceDate / interval)
        glyph.opacity(phase.isMultiple(of: 2) ? 1 : 0)
      }
    } else {
      glyph
    }
  }

  @ViewBuilder private var glyph: some View {
    let thickness = max(1, (metrics.glyphHeight / 12).rounded())
    ZStack(alignment: .bottomLeading) {
      Color.clear
      switch shape {
      case .automatic, .bar:
        // Automatic shows a bar at the prompt, where this cursor sits.
        Rectangle().fill(color).frame(width: max(2, thickness), height: metrics.glyphHeight)
          .frame(maxHeight: .infinity, alignment: .center)
      case .block:
        Rectangle().fill(color.opacity(Self.blockOpacity))
          .frame(width: metrics.width, height: metrics.glyphHeight)
          .frame(maxHeight: .infinity, alignment: .center)
      case .underline:
        Rectangle().fill(color).frame(width: metrics.width, height: thickness)
          .padding(.bottom, (metrics.height - metrics.glyphHeight) / 2)
      case .hollowBlock:
        Rectangle().strokeBorder(color, lineWidth: 1)
          .frame(width: metrics.width, height: metrics.glyphHeight)
          .frame(maxHeight: .infinity, alignment: .center)
      }
    }
    .frame(width: metrics.width, height: metrics.height)
  }
}
