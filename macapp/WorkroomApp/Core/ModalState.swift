import Foundation
import WorkroomDomain

/// Which command-palette dialog is showing (issue #94). A single `@Published` `ActivePicker?` on the
/// store drives both presenters, so raising one dialog automatically dismisses the other.
enum ActivePicker {
  case new
  case open
}

/// A workroom queued for deletion, awaiting the user's confirmation. Held on the store so
/// both the sidebar's delete affordances and the Delete menu command (⌘⌫) raise the same
/// confirmation prompt.
struct PendingWorkroomDeletion {
  let workroom: Workroom
  let project: Project
}

/// A workroom (or root) target awaiting close confirmation. "Closing" tears down all of the
/// target's terminal tabs — its chip leaves the tab bar — but leaves the workroom itself (its
/// directory/worktree) intact; that's the distinction from `PendingWorkroomDeletion`. Held on the
/// store so the tab bar's "Close" context-menu item raises one shared confirmation prompt.
struct PendingWorkroomClose {
  let target: TerminalTarget
  /// The chip's display name (workroom name, or the project name for a root) — used in the prompt.
  let name: String
}

/// A project queued for deletion, awaiting the user's type-the-name confirmation. Held on
/// the store (and `Identifiable` so it drives a `.sheet(item:)`) so the sidebar's Delete
/// Project affordance and the confirm sheet share one piece of state. `id` is the project
/// path, so re-targeting a different project rebuilds the sheet (resetting its typed/toggle
/// `@State`).
struct PendingProjectDeletion: Identifiable {
  let project: Project
  var id: String { project.path }
}

/// A workroom awaiting a display-label edit (issue #41). Held on the store (and `Identifiable` so it
/// drives a `.sheet(item:)`) so the sidebar row's and tab chip's "Set/Edit Label…" items share one
/// piece of state. `id` is the workroom's project-scoped target id, so re-targeting a different
/// workroom rebuilds the sheet (resetting its typed `@State`).
struct PendingWorkroomLabel: Identifiable {
  let workroom: Workroom
  let project: Project
  var id: String { TerminalTarget.workroomID(project: project.path, name: workroom.name) }
}

/// The project-settings sheet's one presentation source (issue #127): used both by the plain
/// "Project Settings…" entry points (hover button / context menu — `showsRunWarning: false`) and
/// by Run invoked with no command configured (`showsRunWarning: true`). Unified into ONE
/// store-level pending state — not one local to `ProjectSidebar` plus a second store-level one —
/// because ⌘R is a global key monitor that can fire while the sheet is already open from the other
/// entry point; two independent `.sheet(item:)` presenters would race (eng review issue #127-eng-1).
struct PendingProjectSettings: Identifiable {
  let project: Project
  var showsRunWarning: Bool = false
  var id: String { project.id }
}

/// A way past an error, offered on its sheet: a label and what it does.
struct ErrorAction {
  let label: String
  let run: @MainActor () -> Void
}

/// One window's modal presentations: the error sheet, the command-palette dialogs, the confirmations
/// and the store-level sheets, and `hasModalPresentation` over all of them. Owned by `AppStore` as
/// `modals`; the store forwards each member, so views and tests still read them through the store.
@MainActor
@Observable
final class ModalState {
  /// Setting it drops `errorDetails` and `errorLog`, which belong to whatever error set them: a later
  /// message from a direct setter must not show an earlier error's codes or output. `present(_:)`
  /// sets the details after.
  var errorMessage: String? {
    didSet {
      errorDetails = nil
      errorLog = nil
      errorAction = nil
    }
  }
  /// Title for the error alert. Nil falls back to the generic title; specific
  /// failures (e.g. teardown) set their own.
  var errorTitle: String?
  /// The error's codes and raw text, under the error sheet's collapsed Details. Set only by
  /// `present(_:)`, cleared with the message.
  var errorDetails: String?
  /// A failed script's output, shown open in a scrolling box beneath the message. Set after the
  /// message, cleared with it.
  var errorLog: String?
  /// A way past the error the sheet offers beside OK (Delete Anyway, after a failed teardown). Set
  /// after the message, cleared with it.
  var errorAction: ErrorAction?

  /// Dismisses the error sheet.
  func clearError() {
    errorMessage = nil  // and with it the details
    errorTitle = nil
  }

  /// Set by the "Add Project" menu command to trigger the sidebar's file importer.
  var requestAddProject = false
  /// Set by the "New Workroom" menu command (⌘N) to raise the project-picker dialog (issue #81).
  /// RootView observes it, presents the sheet, and resets the flag — same idiom as `requestAddProject`.
  var requestNewWorkroomPicker = false
  /// Set by the "Open workroom…" menu command (⌘O, issue #94) to raise the open-existing picker.
  /// RootView observes it, presents the sheet, and resets the flag — same idiom as the two above.
  var requestOpenWorkroomPicker = false
  /// Which command-palette dialog is currently shown (nil = none). Single source of truth so the New
  /// and Open Workroom presenters are mutually exclusive — opening one replaces the other (issue #94).
  var activePicker: ActivePicker?
  /// Whether the picker about to be raised should SPLIT rather than replace (issue #163) — set by
  /// ⌥⌘N / ⌥⌘O. Plain `var`, not `@Published`: it is read once by the presenter as it raises and
  /// cleared in the same breath (`consumePickerSplitIntent`), so nothing observes it.
  var pickerSplits = false
  /// A workroom awaiting delete confirmation; setting it raises the confirmation prompt.
  var pendingDeletion: PendingWorkroomDeletion?
  /// A target awaiting close confirmation (tab bar "Close"); setting it raises the close prompt.
  var pendingWorkroomClose: PendingWorkroomClose?
  /// A project awaiting type-to-confirm deletion (drives the DeleteProjectSheet). Set by the
  /// project row's context menu; cleared when the sheet's Delete/Cancel resolves.
  var pendingProjectDeletion: PendingProjectDeletion?
  /// A workroom awaiting a display-label edit (drives the WorkroomLabelSheet, issue #41). Set by the
  /// sidebar row's / tab chip's "Set Label…"/"Edit Label…" item; cleared when the sheet resolves.
  var pendingWorkroomLabel: PendingWorkroomLabel?
  /// The project-settings sheet's one presentation source (drives `ProjectSettingsSheet`, issue #7
  /// origin, issue #127 adds the no-command-Run trigger). Set by the project row's hover button /
  /// context menu (`showsRunWarning: false`), or by `runOrFocusRunCommand` when Run is invoked with
  /// no command configured (`showsRunWarning: true`). See `PendingProjectSettings`'s doc comment for
  /// why this is ONE store-level source rather than a sidebar-local `@State` plus a second one.
  var pendingProjectSettings: PendingProjectSettings?
  /// A remote action awaiting confirmation — currently only a pull over a dirty working tree, where
  /// `--autostash` will stash and reapply.
  ///
  /// Store-level rather than a `RightInspector` `@State` for the same reason `pendingProjectSettings` is:
  /// there are two entry points (the toolbar segment and the Source Control menu's ⌥⇧⌘P), and a gate
  /// owned by one view can only guard that view. It carries the `SidebarID` it was raised for so the
  /// confirmed action can't be redirected onto whatever is selected by the time the dialog is answered.
  var pendingRemoteConfirm: PendingVCSAction?

  /// The commit sheet's target, or nil when it's closed. Presented from the Changes section header.
  ///
  /// The sheet owns its own draft and selection for its lifetime, which is most of why it is a sheet:
  /// a per-workroom draft store on the AppStore would need pruning on workroom delete, would inherit
  /// a recycled workroom name's old message, and — since `AppStore` is per WINDOW — would let two
  /// windows on the same workroom fight over one `Defaults` dictionary with last-writer-wins.
  var pendingCommit: PendingCommit?

  /// A remote create waiting on the user's setup at its provider (drives `RemoteSetupSheet`).
  var pendingRemoteSetup: PendingRemoteSetup?

  /// Mirrors whether one of RootView's *view-local* sheets is up (Add Project, Keyboard Shortcuts,
  /// What's New — the theme dropdown is a transient popover, not modal, and deliberately NOT counted:
  /// it closes itself when one of these comes up). Those are `@State` in RootView rather than the
  /// `pending*` ones, so `hasModalPresentation` can't see them directly; RootView keeps this in sync
  /// with a single `onChange`. Deliberately a mirror rather than re-homing the four flags onto the
  /// store: re-homing a local sheet flag to a store-level published item needs a clobber guard to stop
  /// a second trigger silently overwriting an open sheet's in-progress input, and none of that
  /// complexity buys anything here — all this needs is "is something up".
  var auxSheetPresented = false

  /// Whether ANY modal presentation owns this window: a command-palette dialog, a confirmation, an
  /// alert, or one of the sheets. The single source of truth for making shortcuts inert behind a
  /// dialog — read by the key monitor's routing (via `activePicker`), by RootView's menu-enablement
  /// values, and by `WorkroomTerminalsView`'s terminal-scoped ones, so all three can't drift.
  ///
  /// Needed because a sheet does NOT make menu commands inert on its own: verified on the real build,
  /// with the Add Project sheet attached every File-menu item still read `enabled=true` and ⌘T
  /// actually created a second terminal tab behind it.
  var hasModalPresentation: Bool {
    activePicker != nil || auxSheetPresented || pendingDeletion != nil
      || pendingWorkroomClose != nil
      || pendingProjectDeletion != nil || pendingWorkroomLabel != nil
      || pendingProjectSettings != nil || errorMessage != nil
      // Included so the Source Control shortcuts are inert while the confirmation is up — otherwise
      // ⌥⇧⌘P could queue a second pull behind the dialog asking about the first.
      || pendingRemoteConfirm != nil
      // Same for the commit sheet: without this, ⌥⇧⌘P could fire a push behind an open commit
      // dialog, and the terminal-scoped shortcuts would still reach a surface the user can't see.
      || pendingCommit != nil
      || pendingRemoteSetup != nil
  }
}
