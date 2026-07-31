import SwiftUI

/// The terminal body for one target (issue #23). Lifted out of `RootView.targetDetail` so the detail
/// pane and each workroom pane render identical terminal UI. Carries **no** navigation title or
/// toolbar — the caller owns that chrome (`WorkroomPaneLeaf`'s title bar since issue #139).
///
/// Two states withhold the terminal, and both are expressed as siblings inside one `ZStack` rather
/// than as branches around it, so this view keeps a single structural position in its parent:
///
/// - **The directory is gone** (deleted on disk). Don't mount a terminal over a dead path. Every
///   visible workroom is guarded here, focused or not — `RootView` used to branch on `isMissing` for
///   the *selected* target only, which left a co-displayed split member rendering live terminal chrome
///   over a vanished path (issue #23 follow-up). The way out is the title bar's ✕.
/// - **A setup script is still running** against the new worktree (`isCreationBlocking`):
///   `WorkroomTerminalsView` mounts (and its `.task` creates the first terminal) only once the setup
///   dialog is dismissed. The dialog itself is drawn window-level over the whole detail (issue #116,
///   see `RootView.detail`), not per-target here.
struct TargetTerminalDetail: View {
  let target: TerminalTarget
  /// Whether this workroom pane is the focused one — gates terminal first-responder so a co-displayed
  /// non-focused workroom doesn't steal focus on mount (issue #23 follow-up). `true` for a solo target.
  var surfaceActive: Bool = true
  @EnvironmentObject var store: AppStore

  var body: some View {
    ZStack {
      if !target.isMissing && !store.isCreationBlocking(target.id) {
        WorkroomTerminalsView(
          target: target, sessions: store.terminals, surfaceActive: surfaceActive)
      }
      if target.isMissing {
        ContentUnavailableView {
          Label("Directory not found", systemImage: "questionmark.folder")
        } description: {
          Text("\(target.title) points at a path that no longer exists.\n\(target.path)")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
