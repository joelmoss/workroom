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
/// - **This workroom is still being created** (`store.creations[target.id]`): `WorkroomTerminalsView`
///   mounts (and its `.task` creates the first terminal) only once its setup dialog is dismissed. The
///   pane draws that create's OWN log and its own Dismiss (issue #167, defect 4) — one `creation` slot
///   used to mean a co-displayed pane rendered whichever create last took the slot, so the second pane
///   of a create-as-split showed the wrong session and dismissed the wrong target. The FOCUSED create
///   is drawn window-level over the whole detail instead (issue #116, `RootView.detailContent`), which
///   is chrome-less because there's nothing to act on yet; this pane is the co-displayed case.
struct TargetTerminalDetail: View {
  let target: TerminalTarget
  /// Whether this workroom pane is the focused one — gates terminal first-responder so a co-displayed
  /// non-focused workroom doesn't steal focus on mount (issue #23 follow-up). `true` for a solo target.
  var surfaceActive: Bool = true
  /// Whether this workroom is itself one member of a multi-workroom split — forwarded to
  /// `WorkroomTerminalsView` (see `PaneTreeView.workroomIsSplit`).
  var workroomIsSplit: Bool = false
  @EnvironmentObject var store: AppStore

  var body: some View {
    ZStack {
      if !target.isMissing && !store.isCreationBlocking(target.id) {
        WorkroomTerminalsView(
          target: target, sessions: store.terminals, surfaceActive: surfaceActive,
          workroomIsSplit: workroomIsSplit)
      }
      // Exactly the `isCreationBlocking` condition above, so the terminal is withheld iff this
      // dialog covers it — one predicate, no drift. A NO-setup create deliberately draws nothing:
      // its terminal mounts immediately, and `CreationLoader` has no background, so drawing it here
      // would float "Creating workroom…" over a live terminal rather than replace it.
      if let creation = store.creations[target.id], creation.hasSetup {
        SetupOverlay(session: creation.session) { store.dismissCreation(target.id) }
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
