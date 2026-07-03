import SwiftUI

/// The terminal body for one target (issue #23). Lifted out of `RootView.targetDetail` so the detail
/// pane (Projects mode) and each Workrooms-mode tab render identical terminal UI. Carries **no**
/// navigation title or toolbar — the caller owns that chrome (`RootView` at the split level;
/// `WorkroomModeView` at the window level, driven by the focused tab).
///
/// While this workroom is being created with a setup script (`isCreationBlocking`), its terminal is
/// withheld — `WorkroomTerminalsView` mounts (and its `.task` creates the first terminal) only once
/// the setup dialog is dismissed. The dialog is drawn window-level over the whole detail (issue #116,
/// see `RootView.detail`), not per-target here.
struct TargetTerminalDetail: View {
  let target: TerminalTarget
  /// Whether this workroom pane is the focused one — gates terminal first-responder so a co-displayed
  /// non-focused workroom doesn't steal focus on mount (issue #23 follow-up). `true` for a solo target.
  var surfaceActive: Bool = true
  /// Forwarded to the terminals view — a split member (issue #110) draws a tighter gutter to its group
  /// card. Default `false` keeps the solo gutter.
  var compact: Bool = false
  @EnvironmentObject var store: AppStore

  var body: some View {
    ZStack {
      if !store.isCreationBlocking(target.id) {
        WorkroomTerminalsView(
          target: target, sessions: store.terminals, surfaceActive: surfaceActive,
          compact: compact)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
