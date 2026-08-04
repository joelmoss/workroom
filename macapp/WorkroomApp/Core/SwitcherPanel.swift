import AppKit
import SwiftUI

/// The quick-switcher rail's window (issue #132, T11) — the app's first `NSPanel`.
///
/// `QuickTerminalWindow` is **not** a precedent for this: it's a plain `.titled NSWindow` that
/// deliberately *does* become key. This one must never take key focus, because the whole gesture
/// depends on the workroom window keeping it — the `AppDelegate` monitor resolves its store from the
/// key window, and release detection ends the session, not a focus change.
final class SwitcherPanel: NSPanel {
  /// Load-bearing. Key focus must stay with the workroom window or the monitor's store lookup misses
  /// and ⌥Tab stops working the moment the rail appears.
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The panel's content view: the rail plus the empty `shadowMargin` halo its drop shadow lands in.
///
/// The halo must not eat clicks. The panel is bigger than the rail it shows, and a plain `NSView`
/// hit-tests its whole bounds — so without this a click in the transparent border would be swallowed by
/// the rail's window instead of reaching the window underneath.
final class HaloContentView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = superview.map { convert(point, from: $0) } ?? point
    let rail = bounds.insetBy(
      dx: SwitcherRailLayout.shadowMargin, dy: SwitcherRailLayout.shadowMargin)
    return rail.contains(local) ? super.hitTest(point) : nil
  }
}

/// Owns the panel and its hosting view, and hands the rail its data. Pre-creates the panel at launch:
/// the first `NSHostingView` render costs real milliseconds, and paying that at the 250 ms reveal is
/// exactly the wrong moment.
@MainActor
final class SwitcherPanelController {
  static let shared = SwitcherPanelController()

  private var panel: SwitcherPanel?
  private let model = SwitcherRailModel()
  private var themeObserver: NSObjectProtocol?

  /// Build the panel and its hosting view, ordered out. Safe to call more than once.
  func prepare() {
    guard panel == nil else { return }
    let panel = SwitcherPanel(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    // `.canJoinAllSpaces` so a rail opened just before a Space switch doesn't strand; `.ignoresCycle`
    // so ⌘` skips it (belt and braces — `isCycleableWindow` already requires `canBecomeKey`).
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    // `isOpaque = false` is load-bearing and has a test. `NSWindow.occlusionState` counts only OPAQUE
    // coverage, so a clear panel never flips it — give this an opaque background and every terminal
    // surface behind the rail believes it is occluded and stops rendering.
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // Stays FALSE, and the rail draws its own shadow instead (`SwitcherRailView.shadowCaster`). Not a
    // style preference — measured: a borderless non-opaque panel casts no system shadow at all. With
    // `hasShadow = true` plus `invalidateShadow()`, a pixel diff of the same screen with and without the
    // panel showed zero darkening at 6/14/26/44pt out on every side, with glass content and with a solid
    // opaque fill alike. Turning this on would buy nothing except a square shadow around the shadow
    // halo if it ever started working.
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = false
    panel.setAccessibilityIdentifier("switcher.panel")

    let content = HaloContentView()
    let host = NSHostingView(rootView: SwitcherRailView(model: model))
    host.autoresizingMask = [.width, .height]
    content.addSubview(host)
    panel.contentView = content
    self.panel = panel
  }

  /// Wire the controller's rail seam to this panel, and the rail's input back to the controller.
  /// Called once at launch.
  func attach(to controller: QuickSwitcherController) {
    controller.onReveal = { [weak self] items, cursor in self?.show(items: items, cursor: cursor) }
    // Re-render from the surviving items when something dies mid-session. `show` is idempotent — it
    // re-sizes and re-centres the panel for the new count — and without this the cards on screen keep
    // showing a workroom that is gone while the controller's array has already moved on, so a click or
    // a release lands on the wrong one.
    controller.onItemsChanged = { [weak self] items, cursor in
      self?.show(items: items, cursor: cursor)
    }
    controller.onCursorMoved = { [weak self] index in self?.model.cursor = index }
    controller.onEnd = { [weak self] in self?.hide() }
    // Hover goes through the controller, not straight to the model: the D17 movement threshold lives
    // there, so a card hovered because the panel opened under a stationary pointer is discarded.
    model.onHover = { index in controller.point(index: index) }
    model.onCommit = { index in controller.clickCommit(index: index) }
    // A static view's `updateNSView` may never run, so the theme change has to be pushed (the same
    // reason `QuickTerminalController` observes this rather than relying on invalidation).
    themeObserver = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.model.themeVersion &+= 1 }
    }
  }

  private func show(items: [QuickSwitcherController.Item], cursor: Int) {
    prepare()
    guard let panel else { return }
    let cards = SwitcherCard.cards(for: items)
    let screen = NSApp.keyWindow?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    // The window is the rail slab plus its shadow halo; the SLAB is only as wide as the cards turned out
    // to be — otherwise the glass runs on past the last card and a rail of four reads as left-aligned
    // inside a wide slab, even though the slab is perfectly centred.
    let size = SwitcherRailLayout.panelSize(count: cards.count, visibleFrame: visible)
    // The cards lay out in the slab they actually get, not the viewport they were sized against: on a
    // narrow display the halo comes out of the slab, and cards measured against the wider viewport would
    // overflow it.
    model.update(
      cards: cards, cursor: cursor, width: size.width - SwitcherRailLayout.shadowMargin * 2)

    let origin = SwitcherRailLayout.panelOrigin(
      size: size, windowFrame: NSApp.keyWindow?.frame ?? visible, visibleFrame: visible)
    panel.setFrame(NSRect(origin: origin, size: size), display: false)
    // `orderFrontRegardless`, not `makeKeyAndOrderFront`: the workroom window keeps key focus.
    panel.orderFrontRegardless()
  }

  private func hide() {
    panel?.orderOut(nil)
  }
}
