import AppKit
import SwiftUI

/// A pane-tree leaf's slot, registered with `PaneSlotAnchors` so a pop out can grow out of it and a
/// pull back land in it (issue #172). An empty view the size of the slot, behind it, that draws
/// nothing and takes no clicks.
struct PaneSlotAnchor: NSViewRepresentable {
  /// Nil registers nothing: a leaf in the pane's own window.
  let tabID: TerminalTab.ID?

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    view.tabID = tabID
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.tabID = tabID
  }

  static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
    view.tabID = nil
  }

  final class AnchorView: NSView {
    var tabID: TerminalTab.ID? {
      didSet {
        guard tabID != oldValue else { return }
        if let oldValue { PaneSlotAnchors.shared.unregister(self, for: oldValue) }
        if let tabID { PaneSlotAnchors.shared.register(self, for: tabID) }
      }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // The slot a pane last mounted in is its slot: a tab moved to another window re-registers.
      if window != nil, let tabID { PaneSlotAnchors.shared.register(self, for: tabID) }
    }
  }
}
