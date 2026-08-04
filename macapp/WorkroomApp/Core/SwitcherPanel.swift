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
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = false
    panel.setAccessibilityIdentifier("switcher.panel")

    let host = NSHostingView(rootView: SwitcherRailView(model: model))
    host.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView = host
    self.panel = panel
  }

  /// Wire the controller's rail seam to this panel, and the rail's input back to the controller.
  /// Called once at launch.
  func attach(to controller: QuickSwitcherController) {
    controller.onReveal = { [weak self] items, cursor in self?.show(items: items, cursor: cursor) }
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
    let cards = items.map(SwitcherCard.init(item:))
    let screen = NSApp.keyWindow?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let width = SwitcherRailLayout.viewportWidth(visibleFrame: visible)
    model.update(cards: cards, cursor: cursor, width: width)

    let size = NSSize(
      width: width, height: SwitcherRailLayout.cardHeight + SwitcherRailLayout.railPadding * 2)
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
