import AppKit
import DesignSystem
import SwiftUI

/// What keeps a window's drop zones and shows the one a terminal drag is over (#652): a window's
/// store, or the Quick Terminal's host, whose pane tabs take a drag from any window.
@MainActor
protocol PaneDropZoneHost: AnyObject {
  /// The zone a terminal drag would drop on now, which shows the drop accent: set by the dragging
  /// window's session (`TerminalDragSession`).
  var incomingPaneDrop: PaneDropZone? { get set }
  /// The zones' views (`PaneDropZoneMarker`), which say where each is on screen at the drag's
  /// start.
  var paneDropZoneViews: [PaneDropZone: [PaneDropZoneMarker.Box]] { get set }
}

/// Marks a sidebar row, the Terminals heading, a pane tab or a group's title bar as somewhere a
/// terminal drag can be let go (#660, #652): registers a view with its window's host, which the
/// drag's session asks where it is on screen when the drag starts (`AppStore.terminalDropZones`).
/// The sidebar sits in its own hosting view, so SwiftUI's frames are not in the tab strip's space.
struct PaneDropZoneMarker: NSViewRepresentable {
  /// A weak hold on a zone's view, so a row scrolled away or gone drops out.
  final class Box {
    weak var view: NSView?
    /// The view is a pane tab's, whose halves are before and after it.
    let isPaneTab: Bool
    init(_ view: NSView, isPaneTab: Bool) {
      self.view = view
      self.isPaneTab = isPaneTab
    }
  }

  let store: any PaneDropZoneHost
  let zone: PaneDropZone
  var isPaneTab = false

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
      zones[zone, default: []].append(Box(view, isPaneTab: isPaneTab))
    }
    store.paneDropZoneViews = zones
  }

  static func dismantleNSView(_ view: NSView, coordinator: ()) {}

  /// Takes no clicks: the row under it keeps them.
  private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// The marker under a row, and the accent over it while a drag here would drop on it; for a
/// terminal's place (`PaneDropZone.tab`), an insertion mark on the side it would land.
private struct PaneDropZoneModifier: ViewModifier {
  let store: any PaneDropZoneHost
  let zone: PaneDropZone
  let isPaneTab: Bool

  func body(content: Content) -> some View {
    content
      .background(PaneDropZoneMarker(store: store, zone: zone, isPaneTab: isPaneTab))
      .overlay(alignment: markAlignment) {
        if insertion != nil {
          DropInsertionMark(vertical: isPaneTab)
        } else if store.incomingPaneDrop == zone {
          DropAccent(cornerRadius: Radius.s)
        }
      }
  }

  /// Where the insertion mark sits: a pane tab's leading or trailing edge, a row's top.
  private var markAlignment: Alignment {
    guard let after = insertion else { return .center }
    if !isPaneTab { return .top }
    return after ? .trailing : .leading
  }

  /// Whether the drop would land after (true) or before (false) this terminal's place, or nil
  /// when no positional drop is over it.
  private var insertion: Bool? {
    switch (zone, store.incomingPaneDrop) {
    case (.tab(let tab, let container, _), .tab(let hovered, let over, let after)):
      return hovered == tab && over == container ? after : nil
    case (.terminalRow, let hovered?) where hovered == zone:
      return false
    default:
      return nil
    }
  }
}

/// The accent line between two terminals' places where a drop would land: a vertical caret
/// between pane tabs, a horizontal line above a sidebar row.
struct DropInsertionMark: View {
  let vertical: Bool

  var body: some View {
    Capsule()
      .fill(Color.accentColor)
      .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
      .padding(vertical ? .vertical : .horizontal, 3)
      .allowsHitTesting(false)
      .accessibilityIdentifier("dropInsertionMark")
  }
}

extension View {
  /// Makes pane tab `tab` of `target` somewhere a terminal drag can land, before or after it
  /// (#652): a drag in its own window, or, for the Quick Terminal panel's strip, one from any
  /// window while the panel shows.
  @ViewBuilder
  func paneTabDropZone(_ tab: TerminalTab.ID, of target: TerminalTarget, host: (any PaneHost)?)
    -> some View
  {
    if let store = host as? any PaneDropZoneHost, let owner = target.id.sidebarID {
      paneDropZone(.tab(tab, in: owner, after: false), store: store, isPaneTab: true)
    } else {
      self
    }
  }

  /// Makes this view `zone`, somewhere a terminal drag over `store`'s window can drop; a pane tab's
  /// halves are before and after it.
  func paneDropZone(_ zone: PaneDropZone, store: any PaneDropZoneHost, isPaneTab: Bool = false)
    -> some View
  {
    modifier(PaneDropZoneModifier(store: store, zone: zone, isPaneTab: isPaneTab))
  }
}
