import Foundation
import WorkroomDomain

/// What the sidebar shows under its switcher (ADR 0083): one view at a time, this window's Open
/// view (its workroom tabs, #819) or the Projects view (the project tree).
enum SidebarView: String, CaseIterable, Sendable {
  case open
  case projects

  /// Its tab's name: the Open tab shows only its glyph, so this is its tooltip and spoken name.
  var title: String {
    switch self {
    case .open: "Open"
    case .projects: "Projects"
    }
  }

  /// Its tab's tooltip.
  var help: String {
    switch self {
    case .open: "Open: the workrooms and terminals open in this window"
    case .projects: "Projects: every project and its workrooms"
    }
  }

  /// Its tab's accessibility identifier.
  var identifier: String { "sidebar.view.\(rawValue)" }
}

/// Which view the sidebar shows, and whether the one it hides needs the user. The selection is
/// this window's own and is saved with its session (`WindowSession.sidebarView`), as its Open
/// rows' folds are.
extension AppStore {
  /// Show `view` in the sidebar, as its tab does. A no-op when it shows already.
  func selectSidebarView(_ view: SidebarView) {
    guard sidebarView != view else { return }
    sidebarView = view
  }

  /// View ▸ Show Open / Show Projects: `view`, in the sidebar, shown if it is hidden.
  func showSidebarView(_ view: SidebarView) {
    selectSidebarView(view)
    if sidebarHasContent, !sidebarVisible { sidebarVisible = true }
  }

  /// Whether something in `view` waits on the user: a target with unread notifications or a
  /// terminal waiting for input, as its rows mark them. The switcher shows it on `view`'s tab while
  /// the other view is shown. Read from what the rows read, not from the rows.
  func sidebarViewNeedsAttention(_ view: SidebarView) -> Bool {
    switch view {
    case .open:
      return displayedWorkroomTargets().contains { _, target in needsAttention(target.id) }
    case .projects:
      return projectStore.projects.contains { $0.targetIDs.contains(where: needsAttention) }
    }
  }

  private func needsAttention(_ id: TerminalTarget.ID) -> Bool {
    notifications.count(target: id) > 0 || terminals.blockedTerminalCount(forTargetID: id) > 0
  }
}
