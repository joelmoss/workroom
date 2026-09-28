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
  /// Whether the current run of config-write failures has already been reported, so a persistent
  /// fault is one event and not one per attempt. Unlike every other `reportStartupFailure` caller
  /// this one sits on a RECURRING trigger: `reloadConfig` runs on each appearance change and on each
  /// theme apply, and `applyActiveTheme` defaults to `force: true` — so arrow-keying the theme
  /// picker with an unwritable config directory would capture one Sentry event per keypress. Reset
  /// on the next success, so a fault that comes back is reported again.
  private var reportedConfigWriteFailure = false
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
    rt.read_clipboard_cb = { userdata, location, state, mimes, mimeCount, wantsAvailable in
      GhosttyRuntimeAdapter.shared.readClipboard(
        userdata: userdata, location: location, state: state, mimes: mimes, mimeCount: mimeCount,
        wantsAvailable: wantsAvailable)
    }
    rt.confirm_read_clipboard_cb = { userdata, confirm, state, request in
      GhosttyRuntimeAdapter.shared.confirmReadClipboard(
        userdata: userdata, confirm: confirm, state: state, request: request)
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
    // The marker records what the engine actually LOADED, so only a successful write advances it —
    // see `reloadConfig`. Init stays fail-soft either way: a failed write leaves it nil, and the
    // first `reloadConfig` then rebuilds whatever `force` it was given.
    if writeThemeConfig(dark: dark) { lastConfiguredDark = dark }
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
  /// change from `ThemeService.applyActiveTheme`, once per apply — NOT once per window). Individual
  /// surfaces are refreshed by `TerminalSessions.applyThemeToAll` via `GhosttySurfaceView.updateConfig`.
  ///
  /// `force` rebuilds even when the appearance is unchanged — needed for a *same-appearance theme
  /// switch* (issue #36), where the active theme name changes but `dark` does not, so the plain
  /// appearance guard would skip the rebuild.
  ///
  /// `dark` comes FROM the caller rather than being re-derived here: `ThemeService`'s reading honours
  /// a forced light/dark preference, this type's `isCurrentAppearanceDark` only asks AppKit. Deriving
  /// it twice let the theme written into the conf disagree with the scheme pushed to the surfaces —
  /// they agreed only because `RootView.applyAppearance` happens to set `NSApp.appearance` first,
  /// which is an invariant held in another file.
  func reloadConfig(force: Bool = false, dark: Bool) {
    guard let app else { return }
    // Unchanged appearance and not forced → nothing to rebuild.
    guard force || dark != lastConfiguredDark else { return }
    // Both steps below only make sense on a file that was actually written. `ghostty_config_load_file`
    // returns `void` — the C API reports nothing for a file it could not read — so a failed write is
    // invisible from here down: the engine would finalize on libghostty's own defaults (no theme, no
    // contrast floor, no padding) and look like a successful reload. Bail instead and keep the config
    // already loaded, which is at worst one appearance stale rather than unthemed.
    //
    // The marker moves only on success, and only after it: setting it first recorded an INTENT, so a
    // silently-failed write was never retried by a later non-forced call for the same appearance.
    guard writeThemeConfig(dark: dark) else { return }
    lastConfiguredDark = dark
    guard let newConfig = loadConfig() else { return }
    ghostty_app_update_config(app, newConfig)
    let old = config
    config = newConfig
    if let old { ghostty_config_free(old) }
  }

  // libghostty has no config setter API (only load-from-file), so everything Workroom has to say to
  // the engine is said in a tiny generated config file: the active theme family's variant for the
  // current appearance, a contrast floor, and the padding that blends the terminal into the native
  // window (see `writeThemeConfig` for what each one is for). New surfaces inherit the app config.
  //
  // Resolved once, at init: nothing it depends on (the bundle id, the test signals, the fixture's
  // launch arguments) changes while the process runs. `internal` so a test can see which file the
  // live engine reads.
  let themeConfigURL = GhosttyApp.themeConfigURLForCurrentEnvironment()

  /// Where the generated config lives, **scoped by bundle id** — the convention
  /// `SessionStore.defaultURL` and `UnrecognizedToolUsage.defaultURL` already use.
  ///
  /// The scoping is not tidiness. `writeThemeConfig` and `loadConfig` are two steps, and each build
  /// identity (Workroom, Workroom Nightly, Workroom Dev) keeps its own theme preference; while they
  /// all shared one `Workroom/ghostty.conf`, an identity that wrote between another's two steps
  /// handed it the wrong theme. That old file is left alone: nothing in this build reads it, and an
  /// older build still running beside this one writes it before each of its own loads, so deleting
  /// it could only race that build.
  ///
  /// A missing bundle id falls back to an obviously-scoped name rather than the release id, for
  /// `UnrecognizedToolUsage.defaultURL`'s reason: a stray process must not land on the shipped
  /// app's file.
  nonisolated static func defaultThemeConfigURL(
    bundleID: String? = Bundle.main.bundleIdentifier,
    fileManager: FileManager = .default
  ) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(bundleID ?? "unknown-bundle", isDirectory: true)
      .appendingPathComponent("ghostty.conf")
  }

  /// The generated config THIS process uses: `defaultThemeConfigURL()`, except under test.
  ///
  /// - A fixture launch that names a file (`-WorkroomUITestGhosttyConfigFile`) uses that file, so
  ///   the sandboxed XCUITest runner reads exactly what this launch wrote (`ThemePickerUITests`).
  /// - Any other test process gets a file of its own, named for its pid. That is every process
  ///   `UserDefaults.app` isolates, by the same three signals: a hosted unit run, a fixture launch
  ///   that named no file, and a launch that only isolates its preferences
  ///   (`WorkroomWorkflowUITests`' real-bootstrap smoke test). The bundle id cannot separate these:
  ///   the unit suite's host IS `Workroom Dev`, so every parallel `make app-test` worker (one host
  ///   process each) and the developer's own running Dev app would otherwise be back on one file.
  ///   A reused pid inherits nothing, because every load follows this process's own write.
  ///
  /// Both redirects are `#if DEBUG`, like `UserDefaults.app`'s: a shipped build always uses the
  /// bundle-scoped file. The parameters default to the real signals so tests can pin each branch
  /// without writing a fixture key into the defaults domain that parallel workers share.
  nonisolated static func themeConfigURLForCurrentEnvironment(
    fixturePath: String? = UITestFixture.ghosttyConfigFilePath,
    underTest: Bool = UITestFixture.isTestProcess
  ) -> URL {
    #if DEBUG
      if let fixturePath { return URL(fileURLWithPath: fixturePath) }
      if underTest {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
          "\(testConfigPrefix)\(ProcessInfo.processInfo.processIdentifier).conf")
        pruneDeadTestConfigs(keeping: url)
        return url
      }
    #endif
    return defaultThemeConfigURL()
  }

  #if DEBUG
    /// Names the per-process files above so `pruneDeadTestConfigs` can find its own and nothing else.
    nonisolated private static let testConfigPrefix = "workroom-tests-ghostty-"

    /// Delete the per-process configs left by test runs whose process is gone, so per-pid naming does
    /// not accumulate a file per run — the same sweep, and the same live-pid guard, as
    /// `UserDefaults.app`'s `pruneDeadSuites`. A pid that is still alive is skipped: that file belongs
    /// to a worker running right now, and deleting it would be the very race the naming avoids.
    ///
    /// Called from the resolver that mints the name, where `DefaultsSuite` prunes too. `removeItem`
    /// directly, unlike the suites: no `cfprefsd` owns these, they are plain files we wrote.
    nonisolated private static func pruneDeadTestConfigs(keeping current: URL) {
      let directory = current.deletingLastPathComponent()
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)
      else { return }
      for file in files where file.pathExtension == "conf" {
        let name = file.deletingPathExtension().lastPathComponent
        guard file != current, name.hasPrefix(testConfigPrefix),
          let pid = Int32(name.dropFirst(testConfigPrefix.count)),
          kill(pid, 0) != 0, errno == ESRCH
        else { continue }
        try? FileManager.default.removeItem(at: file)
      }
    }
  #endif

  // `internal` (not `private`) so `GhosttyConfigMinimumContrastTests` can call it directly via
  // `@testable import` and assert on the real generated config, rather than re-duplicating its format.
  /// Returns whether the file is now on disk. Callers that go on to `loadConfig` must check it: the
  /// engine cannot (`ghostty_config_load_file` returns `void`), so this is the only place a failed
  /// write is still observable.
  @discardableResult
  func writeThemeConfig(dark: Bool) -> Bool {
    let written = Self.writeThemeConfig(
      theme: ThemeService.activeThemeName(isDark: dark), to: themeConfigURL)
    if written {
      reportedConfigWriteFailure = false
    } else if !reportedConfigWriteFailure {
      // Fail-soft like the rest of init (plan A2), but no longer silent. Before this the terminal
      // simply came up unthemed, with no contrast floor and no padding, and nothing anywhere said so.
      // Latched — see `reportedConfigWriteFailure` for why this caller, alone, needs that.
      reportedConfigWriteFailure = true
      // What the failure costs depends on whether the engine has a config yet. At launch
      // (`makeConfig`, before `config` is set) the load goes ahead and reads whatever the file last
      // held — libghostty's defaults only if it never existed. A reload (`reloadConfig`) bails and
      // keeps the config already loaded, so the terminals stay on their previous theme. Saying
      // "defaults" for both sent a stale theme looking for a missing one.
      let consequence =
        config == nil
        ? "terminals start on whatever that file last held, or on libghostty's defaults (no "
          + "theme, no contrast floor, no padding) if it never existed"
        : "terminals keep the config already loaded, so this theme or appearance change does not "
          + "reach them"
      reportStartupFailure(
        "could not write the generated terminal config at \(themeConfigURL.path) — \(consequence)",
        level: .warning)
    }
    return written
  }

  /// The write itself, apart from the `Defaults` lookup, so `GhosttyConfigLocationTests` can write
  /// two identities' files side by side through the production path. Returns false if the directory
  /// could not be created or the file could not be written; the instance overload above is what logs.
  @discardableResult
  nonisolated static func writeThemeConfig(theme: String, to url: URL) -> Bool {
    // The terminal's colours come from the active theme family's variant for this appearance
    // (issue #36). libghostty resolves `theme = "<name>"` from $GHOSTTY_RESOURCES_DIR/themes (and
    // ~/.config/ghostty/themes, which wins) — verified on the pinned GhosttyKit for new and live
    // surfaces. The name is sanitised here (safe to quote into the conf) even though
    // `activeThemeName` already did it, so no caller of this entry point can quote a newline in.
    // The padded region inherits the theme background, so the terminal still blends into the panel.
    //
    // `minimum-contrast` enforces a render-time WCAG contrast floor on terminal CONTENT (not just
    // chrome-matching padding): many bundled light themes, vendored as-is from iTerm2-Color-Schemes,
    // ship an ANSI bright-white (palette 15) at or near their own background — invisible bold/bright
    // text. `3.0` matches `ThemeTokens.legible`'s app-chrome floor (`ThemeTokens.swift:308`) by
    // convention/comment only, not a shared constant — terminal content and app chrome are different
    // subsystems that may need different floors later.
    let contents = """
      # Generated by Workroom — active theme for the current appearance. Do not edit.
      theme = "\(ThemeService.sanitizedThemeName(theme))"
      minimum-contrast = 3.0
      window-padding-x = 8
      window-padding-y = 8
      window-padding-balance = true
      """
    // `write(atomically:)` does not create intermediate directories, and the bundle-id directory
    // doesn't exist on a first run — `SessionStore.persist` takes the same step for the same
    // reason. Either step can fail for real (a full disk, an unwritable Application Support, a
    // stray plain file where the `<bundle id>/` directory belongs), and this diff's extra directory
    // level adds one more way, so the outcome is reported rather than dropped.
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
      return true
    } catch {
      return false
    }
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
