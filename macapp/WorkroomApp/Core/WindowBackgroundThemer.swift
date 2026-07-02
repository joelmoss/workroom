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
    // Hide NavigationSplitView's own toolbar. It looks itemless — `.toolbar(removing: .sidebarToggle)`
    // is meant to clear it (our `LeadingTitlebarBar` carries the real sidebar toggle) — but that removal
    // does NOT take: the live toolbar still carries SwiftUI's `navigationSplitView.toggleSidebar`, a
    // `NSToolbarFlexibleSpaceItem`, and the `splitViewSeparator` tracking item. Our single full-width
    // `.leading` titlebar accessory (TitlebarAccessory, `fillsWidth`) starves the toolbar's content
    // region to ~0pt, so all three items clip into AppKit's "more toolbar items" (») overflow popup —
    // which surfaces centred in the bar whenever nothing opaque (a selected workroom's tab bar /
    // trailing controls) happens to paint over it, e.g. the "Nothing selected" state on a wide/zoomed
    // window. Hiding the toolbar removes the overflow entirely; we use none of its items (the accessory
    // replicates them), and the `.unified` style still applies so the taller title-bar row — the
    // breathing room above/below the controls + workroom tabs — is preserved. `.unified` (vs the
    // shorter `.unifiedCompact`) gives a taller bar with more space beneath it. (Replacing the toolbar
    // outright crashes — SwiftUI owns it — so hide, don't replace.) `.none` separator so no hairline
    // rule appears under the bar when the terminal scrolls.
    // S4 rehost increment 1 (probe): DO NOT hide the toolbar — reveal SwiftUI's `.unified` toolbar so
    // AppKit centers the traffic lights in it (proven by the spike). This surfaces whatever items
    // NavigationSplitView still injects (toggleSidebar / flexible space / split separator) so we can
    // see what to replace with our own toolbar content in the next increment.
    // window.toolbar?.isVisible = false
    window.toolbarStyle = .unified
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
