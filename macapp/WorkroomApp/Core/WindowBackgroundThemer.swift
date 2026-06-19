import AppKit
import SwiftUI

/// Extends the active theme into the window's title bar (issue #36). The toolbar's own material is
/// hidden (`.toolbarBackground(.hidden)` in `RootView`) and the title bar is made transparent, so
/// the window's background colour — set here to the active theme background — shows through the top
/// strip. This is the canonical themed-terminal-app look: the title bar matches the terminal and
/// chrome instead of staying system grey/white. Re-applies on `.themeDidChange` so a theme switch
/// repaints the title bar live.
///
/// A zero-size probe (mirroring `SplitViewAutosave`) locates the host `NSWindow` once it's mounted.
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
    window.titlebarAppearsTransparent = true
    // No title text in the bar — the leading/trailing title-bar accessories (the unified toolbar) and
    // the workroom tabs carry the chrome; an app-name title would just clutter the row.
    window.titleVisibility = .hidden
    // Hide NavigationSplitView's window toolbar. Its only item (the auto sidebar toggle) is removed
    // (`.toolbar(removing:)`), and an itemless toolbar still draws an overflow chevron in the title
    // bar. The traffic lights (window buttons) and our title-bar accessories are separate from the
    // toolbar, so hiding it leaves the single unified accessory row clean.
    window.toolbar?.isVisible = false
    // The title bar belongs to the chrome panel, so it takes the panel colour (a subtle step off
    // the terminal background) — title bar + tab bar + panel read as one surface, terminals as
    // another (issue #36).
    window.backgroundColor = ThemeService.shared.tokens.nsPanel
  }
}
