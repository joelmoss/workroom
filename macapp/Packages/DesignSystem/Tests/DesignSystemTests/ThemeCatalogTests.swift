import AppKit
import XCTest

@testable import DesignSystem

/// The theme catalog without an app host (issue #36): the ghostty theme-file parser, name
/// sanitisation, and the bundled family table. What reads the user's choice or the app bundle stays
/// in the app's `ThemeServiceTests`.
final class ThemeCatalogTests: XCTestCase {
  func testParseHexWithAndWithoutHash() {
    let a = ThemeCatalog.parseHex("#282a36")
    let b = ThemeCatalog.parseHex("282a36")
    for c in [a, b] {
      let srgb = c?.usingColorSpace(.sRGB)
      XCTAssertEqual(srgb?.redComponent ?? -1, 0x28 / 255, accuracy: 0.001)
      XCTAssertEqual(srgb?.greenComponent ?? -1, 0x2a / 255, accuracy: 0.001)
      XCTAssertEqual(srgb?.blueComponent ?? -1, 0x36 / 255, accuracy: 0.001)
    }
  }

  func testParseHexRejectsBadInput() {
    XCTAssertNil(ThemeCatalog.parseHex("#fff"))  // 3-char shorthand not supported by ghostty files
    XCTAssertNil(ThemeCatalog.parseHex("#12345"))  // wrong length
    XCTAssertNil(ThemeCatalog.parseHex("nothex"))
    XCTAssertNil(ThemeCatalog.parseHex(""))
  }

  /// `hex` is `parseHex`'s inverse: a theme file's colour comes back as written, and a component
  /// outside 0...1 is clamped rather than wrapped.
  func testHexRoundTripsParseHex() throws {
    for value in ["#282a36", "#000000", "#ffffff", "#0a7fe3"] {
      XCTAssertEqual(ThemeCatalog.hex(try XCTUnwrap(ThemeCatalog.parseHex(value))), value)
    }
    XCTAssertEqual(
      ThemeCatalog.hex(NSColor(srgbRed: 1.2, green: -0.1, blue: 0.5, alpha: 0.3)), "#ff0080")
  }

  private func writeTheme(_ contents: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  func testParseValidThemeFile() {
    var lines = (0..<16).map { "palette = \($0)=#0000\(String(format: "%02x", $0))" }
    lines.append("background = #1c1c1e")
    lines.append("foreground = #d8d8dc")
    lines.append("cursor-color = #3b9ec4")  // ignored by the parser
    let path = writeTheme(lines.joined(separator: "\n"))
    let preview = ThemeCatalog.parseThemeFile(atPath: path, name: "T")
    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.palette.count, 16)
    XCTAssertEqual(
      preview?.background.usingColorSpace(.sRGB)?.blueComponent ?? -1, 0x1e / 255, accuracy: 0.001)
    XCTAssertEqual(
      preview?.palette[4].usingColorSpace(.sRGB)?.blueComponent ?? -1, 0x04 / 255, accuracy: 0.001)
  }

  func testParseMissingBackgroundReturnsNil() {
    let path = writeTheme("foreground = #ffffff\npalette = 0=#000000")
    XCTAssertNil(ThemeCatalog.parseThemeFile(atPath: path, name: "T"))
  }

  func testParseIgnoresForeignAndDashedLines() {
    // background-blur / foreground-... and comments must not be mistaken for background/foreground.
    let path = writeTheme(
      "# a comment\nbackground-blur = true\nbackground = #102030\nforeground = #fefefe\nrandom junk"
    )
    let preview = ThemeCatalog.parseThemeFile(atPath: path, name: "T")
    XCTAssertEqual(
      preview?.background.usingColorSpace(.sRGB)?.redComponent ?? -1, 0x10 / 255, accuracy: 0.001)
    // No palette entries → empty palette, but still valid because bg + fg are present.
    XCTAssertEqual(preview?.palette.count, 0)
  }

  func testSanitizeStripsDangerousCharacters() {
    XCTAssertEqual(ThemeCatalog.sanitizedThemeName("Foo\"\n\rBar"), "FooBar")
    XCTAssertEqual(ThemeCatalog.sanitizedThemeName("../etc/passwd"), "..etcpasswd")
    XCTAssertEqual(ThemeCatalog.sanitizedThemeName("Catppuccin Mocha"), "Catppuccin Mocha")
  }

  // MARK: bundled themes (#733)

  /// Every bundled theme is listed once. Whether each listed name is a real bundled file, and whether
  /// its fixed side matches its background, needs the app bundle: see `ThemeServiceTests`.
  func testEveryBundledThemeIsListedOnce() {
    let names = ThemeCatalog.bundledThemes.map(\.name)
    XCTAssertFalse(names.isEmpty)
    XCTAssertEqual(
      names.count, Set(names).count,
      "bundled themes listed twice: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)"
    )
  }

  /// A family's light theme is a bundled light theme and its dark theme a bundled dark theme, so
  /// choosing a family can never put a dark theme in the light setting.
  func testEveryFamilysThemesAreBundledOnTheirSides() {
    let sides = Dictionary(
      uniqueKeysWithValues: ThemeCatalog.bundledThemes.map { ($0.name, $0.side) })
    for family in ThemeCatalog.families {
      XCTAssertEqual(
        sides[family.light], .light,
        "\(family.name): '\(family.light)' is not a bundled light theme")
      XCTAssertEqual(
        sides[family.dark], .dark, "\(family.name): '\(family.dark)' is not a bundled dark theme")
    }
  }

  // MARK: pair → family

  func testAFamilysPairMatchesTheFamily() {
    XCTAssertEqual(
      ThemeCatalog.family(light: "Catppuccin Latte", dark: "Catppuccin Mocha")?.name, "Catppuccin")
    XCTAssertEqual(ThemeCatalog.familyLabel(light: "Light Owl", dark: "Night Owl"), "Night Owl")
  }

  func testAMixedPairIsCustom() {
    XCTAssertNil(ThemeCatalog.family(light: "Catppuccin Latte", dark: "Nord"))
    XCTAssertEqual(ThemeCatalog.familyLabel(light: "Catppuccin Latte", dark: "Nord"), "Custom")
  }

  /// A family's pair swapped between the sides is not that family.
  func testASwappedPairIsCustom() {
    XCTAssertNil(ThemeCatalog.family(light: "Catppuccin Mocha", dark: "Catppuccin Latte"))
  }

  /// Matched by name, so a user file that replaces a family member keeps the family's name.
  func testAUserReplacementKeepsTheFamilysName() throws {
    try withUserThemes(["Nord Light": "background = #fafafa\nforeground = #101010\n"]) {
      XCTAssertEqual(ThemeCatalog.family(light: "Nord Light", dark: "Nord")?.name, "Nord")
    }
  }

  // MARK: sides

  func testABundledThemeHasItsFixedSide() throws {
    try withUserThemes([:]) {
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "Workroom Light"), .light)
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "Workroom"), .dark)
    }
  }

  func testAnUnknownThemeHasNoSide() throws {
    try withUserThemes([:]) {
      XCTAssertNil(ThemeCatalog.side(ofThemeNamed: "Does Not Exist"))
    }
  }

  /// A user's own theme is classified by its background, and one replacing a bundled theme takes the
  /// replacement's side.
  func testAUserThemeIsClassifiedByItsBackground() throws {
    try withUserThemes([
      "My Paper": "background = #f4f1e8\nforeground = #202020\n",
      "My Night": "background = #101418\nforeground = #e0e0e0\n",
      "Workroom Light": "background = #000000\nforeground = #ffffff\n",
    ]) {
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "My Paper"), .light)
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "My Night"), .dark)
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "Workroom Light"), .dark)
    }
  }

  /// A user file that doesn't parse is ignored: a bundled theme keeps its side, anything else has none.
  func testAnUnparseableUserThemeIsIgnored() throws {
    try withUserThemes([
      "Broken": "not a theme\n",
      "Workroom Light": "foreground = #000000\n",
    ]) {
      XCTAssertNil(ThemeCatalog.side(ofThemeNamed: "Broken"))
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "Workroom Light"), .light)
    }
  }

  /// Run `body` with the user theme directory pointed at a fresh temp dir holding `files`, never the
  /// developer's real `~/.config/ghostty/themes`.
  private func withUserThemes(_ files: [String: String], _ body: () throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-user-themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, contents) in files {
      try contents.write(
        to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try ThemeCatalog.withUserThemeDirectory(dir.path, body)
  }

  // MARK: families

  func testWorkroomFamilyIsFirst() {
    XCTAssertEqual(ThemeCatalog.families.first?.name, ThemeCatalog.defaultFamilyName)
  }

  /// 4: family names are unique. `ThemeFamily.id` IS `name`, and `ThemePicker` uses it as the
  /// `ForEach` id — duplicates are a SwiftUI identity bug, not a cosmetic one.
  func testFamilyNamesAreUnique() {
    let names = ThemeCatalog.families.map(\.name)
    XCTAssertEqual(
      names.count, Set(names).count,
      "duplicate family names: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)"
    )
  }

  /// 6: `Workroom` pinned first, everything else A→Z.
  ///
  /// Non-vacuous because `families` is an authored literal, not a `sorted(...)` result — appending a
  /// family in the wrong place fails here. The comparator is deliberately locale-independent;
  /// `localizedStandardCompare` would make the picker's order vary by system language.
  func testFamiliesAreAlphabeticalAfterTheDefault() {
    let rest = ThemeCatalog.families.dropFirst().map(\.name)
    let sorted = rest.sorted {
      $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending
    }
    XCTAssertEqual(rest, sorted, "the families literal is not in Workroom-then-A→Z order")
  }
}
