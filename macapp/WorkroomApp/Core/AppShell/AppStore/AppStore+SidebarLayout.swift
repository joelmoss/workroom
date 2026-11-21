import Foundation

/// The sidebar's two panes (#652), top to bottom: the Terminals section and the Projects section.
/// Each is a sticky heading over its own scrolling list, in the inspector's split
/// (`InspectorSplitView`).
enum SidebarPane: Int, CaseIterable {
  case terminals
  case projects
}

/// The sidebar's split layout. A pane's collapse is its section's fold, so there is one fold state
/// per section: the Terminals section's is `TerminalsSection.isFolded`, shared by every window and
/// kept in its file; the Projects section's is `projectsFolded`. The divider's position is
/// `sidebarPaneWeights`.
extension AppStore {
  /// Each pane's collapse, in `SidebarPane` order: its section's fold.
  var sidebarPanesCollapsed: [Bool] {
    SidebarPane.allCases.map(isCollapsed)
  }

  func isCollapsed(_ pane: SidebarPane) -> Bool {
    switch pane {
    case .terminals: terminalsSection.isFolded
    case .projects: projectsFolded
    }
  }

  /// Collapse or expand a pane: fold or unfold its section.
  func setCollapsed(_ pane: SidebarPane, _ collapsed: Bool) {
    switch pane {
    case .terminals: terminalsSection.isFolded = collapsed
    case .projects: projectsFolded = collapsed
    }
  }

  /// Record the pane heights the sidebar's split reports after the user drags its divider.
  func updateSidebarPaneWeights(_ weights: [Double]) {
    guard weights.count == SidebarPane.allCases.count, weights.allSatisfy({ $0 > 0 }),
      weights != sidebarPaneWeights
    else { return }
    sidebarPaneWeights = weights
  }
}
