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

  func testEveryBundledFamilyIsPairComplete() {
    // Issue #36: every theme supports dark AND light — both variant names must be non-empty and
    // distinct (a family is never a single-variant orphan).
    for family in ThemeCatalog.families {
      XCTAssertFalse(family.dark.isEmpty, "\(family.name) missing dark variant")
      XCTAssertFalse(family.light.isEmpty, "\(family.name) missing light variant")
      XCTAssertNotEqual(family.dark, family.light, "\(family.name) dark == light")
    }
  }

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
