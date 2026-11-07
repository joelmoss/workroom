import AppKit
import SwiftUI

/// A SwiftUI wrapper around `NSVisualEffectView` — the system vibrancy backing for the sidebar and
/// inspector cards (with the `.sidebar` material + a `tokens.panel` wash), so they read as a frosted
/// surface distinct from the opaque terminal background. `.withinWindow` (not `.behindWindow`) blends
/// against the window's own backdrop rather than the desktop — so the left and right cards get the
/// identical tint regardless of where the window sits over the wallpaper (`.behindWindow` made the
/// left edge pick up a different desktop tint than the right, so the sidebars looked mismatched).
/// `.followsWindowActiveState` dims it when the window is inactive.
struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .sidebar
  var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
  }
}
