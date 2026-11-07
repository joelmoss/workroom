import AppKit
import Defaults
import SwiftUI
import UserNotifications
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import os

/// Menu-bar commands + keyboard shortcuts. They act on the shared store so they work
/// regardless of which pane has focus.
struct WorkroomCommands: Commands {
  private static let signposter = OSSignposter(
    subsystem: "com.developwithstyle.workroom", category: "MainMenu")
  #if DEBUG
    static var bodyPasses = 0
  #endif
  @ObservedObject var updater: Updater
  /// Which detached pane has key focus (issue #172), so the pop-out item can flip into its own
  /// inverse. Observed directly because a detached window is not a scene: nothing about it reaches
  /// `@FocusedValue`, so without this the body would never re-evaluate when one becomes key.
  @ObservedObject private var detachedFocus = DetachedPaneFocus.shared
  /// The focused window's store (issue #70). Optional — nil when no Workroom window is key, in which
  /// case actions no-op and toggle bindings read false.
  ///
  /// It does **NOT** go nil merely because a dialog is up, contrary to what this comment used to
  /// claim: verified on the real build, with the Add Project sheet attached every File-menu item still
  /// read `enabled=true` and ⌘T created a second terminal tab behind it. That is why enablement has to
  /// AND in `ModalState.hasModalPresentation` explicitly (see `modalBlocked` and `MenuStateValues`).
  /// The focused window's store, through the `Observable` form of `@FocusedValue`, so Observation
  /// re-evaluates this `Commands` body when a store property it reads changes: checkmarks like
  /// Projects track the focused window's `sidebarVisible` live. `@FocusedObject` would listen only to
  /// `objectWillChange`, which the `@Observable` store never sends.
  @FocusedValue(AppStore.self) private var store
  @FocusedValue(\.roomCommandState) private var roomCommandState
  @FocusedValue(\.workroomSelected) private var workroomSelected
  @FocusedValue(\.hasTerminal) private var hasTerminal
  @FocusedValue(\.hasNotifications) private var hasNotifications
  @FocusedValue(\.hasWaitingTerminals) private var hasWaitingTerminals
  @FocusedValue(\.hasProjects) private var hasProjects
  @FocusedValue(\.hasWorkroomAnchor) private var hasWorkroomAnchor
  @FocusedValue(\.canNavigateBack) private var canNavigateBack
  @FocusedValue(\.canNavigateForward) private var canNavigateForward
  @FocusedValue(\.hasRunCommand) private var hasRunCommand
  @FocusedValue(\.runCommandActive) private var runCommandActive
  @FocusedValue(\.vcsCanFetch) private var vcsCanFetch
  @FocusedValue(\.vcsCanPush) private var vcsCanPush
  @FocusedValue(\.vcsCanPull) private var vcsCanPull
  @FocusedValue(\.hasRunTerminal) private var hasRunTerminal
  @FocusedValue(\.multipleTerminalTabs) private var multipleTerminalTabs
  @FocusedValue(\.multipleWorkroomTabs) private var multipleWorkroomTabs
  @FocusedValue(\.canSwitchWorkrooms) private var canSwitchWorkrooms
  @FocusedValue(\.canOpenInEditor) private var canOpenInEditor
  @FocusedValue(\.canMoveWorkroom) private var canMoveWorkroom
  @FocusedValue(\.modalPresented) private var modalPresented
  // Shared with RootView's inspector + toolbar toggle (same key) so all three stay in sync.
  @Default(.showInspector) private var showInspector
  // Same key as the Settings checkbox so the two stay in sync; GhosttySurfaceView reads it
  // on each selection, so toggling here takes effect on the next drag.
  @Default(.copyOnSelect) private var copyOnSelect
  // Gate the quit-confirmation alert. Same key as the Settings checkbox so the two stay in sync;
  // AppDelegate reads it in applicationShouldTerminate.
  @Default(.confirmOnQuit) private var confirmOnQuit
  // Gate the close-terminal confirmation (default on). Same key as the Settings checkbox and the
  // dialog's "Don't ask me again", so the File-menu checkmark reflects — and drives — all three;
  // AppStore reads it in requestCloseTerminalTab.
  @Default(.confirmOnCloseTerminal) private var confirmOnCloseTerminal
  // Drives the quick dark/light toggle (⌘⇧L, issue #57). RootView's `.onChange(of: theme)` applies
  // it through the single theme chokepoint; same key as the sidebar's 3-state cycle button.
  @Default(.theme) private var theme
  /// The Quick Terminal item shows the recorded global shortcut as its equivalent.
  @Default(.quickTerminalShortcut) private var quickTerminalShortcut
  // The two quick-switcher trigger chords (issue #132). Read here so the Go-menu items re-render — and
  // so their key equivalents follow the preference — when either is retuned in Settings.
  @Default(.switcherWorkroomModifier) private var switcherWorkroomModifier
  @Default(.switcherPaneModifier) private var switcherPaneModifier
  /// Opens a new Workroom window (issue #70) — a fresh `WindowSeed` so the window starts blank.
  @Environment(\.openWindow) private var openWindow

  /// A `Binding<Bool>` onto a `Bool` property of the focused store — reads false and ignores writes
  /// when no window is focused (issue #70). Backs the menu toggles that drive per-window state.
  /// True while a modal presentation owns the focused window. Items whose enablement flows through a
  /// `MenuStateValues` boolean already have this ANDed in at the publication site; the ones below have
  /// no such boolean (the `@Default`-bound View-menu toggles, and Quick Terminal, which is documented
  /// "always enabled"), so they AND it in here. Without this their key equivalents fire straight
  /// through a dialog — verified: ⌘T behind the Add Project sheet really did open a terminal tab.
  private var modalBlocked: Bool { modalPresented == true }

  /// No projects: the sidebar and inspector have nothing to show, so their View-menu toggles (and
  /// their key equivalents, which a disabled item drops) are off.
  private var noProjects: Bool { hasProjects != true }

  /// Whether a workroom-scoped command must be disabled because a DETACHED pane's window is key
  /// (issue #172).
  ///
  /// These windows are deliberately kept out of `WindowRegistry` so the `AppDelegate` key monitor
  /// cannot route ⌘T / ⌘1–9 to the origin store while one is key. The SwiftUI menu had the same hole
  /// by a different route: `@FocusedObject`/`@FocusedValue` are SCENE-scoped, and a detached window is
  /// not a scene, so they keep reporting the last scene's store — and ⌘T would open a terminal in the
  /// main window's currently-selected workroom, which has nothing to do with the pane you are looking
  /// at. `isAppShortcut` withholds those keys from the pane's own TUI either way, so there is no
  /// useful fallback to preserve. Disabling also frees the key equivalent, the same mechanism this
  /// app already relies on for Tab.
  private var detachedWindowKey: Bool { detachedFocus.keyTabID != nil }

  /// The gate every workroom-scoped menu item ANDs in: the item's own precondition, and not aimed at
  /// the wrong window.
  ///
  /// "Workroom-scoped" means the action reads the ORIGIN window's selected workroom or focused pane
  /// — which is not what the user is looking at while a popped-out pane holds key. Push against the
  /// origin's selection is the sharp end of that (a wrong-repo push), but Back/Forward, Open in
  /// Editor, Close Other Tabs and the tab cyclers all move a window the user is not in. Items that
  /// are genuinely app-level (New Project, Quick Terminal, Settings, theme, Check for Updates) and
  /// the window-chrome toggles stay ungated: they mean the same thing whichever window is key.
  ///
  /// `MenuCommandGateTests` parses this file and fails on a `<flag> != true` that skipped the gate,
  /// so the next menu item cannot inherit the hole this closed.
  private func workroomCommandEnabled(_ flag: Bool?) -> Bool {
    flag == true && !detachedWindowKey
  }

  /// Room ▸ Reveal in Finder's precondition: something is selected and its directory still exists.
  /// Published with the inspected target's command state. Its publisher refreshes availability
  /// without making this body observe every target's status dictionary entry.
  private var revealInFinderEnabled: Bool? {
    roomCommandState?.canRevealInFinder
  }

  // The Room menu's items that only buttons offered before, off while a dialog or sheet is up, as
  // `MenuStateValues` gates the rest. Commit and the pull request items read the workroom the
  // inspector shows, whose status they need (`inspectorTargetID` is the selection, or nil while it
  // has no tabs); the workroom's own items read the selection, as its right-click menu does.
  private var inspectedWorkroom: SidebarID? {
    store?.modals.hasModalPresentation == false ? store?.inspectorTargetID : nil
  }
  private var canCommit: Bool? { roomCommandState?.canCommit }
  private var pullRequest: RoomCommandState.PullRequest? { roomCommandState?.pullRequest }
  /// Ready for Review or Convert to Draft, whichever an open pull request offers.
  private var draftAction: PRAction? {
    pullRequest?.draftAction
  }
  private var canChangeDraft: Bool? { roomCommandState?.canChangeDraft }
  /// The selected workroom, as the menu's title and the workroom's right-click menu take it; a root
  /// is never labelled or deleted, so it has none.
  private var selectedPair: (workroom: Workroom, project: Project)? {
    guard let store, !store.modals.hasModalPresentation, let sid = store.selectedTargetID else {
      return nil
    }
    return store.workroomAndProject(for: sid)
  }
  private var canLabel: Bool? { selectedPair != nil }
  private var canDelete: Bool? {
    selectedPair.map {
      store?.lifecycle.isCreatingWorkroom($0.workroom, in: $0.project) == false
    }
  }

  /// The Room menu's heading: the selected workroom as `InspectorWorkroomHeader` names it.
  private var workroomMenuTitle: String? {
    guard !detachedWindowKey, let store, let sid = store.selectedTargetID,
      let target = store.selectedTarget
    else { return nil }
    let project = store.project(forTargetID: target.id)?.displayName ?? target.title
    return WorkroomSplitTitlePresentation.workroomName(sid: sid, target: target).map {
      "\(project) / \($0)"
    } ?? project
  }

  /// The inspector's panes, in its activity bar's order (Details first). In View with their
  /// shortcuts, and copied into Room without them, so no key equivalent belongs to two items.
  @ViewBuilder
  private func inspectorPaneToggles(shortcuts: Bool) -> some View {
    // Details (where the selected workroom runs, and its ports) and Files are single-section panes:
    // showing one selects it and opens the inspector; turning it off hides the pane. Bumping
    // `inspectorToggles` makes the bar + inspector re-render synchronously, even when the section
    // stays put (see `AppStore.apply`).
    Toggle("Details", isOn: paneBinding(.details))
      .keyboardShortcut(shortcuts ? KeyboardShortcut("i", modifiers: [.command, .option]) : nil)
      .disabled(modalBlocked || noProjects)
    // Changes, History and Pull Request share the **Changes** pane (a stack), so "showing" one means
    // selecting that pane, opening the inspector, and expanding its sub-section; the checkmark is on
    // only when all three hold. Turning it off just collapses the sub-section. (History is ⌥⌘Y:
    // ⌥⌘H is macOS "Hide Others".)
    Toggle("Changes", isOn: subSectionBinding(\.changesSectionCollapsed))
      .keyboardShortcut(shortcuts ? KeyboardShortcut("c", modifiers: [.command, .option]) : nil)
      .disabled(modalBlocked || noProjects)
    Toggle("History", isOn: subSectionBinding(\.historySectionCollapsed))
      .keyboardShortcut(shortcuts ? KeyboardShortcut("y", modifiers: [.command, .option]) : nil)
      .disabled(modalBlocked || noProjects)
    Toggle("Pull Request", isOn: subSectionBinding(\.prSectionCollapsed))
      .keyboardShortcut(shortcuts ? KeyboardShortcut("p", modifiers: [.command, .option]) : nil)
      .disabled(modalBlocked || noProjects)
    Toggle("Files", isOn: paneBinding(.files))
      .keyboardShortcut(shortcuts ? KeyboardShortcut("f", modifiers: [.command, .option]) : nil)
      .disabled(modalBlocked || noProjects)
  }

  private func paneBinding(_ section: ActivitySection) -> Binding<Bool> {
    Binding(
      get: { showInspector && store?.activeInspectorSection == section },
      set: { on in
        store?.activeInspectorSection = section
        showInspector = on
        store?.inspectorToggles += 1
      })
  }

  private func subSectionBinding(_ collapsed: ReferenceWritableKeyPath<AppStore, Bool>)
    -> Binding<Bool>
  {
    Binding(
      get: {
        showInspector && store?.activeInspectorSection == .changes
          && store?[keyPath: collapsed] == false
      },
      set: { on in
        guard let store else { return }
        if on {
          store.activeInspectorSection = .changes
          showInspector = true
          store[keyPath: collapsed] = false
          store.inspectorToggles += 1
        } else {
          store[keyPath: collapsed] = true
        }
      })
  }

  /// The run command's lifecycle (issue #7): Run is disabled when no command is configured,
  /// Restart/Stop only while it's running.
  @ViewBuilder private var runItems: some View {
    Button("Run") { store?.runOrFocusRunCommand() }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(!workroomCommandEnabled(hasRunCommand))
    Button("Restart") { store?.restartSelectedRunCommand() }
      .keyboardShortcut("r", modifiers: [.command, .option])
      .disabled(!workroomCommandEnabled(runCommandActive))
    Button("Stop") { store?.stopSelectedRunCommand() }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!workroomCommandEnabled(runCommandActive))
    // Jump to the run terminal if one exists — navigation only, so it's named distinctly from Run
    // (which starts the command). Disabled when there's none to go to.
    Button("Go to Run Terminal") { store?.revealRunTerminal() }
      .disabled(!workroomCommandEnabled(hasRunTerminal))
  }

  private func storeFlag(_ keyPath: ReferenceWritableKeyPath<AppStore, Bool>) -> Binding<Bool> {
    Binding(
      get: { store?[keyPath: keyPath] ?? false },
      set: { store?[keyPath: keyPath] = $0 })
  }

  // File ▸ New Project sits at the very top (before New Workroom/Open Workroom), with a divider
  // beneath it. New Workroom (⌘N, issue #81) raises the project-picker dialog (RootView observes
  // `requestNewWorkroomPicker`); picking a project creates + opens a workroom in it. Disabled with
  // no projects, so ⌘N is a silent no-op rather than an empty dialog (issue #81 D3). Replaces the
  // standard WindowGroup item so the labels are explicit. Bundled into one computed property (the
  // Commands builder caps its child count) rather than three separate top-level groups.
  @CommandsBuilder
  private var newItemFileMenuCommands: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Project…") {
        store?.modals.requestAddProject = true
      }

      Divider()

      Button("New Workroom…") { store?.raiseWorkroomPicker(.new) }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(hasProjects != true)
      // (split right) (⌥⌘N, issue #163): same picker, but the pick lands BESIDE the current workroom
      // instead of replacing it. Needs an anchor, hence `hasWorkroomAnchor` — which, unlike
      // `workroomSelected`, is not modal-gated, so this behaves like ⌘N while a picker is open.
      Button("New Workroom (split right)") { store?.raiseWorkroomPicker(.new, split: true) }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(hasProjects != true || !workroomCommandEnabled(hasWorkroomAnchor))
      // Open workroom… (⌘O, issue #94): raises the open-existing picker (RootView observes
      // `requestOpenWorkroomPicker`); picking a root/workroom switches + focuses it. ⌘O moved here
      // from the Go-menu "Open in Editor" (which keeps its menu item, no shortcut). Disabled with no
      // projects, so ⌘O is a silent no-op rather than an empty picker.
      Button("Open Workroom…") { store?.raiseWorkroomPicker(.open) }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(hasProjects != true)
      Button("Open Workroom (split right)") { store?.raiseWorkroomPicker(.open, split: true) }
        .keyboardShortcut("o", modifiers: [.command, .option])
        .disabled(hasProjects != true || !workroomCommandEnabled(hasWorkroomAnchor))

      Divider()
    }

    CommandGroup(after: .newItem) {
      Button("New Terminal") {
        store?.newTerminalInSelectedTarget()
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(!workroomCommandEnabled(workroomSelected))

      // Quick terminal at ~/ in its own chrome-less window (issue #39) — same open/focus action as
      // the toolbar button. Always enabled (needs no workroom). Shows the recorded global shortcut
      // (⌥§ by default) as its equivalent: no double-fire, because the registered Carbon hotkey
      // consumes it system-wide before it reaches the menu (Release). In a Debug-only dev run (no
      // Release build owning the global hotkey), the menu equivalent is what makes the shortcut
      // work — handy for QA.
      Button("Quick Terminal") {
        NotificationCenter.default.post(name: .showQuickTerminal, object: nil)
      }
      .keyboardShortcut(quickTerminalShortcut.keyboardShortcut)
      // The shortcut may carry no ⌘ (⌥§ doesn't), so the key monitor's `flags.contains(.command)`
      // path never sees it and nothing else would stop it opening a whole new window from behind a
      // dialog.
      .disabled(modalBlocked)

      Divider()

      // ⌘W: "Close Tab" sits above the standard File ▸ Close, so it wins the ⌘W
      // equivalent while enabled (Close keeps no shortcut).
      Button("Close Tab") {
        store?.closeCurrentTerminalTab()
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(!workroomCommandEnabled(hasTerminal))

      // Bulk close (issue #72), no shortcuts. Labelled "Tabs" (not "Terminals") since they act on
      // diff/content tabs too. "Close Other Tabs" needs ≥2 tabs; "Close All Tabs" needs ≥1.
      Button("Close Other Tabs") {
        store?.closeOtherTerminalTabsInSelectedTarget()
      }
      .disabled(!workroomCommandEnabled(multipleTerminalTabs))
      Button("Close All Tabs") {
        store?.closeAllTerminalTabsInSelectedTarget()
      }
      .disabled(!workroomCommandEnabled(hasTerminal))

      // Gate the close-terminal confirmation (default on). A set-and-forget preference, so a divider
      // sets it apart from the File actions above (like the Quit toggle); no shortcut. Binds the same
      // key as the Settings checkbox and the dialog's "Don't ask me again", so ticking that box in the
      // confirm alert unchecks this item, and vice versa.
      Divider()
      Toggle("Confirm Before Closing a Terminal", isOn: $confirmOnCloseTerminal)
    }
  }

  var body: some Commands {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    let interval = Self.signposter.beginInterval("Workroom commands")
    defer { Self.signposter.endInterval("Workroom commands", interval) }
    return menuCommands
  }

  @ContentBuilder private var menuCommands: some Commands {
    CommandGroup(after: .appInfo) {
      // Sparkle update check, sitting directly beneath "About Workroom". Disabled while a check is
      // already running. See Core/AppShell/Updater.swift.
      Button("Check for Updates…") { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)
    }

    // App menu: the "Install workroom Command" + "Keyboard Shortcuts…" items, sitting just below
    // Settings… and above Services. Anchored `before: .systemServices`, NOT `after: .appSettings`:
    // the `Settings` scene injects the "Settings…" item at the END of the appSettings group, so
    // `after: .appSettings` lands ABOVE Settings… — anchoring before Services is the documented way
    // to sit just below it. Keyboard Shortcuts has no accelerator (a ⌘-key would need reserving from
    // the terminal in GhosttySurfaceView.isAppShortcut; the menu item is discovery enough) and posts
    // a notification RootView observes to present the sheet (a menu command can't anchor one — same
    // pattern as Theme… below).
    CommandGroup(before: .systemServices) {
      // App menu: symlink the bundled CLI into the user's PATH (like VS Code's "Install 'code'
      // command"). Prompts for admin only if the target dir needs it. See CommandLineInstaller.
      Button("Install ‘workroom’ Command in PATH…") {
        Task { await CommandLineInstaller.runFromMenu() }
      }
      Button("Keyboard Shortcuts…") {
        NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
      }
    }

    // Help menu: the docs site, and the shortcuts sheet again where people look for help. Replaces
    // macOS's default "Workroom Help", which needs a Help Book the app doesn't ship.
    CommandGroup(replacing: .help) {
      Button("Workroom Documentation") {
        NSWorkspace.shared.open(URL(string: "https://codaset.dev/workroom/docs")!)
      }
      Button("Keyboard Shortcuts…") {
        NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
      }
    }

    // Sit the quit-confirmation toggle just above Quit (default on): `.appVisibility` is the
    // Hide/Show All group, the last thing before Quit, so `after:` lands between it and Quit. A
    // divider separates it from that group; mirrored by the Settings checkbox.
    CommandGroup(after: .appVisibility) {
      Divider()
      Toggle("Confirm Before Quitting", isOn: $confirmOnQuit)
    }

    // Replace the default "Show/Hide Sidebar" with a clearer "Projects" label — it's the projects
    // sidebar. A `Toggle` (not a plain `toggleSidebar` Button) so the menu shows a checkmark when the
    // sidebar is visible; it binds `store.sidebarVisible`, which drives the split view's column
    // visibility. Keeps the conventional ⌃⌘S shortcut.
    CommandGroup(replacing: .sidebar) {
      Toggle("Projects", isOn: storeFlag(\.sidebarVisible))
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(modalBlocked || noProjects)
    }

    CommandGroup(after: .sidebar) {
      // View menu: toggle the right-hand inspector panel as a whole (⌘B), independent of which
      // section is active — the Changes/Files/History/Pull Request toggles below select a section
      // AND open the inspector; this one just shows/hides whatever section was last active.
      Toggle("Inspector", isOn: $showInspector)
        .keyboardShortcut("b", modifiers: [.command])
        .disabled(modalBlocked || noProjects)

      inspectorPaneToggles(shortcuts: true)

      // Theme chooser (issue #36). A menu command can't anchor a popover, so it posts a notification
      // that `TrailingTitlebarBar` — which owns the toolbar button the dropdown hangs off — observes.
      Divider()
      Button("Theme…") { NotificationCenter.default.post(name: .showThemePicker, object: nil) }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(modalBlocked)

      // Quick dark/light toggle (issue #57): flip the *currently visible* appearance. From System
      // it resolves the live OS appearance first, so it always inverts what's on screen and lands on
      // a forced mode — repeat presses then flip cleanly (the sidebar button still cycles back to
      // System). Title names the destination so the menu reads as the action it performs.
      Button(theme.toggledLightDark.label + " Mode") {
        theme = theme.toggledLightDark
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
      .disabled(modalBlocked)

      // Split the focused pane with a new terminal beside it (issue #3): ⌘D right, ⇧⌘D down; left/up
      // have no standard key, so they're menu-only.
      Divider()
      Button("Split Right") { store?.splitFocusedRight() }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(!workroomCommandEnabled(hasTerminal))
      Button("Split Left") { store?.splitFocusedLeft() }
        .disabled(!workroomCommandEnabled(hasTerminal))
      Button("Split Down") { store?.splitFocusedDown() }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(!workroomCommandEnabled(hasTerminal))
      Button("Split Up") { store?.splitFocusedUp() }
        .disabled(!workroomCommandEnabled(hasTerminal))

      // Separate our View items from the system "Enter Full Screen" item that follows.
      Divider()
    }

    // The Room menu: everything that acts on the current workroom (its run command, its changes
    // and branch, its pull request, and the workroom itself), after View so it reads as the menu for
    // what the window shows. Every shortcut here is ALSO reserved in `GhosttySurfaceView.isAppShortcut`
    // — without that a focused TUI in an enhanced keyboard mode (Claude/Codex) swallows the keystroke
    // and the menu's key equivalent never fires. The run keys (⌘R / ⌥⌘R / ⇧⌘R) are also handled by
    // the AppDelegate monitor so they fire before the terminal (the monitor consumes them, so no
    // double-fire).
    // Named Room, not Workroom: Release and Nightly's app menu is already "Workroom".
    CommandMenu("Room") {
      // Headed by the workroom it acts on, as the right sidebar's title writes it ("project /
      // workroom", a root its project alone); no heading with nothing selected.
      if let workroomMenuTitle {
        Section(workroomMenuTitle) {
          Divider()
          runItems
        }
      } else {
        runItems
      }

      Divider()
      // The Changes header's commit button.
      Button("Commit…") { store?.requestCommit(store?.inspectorTargetID) }
        .keyboardShortcut(.return, modifiers: [.command, .option])
        .disabled(!workroomCommandEnabled(canCommit))
      Button("Fetch") { store?.performRemoteAction(.fetch) }
        .keyboardShortcut("f", modifiers: [.command, .shift, .option])
        .disabled(!workroomCommandEnabled(vcsCanFetch))
      Button("Push") { store?.performRemoteAction(.push) }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!workroomCommandEnabled(vcsCanPush))
      Button("Pull with Rebase") { store?.performRemoteAction(.pull) }
        .keyboardShortcut("p", modifiers: [.command, .shift, .option])
        .disabled(!workroomCommandEnabled(vcsCanPull))

      // The Pull Request section's actions menu: only while the branch has a pull request.
      if let pullRequest {
        Divider()
        Button("Go to Pull Request") {
          if let url = URL(string: pullRequest.url) { NSWorkspace.shared.open(url) }
        }
        .disabled(detachedWindowKey)
        if let draftAction, let sid = inspectedWorkroom {
          Button(draftAction.label) {
            store?.performPRAction(draftAction, number: pullRequest.number, on: sid)
          }
          .disabled(!workroomCommandEnabled(canChangeDraft))
        }
      }

      // The inspector's panes, as View has them (without their shortcuts, which stay View's).
      Divider()
      inspectorPaneToggles(shortcuts: false)

      // Open the selected target in the remembered external editor (the toolbar's open button, ⇧⌘O),
      // or show its folder in Finder. Disabled when nothing's selected or its directory is missing
      // (a remote workroom's), and Open in when no editor is installed.
      Divider()
      Button("Open in \(ExternalEditor.remembered?.name ?? "Editor")") {
        store?.openSelectedInEditor()
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      .disabled(!workroomCommandEnabled(canOpenInEditor))
      Button("Reveal in Finder") {
        if let path = store?.selectedTarget?.path {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
      }
      .disabled(!workroomCommandEnabled(revealInFinderEnabled))

      // The workroom's own items, as its right-click menu has them (`WorkroomContextMenu`): a root is
      // never labelled or deleted, so these are off for one.
      Divider()
      Button(selectedPair?.workroom.label == nil ? "Set Label…" : "Edit Label…") {
        if let pair = selectedPair {
          store?.modals.pendingWorkroomLabel = PendingWorkroomLabel(
            workroom: pair.workroom, project: pair.project)
        }
      }
      .disabled(!workroomCommandEnabled(canLabel))
      if let pair = selectedPair, pair.workroom.label != nil {
        Button("Remove Label") { store?.removeWorkroomLabel(pair.workroom, in: pair.project) }
          .disabled(!workroomCommandEnabled(canLabel))
      }
      // The selected workroom, every terminal of it, into a window of its own (#444).
      Button("Move Workroom into New Window") {
        if let store, let sid = store.selectedTargetID { store.moveWorkroomToNewWindow(sid) }
      }
      .disabled(!workroomCommandEnabled(canMoveWorkroom))

      Divider()
      // Through RootView's confirmation, so its title ends in an ellipsis. Not while its setup still
      // runs against the worktree (issue #116).
      Button("Delete Workroom…") {
        if let pair = selectedPair {
          store?.modals.pendingDeletion = PendingWorkroomDeletion(
            workroom: pair.workroom, project: pair.project)
        }
      }
      .disabled(!workroomCommandEnabled(canDelete))
    }

    CommandGroup(after: .pasteboard) {
      // Edit ▸ Find: searches the focused pane — the terminal's scrollback for a terminal pane, or the
      // in-file find for a read-only file viewer. ⌘F opens the find bar; ⌘G / ⇧⌘G step to the next /
      // previous match (wrapping at the ends). All three are reserved in GhosttySurfaceView.isAppShortcut
      // so the menu key-equivalent wins over the terminal even while a TUI in an enhanced keyboard mode
      // (Claude/Codex) is running. Find Next / Previous no-op when no find bar is open. Disabled with no
      // terminal (a workroom always opens with one; a lone file pane is the only gap).
      Divider()
      Button("Find…") { store?.startFindInFocusedPane() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!workroomCommandEnabled(hasTerminal))
      Button("Find Next") { store?.navigateFocusedPaneSearch(forward: true) }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(!workroomCommandEnabled(hasTerminal))
      Button("Find Previous") { store?.navigateFocusedPaneSearch(forward: false) }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(!workroomCommandEnabled(hasTerminal))

      // Edit menu: toggle copy-on-select (checkmark reflects state). A divider sets it apart
      // from the standard Cut/Copy/Paste group above, since it governs clipboard behaviour
      // rather than performing an action. No shortcut — it's a set-and-forget preference,
      // mirrored by the Settings checkbox.
      Divider()
      Toggle("Copy on Select", isOn: $copyOnSelect)
    }

    // New Window lives at the top of the Window menu (not File) so it sits beside the other
    // window-management commands (Minimize, Zoom, …).
    CommandGroup(before: .windowSize) {
      Button("New Window") { openWindow(value: WindowSeed(id: UUID(), restore: false)) }
      // Pop the focused detail panel into a window of its own, or put it back (issue #172). ONE item
      // that flips, rather than two: the two directions are mutually exclusive, the same key does
      // both, and a second permanently-greyed item would be noise. The title-bar buttons and the
      // tear-off drag are the discoverable paths; this makes both keyboard-reachable.
      if let detached = detachedFocus.keyTabID {
        Button("Move back to main window") { AppStore.dockDetachedPane(detached) }
          .keyboardShortcut("o", modifiers: [.command, .control])
      } else {
        Button("Move pane into new window") { store?.detachFocusedPane() }
          .keyboardShortcut("o", modifiers: [.command, .control])
          .disabled(!workroomCommandEnabled(workroomSelected))
      }
      Divider()
    }

    newItemFileMenuCommands

    // Browser/Finder-style back/forward over the workroom + terminal history (issue #26), plus
    // the ⇧⌘N jump to the oldest pending notification. ⌘[ / ⌘] are reserved from the terminal in
    // GhosttySurfaceView.isAppShortcut so these key equivalents fire.
    CommandMenu("Go") {
      Button("Back") { store?.navigateBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!workroomCommandEnabled(canNavigateBack))
      Button("Forward") { store?.navigateForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!workroomCommandEnabled(canNavigateForward))

      // Scroll the focused terminal to the top/bottom of its scrollback (issue #42). ⌘↑/⌘↓ — the
      // menu key-equivalent fires before the terminal, so it works even in an enhanced-keyboard TUI.
      // Disabled when no terminal is focused.
      Divider()
      Button("Scroll to Top") { store?.scrollFocusedTerminalToTop() }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(!workroomCommandEnabled(hasTerminal))
      Button("Scroll to Bottom") { store?.scrollFocusedTerminalToBottom() }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(!workroomCommandEnabled(hasTerminal))

      // Cycle terminal tabs (⌥⌘←/→) and workroom tabs (⇧⌥⌘←/→) (issue #29). The keys are caught by
      // the AppDelegate monitor so they fire before the terminal; shown here for discoverability (the
      // monitor consumes them, so no double-fire — like Room ▸ Run). Disabled when there's nothing
      // to cycle between (≤1 tab).
      Divider()
      Button("Next Terminal Tab") { store?.cycleTerminalTab(forward: true) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(!workroomCommandEnabled(multipleTerminalTabs))
      Button("Previous Terminal Tab") { store?.cycleTerminalTab(forward: false) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(!workroomCommandEnabled(multipleTerminalTabs))
      Button("Next Workroom Tab") { store?.cycleWorkroomTab(forward: true) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
        .disabled(!workroomCommandEnabled(multipleWorkroomTabs))
      Button("Previous Workroom Tab") { store?.cycleWorkroomTab(forward: false) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
        .disabled(!workroomCommandEnabled(multipleWorkroomTabs))

      // The quick switchers (issue #132, D11), by recency rather than position — here because a
      // shortcut nobody can see is a shortcut nobody uses, and because this is the only way to reach
      // the feature with the mouse. Both key equivalents track their `Defaults` chord.
      //
      // The action goes through the key window, not this menu's focused store — see
      // `QuickSwitcher.stepFromKeyWindow`. Enablement is load-bearing rather than cosmetic: the monitor
      // consumes the keystroke whenever it switched, so these key equivalents are reached only in the
      // pass-through cases, and a disabled item drops its key equivalent — which is what keeps ⌃⇥
      // reaching a TUI in a single-pane workroom instead of being eaten by a menu that would no-op.
      //
      // Set both preferences to the same chord and these two items share a key equivalent; AppKit fires
      // the first enabled match, which is Workrooms — the same tie-break `QuickSwitcherKey.classify`
      // makes, so the menu and the monitor agree even in that configuration.
      //
      // The detached-window gate rides the same mechanism: a popped-out window is not in the registry,
      // so `switcherGate` hands it `.passThrough` and these would no-op anyway — disabling them frees
      // the key equivalent, which is what lets ⌃⇥ reach the detached pane's own TUI (issue #172).
      Divider()
      Button("Last-Used Workroom") { QuickSwitcher.stepFromKeyWindow(.workrooms) }
        .keyboardShortcut(.tab, modifiers: switcherWorkroomModifier.eventModifiers)
        .disabled(!workroomCommandEnabled(canSwitchWorkrooms))
      Button("Last-Used Pane") { QuickSwitcher.stepFromKeyWindow(.panes) }
        .keyboardShortcut(.tab, modifiers: switcherPaneModifier.eventModifiers)
        .disabled(!workroomCommandEnabled(multipleTerminalTabs))

      Divider()

      // ⇧⌘N: jump to the oldest pending notification (bottom of the panel). Opening dismisses it,
      // so repeated presses walk the backlog oldest→newest. Disabled when there are none.
      Button("Next Notification") {
        store?.openOldestNotification()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(!workroomCommandEnabled(hasNotifications))

      // ⇧⌘M: the terminal that has waited longest for the user, across every window (#358);
      // repeating it steps through the rest. Next Notification goes through unread notifications.
      Button("Go to Terminal That Needs You") {
        if !ProgramStatusAlerts.shared.goToNextWaiting(from: WindowRegistry.shared.frontHost) {
          NSSound.beep()
        }
      }
      .keyboardShortcut("m", modifiers: [.command, .shift])
      .disabled(!workroomCommandEnabled(hasWaitingTerminals))
      .help(
        "Go to the terminal waiting longest for you (Next Notification goes through unread "
          + "notifications)")
    }
  }
}
