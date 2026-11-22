import Defaults
import Foundation

/// The terminal cursor's shape (Settings ▸ Terminal ▸ Cursor).
///
/// `automatic` is libghostty's own behaviour and writes nothing: a block, which Ghostty's shell
/// integration turns into a bar at the prompt. A chosen shape writes `cursor-style` and turns that
/// integration feature off (`shell-integration-features = no-cursor`), or the prompt would still
/// show a bar whatever was chosen. Programs (vim, a TUI) can still ask for another shape with
/// `DECSCUSR`; that is theirs to do.
enum TerminalCursorShape: String, CaseIterable, Identifiable, Sendable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case automatic
  case block
  case bar
  case underline
  case hollowBlock

  var id: Self { self }

  var label: String {
    switch self {
    case .automatic: return "Automatic"
    case .block: return "Block"
    case .bar: return "Bar"
    case .underline: return "Underline"
    case .hollowBlock: return "Hollow Block"
    }
  }

  /// The value for `cursor-style`; nil for `automatic`, which writes no line.
  var configValue: String? {
    switch self {
    case .automatic: return nil
    case .block: return "block"
    case .bar: return "bar"
    case .underline: return "underline"
    case .hollowBlock: return "block_hollow"
    }
  }
}

/// The terminal's font and cursor, as Settings ▸ Terminal sets them, and the `ghostty.conf` lines
/// that say so to libghostty (`GhosttyApp.writeThemeConfig`).
///
/// Every default writes no line at all, so a user who never opens these settings gets exactly the
/// config they had before them.
struct TerminalTypography: Equatable, Sendable {
  // These defaults are the only ones: each `Defaults` key takes its own from `defaults`.
  /// The font family; "" is libghostty's built-in font (JetBrains Mono).
  var family: String = ""
  /// A CSS-style weight, 100 (Thin) to 900 (Black).
  var weight: Int = TerminalTypography.regularWeight
  var italic: Bool = false
  /// Points: libghostty's own default `font-size` on macOS.
  var size: Double = 13
  /// A multiple of the font's own line height.
  var lineHeight: Double = 1
  var cursorShape: TerminalCursorShape = .automatic
  /// On writes nothing, so `cursor-style-blink` stays unset and DEC mode 12 is still honoured, as
  /// before this setting. Off writes `cursor-style-blink = false`, which also tells the shell
  /// integration to keep its prompt cursor steady (`cursor:steady`).
  var cursorBlinks = true

  /// Every setting at its default: what a user who never opens Settings has.
  static let defaults = TerminalTypography()
  static let regularWeight = 400
  static let sizeRange: ClosedRange<Double> = 6...72
  static let lineHeightRange: ClosedRange<Double> = 0.8...2
  /// libghostty's blink phase (`CURSOR_BLINK_INTERVAL`, 600 ms, in `renderer/Thread.zig`), for the
  /// preview.
  static let blinkInterval: TimeInterval = 0.6

  /// Every preference these settings are kept in: what Restore Defaults resets, and part of what
  /// `GhosttyApp` rebuilds the config on.
  static let keys: [Defaults._AnyKey] = [
    .terminalFontFamily, .terminalFontWeight, .terminalFontItalic, .terminalFontSize,
    .terminalLineHeight, .terminalCursorShape, .terminalCursorBlinks,
  ]

  /// The settings as they stand.
  static var current: TerminalTypography {
    TerminalTypography(
      family: Defaults[.terminalFontFamily],
      weight: Defaults[.terminalFontWeight],
      italic: Defaults[.terminalFontItalic],
      size: Defaults[.terminalFontSize],
      lineHeight: Defaults[.terminalLineHeight],
      cursorShape: Defaults[.terminalCursorShape],
      cursorBlinks: Defaults[.terminalCursorBlinks])
  }

  /// The family the terminal draws in: the chosen one, or the built-in font's.
  var effectiveFamily: String {
    family.isEmpty ? TerminalFontCatalog.builtInFamily : family
  }

  /// The face libghostty draws one kind of text in: regular or bold, and upright or italic (italic
  /// when Style is, or when a program asks for it). The config writes one per kind, and the preview
  /// draws with the same ones.
  func face(bold: Bool, italicText: Bool, in faces: [TerminalFontFace]) -> ResolvedTerminalFace? {
    TerminalFontCatalog.resolve(
      weight: bold ? Self.boldWeight(for: weight) : weight, italic: italic || italicText,
      in: faces)
  }

  /// The weights `faces` offers for this Style (`TerminalFontCatalog.weights`), or Regular alone
  /// for a family with none to go by.
  func offeredWeights(in faces: [TerminalFontFace]) -> [Int] {
    let weights = TerminalFontCatalog.weights(in: faces, italic: italic)
    return weights.isEmpty ? [Self.regularWeight] : weights
  }

  /// These settings with the weight and italic moved to what `faces` has: upright for a family with
  /// no italic, and the nearest weight it offers. Unchanged with no faces (a family this Mac lacks),
  /// so the saved choice is kept for when it is installed again.
  func snapped(to faces: [TerminalFontFace]) -> TerminalTypography {
    guard !faces.isEmpty else { return self }
    var snapped = self
    if snapped.italic, !faces.contains(where: \.italic) { snapped.italic = false }
    snapped.weight = TerminalFontCatalog.nearest(weight, in: snapped.offeredWeights(in: faces))
    return snapped
  }

  /// The `ghostty.conf` lines for these settings, in the order they're written.
  ///
  /// `faces` looks a family's faces up; tests hand in their own so the lines don't depend on the
  /// fonts this Mac has.
  func configLines(
    faces: (String) -> [TerminalFontFace] = TerminalFontCatalog.faces(of:)
  ) -> [String] {
    var lines = fontLines(faces: faces)
    let size = Self.clamp(size, to: Self.sizeRange)
    if size != Self.defaults.size {
      lines.append("font-size = \(Self.format(size))")
    }
    // `adjust-cell-height` grows the cell by a percentage of the font's own height, and centres
    // the glyphs in it: what every other terminal calls line height.
    let percent = Int(((Self.clamp(lineHeight, to: Self.lineHeightRange) - 1) * 100).rounded())
    if percent != 0 {
      lines.append("adjust-cell-height = \(percent)%")
    }
    if let style = cursorShape.configValue {
      lines.append("cursor-style = \(style)")
      lines.append("shell-integration-features = no-cursor")
    }
    if !cursorBlinks {
      lines.append("cursor-style-blink = false")
    }
    return lines
  }

  /// `font-family`, then a `font-style` (and a `font-variation` on a variable font) for each of
  /// libghostty's four faces; nothing for the built-in font at its regular weight, upright.
  ///
  /// libghostty has no weight key: a weight is a face, named by `font-style` (which it ignores
  /// unless `font-family` is set too), or, on a variable font, a `wght` value. Each key reaches one
  /// face only, so all four are written: regular text at the chosen weight and style, bold text at
  /// the next weight up (`boldWeight`), and text a program asks to be italic in the italic face at
  /// those same weights. A family with no italic writes no italic lines, so libghostty slants the
  /// upright face itself (`font-synthetic-style`) rather than being handed an upright face by name.
  ///
  /// A weight or italic on the built-in font names it, `JetBrains Mono`, which the app registers for
  /// this process (`TerminalFontCatalog.registerBundledFonts`), since the engine's own embedded copy
  /// takes neither.
  private func fontLines(faces: (String) -> [TerminalFontFace]) -> [String] {
    if Self.sanitized(family).isEmpty, weight == Self.regularWeight, !italic { return [] }
    let named = Self.sanitized(effectiveFamily)
    var lines = ["font-family = \"\(named)\""]
    let available = faces(named)
    let hasItalic = available.contains(where: \.italic)
    let slots: [(suffix: String, bold: Bool, italicText: Bool)] = [
      ("", false, false), ("-bold", true, false), ("-italic", false, true),
      ("-bold-italic", true, true),
    ]
    for slot in slots {
      if slot.italicText, !hasItalic { continue }
      guard let face = face(bold: slot.bold, italicText: slot.italicText, in: available) else {
        continue
      }
      let style = Self.sanitized(face.styleName)
      if !style.isEmpty { lines.append("font-style\(slot.suffix) = \"\(style)\"") }
      if let wght = face.variationWeight {
        lines.append("font-variation\(slot.suffix) = wght=\(wght)")
      }
    }
    return lines
  }

  /// The weight bold text is drawn at for regular text at `weight`: CSS's `bolder`, so Light's bold
  /// is Regular, Regular's is Bold, and from Semibold up it is Black.
  static func boldWeight(for weight: Int) -> Int {
    switch weight {
    case ..<350: return 400
    case ..<550: return 700
    default: return 900
    }
  }

  /// A name safe to quote into the config: no quote, backslash or line break, any of which would end
  /// the value or start a directive of its own. Not `ThemeCatalog.sanitizedThemeName`, which also
  /// drops `/`, legal in a font or style name.
  static func sanitized(_ name: String) -> String {
    String(name.filter { !"\"\\".contains($0) && !$0.isNewline })
      .trimmingCharacters(in: .whitespaces)
  }

  static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  /// `13`, not `13.0`; `13.5` as is.
  static func format(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
  }
}
