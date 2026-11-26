import AppKit
import SwiftUI

/// The one ghost every drag inside a window carries (#652): the dragged thing's title and a grip in
/// a capsule, just above the pointer, whatever is dragged (a workroom's or terminal's title-bar tab,
/// a pane tab, a pane's or group's title bar, a workroom's sidebar row) and wherever it goes over
/// the window (sidebar, title bar, panes). A floating panel, not an overlay of one view, so it
/// follows the pointer across all of them. Out of the window, the drag shows the window it would
/// make instead (`DetachedPaneDragPreview`). A terminal's sidebar row is the exception: the List
/// draws its own drag image, and replacing it means SwiftUI's private table. An Open row carries a
/// copy of itself instead (`OpenRowLift`).
@MainActor
final class DragGhost {
  static let shared = DragGhost()

  /// How far above the pointer the capsule's bottom sits, so the pointer never covers it and no
  /// drop under the pointer meets it.
  static let lift: CGFloat = 2
  private static let size = NSSize(width: 360, height: 50)

  private var panel: NSPanel?
  private var host: NSHostingView<DragGhostChip>?

  /// The ghosts' windows, which a drop under the pointer looks past.
  static var windowNumbers: Set<Int> {
    Set(
      [
        shared.panel?.windowNumber, DetachedPaneDragPreview.shared.windowNumber,
        OpenRowLift.shared.ghost.windowNumber,
      ].compactMap(\.self))
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
    let host = NSHostingView(rootView: DragGhostChip(title: ""))
    let panel = DragGhostPanel.make(identifier: "dragGhost", size: Self.size, content: host)
    self.host = host
    self.panel = panel
    return panel
  }
}

/// The panel a drag's ghost floats in (`DragGhost`, `OpenRowGhost`, `DetachedPaneDragPreview`):
/// borderless, non-activating and mouse-transparent, so it follows the pointer anywhere on screen
/// and a drag in flight over it never meets it.
enum DragGhostPanel {
  /// A panel of `size` showing `content`, which fills it, marked `identifier` for accessibility.
  @MainActor
  static func make(identifier: String, size: NSSize = .zero, content: NSView) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    // Not opaque, or every terminal behind it believes it is occluded and stops rendering. No
    // shadow: a borderless non-opaque panel casts none (measured), so its content draws its own.
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = true
    panel.setAccessibilityIdentifier(identifier)
    content.autoresizingMask = [.width, .height]
    panel.contentView = content
    return panel
  }
}

/// What the ghost draws: a grip and the title in a capsule, with a shadow.
struct DragGhostChip: View {
  let title: String
  /// Sits at the bottom of the ghost's panel, filling it; else just the chip and its margin.
  var fillsPanel = true

  /// Room all round for the shadow to fade out inside the panel, which would otherwise clip it.
  static let margin: CGFloat = 12

  var body: some View {
    let chip = HStack(spacing: 5) {
      Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold))
      Text(title).font(.caption).lineLimit(1)
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    .fixedSize()
    .padding(Self.margin)
    .allowsHitTesting(false)
    if fillsPanel {
      chip.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    } else {
      chip
    }
  }
}
