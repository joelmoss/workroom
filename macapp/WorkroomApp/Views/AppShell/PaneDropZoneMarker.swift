import AppKit
import SwiftUI

/// Marks a sidebar row, or the Terminals heading, as somewhere a terminal tab dragged inside its
/// window can be let go (#660): registers a view with the window's store, which asks it where it
/// is on screen at the moment of the drag (`AppStore.paneDropZone(at:)`). The sidebar sits in its
/// own hosting view, so SwiftUI's frames are not in the tab strip's space.
struct PaneDropZoneMarker: NSViewRepresentable {
  /// A weak hold on a zone's view, so a row scrolled away or gone drops out.
  final class Box {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }

  let store: AppStore
  let zone: PaneDropZone

  func makeNSView(context: Context) -> NSView {
    let view = PassThroughView()
    register(view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    register(view)
  }

  /// Marks `view` as `zone`'s, and only `zone`'s: a reused row's view moves to the zone it shows
  /// now. Views that have gone drop out.
  private func register(_ view: NSView) {
    var zones = store.paneDropZoneViews
    for (other, boxes) in zones {
      let kept = boxes.filter { $0.view != nil && ($0.view !== view || other == zone) }
      zones[other] = kept.isEmpty ? nil : kept
    }
    if !(zones[zone] ?? []).contains(where: { $0.view === view }) {
      zones[zone, default: []].append(Box(view))
    }
    store.paneDropZoneViews = zones
  }

  static func dismantleNSView(_ view: NSView, coordinator: ()) {}

  /// Takes no clicks: the row under it keeps them.
  private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// The marker under a row, and the accent over it while a tab dragged here would move into it.
private struct PaneDropZoneModifier: ViewModifier {
  let store: AppStore
  let zone: PaneDropZone

  func body(content: Content) -> some View {
    content
      .background(PaneDropZoneMarker(store: store, zone: zone))
      .overlay {
        if store.incomingPaneDrop == zone { DropAccent(cornerRadius: 6) }
      }
  }
}

extension View {
  /// Makes this row `zone`, somewhere a terminal tab dragged in `store`'s window can move to.
  func paneDropZone(_ zone: PaneDropZone, store: AppStore) -> some View {
    modifier(PaneDropZoneModifier(store: store, zone: zone))
  }
}
