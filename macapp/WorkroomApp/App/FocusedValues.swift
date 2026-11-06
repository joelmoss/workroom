import AppKit
import Defaults
import SwiftUI
import UserNotifications
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import os

/// Whether the focused window has a usable terminal target selected (a root or a workroom,
/// and not a missing directory). Published via `focusedSceneValue` (see RootView) so menu
/// commands can enable/disable against it — a Commands body doesn't re-evaluate when the
/// shared store changes directly, but it does track focused values.
struct WorkroomSelectedKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom has at least one open terminal — published by
/// WorkroomTerminalsView (which observes the sessions), so "Close Tab" can disable
/// when there's nothing to close.
struct HasTerminalKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether there are any pending notifications — published by RootView (which observes the
/// store), so "Next Notification" can disable when the history is empty.
struct HasNotificationsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether a program in any terminal, in any window, waits on the user (#358), so "Go to Terminal
/// That Needs You" disables with none.
struct HasWaitingTerminalsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the app has at least one project — published by RootView, so "New Workroom" (⌘N, issue
/// #81) disables when there's nothing to pick (a fresh install): ⌘N is then a silent no-op rather
/// than opening an empty dialog.
struct HasProjectsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether a workroom is selected to split BESIDE — published by RootView so the two "…in Split"
/// items (⌥⌘N / ⌥⌘O, issue #163) disable when there is no anchor.
///
/// Deliberately NOT `workroomSelected`, which ANDs in `!hasModalPresentation`: a disabled item
/// drops its key equivalent, so gating on that would make ⌥⌘O dead whenever ANY picker or sheet is
/// up — while plain ⌘N/⌘O are deliberately un-gated so that raising one picker replaces the other
/// (issue #94). Same reasoning, so the same policy: presence of an anchor only, no modal gate.
struct HasWorkroomAnchorKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether Room ▸ "Move Workroom into New Window" applies to the selected workroom (#444): it has
/// terminals here, no create is setting it up, and it is not the window's only workroom.
struct CanMoveWorkroomKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether back/forward navigation can move (issue #26) — published by RootView, so the Go-menu
/// Back/Forward commands disable at the ends of history.
struct CanNavigateBackKey: FocusedValueKey {
  typealias Value = Bool
}

struct CanNavigateForwardKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom's project has a non-empty run command (issue #7) — published by
/// RootView (observes the store), so the Room ▸ Run item disables when there's nothing to run.
struct HasRunCommandKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom's run command is currently running (issue #7) — published by
/// RootView, so the menu shows Run vs Stop/Restart enablement.
struct RunCommandActiveKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the VCS toolbar's fetch / push / pull are currently possible — published by RootView so the
/// Room menu's Fetch/Push/Pull items disable in step with the toolbar's own segments.
///
/// Three separate keys rather than one, because they genuinely differ: pull needs a counterpart that
/// exists on the remote (a fresh workroom has none), while push is what creates it.
struct VCSCanFetchKey: FocusedValueKey {
  typealias Value = Bool
}
struct VCSCanPushKey: FocusedValueKey {
  typealias Value = Bool
}
struct VCSCanPullKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether any run terminal exists to jump to (issue #7) — published by RootView, so the
/// Room ▸ Go to Run Terminal item disables when there's none.
struct HasRunTerminalKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected target has more than one terminal tab (issue #29) — published by
/// WorkroomTerminalsView, so the Go-menu Previous/Next Terminal Tab items disable when there's
/// nothing to cycle between.
struct MultipleTerminalTabsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether there's more than one workroom tab (issue #29) — published by RootView, so the Go-menu
/// Previous/Next Workroom Tab items disable when there's nothing to cycle between.
struct MultipleWorkroomTabsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether ⌥Tab has anywhere to go — published by RootView, so the Go-menu "Last-Used Workroom" item
/// (D11, issue #132) disables when this window's is the only open workroom in the app. Counted across
/// every window, unlike `MultipleWorkroomTabsKey`, because that's the switcher's scope.
struct CanSwitchWorkroomsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected target can be opened in an external editor — published by RootView, so the
/// Go-menu "Open in…" item (⌘O) disables when there's no selection / a missing dir / no editor.
struct CanOpenInEditorKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether a modal presentation owns the focused window (`ModalState.hasModalPresentation`). Backs the
/// menu items that have no other enablement boolean to fold it into — the `@Default`-bound toggles
/// (⌘B, ⌥⌘C/F/Y/P, ⇧⌘K, ⇧⌘L) and Quick Terminal, which is "always enabled" and whose ⌥§ carries no
/// ⌘ at all, so nothing in the key monitor would ever gate it.
struct ModalPresentedKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var workroomSelected: Bool? {
    get { self[WorkroomSelectedKey.self] }
    set { self[WorkroomSelectedKey.self] = newValue }
  }
  var hasTerminal: Bool? {
    get { self[HasTerminalKey.self] }
    set { self[HasTerminalKey.self] = newValue }
  }
  var hasNotifications: Bool? {
    get { self[HasNotificationsKey.self] }
    set { self[HasNotificationsKey.self] = newValue }
  }
  var hasWaitingTerminals: Bool? {
    get { self[HasWaitingTerminalsKey.self] }
    set { self[HasWaitingTerminalsKey.self] = newValue }
  }
  var hasProjects: Bool? {
    get { self[HasProjectsKey.self] }
    set { self[HasProjectsKey.self] = newValue }
  }
  var hasWorkroomAnchor: Bool? {
    get { self[HasWorkroomAnchorKey.self] }
    set { self[HasWorkroomAnchorKey.self] = newValue }
  }
  var canNavigateBack: Bool? {
    get { self[CanNavigateBackKey.self] }
    set { self[CanNavigateBackKey.self] = newValue }
  }
  var canNavigateForward: Bool? {
    get { self[CanNavigateForwardKey.self] }
    set { self[CanNavigateForwardKey.self] = newValue }
  }
  var hasRunCommand: Bool? {
    get { self[HasRunCommandKey.self] }
    set { self[HasRunCommandKey.self] = newValue }
  }
  var runCommandActive: Bool? {
    get { self[RunCommandActiveKey.self] }
    set { self[RunCommandActiveKey.self] = newValue }
  }
  var vcsCanFetch: Bool? {
    get { self[VCSCanFetchKey.self] }
    set { self[VCSCanFetchKey.self] = newValue }
  }
  var vcsCanPush: Bool? {
    get { self[VCSCanPushKey.self] }
    set { self[VCSCanPushKey.self] = newValue }
  }
  var vcsCanPull: Bool? {
    get { self[VCSCanPullKey.self] }
    set { self[VCSCanPullKey.self] = newValue }
  }
  var hasRunTerminal: Bool? {
    get { self[HasRunTerminalKey.self] }
    set { self[HasRunTerminalKey.self] = newValue }
  }
  var multipleTerminalTabs: Bool? {
    get { self[MultipleTerminalTabsKey.self] }
    set { self[MultipleTerminalTabsKey.self] = newValue }
  }
  var multipleWorkroomTabs: Bool? {
    get { self[MultipleWorkroomTabsKey.self] }
    set { self[MultipleWorkroomTabsKey.self] = newValue }
  }
  var canSwitchWorkrooms: Bool? {
    get { self[CanSwitchWorkroomsKey.self] }
    set { self[CanSwitchWorkroomsKey.self] = newValue }
  }
  var canOpenInEditor: Bool? {
    get { self[CanOpenInEditorKey.self] }
    set { self[CanOpenInEditorKey.self] = newValue }
  }
  var modalPresented: Bool? {
    get { self[ModalPresentedKey.self] }
    set { self[ModalPresentedKey.self] = newValue }
  }
  var canMoveWorkroom: Bool? {
    get { self[CanMoveWorkroomKey.self] }
    set { self[CanMoveWorkroomKey.self] = newValue }
  }
}
