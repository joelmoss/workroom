import Foundation

/// Identifies a selectable row in the project → (root | workroom) sidebar tree. Workroom
/// names can repeat across projects, and the root is per project, so both carry their
/// project path. The selected *terminal target* is one of these.
public enum SidebarID: Hashable, Sendable {
  case project(String)
  case root(project: String)
  case workroom(project: String, name: String)
  /// A create's provisional pane, shown from the click until the workroom has a name (#483).
  case creation(project: String, id: UUID)

  /// Whether this id is scoped to the given project path — its row, its root, or one of its
  /// workrooms. Used to clear selection when a whole project is deleted.
  public func belongsToProject(_ path: String) -> Bool {
    switch self {
    case .project(let p), .root(project: let p), .workroom(project: let p, name: _),
      .creation(project: let p, id: _):
      return p == path
    }
  }
}
