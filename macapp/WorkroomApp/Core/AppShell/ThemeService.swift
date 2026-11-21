import AppKit
import Defaults
import DesignSystem
import Foundation
import SwiftUI

@MainActor @Observable
final class ThemeService {
  static let shared = ThemeService()

  /// Current chrome tokens. Recomputed only inside `applyActiveTheme()`, so chrome never re-parses
  /// a theme file per frame. `@Observable` → SwiftUI views reading `tokens` repaint on change.
  private(set) var tokens: ThemeTokens
  /// The theme preview `tokens` was built from, so the terminal config's Glass contrast overrides
  /// (`GhosttyApp.writeThemeConfig`) reuse it rather than parse the theme again: a user theme is
  /// never cached, so each write would read it from disk.
  @ObservationIgnored private(set) var activePreview: ThemePreview?

  /// Monotonic counter bumped on every theme apply. Diff syntax highlighting keys its async
  /// recolour task on this (plus source+path) so a theme switch rebuilds the coloured lines and a
  /// result computed against the old theme is discarded as stale.
  private(set) var generation: Int = 0

  /// Every window's live terminal panes (issue #70). Each window registers its `TerminalPanes`
  /// here so a theme change re-themes terminals in *all* windows — the old single `onApplyTerminals`
  /// callback was overwritten by the last window to appear, leaving other windows un-themed (OV #5).
  /// Weak, so a closed window drops out automatically. The surface iteration stays in
  /// `TerminalPanes`; `applyActiveTheme()` remains the single chokepoint every trigger routes through.
  private let terminalSinks = NSHashTable<TerminalPanes>.weakObjects()

  /// Register/unregister a window's terminal panes for theme sweeps (issue #70).
  func registerTerminals(_ panes: TerminalPanes) { terminalSinks.add(panes) }
  func unregisterTerminals(_ panes: TerminalPanes) { terminalSinks.remove(panes) }

  /// The OS appearance flipped while pref = System. Owned HERE, not by each window's
  /// `TerminalPanes`: one observer per window meant a single flip fired the chokepoint N times,
  /// and each of those already swept all N windows' surfaces — N² surface re-configures for one
  /// keystroke (WORKROOM-3R). One owner, one sweep.
  private var appearanceObserver: NSObjectProtocol?

  /// `private` so `shared` stays the only instance. A second `ThemeService` would register a second
  /// permanent observer (nothing removes it — a process-lifetime singleton needs no `deinit`) and
  /// bring the N-observer stall straight back, with nothing to catch it.
  private init() {
    let preview = Self.activeTheme(for: Self.showingSide()).preview
    activePreview = preview
    tokens = ThemeTokens(preview: preview)
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [unowned self] _ in
      // A forced light/dark preference ignores the OS appearance (see `isCurrentAppearanceDark`),
      // so the whole apply — conf write, config parse, every surface reconfigured — would recompute
      // the values it already has. Only System follows the OS.
      guard Defaults[.appearance] == .system else { return }
      // Route through the chokepoint so chrome tokens recompute (the active variant flips) alongside
      // the terminal re-theme (issue #36).
      Task { @MainActor in self.applyActiveTheme() }
    }
  }

  // MARK: Resolution (static — also called by GhosttyApp.writeThemeConfig without the instance)

  /// The active theme's file name for an appearance (#733): the dark theme setting when the
  /// appearance is dark, else the light theme setting. Each side falls back on its own, to Workroom or
  /// Workroom Light, when its theme is missing or on the wrong side (a user's own file is judged by its
  /// background, as `ThemeCatalog.side(ofThemeNamed:)` does). The fallback is resolution only — the
  /// setting is kept, so a user theme file that is missing for a while comes back when it does — and
  /// the terminal and the chrome both resolve through here, so they never diverge onto different
  /// fallbacks. Always sanitised (safe to write into the conf).
  ///
  /// `userThemes` is the read of the user's theme files to resolve against; nil reads the two files
  /// this can need, the chosen theme's and the fallback's (`userThemesToResolve(for:)`).
  nonisolated static func activeThemeName(for side: ThemeSide, in userThemes: UserThemes? = nil)
    -> String
  {
    resolve(side, in: userThemes ?? userThemesToResolve(for: side)).name
  }

  /// The active theme's name for `side`, and whether it is the fallback rather than the setting.
  nonisolated private static func resolve(_ side: ThemeSide, in users: UserThemes)
    -> (name: String, isFallback: Bool)
  {
    let chosen = Defaults[.theme(for: side)]
    guard ThemeCatalog.side(ofThemeNamed: chosen, in: users) == side else {
      return (ThemeCatalog.defaultFamily.theme(for: side), true)
    }
    return (ThemeCatalog.sanitizedThemeName(chosen), false)
  }

  /// The user's theme files `side` can resolve to: the chosen theme's and Workroom's for that side.
  /// Only those two, so an apply never parses the whole folder.
  nonisolated static func userThemesToResolve(for side: ThemeSide) -> UserThemes {
    .reading(named: Defaults[.theme(for: side)], ThemeCatalog.defaultFamily.theme(for: side))
  }

  /// The side an appearance shows, with System following `systemIsDark`.
  nonisolated static func side(for appearance: AppearanceMode, systemIsDark: Bool) -> ThemeSide {
    switch appearance {
    case .light: return .light
    case .dark: return .dark
    case .system: return ThemeSide(isDark: systemIsDark)
    }
  }

  // MARK: Upgrade (#733)

  /// Carry the single-family settings across to the light and dark theme settings, once, at launch:
  /// the stored family's two themes become `lightTheme` and `darkTheme` (an unknown family becomes
  /// Workroom's), the old `themePreference` becomes `appearance`, and both old keys are deleted, which
  /// is what makes it run once. Each old key upgrades on its own, so someone who only ever changed the
  /// appearance keeps it. A fresh install stores nothing and reads the new keys' defaults: Workroom's
  /// two themes and System.
  ///
  /// An old key always wins over a new one. Presence can't be asked of the new keys anyway —
  /// `Defaults` registers each key's default, so `object(forKey:)` is never nil for them — and an old
  /// key alongside a new one means an older build ran since and wrote it, so it is the newer choice.
  ///
  /// Raw writes, because the old typed keys are gone and `defaults` need not be the keys' suite; the
  /// new keys' names come from the `Defaults` keys themselves. Every new key stores a plain string
  /// (`AppearanceMode` is `PreferRawRepresentable` with the same raw values), so the raw writes are
  /// what `Defaults` reads back.
  nonisolated static func upgradeThemeSettings(in defaults: UserDefaults = .app) {
    if let familyName = defaults.string(forKey: oldThemeFamilyKey) {
      let family = ThemeCatalog.family(named: familyName) ?? ThemeCatalog.defaultFamily
      for side in ThemeSide.allCases {
        defaults.set(family.theme(for: side), forKey: Defaults.Keys.theme(for: side).name)
      }
    }
    defaults.removeObject(forKey: oldThemeFamilyKey)

    if let raw = defaults.string(forKey: oldThemePreferenceKey),
      AppearanceMode(rawValue: raw) != nil
    {
      defaults.set(raw, forKey: Defaults.Keys.appearance.name)
    }
    defaults.removeObject(forKey: oldThemePreferenceKey)
  }

  /// The single theme family setting before #733, a family's name.
  nonisolated static let oldThemeFamilyKey = "themeFamily"
  /// The appearance setting before #733, an `AppearanceMode` raw value.
  nonisolated static let oldThemePreferenceKey = "themePreference"

  // MARK: The chokepoint

  /// THE single apply path. Every trigger (picker selection, appearance change, first run) routes
  /// here. Steps: (1) recompute chrome tokens from the active theme (`activeThemeName`, which also
  /// resolves the per-side fallback, so terminal *and* chrome fall back to the *same* theme);
  /// (2) re-theme live terminals (regenerates the conf with the new `theme=` and force-reloads);
  /// (3) notify AppKit sites that read `ThemeService.shared.tokens` outside SwiftUI.
  func applyActiveTheme(force: Bool = true) {
    let side = Self.showingSide()
    let isDark = side == .dark
    // Resolved once, against one read of the user's theme files, for the chrome and the terminal.
    let active = Self.activeTheme(for: side)
    activePreview = active.preview
    tokens = ThemeTokens(preview: active.preview)
    generation &+= 1
    // The app-global half runs ONCE here, not inside the per-window loop below — it used to live in
    // `applyThemeToAll`, so N windows meant N writes + N parses of the same generated ghostty.conf
    // (and the regex compilation each parse implies) on the main thread. WORKROOM-3R is that stall.
    GhosttyApp.shared.reloadConfig(force: force, dark: isDark, theme: active.configValue)
    GhosttyApp.shared.setColorScheme(dark: isDark)
    for sessions in terminalSinks.allObjects { sessions.applyThemeToAll(isDark: isDark) }
    NotificationCenter.default.post(name: .themeDidChange, object: nil)
  }

  /// Choose a theme family: set both the light theme and the dark theme, then apply once.
  func applyFamily(_ family: ThemeFamily) {
    apply(light: family.light, dark: family.dark)
  }

  /// Set the light theme and the dark theme, then apply once.
  func apply(light: String, dark: String) {
    Defaults[.lightTheme] = light
    Defaults[.darkTheme] = dark
    applyActiveTheme()
  }

  /// Choose one side's theme (#735): save it as the light theme or the dark theme, leaving the other
  /// side alone. Only the side that's showing repaints. Choosing the other side's theme saves it
  /// without touching the appearance, the generated config or the screen, so browsing it in the
  /// picker never flips what you're looking at; it shows the next time that side does.
  func apply(theme: String, for side: ThemeSide) {
    Defaults[.theme(for: side)] = theme
    guard side == Self.showingSide() else { return }
    applyActiveTheme()
  }

  // MARK: Resolution

  /// The bundled theme dir. Immutable for the process lifetime, which is what makes caching its parsed
  /// files correct rather than merely fast.
  nonisolated static func bundledThemeDirectory() -> String? {
    Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes").path
  }

  /// `ThemeCatalog.themePreview` against this app's bundled themes.
  nonisolated static func themePreview(named name: String) -> ThemePreview? {
    ThemeCatalog.themePreview(named: name, bundledDirectory: bundledThemeDirectory())
  }

  /// The active theme for `side`: its name (`activeThemeName(for:in:)`), its colours, and what the
  /// generated config's `theme =` line says, all resolved against one read of the user's theme files,
  /// so the chrome paints the file the terminal is told to load.
  struct ActiveTheme: Sendable {
    let name: String
    let preview: ThemePreview?
    let configValue: GhosttyApp.ThemeValue
  }

  /// The active theme for `side`. A fallback is always the bundled Workroom or Workroom Light, never a
  /// user file of that name: the config names the bundled file by its absolute path, so ghostty loads
  /// it rather than looking the name up in the user's theme directory first, and the chrome paints
  /// the same bundled file. Without that, a broken user file called `Workroom` would be the one ghostty
  /// loaded for the very theme the app falls back to.
  nonisolated static func activeTheme(for side: ThemeSide) -> ActiveTheme {
    let users = userThemesToResolve(for: side)
    let (name, isFallback) = resolve(side, in: users)
    let bundled = bundledThemeDirectory()
    guard isFallback else {
      return ActiveTheme(
        name: name,
        preview: ThemeCatalog.themePreview(named: name, bundledDirectory: bundled, in: users),
        configValue: .named(name))
    }
    return ActiveTheme(
      name: name,
      preview: ThemeCatalog.themePreview(named: name, bundledDirectory: bundled, in: .empty),
      configValue: bundled.map { .bundledFile($0 + "/" + name) } ?? .named(name))
  }

  /// `ThemeCatalog.themeDirectories` with this app's bundled themes.
  nonisolated static func themeDirectories() -> [String] {
    ThemeCatalog.themeDirectories(bundledDirectory: bundledThemeDirectory())
  }

  // MARK: Appearance

  static func isCurrentAppearanceDark() -> Bool {
    // Honour a forced AppearanceMode; otherwise follow the OS effective appearance.
    showingSide() == .dark
  }

  /// The side whose theme is on screen: dark while the appearance is dark, else light.
  static func showingSide() -> ThemeSide {
    side(
      for: Defaults[.appearance],
      systemIsDark: NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
  }
}

// MARK: The SwiftUI environment

/// Injects the live `ThemeService` tokens at a SwiftUI root, into DesignSystem's `\.themeTokens`
/// (whose default is the system palette, not the active theme). This body is the only place a
/// theme switch reaches SwiftUI: it reads the `@Observable` service, so it re-runs and re-injects
/// when the theme changes, and only then, since it holds nothing a parent's update could change.
struct ThemeTokensRoot: ViewModifier {
  func body(content: Content) -> some View {
    content.environment(\.themeTokens, ThemeService.shared.tokens)
  }
}

/// A root view with the theme injected, named so a typed `NSHostingView` can hold one.
typealias ThemeRooted<Root: View> = ModifiedContent<Root, ThemeTokensRoot>

extension View {
  /// Inject the live theme. Apply it at every SwiftUI root: the environment does not cross an
  /// `NSHostingView` or `NSHostingController`, so a hosted tree without it draws the system
  /// palette and never sees a switch.
  func themeTokensRoot() -> ThemeRooted<Self> { modifier(ThemeTokensRoot()) }
}

extension Notification.Name {
  /// Posted by `ThemeService.applyActiveTheme` after tokens + terminals are re-themed, so AppKit
  /// sites that read `ThemeService.shared.tokens` outside a SwiftUI body can refresh.
  static let themeDidChange = Notification.Name("workroom.themeDidChange")

  /// Posted by the `Theme…` (⌘⇧K) command; `TrailingTitlebarBar` toggles the dropdown anchored to its
  /// theme button (a menu command can't anchor a popover itself).
  static let showThemePicker = Notification.Name("workroom.showThemePicker")
}
