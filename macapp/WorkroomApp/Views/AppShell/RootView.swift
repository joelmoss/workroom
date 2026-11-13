import AppKit
import Defaults
import SwiftUI
import WorkroomDomain

/// The window's composition root. It takes from the environment only what it renders from; the
/// Combine-published objects that feed the menus, the title-bar bar and the What's New check are
/// observed by `MenuStateAdapter`, `AccessoryBarInjector` and `WhatsNewLaunchCheck`, so their
/// publishes do not re-run this body (`RootInvalidationTests`).
struct RootView: View {
  #if DEBUG
    /// How many times the body has run, read by `RootInvalidationTests`.
    static var bodyPasses = 0
  #endif
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var modals: ModalState
  @EnvironmentObject var runCommands: RunCommands
  @EnvironmentObject var projectStore: ProjectStore
  @EnvironmentObject var lifecycle: WorkroomLifecycle
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openSettings) private var openSettings
  /// Drives the title-bar accessory's dim while a dialog is up, matched to `DialogOverlay`'s backdrop.
  @Environment(\.colorScheme) private var colorScheme
  /// Injected by `RootWindow` (`themeTokensRoot()`), above this view.
  @Environment(\.themeTokens) private var tokens
  @Default(.theme) private var theme
  /// Whether the right-hand inspector (Changes / Files / Pull Request) is open. `@Default` (not
  /// `@State`) so the View-menu command (WorkroomCommands) toggles the same value.
  @Default(.showInspector) private var showInspector

  /// Drives the New Project sheet — set from `modals.requestAddProject`, which both the menu command
  /// and the sidebar's Add-Project buttons raise. Hosted here (vs the sidebar) so the command presents
  /// it even if the sidebar is collapsed via the standard toggle. The sheet (issue #103) offers two
  /// modes: add an existing repo, or create + git-init a new directory.
  @State private var showAddProject = false

  /// Presents the keyboard-shortcuts reference, raised by the `Keyboard Shortcuts…` command via
  /// notification (a menu command can't anchor a sheet).
  @State private var showKeyboardShortcuts = false

  /// Whether the "What's New" dialog is up, mirrored from `WhatsNewLaunchCheck`, which owns it.
  @State private var whatsNewShown = false

  /// Live preview of a workroom tab being dragged into the detail content to form a split (issue #23
  /// follow-up). Set by `WorkroomTabBar`'s drag, read by `WorkroomSplitView` to highlight the drop edge.
  @State private var workroomChipDrag: WorkroomPaneDrag?
  /// The detail content area's global frame, so a chip drag can be resolved against the workroom panes.
  @State private var detailContentFrame: CGRect = .zero

  var body: some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    // The custom chrome lives in a full-width `.left` titlebar accessory (`accessoryBarContent`, hosted
    // via `TitlebarAccessoryHost` in `rootWindowChrome`), not a content top-strip and not SwiftUI
    // `.toolbar` items — so AppKit owns the bar height (an empty NSToolbar; see WindowBackgroundThemer)
    // and centers the traffic lights alongside the controls.
    // `rootModals` sits OUTSIDE `rootReveals` so the command-palette dialogs — which are `.overlay`s,
    // not sheets — render above the toast stack and above an edge-revealed sidebar. Inside, an
    // arriving toast drew on top of the dialog. Only the overlay presenters care about this ordering;
    // `.sheet` / `.alert` are position-independent.
    return rootWindowChrome(rootLifecycle(rootModals(windowContent)))
  }

  private var windowContent: some View {
    VStack(spacing: 0) {
      rootReveals(splitView)
      WindowFooter()
    }
  }

  /// The full title-bar bar hosted in the `.left` titlebar accessory: leading controls, the workroom
  /// tab strip (fills + scrolls), trailing controls. `AccessoryBarInjector` hosts it and re-injects
  /// the environment objects, because the accessory is a separate hosting tree from the main window
  /// content.
  private var accessoryBarContent: some View {
    HStack(spacing: 6) {
      LeadingTitlebarBar()
      workroomTabsBar
      TrailingTitlebarBar()
    }
    .padding(.horizontal, WorkroomTitlebar.outerInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // No own background — the accessory is transparent so the window's panel bg shows through it AND
    // behind the traffic lights uniformly (an opaque fill here didn't match the titlebar strip behind
    // the lights). WindowBackgroundThemer sets the window bg to the panel token.
    //
    // The accessory is a window-level AppKit hosting tree, so the dialog's own backdrop — an overlay
    // on the content below — can never cover it. Left alone, the workroom tab strip's New/Open buttons
    // and its chips stay clickable through a "modal" dialog, and the bar stays undimmed while
    // everything beneath it darkens. Both halves read the same opacity + curve from
    // `DialogOverlayStyle` so they can't drift.
    .disabled(modals.activePicker != nil)
    .overlay {
      Color.black
        .opacity(
          modals.activePicker != nil ? DialogOverlayStyle.backdropOpacity(for: colorScheme) : 0
        )
        .allowsHitTesting(false)
    }
    .animation(
      reduceMotion ? nil : DialogOverlayStyle.revealAnimation, value: modals.activePicker != nil)
  }

  private var workroomTabsBar: some View {
    // ALWAYS mounted, even with no tabs: its trailing Open/New buttons are how you get your first
    // workroom open in a fresh window, so they can't be gated on a tab already existing (only on a
    // project existing, without which they hide). (It also
    // hosts the provisional "Creating…" chip before any tab resolves — issue #116.) With an empty
    // run the bar is just those two buttons over the draggable title bar.
    WorkroomTabBar(
      tabs: store.displayedWorkroomTargets(), selectedID: store.selectedTargetID,
      onSelect: { selectWorkroomTab($0) },
      chipPaneDrag: $workroomChipDrag,
      localize: { workroomChipLocal($0) },
      dropTarget: { workroomChipDropTarget(at: $0) }
    )
    .frame(maxWidth: .infinity)
  }

  /// The two-column `NavigationSplitView` core (sidebar + detail/inspector). The window chrome, modal
  /// presentations, and lifecycle hooks layer on in `body` via the `root*` helpers below — each its own
  /// function so the modifier chain type-checks within the compiler's budget. The fully-inline chain
  /// timed out the type-checker on CI ("unable to type-check this expression in reasonable time"); this
  /// is the same split-it-up reason `EdgeRevealSidebars`/`MenuStateValues`/`NewWorkroomPresenter` exist.
  private var splitView: some View {
    // A hand-rolled split (sidebar | detail | inspector) instead of `NavigationSplitView`: the native
    // sidebar column drew an inset card with a ~30pt top toolbar-reserve that left an empty gap under
    // the custom title bar, and that inset isn't controllable. `SidebarColumn`/`InspectorColumn` are
    // our own resizable cards (same `sidebarCard` as the edge-reveal, so pinned == unpinned), giving
    // full control over their position. Visibility round-trips through `store.sidebarVisible` /
    // `showInspector` (the View-menu ticks + toggles); width persists per column to `Defaults`.
    // A *detail-only* NavigationSplitView: we keep it (vs a plain HStack) only for the window
    // toolbar/layering context it sets up — that's what lets the custom title bar, drawn in the
    // full-size content under the native title bar, render crisp instead of washed-out by the
    // title-bar vibrancy (a plain HStack / NavigationStack doesn't). Its native sidebar column is
    // never used (forced `.detailOnly`) — that column is what kept the ~30pt inset-card top gap — so
    // the real sidebar is our own `SidebarColumn` in the detail HStack, flush below the bar.
    // Wrapped in a *detail-only* `NavigationSplitView` (empty sidebar column, forced `.detailOnly`) —
    // NOT a plain HStack. A plain HStack detail in a full-size-content window with a visible `.unified`
    // toolbar loses SwiftUI `.onHover` for its content that sits near the top under the title bar (the
    // terminal tab strip's trailing toolbar buttons never lit their hover well — issue #114); the
    // title-bar region eats mouse-moved for a raw content view. `NavigationSplitView` hosts the detail
    // in an `NSSplitViewController`, which sets up the correct content tracking so `.onHover` fires
    // again. Dropping it (0e354d6e) was to stop it clipping `.toolbar { items }` to the sidebar-column
    // width — but the chrome no longer lives in toolbar items; it's a full-width window-level `.left`
    // `TitlebarAccessoryHost` (see `accessoryBarContent`), which NavigationSplitView does not clip. So
    // we get correct hover back with no clipping. The empty native sidebar column is unused — the real
    // sidebar is our own `SidebarColumn` in the detail HStack, flush below the bar.
    // The inspector has nothing to show without a selected target (its panes all render a "Select a
    // workroom…" placeholder instead), so it's also gated on that — not just the user's `showInspector`
    // toggle — closing itself whenever nothing's open instead of sitting there empty. A pure view-layer
    // gate, not a write to `Defaults[.showInspector]`: that key is shared across every window, so
    // flipping it here would also close the inspector in any OTHER window that still has something
    // selected. The toggle's own on/off state (View menu, `ActivityBar`) is untouched either way — it
    // just resumes controlling real visibility again the moment something's selected.
    // Re-renders on every activity-bar click, so `showInspector` is read fresh
    // (`AppStore.inspectorToggles`).
    let _ = store.inspectorToggles
    let inspectorVisible = showInspector && store.selectedTarget != nil
    // Same reasoning as `inspectorVisible`: with zero projects, `SidebarColumn` has nothing to list
    // but its own "No projects yet" empty state — which `detailContent`'s empty state now also shows
    // (with the same "Add Project…" action), so the sidebar just doubles it. Gated on
    // `projectStore.projects`, not a write to `Defaults[.sidebarVisible]`, for the same other-window reason.
    let sidebarShown = store.sidebarVisible && !projectStore.projects.isEmpty
    return NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
      Color.clear.frame(width: 0)
    } detail: {
      HStack(spacing: 0) {
        if sidebarShown {
          SidebarColumn(
            paneDrag: $workroomChipDrag,
            localize: { workroomChipLocal($0) },
            dropTarget: { workroomChipDropTarget(at: $0) }
          )
          .transition(.move(edge: .leading))
        }
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if inspectorVisible {
          InspectorColumn()
            .transition(.move(edge: .trailing))
        }
        // The activity bar is ALWAYS present, flush to the window's trailing edge — the inspector
        // content pane (above) slides in/out beside it. Placed inside the detail-only
        // NavigationSplitView so its icon buttons get working `.onHover` (issue #114).
        ActivityBar()
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sidebarShown)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: inspectorVisible)
    }
  }

  /// Error sheet, add-project importer, and the new-workroom / workroom-delete / project-delete
  /// presenters — all driven by store flags plus the `showImporter` state.
  private func rootModals<V: View>(_ content: V) -> some View {
    content
      // A sheet, not an alert: an alert's message can't hold the collapsed Details.
      .sheet(
        isPresented: Binding(
          get: { modals.errorMessage != nil },
          set: { if !$0 { modals.clearError() } }
        )
      ) {
        ErrorSheet(
          title: modals.errorTitle ?? "Something went wrong", message: modals.errorMessage ?? "",
          log: modals.errorLog, details: modals.errorDetails, action: modals.errorAction,
          approval: modals.errorApproval, scriptName: modals.errorScriptName,
          cancel: modals.errorCancel,
          onDismiss: { modals.clearError() }
        )
      }
      // Add-project importer + delete confirmation, re-homed here from ProjectSidebar (issue #23 OV1) so
      // the ⌘O / ⌘⌫ menu commands present reliably even when the sidebar is collapsed in Workrooms View.
      // The triggers live on `ModalState` (`requestAddProject` / `pendingDeletion`), set by both the
      // menu commands and the sidebar's own buttons.
      .onChange(of: modals.requestAddProject) { _, request in
        if request {
          showAddProject = true
          modals.requestAddProject = false
        }
      }
      .sheet(isPresented: $showAddProject) {
        AddProjectSheet(
          onAdd: { path, create in
            showAddProject = false
            Task { await store.addProject(path, create: create) }
          },
          onCancel: { showAddProject = false }
        )
      }
      // VCS failure dialog. Hosted here rather than on the inspector because ⌥⇧⌘P and the rest of the
      // Room menu work with the inspector hidden, and a failure they raise still has to be
      // readable. `performRemoteAction`, not `runRemoteAction`, so a Pull recovery meets the dirty-tree
      // confirmation — and the sheet is window-modal, so the selection cannot have moved under it.
      .modifier(
        VCSFailurePresenter(
          model: store.remoteState, onRecover: { store.performRemoteAction($0) })
      )
      // New Workroom picker (⌘N, issue #81): same store-flag bridge as the importer above, packaged as
      // a modifier so this large `body` stays within the type-checker's budget (like EdgeRevealSidebars).
      // The menu command gates on `hasProjects`, so it only fires with ≥1 project; the dialog itself
      // still handles a filter that matches nothing.
      .modifier(NewWorkroomPresenter(store: store))
      // Open Workroom picker (⌘O, issue #94): same store-flag bridge, also gated on `hasProjects`.
      .modifier(OpenWorkroomPresenter(store: store))
      .modifier(StartChoicePresenter(store: store))
      .confirmationDialog(
        modals.pendingDeletion.map { "Delete '\($0.workroom.displayName)'?" } ?? "Delete workroom?",
        isPresented: Binding(
          get: { modals.pendingDeletion != nil }, set: { if !$0 { modals.pendingDeletion = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let target = modals.pendingDeletion {
            lifecycle.deleteWorkroom(target.workroom, in: target.project, from: store)
          }
          modals.pendingDeletion = nil
        }
        Button("Cancel", role: .cancel) { modals.pendingDeletion = nil }
      } message: {
        // #253: a remote workroom has no directory here; its host goes, and all on it.
        if let target = modals.pendingDeletion, target.workroom.isSSH {
          Text(
            "This removes \(target.workroom.path) on \(target.workroom.host?.sshDestination ?? "its host"), "
              + "including changes and commits that aren't pushed. The server and its other folders stay."
          )
        } else if let target = modals.pendingDeletion, target.workroom.isRemote {
          Text(
            "This destroys the workroom's remote machine and everything on it, including changes "
              + "and commits that aren't pushed."
          )
        } else if let target = modals.pendingDeletion,
          runCommands.hasLiveInvestigateSession(for: [
            TargetID.workroom(project: target.project.path, name: target.workroom.name)
          ])
        {
          Text(
            "This workroom has an active Investigate agent session running — deleting will stop "
              + "it. This removes the workroom's directory and runs its teardown script. For Git, "
              + "the branch is left in place."
          )
        } else {
          Text(
            "This removes the workroom's directory and runs its teardown script. For Git, the branch is left in place."
          )
        }
      }
      // Tab bar "Close": tear down all of the workroom's terminal tabs (its chip leaves the bar),
      // leaving the workroom itself in place. Same store-flag → confirmationDialog bridge as delete.
      .confirmationDialog(
        modals.pendingWorkroomClose.map { "Close ‘\($0.name)’?" } ?? "Close workroom?",
        isPresented: Binding(
          get: { modals.pendingWorkroomClose != nil },
          set: { if !$0 { modals.pendingWorkroomClose = nil } }),
        titleVisibility: .visible
      ) {
        Button("Close", role: .destructive) {
          if let pending = modals.pendingWorkroomClose { store.closeWorkroom(for: pending.target) }
          modals.pendingWorkroomClose = nil
        }
        Button("Cancel", role: .cancel) { modals.pendingWorkroomClose = nil }
      } message: {
        Text(
          "This closes all of the workroom's terminal tabs and stops anything running in them. The workroom itself is kept."
        )
      }
      // Project deletion uses a type-to-confirm sheet (not a one-tap dialog): it's a bigger,
      // optionally-cascading action, so it demands typing the project name. `.sheet(item:)`
      // rebuilds per pending identity, resetting the sheet's typed/toggle state.
      .sheet(item: $modals.pendingProjectDeletion) { pending in
        DeleteProjectSheet(
          project: pending.project,
          // Issue #146: deleteProject reaps live terminals unconditionally (even `.configOnly`,
          // which keeps files on disk) — warn if any target in this project has a live Investigate
          // session, since none of the sheet's existing per-scope copy mentions stopping one.
          hasLiveInvestigateSession: runCommands.hasLiveInvestigateSession(
            for: [TargetID.root(project: pending.project.path)]
              + pending.project.workrooms.map {
                TargetID.workroom(project: pending.project.path, name: $0.name)
              }),
          onDelete: { scope in
            modals.pendingProjectDeletion = nil
            lifecycle.deleteProject(pending.project, scope: scope, from: store)
          },
          onCancel: { modals.pendingProjectDeletion = nil }
        )
      }
      // Set/edit a workroom's display label (issue #41). Same `.sheet(item:)` bridge as project
      // deletion above — the id-keyed item rebuilds the sheet per workroom, resetting its field.
      .sheet(item: $modals.pendingWorkroomLabel) { pending in
        WorkroomLabelSheet(
          workroom: pending.workroom,
          project: pending.project,
          onSet: { label in
            modals.pendingWorkroomLabel = nil
            store.setWorkroomLabel(pending.workroom, in: pending.project, to: label)
          },
          onCancel: { modals.pendingWorkroomLabel = nil }
        )
      }
      // A project's settings open in Settings ▸ Projects (issue #7; #127 adds the no-command Run).
      // Cleared at once: the request is handed on, and no sheet holds this window's shortcuts.
      .onChange(of: modals.pendingProjectSettings?.id) {
        guard let pending = modals.pendingProjectSettings else { return }
        modals.pendingProjectSettings = nil
        SettingsRoute.shared.show(
          project: pending.project.path, runWarning: pending.showsRunWarning)
        openSettings()
      }
      // The commit dialog. Presented on the ROOT for `VCSFailureSheet`'s reason: it can be opened
      // from the Changes header, and a dialog that only survives while a particular pane happens to
      // be open is worse than no dialog. `pendingCommit` is already counted by
      // `hasModalPresentation`, so the Room menu's Fetch/Push/Pull shortcuts are inert behind it.
      .sheet(item: $modals.pendingCommit) { pending in
        CommitSheet(pending: pending, onDismiss: { modals.pendingCommit = nil })
          .environmentObject(store)
          .environmentObject(store.vcsStatus)
      }
      // A first create at a remote provider, held until the user's account there is ready.
      // A sheet dismissed any other way than its buttons cancels, so no create waits for good.
      .sheet(
        item: Binding(
          get: { modals.pendingRemoteSetup },
          set: { if $0 == nil { lifecycle.resolveRemoteSetup(carryOn: false, in: store.modals) } })
      ) { pending in
        remoteSetupSheet(pending)
      }
  }

  /// The provider's own setup sheet for `pending`. Create Workroom carries on every create waiting on
  /// it, in their own panes (#483, R2); Cancel ends them.
  @ViewBuilder
  private func remoteSetupSheet(_ pending: PendingRemoteSetup) -> some View {
    let create = { lifecycle.resolveRemoteSetup(carryOn: true, in: store.modals) }
    let cancel = { lifecycle.resolveRemoteSetup(carryOn: false, in: store.modals) }
    if let setup = pending.setup as? ExeDevSetup {
      ExeDevSetupSheet(setup: setup, onCreate: create, onCancel: cancel)
    } else if let setup = pending.setup as? BoxdSetup {
      BoxdSetupSheet(setup: setup, onCreate: create, onCancel: cancel)
    } else if let setup = pending.setup as? SSHHostSetup {
      SSHHostSetupSheet(setup: setup, onCreate: create, onCancel: cancel)
    } else if let setup = pending.setup as? RailwaySetup {
      RailwaySetupSheet(setup: setup, onCreate: create, onCancel: cancel)
    }
  }

  /// The edge-reveal sidebars and the foreground toast overlay — the layers drawn over the split.
  private func rootReveals<V: View>(_ content: V) -> some View {
    content
      // Edge-hover reveal of a collapsed sidebar (issue #56): each layer is active only while its
      // sidebar is closed, slides the same content in OVER the detail, and is inert otherwise. Applied
      // before the toast overlay so toasts keep z-order above a revealed panel. Packaged as a modifier
      // so this large `body` stays within the type-checker's budget.
      .modifier(
        EdgeRevealSidebars(
          sidebarVisible: store.sidebarVisible,
          paneDrag: $workroomChipDrag,
          localize: { workroomChipLocal($0) },
          dropTarget: { workroomChipDropTarget(at: $0) })
      )
      // Foreground toasts (issue #31): pinned bottom-right, over the split + inspector. Inset by the
      // activity bar's width (44) so a toast never sits under the always-visible bar on the edge.
      // `.pointerStyle`: the arrow over a toast, not a terminal's cursor rect beneath it (#466).
      .overlay(alignment: .bottomTrailing) {
        ToastStackAdapter().pointerStyle(.default).padding(.trailing, 44)
      }
  }

  /// Window lifecycle + the notification-raised sheets (theme picker, keyboard shortcuts, What's New):
  /// terminal theme registration, appearance application, and the key-window-guarded sheet presenters.
  private func rootLifecycle<V: View>(_ content: V) -> some View {
    content
      .onAppear {
        // Register this window's terminals for theme sweeps — every window stays themed when the theme
        // changes (issue #70/#36; ThemeService owns application, the surface iteration stays in
        // TerminalPanes). Weakly held, so a closed window drops out on its own.
        ThemeService.shared.registerTerminals(store.terminals)
        applyAppearance()
      }
      .onDisappear { ThemeService.shared.unregisterTerminals(store.terminals) }
      .onChange(of: theme) { _ in applyAppearance() }
      // The theme picker is deliberately NOT here: it's a dropdown anchored to a toolbar button
      // (`TrailingTitlebarBar`), because a sheet is the wrong shape for a live preview.
      .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
        guard store.hostWindow?.isKeyWindow ?? false else { return }
        showKeyboardShortcuts = true
      }
      .sheet(isPresented: $showKeyboardShortcuts) {
        KeyboardShortcutsView()
      }
      .modifier(WhatsNewLaunchCheck(store: store, presented: $whatsNewShown))
  }

  /// Window-level chrome (title, toolbar trimming, background themer + the unified title-bar bar), the
  /// regain-focus refresh, and the menu-command state values published for `WorkroomCommands`.
  private func rootWindowChrome<V: View>(_ content: V) -> some View {
    content
      // Title the window with the selected project/workroom for the Window menu + Mission Control. A
      // non-empty `navigationTitle` re-asserts `titleVisibility = .visible` every render — which used to
      // flash the name across the bar on each selection/focus/close change. On macOS 15+ we remove the
      // *visible* title declaratively with `.toolbar(removing: .title)` (S1 spike): the window keeps its
      // `title` for the Window menu, but SwiftUI no longer re-asserts a visible title → no flash. The
      // `AppStore.attachWindow` `didUpdate` re-hide lock stays as the pre-15 fallback (issue #70).
      // Sets `window.title` for the Window menu / Mission Control only; the VISIBLE title is hidden in
      // AppKit (`WindowBackgroundThemer` sets `titleVisibility = .hidden`, backed by the `attachWindow`
      // re-hide lock). We deliberately declare NO SwiftUI `.toolbar*` modifiers here: the taller
      // unified title bar + centered traffic lights are now owned by an empty AppKit `NSToolbar` set in
      // `WindowBackgroundThemer`. Any SwiftUI-managed toolbar item drags in the overflow
      // `menuFormRepresentation` recompute that caused the macOS-26 AppHangs (see WindowBackgroundThemer
      // for the full mechanism). The chrome (leading controls · workroom tabs · trailing controls) lives
      // in a full-width `.left` titlebar accessory to the RIGHT of the lights (Chrome-style), which
      // never collapses into an overflow `»` (the tab strip is a ScrollView that just scrolls).
      .navigationTitle(store.windowTitle)
      .modifier(AccessoryBarInjector(store: store, bar: AnyView(accessoryBarContent)))
      .background(WindowBackgroundThemer())
      // Keep the root branch labels reasonably current: refresh when the app regains
      // focus (throttled, so rapid alt-tabbing doesn't fork a git process per project).
      // Regaining focus also dismisses the now-visible terminal's notifications (you're looking at it).
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        store.dismissFocusedTerminalNotifications()
        // Refresh the History log if it's the visible inspector section — a commit made in an
        // external terminal while backgrounded won't have repainted via the live watcher.
        store.refreshHistoryIfActive()
        // Same safety net for the VCS toolbar, plus the auto-fetch due-check: a fetch or a teammate's
        // push while backgrounded won't have reached the metadata watcher.
        store.refreshRemoteStateIfActive()
        Task { await store.reloadIfStale() }
      }
      // Keep the store's mirror of the view-local sheet flags current, so `hasModalPresentation` is
      // a complete answer for every reader (see its doc comment).
      .onChange(of: auxSheetPresented, initial: true) { _, presented in
        modals.auxSheetPresented = presented
      }
      // Publish selection state for menu-command enablement (see WorkroomCommands).
      .modifier(MenuStateAdapter(store: store))
  }

  /// The sheets RootView owns as `@State` rather than store state, ORed for the store mirror.
  ///
  /// The theme panel is absent on purpose: it is not modal. Counting it would make every shortcut and
  /// menu item inert while it's up, and the whole point of it being a panel is that you keep using the
  /// app — ⌘⇧L especially — to see what the theme you just picked actually looks like.
  private var auxSheetPresented: Bool {
    showAddProject || showKeyboardShortcuts || whatsNewShown
  }

  /// Pushes the chosen appearance onto the running app. nil (System) tells AppKit to
  /// follow the OS appearance and keep tracking it. Terminals follow the appearance too, but
  /// only those currently in a window get AppKit's change hook — so sweep them all explicitly
  /// (see `TerminalPanes.applyThemeToAll`).
  private func applyAppearance() {
    NSApp.appearance = theme.nsAppearance
    // Route through the single chokepoint: recomputes chrome tokens for the (possibly flipped)
    // active variant, re-themes live terminals, and notifies AppKit sites. `force` because an
    // appearance/preference change must always re-theme even if `dark` is unchanged.
    ThemeService.shared.applyActiveTheme(force: true)
  }

  @ViewBuilder
  private var detail: some View {
    // The workroom tab bar now rides in the title bar (issue #23 — see `leadingTitlebar`), between the
    // leading controls and the trailing toolbar, so the detail is just the terminal / empty-state
    // content below it.
    VStack(spacing: 0) {
      detailContent
        // Always fill the remaining height so the tab bar above stays pinned to the top. The
        // terminal branch fills on its own, but the empty states (Nothing selected / Directory not
        // found) size to their content — without this the VStack would shrink to fit and center,
        // dropping the tab bar to the vertical middle when a workroom has terminals but nothing is
        // selected (issue #23 follow-up).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The detail content's global frame, so a chip dragged from the bar can be resolved against the
        // workroom panes below it (issue #23 follow-up) — mirrors WorkroomTerminalsView ↔ TerminalTabStrip.
        // Track the detail content's global frame so a chip dragged from the tab bar can be resolved
        // against the workroom panes below it (issue #23 follow-up). `.onGeometryChange` (not the older
        // `.background(GeometryReader → preference)` + `.onPreferenceChange`): preferences set inside a
        // `.background` did not reliably re-propagate the *settled* frame — after the sidebar opened and
        // shifted the detail right, the sink kept a stale transient value and never received the final
        // rect, so a chip drop hit-tested an off-screen frame and the split silently failed with the
        // sidebar open (worked collapsed only because the stale frame still spanned the left). This
        // observes the frame directly and fires reliably on every change.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
          detailContentFrame = $0
          // Mirror the derived pane space into the store so a NON-drag caller (⌥⌘O, "Open in
          // Split") can apply the same pane floor a drop does. Derived from `$0` rather than from
          // the just-written `@State`, so it cannot depend on read-after-write ordering. Assigning
          // a plain (non-`@Published`) var, so this cannot re-enter layout.
          store.workroomPaneSpace = Self.paneSpace(in: $0)
        }
    }
    // The detail column (tab bar + region around the panes) uses the theme *panel* colour — a
    // subtle step off the terminal background (issue #36) — so the chrome reads as a distinct
    // surface framing the terminals rather than one flat colour.
    //
    // Not under the title bar (`ignoresSafeAreaEdges: []`): SwiftUI counts a fill there as not-the-drag
    // region, and AppKit only zooms the window on a title-bar double-click inside the drag region. The
    // window background behind the bar is already this colour (`WindowBackgroundThemer`).
    .background(tokens.panel, ignoresSafeAreaEdges: [])
  }

  /// The content-local point for a chip drag at `global`, or nil when the cursor is still over the bar
  /// (→ a reorder, not a drop-into-content). The detail content frame spans the full window height —
  /// its top sits *under* the title bar — so a point still within the title-bar strip is a reorder, not
  /// a drop-into-pane (without this guard every horizontal reorder drag, staying at chip height, would
  /// be mistaken for a split — the chips could never be reordered).
  private func workroomChipLocal(_ global: CGPoint) -> CGPoint? {
    guard global.y >= WorkroomTitlebar.height else { return nil }
    let space = workroomPaneSpace
    guard space.contains(global) else { return nil }
    return CGPoint(x: global.x - space.minX, y: global.y - space.minY)
  }

  /// The rect the split renderer actually lays its panes out in: the detail content inset by
  /// `WorkroomSplitView.outerGutter` left and right, and by `windowBottomMargin` on the bottom only
  /// (top gets no outer inset), because that padding is applied OUTSIDE the renderer's
  /// `GeometryReader`, so its pane coordinates start at the inset edge. Hit-testing against the
  /// unpadded frame puts every drop off the pane that was drawn — worst in the gutter itself, where
  /// the drop would land (RootView's rect contains it) with no edge preview ever shown (the
  /// renderer's rect does not). Solo used to be exempt because it had no gutter; since issue #139 it
  /// has one too.
  private var workroomPaneSpace: CGRect { Self.paneSpace(in: detailContentFrame) }

  /// The pure inset, shared by `workroomPaneSpace` (chip-drop hit-testing) and the mirror into
  /// `AppStore.workroomPaneSpace` (the pane floor for keyboard/menu splits) so the two can never
  /// disagree about where the panes actually are.
  static func paneSpace(in frame: CGRect) -> CGRect {
    var space = frame.insetBy(dx: WorkroomSplitView.outerGutter, dy: 0)
    space.size.height -= WorkroomPaneMetrics.windowBottomMargin
    return space
  }

  /// The layout a chip drop targets — the same one the detail is rendering, so the drop edges match
  /// what's on screen: the split when a member is selected, else the lone visible workroom (a drop onto
  /// which seeds a fresh split).
  private func workroomDropLayout() -> PaneLayout<SidebarID>? {
    guard let sid = store.selectedTargetID else { return nil }
    return store.visibleWorkroomLayout(for: sid)
  }

  /// Where a chip dropped at `global` lands (workroom pane + edge), using the same plan the renderer
  /// uses, or nil if it isn't over a pane.
  ///
  /// Carries the hit pane's MEASURED rect as well: `AppStore.insertWorkroomSplit` needs it to refuse a
  /// drop that would halve a pane under the floor, and this is the only layer that has it (the plan is
  /// computed here). Nothing below forwards it anywhere but back to the store.
  private func workroomChipDropTarget(at global: CGPoint) -> (
    sid: SidebarID, edge: PaneEdge, rect: CGRect
  )? {
    guard let local = workroomChipLocal(global), let layout = workroomDropLayout() else {
      return nil
    }
    let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: workroomPaneSpace.size))
    guard let hit = PaneTreeLayout.dropTarget(at: local, panes: plan.panes),
      let rect = plan.panes[hit.tab]
    else { return nil }
    return (sid: hit.tab, edge: hit.edge, rect: rect)
  }

  /// Focus a workroom tab — mirrors `ProjectSidebar`'s selection setter (sets both the target and the
  /// New-Workroom project context). The split is persistent (like a terminal split): selecting a member
  /// shows the split, selecting a non-member shows that workroom solo *without* dissolving the split —
  /// it reappears when a member is reselected (`visibleWorkroomLayout`). The split dissolves only by
  /// removing members below two.
  private func selectWorkroomTab(_ sid: SidebarID) {
    // Re-selecting the current workroom is a no-op, not a republish. Since issue #139 every pane has a
    // title bar, and a click anywhere on it falls through to the leaf's focus tap — so without this
    // guard, clicking your own workroom's header rewrites unchanged `@Published` selection state and
    // re-renders the whole tree.
    guard store.selectedTargetID != sid else { return }
    store.selectedTargetID = sid
    store.selectedProjectID = AppStore.projectPath(of: sid)
  }

  @ViewBuilder
  private var detailContent: some View {
    if store.selectedTarget != nil {
      // The focused target's terminal body — ALWAYS rendered through `WorkroomSplitView` (a no-split
      // case is just `.leaf(selected)`), so single↔split is a leaf-set change, never a structural swap
      // that would re-parent the surface and blank a pane (issue #23, the same lesson as
      // `WorkroomTerminalsView` always rendering through `PaneTreeView`).
      //
      // A missing directory routes through here too, since issue #139: it used to get its own
      // `ContentUnavailableView` branch at this level, which meant a SOLO missing workroom never
      // reached the pane at all and so had no title bar — while a missing *split member* did.
      // `TargetTerminalDetail` now owns that state for every pane, focused or not. A workroom still
      // being created is the same shape since issue #171: its pane owns its loader / setup dialog, so
      // a create that landed beside an anchor keeps BOTH panes on screen while it runs.
      //
      // The run/stop/restart + "Open in…" controls live in each workroom pane's own title bar
      // (`WorkroomPaneTitleBar`), not the window title bar and not a detail `.toolbar`. The window
      // title/subtitle are dropped too — the workroom tabs already name the current workroom.
      workroomSplitBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView {
        Label {
          Text("Work it!")
        } icon: {
          // `AppMark`, not `MenuBarIcon`: same monochrome glyph (`Scripts/make-icon.swift`'s
          // `renderMenuBarGlyph` draws both, just at different pixel sizes) but rendered at 128pt
          // instead of 18pt — `MenuBarIcon`'s 36px-max source went visibly blurry upscaled this far.
          // Both are template images (`template-rendering-intent: template`), so no rounded-square
          // plate/border, just the mark, tinted like any other secondary icon here.
          Image("AppMark")
            .resizable()
            .scaledToFit()
            .frame(width: 128, height: 128)
            .foregroundStyle(.secondary)
        }
      } description: {
        // Zero projects: the sidebar's own empty-state copy (`ProjectSidebar`) — the sidebar itself
        // is hidden in this state (see `splitView`), so this is the only place left to say it.
        if projectStore.projects.isEmpty {
          Text("Add your first project!")
        } else {
          Text("Select a project's root, or open (⌘O) or create (⌘N) a workroom to get started.")
        }
      } actions: {
        if projectStore.projects.isEmpty {
          Button("Add Project…") { modals.requestAddProject = true }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("EmptyStateAddProject")
        }
      }
    }
  }

  /// The workroom body: always `WorkroomSplitView`, with the layout being the split when the selected
  /// workroom is a member, else `.leaf(selected)` — the split is shown only when a member is focused but
  /// persists otherwise (`visibleWorkroomLayout`, mirroring the terminal split). One render path → no
  /// reparent on single↔split.
  ///
  /// Only the selection *id* is needed: `selectedTarget` is `selectedTargetID.flatMap(target(for:))`,
  /// so the caller having resolved a target already guarantees the id is there. (There used to be a
  /// bare-terminal-body fallback here for the other case; it was unreachable, and a header-less render
  /// path that can't happen is worse than none.)
  @ViewBuilder
  private var workroomSplitBody: some View {
    if let selected = store.selectedTargetID {
      WorkroomSplitView(
        store: store,
        layout: store.visibleWorkroomLayout(for: selected),
        resolve: { store.target(for: $0) },
        focusedID: selected,
        externalDrag: $workroomChipDrag,
        localize: { workroomChipLocal($0) },
        dropTarget: { workroomChipDropTarget(at: $0) },
        onFocus: { selectWorkroomTab($0) },
        onSetRatio: { store.setWorkroomSplitRatio($0, forSplit: $1) },
        onClose: { store.removeWorkroomSplitMember($0) },
        onMove: { store.insertWorkroomSplit($0, beside: $1, edge: $2, destinationRect: $3) }
      )
    }
  }
}
