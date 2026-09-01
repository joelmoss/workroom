import AppKit
import Foundation
import GhosttyKit
import Sentry
import os

/// Owns the single libghostty runtime (`ghostty_app_t`) for the whole app, plus the loaded
/// config. One app, many surfaces (each `GhosttySurfaceView` is one `ghostty_surface_t`); this
/// mirrors how Ghostty's own macOS app is structured.
///
/// Lifecycle contract (plan A1):
///   - `ghostty_app_tick` is the render/IO pump. libghostty calls `wakeup_cb` (possibly off the
///     main thread) when it has work; we **coalesce** those into a single main-queue tick.
///   - Surfaces are created/freed by `TerminalSessions`; `shutdown()` frees the app+config on quit
///     (individual surfaces are freed first by `TerminalSessions.reapAll`).
///   - All libghostty calls happen on the main thread.
///
/// Init is **fail-soft** (plan A2): if `ghostty_init`/`ghostty_app_new` fails or the bundled
/// resources are missing, `app` stays nil and `isReady` is false — the UI shows a placeholder
/// instead of crashing. Never `fatalError` here; this is the one engine the whole app depends on.
@MainActor
final class GhosttyApp {
  static let shared = GhosttyApp()

  /// The runtime handle, or nil if the engine failed to come up (see `isReady`).
  private(set) var app: ghostty_app_t?
  /// The active config (owned; freed on `shutdown` / replaced on `reloadConfig`).
  private(set) var config: ghostty_config_t?

  /// Absolute path to the bundled terminfo directory (set once resources resolve), or nil if the
  /// bundled `xterm-ghostty` entry is missing. Each surface injects it as `TERMINFO` into the shell's
  /// environment so the shell can resolve `xterm-ghostty` (see `GhosttySurfaceView.createSurface`).
  private(set) var terminfoDirectory: String?

  /// True once libghostty initialized successfully. Views/sessions check this to decide between
  /// a live terminal and the "engine unavailable" placeholder.
  var isReady: Bool { app != nil }

  private let logger = Logger(subsystem: "com.developwithstyle.workroom", category: "GhosttyApp")
  /// Coalescing flag for the tick pump — only ever touched on the main thread.
  private var tickPending = false
  /// The dark/light the generated config was last built for, so `reloadConfig` can no-op when the
  /// appearance hasn't actually changed (it's called per OS-appearance notification).
  private var lastConfiguredDark: Bool?
  /// NSApplication active/inactive observers that drive app-level focus (see `observeAppFocus`).
  private var appFocusObservers: [NSObjectProtocol] = []

  private init() {
    initialize()
  }

  // MARK: Init (fail-soft — A2)

  private func initialize() {
    guard resolveResources() else { return }  // logs + bails if resources missing

    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      reportStartupFailure("ghostty_init failed — terminals unavailable")
      return
    }

    guard let cfg = makeConfig() else {
      reportStartupFailure("ghostty_config_new failed — terminals unavailable")
      return
    }

    var rt = ghostty_runtime_config_s()
    rt.userdata = Unmanaged.passUnretained(self).toOpaque()
    // We service the system pasteboard ourselves (copy-on-select etc. live on the surface view),
    // so the X11-style selection clipboard is not supported.
    rt.supports_selection_clipboard = false
    // @convention(c) callbacks capture nothing — they route through the shared singleton.
    rt.wakeup_cb = { _ in GhosttyApp.shared.scheduleTick() }
    rt.action_cb = { app, target, action in
      GhosttyRuntimeAdapter.shared.handleAction(app: app, target: target, action: action)
    }
    rt.read_clipboard_cb = { userdata, location, state in
      GhosttyRuntimeAdapter.shared.readClipboard(
        userdata: userdata, location: location, state: state)
    }
    rt.confirm_read_clipboard_cb = { userdata, content, state, request in
      GhosttyRuntimeAdapter.shared.confirmReadClipboard(
        userdata: userdata, content: content, state: state, request: request)
    }
    rt.write_clipboard_cb = { userdata, location, content, count, confirm in
      GhosttyRuntimeAdapter.shared.writeClipboard(
        userdata: userdata, location: location, content: content, count: count, confirm: confirm)
    }
    rt.close_surface_cb = { userdata, needsConfirm in
      GhosttyRuntimeAdapter.shared.closeSurface(userdata: userdata, needsConfirm: needsConfirm)
    }

    guard let createdApp = ghostty_app_new(&rt, cfg) else {
      reportStartupFailure("ghostty_app_new failed — terminals unavailable")
      ghostty_config_free(cfg)
      return
    }

    app = createdApp
    config = cfg
    ghostty_app_set_color_scheme(createdApp, Self.currentColorScheme())
    // Tell libghostty the application's focus state, now and on every change. Real Ghostty's macOS
    // app drives this from NSApplication activation; we were missing it entirely — only per-surface
    // `ghostty_surface_set_focus` (from first-responder changes) was wired. The gap surfaces as a
    // terminal focus desync: a focus-tracking TUI (Claude Code, Codex) can end up stuck ignoring
    // navigation keys after the app/terminal loses and regains focus, while Ctrl-C (a tty signal,
    // focus-independent) still works. Keeping the app-level flag in sync is part of the embedding
    // contract and a prerequisite for correct DECSET 1004 (`CSI I`/`CSI O`) focus reporting.
    observeAppFocus(for: createdApp)
    let info = ghostty_info()
    logger.info("libghostty ready (build mode \(info.build_mode.rawValue), version available)")
  }

  // MARK: App-level focus (embedding contract)

  /// Set libghostty's initial app-focus and keep it in sync with NSApplication activation. Real
  /// Ghostty's macOS app does the same from `applicationDid{Become,Resign}Active`; the surface's
  /// per-focus `ghostty_surface_set_focus` (driven by first-responder changes) is not enough on its
  /// own — the app-level flag is what unblocks focus-event delivery.
  private func observeAppFocus(for app: ghostty_app_t) {
    ghostty_app_set_focus(app, NSApp.isActive)
    let center = NotificationCenter.default
    let onActive = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setAppFocus(true) }
    let onResign = center.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setAppFocus(false) }
    appFocusObservers = [onActive, onResign]
  }

  private func setAppFocus(_ focused: Bool) {
    guard let app else { return }
    ghostty_app_set_focus(app, focused)
  }

  /// Log a libghostty startup failure and report it to Sentry. The terminal engine is the app's
  /// core feature; when it fails to come up the app degrades to a placeholder rather than crashing
  /// (the fail-soft contract above), so the crash handler never sees these — a Sentry event is the
  /// only way we'd learn the engine broke in the field. The `os.Logger` line stays for local
  /// `log stream`/Console debugging; Sentry gets the same message at `level`.
  private func reportStartupFailure(_ message: String, level: SentryLevel = .error) {
    logger.error("\(message, privacy: .public)")
    SentrySDK.capture(message: message) { scope in scope.setLevel(level) }
  }

  /// Point `GHOSTTY_RESOURCES_DIR` at the bundled `ghostty/` tree (terminfo + shell-integration).
  /// Returns false (and logs) if the resources are missing — shell integration, the `xterm-ghostty`
  /// terminfo entry, and OSC-7 cwd reporting all depend on them. See Resources/ghostty/SOURCE.md.
  private func resolveResources() -> Bool {
    guard let resourcesURL = GhosttyResources.exportResourcesDir() else {
      reportStartupFailure("bundled ghostty resources not found — terminals unavailable")
      return false
    }

    // Resolve the bundled terminfo dir; each surface injects it as `TERMINFO` into the shell's env
    // (see `GhosttySurfaceView.createSurface`). libghostty sets `TERM=xterm-ghostty` but builds the
    // child environment itself — a plain process `setenv("TERMINFO", …)` does NOT reach the shell —
    // and macOS has no system `xterm-ghostty` entry, so without injecting it the shell can't resolve
    // the terminal's capabilities (e.g. `kbs`), which breaks line editing (notably Backspace).
    // Entries live under hex-named dirs (`terminfo/78/xterm-ghostty`, 0x78 = 'x').
    let terminfoURL = resourcesURL.appendingPathComponent("terminfo")
    if FileManager.default.fileExists(
      atPath: terminfoURL.appendingPathComponent("78/xterm-ghostty").path)
    {
      terminfoDirectory = terminfoURL.path
    } else {
      reportStartupFailure(
        "bundled xterm-ghostty terminfo missing — terminal line editing may misbehave",
        level: .warning)
    }
    return true
  }

  private func makeConfig() -> ghostty_config_t? {
    let dark = Self.isCurrentAppearanceDark()
    lastConfiguredDark = dark
    writeThemeConfig(dark: dark)
    return loadConfig()
  }

  // `internal` (not `private`) — see `writeThemeConfig` above; same testability reason.
  func loadConfig() -> ghostty_config_t? {
    guard let cfg = ghostty_config_new() else { return nil }
    themeConfigURL.path.withCString { ghostty_config_load_file(cfg, $0) }
    ghostty_config_finalize(cfg)
    return cfg
  }

  /// Rebuild the config for the current appearance and apply it app-wide (called on a light/dark
  /// change from `TerminalSessions.applyThemeToAll`). Individual surfaces are refreshed by the
  /// caller via `GhosttySurfaceView.updateConfig`.
  ///
  /// `force` rebuilds even when the appearance is unchanged — needed for a *same-appearance theme
  /// switch* (issue #36), where the active theme name changes but `dark` does not, so the plain
  /// appearance guard would skip the rebuild.
  func reloadConfig(force: Bool = false) {
    guard let app else { return }
    let dark = Self.isCurrentAppearanceDark()
    // Unchanged appearance and not forced → nothing to rebuild.
    guard force || dark != lastConfiguredDark else { return }
    lastConfiguredDark = dark
    writeThemeConfig(dark: dark)
    guard let newConfig = loadConfig() else { return }
    ghostty_app_update_config(app, newConfig)
    let old = config
    config = newConfig
    if let old { ghostty_config_free(old) }
  }

  // libghostty has no config setter API (only load-from-file), so Workroom's "blend into the native
  // window" look is expressed as a tiny generated config file whose `background`/`foreground` are the
  // macOS system colors resolved for the current appearance. New surfaces inherit the app config.
  private lazy var themeConfigURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("ghostty.conf")
  }()

  // `internal` (not `private`) so `GhosttyConfigMinimumContrastTests` can call it directly via
  // `@testable import` and assert on the real generated config, rather than re-duplicating its format.
  func writeThemeConfig(dark: Bool) {
    // The terminal's colours come from the active theme family's variant for this appearance
    // (issue #36). libghostty resolves `theme = "<name>"` from $GHOSTTY_RESOURCES_DIR/themes (and
    // ~/.config/ghostty/themes, which wins) — verified on the pinned GhosttyKit for new and live
    // surfaces. The name is already sanitised by ThemeService (safe to quote into the conf). The
    // padded region inherits the theme background, so the terminal still blends into the panel.
    //
    // `minimum-contrast` enforces a render-time WCAG contrast floor on terminal CONTENT (not just
    // chrome-matching padding): many bundled light themes, vendored as-is from iTerm2-Color-Schemes,
    // ship an ANSI bright-white (palette 15) at or near their own background — invisible bold/bright
    // text. `3.0` matches `ThemeTokens.legible`'s app-chrome floor (`ThemeTokens.swift:308`) by
    // convention/comment only, not a shared constant — terminal content and app chrome are different
    // subsystems that may need different floors later.
    let theme = ThemeService.activeThemeName(isDark: dark)
    let contents = """
      # Generated by Workroom — active theme for the current appearance. Do not edit.
      theme = "\(theme)"
      minimum-contrast = 3.0
      window-padding-x = 8
      window-padding-y = 8
      window-padding-balance = true
      """
    try? contents.write(to: themeConfigURL, atomically: true, encoding: .utf8)
  }

  // MARK: Tick pump (A1 — coalesced, main-thread)

  /// Called by `wakeup_cb`, possibly off the main thread. Hops to the main actor and coalesces
  /// bursts of wakeups into a single `ghostty_app_tick` per runloop turn.
  nonisolated func scheduleTick() {
    Task { @MainActor in GhosttyApp.shared.coalescedTick() }
  }

  private func coalescedTick() {
    guard !tickPending else { return }
    tickPending = true
    DispatchQueue.main.async { [self] in
      tickPending = false
      guard let app else { return }
      ghostty_app_tick(app)
    }
  }

  // MARK: Appearance

  func setColorScheme(dark: Bool) {
    guard let app else { return }
    ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
  }

  private static func currentColorScheme() -> ghostty_color_scheme_e {
    isCurrentAppearanceDark() ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
  }

  private static func isCurrentAppearanceDark() -> Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  // MARK: Teardown (A1 — on app quit, after surfaces are freed)

  func shutdown() {
    for observer in appFocusObservers { NotificationCenter.default.removeObserver(observer) }
    appFocusObservers.removeAll()
    if let app {
      ghostty_app_free(app)
      self.app = nil
    }
    if let config {
      ghostty_config_free(config)
      self.config = nil
    }
  }
}
