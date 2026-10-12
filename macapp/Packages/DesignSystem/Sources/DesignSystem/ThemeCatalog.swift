import AppKit
import Foundation
import Synchronization

/// A named theme **family** that bundles a dark and a light variant (issue #36: every theme must
/// support both modes). The user picks one family; the active variant follows the appearance, so
/// "supports dark and light" holds by construction.
public struct ThemeFamily: Identifiable, Hashable, Sendable {
  public let name: String
  public let dark: String  // dark-variant theme-file name (resolved by ghostty + parsed for chrome)
  public let light: String  // light-variant theme-file name

  public var id: String { name }

  public func variant(isDark: Bool) -> String { isDark ? dark : light }

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

  /// The curated, pair-complete bundled families. Each variant name is a file in
  /// `Resources/ghostty/themes` (and resolvable by ghostty).
  ///
  /// **Order is authored, not computed:** `Workroom` is pinned first, then A→Z. A `sorted(...)` call
  /// here would make `testFamiliesAreAlphabeticalAfterTheDefault` vacuous — it would assert a
  /// property the initializer had just imposed — so the list is typed in its final display order and
  /// the test compares it against `compare(options: [.caseInsensitive, .numeric])`. That comparator
  /// is deliberately NOT `localizedStandardCompare`: a locale-sensitive collation would make the
  /// picker's row order vary by system language and the assertion unpinnable.
  ///
  /// **Inclusion criteria** (see `Resources/ghostty/themes/SOURCE.md`): a designed dark AND light
  /// variant (issue #36); clears every contrast floor in `SwitcherThemeSweepTests`; a distinct
  /// palette rather than a shade of one already here; serves a real user (a tool people use, a
  /// well-known scheme, or an accessibility need); and never another product's brand identity.
  ///
  /// Every file in the themes dir belongs to exactly one family — `ThemeServiceTests` pins that as
  /// exact set equality, so adding a file without registering it here fails the suite.
  public static let families: [ThemeFamily] = [
    ThemeFamily(name: "Workroom", dark: "Workroom", light: "Workroom Light"),
    ThemeFamily(name: "3024", dark: "3024 Night", light: "3024 Day"),
    ThemeFamily(name: "Aizen", dark: "Aizen Dark", light: "Aizen Light"),
    ThemeFamily(
      name: "Apple System Colors", dark: "Apple System Colors",
      light: "Apple System Colors Light"),
    ThemeFamily(name: "Atom One", dark: "Atom One Dark", light: "Atom One Light"),
    ThemeFamily(name: "Ayu", dark: "Ayu Mirage", light: "Ayu Light"),
    ThemeFamily(name: "Belafonte", dark: "Belafonte Night", light: "Belafonte Day"),
    ThemeFamily(name: "Bluloco", dark: "Bluloco Dark", light: "Bluloco Light"),
    ThemeFamily(name: "Catppuccin", dark: "Catppuccin Mocha", light: "Catppuccin Latte"),
    ThemeFamily(name: "Claude", dark: "Claude Dark", light: "Claude Light"),
    ThemeFamily(name: "Clear", dark: "Clear Dark", light: "Clear Light"),
    ThemeFamily(name: "Cursor", dark: "Cursor Dark", light: "Cursor Light"),
    ThemeFamily(name: "Duskfox", dark: "Duskfox", light: "Dawnfox"),
    ThemeFamily(
      name: "Electron Highlighter", dark: "Electron Highlighter",
      light: "Electron Highlighter Day"),
    ThemeFamily(name: "Everforest", dark: "Everforest Dark Hard", light: "Everforest Light Med"),
    ThemeFamily(name: "Farmhouse", dark: "Farmhouse Dark", light: "Farmhouse Light"),
    ThemeFamily(name: "Flexoki", dark: "Flexoki Dark", light: "Flexoki Light"),
    ThemeFamily(name: "GitHub", dark: "GitHub Dark", light: "GitHub Light Default"),
    ThemeFamily(
      name: "GitHub High Contrast", dark: "GitHub Dark High Contrast",
      light: "GitHub Light High Contrast"),
    ThemeFamily(name: "GitLab", dark: "GitLab Dark", light: "GitLab Light"),
    ThemeFamily(name: "Gruvbox", dark: "Gruvbox Dark", light: "Gruvbox Light"),
    ThemeFamily(
      name: "Gruvbox Material", dark: "Gruvbox Material Dark", light: "Gruvbox Material Light"),
    ThemeFamily(name: "Iceberg", dark: "Iceberg Dark", light: "Iceberg Light"),
    ThemeFamily(name: "Kanagawa", dark: "Kanagawa Wave", light: "Kanagawa Lotus"),
    ThemeFamily(name: "Kanso", dark: "Kanso Zen", light: "Kanso Pearl"),
    ThemeFamily(name: "Karma", dark: "Karma Dark", light: "Karma Light"),
    ThemeFamily(name: "Material", dark: "Material Dark", light: "Material"),
    ThemeFamily(name: "Melange", dark: "Melange Dark", light: "Melange Light"),
    ThemeFamily(name: "Modus", dark: "Modus Vivendi", light: "Modus Operandi"),
    ThemeFamily(name: "Monokai Pro", dark: "Monokai Pro", light: "Monokai Pro Light"),
    ThemeFamily(name: "Monospace", dark: "Monospace Dark", light: "Monospace Light"),
    ThemeFamily(name: "Neobones", dark: "Neobones Dark", light: "Neobones Light"),
    ThemeFamily(name: "Night Owl", dark: "Night Owl", light: "Light Owl"),
    ThemeFamily(name: "Nightfox", dark: "Nightfox", light: "Dayfox"),
    ThemeFamily(
      name: "No Clown Fiesta", dark: "No Clown Fiesta", light: "No Clown Fiesta Light"),
    ThemeFamily(name: "Nord", dark: "Nord", light: "Nord Light"),
    ThemeFamily(name: "Nvim", dark: "Nvim Dark", light: "Nvim Light"),
    ThemeFamily(name: "One Half", dark: "One Half Dark", light: "One Half Light"),
    ThemeFamily(name: "Onenord", dark: "Onenord", light: "Onenord Light"),
    ThemeFamily(name: "Patina", dark: "Patina Dark", light: "Patina Light"),
    ThemeFamily(name: "Pencil", dark: "Pencil Dark", light: "Pencil Light"),
    ThemeFamily(name: "Pyrokai", dark: "Pyrokai", light: "Pyrokai Light"),
    ThemeFamily(name: "Raycast", dark: "Raycast Dark", light: "Raycast Light"),
    ThemeFamily(name: "Rosé Pine", dark: "Rose Pine", light: "Rose Pine Dawn"),
    ThemeFamily(name: "Selenized", dark: "Selenized Dark", light: "Selenized Light"),
    ThemeFamily(name: "Seoulbones", dark: "Seoulbones Dark", light: "Seoulbones Light"),
    ThemeFamily(
      name: "Sequoia Monochrome", dark: "Sequoia Monochrome Dark",
      light: "Sequoia Monochrome Light"),
    ThemeFamily(
      name: "Sequoia Moonlight", dark: "Sequoia Moonlight Dark",
      light: "Sequoia Moonlight Light"),
    ThemeFamily(
      name: "Sequoia Retro", dark: "Sequoia Retro Dark", light: "Sequoia Retro Light"),
    ThemeFamily(name: "Solarized", dark: "iTerm2 Solarized Dark", light: "iTerm2 Solarized Light"),
    ThemeFamily(
      name: "Tinacious Design", dark: "Tinacious Design Dark", light: "Tinacious Design Light"),
    ThemeFamily(name: "Token", dark: "Token Dark", light: "Token Light"),
    ThemeFamily(name: "Tokyo Night", dark: "TokyoNight Night", light: "TokyoNight Day"),
    ThemeFamily(name: "Tomorrow", dark: "Tomorrow Night", light: "Tomorrow"),
    ThemeFamily(name: "Xcode", dark: "Xcode Dark", light: "Xcode Light"),
    ThemeFamily(name: "Xcode High Contrast", dark: "Xcode Dark hc", light: "Xcode Light hc"),
    ThemeFamily(name: "Zenbones", dark: "Zenbones Dark", light: "Zenbones Light"),
    ThemeFamily(name: "Zenwritten", dark: "Zenwritten Dark", light: "Zenwritten Light"),
  ]

  public static func family(named name: String) -> ThemeFamily? {
    families.first { $0.name == name }
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
}
