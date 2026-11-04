import AppKit
import Defaults

/// Marker type for the quick-terminal window so the `AppDelegate` key monitor can recognise it and
/// route ⌘W to close it. (The app rebinds ⌘W to a "Close Tab" menu command that targets the
/// main window's tabs and wins over a window's own `performKeyEquivalent`, so ⌘W is caught in the
/// monitor — the same mechanism the app already uses for ⌘R / ⌘1–9.)
final class QuickTerminalWindow: NSWindow {
  // AppKit pulls a titled window back on-screen, so the slide could never start off-screen.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// The screen edge the quick terminal slides in from (Settings ▸ Terminal).
enum QuickTerminalEdge: String, CaseIterable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case top, bottom, left, right

  var label: String { rawValue.capitalized }

  /// Where the window sits when shown: against this edge of `visible` (the screen's
  /// `visibleFrame`), centred along it, shrunk to fit.
  func dockedFrame(size: NSSize, in visible: NSRect) -> NSRect {
    let size = NSSize(
      width: min(size.width, visible.width), height: min(size.height, visible.height))
    let centredX = visible.midX - size.width / 2
    let centredY = visible.midY - size.height / 2
    let origin: NSPoint
    switch self {
    case .top: origin = NSPoint(x: centredX, y: visible.maxY - size.height)
    case .bottom: origin = NSPoint(x: centredX, y: visible.minY)
    case .left: origin = NSPoint(x: visible.minX, y: centredY)
    case .right: origin = NSPoint(x: visible.maxX - size.width, y: centredY)
    }
    return NSRect(origin: origin, size: size)
  }

  /// `docked` pushed just past this edge of `screen` (the screen's full frame), where the slide
  /// starts and ends. Only the origin moves, so the terminal never resizes mid-slide.
  func hiddenFrame(docked: NSRect, screen: NSRect) -> NSRect {
    var frame = docked
    switch self {
    case .top: frame.origin.y = screen.maxY
    case .bottom: frame.origin.y = screen.minY - frame.height
    case .left: frame.origin.x = screen.minX - frame.width
    case .right: frame.origin.x = screen.maxX
    }
    return frame
  }
}

/// The "quick terminal" (issue #39): a login shell (at `~/` unless Settings ▸ Terminal names
/// another folder) in its own chrome-less window that slides in from a screen edge, Quake-style,
/// summoned by the ⌥§ global hotkey or the main-toolbar button. One persistent controller owns at
/// most one window + surface at a time:
///
/// ```
///   ABSENT  ──⌥§ / button──▶ VISIBLE      create window + a fresh surface, slide in, key + focused
///   VISIBLE ──⌥§───────────▶ HIDDEN       slide out, orderOut — surface kept alive (scrollback / process persist)
///   HIDDEN  ──⌥§ / button──▶ VISIBLE      slide in, focus the SAME surface
///   VISIBLE/HIDDEN ──⌘W / shell exit──▶ ABSENT   tearDown surface, destroy window
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
  /// Set while a slide-out runs; a summon during it clears it, cancelling the pending `orderOut`.
  private var hiding = false

  /// Nonisolated so `AppDelegate` can construct it as a stored-property default (a nonisolated
  /// context); it only assigns nil/closure defaults — no main-actor work runs here. Every method
  /// that touches AppKit stays main-actor-isolated via the class annotation.
  nonisolated override init() {
    super.init()
  }

  /// Surface factory — overridable in tests to inject a non-spawning surface (`spawnsSurface: false`)
  /// so no real PTY / Metal renderer is created. Defaults to a login shell in the Settings folder.
  var makeSurface: @MainActor () -> GhosttySurfaceView = {
    GhosttySurfaceView(
      workingDirectory: QuickTerminalController.workingDirectory(
        for: Defaults[.quickTerminalDirectory]))
  }

  /// The folder a new quick-terminal shell starts in: the setting with `~` expanded, or the home
  /// folder when it is empty or no longer a folder (deleted, or on an unmounted volume).
  nonisolated static func workingDirectory(for setting: String) -> String {
    let path = (setting as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    // An empty setting expands to "", which no folder matches.
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return NSHomeDirectory() }
    return path
  }

  /// Whether losing key focus slides the window away (Settings ▸ Terminal). Overridable in tests,
  /// so no shared `Defaults` write races the parallel test workers.
  var hidesWhenUnfocused: @MainActor () -> Bool = { Defaults[.quickTerminalHidesWhenUnfocused] }

  /// True while a window is on screen and not sliding out. False when ABSENT or HIDDEN.
  var isVisible: Bool { !hiding && (window?.isVisible ?? false) }
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

  /// Button / summon semantics: never hides — create if ABSENT, then slide in + focus. Called
  /// for the toolbar button and as the second half of `toggle()` from ABSENT/HIDDEN.
  func show() {
    if window == nil { createWindow() }
    guard let window, let surface else { return }
    // The hotkey can fire while another app is frontmost (or while Workroom is hidden), so pull the
    // app forward — mirrors `AppDelegate.toggleAppVisibility`.
    NSApp.activate(ignoringOtherApps: true)
    hiding = false
    // Dock on every summon: to the edge the setting names now, on the screen under the pointer
    // (the hotkey fires from any app, so the key window's screen may not be where the user is).
    let screen =
      NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    if let screen {
      let edge = Defaults[.quickTerminalEdge]
      let docked = edge.dockedFrame(size: window.frame.size, in: screen.visibleFrame)
      // Re-summoned mid slide-out, it is still up: slide back from where it is.
      if !window.isVisible {
        window.setFrame(edge.hiddenFrame(docked: docked, screen: screen.frame), display: false)
      }
      window.makeKeyAndOrderFront(nil)
      slide(window, to: docked)
    } else {
      window.makeKeyAndOrderFront(nil)
    }
    window.makeFirstResponder(surface)
  }

  /// Slide out, then hide without destroying: the surface keeps running so a re-summon restores
  /// the same session.
  func hide() {
    guard let window, window.isVisible, !hiding else { return }
    hiding = true
    guard let screen = window.screen else { return finishHide() }
    let hidden = Defaults[.quickTerminalEdge].hiddenFrame(
      docked: window.frame, screen: screen.frame)
    slide(window, to: hidden) { [weak self] in self?.finishHide() }
  }

  /// End of a slide-out. A summon during it cleared `hiding`, and then the window stays up.
  private func finishHide() {
    guard hiding else { return }
    hiding = false
    window?.orderOut(nil)
  }

  /// Animate the window to `frame`, which only differs in origin; instant under Reduce Motion.
  private func slide(
    _ window: NSWindow, to frame: NSRect,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0 : 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().setFrame(frame, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { completion?() }
    }
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
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Quick Terminal"
    // Chrome-less: hide the title text, the toolbar and the traffic lights, and make the titlebar
    // transparent so the themed window background shows through (mirrors WindowBackgroundThemer).
    // Still `.titled` + `.closable`, so it takes key focus, ⌘W's `performClose` works and the edges
    // resize. Not movable, because every summon docks it to its edge.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(button)?.isHidden = true
    }
    window.isMovable = false
    // We own the lifetime (nil our refs in `tearDownState`); don't let AppKit free the window on close.
    window.isReleasedWhenClosed = false
    window.delegate = self
    // The autosave restores the user's last size; `show()` sets the position.
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

  /// Focus moved to another window or app: slide away. Not while a sheet is up (a clipboard
  /// confirmation takes key from this window but belongs to it).
  func windowDidResignKey(_ notification: Notification) {
    guard hidesWhenUnfocused(), window?.attachedSheet == nil else { return }
    hide()
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
    hiding = false
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
