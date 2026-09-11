import AppKit
import SwiftUI

/// Shared rounding for the terminal panel chip. The border, dim scrim, and diff clip (PaneTreeView)
/// and the surface's own layer clip (below) must all use the same radius or the corners mismatch —
/// one constant keeps them in lockstep.
enum TerminalPanelMetrics {
  static let cornerRadius: CGFloat = 8
  /// Height of a pane's chrome rows — the title bar above the content (`PaneTitleBarMetrics.height`)
  /// and the status bar below it (`TerminalStatusBar`). One constant because the two must match: they
  /// bracket the content, and `TerminalSessions.minPaneHeight` budgets for BOTH of them, so a change
  /// in one place that missed the others would make the pane floor quietly wrong.
  static let chromeRowHeight: CGFloat = 28
}

/// Hosts a single terminal surface. Terminals live in
/// `TerminalSessions` (retained across switches); this view mounts whichever one it's given and
/// re-mounts when that changes.
///
/// Occlusion (plan A4): the hosted surface is marked visible on mount and **hidden on dismantle**,
/// so a backgrounded tab's GPU surface stops rendering while it stays alive (its shell keeps running).
/// With splits (issue #3) the model also drives occlusion centrally (`reconcileOcclusion`), so several
/// panes can be visible at once; this view's mount/dismantle is the per-mount backstop.
///
/// This hosts exactly one terminal surface (one tab). A split composes several of these into one
/// on-screen layout via the recursive pane renderer over `PaneLayout` — splitting does not nest
/// surfaces inside a tab.
///
/// Focus (issue #3): with multiple panes mounted, only the focused one may grab first responder.
/// `isFocusedPane` drives that — the host passes `true` for exactly the focused leaf. Mount no longer
/// force-focuses unconditionally (that would let the last-mounted pane steal focus); focus is applied
/// from `isFocusedPane` on update. A pane the user clicks becomes first responder via the surface's own
/// `mouseDown`, which feeds the selection back through `onFocused`.
struct TerminalContainerView: NSViewRepresentable {
  let view: GhosttySurfaceView
  /// Whether this pane should hold keyboard focus. Solo callers leave it `true`; the split renderer
  /// passes `true` only for the focused leaf.
  var isFocusedPane: Bool = true
  /// Whether THIS host is the one currently entitled to the surface (issue #172).
  ///
  /// A surface has exactly one host, but two of them can briefly exist: popping a pane out mounts it
  /// in the detached window while the origin tree still has one update pass left to run, and
  /// `updateNSView` re-homes unconditionally — so the origin re-adopted the surface and then took it
  /// down with its own container, stranding it in no window at all (a blank detached pane, and the
  /// same failure shape as the split-collapse bug in issue #3). The caller resolves this from the
  /// model — a host may adopt the surface only when its kind matches `detachedTabIDs` — so a stale
  /// pass is inert in both directions, popping out and docking back.
  var mayHostSurface: Bool = true
  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    // The surface itself rounds NOTHING: since issue #150 it is sandwiched between the pane's title
    // bar above and its status bar below, so all four of its corners are interior. The pane's rounded
    // silhouette is cut once by `PaneLeafView`'s `clipShape`, around the whole stack.
    //
    // `masksToBounds` stays — it clips the hosted surface (pinned to the container's edges) to the
    // container, which is what keeps a mid-resize surface from painting outside its pane.
    container.layer?.masksToBounds = true
    guard mayHostSurface else { return container }
    mount(in: container)
    applyFocus(in: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    guard mayHostSurface else { return }
    mount(in: container)
    applyFocus(in: container)
  }

  // No `dismantleNSView`: occlusion is driven by the model (`reconcileOcclusion`) and by AppKit's
  // window occlusion (a surface removed from the window pauses via `viewDidMoveToWindow`). Pausing here
  // on dismantle would be redundant and, worse, would race the split↔solo transition — when a split
  // collapses, the surviving surface is re-homed from the (dismantled) split leaf into the solo
  // container, and a stray `setVisible(false)` landing after the re-home left the pane blank (issue #3).

  private func mount(in container: NSView) {
    // Set before any re-home: `addSubview` below fires `viewDidMoveToWindow`, where the focused surface
    // claims first responder off this flag (the switch-focus-loss fix). Must reflect *this* render's
    // focus, not the previous one.
    view.wantsFocus = isFocusedPane
    if view.superview === container {
      view.frame = container.bounds
      view.setVisible(true)
      return
    }
    // Detach whatever was shown (do NOT tear down — it lives on in the cache).
    for sub in container.subviews { sub.removeFromSuperview() }

    // Pin the surface to the container with an autoresizing mask, NOT AutoLayout constraints. A surface
    // is re-homed between containers (split leaf → solo, and back) while the old container may still be
    // alive mid-transition; AutoLayout constraints to the old container would linger and conflict with
    // the new ones, leaving the surface at a broken/zero frame (a blank pane — issue #3). A frame +
    // autoresizing mask carries no cross-container state, so re-homing is clean.
    view.translatesAutoresizingMaskIntoConstraints = true
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    container.addSubview(view)
    view.setVisible(true)
  }

  /// Keep this surface's AppKit first-responder state in sync with whether it's the focused pane.
  ///
  /// Focused: claim first responder when it isn't already (so re-rendering a focused solo pane, or a
  /// divider drag, doesn't churn the responder chain). This covers the same-window-reuse path; the
  /// freshly-mounted-container path (where `container.window` is still nil when this async runs) is
  /// covered by the surface's own `viewDidMoveToWindow`, driven by the `wantsFocus` flag `mount` sets.
  ///
  /// Not focused: resign first responder if this surface still holds it. Focus moving to a sibling
  /// **diff** pane is pure SwiftUI — it claims no AppKit responder — so without this the terminal
  /// stays the window's first responder while the diff is logically focused. A later click on the
  /// terminal then calls `makeFirstResponder(self)` on a view that's *already* first responder, which
  /// AppKit short-circuits: `becomeFirstResponder` (hence `onFocused`) never fires and the click can't
  /// refocus the terminal. Terminal→terminal doesn't need this (the new pane claiming first responder
  /// resigns the old one), so the guard makes this a no-op there.
  private func applyFocus(in container: NSView) {
    DispatchQueue.main.async {
      guard let window = container.window else { return }
      if isFocusedPane {
        // While this pane's find bar is open, the search field owns first responder — don't reclaim
        // it for the terminal. Opening the bar re-renders this pane (the overlay appears), which runs
        // applyFocus; without this guard it would steal focus straight back from the field, so ⌘F
        // would never land you in the search box.
        if view.searchModel.isActive { return }
        guard window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
      } else {
        guard window.firstResponder === view else { return }
        window.makeFirstResponder(nil)  // → the window; lets a later click refocus this terminal
      }
    }
  }
}
