import Defaults
import GhosttyKit
import XCTest

@testable import Workroom

/// Settings ▸ Terminal's font and cursor, as `ghostty.conf` lines (`TerminalTypography`), the face
/// a weight and italic resolve to (`TerminalFontCatalog`), and the linked engine accepting every
/// line they can write.
@MainActor
final class TerminalTypographyTests: XCTestCase {
  // A static family with an italic, and a variable one with none, so the lines don't depend on the
  // fonts this Mac has.
  private let staticFaces = [
    TerminalFontFace(styleName: "Light", weight: 300, italic: false, weightAxis: nil),
    TerminalFontFace(styleName: "Regular", weight: 400, italic: false, weightAxis: nil),
    TerminalFontFace(styleName: "Bold", weight: 700, italic: false, weightAxis: nil),
    TerminalFontFace(styleName: "Italic", weight: 400, italic: true, weightAxis: nil),
    TerminalFontFace(styleName: "Bold Italic", weight: 700, italic: true, weightAxis: nil),
  ]
  private let variableFaces = [
    TerminalFontFace(styleName: "Thin", weight: 100, italic: false, weightAxis: 100...800),
    TerminalFontFace(styleName: "Regular", weight: 400, italic: false, weightAxis: 100...800),
    TerminalFontFace(styleName: "Bold", weight: 700, italic: false, weightAxis: 100...800),
  ]

  private func lines(_ typography: TerminalTypography) -> [String] {
    typography.configLines { family in
      switch family {
      case "Static Mono": return self.staticFaces
      case "Variable Mono", TerminalFontCatalog.builtInFamily: return self.variableFaces
      default: return []
      }
    }
  }

  // MARK: Lines

  /// The defaults write nothing, so a user who never opens the settings keeps the config they had.
  func testDefaultsWriteNoLines() {
    XCTAssertEqual(lines(TerminalTypography()), [])
  }

  func testTheGeneratedConfigIsUnchangedAtTheDefaults() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-typography-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let plain = dir.appendingPathComponent("plain.conf")
    let typed = dir.appendingPathComponent("typed.conf")
    XCTAssertTrue(GhosttyApp.writeThemeConfig(theme: .named("Nord"), to: plain))
    XCTAssertTrue(
      GhosttyApp.writeThemeConfig(
        theme: .named("Nord"), typography: TerminalTypography(), to: typed))
    XCTAssertEqual(
      try String(contentsOf: plain, encoding: .utf8), try String(contentsOf: typed, encoding: .utf8)
    )
    XCTAssertFalse(try String(contentsOf: plain, encoding: .utf8).contains("font-"))
  }

  /// Each face libghostty draws with gets its own lines: regular text at the weight, bold text a
  /// step heavier, and italic text in the italic face at those weights.
  func testAStaticWeightNamesAFaceForEachOfTheFourStyles() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Static Mono", weight: 300)),
      [
        "font-family = \"Static Mono\"", "font-style = \"Light\"", "font-style-bold = \"Regular\"",
        "font-style-italic = \"Italic\"", "font-style-bold-italic = \"Italic\"",
      ])
  }

  func testAFamilyAtRegularNamesItsFourFaces() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Static Mono")),
      [
        "font-family = \"Static Mono\"", "font-style = \"Regular\"", "font-style-bold = \"Bold\"",
        "font-style-italic = \"Italic\"", "font-style-bold-italic = \"Bold Italic\"",
      ])
  }

  func testAWeightTheFontLacksNamesTheNearestFace() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Static Mono", weight: 600)),
      [
        "font-family = \"Static Mono\"", "font-style = \"Bold\"", "font-style-bold = \"Bold\"",
        "font-style-italic = \"Bold Italic\"", "font-style-bold-italic = \"Bold Italic\"",
      ])
  }

  /// Italic chosen: regular and bold text both use the italic faces.
  func testItalicNamesTheItalicFaces() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Static Mono", italic: true)),
      [
        "font-family = \"Static Mono\"", "font-style = \"Italic\"",
        "font-style-bold = \"Bold Italic\"", "font-style-italic = \"Italic\"",
        "font-style-bold-italic = \"Bold Italic\"",
      ])
  }

  /// A variable face is named by its default instance and set with `wght`, so any step works, and
  /// bold text gets its own `wght`. With no italic face, no italic lines: libghostty slants the
  /// upright face itself rather than being handed it by name.
  func testAVariableWeightSetsWghtForRegularAndBold() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Variable Mono", weight: 500)),
      [
        "font-family = \"Variable Mono\"", "font-style = \"Regular\"", "font-variation = wght=500",
        "font-style-bold = \"Regular\"", "font-variation-bold = wght=700",
      ])
  }

  func testItalicOnAFamilyWithoutOneStaysUpright() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Variable Mono", italic: true)),
      [
        "font-family = \"Variable Mono\"", "font-style = \"Regular\"", "font-variation = wght=400",
        "font-style-bold = \"Regular\"", "font-variation-bold = wght=700",
      ])
  }

  /// The built-in font takes no weight from the engine's embedded copy, so a weight names the
  /// registered JetBrains Mono.
  func testAWeightOnTheBuiltInFontNamesJetBrainsMono() {
    XCTAssertEqual(
      lines(TerminalTypography(weight: 300)),
      [
        "font-family = \"JetBrains Mono\"", "font-style = \"Regular\"", "font-variation = wght=300",
        "font-style-bold = \"Regular\"", "font-variation-bold = wght=400",
      ])
  }

  /// Bold past the end of a variable font's axis is drawn at the end, still with a `wght`: from
  /// Semibold up bold asks for Black, and this axis stops at Extra Bold.
  func testBoldPastAVariableAxisIsDrawnAtItsEnd() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Variable Mono", weight: 600)),
      [
        "font-family = \"Variable Mono\"", "font-style = \"Regular\"", "font-variation = wght=600",
        "font-style-bold = \"Regular\"", "font-variation-bold = wght=800",
      ])
    XCTAssertEqual(
      lines(TerminalTypography(family: "Variable Mono", weight: 800)),
      [
        "font-family = \"Variable Mono\"", "font-style = \"Regular\"", "font-variation = wght=800",
        "font-style-bold = \"Regular\"", "font-variation-bold = wght=800",
      ])
  }

  // MARK: Snapping to a font

  func testSnappingMovesAWeightTheFontLacksToTheNearest() {
    let snapped = TerminalTypography(family: "Static Mono", weight: 600).snapped(to: staticFaces)
    XCTAssertEqual(snapped.weight, 700)
    XCTAssertFalse(snapped.italic)
  }

  func testSnappingTurnsItalicOffForAFamilyWithoutOne() {
    let snapped = TerminalTypography(family: "Variable Mono", weight: 500, italic: true)
      .snapped(to: variableFaces)
    XCTAssertFalse(snapped.italic)
    XCTAssertEqual(snapped.weight, 500, "the variable axis spans 500, so it stays")
  }

  /// Italic offers only the italic faces' weights, so a weight only the upright has moves too.
  func testSnappingToItalicUsesTheItalicWeights() {
    let snapped = TerminalTypography(family: "Static Mono", weight: 300, italic: true)
      .snapped(to: staticFaces)
    XCTAssertTrue(snapped.italic)
    XCTAssertEqual(snapped.weight, 400)
  }

  func testSnappingLeavesAWeightTheFontHas() {
    let typography = TerminalTypography(family: "Static Mono", weight: 300)
    XCTAssertEqual(typography.snapped(to: staticFaces), typography)
  }

  /// No faces is a font this Mac lacks: the saved choice stays for when it comes back.
  func testSnappingKeepsTheChoiceForAFontThisMacLacks() {
    let typography = TerminalTypography(family: "Gone Mono", weight: 300, italic: true)
    XCTAssertEqual(typography.snapped(to: []), typography)
  }

  func testOfferedWeightsFallBackToRegular() {
    XCTAssertEqual(TerminalTypography().offeredWeights(in: []), [400])
    XCTAssertEqual(TerminalTypography().offeredWeights(in: staticFaces), [300, 400, 700])
  }

  func testTheKeysDefaultToTheTypographyDefaults() {
    XCTAssertEqual(
      Defaults.Keys.terminalFontWeight.defaultValue, TerminalTypography.defaults.weight)
    XCTAssertEqual(Defaults.Keys.terminalFontSize.defaultValue, TerminalTypography.defaults.size)
    XCTAssertEqual(
      Defaults.Keys.terminalLineHeight.defaultValue, TerminalTypography.defaults.lineHeight)
    XCTAssertEqual(TerminalTypography.keys.count, 7)
  }

  func testBoldIsTheNextWeightUp() {
    XCTAssertEqual(TerminalTypography.boldWeight(for: 100), 400)
    XCTAssertEqual(TerminalTypography.boldWeight(for: 300), 400)
    XCTAssertEqual(TerminalTypography.boldWeight(for: 400), 700)
    XCTAssertEqual(TerminalTypography.boldWeight(for: 500), 700)
    XCTAssertEqual(TerminalTypography.boldWeight(for: 600), 900)
    XCTAssertEqual(TerminalTypography.boldWeight(for: 900), 900)
  }

  func testAFamilyThisMacLacksIsStillNamed() {
    XCTAssertEqual(lines(TerminalTypography(family: "Gone Mono")), ["font-family = \"Gone Mono\""])
  }

  func testANameCannotEndItsValueOrStartADirective() {
    XCTAssertEqual(
      lines(TerminalTypography(family: "Evil\"\nminimum-contrast = 0\\")),
      ["font-family = \"Evilminimum-contrast = 0\""])
  }

  func testSizeAndLineHeight() {
    XCTAssertEqual(lines(TerminalTypography(size: 15)), ["font-size = 15"])
    XCTAssertEqual(lines(TerminalTypography(size: 12.5)), ["font-size = 12.5"])
    XCTAssertEqual(lines(TerminalTypography(size: 500)), ["font-size = 72"])
    XCTAssertEqual(lines(TerminalTypography(lineHeight: 1.25)), ["adjust-cell-height = 25%"])
    XCTAssertEqual(lines(TerminalTypography(lineHeight: 0.9)), ["adjust-cell-height = -10%"])
  }

  /// A chosen shape turns the shell integration's prompt bar off, or the prompt ignores it.
  func testACursorShapeTurnsOffTheIntegrationsPromptCursor() {
    XCTAssertEqual(
      lines(TerminalTypography(cursorShape: .hollowBlock)),
      ["cursor-style = block_hollow", "shell-integration-features = no-cursor"])
    XCTAssertEqual(
      lines(TerminalTypography(cursorShape: .underline)),
      ["cursor-style = underline", "shell-integration-features = no-cursor"])
  }

  func testBlink() {
    XCTAssertEqual(lines(TerminalTypography(cursorBlinks: false)), ["cursor-style-blink = false"])
    XCTAssertEqual(lines(TerminalTypography(cursorBlinks: true)), [])
  }

  // MARK: Catalog

  func testWeightsOffered() {
    XCTAssertEqual(TerminalFontCatalog.weights(in: staticFaces, italic: false), [300, 400, 700])
    XCTAssertEqual(TerminalFontCatalog.weights(in: staticFaces, italic: true), [400, 700])
    XCTAssertEqual(
      TerminalFontCatalog.weights(in: variableFaces, italic: false),
      [100, 200, 300, 400, 500, 600, 700, 800])
    // No italic: the upright weights.
    XCTAssertEqual(TerminalFontCatalog.weights(in: variableFaces, italic: true).count, 8)
  }

  func testNearestWeight() {
    XCTAssertEqual(TerminalFontCatalog.nearest(300, in: [400, 700]), 400)
    XCTAssertEqual(TerminalFontCatalog.nearest(550, in: [400, 700]), 400)
    XCTAssertEqual(TerminalFontCatalog.nearest(600, in: [400, 700]), 700)
  }

  func testWeightFromStyleNameThenTrait() {
    XCTAssertEqual(TerminalFontCatalog.weight(styleName: "SemiBold Italic", trait: 0.4), 600)
    XCTAssertEqual(TerminalFontCatalog.weight(styleName: "ExtraLight", trait: nil), 200)
    XCTAssertEqual(TerminalFontCatalog.weight(styleName: "Light", trait: nil), 300)
    XCTAssertEqual(TerminalFontCatalog.weight(styleName: "Retina", trait: 0.1), 400)
    XCTAssertEqual(TerminalFontCatalog.weight(styleName: "W6", trait: 0.3), 600)
  }

  /// The bundled JetBrains Mono is registered for the app (or installed), and reads as a variable
  /// family with an italic: what the built-in font's weight and italic rely on.
  func testTheBuiltInFontIsAvailableWithWeightsAndItalic() {
    XCTAssertTrue(GhosttyApp.shared.isReady, "the engine didn't start")
    let faces = TerminalFontCatalog.faces(of: TerminalFontCatalog.builtInFamily)
    XCTAssertFalse(faces.isEmpty, "JetBrains Mono isn't available to the app")
    XCTAssertTrue(faces.contains(where: \.italic))
    XCTAssertGreaterThan(TerminalFontCatalog.weights(in: faces, italic: false).count, 3)
  }

  // MARK: Engine

  /// Every key these settings write, at a non-default value, loads with no diagnostics.
  func testTheEngineAcceptsEveryLine() throws {
    XCTAssertTrue(GhosttyApp.shared.isReady, "the engine didn't start")
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-typography-\(UUID().uuidString).conf")
    defer { try? FileManager.default.removeItem(at: url) }

    func diagnostics(_ typography: TerminalTypography) throws -> [String] {
      XCTAssertTrue(
        GhosttyApp.writeThemeConfig(theme: .named("Nord"), typography: typography, to: url))
      let cfg = try XCTUnwrap(ghostty_config_new())
      defer { ghostty_config_free(cfg) }
      url.path.withCString { ghostty_config_load_file(cfg, $0) }
      ghostty_config_finalize(cfg)
      return (0..<ghostty_config_diagnostics_count(cfg)).map {
        String(cString: ghostty_config_get_diagnostic(cfg, $0).message)
      }
    }

    XCTAssertEqual(
      try diagnostics(
        TerminalTypography(
          weight: 300, italic: true, size: 15.5, lineHeight: 1.3, cursorShape: .hollowBlock,
          cursorBlinks: false)), [])
    XCTAssertEqual(try diagnostics(TerminalTypography(cursorShape: .bar, cursorBlinks: false)), [])
    XCTAssertEqual(try diagnostics(TerminalTypography(lineHeight: 0.8)), [])
  }
}
