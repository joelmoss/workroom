import AppKit
import XCTest

@testable import Workroom

/// D14 / T15: every rail role's contrast floor, measured against **every bundled ghostty theme** rather
/// than a hand-picked pair.
///
/// Two fixtures can't answer this. The rail's colours are derived from a *user-supplied* theme — the tile
/// hues, the accent, the two diff foregrounds and the dimmed subtitle are all computed from whatever
/// `background`/`foreground`/ANSI palette a theme file happens to carry — and the ways that goes wrong are
/// specific to real palettes: a near-monochrome theme, a theme whose ANSI blue is nearly its background, a
/// light theme with a pale accent. The 56 bundled themes ARE the product's input set, so they are what the
/// floors get asserted against.
///
/// The sweep is also what caught the contrast metric itself: `ThemeTokens.luminance` was weighting
/// gamma-encoded sRGB, so 43 of the 56 themes scored below the body-text floor and 38 of them lost the
/// Liquid Glass surface to the opaque fallback. A floor that holds for two fixtures says nothing about the
/// fiftieth theme.
@MainActor
final class SwitcherThemeSweepTests: XCTestCase {

  /// Every bundled theme, parsed. Read from the app bundle's own `ghostty/themes` — deliberately NOT
  /// through `ThemeService.themeDirectories()`, whose first entry is `~/.config/ghostty/themes`: a user
  /// override there would make this test's result depend on the machine running it.
  private func bundledThemes() throws -> [ThemePreview] {
    let root = try XCTUnwrap(
      Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes"),
      "the app bundle must carry its themes — the terminal can't start without them")
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    let themes = names.compactMap {
      ThemeService.parseThemeFile(atPath: root.path + "/" + $0, name: $0)
    }
    XCTAssertGreaterThan(
      themes.count, 40, "the bundled set is ~56 themes; a near-empty sweep is a bug")
    return themes
  }

  /// Text roles. The guarantee is *two-tiered* by design (D14): a card keeps its Liquid Glass while its
  /// text clears `opaqueFillFloor`, and drops to an opaque fill below that. So the invariant asserted here
  /// is the floor, not the 4.5:1 target — a theme landing in the 4.0–4.5 band deliberately keeps the
  /// material, because going opaque wouldn't raise the ratio anyway (it's measured against `nsPanel`
  /// either way; what it buys is certainty, and that isn't worth the whole surface for a near miss).
  ///
  /// The counts are asserted too, loosely. They are what makes this a regression net rather than a
  /// tautology: if a future change pushes half the bundled set into the near-miss band or into the opaque
  /// fallback, every per-theme assertion above still passes while the rail quietly stops being glass.
  func testEveryBundledThemeKeepsTheRailsTextLegible() throws {
    var fellBack: [String] = []
    var nearMiss: [String] = []
    let themes = try bundledThemes()
    for theme in themes {
      let tokens = ThemeTokens(preview: theme)
      let palette = SwitcherRailLayout.palette(for: tokens)
      if palette.needsOpaqueFill {
        fellBack.append(theme.name)
        continue
      }
      for (role, color) in [("name", palette.nsName), ("subtitle", palette.nsSubtitle)] {
        XCTAssertGreaterThanOrEqual(
          ThemeTokens.contrastRatio(color, tokens.nsPanel),
          SwitcherRailLayout.Palette.opaqueFillFloor - 0.01,
          "\(theme.name): the \(role) is below the floor that keeps the material on")
      }
      if ThemeTokens.contrastRatio(palette.nsName, tokens.nsPanel)
        < SwitcherRailLayout.Palette.textTarget
      {
        nearMiss.append(theme.name)
      }
    }
    // Measured at the time of writing: 1 fallback (iTerm2 Solarized Light, 3.90:1) and 3 in the band
    // (Everforest Light Med 4.39, TokyoNight Day 4.25, iTerm2 Solarized Dark 4.35).
    XCTAssertLessThanOrEqual(
      fellBack.count, 4,
      "the opaque fallback is the exception, not the rule — fell back: \(fellBack)")
    XCTAssertLessThanOrEqual(
      nearMiss.count, 6, "the 4.0–4.5 band should stay a handful — in it: \(nearMiss)")
  }

  /// Indicator roles: 3:1 for the ring, the running dot and the diff bars.
  func testEveryBundledThemeKeepsTheRailsIndicatorsVisible() throws {
    for theme in try bundledThemes() {
      let tokens = ThemeTokens(preview: theme)
      let palette = SwitcherRailLayout.palette(for: tokens)
      for (role, color) in [
        ("ring", palette.nsRing), ("dot", palette.nsDot), ("diffAdd", palette.nsDiffAdd),
        ("diffRemove", palette.nsDiffRemove),
      ] {
        XCTAssertGreaterThanOrEqual(
          ThemeTokens.contrastRatio(color, tokens.nsPanel),
          SwitcherRailLayout.Palette.indicatorTarget - 0.01,
          "\(theme.name): \(role) is below the indicator floor")
      }
    }
  }

  /// Every mark tile, on every theme: the tile must be visible against the card, and its monogram legible
  /// on the tile. The second half is what a brightness-threshold ink rule failed — it took white on a
  /// 0.54-brightness tile at 1.77:1 where black gives 11.8:1 — so `ink` measures both candidates.
  func testEveryBundledThemeKeepsEveryMonogramLegible() throws {
    for theme in try bundledThemes() {
      let tokens = ThemeTokens(preview: theme)
      for hue in 0..<SwitcherMark.hueCount {
        let tile = SwitcherMark.tileColor(hue: hue, tokens: tokens)
        XCTAssertGreaterThanOrEqual(
          ThemeTokens.contrastRatio(tile, tokens.nsPanel), SwitcherMark.tileContrastFloor - 0.01,
          "\(theme.name) hue \(hue): the tile itself disappears into the card")
        XCTAssertGreaterThanOrEqual(
          ThemeTokens.contrastRatio(SwitcherMark.ink(on: tile), tile),
          SwitcherRailLayout.Palette.textTarget - 0.01,
          "\(theme.name) hue \(hue): the monogram is illegible on its own tile")
      }
    }
  }

  /// The badge's own pill: its label against the fill it sits on, and the fill against the card.
  ///
  /// This is the role D14 lists last and the one the rail nearly shipped wrong: `UnreadBadge`'s own colours
  /// are the RAW `accent` with ink on top, and the raw accent is exactly what the ring gets corrected away
  /// from — so a pale-accent theme drew an invisible pill beside a visible ring. The rail passes its own
  /// pair instead, which is `nsRing` plus measured ink.
  func testEveryBundledThemeKeepsTheBadgeReadable() throws {
    for theme in try bundledThemes() {
      let tokens = ThemeTokens(preview: theme)
      let palette = SwitcherRailLayout.palette(for: tokens)
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(palette.nsBadgeInk, palette.nsBadgeFill),
        SwitcherRailLayout.Palette.textTarget - 0.01,
        "\(theme.name): the unread count is illegible on its own pill")
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(palette.nsBadgeFill, tokens.nsPanel),
        SwitcherRailLayout.Palette.indicatorTarget - 0.01,
        "\(theme.name): the pill disappears into the card")
    }
  }

  /// The rail's badge and its cursor ring must be the SAME accent. Flagged as an open judgment call when
  /// the rail landed: `legible` walked the ring away from a pale accent while the badge kept the raw one,
  /// so on those themes the two disagreed about what the app's accent is.
  func testTheBadgeAndTheCursorRingAgreeOnTheAccent() throws {
    for theme in try bundledThemes() {
      let palette = SwitcherRailLayout.palette(for: ThemeTokens(preview: theme))
      XCTAssertEqual(
        palette.nsBadgeFill, palette.nsRing,
        "\(theme.name): the badge pill and the cursor ring are both 'the accent'")
    }
  }
}
