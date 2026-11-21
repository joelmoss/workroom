import AppKit
import Foundation
import Synchronization

/// Which appearance a theme belongs to, judged by its background: a light theme has a light
/// background, a dark theme a dark one (#733).
public enum ThemeSide: String, CaseIterable, Hashable, Sendable {
  case light
  case dark

  public init(isDark: Bool) { self = isDark ? .dark : .light }

  /// The side a background puts a theme on: the same `perceivedBrightness > 0.5` test that decides
  /// the interface's colour scheme (`ThemeTokens.colorScheme`), so a theme's side and the chrome it
  /// paints can never disagree.
  public init(background: NSColor) {
    self = ThemeTokens.perceivedBrightness(of: background) > 0.5 ? .light : .dark
  }
}

/// One theme the app bundles, with its side fixed by the catalog rather than worked out at runtime.
/// `ThemeServiceTests` checks every fixed side against the file's background.
public struct BundledTheme: Hashable, Sendable {
  public let name: String
  public let side: ThemeSide

  public init(name: String, side: ThemeSide) {
    self.name = name
    self.side = side
  }
}

/// One row of the Light or Dark list (#737): a bundled theme, or one of the user's own files in
/// `~/.config/ghostty/themes`, which the picker labels as theirs. A user file that replaces a bundled
/// theme is the user's.
public struct ListedTheme: Hashable, Sendable {
  public let name: String
  public let side: ThemeSide
  public let isUserTheme: Bool

  public init(name: String, side: ThemeSide, isUserTheme: Bool) {
    self.name = name
    self.side = side
    self.isUserTheme = isUserTheme
  }
}

/// A **theme family**: a curated preset pairing one light theme with one dark theme. Choosing it sets
/// both the light theme and the dark theme, and either can then be changed on its own (#733).
public struct ThemeFamily: Identifiable, Hashable, Sendable {
  public let name: String
  public let dark: String  // the dark theme's file name (resolved by ghostty + parsed for chrome)
  public let light: String  // the light theme's file name

  public var id: String { name }

  public func theme(for side: ThemeSide) -> String { side == .dark ? dark : light }

  public init(name: String, dark: String, light: String) {
    self.name = name
    self.dark = dark
    self.light = light
  }
}

/// A parsed ghostty theme file: the colours we need for chrome tokens and picker swatches.
/// (The *terminal* gets these straight from ghostty's native `theme=` resolution; we parse the same
/// file so the chrome derives from identical colours — see `GhosttyApp.writeThemeConfig`.)
public struct ThemePreview: Identifiable, Hashable, Sendable {
  public let name: String
  public let background: NSColor
  public let foreground: NSColor
  public let palette: [NSColor]
  public var id: String { name }

  public init(name: String, background: NSColor, foreground: NSColor, palette: [NSColor]) {
    self.name = name
    self.background = background
    self.foreground = foreground
    self.palette = palette
  }
}

/// The bundled theme families and the ghostty theme files behind them: resolving a name to its
/// parsed colours (the user's `~/.config/ghostty/themes` first, uncached, then the bundled
/// directory, cached), and the parser itself. Pure of app state: which family is active, and where
/// the app bundles its themes, are `ThemeService`'s to say.
public enum ThemeCatalog {
  public static let defaultFamilyName = "Workroom"

  /// The curated bundled families. Each theme name is a file in `Resources/ghostty/themes` (and
  /// resolvable by ghostty). Most bundled themes belong to no family.
  ///
  /// **Order is authored, not computed:** `Workroom` is pinned first, then A→Z. A `sorted(...)` call
  /// here would make `testFamiliesAreAlphabeticalAfterTheDefault` vacuous — it would assert a
  /// property the initializer had just imposed — so the list is typed in its final display order and
  /// the test compares it against `compare(options: [.caseInsensitive, .numeric])`. That comparator
  /// is deliberately NOT `localizedStandardCompare`: a locale-sensitive collation would make the
  /// picker's row order vary by system language and the assertion unpinnable.
  ///
  /// **What makes a family** (see `Resources/ghostty/themes/SOURCE.md`): an upstream light theme and
  /// dark theme designed as a pair, checked by hand, both bundled. Which themes are bundled at all is
  /// SOURCE.md's inclusion rules (#736): the contrast floors, no duplicate palettes and no other
  /// terminal product's brand.
  ///
  /// Each family's light theme must be a bundled light theme and its dark theme a bundled dark theme
  /// (`bundledThemes`, in `BundledThemes.generated.swift`); `ThemeCatalogTests` pins that.
  public static let families: [ThemeFamily] = [
    ThemeFamily(name: "Workroom", dark: "Workroom", light: "Workroom Light"),
    ThemeFamily(name: "3024", dark: "3024 Night", light: "3024 Day"),
    ThemeFamily(name: "Adwaita", dark: "Adwaita Dark", light: "Adwaita"),
    ThemeFamily(name: "Aizen", dark: "Aizen Dark", light: "Aizen Light"),
    ThemeFamily(name: "AlxPro", dark: "AlxPro Dark", light: "AlxPro Light"),
    ThemeFamily(name: "Analyzed", dark: "Analyzed Dark", light: "Analyzed Light"),
    ThemeFamily(
      name: "Apple System Colors", dark: "Apple System Colors", light: "Apple System Colors Light"),
    ThemeFamily(name: "Atom One", dark: "Atom One Dark", light: "Atom One Light"),
    ThemeFamily(name: "Ayu", dark: "Ayu Mirage", light: "Ayu Light"),
    ThemeFamily(name: "Bauhaus", dark: "Bauhaus Dark", light: "Bauhaus Light"),
    ThemeFamily(name: "Belafonte", dark: "Belafonte Night", light: "Belafonte Day"),
    ThemeFamily(name: "Bluloco", dark: "Bluloco Dark", light: "Bluloco Light"),
    ThemeFamily(name: "Callie", dark: "Callie", light: "Callie Light"),
    ThemeFamily(name: "Catppuccin", dark: "Catppuccin Mocha", light: "Catppuccin Latte"),
    ThemeFamily(name: "Claude", dark: "Claude Dark", light: "Claude Light"),
    ThemeFamily(name: "Clear", dark: "Clear Dark", light: "Clear Light"),
    ThemeFamily(name: "Code 2026", dark: "Code 2026 Dark", light: "Code 2026 Light"),
    ThemeFamily(name: "Cursor", dark: "Cursor Dark", light: "Cursor Light"),
    ThemeFamily(name: "datum", dark: "datum (dark)", light: "datum (light)"),
    ThemeFamily(name: "Duskfox", dark: "Duskfox", light: "Dawnfox"),
    ThemeFamily(
      name: "Electron Highlighter", dark: "Electron Highlighter", light: "Electron Highlighter Day"),
    ThemeFamily(name: "Everforest", dark: "Everforest Dark Hard", light: "Everforest Light Med"),
    ThemeFamily(
      name: "Everforest Hard", dark: "Everforest Dark Hard", light: "Everforest Light Hard"),
    ThemeFamily(name: "Farmhouse", dark: "Farmhouse Dark", light: "Farmhouse Light"),
    ThemeFamily(name: "Flexoki", dark: "Flexoki Dark", light: "Flexoki Light"),
    ThemeFamily(name: "GitHub", dark: "GitHub Dark", light: "GitHub Light Default"),
    ThemeFamily(
      name: "GitHub Colorblind", dark: "GitHub Dark Colorblind", light: "GitHub Light Colorblind"),
    ThemeFamily(
      name: "GitHub High Contrast", dark: "GitHub Dark High Contrast",
      light: "GitHub Light High Contrast"),
    ThemeFamily(name: "GitLab", dark: "GitLab Dark", light: "GitLab Light"),
    ThemeFamily(name: "Grok", dark: "Grok Night", light: "Grok Day"),
    ThemeFamily(name: "Gruvbox", dark: "Gruvbox Dark", light: "Gruvbox Light"),
    ThemeFamily(name: "Gruvbox Hard", dark: "Gruvbox Dark Hard", light: "Gruvbox Light Hard"),
    ThemeFamily(
      name: "Gruvbox Material", dark: "Gruvbox Material Dark", light: "Gruvbox Material Light"),
    ThemeFamily(name: "Havn", dark: "Havn Skumring", light: "Havn Daggry"),
    ThemeFamily(name: "Iceberg", dark: "Iceberg Dark", light: "Iceberg Light"),
    ThemeFamily(name: "iglass", dark: "iglass Dark", light: "iglass Light"),
    ThemeFamily(name: "Kanagawa", dark: "Kanagawa Wave", light: "Kanagawa Lotus"),
    ThemeFamily(name: "Kanso", dark: "Kanso Zen", light: "Kanso Pearl"),
    ThemeFamily(name: "Karasu", dark: "Karasu Night", light: "Karasu Snow"),
    ThemeFamily(name: "Karma", dark: "Karma Dark", light: "Karma Light"),
    ThemeFamily(name: "Karma Dimmed", dark: "Karma Dark Dimmed", light: "Karma Light Dimmed"),
    ThemeFamily(name: "Karma High Contrast", dark: "Karma Dark HC", light: "Karma Light HC"),
    ThemeFamily(name: "Lit Cell", dark: "Lit Cell", light: "Lit Cell Light"),
    ThemeFamily(name: "Lumina Aurora", dark: "Lumina Aurora Dark", light: "Lumina Aurora Light"),
    ThemeFamily(name: "Lumina Canopy", dark: "Lumina Canopy Dark", light: "Lumina Canopy Light"),
    ThemeFamily(
      name: "Lumina Cherenkov", dark: "Lumina Cherenkov Dark", light: "Lumina Cherenkov Light"),
    ThemeFamily(name: "Lumina Dusk", dark: "Lumina Dusk Dark", light: "Lumina Dusk Light"),
    ThemeFamily(name: "Lumina Ember", dark: "Lumina Ember Dark", light: "Lumina Ember Light"),
    ThemeFamily(
      name: "Lumina Espresso", dark: "Lumina Espresso Dark", light: "Lumina Espresso Light"),
    ThemeFamily(name: "Lumina Harbor", dark: "Lumina Harbor Dark", light: "Lumina Harbor Light"),
    ThemeFamily(name: "Lumina Lagoon", dark: "Lumina Lagoon Dark", light: "Lumina Lagoon Light"),
    ThemeFamily(name: "Lumina Nebula", dark: "Lumina Nebula Dark", light: "Lumina Nebula Light"),
    ThemeFamily(name: "Lumina Olive", dark: "Lumina Olive Dark", light: "Lumina Olive Light"),
    ThemeFamily(name: "Lumina Oxblood", dark: "Lumina Oxblood Dark", light: "Lumina Oxblood Light"),
    ThemeFamily(
      name: "Lumina Parchment", dark: "Lumina Parchment Dark", light: "Lumina Parchment Light"),
    ThemeFamily(name: "Lumina Polaire", dark: "Lumina Polaire Dark", light: "Lumina Polaire Light"),
    ThemeFamily(name: "Lumina Quartz", dark: "Lumina Quartz Dark", light: "Lumina Quartz Light"),
    ThemeFamily(
      name: "Lumina Rayleigh", dark: "Lumina Rayleigh Dark", light: "Lumina Rayleigh Light"),
    ThemeFamily(name: "Lumina Vitrail", dark: "Lumina Vitrail Dark", light: "Lumina Vitrail Light"),
    ThemeFamily(name: "Material", dark: "Material Dark", light: "Material"),
    ThemeFamily(name: "Melange", dark: "Melange Dark", light: "Melange Light"),
    ThemeFamily(name: "Modus", dark: "Modus Vivendi", light: "Modus Operandi"),
    ThemeFamily(
      name: "Modus Deuteranopia", dark: "Modus Vivendi Deuteranopia",
      light: "Modus Operandi Deuteranopia"),
    ThemeFamily(name: "Modus Tinted", dark: "Modus Vivendi Tinted", light: "Modus Operandi Tinted"),
    ThemeFamily(
      name: "Modus Tritanopia", dark: "Modus Vivendi Tritanopia", light: "Modus Operandi Tritanopia"
    ),
    ThemeFamily(name: "Monokai Pro", dark: "Monokai Pro", light: "Monokai Pro Light"),
    ThemeFamily(name: "Monospace", dark: "Monospace Dark", light: "Monospace Light"),
    ThemeFamily(name: "Neobones", dark: "Neobones Dark", light: "Neobones Light"),
    ThemeFamily(name: "Night Owl", dark: "Night Owl", light: "Light Owl"),
    ThemeFamily(name: "Nightfox", dark: "Nightfox", light: "Dayfox"),
    ThemeFamily(name: "No Clown Fiesta", dark: "No Clown Fiesta", light: "No Clown Fiesta Light"),
    ThemeFamily(name: "Nord", dark: "Nord", light: "Nord Light"),
    ThemeFamily(name: "Nvim", dark: "Nvim Dark", light: "Nvim Light"),
    ThemeFamily(name: "One Double", dark: "One Double Dark", light: "One Double Light"),
    ThemeFamily(name: "One Half", dark: "One Half Dark", light: "One Half Light"),
    ThemeFamily(name: "Onenord", dark: "Onenord", light: "Onenord Light"),
    ThemeFamily(name: "OpenCode", dark: "OpenCode Dark", light: "OpenCode Light"),
    ThemeFamily(name: "Patina", dark: "Patina Dark", light: "Patina Light"),
    ThemeFamily(name: "Pencil", dark: "Pencil Dark", light: "Pencil Light"),
    ThemeFamily(name: "Pierre", dark: "Pierre Dark", light: "Pierre Light"),
    ThemeFamily(name: "Pyrokai", dark: "Pyrokai", light: "Pyrokai Light"),
    ThemeFamily(name: "Raycast", dark: "Raycast Dark", light: "Raycast Light"),
    ThemeFamily(name: "Rosé Pine", dark: "Rose Pine", light: "Rose Pine Dawn"),
    ThemeFamily(name: "Selenized", dark: "Selenized Dark", light: "Selenized Light"),
    ThemeFamily(name: "Seoulbones", dark: "Seoulbones Dark", light: "Seoulbones Light"),
    ThemeFamily(
      name: "Sequoia Monochrome", dark: "Sequoia Monochrome Dark", light: "Sequoia Monochrome Light"
    ),
    ThemeFamily(
      name: "Sequoia Moonlight", dark: "Sequoia Moonlight Dark", light: "Sequoia Moonlight Light"),
    ThemeFamily(name: "Sequoia Retro", dark: "Sequoia Retro Dark", light: "Sequoia Retro Light"),
    ThemeFamily(name: "Serendipity", dark: "Serendipity Midnight", light: "Serendipity Morning"),
    ThemeFamily(name: "Solarized", dark: "iTerm2 Solarized Dark", light: "iTerm2 Solarized Light"),
    ThemeFamily(name: "Tailwind", dark: "Tailwind Dark", light: "Tailwind Light"),
    ThemeFamily(
      name: "Tinacious Design", dark: "Tinacious Design Dark", light: "Tinacious Design Light"),
    ThemeFamily(name: "Token", dark: "Token Dark", light: "Token Light"),
    ThemeFamily(name: "Tokyo Night", dark: "TokyoNight Night", light: "TokyoNight Day"),
    ThemeFamily(name: "Tomorrow", dark: "Tomorrow Night", light: "Tomorrow"),
    ThemeFamily(name: "Vercel", dark: "Vercel", light: "Vercel Light"),
    ThemeFamily(name: "Warm Burnout", dark: "Warm Burnout Dark", light: "Warm Burnout Light"),
    ThemeFamily(name: "Wild Charm", dark: "Wild Charm Dark", light: "Wild Charm Light"),
    ThemeFamily(name: "Xcode", dark: "Xcode Dark", light: "Xcode Light"),
    ThemeFamily(name: "Xcode High Contrast", dark: "Xcode Dark hc", light: "Xcode Light hc"),
    ThemeFamily(name: "Zacess", dark: "Zacess Dark", light: "Zacess Light"),
    ThemeFamily(
      name: "Zacess Deep Contrast", dark: "Zacess Deep Contrast Dark",
      light: "Zacess Deep Contrast Light"),
    ThemeFamily(
      name: "Zacess High Contrast", dark: "Zacess High Contrast Dark",
      light: "Zacess High Contrast Light"),
    ThemeFamily(name: "Zacess Warm", dark: "Zacess Warm Dark", light: "Zacess Warm Light"),
    ThemeFamily(name: "Zenbones", dark: "Zenbones Dark", light: "Zenbones Light"),
    ThemeFamily(name: "Zenwritten", dark: "Zenwritten Dark", light: "Zenwritten Light"),
  ]

  public static func family(named name: String) -> ThemeFamily? {
    families.first { $0.name == name }
  }

  /// The default family, Workroom: every side falls back to its theme, and a fresh install starts on
  /// it.
  public static var defaultFamily: ThemeFamily { family(named: defaultFamilyName)! }

  /// What a light and dark pair is called when no family pairs them.
  public static let customFamilyLabel = "Custom"

  /// The family that pairs exactly this light theme with this dark theme, matched by name, or nil when
  /// none does. By name on purpose: a user file that replaces a family member keeps the family's name.
  public static func family(light: String, dark: String) -> ThemeFamily? {
    families.first { $0.light == light && $0.dark == dark }
  }

  /// The family's name for this pair, or "Custom" when no family pairs them.
  public static func familyLabel(light: String, dark: String) -> String {
    family(light: light, dark: dark)?.name ?? customFamilyLabel
  }

  /// The pair as Settings shows it: the family's name, or "Custom" with both theme names, light first.
  public static func familySummary(light: String, dark: String) -> String {
    family(light: light, dark: dark)?.name ?? "\(customFamilyLabel): \(light) / \(dark)"
  }

  private static let bundledSides: [String: ThemeSide] = Dictionary(
    bundledThemes.map { ($0.name, $0.side) }, uniquingKeysWith: { first, _ in first })

  /// The side the theme called `name` is on, resolved the way ghostty resolves `theme =`: a file of
  /// that name in the user's theme directory first, classified by its background, then the bundled
  /// theme's fixed side. Nil when neither exists, when the user's file doesn't parse, and when ghostty
  /// would read the name as a light/dark pair (`isSingleThemeName`).
  ///
  /// A user file that doesn't parse gives no side even when a bundled theme shares its name: ghostty
  /// still loads the user's file for that name, so taking the bundled side would paint the chrome in
  /// the bundled colours over a terminal loading the broken file. With no side the setting falls back
  /// to Workroom or Workroom Light, which the terminal and the chrome both load (#737).
  public static func side(ofThemeNamed name: String, in userThemes: UserThemes) -> ThemeSide? {
    guard isSingleThemeName(name) else { return nil }
    switch userThemes.entry(named: name) {
    case .theme(let preview): return ThemeSide(background: preview.background)
    case .unusable: return nil
    case .absent: return bundledSides[name]
    }
  }

  /// `side(ofThemeNamed:in:)`, reading only the one file `name` names.
  public static func side(ofThemeNamed name: String) -> ThemeSide? {
    side(ofThemeNamed: name, in: .reading(named: name))
  }

  /// Whether ghostty reads `name`, written as `theme = "<name>"`, as one theme: its `Theme.parseCLI`
  /// reads any value holding a comma, `=` or colon as a light/dark pair. The bundled themes are
  /// vendored by the same rule (`Scripts/vendor-ghostty-themes.py`); a user file named otherwise is
  /// never listed and never resolves, so it never reaches the generated config.
  public static func isSingleThemeName(_ name: String) -> Bool {
    !name.contains { $0 == ":" || $0 == "," || $0 == "=" }
  }

  /// Strip anything that would break or inject into the generated `ghostty.conf` (the name is
  /// written as `theme = "<name>"`), and reject path separators so a crafted `~/.config` filename
  /// can't escape the themes dir.
  public static func sanitizedThemeName(_ name: String) -> String {
    name.filter { $0 != "\"" && $0 != "\n" && $0 != "\r" && $0 != "/" && $0 != "\\" }
  }

  /// Parsed previews for the **bundled** dir only, keyed by theme name.
  ///
  /// `ThemePicker` calls `themePreview` twice per row *inside the row body* (`ThemePicker.swift`),
  /// and every `FamilyRow` observes `ThemeService.shared` for `tokens` — so each ↑/↓, which applies a
  /// theme and replaces `tokens`, invalidates every instantiated row and sent all of them back to
  /// disk. With 58 families that is up to 116 synchronous file reads per keypress on the main actor,
  /// on top of the conf rewrite + engine reload the apply already does.
  ///
  /// Only the bundled dir is cached, and that is what makes the cache correct rather than merely
  /// fast: those files cannot change while the app is running, so an entry can never go stale.
  /// `~/.config` is re-read on every call (below) precisely so a user editing their own theme still
  /// sees it change.
  ///
  /// A `Mutex` rather than `@MainActor`: this package has no actor of its own, so `themePreview`
  /// stays callable from any isolation. The state lives inside the lock, so no access can skip it.
  private static let bundledPreviewCache = Mutex<[String: ThemePreview]>([:])

  /// Drop the bundled cache. Tests only — a process-lifetime static otherwise leaks state across
  /// test cases and makes the "a user override still wins" case impossible to isolate.
  public static func resetPreviewCacheForTesting() {
    bundledPreviewCache.withLock { $0.removeAll() }
  }

  /// Resolve one theme name to its parsed colours, with `~/.config` winning over bundled — the
  /// SAME precedence as ghostty's terminal resolution, so chrome and terminal never diverge for a
  /// user-overridden theme file.
  public static func themePreview(named name: String, bundledDirectory: String?) -> ThemePreview? {
    // The user's dir is checked first and NEVER cached, preserving both ghostty's precedence and the
    // ability to edit a theme live. Named directly rather than as `themeDirectories().first`: which
    // entry is user-writable (and therefore uncacheable) is the whole correctness argument for the
    // cache below, and an index into an array pins nothing — a third directory added at the front
    // would silently start being cached forever.
    themePreview(named: name, bundledDirectory: bundledDirectory, in: .reading(named: name))
  }

  /// `themePreview(named:bundledDirectory:)` against user theme files already read, so an apply reads
  /// them once. A user file that doesn't parse resolves to nothing rather than to a bundled theme of
  /// the same name, since ghostty would load the user's file (see `side(ofThemeNamed:in:)`).
  public static func themePreview(
    named name: String, bundledDirectory: String?, in userThemes: UserThemes
  ) -> ThemePreview? {
    switch userThemes.entry(named: name) {
    case .theme(let preview): return preview
    case .unusable: return nil
    case .absent: break
    }

    return bundledPreviewCache.withLock { cache in
      if let hit = cache[name] { return hit }
      guard let bundledDir = bundledDirectory else { return nil }
      let path = bundledDir + "/" + name
      guard FileManager.default.fileExists(atPath: path),
        let theme = parseThemeFile(atPath: path, name: name)
      else { return nil }
      cache[name] = theme
      return theme
    }
  }

  /// User config dir first (wins on resolution), bundled dir second: `userThemeDirectory()` below
  /// and the caller's bundled directory. `themePreview` deliberately does NOT resolve through this,
  /// because the user/bundled distinction is what decides cacheability and a position in an array
  /// can't carry that.
  public static func themeDirectories(bundledDirectory: String?) -> [String] {
    guard let bundled = bundledDirectory else { return [userThemeDirectory()] }
    return [userThemeDirectory(), bundled]
  }

  /// The user's own theme dir — the same `~/.config/ghostty/themes` ghostty itself reads, so a file
  /// dropped there overrides a bundled theme of the same name in the terminal AND the chrome.
  /// User-writable, therefore never cached.
  public static func userThemeDirectory() -> String {
    userThemeDirectoryOverride.withLock { $0 } ?? NSHomeDirectory() + "/.config/ghostty/themes"
  }

  private static let userThemeDirectoryOverride = Mutex<String?>(nil)

  /// Point `userThemeDirectory()` at `path` for the rest of the process, or back at `~/.config` with
  /// nil. **Test processes only** (a fixture launch, or the host of a hosted unit run): a launch can't
  /// scope the override to a closure the way a unit test does (`withUserThemeDirectory`), and must
  /// never read the owner's real theme files.
  public static func setUserThemeDirectoryForUITesting(_ path: String?) {
    userThemeDirectoryOverride.withLock { $0 = path }
  }

  // MARK: The Light and Dark lists (#737)

  /// The themes on `side`, as the Light and Dark lists show them: the bundled themes on that side
  /// plus the user's own, Workroom's theme for the side first and the rest A→Z (case-insensitive,
  /// numeric, locale-independent for the same reason as `families`).
  ///
  /// The user's themes come from `userThemes`, a read of the folder, so a list reflects the folder as
  /// it was when it loaded. Each is classified by its background (`ThemeSide(background:)`), and one
  /// that doesn't parse, or whose name ghostty reads as a pair (`isSingleThemeName`), is left out. One
  /// named like a bundled theme replaces it: listed once, as the user's, on the side its own
  /// background gives it, so a dark file called `Ayu Light` moves to the Dark list. An unusable one
  /// hides the bundled theme too, since ghostty would still load the user's file for that name
  /// (`side(ofThemeNamed:in:)`).
  public static func themes(on side: ThemeSide, in userThemes: UserThemes) -> [ListedTheme] {
    let users = userThemes.listed
    let bundled = bundledThemes.filter { $0.side == side && !userThemes.shadows($0.name) }
      .map { ListedTheme(name: $0.name, side: $0.side, isUserTheme: false) }
    let all = (bundled + users.filter { $0.side == side }).sorted {
      $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
    }
    let first = defaultFamily.theme(for: side)
    guard let index = all.firstIndex(where: { $0.name == first }) else { return all }
    var ordered = all
    let workroom = ordered.remove(at: index)
    return [workroom] + ordered
  }

  /// The families the Family tab offers: every family whose light theme resolves to the light side
  /// and whose dark theme resolves to the dark side (`side(ofThemeNamed:in:)`, so a user's
  /// replacement is judged by its own background). A family is unavailable while a replacement puts
  /// either of its themes on the wrong side, or doesn't parse, so choosing a family never puts a dark
  /// theme in the light setting. `families` order is kept.
  public static func availableFamilies(in userThemes: UserThemes) -> [ThemeFamily] {
    families.filter {
      side(ofThemeNamed: $0.light, in: userThemes) == .light
        && side(ofThemeNamed: $0.dark, in: userThemes) == .dark
    }
  }

  /// `themes(on:in:)` against the user's theme folder as it is now.
  public static func themes(on side: ThemeSide) -> [ListedTheme] {
    themes(on: side, in: .read())
  }

  /// `availableFamilies(in:)` against the user's theme folder as it is now, read once.
  public static func availableFamilies() -> [ThemeFamily] {
    availableFamilies(in: .read())
  }

  /// Redirect `userThemeDirectory()` at `path` for the duration of `body`. **Tests only.**
  ///
  /// This exists because the alternative was untestable: proving "a user's own theme file beats a warm
  /// bundled cache" needs a real file in the user dir, and the only user dir available was the
  /// developer's actual `~/.config/ghostty/themes`. The test that stood here before asserted the
  /// *ordering* of `themeDirectories()` instead and would still have passed if the cache had been
  /// consulted before the user dir — the exact regression the cache introduced the risk of.
  ///
  /// Scoped rather than a settable property so a test can't leak the override into later cases. It is
  /// process-wide while set, so a concurrent reader in another test class sees it — harmless in
  /// practice, since a lookup only diverges for a name that exists in `path`. The override in place
  /// before is put back after, not cleared: a hosted unit run points the whole process at an empty
  /// scratch directory at launch, and clearing it would send every later test to the real
  /// `~/.config`.
  public static func withUserThemeDirectory<T>(_ path: String, _ body: () throws -> T) rethrows
    -> T
  {
    let previous = userThemeDirectoryOverride.withLock { override in
      defer { override = path }
      return override
    }
    defer { userThemeDirectoryOverride.withLock { $0 = previous } }
    return try body()
  }
}
