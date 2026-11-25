import CoreGraphics
import Observation
import WorkroomDomain

/// A tab dragged into its target's panes to split them (issue #3), by its strip chip or by its row
/// in the sidebar's Open section (#819). One per target (`TerminalPanes.contentDrop(for:)`), so the
/// sidebar, which is not inside the target's view, reaches the same drop the strip does.
///
/// `preview` is the live drop preview `PaneTreeView` draws, in content-local coordinates. It is
/// observed per target, so a drag's ticks re-run only that target's terminals view. `frame` is the
/// pane area's frame in its window's `.global` space while `WorkroomTerminalsView` shows it, nil
/// otherwise: a measurement, not observed.
@MainActor
@Observable
final class TabContentDrop {
  var preview: PaneDragState?
  @ObservationIgnored var frame: CGRect?

  /// The content-local point for a drag at `global`, or nil outside the pane area.
  func localize(_ global: CGPoint) -> CGPoint? {
    guard let frame, frame.contains(global) else { return nil }
    return CGPoint(x: global.x - frame.minX, y: global.y - frame.minY)
  }

  /// Where a drop at `global` lands in `layout` (pane and edge), laid out as the renderer lays it
  /// out, or nil when it isn't over a pane.
  func dropTarget(
    at global: CGPoint, in layout: TerminalPaneLayout?
  ) -> (tab: TerminalTab.ID, edge: PaneEdge)? {
    guard let local = localize(global), let layout, let frame else { return nil }
    let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: frame.size))
    return PaneTreeLayout.dropTarget(at: local, panes: plan.panes)
  }
}

extension TerminalPanes {
  /// The layout `target`'s content renders: the focused tab's group when it has one, else that tab
  /// solo; nil with no tab.
  func contentLayout(for target: TerminalTarget) -> TerminalPaneLayout? {
    activeTab(for: target).map { split(for: target) ?? .leaf($0.id) }
  }

  /// Where a tab dropped at `global` lands in `target`'s panes, or nil when it isn't over one.
  func contentDropTarget(
    at global: CGPoint, for target: TerminalTarget
  ) -> (tab: TerminalTab.ID, edge: PaneEdge)? {
    contentDrop(for: target.id).dropTarget(at: global, in: contentLayout(for: target))
  }

  /// Tab `tabID` dragged to `global`: previews a drop into `target`'s panes while over them.
  /// Returns whether it is over them.
  @discardableResult
  func dragTab(_ tabID: TerminalTab.ID, of target: TerminalTarget, overContentAt global: CGPoint)
    -> Bool
  {
    let drop = contentDrop(for: target.id)
    drop.preview = drop.localize(global).map { PaneDragState(tabID: tabID, location: $0) }
    return drop.preview != nil
  }

  /// Tab `tabID` let go at `global`: over `target`'s panes it splits them, as a strip chip's drop
  /// does. Returns whether it landed there. Clears the preview either way.
  @discardableResult
  func dropTab(_ tabID: TerminalTab.ID, of target: TerminalTarget, onContentAt global: CGPoint)
    -> Bool
  {
    defer { contentDrop(for: target.id).preview = nil }
    guard let drop = contentDropTarget(at: global, for: target) else { return false }
    dropTabFromStrip(tabID, ontoEdge: drop.edge, of: drop.tab, for: target)
    return true
  }
}
