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

  /// Monotonic counter bumped on every theme apply. Diff syntax highlighting keys its async
  /// recolour task on this (plus source+path) so a theme switch rebuilds the coloured lines and a
  /// result computed against the old theme is discarded as stale.
  private(set) var generation: Int = 0

  /// Every window's live terminal sessions (issue #70). Each window registers its `TerminalSessions`
  /// here so a theme change re-themes terminals in *all* windows — the old single `onApplyTerminals`
  /// callback was overwritten by the last window to appear, leaving other windows un-themed (OV #5).
  /// Weak, so a closed window drops out automatically. The surface iteration stays in
  /// `TerminalSessions`; `applyActiveTheme()` remains the single chokepoint every trigger routes through.
  private let terminalSinks = NSHashTable<TerminalSessions>.weakObjects()

  /// Register/unregister a window's terminal sessions for theme sweeps (issue #70).
  func registerTerminals(_ sessions: TerminalSessions) { terminalSinks.add(sessions) }
  func unregisterTerminals(_ sessions: TerminalSessions) { terminalSinks.remove(sessions) }

  /// The OS appearance flipped while pref = System. Owned HERE, not by each window's
  /// `TerminalSessions`: one observer per window meant a single flip fired the chokepoint N times,
  /// and each of those already swept all N windows' surfaces — N² surface re-configures for one
  /// keystroke (WORKROOM-3R). One owner, one sweep.
  private var appearanceObserver: NSObjectProtocol?

  /// `private` so `shared` stays the only instance. A second `ThemeService` would register a second
  /// permanent observer (nothing removes it — a process-lifetime singleton needs no `deinit`) and
  /// bring the N-observer stall straight back, with nothing to catch it.
  private init() {
    let isDark = Self.isCurrentAppearanceDark()
    tokens = ThemeTokens(preview: Self.themePreview(named: Self.activeThemeName(isDark: isDark)))
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [unowned self] _ in
      // A forced light/dark preference ignores the OS appearance (see `isCurrentAppearanceDark`),
      // so the whole apply — conf write, config parse, every surface reconfigured — would recompute
      // the values it already has. Only System follows the OS.
      guard Defaults[.theme] == .system else { return }
      // Route through the chokepoint so chrome tokens recompute (the active variant flips) alongside
      // the terminal re-theme (issue #36).
      Task { @MainActor in self.applyActiveTheme() }
    }
  }

  // MARK: Resolution (static — also called by GhosttyApp.writeThemeConfig without the instance)

  /// The active variant file name for an appearance: the selected family's variant for that mode,
  /// else the Workroom default. Always sanitised (safe to write into the conf).
  nonisolated static func activeThemeName(isDark: Bool) -> String {
    let resolved =
      ThemeCatalog.family(named: Defaults[.themeFamily])?.variant(isDark: isDark)
      ?? ThemeCatalog.family(named: ThemeCatalog.defaultFamilyName)!.variant(isDark: isDark)
    return ThemeCatalog.sanitizedThemeName(resolved)
  }

  // MARK: The chokepoint

  /// THE single apply path. Every trigger (picker selection, appearance change, first run) routes
  /// here. Steps: (1) validate the active name resolves — reset to Workroom if not, so terminal
  /// *and* chrome fall back to the *same* theme; (2) recompute chrome tokens; (3) re-theme live
  /// terminals (regenerates the conf with the new `theme=` and force-reloads); (4) notify AppKit
  /// sites that read `ThemeService.shared.tokens` outside SwiftUI.
  func applyActiveTheme(force: Bool = true) {
    validateSelection()
    let isDark = Self.isCurrentAppearanceDark()
    tokens = ThemeTokens(preview: Self.themePreview(named: Self.activeThemeName(isDark: isDark)))
    generation &+= 1
    // The app-global half runs ONCE here, not inside the per-window loop below — it used to live in
    // `applyThemeToAll`, so N windows meant N writes + N parses of the same generated ghostty.conf
    // (and the regex compilation each parse implies) on the main thread. WORKROOM-3R is that stall.
    GhosttyApp.shared.reloadConfig(force: force, dark: isDark)
    GhosttyApp.shared.setColorScheme(dark: isDark)
    for sessions in terminalSinks.allObjects { sessions.applyThemeToAll(isDark: isDark) }
    NotificationCenter.default.post(name: .themeDidChange, object: nil)
  }

  func applyFamily(_ name: String) {
    Defaults[.themeFamily] = name
    applyActiveTheme()
  }

  /// If the stored family no longer resolves (e.g. an old key references a renamed family), reset
  /// to the Workroom default so the terminal (ghostty) and chrome don't diverge onto different
  /// fallbacks.
  private func validateSelection() {
    if ThemeCatalog.family(named: Defaults[.themeFamily]) == nil {
      Defaults[.themeFamily] = ThemeCatalog.defaultFamilyName
    }
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

  /// `ThemeCatalog.themeDirectories` with this app's bundled themes.
  nonisolated static func themeDirectories() -> [String] {
    ThemeCatalog.themeDirectories(bundledDirectory: bundledThemeDirectory())
  }

  // MARK: Appearance

  static func isCurrentAppearanceDark() -> Bool {
    // Honour a forced ThemePreference; otherwise follow the OS effective appearance.
    switch Defaults[.theme] {
    case .light: return false
    case .dark: return true
    case .system:
      return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
  }
}

extension Notification.Name {
  /// Posted by `ThemeService.applyActiveTheme` after tokens + terminals are re-themed, so AppKit
  /// sites that read `ThemeService.shared.tokens` outside a SwiftUI body can refresh.
  static let themeDidChange = Notification.Name("workroom.themeDidChange")

  /// Posted by the `Theme…` (⌘⇧K) command; `TrailingTitlebarBar` toggles the dropdown anchored to its
  /// theme button (a menu command can't anchor a popover itself).
  static let showThemePicker = Notification.Name("workroom.showThemePicker")
}
