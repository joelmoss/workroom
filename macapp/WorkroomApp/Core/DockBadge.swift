import AppKit

/// The app's Dock-icon unread badge.
///
/// We composite the badge onto the app icon via `NSDockTile.contentView` rather than setting
/// `NSApp.dockTile.badgeLabel`, because in this app a linked framework suppresses the system's
/// automatic `badgeLabel` rendering — the value is set and held but is never drawn on the tile
/// (issue #32). A `contentView` renders as ordinary tile content (the same path the app icon
/// itself takes), so it's unaffected. Driven from `AppStore` off `NotificationCenterStore`'s
/// `onTotalChange` seam, so the badge tracks the count regardless of window/app state.
enum DockBadge {
  /// Show `count` on the Dock icon, or restore the plain icon at zero.
  static func apply(_ count: Int) {
    let tile = NSApp.dockTile
    guard let text = label(for: count) else {
      tile.contentView = nil  // nil ⇒ the system draws the default app icon
      tile.display()
      return
    }
    let view = NSImageView()
    view.image = badgedIcon(text)
    tile.contentView = view
    tile.display()
  }

  /// The badge text for an unread count: `nil` clears the badge; the count is capped at "99+" to
  /// match the in-app `UnreadBadge` pill (the cap itself is owned by `UnreadCount.label`). Pure,
  /// so it's unit-testable.
  static func label(for count: Int) -> String? {
    guard count > 0 else { return nil }
    return UnreadCount.label(count)
  }

  /// The app icon with a red badge (white, bold `text`) drawn in the top-right corner.
  private static func badgedIcon(_ text: String) -> NSImage {
    let side: CGFloat = 128
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    NSApp.applicationIconImage?.draw(in: NSRect(x: 0, y: 0, width: side, height: side))

    let attributes: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 30),
    ]
    let textSize = (text as NSString).size(withAttributes: attributes)
    let height: CGFloat = 46
    let width = max(height, textSize.width + 24)  // circle for 1–2 digits, capsule for "99+"
    let badge = NSRect(x: side - width - 2, y: side - height - 2, width: width, height: height)

    NSColor.systemRed.setFill()
    NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()
    (text as NSString).draw(
      at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
      withAttributes: attributes)

    image.unlockFocus()
    return image
  }
}
