/// The terminal surfaces of one window's tabs, by tab id. A tab is a value (`TerminalTab`) that
/// holds no view; `TerminalSessions` keeps each terminal tab's `GhosttySurfaceView` here, from the
/// moment the tab is made (`makeTerminalTab`) until it is closed, reaped or handed to another
/// window (#444), which takes the views with the tabs. So every terminal tab this window holds has
/// exactly one entry, and a content tab has none.
///
/// Holding a view here keeps it alive, as the tab value used to: when an entry goes is when this
/// window stops keeping the view, never when it frees the surface. That is `tearDown`, which the
/// sessions call first.
struct SurfaceRegistry {
  private var views: [TerminalTab.ID: GhosttySurfaceView] = [:]

  /// The surface of `tabID`, or nil for a content tab or a tab this window does not hold.
  subscript(tabID: TerminalTab.ID) -> GhosttySurfaceView? { views[tabID] }

  mutating func register(_ view: GhosttySurfaceView, for tabID: TerminalTab.ID) {
    views[tabID] = view
  }

  /// Stop keeping `tabID`'s surface, and return it.
  @discardableResult
  mutating func remove(_ tabID: TerminalTab.ID) -> GhosttySurfaceView? {
    views.removeValue(forKey: tabID)
  }

  /// Stop keeping the surfaces of `tabIDs`, and return them by tab id: what a hand-off carries.
  @discardableResult
  mutating func remove(_ tabIDs: [TerminalTab.ID]) -> [TerminalTab.ID: GhosttySurfaceView] {
    var removed: [TerminalTab.ID: GhosttySurfaceView] = [:]
    for id in tabIDs {
      if let view = views.removeValue(forKey: id) { removed[id] = view }
    }
    return removed
  }
}
