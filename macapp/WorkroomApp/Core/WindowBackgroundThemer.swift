import AppKit
import SwiftUI

/// Extends the active theme into the window's title bar (issue #36). The toolbar's own material is
/// hidden (`.toolbarBackground(.hidden)` in `RootView`) and the title bar is made transparent, so
/// the window's background colour — set here to the active theme background — shows through the top
/// strip. This is the canonical themed-terminal-app look: the title bar matches the terminal and
/// chrome instead of staying system grey/white. Re-applies on `.themeDidChange` so a theme switch
/// repaints the title bar live.
///
/// A zero-size probe view locates the host `NSWindow` once it's mounted.
struct WindowBackgroundThemer: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    DispatchQueue.main.async { [weak probe] in Self.apply(to: probe?.window) }
    context.coordinator.observer = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak probe] _ in
      MainActor.assumeIsolated { Self.apply(to: probe?.window) }
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    Self.apply(to: nsView.window)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var observer: NSObjectProtocol?
    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }

  @MainActor private static func apply(to window: NSWindow?) {
    guard let window else { return }
    // Content extends up under the (transparent) title bar so the custom bar can be drawn as the
    // top strip of the content at any height — see `WorkroomTitlebar` / `TitlebarBars`.
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    // No title text in the bar — the leading/trailing title-bar accessories (the unified toolbar) and
    // the workroom tabs carry the chrome; an app-name title would just clutter the row. Set here (not
    // via SwiftUI `.toolbar(removing: .title)`) because SwiftUI no longer manages this window's
    // toolbar — see the empty AppKit toolbar below. `.navigationTitle` still re-asserts a visible title
    // on some updates, so `AppStore.attachWindow`'s `didUpdate` re-hide lock backstops this.
    window.titleVisibility = .hidden
    // Kill the window toolbar. The taller single-row title bar (with the traffic lights centered in
    // it — the breathing room, issue #23) comes from the full-width `.left` titlebar accessory
    // (`TitlebarAccessoryHost`), which grows the titlebar to its own height; the toolbar is NOT needed
    // for that. We must remove it because `NavigationSplitView` (in RootView) auto-injects a
    // sidebar-toggle toolbar item even with the sidebar column forced `.detailOnly`, and that single
    // item is poison two ways: (a) it renders as a stray `»` "more toolbar items" overflow popup in
    // the title bar, and (b) it keeps SwiftUI's `AppKitToolbarItem.updateMenuFormRepresentation` alive
    // — recomputed on every layout pass, it bridges an NSAttributedString attributes dict into
    // `swift_dynamicCast` → `_dyld_find_foreign_type_protocol_conformance` (a linear scan of every
    // loaded Mach-O image; this app links many: GhosttyKit, the Rust VCS xcframework, SwiftGitX/
    // libgit2, Sparkle), stacking up to the ≥2s macOS-26 AppHangs. SwiftUI OWNS this toolbar and
    // re-injects the toggle, so `.toolbar(removing: .sidebarToggle)` is a no-op — we strip it in AppKit
    // instead, on every apply, and hide the bar so the `»` never shows. Our own sidebar toggle lives in
    // the `.left` accessory (`LeadingTitlebarBar`).
    window.toolbar?.isVisible = false
    // `.none` separator so no hairline rule appears under the bar when the terminal scrolls.
    window.titlebarSeparatorStyle = .none
    // The title bar belongs to the chrome panel, so it takes the panel colour (a subtle step off
    // the terminal background) — title bar + tab bar + panel read as one surface, terminals as
    // another (issue #36).
    window.backgroundColor = ThemeService.shared.tokens.nsPanel
    // We no longer hand-position the traffic lights. Manually moving the standard window
    // buttons into our 38pt bar fought AppKit (it re-lays them to the standard row on every layout
    // change — opening the first terminal, resize, fullscreen — so they shifted, and re-centering on
    // every update jittered). The lights now sit at AppKit's natural position, stable. `RootView`'s
    // bar content is inset to clear them (`WorkroomTitlebar.trafficLightInset`).
  }
}
