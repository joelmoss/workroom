/// The terminal surfaces of the app's tabs, by tab id (`TerminalTabs`). A tab is a value
/// (`TerminalTab`) that holds no view; each terminal tab's `GhosttySurfaceView` is kept here, from
/// the moment the tab is made (`makeTerminalTab`) until it is closed, reaped or its window goes. A
/// move to another window (#444) leaves it here. So every terminal tab has exactly one entry, and
/// a content tab has none.
///
/// Holding a view here keeps it alive, as the tab value used to: when an entry goes is when the app
/// stops keeping the view, never when it frees the surface. That is `tearDown`, which the window
/// holding the tab calls first.
struct SurfaceRegistry {
  private var views: [TerminalTab.ID: GhosttySurfaceView] = [:]

  /// The surface of `tabID`, or nil for a content tab.
  subscript(tabID: TerminalTab.ID) -> GhosttySurfaceView? { views[tabID] }

  mutating func register(_ view: GhosttySurfaceView, for tabID: TerminalTab.ID) {
    views[tabID] = view
  }

  /// Stop keeping `tabID`'s surface, and return it.
  @discardableResult
  mutating func remove(_ tabID: TerminalTab.ID) -> GhosttySurfaceView? {
    views.removeValue(forKey: tabID)
  }
}
