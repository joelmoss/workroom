import AppKit
import SwiftUI

/// Where each snapshottable region currently is on screen, reported by the views that own them.
///
/// The rects have to come from the view tree because nothing else knows the split geometry — a
/// workroom's pane can be any leaf of an arbitrary split tree. They're read *synchronously* when a
/// capture is planned, never stored across an await, so a layout change between plan and delivery can't
/// mislabel a crop (the service's epoch guard is what enforces that).
@MainActor
final class SnapshotRegistry {
  static let shared = SnapshotRegistry()

  /// One reported region: the view, and the key whose picture it is.
  private struct Region {
    weak var view: NSView?
    let key: SnapshotKey
  }

  private var regions: [ObjectIdentifier: Region] = [:]

  func register(_ view: NSView, for key: SnapshotKey) {
    regions[ObjectIdentifier(view)] = Region(view: view, key: key)
  }

  func unregister(_ view: NSView) {
    regions[ObjectIdentifier(view)] = nil
  }

  /// Every live region in `window`, as `(key, rect-in-AppKit-screen-coordinates)`.
  ///
  /// Prunes dead views as it goes — the reporter's `removeFromSuperview` is not a guaranteed hook, so
  /// the weak reference is the real lifetime signal.
  func regions(in window: NSWindow) -> [(key: SnapshotKey, rect: CGRect)] {
    var dead: [ObjectIdentifier] = []
    var result: [(key: SnapshotKey, rect: CGRect)] = []
    for (id, region) in regions {
      guard let view = region.view else {
        dead.append(id)
        continue
      }
      guard view.window === window, !view.bounds.isEmpty else { continue }
      // View → window → screen, in AppKit's y-up space. `SnapshotGeometry` performs the single flip.
      let inWindow = view.convert(view.bounds, to: nil)
      result.append((region.key, window.convertToScreen(inWindow)))
    }
    for id in dead { regions[id] = nil }
    return result
  }

  /// Test seam: how many regions are currently registered.
  var count: Int { regions.count }
}

/// A zero-drawing `NSView` that reports its own frame to `SnapshotRegistry` for as long as it is in a
/// window. Mounted with `.background { }` so it inherits the exact bounds of whatever it decorates
/// without affecting layout.
///
/// Deliberately NOT a `GhosttySurfaceView` read: the surface is Metal-backed, so there is no
/// `cacheDisplay` to draw it into. All this does is say *where* to crop the window capture.
struct SnapshotRectReporter: NSViewRepresentable {
  let key: SnapshotKey

  func makeNSView(context: Context) -> ReporterView {
    let view = ReporterView()
    view.key = key
    return view
  }

  func updateNSView(_ view: ReporterView, context: Context) {
    // A leaf can be re-used for a different pane when a split changes shape, so re-key rather than
    // assuming the first key is forever.
    if view.key != key {
      SnapshotRegistry.shared.unregister(view)
      view.key = key
      if view.window != nil { SnapshotRegistry.shared.register(view, for: key) }
    }
  }

  static func dismantleNSView(_ view: ReporterView, coordinator: ()) {
    MainActor.assumeIsolated { SnapshotRegistry.shared.unregister(view) }
  }

  final class ReporterView: NSView {
    var key: SnapshotKey?

    override var isOpaque: Bool { false }
    /// Never take a click — this sits behind real content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let key else { return }
      if window != nil {
        SnapshotRegistry.shared.register(self, for: key)
      } else {
        SnapshotRegistry.shared.unregister(self)
      }
    }
  }
}
