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
  /// (`bundledThemes` below); `ThemeCatalogTests` pins that.
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

  /// Every theme the app bundles, each listed once with its side fixed. Each name is a file in
  /// `Resources/ghostty/themes`; `ThemeServiceTests` pins the list to the files as exact set equality
  /// and checks every side against the file's background.
  ///
  /// Authored, not derived from `families`: a derived list would make "every family's themes are
  /// bundled on their sides" true by construction, and themes that belong to no family must be able
  /// to appear here.
  public static let bundledThemes: [BundledTheme] = [
    BundledTheme(name: "0x96f", side: .dark),
    BundledTheme(name: "12-bit Rainbow", side: .dark),
    BundledTheme(name: "13th Floor", side: .dark),
    BundledTheme(name: "3024 Day", side: .light),
    BundledTheme(name: "3024 Night", side: .dark),
    BundledTheme(name: "5150 Mode", side: .dark),
    BundledTheme(name: "Aardvark Blue", side: .dark),
    BundledTheme(name: "Aardvark Ink", side: .dark),
    BundledTheme(name: "Abandoned", side: .dark),
    BundledTheme(name: "Abernathy", side: .dark),
    BundledTheme(name: "Acid Lime", side: .dark),
    BundledTheme(name: "Adobe Moon", side: .dark),
    BundledTheme(name: "Adventure", side: .dark),
    BundledTheme(name: "Adventure Time", side: .dark),
    BundledTheme(name: "Adwaita", side: .light),
    BundledTheme(name: "Adwaita Dark", side: .dark),
    BundledTheme(name: "After Hours", side: .dark),
    BundledTheme(name: "Afterglow", side: .dark),
    BundledTheme(name: "Afterimage", side: .light),
    BundledTheme(name: "Agave Dusk", side: .dark),
    BundledTheme(name: "Aizen Dark", side: .dark),
    BundledTheme(name: "Aizen Light", side: .light),
    BundledTheme(name: "Alabaster", side: .light),
    BundledTheme(name: "Alpine Milk", side: .light),
    BundledTheme(name: "AlxPro Dark", side: .dark),
    BundledTheme(name: "AlxPro Light", side: .light),
    BundledTheme(name: "Amber CRT Retro", side: .dark),
    BundledTheme(name: "Analog Heartbeat", side: .dark),
    BundledTheme(name: "Analyzed Dark", side: .dark),
    BundledTheme(name: "Analyzed Light", side: .light),
    BundledTheme(name: "Andromeda", side: .dark),
    BundledTheme(name: "Apple Classic", side: .dark),
    BundledTheme(name: "Apple System Colors", side: .dark),
    BundledTheme(name: "Apple System Colors Light", side: .light),
    BundledTheme(name: "Arcoiris", side: .dark),
    BundledTheme(name: "Ardoise", side: .dark),
    BundledTheme(name: "Argonaut", side: .dark),
    BundledTheme(name: "Arizona Monsoon", side: .dark),
    BundledTheme(name: "Arthur", side: .dark),
    BundledTheme(name: "Atelier Sulphurpool", side: .dark),
    BundledTheme(name: "Atlas Ragnarok", side: .dark),
    BundledTheme(name: "Atom", side: .dark),
    BundledTheme(name: "Atom One Dark", side: .dark),
    BundledTheme(name: "Atom One Light", side: .light),
    BundledTheme(name: "Aubade", side: .light),
    BundledTheme(name: "Aura", side: .dark),
    BundledTheme(name: "Aura Dark", side: .dark),
    BundledTheme(name: "Aurora", side: .dark),
    BundledTheme(name: "Aurora Drift", side: .dark),
    BundledTheme(name: "Autumn After Dark", side: .dark),
    BundledTheme(name: "Ayu", side: .dark),
    BundledTheme(name: "Ayu Light", side: .light),
    BundledTheme(name: "Ayu Mirage", side: .dark),
    BundledTheme(name: "Aztec Sunset", side: .dark),
    BundledTheme(name: "Banana Blueberry", side: .dark),
    BundledTheme(name: "Barbenheimer Bunker", side: .dark),
    BundledTheme(name: "Barbenheimer Dreamhouse", side: .light),
    BundledTheme(name: "Barbenheimer Nuclear Sunrise", side: .dark),
    BundledTheme(name: "Barrel Cactus", side: .dark),
    BundledTheme(name: "Bauhaus Dark", side: .dark),
    BundledTheme(name: "Bauhaus Light", side: .light),
    BundledTheme(name: "Belafonte Day", side: .light),
    BundledTheme(name: "Belafonte Night", side: .dark),
    BundledTheme(name: "Belfry", side: .dark),
    BundledTheme(name: "Birds Of Paradise", side: .dark),
    BundledTheme(name: "Black Box Recorder", side: .dark),
    BundledTheme(name: "Black Cat", side: .dark),
    BundledTheme(name: "Black Metal", side: .dark),
    BundledTheme(name: "Black Metal (Bathory)", side: .dark),
    BundledTheme(name: "Black Metal (Burzum)", side: .dark),
    BundledTheme(name: "Black Metal (Dark Funeral)", side: .dark),
    BundledTheme(name: "Black Metal (Gorgoroth)", side: .dark),
    BundledTheme(name: "Black Metal (Immortal)", side: .dark),
    BundledTheme(name: "Black Metal (Khold)", side: .dark),
    BundledTheme(name: "Black Metal (Marduk)", side: .dark),
    BundledTheme(name: "Black Metal (Mayhem)", side: .dark),
    BundledTheme(name: "Black Metal (Nile)", side: .dark),
    BundledTheme(name: "Black Metal (Venom)", side: .dark),
    BundledTheme(name: "Blazer", side: .dark),
    BundledTheme(name: "Blood Moon", side: .dark),
    BundledTheme(name: "Blue Berry Pie", side: .dark),
    BundledTheme(name: "Blue Dolphin", side: .dark),
    BundledTheme(name: "Blue Matrix", side: .dark),
    BundledTheme(name: "Blueprint", side: .light),
    BundledTheme(name: "Bluloco Dark", side: .dark),
    BundledTheme(name: "Bluloco Light", side: .light),
    BundledTheme(name: "Bone Yard", side: .light),
    BundledTheme(name: "Borland", side: .dark),
    BundledTheme(name: "Box", side: .dark),
    BundledTheme(name: "branch", side: .dark),
    BundledTheme(name: "Breadog", side: .light),
    BundledTheme(name: "Breeze", side: .dark),
    BundledTheme(name: "Bright Lights", side: .dark),
    BundledTheme(name: "Broadcast", side: .dark),
    BundledTheme(name: "Brogrammer", side: .dark),
    BundledTheme(name: "Cactus Bloom", side: .light),
    BundledTheme(name: "Calamity", side: .dark),
    BundledTheme(name: "Caliche", side: .dark),
    BundledTheme(name: "Callie", side: .dark),
    BundledTheme(name: "Callie Light", side: .light),
    BundledTheme(name: "Candlelight", side: .dark),
    BundledTheme(name: "Candy Corn", side: .light),
    BundledTheme(name: "Canyon Shadow", side: .dark),
    BundledTheme(name: "Canyon Walnut", side: .dark),
    BundledTheme(name: "Carbon Paper", side: .light),
    BundledTheme(name: "Carbonfox", side: .dark),
    BundledTheme(name: "Cassette Tape", side: .light),
    BundledTheme(name: "Catppuccin Frappe", side: .dark),
    BundledTheme(name: "Catppuccin Latte", side: .light),
    BundledTheme(name: "Catppuccin Macchiato", side: .dark),
    BundledTheme(name: "Catppuccin Mocha", side: .dark),
    BundledTheme(name: "Catthode", side: .dark),
    BundledTheme(name: "CGA", side: .dark),
    BundledTheme(name: "Chalk", side: .dark),
    BundledTheme(name: "Chalkboard", side: .dark),
    BundledTheme(name: "Challenger Deep", side: .dark),
    BundledTheme(name: "Charcoal", side: .dark),
    BundledTheme(name: "Chester", side: .dark),
    BundledTheme(name: "Cholla", side: .dark),
    BundledTheme(name: "Ciapre", side: .dark),
    BundledTheme(name: "Citrus Ink", side: .dark),
    BundledTheme(name: "Citruszest", side: .dark),
    BundledTheme(name: "Claude", side: .light),
    BundledTheme(name: "Claude Dark", side: .dark),
    BundledTheme(name: "Claude Light", side: .light),
    BundledTheme(name: "Clear Dark", side: .dark),
    BundledTheme(name: "Clear Light", side: .light),
    BundledTheme(name: "Clockwork Gold", side: .dark),
    BundledTheme(name: "CLRS", side: .light),
    BundledTheme(name: "Clu", side: .dark),
    BundledTheme(name: "Cobalt Foundry", side: .dark),
    BundledTheme(name: "Cobalt Neon", side: .dark),
    BundledTheme(name: "Cobalt Next", side: .dark),
    BundledTheme(name: "Cobalt Next Dark", side: .dark),
    BundledTheme(name: "Cobalt Next Minimal", side: .dark),
    BundledTheme(name: "Cobalt2", side: .dark),
    BundledTheme(name: "Cobweb", side: .dark),
    BundledTheme(name: "Code 2026 Dark", side: .dark),
    BundledTheme(name: "Code 2026 Light", side: .light),
    BundledTheme(name: "Coffee Theme", side: .light),
    BundledTheme(name: "Cold Storage", side: .light),
    BundledTheme(name: "Cool Night", side: .dark),
    BundledTheme(name: "Copper Canyon", side: .dark),
    BundledTheme(name: "Count Terminal", side: .dark),
    BundledTheme(name: "CRT Afterglow", side: .dark),
    BundledTheme(name: "CRT Amber", side: .dark),
    BundledTheme(name: "Crypt Keeper", side: .dark),
    BundledTheme(name: "Crystal Ball", side: .dark),
    BundledTheme(name: "Cursed VHS", side: .dark),
    BundledTheme(name: "Cursor Dark", side: .dark),
    BundledTheme(name: "Cursor Light", side: .light),
    BundledTheme(name: "Cutie Pro", side: .dark),
    BundledTheme(name: "Cyberdyne", side: .dark),
    BundledTheme(name: "Cyberpunk", side: .dark),
    BundledTheme(name: "cyberpunk-icy", side: .dark),
    BundledTheme(name: "Dalton Dark", side: .dark),
    BundledTheme(name: "Dark 2026", side: .dark),
    BundledTheme(name: "Dark Modern", side: .dark),
    BundledTheme(name: "Dark Pastel", side: .dark),
    BundledTheme(name: "Darkside", side: .dark),
    BundledTheme(name: "datum (dark)", side: .dark),
    BundledTheme(name: "datum (light)", side: .light),
    BundledTheme(name: "Dawnfox", side: .light),
    BundledTheme(name: "Daybreak", side: .light),
    BundledTheme(name: "Daybreaker", side: .light),
    BundledTheme(name: "Dayfox", side: .light),
    BundledTheme(name: "Dead Letter Office", side: .dark),
    BundledTheme(name: "Deep", side: .dark),
    BundledTheme(name: "Deep Current", side: .dark),
    BundledTheme(name: "Desert", side: .dark),
    BundledTheme(name: "Desert Bloom", side: .dark),
    BundledTheme(name: "Desert Moon", side: .dark),
    BundledTheme(name: "Desert Morning", side: .light),
    BundledTheme(name: "Desert Rose", side: .dark),
    BundledTheme(name: "Desert Thunder", side: .dark),
    BundledTheme(name: "Detroit After Dark", side: .dark),
    BundledTheme(name: "Detuned", side: .dark),
    BundledTheme(name: "Diary of a Lunatic", side: .dark),
    BundledTheme(name: "Dimidium", side: .dark),
    BundledTheme(name: "Dimmed Monokai", side: .dark),
    BundledTheme(name: "Django", side: .dark),
    BundledTheme(name: "Django Reborn Again", side: .dark),
    BundledTheme(name: "Django Smooth", side: .dark),
    BundledTheme(name: "Dogxi Misty", side: .dark),
    BundledTheme(name: "Doom One", side: .dark),
    BundledTheme(name: "Doom Peacock", side: .dark),
    BundledTheme(name: "Dot Gov", side: .dark),
    BundledTheme(name: "Dracula", side: .dark),
    BundledTheme(name: "Dracula+", side: .dark),
    BundledTheme(name: "Dracula+ High Contrast", side: .dark),
    BundledTheme(name: "Dream Onward", side: .dark),
    BundledTheme(name: "Driftwood", side: .dark),
    BundledTheme(name: "Duckbones", side: .dark),
    BundledTheme(name: "Duotone Dark", side: .dark),
    BundledTheme(name: "Duskfox", side: .dark),
    BundledTheme(name: "Earl Grey", side: .light),
    BundledTheme(name: "Earthsong", side: .dark),
    BundledTheme(name: "Eclipse", side: .dark),
    BundledTheme(name: "Ectoplasm", side: .dark),
    BundledTheme(name: "Edge Light", side: .light),
    BundledTheme(name: "Eight Hundred", side: .dark),
    BundledTheme(name: "Electric Voodoo", side: .dark),
    BundledTheme(name: "Electron Highlighter", side: .dark),
    BundledTheme(name: "Electron Highlighter Day", side: .light),
    BundledTheme(name: "Elegant", side: .dark),
    BundledTheme(name: "Elementary", side: .dark),
    BundledTheme(name: "Embark", side: .dark),
    BundledTheme(name: "Ember", side: .dark),
    BundledTheme(name: "Ember Peak", side: .dark),
    BundledTheme(name: "Emberglass", side: .dark),
    BundledTheme(name: "Embers Dark", side: .dark),
    BundledTheme(name: "Emerald Synth", side: .dark),
    BundledTheme(name: "ENCOM", side: .dark),
    BundledTheme(name: "Espresso", side: .dark),
    BundledTheme(name: "Espresso Libre", side: .dark),
    BundledTheme(name: "Eventide", side: .dark),
    BundledTheme(name: "Everblush", side: .dark),
    BundledTheme(name: "Everforest Dark Hard", side: .dark),
    BundledTheme(name: "Everforest Dark Med", side: .dark),
    BundledTheme(name: "Everforest Dark Soft", side: .dark),
    BundledTheme(name: "Everforest Light Hard", side: .light),
    BundledTheme(name: "Everforest Light Med", side: .light),
    BundledTheme(name: "Evergreen", side: .dark),
    BundledTheme(name: "everslate", side: .dark),
    BundledTheme(name: "EVH FrankenTone", side: .dark),
    BundledTheme(name: "eyesclosed", side: .dark),
    BundledTheme(name: "Fahrenheit", side: .dark),
    BundledTheme(name: "Farmhouse Dark", side: .dark),
    BundledTheme(name: "Farmhouse Light", side: .light),
    BundledTheme(name: "Fideloper", side: .dark),
    BundledTheme(name: "Firefly Traditional", side: .dark),
    BundledTheme(name: "Firefox Dev", side: .dark),
    BundledTheme(name: "Firewatch", side: .dark),
    BundledTheme(name: "Fish Tank", side: .dark),
    BundledTheme(name: "Flat", side: .dark),
    BundledTheme(name: "Flatland", side: .dark),
    BundledTheme(name: "Flexoki Dark", side: .dark),
    BundledTheme(name: "Flexoki Light", side: .light),
    BundledTheme(name: "Floraverse", side: .dark),
    BundledTheme(name: "Forest Blue", side: .dark),
    BundledTheme(name: "Forge Ember", side: .dark),
    BundledTheme(name: "Forged in Steel", side: .dark),
    BundledTheme(name: "Front End Delight", side: .dark),
    BundledTheme(name: "Frostbyte", side: .light),
    BundledTheme(name: "Frostline", side: .light),
    BundledTheme(name: "Fun Forrest", side: .dark),
    BundledTheme(name: "Galaxy", side: .dark),
    BundledTheme(name: "Galizur", side: .dark),
    BundledTheme(name: "Ghost Circuit", side: .dark),
    BundledTheme(name: "Gilded-Forest-Dark", side: .dark),
    BundledTheme(name: "GitHub", side: .light),
    BundledTheme(name: "GitHub Dark", side: .dark),
    BundledTheme(name: "GitHub Dark Colorblind", side: .dark),
    BundledTheme(name: "GitHub Dark Default", side: .dark),
    BundledTheme(name: "GitHub Dark Dimmed", side: .dark),
    BundledTheme(name: "GitHub Dark High Contrast", side: .dark),
    BundledTheme(name: "GitHub Light Colorblind", side: .light),
    BundledTheme(name: "GitHub Light Default", side: .light),
    BundledTheme(name: "GitHub Light High Contrast", side: .light),
    BundledTheme(name: "GitLab Dark", side: .dark),
    BundledTheme(name: "GitLab Dark Grey", side: .dark),
    BundledTheme(name: "GitLab Light", side: .light),
    BundledTheme(name: "Glacier", side: .dark),
    BundledTheme(name: "Glacier Mint", side: .light),
    BundledTheme(name: "Gleam", side: .dark),
    BundledTheme(name: "Gleam Classic", side: .dark),
    BundledTheme(name: "Golden Mischief", side: .light),
    BundledTheme(name: "Golden Retriever Cream", side: .light),
    BundledTheme(name: "Golden Retriever Honey", side: .light),
    BundledTheme(name: "Golden Retriever Red", side: .light),
    BundledTheme(name: "Grape", side: .dark),
    BundledTheme(name: "Graphite", side: .dark),
    BundledTheme(name: "Graveyard Shift", side: .dark),
    BundledTheme(name: "Great Pumpkin", side: .light),
    BundledTheme(name: "Green Phosphor CRT", side: .dark),
    BundledTheme(name: "Green Screen", side: .dark),
    BundledTheme(name: "Grey Green", side: .dark),
    BundledTheme(name: "Grok Day", side: .light),
    BundledTheme(name: "Grok Night", side: .dark),
    BundledTheme(name: "Gruber Darker", side: .dark),
    BundledTheme(name: "Gruber Darker Legacy", side: .dark),
    BundledTheme(name: "Gruvbox Dark", side: .dark),
    BundledTheme(name: "Gruvbox Dark Hard", side: .dark),
    BundledTheme(name: "Gruvbox Light", side: .light),
    BundledTheme(name: "Gruvbox Light Hard", side: .light),
    BundledTheme(name: "Gruvbox Material", side: .dark),
    BundledTheme(name: "Gruvbox Material Dark", side: .dark),
    BundledTheme(name: "Gruvbox Material Light", side: .light),
    BundledTheme(name: "Guezwhoz", side: .dark),
    BundledTheme(name: "Hacktober", side: .dark),
    BundledTheme(name: "Hadal Bloom", side: .dark),
    BundledTheme(name: "Hardcore", side: .dark),
    BundledTheme(name: "Harper", side: .dark),
    BundledTheme(name: "Harvest Moon", side: .dark),
    BundledTheme(name: "Haunted House", side: .dark),
    BundledTheme(name: "Havn Daggry", side: .light),
    BundledTheme(name: "Havn Skumring", side: .dark),
    BundledTheme(name: "HaX0R Blue", side: .dark),
    BundledTheme(name: "HaX0R Gr33N", side: .dark),
    BundledTheme(name: "hazyland", side: .dark),
    BundledTheme(name: "Heeler", side: .dark),
    BundledTheme(name: "Hellfire", side: .dark),
    BundledTheme(name: "High Desert Snow", side: .light),
    BundledTheme(name: "High Voltage Highway", side: .dark),
    BundledTheme(name: "Highway", side: .dark),
    BundledTheme(name: "Hipster Green", side: .dark),
    BundledTheme(name: "Hivacruz", side: .dark),
    BundledTheme(name: "HN After Dark", side: .dark),
    BundledTheme(name: "HN Classic", side: .light),
    BundledTheme(name: "Hocus Pocus", side: .dark),
    BundledTheme(name: "Homebrew", side: .dark),
    BundledTheme(name: "Hopscotch", side: .dark),
    BundledTheme(name: "Hopscotch.256", side: .dark),
    BundledTheme(name: "Horizon", side: .dark),
    BundledTheme(name: "Horizon Bright", side: .light),
    BundledTheme(name: "Horizons", side: .light),
    BundledTheme(name: "Hot Dog Stand (Mustard)", side: .light),
    BundledTheme(name: "Hurtado", side: .dark),
    BundledTheme(name: "Hybrid", side: .dark),
    BundledTheme(name: "Hysterical Frequency", side: .dark),
    BundledTheme(name: "IBM 5153 CGA", side: .dark),
    BundledTheme(name: "IBM 5153 CGA (Black)", side: .dark),
    BundledTheme(name: "IC Green PPL", side: .dark),
    BundledTheme(name: "IC Orange PPL", side: .dark),
    BundledTheme(name: "Iceberg Dark", side: .dark),
    BundledTheme(name: "Iceberg Light", side: .light),
    BundledTheme(name: "Icy Glacier", side: .light),
    BundledTheme(name: "Idea", side: .dark),
    BundledTheme(name: "Idle Toes", side: .dark),
    BundledTheme(name: "iglass Dark", side: .dark),
    BundledTheme(name: "iglass Light", side: .light),
    BundledTheme(name: "IR Black", side: .dark),
    BundledTheme(name: "IRIX Console", side: .dark),
    BundledTheme(name: "IRIX Terminal", side: .dark),
    BundledTheme(name: "iTerm2 Solarized Dark", side: .dark),
    BundledTheme(name: "iTerm2 Solarized Light", side: .light),
    BundledTheme(name: "Jack O' Lantern", side: .dark),
    BundledTheme(name: "Jackie Brown", side: .dark),
    BundledTheme(name: "Japanesque", side: .dark),
    BundledTheme(name: "Jellybeans", side: .dark),
    BundledTheme(name: "JetBrains Darcula", side: .dark),
    BundledTheme(name: "JetBrains Islands Dark", side: .dark),
    BundledTheme(name: "JetCalm Light", side: .light),
    BundledTheme(name: "Jubi", side: .dark),
    BundledTheme(name: "Jump Start", side: .dark),
    BundledTheme(name: "Jute Espresso", side: .dark),
    BundledTheme(name: "Kanagawa Dragon", side: .dark),
    BundledTheme(name: "Kanagawa Lotus", side: .light),
    BundledTheme(name: "Kanagawa Wave", side: .dark),
    BundledTheme(name: "Kanagawabones", side: .dark),
    BundledTheme(name: "Kanso Ink", side: .dark),
    BundledTheme(name: "Kanso Mist", side: .dark),
    BundledTheme(name: "Kanso Pearl", side: .light),
    BundledTheme(name: "Kanso Zen", side: .dark),
    BundledTheme(name: "Karasu Night", side: .dark),
    BundledTheme(name: "Karasu Snow", side: .light),
    BundledTheme(name: "Karma Dark", side: .dark),
    BundledTheme(name: "Karma Dark Dimmed", side: .dark),
    BundledTheme(name: "Karma Dark HC", side: .dark),
    BundledTheme(name: "Karma Light", side: .light),
    BundledTheme(name: "Karma Light Dimmed", side: .light),
    BundledTheme(name: "Karma Light HC", side: .light),
    BundledTheme(name: "Kashmir Nights", side: .dark),
    BundledTheme(name: "Keys Ocean Sunset", side: .dark),
    BundledTheme(name: "Keys Ocean Sunset HC", side: .dark),
    BundledTheme(name: "Kibble", side: .dark),
    BundledTheme(name: "Klein Void", side: .dark),
    BundledTheme(name: "Kolorit", side: .dark),
    BundledTheme(name: "Konsolas", side: .dark),
    BundledTheme(name: "Kurokula", side: .dark),
    BundledTheme(name: "Kwyjibo", side: .dark),
    BundledTheme(name: "Lab Fox", side: .dark),
    BundledTheme(name: "Laser", side: .dark),
    BundledTheme(name: "Last Broadcast", side: .dark),
    BundledTheme(name: "Later This Evening", side: .dark),
    BundledTheme(name: "Lemon Graphite", side: .dark),
    BundledTheme(name: "Letterpress", side: .light),
    BundledTheme(name: "Light 2026", side: .light),
    BundledTheme(name: "Light Owl", side: .light),
    BundledTheme(name: "Liquid Carbon", side: .dark),
    BundledTheme(name: "Liquid Carbon Transparent", side: .dark),
    BundledTheme(name: "Lit Cell", side: .dark),
    BundledTheme(name: "Lit Cell Light", side: .light),
    BundledTheme(name: "London Bonfire Night", side: .dark),
    BundledTheme(name: "London Columbia Road", side: .light),
    BundledTheme(name: "London Embankment Dusk", side: .dark),
    BundledTheme(name: "London Soho Night", side: .dark),
    BundledTheme(name: "Lovelace", side: .dark),
    BundledTheme(name: "Lumina Aurora Dark", side: .dark),
    BundledTheme(name: "Lumina Aurora Light", side: .light),
    BundledTheme(name: "Lumina Canopy Dark", side: .dark),
    BundledTheme(name: "Lumina Canopy Light", side: .light),
    BundledTheme(name: "Lumina Cherenkov Dark", side: .dark),
    BundledTheme(name: "Lumina Cherenkov Light", side: .light),
    BundledTheme(name: "Lumina Dusk Dark", side: .dark),
    BundledTheme(name: "Lumina Dusk Light", side: .light),
    BundledTheme(name: "Lumina Ember Dark", side: .dark),
    BundledTheme(name: "Lumina Ember Light", side: .light),
    BundledTheme(name: "Lumina Espresso Dark", side: .dark),
    BundledTheme(name: "Lumina Espresso Light", side: .light),
    BundledTheme(name: "Lumina Harbor Dark", side: .dark),
    BundledTheme(name: "Lumina Harbor Light", side: .light),
    BundledTheme(name: "Lumina Lagoon Dark", side: .dark),
    BundledTheme(name: "Lumina Lagoon Light", side: .light),
    BundledTheme(name: "Lumina Nebula Dark", side: .dark),
    BundledTheme(name: "Lumina Nebula Light", side: .light),
    BundledTheme(name: "Lumina Olive Dark", side: .dark),
    BundledTheme(name: "Lumina Olive Light", side: .light),
    BundledTheme(name: "Lumina Oxblood Dark", side: .dark),
    BundledTheme(name: "Lumina Oxblood Light", side: .light),
    BundledTheme(name: "Lumina Parchment Dark", side: .dark),
    BundledTheme(name: "Lumina Parchment Light", side: .light),
    BundledTheme(name: "Lumina Polaire Dark", side: .dark),
    BundledTheme(name: "Lumina Polaire Light", side: .light),
    BundledTheme(name: "Lumina Quartz Dark", side: .dark),
    BundledTheme(name: "Lumina Quartz Light", side: .light),
    BundledTheme(name: "Lumina Rayleigh Dark", side: .dark),
    BundledTheme(name: "Lumina Rayleigh Light", side: .light),
    BundledTheme(name: "Lumina Vitrail Dark", side: .dark),
    BundledTheme(name: "Lumina Vitrail Light", side: .light),
    BundledTheme(name: "Lunar Dust", side: .light),
    BundledTheme(name: "Madman's Diary", side: .dark),
    BundledTheme(name: "Man Page", side: .light),
    BundledTheme(name: "Maple Jute", side: .dark),
    BundledTheme(name: "Mariana", side: .dark),
    BundledTheme(name: "Matcha Zen", side: .light),
    BundledTheme(name: "Material", side: .light),
    BundledTheme(name: "Material Dark", side: .dark),
    BundledTheme(name: "Material Darker", side: .dark),
    BundledTheme(name: "Material Design Colors", side: .dark),
    BundledTheme(name: "Material Ocean", side: .dark),
    BundledTheme(name: "Mathias", side: .dark),
    BundledTheme(name: "Matte Black", side: .dark),
    BundledTheme(name: "Medallion", side: .dark),
    BundledTheme(name: "Melange Dark", side: .dark),
    BundledTheme(name: "Melange Light", side: .light),
    BundledTheme(name: "Mellifluous", side: .dark),
    BundledTheme(name: "Mellow", side: .dark),
    BundledTheme(name: "Merino Light", side: .light),
    BundledTheme(name: "Mesa Blue", side: .dark),
    BundledTheme(name: "Mesa Twilight", side: .dark),
    BundledTheme(name: "Mesila One", side: .dark),
    BundledTheme(name: "Miami Heat", side: .dark),
    BundledTheme(name: "Miasma", side: .dark),
    BundledTheme(name: "Midnight Arcade", side: .dark),
    BundledTheme(name: "Midnight In Mojave", side: .dark),
    BundledTheme(name: "Midnight Rambler", side: .dark),
    BundledTheme(name: "Midnight Tundra", side: .dark),
    BundledTheme(name: "Mindcrime", side: .dark),
    BundledTheme(name: "Mirage", side: .dark),
    BundledTheme(name: "Misterioso", side: .dark),
    BundledTheme(name: "mistpine", side: .dark),
    BundledTheme(name: "Modus Operandi", side: .light),
    BundledTheme(name: "Modus Operandi Deuteranopia", side: .light),
    BundledTheme(name: "Modus Operandi Tinted", side: .light),
    BundledTheme(name: "Modus Operandi Tritanopia", side: .light),
    BundledTheme(name: "Modus Vivendi", side: .dark),
    BundledTheme(name: "Modus Vivendi Deuteranopia", side: .dark),
    BundledTheme(name: "Modus Vivendi Tinted", side: .dark),
    BundledTheme(name: "Modus Vivendi Tritanopia", side: .dark),
    BundledTheme(name: "Molokai", side: .dark),
    BundledTheme(name: "Molten Core", side: .dark),
    BundledTheme(name: "Mona Lisa", side: .dark),
    BundledTheme(name: "Monokai Classic", side: .dark),
    BundledTheme(name: "Monokai Pro", side: .dark),
    BundledTheme(name: "Monokai Pro Light", side: .light),
    BundledTheme(name: "Monokai Pro Light Sun", side: .light),
    BundledTheme(name: "Monokai Pro Machine", side: .dark),
    BundledTheme(name: "Monokai Pro Octagon", side: .dark),
    BundledTheme(name: "Monokai Pro Ristretto", side: .dark),
    BundledTheme(name: "Monokai Pro Spectrum", side: .dark),
    BundledTheme(name: "Monokai Remastered", side: .dark),
    BundledTheme(name: "Monokai Soda", side: .dark),
    BundledTheme(name: "Monokai SublimeText", side: .dark),
    BundledTheme(name: "Monokai Vivid", side: .dark),
    BundledTheme(name: "Monospace Dark", side: .dark),
    BundledTheme(name: "Monospace Light", side: .light),
    BundledTheme(name: "Monsoon Mesa", side: .dark),
    BundledTheme(name: "Monster Mash", side: .dark),
    BundledTheme(name: "Moonfly", side: .dark),
    BundledTheme(name: "Moonwalk", side: .light),
    BundledTheme(name: "Moss & Ember", side: .dark),
    BundledTheme(name: "Motel Vacancy", side: .dark),
    BundledTheme(name: "Moving Signals", side: .dark),
    BundledTheme(name: "N0Tch2K", side: .dark),
    BundledTheme(name: "Nachtschicht", side: .dark),
    BundledTheme(name: "Nebula Drift", side: .dark),
    BundledTheme(name: "Neobones Dark", side: .dark),
    BundledTheme(name: "Neobones Light", side: .light),
    BundledTheme(name: "Neon", side: .dark),
    BundledTheme(name: "Neon Analog", side: .dark),
    BundledTheme(name: "Neon Arcade", side: .dark),
    BundledTheme(name: "Neon Purple", side: .dark),
    BundledTheme(name: "Neon Raincheck", side: .dark),
    BundledTheme(name: "Neopolitan", side: .dark),
    BundledTheme(name: "Nephrite Forest", side: .dark),
    BundledTheme(name: "Nephrite Jade", side: .dark),
    BundledTheme(name: "Nephrite Mint", side: .light),
    BundledTheme(name: "Neutron", side: .dark),
    BundledTheme(name: "Newsprint Fog", side: .light),
    BundledTheme(name: "Night Lion V1", side: .dark),
    BundledTheme(name: "Night Lion V2", side: .dark),
    BundledTheme(name: "Night Owl", side: .dark),
    BundledTheme(name: "Night Owlish Light", side: .light),
    BundledTheme(name: "Night Pharmacy", side: .dark),
    BundledTheme(name: "Nightfall", side: .dark),
    BundledTheme(name: "Nightfox", side: .dark),
    BundledTheme(name: "Niji", side: .dark),
    BundledTheme(name: "No Clown Fiesta", side: .dark),
    BundledTheme(name: "No Clown Fiesta Light", side: .light),
    BundledTheme(name: "Noctis", side: .dark),
    BundledTheme(name: "Noctis Azureus", side: .dark),
    BundledTheme(name: "Noctis Bordo", side: .dark),
    BundledTheme(name: "Noctis Hibernus", side: .light),
    BundledTheme(name: "Noctis Lilac", side: .light),
    BundledTheme(name: "Noctis Lux", side: .light),
    BundledTheme(name: "Noctis Minimus", side: .dark),
    BundledTheme(name: "Noctis Obscuro", side: .dark),
    BundledTheme(name: "Noctis Sereno", side: .dark),
    BundledTheme(name: "Noctis Uva", side: .dark),
    BundledTheme(name: "Noctis Viola", side: .dark),
    BundledTheme(name: "Nocturnal Winter", side: .dark),
    BundledTheme(name: "Nord", side: .dark),
    BundledTheme(name: "Nord Light", side: .light),
    BundledTheme(name: "Nord Wave", side: .dark),
    BundledTheme(name: "Nordfox", side: .dark),
    BundledTheme(name: "Northstar", side: .dark),
    BundledTheme(name: "Novel", side: .light),
    BundledTheme(name: "novmbr", side: .dark),
    BundledTheme(name: "Numbers Station", side: .dark),
    BundledTheme(name: "Nvim Dark", side: .dark),
    BundledTheme(name: "Nvim Light", side: .light),
    BundledTheme(name: "Obsidian", side: .dark),
    BundledTheme(name: "Obsurdian", side: .dark),
    BundledTheme(name: "Ocean", side: .dark),
    BundledTheme(name: "Oceanic Material", side: .dark),
    BundledTheme(name: "Oceanic Next", side: .dark),
    BundledTheme(name: "Ocotillo", side: .dark),
    BundledTheme(name: "Ollie", side: .dark),
    BundledTheme(name: "One Dark Two", side: .dark),
    BundledTheme(name: "One Double Dark", side: .dark),
    BundledTheme(name: "One Double Light", side: .light),
    BundledTheme(name: "One Half Dark", side: .dark),
    BundledTheme(name: "One Half Light", side: .light),
    BundledTheme(name: "Onenord", side: .dark),
    BundledTheme(name: "Onenord Light", side: .light),
    BundledTheme(name: "Opaline", side: .dark),
    BundledTheme(name: "OpenCode Dark", side: .dark),
    BundledTheme(name: "OpenCode Light", side: .light),
    BundledTheme(name: "Operator Mono Dark", side: .dark),
    BundledTheme(name: "Outrun Electric", side: .dark),
    BundledTheme(name: "Overnight Slumber", side: .dark),
    BundledTheme(name: "owl", side: .dark),
    BundledTheme(name: "Oxblood", side: .dark),
    BundledTheme(name: "Oxide", side: .dark),
    BundledTheme(name: "Oxocarbon", side: .dark),
    BundledTheme(name: "Painted Desert", side: .dark),
    BundledTheme(name: "Pale Night Hc", side: .dark),
    BundledTheme(name: "Pandora", side: .dark),
    BundledTheme(name: "Paper Crane", side: .light),
    BundledTheme(name: "Paper Tiger", side: .light),
    BundledTheme(name: "Paraiso Dark", side: .dark),
    BundledTheme(name: "Paranoid Circuit", side: .dark),
    BundledTheme(name: "Parchment", side: .light),
    BundledTheme(name: "Patina", side: .dark),
    BundledTheme(name: "Patina Dark", side: .dark),
    BundledTheme(name: "Patina Dark Soft", side: .dark),
    BundledTheme(name: "Patina Lichen", side: .light),
    BundledTheme(name: "Patina Light", side: .light),
    BundledTheme(name: "Patina Moss", side: .dark),
    BundledTheme(name: "Patina Stellar", side: .light),
    BundledTheme(name: "Paul Millr", side: .dark),
    BundledTheme(name: "Pencil Dark", side: .dark),
    BundledTheme(name: "Pencil Light", side: .light),
    BundledTheme(name: "Peppermint", side: .dark),
    BundledTheme(name: "Petrified", side: .dark),
    BundledTheme(name: "Petrol Lagoon", side: .dark),
    BundledTheme(name: "Phala Green Dark", side: .dark),
    BundledTheme(name: "Pharaoh's Voltage", side: .dark),
    BundledTheme(name: "Piatto Light", side: .light),
    BundledTheme(name: "Pierre Dark", side: .dark),
    BundledTheme(name: "Pierre Light", side: .light),
    BundledTheme(name: "Pissed Off Pancakes", side: .dark),
    BundledTheme(name: "Pnevma", side: .dark),
    BundledTheme(name: "Poimandres", side: .dark),
    BundledTheme(name: "Poimandres Darker", side: .dark),
    BundledTheme(name: "Poimandres Storm", side: .dark),
    BundledTheme(name: "Poison Apple", side: .dark),
    BundledTheme(name: "Poltergeist", side: .dark),
    BundledTheme(name: "Popping And Locking", side: .dark),
    BundledTheme(name: "Porcelain", side: .light),
    BundledTheme(name: "Possessed Toaster", side: .dark),
    BundledTheme(name: "Powershell", side: .dark),
    BundledTheme(name: "Prickly Pear", side: .dark),
    BundledTheme(name: "Primary", side: .light),
    BundledTheme(name: "Prince of Barkness", side: .dark),
    BundledTheme(name: "Prince of Darkness", side: .dark),
    BundledTheme(name: "Prism", side: .dark),
    BundledTheme(name: "Prismatica", side: .dark),
    BundledTheme(name: "Pro", side: .dark),
    BundledTheme(name: "Pro Light", side: .light),
    BundledTheme(name: "Pueblo Night", side: .dark),
    BundledTheme(name: "Pumpkin Patch", side: .dark),
    BundledTheme(name: "Puppet's Master", side: .dark),
    BundledTheme(name: "Purple Portal", side: .dark),
    BundledTheme(name: "Purple Rain", side: .dark),
    BundledTheme(name: "Purplepeter", side: .dark),
    BundledTheme(name: "Pyrokai", side: .dark),
    BundledTheme(name: "Pyrokai Light", side: .light),
    BundledTheme(name: "RadicalReborn", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns Arcade", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns Den", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns EGA 85", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns Mane", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns Miami", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns Paper White", side: .light),
    BundledTheme(name: "Rainbows and Unicorns Sorbet", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns VHS", side: .dark),
    BundledTheme(name: "Rainbows and Unicorns Workbench", side: .dark),
    BundledTheme(name: "Rapture", side: .dark),
    BundledTheme(name: "Raycast Dark", side: .dark),
    BundledTheme(name: "Raycast Light", side: .light),
    BundledTheme(name: "Rebecca", side: .dark),
    BundledTheme(name: "Red Alert", side: .dark),
    BundledTheme(name: "Red Planet", side: .dark),
    BundledTheme(name: "Red Rock", side: .dark),
    BundledTheme(name: "Red Sands", side: .dark),
    BundledTheme(name: "Redacted", side: .light),
    BundledTheme(name: "Relaxed", side: .dark),
    BundledTheme(name: "Retro", side: .dark),
    BundledTheme(name: "Retro Legends", side: .dark),
    BundledTheme(name: "Rhoads Concord", side: .light),
    BundledTheme(name: "Rhoads Insipired", side: .dark),
    BundledTheme(name: "Rhoads Legacy", side: .dark),
    BundledTheme(name: "Rhoads LP", side: .light),
    BundledTheme(name: "Rhoads RR Black", side: .dark),
    BundledTheme(name: "Rhoads Tribute", side: .dark),
    BundledTheme(name: "Ride the Current", side: .dark),
    BundledTheme(name: "Rippedcasts", side: .dark),
    BundledTheme(name: "Rose Pine", side: .dark),
    BundledTheme(name: "Rose Pine Dawn", side: .light),
    BundledTheme(name: "Rose Pine Moon", side: .dark),
    BundledTheme(name: "Rouge 2", side: .dark),
    BundledTheme(name: "Royal Rhapsody", side: .light),
    BundledTheme(name: "Ryuuko", side: .dark),
    BundledTheme(name: "Safety Glass", side: .light),
    BundledTheme(name: "Saffron Nightfall", side: .dark),
    BundledTheme(name: "Saguaro", side: .dark),
    BundledTheme(name: "Sakura", side: .dark),
    BundledTheme(name: "Salem", side: .dark),
    BundledTheme(name: "Sandstone Classic", side: .light),
    BundledTheme(name: "Sandstone Ink", side: .light),
    BundledTheme(name: "Sandstone Warm", side: .light),
    BundledTheme(name: "Sauber", side: .light),
    BundledTheme(name: "Sea Shells", side: .dark),
    BundledTheme(name: "Seafoam Pastel", side: .dark),
    BundledTheme(name: "Seance", side: .dark),
    BundledTheme(name: "Sedona", side: .dark),
    BundledTheme(name: "SeedFlip Abyss", side: .dark),
    BundledTheme(name: "SeedFlip Amethyst", side: .light),
    BundledTheme(name: "SeedFlip Canopy", side: .dark),
    BundledTheme(name: "SeedFlip Carbon", side: .light),
    BundledTheme(name: "SeedFlip Coral", side: .light),
    BundledTheme(name: "SeedFlip Ember", side: .dark),
    BundledTheme(name: "SeedFlip Glacier", side: .light),
    BundledTheme(name: "SeedFlip Inkwell", side: .dark),
    BundledTheme(name: "SeedFlip Ivory", side: .light),
    BundledTheme(name: "SeedFlip Nightfall", side: .dark),
    BundledTheme(name: "SeedFlip Phosphor", side: .dark),
    BundledTheme(name: "SeedFlip Pulse", side: .dark),
    BundledTheme(name: "SeedFlip Ultraviolet", side: .dark),
    BundledTheme(name: "SeedFlip Wavelength", side: .dark),
    BundledTheme(name: "Selenized Black", side: .dark),
    BundledTheme(name: "Selenized Dark", side: .dark),
    BundledTheme(name: "Selenized Light", side: .light),
    BundledTheme(name: "Seoulbones Dark", side: .dark),
    BundledTheme(name: "Seoulbones Light", side: .light),
    BundledTheme(name: "Sequoia Monochrome Dark", side: .dark),
    BundledTheme(name: "Sequoia Monochrome Light", side: .light),
    BundledTheme(name: "Sequoia Moonlight Dark", side: .dark),
    BundledTheme(name: "Sequoia Moonlight Light", side: .light),
    BundledTheme(name: "Sequoia Retro Dark", side: .dark),
    BundledTheme(name: "Sequoia Retro Light", side: .light),
    BundledTheme(name: "Serendipity Midnight", side: .dark),
    BundledTheme(name: "Serendipity Morning", side: .light),
    BundledTheme(name: "Serendipity Sunset", side: .dark),
    BundledTheme(name: "Seti", side: .dark),
    BundledTheme(name: "Shades Of Purple", side: .dark),
    BundledTheme(name: "Shokunin", side: .light),
    BundledTheme(name: "Sierra Gold", side: .dark),
    BundledTheme(name: "Signal Ghost", side: .dark),
    BundledTheme(name: "Silent Empire", side: .dark),
    BundledTheme(name: "SilkCircuit Dawn", side: .light),
    BundledTheme(name: "SilkCircuit Glow", side: .dark),
    BundledTheme(name: "SilkCircuit Neon", side: .dark),
    BundledTheme(name: "SilkCircuit Soft", side: .dark),
    BundledTheme(name: "SilkCircuit Vibrant", side: .dark),
    BundledTheme(name: "Slate", side: .dark),
    BundledTheme(name: "Sleepy Hollow", side: .dark),
    BundledTheme(name: "SLOMP", side: .dark),
    BundledTheme(name: "Smoke on the Terminal", side: .dark),
    BundledTheme(name: "Smyck", side: .dark),
    BundledTheme(name: "Snazzy", side: .dark),
    BundledTheme(name: "Snazzy Soft", side: .dark),
    BundledTheme(name: "Soft Server", side: .dark),
    BundledTheme(name: "Solar Flare", side: .light),
    BundledTheme(name: "Solarized Darcula", side: .dark),
    BundledTheme(name: "Solarized Dark Higher Contrast", side: .dark),
    BundledTheme(name: "Sonokai", side: .dark),
    BundledTheme(name: "Sonoran Afterglow", side: .dark),
    BundledTheme(name: "Sonoran Blue Hour", side: .dark),
    BundledTheme(name: "Sonoran Dusk", side: .dark),
    BundledTheme(name: "Spacedust", side: .dark),
    BundledTheme(name: "Spacegray", side: .dark),
    BundledTheme(name: "Spacegray Bright", side: .dark),
    BundledTheme(name: "Spacegray Eighties", side: .dark),
    BundledTheme(name: "Spacegray Eighties Dull", side: .dark),
    BundledTheme(name: "Spiderman", side: .dark),
    BundledTheme(name: "Spring", side: .light),
    BundledTheme(name: "Springfield Resident", side: .light),
    BundledTheme(name: "Springfield Resident Hight Contrast", side: .light),
    BundledTheme(name: "Square", side: .dark),
    BundledTheme(name: "Squintless", side: .light),
    BundledTheme(name: "Squirrelsong Dark", side: .dark),
    BundledTheme(name: "Srcery", side: .dark),
    BundledTheme(name: "Stairway Skies", side: .dark),
    BundledTheme(name: "Stardust Voltage", side: .light),
    BundledTheme(name: "Starlight", side: .dark),
    BundledTheme(name: "Static Memory", side: .light),
    BundledTheme(name: "Static Noir", side: .dark),
    BundledTheme(name: "Sublette", side: .dark),
    BundledTheme(name: "Subliminal", side: .dark),
    BundledTheme(name: "Sugarplum", side: .dark),
    BundledTheme(name: "Sumi Ink", side: .dark),
    BundledTheme(name: "Sumi Linen", side: .light),
    BundledTheme(name: "Sumi Phosphor", side: .dark),
    BundledTheme(name: "Sun Bleached", side: .light),
    BundledTheme(name: "Sundried", side: .dark),
    BundledTheme(name: "Sunset Copper Relay", side: .dark),
    BundledTheme(name: "Sunset Drive", side: .dark),
    BundledTheme(name: "Sunset Strip", side: .dark),
    BundledTheme(name: "Sweet Emotion", side: .dark),
    BundledTheme(name: "Symfonic", side: .dark),
    BundledTheme(name: "Syncopation", side: .dark),
    BundledTheme(name: "Synthwave", side: .dark),
    BundledTheme(name: "Synthwave Alpha", side: .dark),
    BundledTheme(name: "Synthwave Everything", side: .dark),
    BundledTheme(name: "Tailwind Dark", side: .dark),
    BundledTheme(name: "Tailwind Light", side: .light),
    BundledTheme(name: "Tango Adapted", side: .light),
    BundledTheme(name: "Tango Half Adapted", side: .light),
    BundledTheme(name: "Tearout", side: .dark),
    BundledTheme(name: "Teerb", side: .dark),
    BundledTheme(name: "Terafox", side: .dark),
    BundledTheme(name: "Terminal Green 1999", side: .dark),
    BundledTheme(name: "Thayer Bright", side: .dark),
    BundledTheme(name: "The Fog", side: .dark),
    BundledTheme(name: "The Hulk", side: .dark),
    BundledTheme(name: "Thirteen", side: .dark),
    BundledTheme(name: "This One Goes to 11", side: .dark),
    BundledTheme(name: "Tinacious Design Dark", side: .dark),
    BundledTheme(name: "Tinacious Design Light", side: .light),
    BundledTheme(name: "Token Dark", side: .dark),
    BundledTheme(name: "Token Light", side: .light),
    BundledTheme(name: "TokyoNight Day", side: .light),
    BundledTheme(name: "TokyoNight Moon", side: .dark),
    BundledTheme(name: "TokyoNight Night", side: .dark),
    BundledTheme(name: "TokyoNight Storm", side: .dark),
    BundledTheme(name: "Tomorrow", side: .light),
    BundledTheme(name: "Tomorrow Night", side: .dark),
    BundledTheme(name: "Tomorrow Night Blue", side: .dark),
    BundledTheme(name: "Tomorrow Night Bright", side: .dark),
    BundledTheme(name: "Tomorrow Night Burns", side: .dark),
    BundledTheme(name: "Tomorrow Night Eighties", side: .dark),
    BundledTheme(name: "Toy Chest", side: .dark),
    BundledTheme(name: "traffic", side: .dark),
    BundledTheme(name: "Trapped in Amber", side: .dark),
    BundledTheme(name: "Trick or Treat", side: .dark),
    BundledTheme(name: "Tumbling Stones", side: .dark),
    BundledTheme(name: "Turquoise Trail", side: .dark),
    BundledTheme(name: "Twilight", side: .dark),
    BundledTheme(name: "Ubuntu", side: .dark),
    BundledTheme(name: "Ultra Dark", side: .dark),
    BundledTheme(name: "Ultra Violent", side: .dark),
    BundledTheme(name: "Unalive 'Em All", side: .dark),
    BundledTheme(name: "Undead", side: .dark),
    BundledTheme(name: "Under The Sea", side: .dark),
    BundledTheme(name: "Unikitty", side: .light),
    BundledTheme(name: "urban", side: .dark),
    BundledTheme(name: "Vacuum Tube", side: .dark),
    BundledTheme(name: "Vague", side: .dark),
    BundledTheme(name: "Vaporwave Sunset", side: .dark),
    BundledTheme(name: "Vaughn", side: .dark),
    BundledTheme(name: "Velvet Court", side: .dark),
    BundledTheme(name: "Vercel", side: .dark),
    BundledTheme(name: "Vercel Light", side: .light),
    BundledTheme(name: "Verdigris", side: .dark),
    BundledTheme(name: "Vesper", side: .dark),
    BundledTheme(name: "Vibrant Ink", side: .dark),
    BundledTheme(name: "Vimbones", side: .light),
    BundledTheme(name: "Violet Light", side: .light),
    BundledTheme(name: "Violite", side: .dark),
    BundledTheme(name: "Warm Burnout Dark", side: .dark),
    BundledTheme(name: "Warm Burnout Light", side: .light),
    BundledTheme(name: "Warm Neon", side: .dark),
    BundledTheme(name: "Wasteland Terminal", side: .dark),
    BundledTheme(name: "Whimsy", side: .dark),
    BundledTheme(name: "White Sands", side: .light),
    BundledTheme(name: "Wild Charm Dark", side: .dark),
    BundledTheme(name: "Wild Charm Light", side: .light),
    BundledTheme(name: "Wild Cherry", side: .dark),
    BundledTheme(name: "Willow Grove", side: .light),
    BundledTheme(name: "Wilmersdorf", side: .dark),
    BundledTheme(name: "Witches' Brew", side: .dark),
    BundledTheme(name: "Witching Hour", side: .dark),
    BundledTheme(name: "Wombat", side: .dark),
    BundledTheme(name: "Workroom", side: .dark),
    BundledTheme(name: "Workroom Light", side: .light),
    BundledTheme(name: "Wryan", side: .dark),
    BundledTheme(name: "X", side: .dark),
    BundledTheme(name: "X Berlin", side: .dark),
    BundledTheme(name: "X Bogota", side: .dark),
    BundledTheme(name: "X Helsinki", side: .light),
    BundledTheme(name: "X Lahabana", side: .dark),
    BundledTheme(name: "X London", side: .light),
    BundledTheme(name: "X Madrid", side: .light),
    BundledTheme(name: "X Miami", side: .dark),
    BundledTheme(name: "X Paris", side: .dark),
    BundledTheme(name: "X Praha", side: .dark),
    BundledTheme(name: "X Tokio", side: .dark),
    BundledTheme(name: "Xcode Dark", side: .dark),
    BundledTheme(name: "Xcode Dark hc", side: .dark),
    BundledTheme(name: "Xcode Light", side: .light),
    BundledTheme(name: "Xcode Light hc", side: .light),
    BundledTheme(name: "Xcode WWDC", side: .dark),
    BundledTheme(name: "Y2K Chrome", side: .light),
    BundledTheme(name: "Yngwie's Strat", side: .light),
    BundledTheme(name: "Zacess Cream", side: .light),
    BundledTheme(name: "Zacess Dark", side: .dark),
    BundledTheme(name: "Zacess Deep Contrast Dark", side: .dark),
    BundledTheme(name: "Zacess Deep Contrast Light", side: .light),
    BundledTheme(name: "Zacess High Contrast Dark", side: .dark),
    BundledTheme(name: "Zacess High Contrast Light", side: .light),
    BundledTheme(name: "Zacess Light", side: .light),
    BundledTheme(name: "Zacess Warm Dark", side: .dark),
    BundledTheme(name: "Zacess Warm Light", side: .light),
    BundledTheme(name: "Zacess Yellow on Black", side: .dark),
    BundledTheme(name: "Zenbones Dark", side: .dark),
    BundledTheme(name: "Zenbones Light", side: .light),
    BundledTheme(name: "Zenburn", side: .dark),
    BundledTheme(name: "Zenburned", side: .dark),
    BundledTheme(name: "Zenwritten Dark", side: .dark),
    BundledTheme(name: "Zenwritten Light", side: .light),
  ]

  private static let bundledSides: [String: ThemeSide] = Dictionary(
    bundledThemes.map { ($0.name, $0.side) }, uniquingKeysWith: { first, _ in first })

  /// The side the theme called `name` is on, resolved the way `themePreview` resolves its colours: the
  /// user's own file in `~/.config/ghostty/themes` first, classified by its background, then the
  /// bundled theme's fixed side. Nil when neither exists, or the user's file doesn't parse and no
  /// bundled theme has that name.
  public static func side(ofThemeNamed name: String) -> ThemeSide? {
    let userPath = userThemeDirectory() + "/" + name
    if FileManager.default.fileExists(atPath: userPath),
      let theme = parseThemeFile(atPath: userPath, name: name)
    {
      return ThemeSide(background: theme.background)
    }
    return bundledSides[name]
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
    let userPath = userThemeDirectory() + "/" + name
    if FileManager.default.fileExists(atPath: userPath),
      let theme = parseThemeFile(atPath: userPath, name: name)
    {
      return theme
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
  /// nil. **UI-test fixture only**: a fixture launch can't scope the override to a closure the way a
  /// unit test does (`withUserThemeDirectory`), and must never read the owner's real theme files.
  public static func setUserThemeDirectoryForUITesting(_ path: String?) {
    userThemeDirectoryOverride.withLock { $0 = path }
  }

  // MARK: The Light and Dark lists (#737)

  /// The themes on `side`, as the Light and Dark lists show them: the bundled themes on that side
  /// plus the user's own, Workroom's theme for the side first and the rest A→Z (case-insensitive,
  /// numeric, locale-independent for the same reason as `families`).
  ///
  /// The user's themes are read from `userThemeDirectory()` on every call, so a list reflects the
  /// folder as it is when it loads. Each is classified by its background (`ThemeSide(background:)`),
  /// and one that doesn't parse is left out. One named like a bundled theme replaces it: listed once,
  /// as the user's, on the side its own background gives it, so a dark file called `Ayu Light` moves
  /// to the Dark list. An unparseable one replaces nothing, so the bundled theme stays.
  public static func themes(on side: ThemeSide) -> [ListedTheme] {
    let users = userThemes()
    let userNames = Set(users.map(\.name))
    let bundled = bundledThemes.filter { $0.side == side && !userNames.contains($0.name) }
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
  /// and whose dark theme resolves to the dark side (`side(ofThemeNamed:)`, so a user's replacement
  /// is judged by its own background). A family is unavailable while a replacement puts either of
  /// its themes on the wrong side, so choosing a family never puts a dark theme in the light setting.
  /// `families` order is kept.
  public static func availableFamilies() -> [ThemeFamily] {
    families.filter {
      side(ofThemeNamed: $0.light) == .light && side(ofThemeNamed: $0.dark) == .dark
    }
  }

  /// Every parseable theme file in the user's theme directory, classified by its background. Hidden
  /// files and directories are skipped; user themes never form families.
  private static func userThemes() -> [ListedTheme] {
    let dir = userThemeDirectory()
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return entries.compactMap { name in
      guard !name.hasPrefix(".") else { return nil }
      let path = dir + "/" + name
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        let theme = parseThemeFile(atPath: path, name: name)
      else { return nil }
      return ListedTheme(
        name: name, side: ThemeSide(background: theme.background), isUserTheme: true)
    }
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
  /// practice, since a lookup only diverges for a name that exists in `path`.
  public static func withUserThemeDirectory<T>(_ path: String, _ body: () throws -> T) rethrows
    -> T
  {
    userThemeDirectoryOverride.withLock { $0 = path }
    defer { userThemeDirectoryOverride.withLock { $0 = nil } }
    return try body()
  }

  // MARK: Theme-file parser (ported from muxy — pure)

  public static func parseThemeFile(atPath path: String, name: String) -> ThemePreview? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var bg: NSColor?
    var fg: NSColor?
    var palette: [Int: NSColor] = [:]
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("background"), !trimmed.hasPrefix("background-") {
        bg = extractColor(from: trimmed)
      } else if trimmed.hasPrefix("foreground"), !trimmed.hasPrefix("foreground-") {
        fg = extractColor(from: trimmed)
      } else if trimmed.hasPrefix("palette") {
        parsePaletteEntry(trimmed, into: &palette)
      }
    }
    guard let bg, let fg else { return nil }
    let sorted = (0..<16).compactMap { palette[$0] }
    return ThemePreview(name: name, background: bg, foreground: fg, palette: sorted)
  }

  private static func parsePaletteEntry(
    _ line: String, into palette: inout [Int: NSColor]
  ) {
    guard let eq = line.firstIndex(of: "=") else { return }
    let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    guard let eq2 = value.firstIndex(of: "="), let index = Int(value[..<eq2]),
      (0..<16).contains(index),
      let color = parseHex(String(value[value.index(after: eq2)...]))
    else { return }
    palette[index] = color
  }

  private static func extractColor(from line: String) -> NSColor? {
    guard let eq = line.firstIndex(of: "=") else { return nil }
    return parseHex(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
  }

  public static func parseHex(_ hex: String) -> NSColor? {
    var h = hex
    if h.hasPrefix("#") { h = String(h.dropFirst()) }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return NSColor(
      srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
      green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255,
      alpha: 1)
  }

  /// `parseHex`'s inverse: `color` as a theme file writes it, `#rrggbb` in sRGB, each component
  /// clamped and rounded to the nearest byte. Alpha is dropped.
  public static func hex(_ color: NSColor) -> String {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
    return String(
      format: "#%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent),
      byte(srgb.blueComponent))
  }
}
