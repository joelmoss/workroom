import Foundation
import WorkroomDomain

/// What a version-control action (a commit, a pull request action) acts on: captured when the user
/// acts and never re-derived, since the selection, or the folder a terminal is in, can move while a
/// sheet is open or a hook runs.
enum VCSActionTarget: Hashable, Sendable {
  /// A project root's or a workroom's working copy, by its sidebar row.
  case row(SidebarID)
  /// A repository a terminal's inspector follows that is no sidebar row's (#808, ADR 0081), by its
  /// canonical root. Addressable only while some window follows it.
  case followed(root: String)

  /// The sidebar row it names, nil for a followed repository.
  var sidebarID: SidebarID? {
    if case .row(let sid) = self { return sid }
    return nil
  }

  /// The followed repository's canonical root, nil for a row.
  var followedRoot: String? {
    if case .followed(let root) = self { return root }
    return nil
  }

  /// What a failure dialog calls a followed repository: its root, `~`-abbreviated. Nil for a row,
  /// which goes by its label.
  var followedName: String? {
    followedRoot.map { ($0 as NSString).abbreviatingWithTildeInPath }
  }
}

/// A write addressed a followed repository no window follows any more: the terminal moved to
/// another folder, or its window closed, after the user acted. The write is refused, never sent to
/// the repository the terminal is in now.
struct FollowedRepositoryGone: LocalizedError, CustomStringConvertible {
  var errorDescription: String? { description }
  var description: String { "That repository is no longer available." }
}
