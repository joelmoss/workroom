import SwiftUI

/// The shared right-click menu items for a workroom, reused by the tab chip
/// (`WorkroomTabBar`) and the split group title bar (`WorkroomSplitView`) — issue #112. One
/// source of truth so the two menus can't drift.
///
/// `closeName != nil` renders the "Close" item (close the whole workroom — all its terminal
/// tabs — the files stay) with that display name.
///
/// `onRemoveFromSplit != nil` renders a "Remove from Split" item that pops this workroom out of the
/// split (keeps it running) — the menu equivalent of the title bar's `pip.exit` ✕. Only the split
/// title bar passes it; the tab chip passes `nil` (a tab isn't a split member).
///
/// Label + Delete apply only to a real workroom (roots are never labelled or deletable), gated
/// on `store.workroomAndProject(for:)`.
///
/// Each item sets a store flag that `RootView`'s `.confirmationDialog`/`.sheet` bridge observes
/// (the store-flag → dialog pattern), except "Remove Label"/"Remove from Split" which act immediately.
///
/// `@MainActor` because it touches the main-actor `AppStore`; the callers' `.contextMenu` closures
/// are already main-actor-isolated (they live in `View.body`), so this is a no-op at the call site.
@MainActor
@ViewBuilder
func workroomContextMenu(
  store: AppStore, sid: SidebarID, target: TerminalTarget, closeName: String?,
  onRemoveFromSplit: (() -> Void)? = nil
) -> some View {
  if let closeName {
    // Close the whole workroom (all its tabs); the workroom's files stay. Confirmed via
    // RootView's `pendingWorkroomClose` dialog.
    Button {
      store.pendingWorkroomClose = PendingWorkroomClose(target: target, name: closeName)
    } label: {
      Label("Close", systemImage: "xmark")
    }
  }
  if let onRemoveFromSplit {
    // Pop this workroom out of the split (it keeps running) — same action as the title bar's ✕
    // (`pip.exit`). Acts immediately; no confirmation.
    Button {
      onRemoveFromSplit()
    } label: {
      Label("Remove from Split", systemImage: "pip.exit")
    }
  }
  // Label + delete only apply to a workroom (roots are never labelled or deletable). Mirrors the
  // sidebar row's context menu (issue #41 + delete).
  if let pair = store.workroomAndProject(for: sid) {
    // Leading divider only when a top item (Close / Remove from Split) was shown above.
    if closeName != nil || onRemoveFromSplit != nil { Divider() }
    Button {
      store.pendingWorkroomLabel = PendingWorkroomLabel(
        workroom: pair.workroom, project: pair.project)
    } label: {
      Label(pair.workroom.label == nil ? "Set Label…" : "Edit Label…", systemImage: "pencil")
    }
    if pair.workroom.label != nil {
      Button {
        store.removeWorkroomLabel(pair.workroom, in: pair.project)
      } label: {
        Label("Remove Label", systemImage: "pencil.slash")
      }
    }
    Divider()
    Button(role: .destructive) {
      store.pendingDeletion = PendingWorkroomDeletion(
        workroom: pair.workroom, project: pair.project)
    } label: {
      Label("Delete Workroom…", systemImage: "trash")
    }
    // Can't delete a workroom while its setup is still running against the worktree (issue #116).
    .disabled(store.isCreatingWorkroom(pair.workroom, in: pair.project))
  }
}
