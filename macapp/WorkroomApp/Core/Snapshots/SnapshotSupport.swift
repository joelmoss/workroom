import CoreGraphics
import Foundation

/// What a snapshot belongs to. A workroom is keyed by its window too, because the same `SidebarID` can
/// be displayed in two windows at once and their captures are different pictures.
enum SnapshotKey: Hashable {
  case pane(TerminalTab.ID)
  case workroom(SidebarID, WindowToken)
}

/// One cached capture.
struct Snapshot {
  let image: CGImage
  /// The theme generation it was captured under. An older generation reads stale — the terminal's own
  /// colours changed, so the picture is of a theme that is no longer on screen.
  let themeGeneration: Int
  let capturedAt: Date
  /// Rough decoded size, for the cache's byte cap.
  var byteSize: Int { image.bytesPerRow * image.height }
}

/// The pixel arithmetic for turning one window capture into N per-pane thumbnails.
///
/// Pure and separately tested because **the plan was wrong here and the T1 spike caught it**. Two
/// assumptions that both look obviously true and are both false:
///
/// ```
/// NSWindow.frame       (200, 200, 820, 552)   AppKit: y-UP,   origin bottom-left
/// filter.contentRect   (205, 872, 810, 544)   CG:     y-DOWN, origin top-left, inset ~5pt x / ~4pt y
/// captured image        1620 x 1088  ==  contentRect × pointPixelScale(2.0), EXACTLY
/// ```
///
/// So (1) `contentRect` is **not** the window frame — deriving the scale from the delivered image
/// against the frame gave 1.9756 (x) and 1.9710 (y), neither 2.0 nor even equal to each other, a ~1.2%
/// error that drifts ~10px by the far edge of a large window; and (2) the y-flips do **not** cancel,
/// because `convertToScreen` is y-up while `contentRect` is y-down.
///
/// Hence: the reference rect is always `filter.contentRect`, the scale is always
/// `filter.pointPixelScale`, and the region is flipped exactly once.
enum SnapshotGeometry {

  /// Where `regionOnScreen` lands inside a window capture, in image pixels.
  ///
  /// - `regionOnScreen`: the pane's rect in AppKit screen coordinates (y-up).
  /// - `windowContentRect`: `SCContentFilter.contentRect` (CG, y-down) — NOT `NSWindow.frame`.
  /// - `mainScreenHeight`: `NSScreen.screens[0].frame.height`, the y-flip constant. One `NSScreen`
  ///   read the plan hoped to avoid and cannot.
  /// - `scale`: `SCContentFilter.pointPixelScale`.
  ///
  /// Returns nil when the region falls entirely outside the capture.
  static func cropRect(
    regionOnScreen: CGRect, windowContentRect: CGRect, mainScreenHeight: CGFloat, scale: CGFloat
  ) -> CGRect? {
    guard scale > 0, !regionOnScreen.isEmpty, !windowContentRect.isEmpty else { return nil }
    // The single y-flip: AppKit's bottom-left origin to CG's top-left.
    let cgMinY = mainScreenHeight - regionOnScreen.maxY
    let rect = CGRect(
      x: (regionOnScreen.minX - windowContentRect.minX) * scale,
      y: (cgMinY - windowContentRect.minY) * scale,
      width: regionOnScreen.width * scale,
      height: regionOnScreen.height * scale
    ).integral
    let bounds = CGRect(
      x: 0, y: 0, width: (windowContentRect.width * scale).rounded(),
      height: (windowContentRect.height * scale).rounded())
    let clamped = rect.intersection(bounds)
    return clamped.isNull || clamped.isEmpty ? nil : clamped
  }

  /// The capture's configured pixel size. **Strictly proportional to `contentRect`** — `width`/`height`
  /// are the only knobs the config exposes (`scalesToFit` aside), and a size whose aspect doesn't match
  /// letterboxes, which silently misaligns every crop taken from it.
  static func capturePixelSize(contentRect: CGRect, scale: CGFloat, maxLongEdge: CGFloat) -> CGSize
  {
    let full = CGSize(width: contentRect.width * scale, height: contentRect.height * scale)
    let longEdge = max(full.width, full.height)
    guard longEdge > maxLongEdge, longEdge > 0 else {
      return CGSize(width: full.width.rounded(), height: full.height.rounded())
    }
    let factor = maxLongEdge / longEdge
    return CGSize(
      width: (full.width * factor).rounded(), height: (full.height * factor).rounded())
  }

  /// Aspect-**fit** target for a thumbnail well — never a crop. A crop-zoom of two different panes can
  /// look identical, and at 72×56 the well's job is "which pane is this", not "read the output".
  static func thumbnailPixelSize(source: CGSize, maxPointSize: CGSize, scale: CGFloat) -> CGSize {
    guard source.width > 0, source.height > 0, scale > 0 else { return .zero }
    let target = CGSize(width: maxPointSize.width * scale, height: maxPointSize.height * scale)
    let factor = min(target.width / source.width, target.height / source.height, 1)
    return CGSize(
      width: max(1, (source.width * factor).rounded()),
      height: max(1, (source.height * factor).rounded()))
  }
}

/// An LRU cache of captures, bounded by both count and bytes.
///
/// Correctness does not depend on a purge-on-window-close hook: `WindowToken` is a UUID that is never
/// reused, so a workroom key from a closed window can never collide with a live one. The purges that
/// exist are about memory, not staleness.
final class SnapshotCache {
  static let maxEntries = 32
  /// ~48 MB of decoded bitmaps. A 1440-long-edge Retina window capture is roughly 4–6 MB.
  static let maxBytes = 48 * 1024 * 1024

  private var entries: [SnapshotKey: Snapshot] = [:]
  /// Most-recently-used last.
  private var order: [SnapshotKey] = []
  private let now: () -> Date

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  var count: Int { entries.count }
  var byteSize: Int { entries.values.reduce(0) { $0 + $1.byteSize } }

  /// A snapshot, if one is cached and still matches the current theme. A stale-theme entry is dropped
  /// rather than returned: the terminal's own colours changed, so the picture is of a theme that is no
  /// longer on screen.
  func snapshot(for key: SnapshotKey, themeGeneration: Int) -> Snapshot? {
    guard let entry = entries[key] else { return nil }
    guard entry.themeGeneration == themeGeneration else {
      remove(key)
      return nil
    }
    touch(key)
    return entry
  }

  func store(_ image: CGImage, for key: SnapshotKey, themeGeneration: Int) {
    entries[key] = Snapshot(image: image, themeGeneration: themeGeneration, capturedAt: now())
    touch(key)
    evictIfNeeded()
  }

  func remove(_ key: SnapshotKey) {
    entries[key] = nil
    order.removeAll { $0 == key }
  }

  func removeAll() {
    entries.removeAll()
    order.removeAll()
  }

  /// Drop everything for panes that no longer exist.
  func forgetPanes(_ ids: [TerminalTab.ID]) {
    for id in ids { remove(.pane(id)) }
  }

  private func touch(_ key: SnapshotKey) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func evictIfNeeded() {
    while entries.count > Self.maxEntries, let oldest = order.first {
      remove(oldest)
    }
    while byteSize > Self.maxBytes, order.count > 1, let oldest = order.first {
      remove(oldest)
    }
  }
}
