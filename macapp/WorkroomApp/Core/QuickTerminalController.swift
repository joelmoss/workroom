import AppKit

/// Marker type for the quick-terminal window so the `AppDelegate` key monitor can recognise it and
/// route ⌘W to close it. (The app rebinds ⌘W to a "Close Tab" menu command that targets the
/// main window's tabs and wins over a window's own `performKeyEquivalent`, so ⌘W is caught in the
/// monitor — the same mechanism the app already uses for ⌘R / ⌘1–9.)
final class QuickTerminalWindow: NSWindow {}

/// The "quick terminal" (issue #39): a login shell at `~/` in its own chrome-less window, summoned
/// by the ⌥§ global hotkey or the main-toolbar button. One persistent controller owns at most one
/// window + surface at a time:
///
/// ```
///   ABSENT  ──⌥§ / button──▶ VISIBLE      create window + a fresh ~/ surface, key + front + focused
///   VISIBLE ──⌥§───────────▶ HIDDEN       orderOut — surface kept alive (scrollback / process persist)
///   HIDDEN  ──⌥§ / button──▶ VISIBLE      order front, focus the SAME surface
///   VISIBLE/HIDDEN ──⌘W / red / shell exit──▶ ABSENT   tearDown surface, destroy window
/// ```
///
/// A toggle (`toggle()`, the hotkey) can hide; the button (`show()`) only ever brings the window
/// forward. After a full close the next summon is a brand-new terminal — no session resurrection.
///
/// AppKit `NSWindow` (not a SwiftUI scene) so we host the existing `GhosttySurfaceView` `NSView`
/// directly with exact chrome control — no project sidebar, terminal tabs, or inspector. The window
/// is themed to match the app (transparent titlebar over the panel background) and follows live
/// theme switches, which the store-driven `applyThemeToAll` never reaches (this surface isn't in
/// `store.terminals`).
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var surface: GhosttySurfaceView?
  private var themeObserver: NSObjectProtocol?
  /// Guards `tearDownState` against the re-entrancy of `window.close()` → `windowWillClose`.
  private var tearingDown = false

  /// Nonisolated so `AppDelegate` can construct it as a stored-property default (a nonisolated
  /// context); it only assigns nil/closure defaults — no main-actor work runs here. Every method
  /// that touches AppKit stays main-actor-isolated via the class annotation.
  nonisolated override init() {
    super.init()
  }

  /// Surface factory — overridable in tests to inject a non-spawning surface (`spawnsSurface: false`)
  /// so no real PTY / Metal renderer is created. Defaults to a login shell at the user's home dir.
  var makeSurface: () -> GhosttySurfaceView = {
    GhosttySurfaceView(workingDirectory: NSHomeDirectory())
  }

  /// True while a window is on screen. False when ABSENT or HIDDEN.
  var isVisible: Bool { window?.isVisible ?? false }
  /// True while a window exists (VISIBLE or HIDDEN) — inspection aid for tests.
  var hasWindow: Bool { window != nil }
  /// The live surface (VISIBLE or HIDDEN), else nil — for tests.
  var currentSurface: GhosttySurfaceView? { surface }
  /// The live window — for tests asserting the chrome-less styling.
  var currentWindow: NSWindow? { window }

  /// Hotkey semantics: ABSENT → new + show, VISIBLE → hide, HIDDEN → show.
  func toggle() {
    if window == nil {
      show()
    } else if isVisible {
      hide()
    } else {
      show()
    }
  }

  /// Button / summon semantics: never hides — create if ABSENT, then bring forward + focus. Called
  /// for the toolbar button and as the second half of `toggle()` from ABSENT/HIDDEN.
  func show() {
    if window == nil { createWindow() }
    guard let window, let surface else { return }
    // The hotkey can fire while another app is frontmost (or while Workroom is hidden), so pull the
    // app forward — mirrors `AppDelegate.toggleAppVisibility`.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(surface)
  }

  /// Hide without destroying: the surface keeps running so a re-summon restores the same session.
  func hide() {
    window?.orderOut(nil)
  }

  private func createWindow() {
    let surface = makeSurface()
    surface.wantsFocus = true
    // Shell exit (`exit`, or the login shell dying) closes the window — "close = destroy". This fires
    // from a libghostty action callback, so defer the teardown off that stack: freeing a surface
    // synchronously inside a libghostty callback races its IO and crashes (see GhosttySurfaceView /
    // AppDelegate.applicationWillTerminate). The async hop lands on the same main run loop a moment later.
    surface.onChildExited = { [weak self] _ in
      DispatchQueue.main.async { self?.close() }
    }
    self.surface = surface

    let window = QuickTerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Quick Terminal"
    // Chrome-less: hide the title text + the toolbar and make the titlebar transparent so the themed
    // window background shows through (mirrors WindowBackgroundThemer); keep the traffic lights so the
    // window is still movable + closable.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    // We own the lifetime (nil our refs in `tearDownState`); don't let AppKit free the window on close.
    window.isReleasedWhenClosed = false
    window.delegate = self
    // Center as the first-launch default, then let the autosave restore the user's last frame if one
    // exists (centre before setFrameAutosaveName so a saved frame still wins).
    window.center()
    window.setFrameAutosaveName("QuickTerminal")
    window.contentView = surface
    surface.autoresizingMask = [.width, .height]
    self.window = window
    applyTheme()

    themeObserver = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyTheme() }
    }
  }

  /// Repaint the window background and re-theme the surface for the active theme. On a `.themeDidChange`
  /// the global ghostty config is already reloaded (ThemeService posts the notification after it
  /// reloads), so we just push it to this standalone surface — the per-tab path in
  /// `TerminalSessions.applyThemeToAll` doesn't see it.
  private func applyTheme() {
    guard let window, let surface else { return }
    window.backgroundColor = ThemeService.shared.tokens.nsPanel
    if let config = GhosttyApp.shared.config { surface.updateConfig(config) }
    surface.applyColorScheme(isDark: ThemeService.isCurrentAppearanceDark())
  }

  /// Full close: destroy the window (its `windowWillClose` runs the teardown). Idempotent.
  func close() {
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    tearDownState()
  }

  /// Free the surface via the documented single-steady-state-surface path (clears callbacks first,
  /// then `ghostty_surface_free`) and drop the window — leaving the controller ABSENT so the next
  /// summon is fresh. Re-entrancy-guarded because `close()` → `windowWillClose` re-enters.
  private func tearDownState() {
    guard !tearingDown else { return }
    tearingDown = true
    if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    themeObserver = nil
    surface?.tearDown()
    surface = nil
    window?.delegate = nil
    window = nil
    tearingDown = false
  }
}

/// Posted by the main-toolbar Quick-Terminal button; `AppDelegate` observes it and calls `show()`
/// (the controller lives on the delegate, out of reach of the SwiftUI view). Same decoupled pattern
/// as `.showThemePicker` / `.showKeyboardShortcuts`. The ⌥§ global hotkey calls the controller
/// directly (it's registered in the delegate), so it doesn't go through this.
extension Notification.Name {
  static let showQuickTerminal = Notification.Name("workroom.showQuickTerminal")
}
