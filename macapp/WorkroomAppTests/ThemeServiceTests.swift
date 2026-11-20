import AppKit
import CryptoKit
import Defaults
import DesignSystem
import XCTest

@testable import Workroom

/// The theming engine at the `ThemeService` seam (issues #36, #733): settings in, the active theme's
/// name, the generated ghostty config and the stored settings out. Every resolution runs with the user
/// theme directory pointed at an empty temp dir, never the developer's real `~/.config/ghostty/themes`.
/// `Defaults` here is the per-process test suite (`UserDefaults.app`), never the developer's domain.
@MainActor
final class ThemeServiceTests: XCTestCase {
  // Save/restore the theme Defaults each test mutates, so tests don't leak into each other.
  private var savedLight: String!
  private var savedDark: String!
  private var savedAppearance: AppearanceMode!
  private var userThemeDir: URL!

  override func setUp() async throws {
    try await super.setUp()
    savedLight = Defaults[.lightTheme]
    savedDark = Defaults[.darkTheme]
    savedAppearance = Defaults[.appearance]
    userThemeDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("workroom-user-themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: userThemeDir, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    Defaults[.lightTheme] = savedLight
    Defaults[.darkTheme] = savedDark
    Defaults[.appearance] = savedAppearance
    for key in Self.oldKeys { UserDefaults.app.removeObject(forKey: key) }
    try? FileManager.default.removeItem(at: userThemeDir)
    try await super.tearDown()
  }

  /// Run `body` with the user theme directory at this test's own temp dir.
  private func withUserThemes<T>(_ body: () throws -> T) rethrows -> T {
    try ThemeCatalog.withUserThemeDirectory(userThemeDir.path, body)
  }

  private func writeUserTheme(_ name: String, background: String) throws {
    try "background = \(background)\nforeground = #808080\n".write(
      to: userThemeDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  // MARK: resolution (#733)

  func testEachForcedAppearanceResolvesToItsOwnSetting() {
    Defaults[.lightTheme] = "Catppuccin Latte"
    Defaults[.darkTheme] = "Nord"
    withUserThemes {
      // A forced appearance ignores the system's.
      for systemIsDark in [false, true] {
        XCTAssertEqual(
          ThemeService.activeThemeName(appearance: .light, systemIsDark: systemIsDark),
          "Catppuccin Latte")
        XCTAssertEqual(
          ThemeService.activeThemeName(appearance: .dark, systemIsDark: systemIsDark), "Nord")
      }
    }
  }

  func testSystemAppearanceFollowsTheEffectiveAppearance() {
    Defaults[.lightTheme] = "Catppuccin Latte"
    Defaults[.darkTheme] = "Nord"
    withUserThemes {
      XCTAssertEqual(
        ThemeService.activeThemeName(appearance: .system, systemIsDark: false), "Catppuccin Latte")
      XCTAssertEqual(ThemeService.activeThemeName(appearance: .system, systemIsDark: true), "Nord")
    }
  }

  /// A missing light theme falls back to Workroom Light, and the dark theme is left alone.
  func testAMissingLightThemeFallsBackOnItsOwn() {
    Defaults[.lightTheme] = "Does Not Exist"
    Defaults[.darkTheme] = "Nord"
    withUserThemes {
      XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Workroom Light")
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Nord")
    }
  }

  /// A missing dark theme falls back to Workroom, and the light theme is left alone.
  func testAMissingDarkThemeFallsBackOnItsOwn() {
    Defaults[.lightTheme] = "Catppuccin Latte"
    Defaults[.darkTheme] = "Does Not Exist"
    withUserThemes {
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Workroom")
      XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Catppuccin Latte")
    }
  }

  /// A theme on the wrong side falls back: a light theme in the dark setting, a dark one in the light.
  func testAThemeOnTheWrongSideFallsBack() {
    Defaults[.lightTheme] = "Nord"
    Defaults[.darkTheme] = "Catppuccin Latte"
    withUserThemes {
      XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Workroom Light")
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Workroom")
    }
  }

  /// A user's file that replaces a bundled theme and puts it on the other side makes that side fall
  /// back; a user's own theme on the right side is used.
  func testAUserFileDecidesItsThemesSide() throws {
    try writeUserTheme("Nord", background: "#fafafa")
    try writeUserTheme("My Paper", background: "#f4f1e8")
    Defaults[.lightTheme] = "My Paper"
    Defaults[.darkTheme] = "Nord"
    withUserThemes {
      XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "My Paper")
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Workroom")
    }
  }

  /// A chosen user theme whose file is deleted, or stops parsing, falls back to Workroom's theme for
  /// that side, and the other side's chosen user theme is untouched (#737).
  func testAChosenUserThemeThatGoesAwayFallsBackOnItsOwnSide() throws {
    try writeUserTheme("My Paper", background: "#f4f1e8")
    try writeUserTheme("My Night", background: "#101418")
    Defaults[.lightTheme] = "My Paper"
    Defaults[.darkTheme] = "My Night"
    try withUserThemes {
      XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "My Paper")
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "My Night")

      try FileManager.default.removeItem(at: userThemeDir.appendingPathComponent("My Paper"))
      XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Workroom Light")
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "My Night")

      try "garbage\n".write(
        to: userThemeDir.appendingPathComponent("My Night"), atomically: true, encoding: .utf8)
      XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Workroom")
      XCTAssertEqual(Defaults[.lightTheme], "My Paper", "a fallback rewrote the setting")
      XCTAssertEqual(Defaults[.darkTheme], "My Night", "a fallback rewrote the setting")
    }
  }

  /// The fallback is resolution only: the stored setting is kept, so a user theme file that is missing
  /// for a while comes back when it does.
  func testFallingBackLeavesTheSettingAlone() {
    Defaults[.lightTheme] = "Does Not Exist"
    withUserThemes {
      _ = ThemeService.activeThemeName(isDark: false)
      ThemeService.shared.applyActiveTheme()
    }
    XCTAssertEqual(Defaults[.lightTheme], "Does Not Exist")
  }

  // MARK: generated config

  /// The generated ghostty config names the active theme, on one `theme =` line.
  func testTheGeneratedConfigNamesTheActiveTheme() throws {
    Defaults[.lightTheme] = "Catppuccin Latte"
    Defaults[.darkTheme] = "Nord"
    for (isDark, expected) in [(true, "Nord"), (false, "Catppuccin Latte")] {
      try withUserThemes {
        XCTAssertTrue(GhosttyApp.shared.writeThemeConfig(dark: isDark))
        let conf = try String(contentsOf: GhosttyApp.shared.themeConfigURL, encoding: .utf8)
        let themeLines = conf.split(separator: "\n").filter { $0.hasPrefix("theme") }
        XCTAssertEqual(themeLines, ["theme = \"\(expected)\""])
      }
    }
  }

  // MARK: choosing a family

  /// Choosing a family sets both settings, in one apply.
  func testChoosingAFamilySetsBothThemesInOneApply() throws {
    Defaults[.lightTheme] = "Nord Light"
    Defaults[.darkTheme] = "Nord"
    let family = try XCTUnwrap(ThemeCatalog.family(named: "Catppuccin"))
    let before = ThemeService.shared.generation
    withUserThemes { ThemeService.shared.applyFamily(family) }
    XCTAssertEqual(Defaults[.lightTheme], "Catppuccin Latte")
    XCTAssertEqual(Defaults[.darkTheme], "Catppuccin Mocha")
    XCTAssertEqual(ThemeService.shared.generation, before &+ 1, "choosing a family applied twice")
  }

  // MARK: choosing one side (#735)

  /// The `theme =` line of the generated config, as the app last wrote it.
  private func generatedConfigTheme() throws -> String? {
    let conf = try String(contentsOf: GhosttyApp.shared.themeConfigURL, encoding: .utf8)
    return conf.split(separator: "\n").first { $0.hasPrefix("theme") }.map(String.init)
  }

  /// Choosing the theme for the side that's showing saves it and repaints, once.
  func testChoosingTheShowingSidesThemeSavesItAndRepaints() throws {
    Defaults[.appearance] = .dark
    Defaults[.lightTheme] = "Catppuccin Latte"
    Defaults[.darkTheme] = "Catppuccin Mocha"
    try withUserThemes {
      let before = ThemeService.shared.generation
      ThemeService.shared.apply(theme: "Nord", for: .dark)
      XCTAssertEqual(Defaults[.darkTheme], "Nord")
      XCTAssertEqual(Defaults[.lightTheme], "Catppuccin Latte", "the other side changed")
      XCTAssertEqual(ThemeService.shared.generation, before &+ 1, "expected exactly one apply")
      XCTAssertEqual(try generatedConfigTheme(), "theme = \"Nord\"")
    }
  }

  /// Choosing the theme for the side that isn't showing saves it, and changes neither the screen nor
  /// the generated config: the appearance stays put while you browse the other side.
  func testChoosingTheHiddenSidesThemeSavesItWithoutRepainting() throws {
    Defaults[.lightTheme] = "Catppuccin Latte"
    Defaults[.darkTheme] = "Catppuccin Mocha"
    for (appearance, hidden, theme) in [
      (AppearanceMode.dark, ThemeSide.light, "Nord Light"), (.light, .dark, "Nord"),
    ] {
      Defaults[.appearance] = appearance
      try withUserThemes {
        ThemeService.shared.applyActiveTheme()
        let confBefore = try generatedConfigTheme()
        let before = ThemeService.shared.generation
        ThemeService.shared.apply(theme: theme, for: hidden)
        XCTAssertEqual(hidden == .light ? Defaults[.lightTheme] : Defaults[.darkTheme], theme)
        XCTAssertEqual(ThemeService.shared.generation, before, "the hidden side repainted")
        XCTAssertEqual(try generatedConfigTheme(), confBefore, "the generated config changed")
        XCTAssertEqual(Defaults[.appearance], appearance, "the appearance changed")
      }
    }
  }

  // MARK: upgrade (#733)

  /// The keys the single-family settings used. Raw, because their typed keys are gone.
  private static let oldKeys = ["themeFamily", "themePreference"]

  /// Clear the new keys, so `Defaults` reads their defaults, and write the old ones as an older build
  /// stored them: plain strings.
  private func storeOldSettings(family: String?, appearance: String?) {
    for key in ["lightTheme", "darkTheme", "appearance"] {
      UserDefaults.app.removeObject(forKey: key)
    }
    UserDefaults.app.set(family, forKey: "themeFamily")
    UserDefaults.app.set(appearance, forKey: "themePreference")
  }

  func testUpgradeCarriesTheFamilyAndAppearanceAcross() {
    storeOldSettings(family: "Catppuccin", appearance: "dark")
    ThemeService.upgradeThemeSettings(in: .app)
    XCTAssertEqual(Defaults[.lightTheme], "Catppuccin Latte")
    XCTAssertEqual(Defaults[.darkTheme], "Catppuccin Mocha")
    XCTAssertEqual(Defaults[.appearance], .dark)
    for key in Self.oldKeys {
      XCTAssertNil(UserDefaults.app.object(forKey: key), "\(key) survived the upgrade")
    }
  }

  func testUpgradeSendsAnUnknownFamilyToWorkroom() {
    storeOldSettings(family: "Retired Family", appearance: "light")
    ThemeService.upgradeThemeSettings(in: .app)
    XCTAssertEqual(Defaults[.lightTheme], "Workroom Light")
    XCTAssertEqual(Defaults[.darkTheme], "Workroom")
    XCTAssertEqual(Defaults[.appearance], .light)
    XCTAssertNil(UserDefaults.app.object(forKey: "themeFamily"))
  }

  /// Each old key upgrades on its own: someone who only ever changed the appearance keeps it.
  func testUpgradeCarriesAnAppearanceWithNoFamily() {
    storeOldSettings(family: nil, appearance: "light")
    ThemeService.upgradeThemeSettings(in: .app)
    XCTAssertEqual(Defaults[.appearance], .light)
    XCTAssertEqual(Defaults[.lightTheme], "Workroom Light")
    XCTAssertEqual(Defaults[.darkTheme], "Workroom")
    XCTAssertNil(UserDefaults.app.object(forKey: "themePreference"))
  }

  func testUpgradeCarriesAFamilyWithNoAppearance() {
    storeOldSettings(family: "Nord", appearance: nil)
    ThemeService.upgradeThemeSettings(in: .app)
    XCTAssertEqual(Defaults[.lightTheme], "Nord Light")
    XCTAssertEqual(Defaults[.darkTheme], "Nord")
    XCTAssertEqual(Defaults[.appearance], .system)
  }

  /// A fresh install gets Workroom's two themes and System.
  func testAFreshInstallGetsWorkroomAndSystem() {
    storeOldSettings(family: nil, appearance: nil)
    ThemeService.upgradeThemeSettings(in: .app)
    XCTAssertEqual(Defaults[.lightTheme], "Workroom Light")
    XCTAssertEqual(Defaults[.darkTheme], "Workroom")
    XCTAssertEqual(Defaults[.appearance], .system)
  }

  /// Running the upgrade again changes nothing: settings chosen since are kept.
  func testUpgradeRunsOnce() {
    storeOldSettings(family: "Catppuccin", appearance: "dark")
    ThemeService.upgradeThemeSettings(in: .app)
    Defaults[.darkTheme] = "Nord"
    ThemeService.upgradeThemeSettings(in: .app)
    XCTAssertEqual(Defaults[.darkTheme], "Nord")
    XCTAssertEqual(Defaults[.lightTheme], "Catppuccin Latte")
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
      names.filter { ThemeCatalog.parseThemeFile(atPath: dir + "/" + $0, name: $0) != nil })
  }

  /// 1 + 2: every bundled theme the catalog lists resolves to a real bundled file, AND that file
  /// carries a complete 16-colour palette.
  ///
  /// The palette half is not belt-and-braces. `parseThemeFile` returns non-nil as soon as it has a
  /// background and a foreground, while `ThemeTokens` reads the palette for the accent
  /// (`p(4) ?? .controlAccentColor`), the diff colours and all 14 syntax categories — so a truncated
  /// file resolves fine and then silently paints the whole chrome with macOS system colours.
  func testEveryBundledThemeResolvesToACompleteBundledFile() throws {
    let dir = try bundledThemeDir()
    for theme in ThemeCatalog.bundledThemes {
      let preview = ThemeCatalog.parseThemeFile(atPath: dir + "/" + theme.name, name: theme.name)
      XCTAssertNotNil(preview, "'\(theme.name)' is not a bundled theme file")
      XCTAssertEqual(
        preview?.palette.count, 16,
        "'\(theme.name)' has an incomplete palette, so the chrome would fall back to system "
          + "colours while the terminal renders correctly")
    }
  }

  /// 3: every bundled theme's fixed side matches its background (#733), by the same
  /// `perceivedBrightness` test that decides the interface's colour scheme.
  ///
  /// It matters because `ThemeTokens` derives `colorScheme` from the theme's own background, and
  /// `SwitcherMark.tileColor` picks which direction to walk its brightness ladder from that — so a
  /// light theme listed as dark would render in dark mode and search the wrong way for legible mark
  /// tiles. Families are checked against these sides in `ThemeCatalogTests`.
  func testEveryBundledThemesSideMatchesItsBackground() throws {
    let dir = try bundledThemeDir()
    for theme in ThemeCatalog.bundledThemes {
      guard
        let preview = ThemeCatalog.parseThemeFile(
          atPath: dir + "/" + theme.name, name: theme.name)
      else {
        XCTFail("'\(theme.name)' must resolve before its side can be checked")
        continue
      }
      let brightness = ThemeTokens.perceivedBrightness(of: preview.background)
      switch theme.side {
      case .dark:
        XCTAssertLessThanOrEqual(
          brightness, 0.5, "'\(theme.name)' is listed as dark but has a light background")
      case .light:
        XCTAssertGreaterThan(
          brightness, 0.5, "'\(theme.name)' is listed as light but has a dark background")
      }
    }
  }

  /// 5: the catalog and the themes dir are in exact correspondence — compared as **sets**, not by
  /// count, with each theme listed once (`ThemeCatalogTests` pins the "once").
  ///
  /// Consequence worth knowing: shipping a theme file without listing it in
  /// `ThemeCatalog.bundledThemes` fails this test.
  func testTheCatalogAndBundledThemesAreInExactCorrespondence() throws {
    let listed = Set(ThemeCatalog.bundledThemes.map(\.name))
    let onDisk = try parseableBundledThemeNames()

    XCTAssertEqual(listed.subtracting(onDisk), [], "listed themes with no bundled file")
    XCTAssertEqual(onDisk.subtracting(listed), [], "bundled theme files the catalog doesn't list")
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
    let name = try XCTUnwrap(ThemeCatalog.families.first?.dark)
    let userDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("workroom-theme-override-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: userDir) }

    ThemeCatalog.resetPreviewCacheForTesting()
    // Warm the cache from the bundle first — that is the state the hazard needs.
    let bundled = try XCTUnwrap(ThemeService.themePreview(named: name))

    let overridePath = userDir.appendingPathComponent(name).path
    try "background = #ff00ff\nforeground = #000000\n".write(
      toFile: overridePath, atomically: true, encoding: .utf8)
    // Parsed through the same code path as the assertion below, so this can't fail on NSColor
    // colour-space equality rather than on precedence.
    let expected = try XCTUnwrap(
      ThemeCatalog.parseThemeFile(atPath: overridePath, name: name))
    XCTAssertNotEqual(
      expected.background, bundled.background, "the fixture must differ from the bundled theme")

    try ThemeCatalog.withUserThemeDirectory(userDir.path) {
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

  // MARK: dark/light quick toggle (issue #57)

  func testToggledLightDarkFlipsForcedModes() {
    XCTAssertEqual(AppearanceMode.light.toggledLightDark, .dark)
    XCTAssertEqual(AppearanceMode.dark.toggledLightDark, .light)
  }

  func testToggledLightDarkFromSystemIsAlwaysForced() {
    // From System the toggle resolves the live appearance and lands on a forced mode — never
    // `.system` — so repeat presses flip cleanly between light and dark.
    XCTAssertNotEqual(AppearanceMode.system.toggledLightDark, .system)
  }

  // MARK: observer ownership (WORKROOM-3R)

  /// The OS-appearance `DistributedNotificationCenter` observer must be owned by `ThemeService`
  /// (one process-wide instance) and NOT re-added to `TerminalPanes` (one per window) — a
  /// per-window observer is exactly the N-observers-N-sweeps regression this diff fixes (a single
  /// flip would fire the chokepoint N times, each already sweeping all N windows). A behavioural
  /// assertion would need a real DistributedNotificationCenter round-trip through distnoted, which
  /// is flaky in a test host; the declaration is the only place this is reliably observable — same
  /// reasoning as `TerminalPanesTests.testIsDirectoryTitleDefaultsToTheCachedHomeDirectory`.
  func testAppearanceObserverIsOwnedByThemeServiceNotTerminalPanes() throws {
    let coreDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // WorkroomAppTests
      .deletingLastPathComponent()  // macapp
      .appendingPathComponent("WorkroomApp/Core")
    let themeService = try String(
      contentsOf: coreDir.appendingPathComponent("AppShell/ThemeService.swift"), encoding: .utf8)
    let terminalSessions = try String(
      contentsOf: coreDir.appendingPathComponent("Terminal/TerminalPanes.swift"),
      encoding: .utf8)

    XCTAssertTrue(
      themeService.contains("AppleInterfaceThemeChangedNotification"),
      "ThemeService must own the OS-appearance observer")
    XCTAssertFalse(
      terminalSessions.contains("AppleInterfaceThemeChangedNotification"),
      "TerminalPanes must not re-add a per-window observer — that reopens WORKROOM-3R's "
        + "N-observers-N-sweeps stall")
  }
}
