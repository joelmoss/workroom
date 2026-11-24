import Foundation
import WorkroomDomain
import WorkroomVCS

/// A VCS remote action queued behind a confirmation. Only a pull over a dirty working tree needs one:
/// `--autostash` stashes and reapplies, and workroom trees are essentially always dirty, so this fires
/// most times someone pulls — the copy has to be worth reading rather than a speed bump.
///
/// Carries what it was raised for (a row, or a followed repository by its root, #808), and
/// `AppStore.runRemoteAction` verifies it: the dialog is not modal to the sidebar, so the selection
/// can move, or the terminal's shell `cd` to another repository, while it is open.
struct PendingVCSAction: Identifiable, Equatable, Sendable {
  let action: VCSRemoteAction
  let target: VCSActionTarget
  var id: String { "\(action.rawValue)-\(target.hashValue)" }
}
