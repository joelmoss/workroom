import CoreText
import Foundation
import os

/// One face of a font family, as CoreText lists it.
struct TerminalFontFace: Hashable, Sendable {
  /// The face's style name ("Regular", "Medium Italic"), which `font-style` matches.
  var styleName: String
  /// CSS-style, 100–900.
  var weight: Int
  var italic: Bool
  /// The `wght` axis' range when the face is a variable font, else nil.
  var weightAxis: ClosedRange<Int>?
}

/// The face a weight and italic come to: what `font-style` and `font-variation` name.
struct ResolvedTerminalFace: Equatable, Sendable {
  var styleName: String
  /// A `wght` value for a variable face; nil for a static one.
  var variationWeight: Int?
}

/// The fonts a terminal can use: the monospaced families on this Mac, their faces, and the weights
/// each offers. CoreText only, so it is safe off the main thread.
enum TerminalFontCatalog {
  /// libghostty's built-in font.
  static let builtInFamily = "JetBrains Mono"

  static let weightNames: [Int: String] = [
    100: "Thin", 200: "Extra Light", 300: "Light", 400: "Regular", 500: "Medium",
    600: "Semibold", 700: "Bold", 800: "Extra Bold", 900: "Black",
  ]

  static func weightName(_ weight: Int) -> String {
    weightNames[weight] ?? "\(weight)"
  }

  /// Registers the bundled JetBrains Mono (the font libghostty embeds) for this process, so the
  /// config can name it with a weight or italic (`TerminalTypography.fontLines`), unless this Mac
  /// already has it installed. Idempotent.
  static func registerBundledFonts(bundle: Bundle = .main) {
    guard matchingDescriptors(of: builtInFamily).isEmpty else { return }
    let urls =
      bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? []
    for url in urls {
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    forgetFaces()
  }

  /// The monospaced families on this Mac, sorted for a menu. Hidden system families (a leading
  /// `.`) are left out. A family counts when CoreText says it is monospaced, or, for the fonts that
  /// leave that trait off, when an `i` is as wide as an `M`.
  static func monospacedFamilies() -> [String] {
    // A font installed since the last look may have changed a family's faces too.
    forgetFaces()
    let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
    return
      families
      .filter { !$0.hasPrefix(".") && isMonospaced(family: $0) }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private static func isMonospaced(family: String) -> Bool {
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontFamilyNameAttribute: family] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    // A fallback font (the family is gone) is not the family asked for.
    guard (CTFontCopyFamilyName(font) as String) == family else { return false }
    if CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) { return true }
    var glyphs = [CGGlyph](repeating: 0, count: 2)
    let characters = Array("iM".utf16)
    guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, 2), glyphs[0] != 0,
      glyphs[1] != 0
    else { return false }
    var advances = [CGSize](repeating: .zero, count: 2)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, 2)
    return abs(advances[0].width - advances[1].width) < 0.01 && advances[0].width > 0
  }

  /// Faces by family, so the preview (each SwiftUI pass) and every config write (each theme or
  /// appearance change) don't re-enumerate a family and instantiate a font per face. Cleared when
  /// the bundled fonts register and whenever the family list is rebuilt.
  private static let faceCache = OSAllocatedUnfairLock(initialState: [String: [TerminalFontFace]]())

  private static func forgetFaces() {
    faceCache.withLock { $0.removeAll() }
  }

  /// The family's faces, de-duplicated by style name.
  static func faces(of family: String) -> [TerminalFontFace] {
    guard !family.isEmpty else { return [] }
    if let cached = faceCache.withLock({ $0[family] }) { return cached }
    let faces = loadFaces(of: family)
    faceCache.withLock { $0[family] = faces }
    return faces
  }

  private static func matchingDescriptors(of family: String) -> [CTFontDescriptor] {
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontFamilyNameAttribute: family] as CFDictionary)
    let mandatory: Set<CFString> = [kCTFontFamilyNameAttribute]
    return CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory as CFSet)
      as? [CTFontDescriptor] ?? []
  }

  private static func loadFaces(of family: String) -> [TerminalFontFace] {
    let matches = matchingDescriptors(of: family)
    var seen = Set<String>()
    var faces: [TerminalFontFace] = []
    for match in matches {
      guard
        let style = CTFontDescriptorCopyAttribute(match, kCTFontStyleNameAttribute) as? String,
        seen.insert(style).inserted
      else { continue }
      let traits = CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute) as? [CFString: Any]
      let symbolic = (traits?[kCTFontSymbolicTrait] as? UInt32).map(CTFontSymbolicTraits.init)
      let italic =
        symbolic?.contains(.traitItalic) == true
        || style.localizedCaseInsensitiveContains("italic")
        || style.localizedCaseInsensitiveContains("oblique")
      let trait = traits?[kCTFontWeightTrait] as? Double
      faces.append(
        TerminalFontFace(
          styleName: style, weight: weight(styleName: style, trait: trait), italic: italic,
          weightAxis: weightAxis(of: match)))
    }
    return faces
  }

  /// A face's weight from its style name, which fonts get right far more often than the weight
  /// trait; the trait when the name says nothing.
  static func weight(styleName: String, trait: Double?) -> Int {
    let name = styleName.lowercased().replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
    let keywords: [(String, Int)] = [
      ("extralight", 200), ("ultralight", 200), ("hairline", 100), ("thin", 100),
      ("semibold", 600), ("demibold", 600), ("extrabold", 800), ("ultrabold", 800),
      ("light", 300), ("medium", 500), ("bold", 700), ("heavy", 900), ("black", 900),
      ("book", 400), ("regular", 400), ("normal", 400),
    ]
    if let match = keywords.first(where: { name.contains($0.0) }) { return match.1 }
    guard let trait else { return 400 }
    // `NSFont.Weight`'s values, which CoreText's weight trait shares.
    let table: [(Double, Int)] = [
      (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700),
      (0.56, 800), (0.62, 900),
    ]
    return table.closest(to: trait, by: \.0)?.1 ?? 400
  }

  /// The OpenType tag of the weight axis, `'wght'`, as CoreText and `NSFontDescriptor` key it.
  static let weightAxisTag = 0x7767_6874

  private static func weightAxis(of descriptor: CTFontDescriptor) -> ClosedRange<Int>? {
    let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    guard let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] else { return nil }
    for axis in axes {
      guard (axis[kCTFontVariationAxisIdentifierKey] as? Int) == weightAxisTag,
        let low = axis[kCTFontVariationAxisMinimumValueKey] as? Double,
        let high = axis[kCTFontVariationAxisMaximumValueKey] as? Double, low < high
      else { continue }
      return Int(low.rounded())...Int(high.rounded())
    }
    return nil
  }

  /// The weights `faces` offers, upright or italic: each static face's, and every hundred a variable
  /// face's axis spans.
  static func weights(in faces: [TerminalFontFace], italic: Bool) -> [Int] {
    let matching = faces.filter { $0.italic == italic }
    let pool = matching.isEmpty ? faces : matching
    var weights = Set<Int>()
    for face in pool {
      weights.insert(face.weight)
      if let axis = face.weightAxis {
        for step in stride(from: 100, through: 900, by: 100) where axis.contains(step) {
          weights.insert(step)
        }
      }
    }
    return weights.sorted()
  }

  /// The available weight nearest to `weight`, preferring the lighter on a tie.
  static func nearest(_ weight: Int, in weights: [Int]) -> Int {
    weights.closest(to: Double(weight)) { Double($0) } ?? weight
  }

  /// The face to name for `weight` and `italic`.
  ///
  /// A static face of that weight is named as is. Otherwise a variable face whose axis spans it is
  /// named by the style of its default instance (the one nearest Regular) and set with `wght`.
  /// Otherwise the nearest weight's face. Italic falls back to upright for a family with none.
  static func resolve(weight: Int, italic: Bool, in faces: [TerminalFontFace])
    -> ResolvedTerminalFace?
  {
    let matching = faces.filter { $0.italic == italic }
    let pool = matching.isEmpty ? faces : matching
    guard !pool.isEmpty else { return nil }
    // A variable face takes any weight its axis spans, and one past either end at that end: bold
    // above Semibold asks for Black, and a font whose axis stops at Extra Bold draws it there.
    let variable = pool.filter { $0.weightAxis != nil }
    if let base = variable.closest(
      to: Double(TerminalTypography.regularWeight), by: { Double($0.weight) }),
      let axis = base.weightAxis
    {
      return ResolvedTerminalFace(
        styleName: base.styleName,
        variationWeight: min(max(weight, axis.lowerBound), axis.upperBound))
    }
    if let exact = pool.first(where: { $0.weight == weight }) {
      return ResolvedTerminalFace(styleName: exact.styleName, variationWeight: nil)
    }
    let near = pool.closest(to: Double(weight)) { Double($0.weight) } ?? pool[0]
    return ResolvedTerminalFace(styleName: near.styleName, variationWeight: nil)
  }
}

extension Collection {
  // `fileprivate`: the catalog's weight matching is its only use.
  /// The element whose `value` is nearest `target`, the first of a tie.
  fileprivate func closest(to target: Double, by value: (Element) -> Double) -> Element? {
    self.min(by: { abs(value($0) - target) < abs(value($1) - target) })
  }
}
