import AppKit
import DesignSystem
import SwiftUI

/// Extends the active theme into the window's title bar (issue #36). The toolbar's own material is
/// hidden (`.toolbarBackground(.hidden)` in `RootView`) and the title bar is made transparent, so
/// the window's background colour — set here to the active theme background — shows through the top
/// strip. This is the canonical themed-terminal-app look: the title bar matches the terminal and
/// chrome instead of staying system grey/white. Re-applies on `.themeDidChange` so a theme switch
/// repaints the title bar live.
///
/// Glass (#727): it also applies the window's resolved `\.glassAppearance` (see `apply`), and reports
/// the window's native full-screen state back so the root can resolve against it.
///
/// A zero-size probe view locates the host `NSWindow` once it's mounted.
struct WindowBackgroundThemer: NSViewRepresentable {
  /// What the window's title bar is: the main window's content, or a normal one.
  var titlebar = TitlebarStyle.content
  /// Told whether the window is in native full screen, which Glass resolves against (#727): the
  /// root reads it back into `GlassService.appearance(fullScreen:)` and injects the result.
  var isFullScreen: Binding<Bool>?

  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    let titlebar = titlebar
    let coordinator = context.coordinator
    coordinator.glass = context.environment.glassAppearance
    coordinator.isFullScreen = isFullScreen
    DispatchQueue.main.async { [weak probe] in
      coordinator.attach(to: probe?.window)
      Self.apply(to: probe?.window, glass: coordinator.glass, titlebar: titlebar)
    }
    coordinator.observer = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak probe] _ in
      MainActor.assumeIsolated {
        Self.apply(to: probe?.window, glass: coordinator.glass, titlebar: titlebar)
      }
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.glass = context.environment.glassAppearance
    context.coordinator.isFullScreen = isFullScreen
    context.coordinator.attach(to: nsView.window)
    Self.apply(to: nsView.window, glass: context.environment.glassAppearance, titlebar: titlebar)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    var observer: NSObjectProtocol?
    /// The latest resolved appearance, for the theme observer's re-apply.
    var glass = GlassAppearance.opaque
    var isFullScreen: Binding<Bool>?
    private weak var window: NSWindow?
    private var fullScreenObservers: [NSObjectProtocol] = []

    /// Watch `window`'s full-screen transitions (once per window) and report its state now.
    func attach(to window: NSWindow?) {
      guard let window, window !== self.window else { return }
      self.window = window
      fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
      fullScreenObservers = [
        NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
      ].map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.reportFullScreen() }
        }
      }
      // Deferred: `attach` runs inside a view update, where writing state is not allowed.
      DispatchQueue.main.async { [weak self] in self?.reportFullScreen() }
    }

    private func reportFullScreen() {
      guard let window, let isFullScreen else { return }
      let now = window.styleMask.contains(.fullScreen)
      if isFullScreen.wrappedValue != now { isFullScreen.wrappedValue = now }
    }

    isolated deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
    }
  }

  /// Make `window` draw `glass` (#727). Opaque: the theme's panel fill, as before Glass. Glass: a
  /// non-opaque window whose own background is the window base, the theme `bg` at the Glass
  /// opacity (`baseColor`), blurred behind by the window server (`WindowBlur`, ADR 0080). The base
  /// is the one tint under every pixel of the window, the title bar's included; the chrome adds
  /// only the panel wash on it (`ThemeFill`), and the terminals draw no default background of their
  /// own. Nothing adds a behind-window blur view, and Ghostty's own `background-blur` stays off.
  ///
  /// Occlusion still works for a non-opaque window: `occlusionState` reports whether any of THIS
  /// window is on screen, so it still drops `.visible` when the window is hidden or covered by
  /// another opaque window, and the terminals still pause (`GlassWindowTests`). What a translucent
  /// window changes is the windows BEHIND it, which now stay visible, as they should.
  ///
  /// Idempotent and cheap to repeat, as it runs on every SwiftUI update of the window's root and on
  /// every theme change: each step compares against the window first, so the blur call, the shadow
  /// and the title-bar setup run only when the window turns glass or opaque. An opacity change sets
  /// the background colour alone.
  ///
  /// The blur call needs the window's window-server number, so a window the server hasn't
  /// numbered yet doesn't turn glass: it stays opaque, and the next apply (its root's next update,
  /// or a theme change) turns it, blur and all. Without this it would turn on the first apply and
  /// stay unblurred, as the turn is the only time the blur is set. A Mac without the blur call
  /// (`WindowBlur.setRadius` nil) is different: it turns, and is clear glass with no blur.
  @MainActor static func apply(
    to window: NSWindow?, glass requested: GlassAppearance, titlebar: TitlebarStyle = .content
  ) {
    guard let window else { return }
    let glass =
      requested.isGlass && window.isOpaque && window.windowNumber <= 0 ? .opaque : requested
    let turned = window.isOpaque == glass.isGlass
    if turned { window.isOpaque = !glass.isGlass }
    let background = baseColor(glass)
    if window.backgroundColor != background { window.backgroundColor = background }
    if titlebar == .standard, window.titlebarAppearsTransparent != glass.isGlass {
      window.titlebarAppearsTransparent = glass.isGlass
    }
    if turned {
      WindowBlur.setBlurRadius(glass.isGlass ? WindowBlur.glassRadius : 0, of: window)
      // A window's shadow is cut from its opaque pixels: re-cut it.
      window.invalidateShadow()
    }
    guard titlebar.takesOver else { return }
    applyTitlebar(to: window)
  }

  /// `apply` for a window whose controller installs its content (the Quick Terminal, a detached
  /// pane): the appearance its `GlassWindowRoot` resolves, applied now rather than when the root
  /// first mounts on a display cycle, so the window opens glass.
  @MainActor static func applyResolved(to window: NSWindow, titlebar: TitlebarStyle) {
    apply(
      to: window,
      glass: GlassService.shared.appearance(fullScreen: window.styleMask.contains(.fullScreen)),
      titlebar: titlebar)
  }

  /// The window's own background under `glass`: the theme panel when opaque, as before Glass;
  /// under glass the theme `bg` at the Glass opacity, the base every surface sits on. Never near
  /// zero (the floor is 70%), so no gap between the surfaces clicks through to the desktop.
  @MainActor static func baseColor(
    _ glass: GlassAppearance, tokens: ThemeTokens = ThemeService.shared.tokens
  ) -> NSColor {
    glass.isGlass
      ? tokens.nsBg.withAlphaComponent(CGFloat(glass.opacity)) : ThemeFill.panel.nsColor(tokens)
  }

  /// Take the title bar over as content: everything the main window wants beyond its background,
  /// which a window with a normal title bar must not get. Each setter is guarded on the window's
  /// current value, so a repeat is a no-op, yet whatever SwiftUI re-asserts is put back.
  @MainActor private static func applyTitlebar(to window: NSWindow) {
    // Content extends up under the (transparent) title bar so the custom bar can be drawn as the
    // top strip of the content at any height — see `WorkroomTitlebar` / `TitlebarBars`.
    if !window.styleMask.contains(.fullSizeContentView) {
      window.styleMask.insert(.fullSizeContentView)
    }
    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
    // No title text in the bar — the leading/trailing title-bar accessories (the unified toolbar) and
    // the workroom tabs carry the chrome; an app-name title would just clutter the row. Set here (not
    // via SwiftUI `.toolbar(removing: .title)`) because SwiftUI no longer manages this window's
    // toolbar — see the empty AppKit toolbar below. `.navigationTitle` still re-asserts a visible title
    // on some updates, so `AppStore.attachWindow`'s `didUpdate` re-hide lock backstops this.
    if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
    // Kill the window toolbar. The taller single-row title bar (with the traffic lights centered in
    // it — the breathing room, issue #23) comes from the full-width `.left` titlebar accessory
    // (`TitlebarAccessoryHost`), which grows the titlebar to its own height; the toolbar is NOT needed
    // for that. We must remove it because `NavigationSplitView` (in RootView) auto-injects a
    // sidebar-toggle toolbar item even with the sidebar column forced `.detailOnly`, and that single
    // item is poison two ways: (a) it renders as a stray `»` "more toolbar items" overflow popup in
    // the title bar, and (b) it keeps SwiftUI's `AppKitToolbarItem.updateMenuFormRepresentation` alive
    // — recomputed on every layout pass, it bridges an NSAttributedString attributes dict into
    // `swift_dynamicCast` → `_dyld_find_foreign_type_protocol_conformance` (a linear scan of every
    // loaded Mach-O image; this app links many: GhosttyKit, SwiftGitX/
    // libgit2, Sparkle), stacking up to the ≥2s macOS-26 AppHangs. SwiftUI OWNS this toolbar and
    // re-injects the toggle, so `.toolbar(removing: .sidebarToggle)` is a no-op — we strip it in AppKit
    // instead, on every apply, and hide the bar so the `»` never shows. Our own sidebar toggle lives in
    // the `.left` accessory (`LeadingTitlebarBar`).
    if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
    // `.none` separator so no hairline rule appears under the bar when the terminal scrolls.
    if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    // We no longer hand-position the traffic lights. Manually moving the standard window
    // buttons into our 38pt bar fought AppKit (it re-lays them to the standard row on every layout
    // change — opening the first terminal, resize, fullscreen — so they shifted, and re-centering on
    // every update jittered). The lights now sit at AppKit's natural position, stable. `RootView`'s
    // bar content is inset to clear them (`WorkroomTitlebar.trafficLightInset`).
  }
}

/// What a window's title bar is, for `WindowBackgroundThemer`.
enum TitlebarStyle: Equatable, Sendable {
  /// The main window's: content extends under a transparent title bar, which the window takes over
  /// (`WorkroomTitlebar`).
  case content
  /// A normal title bar (a detached pane's window, issue #172, which wants the standard chrome:
  /// traffic lights, the pane's name beside them, and something to drag the window by). Under glass
  /// it turns transparent, so the window base shows through it as it does through the rest of the
  /// window, rather than AppKit's own title-bar material.
  case standard
  /// A title bar the window's controller has already made transparent and emptied (the Quick
  /// Terminal, #731), which Glass leaves as it is.
  case hidden

  /// Whether the window takes the title bar over as content.
  var takesOver: Bool { self == .content }
}

extension NSWindow {
  /// The title bar's own view (`NSTitlebarView`), the row the traffic lights sit in: the close
  /// button's parent.
  @MainActor var titlebarView: NSView? { standardWindowButton(.closeButton)?.superview }
}
