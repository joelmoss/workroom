import Foundation
import WorkroomDomain
import WorkroomVCS

/// A VCS remote action queued behind a confirmation. Only a pull over a dirty working tree needs one:
/// `--autostash` stashes and reapplies, and workroom trees are essentially always dirty, so this fires
/// most times someone pulls — the copy has to be worth reading rather than a speed bump.
///
/// Carries the `SidebarID` it was raised for, and `AppStore.runRemoteAction` verifies it: the dialog is
/// not modal to the sidebar, so the selection can move while it is open.
struct PendingVCSAction: Identifiable, Equatable, Sendable {
  let action: VCSRemoteAction
  let sid: SidebarID
  /// The followed repository it was raised for (`RemoteStateModel.Target.followedRoot`), nil for a
  /// row's: the terminal's row is the same wherever its shell `cd`s, so the root is what
  /// `runRemoteAction` verifies for one (#808).
  var followedRoot: String? = nil
  var id: String { "\(action.rawValue)-\(sid.hashValue)-\(followedRoot ?? "")" }
}
