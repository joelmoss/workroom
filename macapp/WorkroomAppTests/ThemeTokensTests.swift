import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// Derivation tests for `ThemeTokens` (issue #36): one bg + fg + palette must yield the accent,
/// the alpha-variant fills, the diff colours, and the right `colorScheme`. UI- and
/// filesystem-free — previews are built in-memory.
@MainActor
final class ThemeTokensTests: XCTestCase {
  private func ns(_ hex: String) -> NSColor { ThemeService.parseHex(hex)! }

  private func preview(bg: String, fg: String, palette: [String]) -> ThemePreview {
    ThemePreview(name: "T", background: ns(bg), foreground: ns(fg), palette: palette.map(ns))
  }

  /// sRGB components of a SwiftUI Color, for robust comparison.
  private func rgb(_ color: Color) -> (CGFloat, CGFloat, CGFloat) {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
  }

  private func assertRGB(_ color: Color, _ hex: String, line: UInt = #line) {
    let got = rgb(color)
    let want = ns(hex).usingColorSpace(.sRGB)!
    XCTAssertEqual(got.0, want.redComponent, accuracy: 0.01, line: line)
    XCTAssertEqual(got.1, want.greenComponent, accuracy: 0.01, line: line)
    XCTAssertEqual(got.2, want.blueComponent, accuracy: 0.01, line: line)
  }

  private func full(
    bg: String, fg: String, accent4: String, green2: String = "#00ff00",
    red1: String = "#ff0000", cyan6: String = "#00ffff", yellow3: String = "#ffff00"
  ) -> ThemePreview {
    var pal = Array(repeating: "#808080", count: 16)
    pal[1] = red1
    pal[2] = green2
    pal[3] = yellow3
    pal[4] = accent4
    pal[6] = cyan6
    return preview(bg: bg, fg: fg, palette: pal)
  }

  func testAccentIsPaletteIndexFour() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    assertRGB(t.accent, "#3b9ec4")
  }

  func testDiffColoursFromPalette() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    assertRGB(t.diffAddFg, "#00ff00")  // palette[2]
    assertRGB(t.diffRemoveFg, "#ff0000")  // palette[1]
    assertRGB(t.diffHunkFg, "#00ffff")  // palette[6]
    assertRGB(t.warning, "#ffff00")  // palette[3]
  }

  func testColorSchemeFromBackgroundLuminance() {
    XCTAssertEqual(
      ThemeTokens(preview: full(bg: "#fbfbfd", fg: "#1d1d1f", accent4: "#1e7fa8")).colorScheme,
      .light)
    XCTAssertEqual(
      ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4")).colorScheme,
      .dark)
  }

  func testContrastingForeground() {
    XCTAssertEqual(ThemeTokens.contrastingForeground(for: ns("#ffffff")), .black)
    XCTAssertEqual(ThemeTokens.contrastingForeground(for: ns("#000000")), .white)
    XCTAssertEqual(ThemeTokens.contrastingForeground(for: ns("#1c1c1e")), .white)
  }

  /// The band a brightness threshold gets wrong. This used to be `luminance > 0.6 ? .black : .white`, and
  /// a mid-tone fill sits just under 0.6 *apparent* brightness while black beats white on it several times
  /// over — the illegible-monogram bug (1.77:1 where black gave 11.8:1). Picking by measurement has no
  /// threshold to miscalibrate.
  func testContrastingForegroundPicksByMeasurementNotBrightness() {
    for hex in ["#8a8a8a", "#7f9f5f", "#a08a4a", "#9a7fbf"] {
      let fill = ns(hex)
      let ink = ThemeTokens.contrastingForeground(for: fill)
      let chosen = ThemeTokens.contrastRatio(ink, fill)
      let rejected = ThemeTokens.contrastRatio(ink == .black ? .white : .black, fill)
      XCTAssertGreaterThanOrEqual(chosen, rejected, "\(hex) took the worse of black/white")
    }
  }

  func testLuminanceBounds() {
    XCTAssertEqual(ThemeTokens.luminance(of: ns("#ffffff")), 1.0, accuracy: 0.001)
    XCTAssertEqual(ThemeTokens.luminance(of: ns("#000000")), 0.0, accuracy: 0.001)
  }

  /// `luminance` is WCAG — sRGB **linearized** before weighting — and `perceivedBrightness` is the
  /// gamma-encoded weighting it used to be. Mid-grey separates them: 0.5 encoded, 0.216 linear.
  ///
  /// Not a pedantic distinction. Weighting encoded components inflates dark colours (`#2e3440` reads 0.20
  /// against a true 0.033), which collapses dark-background/light-text ratios: the switcher rail's name
  /// text measured under 4.5:1 for 43 of the 56 bundled themes on the old formula and for 3 on this one,
  /// and its "this theme is unreadable, drop the material" fallback was firing for 38 legible themes.
  func testLuminanceIsWCAGWhileBrightnessStaysPerceptual() {
    XCTAssertEqual(ThemeTokens.luminance(of: ns("#808080")), 0.216, accuracy: 0.005)
    XCTAssertEqual(ThemeTokens.perceivedBrightness(of: ns("#808080")), 0.502, accuracy: 0.005)
    // A real theme: Nord's foreground on its background — 9.2:1, legible as anyone can see. The old
    // formula scored that same pair 3.6:1, which is what had the rail treating Nord as a contrast failure.
    XCTAssertEqual(ThemeTokens.contrastRatio(ns("#d8dee9"), ns("#2e3440")), 9.25, accuracy: 0.15)
  }

  /// Light/dark classification must keep reading the *encoded* value, or a visibly light background whose
  /// linearized luminance is under 0.5 flips to dark and re-themes the whole app.
  func testColorSchemeStillFollowsApparentBrightness() {
    for (hex, expected) in [
      ("#c8c8c8", ColorScheme.light), ("#8f8f8f", .light), ("#4a4a4a", .dark),
    ] {
      XCTAssertEqual(
        ThemeTokens(preview: full(bg: hex, fg: "#101010", accent4: "#1e7fa8")).colorScheme,
        expected,
        "\(hex)")
    }
  }

  func testTerminalDimIsBackgroundAndFocusedIsForeground() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    XCTAssertEqual(
      NSColor(t.terminalDim).usingColorSpace(.sRGB)?.redComponent ?? -1, 0x1c / 255, accuracy: 0.01)
    let focused = NSColor(t.focused).usingColorSpace(.sRGB)!
    XCTAssertEqual(focused.redComponent, 0xd8 / 255, accuracy: 0.01)  // fg hue
    XCTAssertEqual(focused.alphaComponent, 0.3, accuracy: 0.01)  // fixed alpha
  }

  func testFallbackToSystemColoursWhenNoPreview() {
    // No theme resolved (first launch / deleted file) → degrade to the pre-theming native look.
    let t = ThemeTokens(preview: nil)
    XCTAssertEqual(t.nsBg, .textBackgroundColor)
    XCTAssertEqual(t.nsFg, .textColor)
  }

  func testAlphaVariantsDeriveFromForeground() {
    let t = ThemeTokens(preview: full(bg: "#000000", fg: "#ffffff", accent4: "#3b9ec4"))
    // surface/border/hover are foreground at low alpha — over a black bg they read as faint greys.
    let surface = NSColor(t.surface).usingColorSpace(.sRGB)!
    XCTAssertEqual(surface.alphaComponent, 0.08, accuracy: 0.01)
  }

  // MARK: - Syntax sub-palette (tree-sitter diff highlighting, phase 1)

  func testCaptureCategoryMapping() {
    // Any capture collapses to its family by the leading dotted component.
    XCTAssertEqual(ThemeTokens.category(for: "keyword"), .keyword)
    XCTAssertEqual(ThemeTokens.category(for: "keyword.control.return"), .keyword)
    XCTAssertEqual(ThemeTokens.category(for: "conditional"), .keyword)
    XCTAssertEqual(ThemeTokens.category(for: "function.method.builtin"), .function)
    XCTAssertEqual(ThemeTokens.category(for: "type.builtin"), .type)
    XCTAssertEqual(ThemeTokens.category(for: "string.special.path"), .string)
    XCTAssertEqual(ThemeTokens.category(for: "comment.line"), .comment)
    XCTAssertEqual(ThemeTokens.category(for: "number"), .number)
    XCTAssertEqual(ThemeTokens.category(for: "operator"), .punctuation)
    XCTAssertEqual(ThemeTokens.category(for: "punctuation.bracket"), .punctuation)
    XCTAssertEqual(ThemeTokens.category(for: "tag"), .tag)
    XCTAssertEqual(ThemeTokens.category(for: "attribute"), .attribute)
    // Unknown captures fold to nil → default foreground.
    XCTAssertNil(ThemeTokens.category(for: "spell"))
    XCTAssertNil(ThemeTokens.category(for: ""))
  }

  func testSyntaxColoursDeriveFromPalette() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    // string → palette[2] (green), keyword → palette[5] (the full() default grey #808080).
    assertRGB(t.syntaxColor(forCapture: "string.quoted")!, "#00ff00")
    // Unknown capture → nil (caller renders default foreground).
    XCTAssertNil(t.syntaxColor(forCapture: "definitely-not-a-capture"))
  }

  func testSyntaxColourContrastGuardOnAddedBackground() {
    // A green string on a green-tinted add background is the wash-out case: force the palette green
    // to equal the add colour (palette[2]) so the base string colour sits right on the tint.
    let t = ThemeTokens(preview: full(bg: "#0a2a0a", fg: "#e8ffe8", accent4: "#3b9ec4"))
    let bg = t.nsAddBackgroundOpaque
    let base = NSColor(t.syntaxColor(forCapture: "string")!).usingColorSpace(.sRGB)!
    let onAdd = NSColor(t.syntaxColor(forCapture: "string", onAddedBackground: true)!)
      .usingColorSpace(.sRGB)!
    // The on-add colour must be at least as legible as the base against the add background, and
    // clear a minimal contrast floor.
    XCTAssertGreaterThanOrEqual(
      ThemeTokens.contrastRatio(onAdd, bg), ThemeTokens.contrastRatio(base, bg))
    XCTAssertGreaterThanOrEqual(ThemeTokens.contrastRatio(onAdd, bg), 2.0)
  }

  func testEverySyntaxCategoryHasAColour() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    for category in ThemeTokens.SyntaxCategory.allCases {
      XCTAssertNotNil(t.syntaxByCategory[category], "category \(category) has no colour")
    }
  }
}
