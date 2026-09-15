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
///   mounts (and its `.task` creates the first terminal) only once that entry clears — the setup
///   dialog being dismissed, or the loader giving way when a no-setup create ends. The pane draws that
///   create's OWN log and its own Dismiss (issue #167, defect 4) — one `creation` slot used to mean a
///   co-displayed pane rendered whichever create last took the slot, so the second pane of a
///   create-as-split showed the wrong session and dismissed the wrong target.
///
///   Since issue #171 this is EVERY create that has a workroom, focused or not: `RootView.detailContent`
///   keeps the full-frame branch only for a create too young to have a target (and so too young to have
///   a pane). That is what lets ⌥⌘N show both halves of its split while the new one is still being
///   built, instead of blacking out the anchor it was created beside.
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
      // Mirrors `isCreationBlocking` EXACTLY, so the terminal is withheld iff something covers it —
      // one predicate, no drift. A no-setup create gets the loader rather than the dialog it never
      // had; it withholds too (issue #171), so the loader replaces a terminal instead of floating
      // over one.
      //
      // The `else` is the case that had neither: `settingUpWorkrooms` is SHARED across windows while
      // `creations` is per-window, so a second window looking at a workroom whose script this window
      // started withholds the terminal with no entry to draw from — a blank pane under a full title
      // bar, for the length of the script. It gets the loader; only the window that owns the dialog
      // can show the log.
      if let creation = store.creations[target.id] {
        if creation.hasSetup {
          SetupOverlay(session: creation.session) { store.dismissCreation(target.id) }
        } else {
          CreationLoader()
        }
      } else if store.isCreationBlocking(target.id) {
        CreationLoader()
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
