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

/// A create waiting on where it starts: the main checkout has work the remote's copy lacks.
struct PendingStartChoice {
  let run: CreationRun
  let work: LocalWork
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
  var id: TargetID { .workroom(project: project.path, name: workroom.name) }
}

/// A request for a project's settings (issue #127), from the plain "Project Settings…" entry points
/// (hover button / context menu — `showsRunWarning: false`) or from Run invoked with no command
/// configured (`showsRunWarning: true`). `RootView` hands it to Settings ▸ Projects and clears it.
struct PendingProjectSettings: Identifiable {
  let project: Project
  var showsRunWarning: Bool = false
  var id: String { project.id }
}

/// A boxd or exe.dev create waiting on its Options panel (#575): the place, and where the workroom
/// lands, taken when it was asked for.
struct PendingHostOptions: Identifiable {
  let project: Project
  let place: HostKind
  var splitAnchor: SidebarID?
  let id = UUID()
}

/// A way past an error, offered on its sheet: a label and what it does.
struct ErrorAction {
  /// What the sheet asks before running an action that needs it.
  struct Confirmation {
    let title: String
    let message: String
    let button: String
  }

  let label: String
  /// Drawn as destructive (Delete Anyway); as an `errorAction` only.
  var destructive = true
  /// Asked, over the sheet, before `run`; as an `errorAction` only.
  var confirmation: Confirmation? = nil
  let run: @MainActor () -> Void
}

/// A modal presentation that owns its window while it is up: a command-palette dialog, one of
/// `RootView`'s own sheets, the error sheet, a confirmation or a store-level sheet.
///
/// `ModalState` holds at most one of each kind, not one in all. Several can be up at once: an error,
/// a provider's setup sheet or a start choice arrives when its work finishes, over whatever the user
/// opened in the meantime, and must not take that down. An error replacing an open commit sheet would
/// lose its draft, and one replacing a provider's setup sheet would leave its creates waiting for good.
enum ActiveModal {
  case picker(ActivePicker)
  /// One of `RootView`'s view-local sheets (see `ModalState.auxSheetPresented`).
  case auxSheet
  /// The error sheet, by its message. The rest of what it shows is on `ModalState`.
  case error(String)
  case workroomDeletion(PendingWorkroomDeletion)
  case workroomClose(PendingWorkroomClose)
  case startChoice(PendingStartChoice)
  case projectDeletion(PendingProjectDeletion)
  case workroomLabel(PendingWorkroomLabel)
  case remoteConfirm(PendingVCSAction)
  case commit(PendingCommit)
  case remoteSetup(PendingRemoteSetup)
  case hostOptions(PendingHostOptions)

  enum Kind {
    case picker, auxSheet, error, workroomDeletion, workroomClose, startChoice, projectDeletion
    case workroomLabel, remoteConfirm, commit, remoteSetup, hostOptions
  }
}

/// One window's modal presentations (the `ActiveModal`s that are up), the error sheet's contents, and
/// the one-shot requests that raise a dialog. Owned by `AppStore` as `modals`.
@MainActor
@Observable
// `ObservableObject` only so views can take it as an `@EnvironmentObject`, as they take the store
// and `DetachedPaneEnvironmentTests` checks detached windows inject; Observation tracks the reads.
final class ModalState: ObservableObject {
  /// What is up, at most one of each kind: the picker in a slot of its own, every other kind in
  /// `others`. Every pane reads `activePicker`, and a write into one stored property notifies every
  /// reader of it, so the picker's own slot keeps the panes from redrawing on every other modal's
  /// change. The typed members below (`activePicker`, `pending*`, `errorMessage`,
  /// `auxSheetPresented`) read and write them only through `self[kind]`, and nothing else holds a
  /// modal, so `hasModalPresentation` cannot leave one out.
  private var picker: ActiveModal?
  private var others: [ActiveModal.Kind: ActiveModal] = [:]

  /// The modal of `kind` that is up, in the slot that holds that kind.
  private subscript(kind: ActiveModal.Kind) -> ActiveModal? {
    get { kind == .picker ? picker : others[kind] }
    set {
      if kind == .picker {
        picker = newValue
      } else {
        others[kind] = newValue
      }
    }
  }

  /// Puts `value` up as a modal of `kind`, replacing only one of that kind, or takes that kind down.
  /// Taking down what isn't up writes nothing, so it notifies no one.
  private func update<Value>(
    _ kind: ActiveModal.Kind, to value: Value?, as modal: (Value) -> ActiveModal
  ) {
    if let value {
      self[kind] = modal(value)
    } else if self[kind] != nil {
      self[kind] = nil
    }
  }

  /// Setting it drops `errorDetails` and `errorLog`, which belong to whatever error set them: a later
  /// message from a direct setter must not show an earlier error's codes or output. `present(_:)`
  /// sets the details after. Setting the message already shown changes nothing else, and notifies
  /// no reader of the message, as an equal write to a stored `String?` does not.
  var errorMessage: String? {
    get { if case .error(let message)? = self[.error] { message } else { nil } }
    set {
      errorDetails = nil
      errorLog = nil
      errorAction = nil
      errorApproval = nil
      errorScriptName = nil
      errorCancel = nil
      guard newValue != errorMessage else { return }
      update(.error, to: newValue, as: ActiveModal.error)
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
  /// Approve, for a script this Mac has not approved, whose text is `errorLog` (#363). With
  /// it the sheet's OK reads Cancel. Set after the message, cleared with it.
  var errorApproval: ErrorAction?
  /// With `errorApproval`, the file name of the script `errorLog` holds, so the sheet draws it as
  /// that file. Set after the message, cleared with it.
  var errorScriptName: String?
  /// With `errorApproval`, what Cancel (and Escape) does besides closing the sheet, under its own
  /// label: Cancel Creation, for a create's setup script. Nil: Cancel only closes it. Set after the
  /// message, cleared with it.
  var errorCancel: ErrorAction?

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
  /// Raising the one already up notifies no one, as an equal write to a stored optional does not.
  var activePicker: ActivePicker? {
    get { if case .picker(let picker)? = self[.picker] { picker } else { nil } }
    set {
      guard newValue != activePicker else { return }
      update(.picker, to: newValue, as: ActiveModal.picker)
    }
  }
  /// Whether the picker about to be raised should SPLIT rather than replace (issue #163) — set by
  /// ⌥⌘N / ⌥⌘O. Plain `var`, not `@Published`: it is read once by the presenter as it raises and
  /// cleared in the same breath (`consumePickerSplitIntent`), so nothing observes it.
  var pickerSplits = false
  /// A workroom awaiting delete confirmation; setting it raises the confirmation prompt.
  var pendingDeletion: PendingWorkroomDeletion? {
    get {
      if case .workroomDeletion(let pending)? = self[.workroomDeletion] { pending } else { nil }
    }
    set { update(.workroomDeletion, to: newValue, as: ActiveModal.workroomDeletion) }
  }
  /// A target awaiting close confirmation (tab bar "Close"); setting it raises the close prompt.
  var pendingWorkroomClose: PendingWorkroomClose? {
    get { if case .workroomClose(let pending)? = self[.workroomClose] { pending } else { nil } }
    set { update(.workroomClose, to: newValue, as: ActiveModal.workroomClose) }
  }
  /// A create asking where it starts; setting it raises the choice.
  var pendingStartChoice: PendingStartChoice? {
    get { if case .startChoice(let pending)? = self[.startChoice] { pending } else { nil } }
    set { update(.startChoice, to: newValue, as: ActiveModal.startChoice) }
  }
  /// A project awaiting type-to-confirm deletion (drives the DeleteProjectSheet). Set by the
  /// project row's context menu; cleared when the sheet's Delete/Cancel resolves.
  var pendingProjectDeletion: PendingProjectDeletion? {
    get {
      if case .projectDeletion(let pending)? = self[.projectDeletion] { pending } else { nil }
    }
    set { update(.projectDeletion, to: newValue, as: ActiveModal.projectDeletion) }
  }
  /// A workroom awaiting a display-label edit (drives the WorkroomLabelSheet, issue #41). Set by the
  /// sidebar row's / tab chip's "Set Label…"/"Edit Label…" item; cleared when the sheet resolves.
  var pendingWorkroomLabel: PendingWorkroomLabel? {
    get { if case .workroomLabel(let pending)? = self[.workroomLabel] { pending } else { nil } }
    set { update(.workroomLabel, to: newValue, as: ActiveModal.workroomLabel) }
  }
  /// A request for a project's settings, which `RootView` hands to Settings ▸ Projects and clears
  /// at once. See `PendingProjectSettings`. Not a modal: nothing holds this window while it is set.
  var pendingProjectSettings: PendingProjectSettings?
  /// A remote action awaiting confirmation — currently only a pull over a dirty working tree, where
  /// `--autostash` will stash and reapply.
  ///
  /// Store-level rather than a `RightInspector` `@State`: there are two entry points (the toolbar
  /// segment and the Room menu's ⌥⇧⌘P), and a gate owned by one view can only guard that view. It
  /// carries the `SidebarID` it was raised for so the confirmed action can't be redirected onto
  /// whatever is selected by the time the dialog is answered.
  ///
  /// A modal so the Room menu's Fetch/Push/Pull shortcuts are inert while the confirmation is up:
  /// otherwise ⌥⇧⌘P could queue a second pull behind the dialog asking about the first.
  var pendingRemoteConfirm: PendingVCSAction? {
    get { if case .remoteConfirm(let pending)? = self[.remoteConfirm] { pending } else { nil } }
    set { update(.remoteConfirm, to: newValue, as: ActiveModal.remoteConfirm) }
  }

  /// The commit sheet's target, or nil when it's closed. Presented from the Changes section header.
  ///
  /// The sheet owns its own draft and selection for its lifetime, which is most of why it is a sheet:
  /// a per-workroom draft store on the AppStore would need pruning on workroom delete, would inherit
  /// a recycled workroom name's old message, and — since `AppStore` is per WINDOW — would let two
  /// windows on the same workroom fight over one `Defaults` dictionary with last-writer-wins.
  ///
  /// A modal for the same reason as `pendingRemoteConfirm`: ⌥⇧⌘P could otherwise fire a push behind an
  /// open commit dialog, and the terminal-scoped shortcuts would still reach a surface the user can't
  /// see.
  var pendingCommit: PendingCommit? {
    get { if case .commit(let pending)? = self[.commit] { pending } else { nil } }
    set { update(.commit, to: newValue, as: ActiveModal.commit) }
  }

  /// A remote create waiting on the user's setup at its provider (drives `RemoteSetupSheet`).
  var pendingRemoteSetup: PendingRemoteSetup? {
    get { if case .remoteSetup(let pending)? = self[.remoteSetup] { pending } else { nil } }
    set { update(.remoteSetup, to: newValue, as: ActiveModal.remoteSetup) }
  }

  /// A boxd or exe.dev create waiting on its host options (drives `HostOptionsPanel`, #575).
  var pendingHostOptions: PendingHostOptions? {
    get { if case .hostOptions(let pending)? = self[.hostOptions] { pending } else { nil } }
    set { update(.hostOptions, to: newValue, as: ActiveModal.hostOptions) }
  }

  /// Mirrors whether one of RootView's *view-local* sheets is up (Add Project, Keyboard Shortcuts,
  /// What's New — the theme dropdown is a transient popover, not modal, and deliberately NOT counted:
  /// it closes itself when one of these comes up). Those are `@State` in RootView rather than the
  /// `pending*` ones, so `hasModalPresentation` can't see them directly; RootView keeps this in sync
  /// with a single `onChange` (What's New's flag reaches it through `WhatsNewLaunchCheck`'s
  /// binding). Deliberately a mirror rather than re-homing the four flags onto the store:
  /// re-homing a local sheet flag to a store-level published item needs a clobber guard to stop a
  /// second trigger silently overwriting an open sheet's in-progress input, and none of that
  /// complexity buys anything here — all this needs is "is something up".
  var auxSheetPresented: Bool {
    get { self[.auxSheet] != nil }
    set {
      guard newValue != auxSheetPresented else { return }
      self[.auxSheet] = newValue ? .auxSheet : nil
    }
  }

  /// Whether ANY modal presentation owns this window: a command-palette dialog, a confirmation, an
  /// alert, or one of the sheets. The single source of truth for making shortcuts inert behind a
  /// dialog — read by the key monitor's routing (via `activePicker`), by RootView's menu-enablement
  /// values, and by `WorkroomTerminalsView`'s terminal-scoped ones, so all three can't drift. Every
  /// modal is an `ActiveModal` in one of the two slots `self[kind]` writes, so a new one is counted
  /// without being listed here.
  ///
  /// Needed because a sheet does NOT make menu commands inert on its own: verified on the real build,
  /// with the Add Project sheet attached every File-menu item still read `enabled=true` and ⌘T
  /// actually created a second terminal tab behind it.
  var hasModalPresentation: Bool { picker != nil || !others.isEmpty }
}
