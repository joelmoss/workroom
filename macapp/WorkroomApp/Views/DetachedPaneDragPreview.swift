import AppKit
import SwiftUI

/// The ghost window shown while a pane is being dragged OUT of the window (issue #172).
///
/// The pane tree's own `dragGhost` is a SwiftUI overlay, so it stops existing the moment the cursor
/// leaves the window — which is exactly when the user most needs to be told what is about to happen.
/// This is a borderless floating panel instead, so it can follow the pointer anywhere on screen, and
/// it is drawn at the size and position the real window will take: what you see is where it lands.
///
/// Modelled on `SwitcherPanel`, including the two properties that are load-bearing rather than
/// stylistic: `isOpaque = false` (an opaque panel makes every terminal behind it believe it is
/// occluded and stop rendering) and `hasShadow = false` (a borderless non-opaque panel casts no system
/// shadow at all — measured — so the content draws its own).
@MainActor
final class DetachedPaneDragPreview {
  static let shared = DetachedPaneDragPreview()

  /// Margin around the ghost for its drawn shadow to land in, so the panel does not clip it.
  private static let shadowMargin: CGFloat = 24

  private var panel: NSPanel?
  private var host: NSHostingView<DetachedPaneGhost>?

  /// Show (or move) the ghost, with its top-left at `screenPoint` — the same placement
  /// `DetachedPaneWindows.open` gives the real window, so the preview does not lie about where the
  /// pane will end up.
  func show(title: String, glyph: String?, at screenPoint: CGPoint) {
    let size = DetachedPaneWindows.defaultSize
    let panelSize = NSSize(
      width: size.width + 2 * Self.shadowMargin, height: size.height + 2 * Self.shadowMargin)
    let panel = existingPanel(size: panelSize)
    host?.rootView = DetachedPaneGhost(title: title, glyph: glyph, size: size)
    panel.setFrameTopLeftPoint(
      CGPoint(x: screenPoint.x - Self.shadowMargin, y: screenPoint.y + Self.shadowMargin))
    if !panel.isVisible { panel.orderFront(nil) }
  }

  /// Hide the ghost. Idempotent, and called unconditionally when a drag ends — including the drags
  /// that never left the window, where it was never shown.
  func hide() {
    panel?.orderOut(nil)
  }

  private func existingPanel(size: NSSize) -> NSPanel {
    if let panel {
      if panel.frame.size != size { panel.setContentSize(size) }
      return panel
    }
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    // A drag is in flight over this panel the whole time it is up; it must never intercept the mouse.
    panel.ignoresMouseEvents = true
    panel.setAccessibilityIdentifier("detachedPane.dragPreview")

    let host = NSHostingView(rootView: DetachedPaneGhost(title: "", glyph: nil, size: size))
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    self.host = host
    self.panel = panel
    return panel
  }
}

/// Whether a SwiftUI `.global` point has left the window the drag started in (issue #172).
///
/// `.global` is the window's own coordinate space with its origin at the window's top-left, so the
/// window is simply the rect at the origin — see `RootView.workroomChipLocal`, which already reads it
/// that way. AppKit keeps the mouse-down window key for the life of a drag, which is what makes
/// `keyWindow` the right window to ask about. With no key window nothing is outside anything.
@MainActor
func isDragOutsideWindow(_ globalPoint: CGPoint) -> Bool {
  guard let size = NSApp.keyWindow?.frame.size else { return false }
  return !CGRect(origin: .zero, size: size).contains(globalPoint)
}

/// What the ghost draws: an outline of the window the drop will create, carrying the pane's own title
/// bar so it reads as *this* pane rather than a generic rectangle.
struct DetachedPaneGhost: View {
  let title: String
  let glyph: String?
  let size: CGSize

  private let theme = ThemeService.shared

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        if let glyph {
          Image(systemName: glyph)
            .font(.system(size: 10))
            .foregroundStyle(theme.tokens.fgMuted)
        }
        Text(title)
          .font(.subheadline)
          .lineLimit(1)
          .foregroundStyle(.primary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .frame(height: PaneTitleBarMetrics.height)
      .background(theme.tokens.panel)
      Rectangle().fill(theme.tokens.border).frame(height: 1)
      // The body is deliberately empty: this is the window you are about to get, not a live preview
      // of its contents — the pane itself has not moved yet.
      theme.tokens.bg
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .overlay(shape.strokeBorder(theme.tokens.accent.opacity(0.9), lineWidth: 2))
    // Drawn, not `panel.hasShadow`: a borderless non-opaque panel casts no system shadow.
    .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    .opacity(0.92)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
