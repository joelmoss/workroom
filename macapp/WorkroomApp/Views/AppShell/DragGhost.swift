import AppKit
import SwiftUI

/// The one ghost every drag inside a window carries (#652): the dragged thing's title and a grip in
/// a capsule, just above the pointer, whatever is dragged (a workroom's or terminal's title-bar tab,
/// a pane tab, a pane's or group's title bar, a workroom's sidebar row) and wherever it goes over
/// the window (sidebar, title bar, panes). A floating panel, not an overlay of one view, so it
/// follows the pointer across all of them. Out of the window, the drag shows the window it would
/// make instead (`DetachedPaneDragPreview`). A terminal's sidebar row is the exception: the List
/// draws its own drag image, and replacing it means SwiftUI's private table.
@MainActor
final class DragGhost {
  static let shared = DragGhost()

  /// How far above the pointer the capsule's bottom sits, so the pointer never covers it and no
  /// drop under the pointer meets it.
  private static let lift: CGFloat = 6
  private static let size = NSSize(width: 360, height: 40)

  private var panel: NSPanel?
  private var host: NSHostingView<DragGhostChip>?

  /// The ghosts' windows, which a drop under the pointer looks past.
  static var windowNumbers: Set<Int> {
    Set(
      [shared.panel?.windowNumber, DetachedPaneDragPreview.shared.windowNumber].compactMap(\.self))
  }

  /// Shows (or moves) the ghost for `title` just above `screenPoint`.
  func show(title: String, at screenPoint: CGPoint) {
    let panel = existingPanel()
    if host?.rootView.title != title { host?.rootView = DragGhostChip(title: title) }
    panel.setFrameOrigin(
      CGPoint(x: screenPoint.x - Self.size.width / 2, y: screenPoint.y + Self.lift))
    if !panel.isVisible { panel.orderFront(nil) }
  }

  /// Hides the ghost. Idempotent: every drag's end calls it.
  func hide() {
    if panel?.isVisible == true { panel?.orderOut(nil) }
  }

  private func existingPanel() -> NSPanel {
    if let panel { return panel }
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    // Not opaque, or every terminal behind it believes it is hidden (`DetachedPaneDragPreview`).
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = true
    panel.setAccessibilityIdentifier("dragGhost")
    let host = NSHostingView(rootView: DragGhostChip(title: ""))
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    self.host = host
    self.panel = panel
    return panel
  }
}

/// What the ghost draws: a grip and the title in a capsule, with a shadow.
struct DragGhostChip: View {
  let title: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold))
      Text(title).font(.caption).lineLimit(1)
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    .fixedSize()
    // Room below for its shadow, which the panel would otherwise clip.
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .allowsHitTesting(false)
  }
}
