import AppKit
import CryptoKit
import Defaults
import XCTest

@testable import Workroom

/// Pure-logic tests for the theming engine (issue #36): the ghostty theme-file parser, name
/// sanitisation, and family/override resolution. Filesystem- and UI-free — `activeThemeName`
/// resolves names from the family table + `Defaults`, so it never touches the bundle.
@MainActor
final class ThemeServiceTests: XCTestCase {
  // Save/restore the theme Defaults each test mutates, so tests don't leak into each other or the
  // running app's prefs.
  private var savedFamily: String!
  private var savedAppearance: ThemePreference!

  override func setUp() {
    savedFamily = Defaults[.themeFamily]
    savedAppearance = Defaults[.theme]
  }

  override func tearDown() {
    Defaults[.themeFamily] = savedFamily
    Defaults[.theme] = savedAppearance
  }

  // MARK: parseHex

  func testParseHexWithAndWithoutHash() {
    let a = ThemeService.parseHex("#282a36")
    let b = ThemeService.parseHex("282a36")
    for c in [a, b] {
      let srgb = c?.usingColorSpace(.sRGB)
      XCTAssertEqual(srgb?.redComponent ?? -1, 0x28 / 255, accuracy: 0.001)
      XCTAssertEqual(srgb?.greenComponent ?? -1, 0x2a / 255, accuracy: 0.001)
      XCTAssertEqual(srgb?.blueComponent ?? -1, 0x36 / 255, accuracy: 0.001)
    }
  }

  func testParseHexRejectsBadInput() {
    XCTAssertNil(ThemeService.parseHex("#fff"))  // 3-char shorthand not supported by ghostty files
    XCTAssertNil(ThemeService.parseHex("#12345"))  // wrong length
    XCTAssertNil(ThemeService.parseHex("nothex"))
    XCTAssertNil(ThemeService.parseHex(""))
  }

  // MARK: parseThemeFile

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
    let preview = ThemeService.parseThemeFile(atPath: path, name: "T")
    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.palette.count, 16)
    XCTAssertEqual(
      preview?.background.usingColorSpace(.sRGB)?.blueComponent ?? -1, 0x1e / 255, accuracy: 0.001)
    XCTAssertEqual(
      preview?.palette[4].usingColorSpace(.sRGB)?.blueComponent ?? -1, 0x04 / 255, accuracy: 0.001)
  }

  func testParseMissingBackgroundReturnsNil() {
    let path = writeTheme("foreground = #ffffff\npalette = 0=#000000")
    XCTAssertNil(ThemeService.parseThemeFile(atPath: path, name: "T"))
  }

  func testParseIgnoresForeignAndDashedLines() {
    // background-blur / foreground-... and comments must not be mistaken for background/foreground.
    let path = writeTheme(
      "# a comment\nbackground-blur = true\nbackground = #102030\nforeground = #fefefe\nrandom junk"
    )
    let preview = ThemeService.parseThemeFile(atPath: path, name: "T")
    XCTAssertEqual(
      preview?.background.usingColorSpace(.sRGB)?.redComponent ?? -1, 0x10 / 255, accuracy: 0.001)
    // No palette entries → empty palette, but still valid because bg + fg are present.
    XCTAssertEqual(preview?.palette.count, 0)
  }

  // MARK: sanitisation

  func testSanitizeStripsDangerousCharacters() {
    XCTAssertEqual(ThemeService.sanitizedThemeName("Foo\"\n\rBar"), "FooBar")
    XCTAssertEqual(ThemeService.sanitizedThemeName("../etc/passwd"), "..etcpasswd")
    XCTAssertEqual(ThemeService.sanitizedThemeName("Catppuccin Mocha"), "Catppuccin Mocha")
  }

  // MARK: family / override resolution

  func testActiveNamePicksFamilyVariantPerAppearance() {
    Defaults[.theme] = .dark
    Defaults[.themeFamily] = "Catppuccin"
    XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Catppuccin Mocha")
    XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Catppuccin Latte")
  }

  func testUnknownFamilyFallsBackToWorkroom() {
    Defaults[.themeFamily] = "DoesNotExist"
    XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Workroom")
    XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Workroom Light")
  }

  func testEveryBundledFamilyIsPairComplete() {
    // Issue #36: every theme supports dark AND light — both variant names must be non-empty and
    // distinct (a family is never a single-variant orphan).
    for family in ThemeService.families {
      XCTAssertFalse(family.dark.isEmpty, "\(family.name) missing dark variant")
      XCTAssertFalse(family.light.isEmpty, "\(family.name) missing light variant")
      XCTAssertNotEqual(family.dark, family.light, "\(family.name) dark == light")
    }
  }

  func testWorkroomFamilyIsFirst() {
    XCTAssertEqual(ThemeService.families.first?.name, ThemeService.defaultFamilyName)
  }

  // MARK: registry ↔ bundle integrity

  /// Every theme file the app ships, parsed straight out of the bundle.
  ///
  /// Read from `Bundle.main.resourceURL` and deliberately NOT through `ThemeService.themeDirectories()`,
  /// whose first entry is `~/.config/ghostty/themes` — a user override there would make these results
  /// depend on the machine running the suite. Same reasoning as `SwitcherThemeSweepTests`.
  private func bundledThemeDir() throws -> String {
    try XCTUnwrap(
      Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes").path,
      "the app bundle must carry its themes — the terminal can't start without them")
  }

  /// Filenames in the bundled themes dir that actually parse as themes. Filters out `LICENSE`,
  /// `SOURCE.md`, `CHECKSUMS` and any stray directory the folder reference copies in.
  private func parseableBundledThemeNames() throws -> Set<String> {
    let dir = try bundledThemeDir()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir)
    return Set(
      names.filter { ThemeService.parseThemeFile(atPath: dir + "/" + $0, name: $0) != nil })
  }

  /// 1 + 2: every declared variant resolves to a real bundled file, AND that file carries a complete
  /// 16-colour palette.
  ///
  /// The palette half is not belt-and-braces. `parseThemeFile` returns non-nil as soon as it has a
  /// background and a foreground, while `ThemeTokens` reads the palette for the accent
  /// (`p(4) ?? .controlAccentColor`), the diff colours and all 14 syntax categories — so a truncated
  /// file resolves fine and then silently paints the whole chrome with macOS system colours.
  func testEveryFamilyVariantResolvesToACompleteBundledTheme() throws {
    let dir = try bundledThemeDir()
    for family in ThemeService.families {
      for (role, name) in [("dark", family.dark), ("light", family.light)] {
        let preview = ThemeService.parseThemeFile(atPath: dir + "/" + name, name: name)
        XCTAssertNotNil(
          preview, "\(family.name): the \(role) variant '\(name)' is not a bundled theme file")
        XCTAssertEqual(
          preview?.palette.count, 16,
          "\(family.name): the \(role) variant '\(name)' has an incomplete palette, so the chrome "
            + "would fall back to system colours while the terminal renders correctly")
      }
    }
  }

  /// 3: the dark slot holds a dark theme and the light slot a light one.
  ///
  /// Scoped claim: this catches a pair whose two variants are **swapped between the slots**. It does
  /// NOT prove the two were designed as a pair. It matters because `ThemeTokens` derives
  /// `colorScheme` from the theme's own background, and `SwitcherMark.tileColor` picks which
  /// direction to walk its brightness ladder from that — so a swapped pair renders a light theme in
  /// dark mode and searches the wrong way for legible mark tiles.
  func testEveryFamilyVariantIsOnTheCorrectSideOfTheAppearance() throws {
    let dir = try bundledThemeDir()
    for family in ThemeService.families {
      guard
        let dark = ThemeService.parseThemeFile(atPath: dir + "/" + family.dark, name: family.dark),
        let light = ThemeService.parseThemeFile(
          atPath: dir + "/" + family.light, name: family.light)
      else {
        XCTFail("\(family.name): variants must resolve before orientation can be checked")
        continue
      }
      XCTAssertLessThanOrEqual(
        ThemeTokens.perceivedBrightness(of: dark.background), 0.5,
        "\(family.name): '\(family.dark)' sits in the dark slot but has a light background")
      XCTAssertGreaterThan(
        ThemeTokens.perceivedBrightness(of: light.background), 0.5,
        "\(family.name): '\(family.light)' sits in the light slot but has a dark background")
    }
  }

  /// 4: family names are unique. `ThemeFamily.id` IS `name`, and `ThemePicker` uses it as the
  /// `ForEach` id — duplicates are a SwiftUI identity bug, not a cosmetic one.
  func testFamilyNamesAreUnique() {
    let names = ThemeService.families.map(\.name)
    XCTAssertEqual(
      names.count, Set(names).count,
      "duplicate family names: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)"
    )
  }

  /// 5: the registry and the themes dir are in exact correspondence — compared as **sets**, not by
  /// count. A count check passes when two families share a variant and an unregistered file pads the
  /// total back to even, which is precisely the mistake it is supposed to catch.
  ///
  /// Consequence worth knowing: shipping a theme file without registering it here fails this test.
  func testRegistryAndBundledThemesAreInExactCorrespondence() throws {
    let declared = ThemeService.families.flatMap { [$0.dark, $0.light] }
    let onDisk = try parseableBundledThemeNames()

    XCTAssertEqual(
      Set(declared).subtracting(onDisk), [], "declared variants with no bundled file")
    XCTAssertEqual(
      onDisk.subtracting(Set(declared)), [], "bundled theme files no family references")
    XCTAssertEqual(
      declared.count, Set(declared).count,
      "two families share a variant file: \(Dictionary(grouping: declared, by: { $0 }).filter { $0.value.count > 1 }.keys)"
    )
    XCTAssertEqual(declared.count, ThemeService.families.count * 2)
  }

  /// 6: `Workroom` pinned first, everything else A→Z.
  ///
  /// Non-vacuous because `families` is an authored literal, not a `sorted(...)` result — appending a
  /// family in the wrong place fails here. The comparator is deliberately locale-independent;
  /// `localizedStandardCompare` would make the picker's order vary by system language.
  func testFamiliesAreAlphabeticalAfterTheDefault() {
    let rest = ThemeService.families.dropFirst().map(\.name)
    let sorted = rest.sorted {
      $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending
    }
    XCTAssertEqual(rest, sorted, "the families literal is not in Workroom-then-A→Z order")
  }

  /// 7: the shipped bytes are the vetted bytes. Structural tests cannot catch this — an upstream
  /// colour tweak stays palette-complete and sweeps clean — so `themes/CHECKSUMS` pins the files to
  /// the vendored upstream commit recorded in `themes/SOURCE.md`.
  func testBundledThemeChecksumsMatch() throws {
    let dir = try bundledThemeDir()
    let manifest = try XCTUnwrap(
      try? String(contentsOfFile: dir + "/CHECKSUMS", encoding: .utf8),
      "themes/CHECKSUMS must ship — it is what makes the vendored commit verifiable")

    var expected: [String: String] = [:]
    for line in manifest.split(separator: "\n") {
      // `shasum -a 256` format: "<64 hex>  <filename>" (two spaces, filename may contain spaces).
      let parts = line.components(separatedBy: "  ")
      guard parts.count >= 2, parts[0].count == 64 else { continue }
      expected[parts.dropFirst().joined(separator: "  ")] = parts[0].lowercased()
    }
    XCTAssertFalse(expected.isEmpty, "CHECKSUMS parsed to nothing — wrong format?")

    let onDisk = try parseableBundledThemeNames()
    XCTAssertEqual(
      Set(expected.keys), onDisk, "CHECKSUMS and the shipped theme files disagree on membership")

    for (name, want) in expected {
      guard let data = FileManager.default.contents(atPath: dir + "/" + name) else {
        XCTFail("\(name): listed in CHECKSUMS but unreadable")
        continue
      }
      XCTAssertEqual(
        Self.sha256Hex(data), want,
        "\(name): contents differ from the vendored upstream commit recorded in SOURCE.md")
    }
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: preview cache

  /// The bundled cache must never shadow a user's own theme file — asserted by actually writing one.
  ///
  /// This is the cache's one real hazard. Bundled files can't change while the app runs, so a cached
  /// entry can't go stale; a file the USER edits can, which is why `themePreview` reads their dir on
  /// every call and caches only the bundle. A regression that consulted the cache first would be
  /// invisible to any test that only inspects `themeDirectories()` — it would still report the user dir
  /// first while the lookup never reached it.
  ///
  /// The override lands in a temp dir via `withUserThemeDirectory`, so this never touches the
  /// developer's real `~/.config/ghostty/themes`.
  func testAUserOverrideBeatsAWarmBundledCache() throws {
    let name = try XCTUnwrap(ThemeService.families.first?.dark)
    let userDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("workroom-theme-override-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: userDir) }

    ThemeService.resetPreviewCacheForTesting()
    // Warm the cache from the bundle first — that is the state the hazard needs.
    let bundled = try XCTUnwrap(ThemeService.themePreview(named: name))

    let overridePath = userDir.appendingPathComponent(name).path
    try "background = #ff00ff\nforeground = #000000\n".write(
      toFile: overridePath, atomically: true, encoding: .utf8)
    // Parsed through the same code path as the assertion below, so this can't fail on NSColor
    // colour-space equality rather than on precedence.
    let expected = try XCTUnwrap(
      ThemeService.parseThemeFile(atPath: overridePath, name: name))
    XCTAssertNotEqual(
      expected.background, bundled.background, "the fixture must differ from the bundled theme")

    try ThemeService.withUserThemeDirectory(userDir.path) {
      let resolved = try XCTUnwrap(ThemeService.themePreview(named: name))
      XCTAssertEqual(
        resolved.background, expected.background,
        "the warm bundled cache shadowed the user's own theme file — a theme they edit would appear "
          + "not to change")
    }

    // And the bundled theme comes back once the override is gone, so the override can't have poisoned
    // the cache on its way through.
    XCTAssertEqual(ThemeService.themePreview(named: name)?.background, bundled.background)
  }

  /// The search order every other reader relies on. Kept as a separate, honest assertion now that
  /// `themePreview` resolves the two directories by name instead of by index.
  func testThemeDirectoriesReportTheUserDirFirst() {
    let dirs = ThemeService.themeDirectories()
    XCTAssertTrue(
      dirs.first?.hasSuffix("/.config/ghostty/themes") == true, "user dir must come first")
    XCTAssertEqual(dirs.count, 2, "user dir + bundled dir")
    XCTAssertEqual(dirs.last, ThemeService.bundledThemeDirectory())
  }

  func testResetPreviewCacheForTestingClearsIt() throws {
    let name = try XCTUnwrap(ThemeService.families.first?.dark)
    // Reset FIRST: the cache is a process-lifetime static, so without this the test silently inherits
    // whatever an earlier case in the same process left warm and proves nothing about a cold start.
    ThemeService.resetPreviewCacheForTesting()
    let cold = try XCTUnwrap(ThemeService.themePreview(named: name))
    ThemeService.resetPreviewCacheForTesting()
    // Same colours after a reset — the cache is an optimisation, never the source of truth, so a
    // repopulated entry must be indistinguishable from the one it replaced.
    let repopulated = try XCTUnwrap(ThemeService.themePreview(named: name))
    XCTAssertEqual(repopulated.background, cold.background)
    XCTAssertEqual(repopulated.palette, cold.palette)
  }

  // MARK: dark/light quick toggle (issue #57)

  func testToggledLightDarkFlipsForcedModes() {
    XCTAssertEqual(ThemePreference.light.toggledLightDark, .dark)
    XCTAssertEqual(ThemePreference.dark.toggledLightDark, .light)
  }

  func testToggledLightDarkFromSystemIsAlwaysForced() {
    // From System the toggle resolves the live appearance and lands on a forced mode — never
    // `.system` — so repeat presses flip cleanly between light and dark.
    XCTAssertNotEqual(ThemePreference.system.toggledLightDark, .system)
  }
}
