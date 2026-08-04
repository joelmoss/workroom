import AppKit
import SwiftUI

/// The switcher rail's backing material: the system's Liquid Glass, the same surface the macOS ⌘Tab
/// switcher sits on (issue #132).
///
/// Two reasons this is not the app's usual `sidebarCard(vibrant:)` recipe:
///
/// 1. **The material has to sample what is behind the *window*.** `VisualEffectView` defaults to
///    `.withinWindow`, which blends against the host window's own backdrop — deliberately, so the left
///    and right sidebar cards get an identical tint. But this panel is transparent and floats over other
///    windows and the desktop, so `.withinWindow` has nothing to sample and the glass reads flat.
///    `.behindWindow` is what makes it glass.
/// 2. **⌘Tab's surface is a HUD**, not a sidebar. `.hudWindow` is the material that reads as a floating
///    overlay rather than a piece of window chrome.
///
/// On macOS 26+ this uses the real thing — `NSGlassEffectView`, which is what the system switcher
/// itself draws — and falls back to the `.hudWindow` vibrancy that approximated it before Liquid Glass
/// existed, because the app still deploys to macOS 15.
struct RailGlassBackground: NSViewRepresentable {
  var cornerRadius: CGFloat = 20

  func makeNSView(context: Context) -> NSView {
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.cornerRadius = cornerRadius
      // `.regular` rather than `.clear`: the rail carries text over arbitrary windows and wallpapers, and
      // `.clear` leaves too little separation for a 12pt subtitle to survive a busy backdrop.
      glass.style = .regular
      return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active  // NOT `.followsWindowActiveState`: this panel is never the key window
    effect.wantsLayer = true
    effect.layer?.cornerRadius = cornerRadius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    return effect
  }

  func updateNSView(_ view: NSView, context: Context) {
    if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
      glass.cornerRadius = cornerRadius
      return
    }
    view.layer?.cornerRadius = cornerRadius
  }
}
