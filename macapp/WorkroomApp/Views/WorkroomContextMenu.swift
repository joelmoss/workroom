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
/// Whether `openInSplitMenuItem` renders anything — read by `workroomContextMenu` so its leading
/// divider tracks the item, instead of the two drifting apart.
@MainActor
func canOpenInSplit(store: AppStore, sid: SidebarID) -> Bool {
  // The store's own predicate, not a re-derived subset: it also refuses a missing directory and a
  // pane too narrow to hold two halves, so the item disappears in exactly the states where
  // choosing it could not have worked.
  store.canOpenAsSplit(sid)
}

/// "Open (split right)" — open this workroom beside the current one (issue #163), the mouse-reachable
/// equivalent of ⌥⌘O and of dragging the row onto a pane edge. Shared by `workroomContextMenu`
/// (tab chip + split pane title bar) and `ProjectSidebar`'s own inline row menu.
///
/// Hidden only when there is nothing to split beside, or when this workroom IS the selection.
/// Deliberately NOT also hidden for a workroom already in the visible group: every rendered pane
/// title bar belongs either to the selected solo workroom or to the visible group, so that guard
/// would make the item unreachable on that whole surface. Invoked on a non-focused member it moves
/// that pane to the right of the focused one — a real rearrange, and exactly what dragging the
/// same title bar already does (`insertWorkroomSplit` is "a move, not a duplicate").
@MainActor
@ViewBuilder
func openInSplitMenuItem(store: AppStore, sid: SidebarID) -> some View {
  if canOpenInSplit(store: store, sid: sid) {
    Button {
      store.openExistingAsSplit(sid)
    } label: {
      // `rectangle.trailinghalf.inset.filled` is the app's established glyph for a rightward split
      // (TerminalTabStrip's Split Right toolbar button and context item), and this action always
      // inserts on `.right` — so it wears the same icon rather than a neutral one.
      Label("Open (split right)", systemImage: "rectangle.trailinghalf.inset.filled")
    }
  }
}

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
  openInSplitMenuItem(store: store, sid: sid)
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
    // Leading divider only when a top item (Close / Remove from Split / Open (split right)) showed.
    if closeName != nil || onRemoveFromSplit != nil || canOpenInSplit(store: store, sid: sid) {
      Divider()
    }
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
