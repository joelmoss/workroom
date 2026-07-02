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
    // the workroom tabs carry the chrome; an app-name title would just clutter the row.
    window.titleVisibility = .hidden
    // The window keeps its (item-less) `.unified` toolbar VISIBLE on purpose: it's what grows the
    // title bar to a taller single row and lets AppKit vertically center the traffic lights (the
    // breathing room, issue #23). We do NOT hide it (that would collapse the bar back to the standard
    // height). Its own material would paint a grey vibrancy over the bar — that's removed declaratively
    // in RootView with `.toolbarBackground(.hidden, for: .windowToolbar)`, so with
    // `titlebarAppearsTransparent` the themed window background below shows through the whole bar. The
    // chrome (controls + workroom tabs) lives in a `.left` titlebar accessory that grows to this taller
    // bar (see TitlebarAccessoryHost), never in the toolbar itself — so there's no overflow `»` popup.
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
