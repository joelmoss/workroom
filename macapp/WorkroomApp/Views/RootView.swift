import AppKit
import Defaults
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  // Observed so the detail's workroom tab bar re-renders as terminals open/close (a tab appears when a
  // workroom gains its first terminal and disappears when it loses its last) — issue #23.
  @EnvironmentObject var terminals: TerminalSessions
  // Drives the leading title-bar "Update" pill (injected into the accessory closure below) and the
  // "What's New" dialog. Both injected by `WorkroomApp` on the `RootWindow`.
  @EnvironmentObject var updater: Updater
  @EnvironmentObject var whatsNew: WhatsNewService
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Default(.theme) private var theme
  /// Whether the right-hand inspector (Changes / Files / Pull Request) is open. `@Default` (not
  /// `@State`) so the View-menu command (WorkroomCommands) toggles the same value.
  @Default(.showInspector) private var showInspector

  /// Drives the New Project sheet — set from `store.requestAddProject`, which both the menu command
  /// and the sidebar's Add-Project buttons raise. Hosted here (vs the sidebar) so the command presents
  /// it even if the sidebar is collapsed via the standard toggle. The sheet (issue #103) offers two
  /// modes: add an existing repo, or create + git-init a new directory.
  @State private var showAddProject = false

  /// Presents the theme picker (issue #36), raised by the `Theme…` (⌘⇧K) command via notification.
  @State private var showThemePicker = false

  /// Presents the keyboard-shortcuts reference, raised by the `Keyboard Shortcuts…` command via
  /// notification (same menu-can't-anchor-a-sheet pattern as the theme picker).
  @State private var showKeyboardShortcuts = false

  /// The "What's New" dialog's content, or nil when closed. Set by the launch-window auto-check.
  /// Window-local so multiple windows never stack duplicate dialogs.
  @State private var whatsNewContent: WhatsNewSheetContent?

  /// Live preview of a workroom tab being dragged into the detail content to form a split (issue #23
  /// follow-up). Set by `WorkroomTabBar`'s drag, read by `WorkroomSplitView` to highlight the drop edge.
  @State private var workroomChipDrag: WorkroomPaneDrag?
  /// The detail content area's global frame, so a chip drag can be resolved against the workroom panes.
  @State private var detailContentFrame: CGRect = .zero

  /// True when the selected target can host a terminal right now: it exists, isn't missing, and the
  /// detail isn't currently showing the creating slot's loader/setup dialog (issue #116).
  private var terminalInteractionAvailable: Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    if store.isCreationFocused { return false }
    return true
  }

  /// The single, full-width title-bar bar (issue #23), hosted as one `NSTitlebarAccessoryViewController`
  /// stretched from just right of the traffic lights to the window's trailing edge (`fillsWidth`). It
  /// lays out, left to right: the leading controls (sidebar toggle + history nav), then — when any
  /// workroom/root has a terminal — a divider and the **workroom tab bar, which fills all the space
  /// between** the leading and trailing controls; then the trailing controls (run/open-in + bell +
  /// inspector toggle), hugging the right edge. One accessory rather than two because both halves can't
  /// claim the trailing edge while a stretchable bar fills the middle. Env objects + the chip-drag
  /// plumbing are injected/captured inside the closure because the hosted tree lives outside the
  /// WindowGroup's environment.
  private var titlebarBar: some View {
    let tabs = store.displayedWorkroomTargets()
    return HStack(spacing: 6) {
      LeadingTitlebarBar()
      if !tabs.isEmpty {
        WorkroomTabBar(
          tabs: tabs, selectedID: store.selectedTargetID,
          onSelect: { selectWorkroomTab($0) },
          chipPaneDrag: $workroomChipDrag,
          localize: { workroomChipLocal($0) },
          dropTarget: { workroomChipDropTarget(at: $0) }
        )
      } else {
        Spacer(minLength: 0)
      }
      TrailingTitlebarBar()
    }
    // Clear the traffic-light cluster on the leading edge (the bar now spans the full window width
    // as the top strip of the content, not an accessory placed after the lights by AppKit).
    .padding(.leading, WorkroomTitlebar.trafficLightInset)
    .frame(height: WorkroomTitlebar.height)
    .frame(maxWidth: .infinity)
    // Empty regions of the bar drag the window; the panel colour reads as one surface with the
    // title bar / tab bar / gutters (it sits behind the transparent drag layer).
    .background(WindowDragBackground())
    .background(ThemeService.shared.tokens.panel)
  }

  var body: some View {
    // The custom chrome now lives in a real `.unified` window toolbar (`titlebarContent`, hosted via
    // `.toolbar` in `rootWindowChrome`), not a content top-strip — so AppKit owns the bar height and
    // centers the traffic lights alongside the controls.
    rootWindowChrome(rootLifecycle(rootReveals(rootModals(splitView))))
  }

  /// The workroom tab strip, hosted as the principal (center) toolbar item (S4 rehost). Leading /
  /// trailing controls are separate toolbar placements (`LeadingTitlebarBar` / `TrailingTitlebarBar`).
  /// No strip chrome (height / panel background / drag layer / inset) — the real toolbar provides the
  /// bar, its height, and the traffic-light gutter.
  /// The full title-bar bar hosted in the `.left` titlebar accessory: leading controls, the workroom
  /// tab strip (fills + scrolls), trailing controls. Environment objects are re-injected because the
  /// accessory is a separate hosting tree from the main window content.
  private var accessoryBarContent: some View {
    HStack(spacing: 6) {
      LeadingTitlebarBar()
      workroomTabsBar
      TrailingTitlebarBar()
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // No own background — the accessory is transparent so the window's panel bg shows through it AND
    // behind the traffic lights uniformly (an opaque fill here didn't match the titlebar strip behind
    // the lights). WindowBackgroundThemer sets the window bg to the panel token.
    .environmentObject(store)
    .environmentObject(notifications)
    .environmentObject(terminals)
    .environmentObject(updater)
  }

  @ViewBuilder private var workroomTabsBar: some View {
    let tabs = store.displayedWorkroomTargets()
    // Show the bar during a create even before any tab resolves (issue #116) — it hosts the
    // provisional "Creating…" chip, so the bar can't be hidden just because `tabs` is still empty.
    if !tabs.isEmpty || store.creation != nil {
      WorkroomTabBar(
        tabs: tabs, selectedID: store.selectedTargetID,
        onSelect: { selectWorkroomTab($0) },
        chipPaneDrag: $workroomChipDrag,
        localize: { workroomChipLocal($0) },
        dropTarget: { workroomChipDropTarget(at: $0) }
      )
      .frame(maxWidth: .infinity)
    } else {
      Spacer(minLength: 0)
    }
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
    NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
      Color.clear.frame(width: 0)
    } detail: {
      HStack(spacing: 0) {
        if store.sidebarVisible {
          SidebarColumn(
            paneDrag: $workroomChipDrag,
            localize: { workroomChipLocal($0) },
            dropTarget: { workroomChipDropTarget(at: $0) }
          )
          .transition(.move(edge: .leading))
        }
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if showInspector {
          InspectorColumn()
            .transition(.move(edge: .trailing))
        }
        // The activity bar is ALWAYS present, flush to the window's trailing edge — the inspector
        // content pane (above) slides in/out beside it. Placed inside the detail-only
        // NavigationSplitView so its icon buttons get working `.onHover` (issue #114).
        ActivityBar()
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.sidebarVisible)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showInspector)
    }
  }

  /// Error alert, add-project importer, and the new-workroom / workroom-delete / project-delete
  /// presenters — all driven by store flags plus the `showImporter` state.
  private func rootModals<V: View>(_ content: V) -> some View {
    content
      .alert(
        store.errorTitle ?? "Something went wrong",
        isPresented: Binding(
          get: { store.errorMessage != nil },
          set: {
            if !$0 {
              store.errorMessage = nil
              store.errorTitle = nil
            }
          }
        )
      ) {
        Button("OK", role: .cancel) {
          store.errorMessage = nil
          store.errorTitle = nil
        }
      } message: {
        Text(store.errorMessage ?? "")
      }
      // Add-project importer + delete confirmation, re-homed here from ProjectSidebar (issue #23 OV1) so
      // the ⌘O / ⌘⌫ menu commands present reliably even when the sidebar is collapsed in Workrooms View.
      // The triggers stay on the store (`requestAddProject` / `pendingDeletion`), set by both the menu
      // commands and the sidebar's own buttons.
      .onChange(of: store.requestAddProject) { _, request in
        if request {
          showAddProject = true
          store.requestAddProject = false
        }
      }
      .sheet(isPresented: $showAddProject) {
        AddProjectSheet(
          onAdd: { path, create in
            showAddProject = false
            Task { await store.addProject(path, create: create) }
          },
          onCancel: { showAddProject = false })
      }
      // New Workroom picker (⌘N, issue #81): same store-flag bridge as the importer above, packaged as
      // a modifier so this large `body` stays within the type-checker's budget (like EdgeRevealSidebars).
      // The menu command gates on `hasProjects`, so it only fires with ≥1 project; the dialog itself
      // still handles a filter that matches nothing.
      .modifier(NewWorkroomPresenter(store: store))
      // Open Workroom picker (⌘O, issue #94): same store-flag bridge, also gated on `hasProjects`.
      // One of several sibling `.sheet` presenters on this view — only one is ever active at a time.
      .modifier(OpenWorkroomPresenter(store: store))
      .confirmationDialog(
        store.pendingDeletion.map { "Delete '\($0.workroom.displayName)'?" } ?? "Delete workroom?",
        isPresented: Binding(
          get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let target = store.pendingDeletion {
            store.deleteWorkroom(target.workroom, in: target.project)
          }
          store.pendingDeletion = nil
        }
        Button("Cancel", role: .cancel) { store.pendingDeletion = nil }
      } message: {
        Text(
          "This removes the workroom's directory and runs its teardown script. For Git, the branch is left in place."
        )
      }
      // Tab bar "Close": tear down all of the workroom's terminal tabs (its chip leaves the bar),
      // leaving the workroom itself in place. Same store-flag → confirmationDialog bridge as delete.
      .confirmationDialog(
        store.pendingWorkroomClose.map { "Close ‘\($0.name)’?" } ?? "Close workroom?",
        isPresented: Binding(
          get: { store.pendingWorkroomClose != nil },
          set: { if !$0 { store.pendingWorkroomClose = nil } }),
        titleVisibility: .visible
      ) {
        Button("Close", role: .destructive) {
          if let pending = store.pendingWorkroomClose { store.closeWorkroom(for: pending.target) }
          store.pendingWorkroomClose = nil
        }
        Button("Cancel", role: .cancel) { store.pendingWorkroomClose = nil }
      } message: {
        Text(
          "This closes all of the workroom's terminal tabs and stops anything running in them. The workroom itself is kept."
        )
      }
      // Project deletion uses a type-to-confirm sheet (not a one-tap dialog): it's a bigger,
      // optionally-cascading action, so it demands typing the project name. `.sheet(item:)`
      // rebuilds per pending identity, resetting the sheet's typed/toggle state.
      .sheet(item: $store.pendingProjectDeletion) { pending in
        DeleteProjectSheet(
          project: pending.project,
          onDelete: { scope in
            store.pendingProjectDeletion = nil
            store.deleteProject(pending.project, scope: scope)
          },
          onCancel: { store.pendingProjectDeletion = nil })
      }
      // Set/edit a workroom's display label (issue #41). Same `.sheet(item:)` bridge as project
      // deletion above — the id-keyed item rebuilds the sheet per workroom, resetting its field.
      .sheet(item: $store.pendingWorkroomLabel) { pending in
        WorkroomLabelSheet(
          workroom: pending.workroom,
          project: pending.project,
          onSet: { label in
            store.pendingWorkroomLabel = nil
            store.setWorkroomLabel(pending.workroom, in: pending.project, to: label)
          },
          onCancel: { store.pendingWorkroomLabel = nil })
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
      .overlay(alignment: .bottomTrailing) { ToastStack().padding(.trailing, 44) }
  }

  /// Window lifecycle + the notification-raised sheets (theme picker, keyboard shortcuts, What's New):
  /// terminal theme registration, appearance application, and the key-window-guarded sheet presenters.
  private func rootLifecycle<V: View>(_ content: V) -> some View {
    content
      .onAppear {
        // Register this window's terminals for theme sweeps — every window stays themed when the theme
        // changes (issue #70/#36; ThemeService owns application, the surface iteration stays in
        // TerminalSessions). Weakly held, so a closed window drops out on its own.
        ThemeService.shared.registerTerminals(store.terminals)
        applyAppearance()
      }
      .onDisappear { ThemeService.shared.unregisterTerminals(store.terminals) }
      .onChange(of: theme) { _ in applyAppearance() }
      // Present only in the key window — the notification is broadcast to every window's RootView, so
      // without this guard the sheet would pop in all of them (issue #70, OV #6).
      .onReceive(NotificationCenter.default.publisher(for: .showThemePicker)) { _ in
        guard store.hostWindow?.isKeyWindow ?? false else { return }
        showThemePicker = true
      }
      .sheet(isPresented: $showThemePicker) {
        ThemePicker(presentedAsSheet: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
        guard store.hostWindow?.isKeyWindow ?? false else { return }
        showKeyboardShortcuts = true
      }
      .sheet(isPresented: $showKeyboardShortcuts) {
        KeyboardShortcutsView()
      }
      // "What's New" auto-check: only the launch/restore window runs it, so restored ⌘N windows don't
      // each pop the dialog. Silent — opens straight to the notes when there are any to show.
      .task {
        guard store.isRestoreWindow else { return }
        if let notes = await whatsNew.checkOnLaunch() {
          whatsNewContent = WhatsNewSheetContent(notes: notes)
        }
      }
      .sheet(item: $whatsNewContent) { content in
        WhatsNewSheet(content: content) { whatsNewContent = nil }
      }
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
      .navigationTitle(store.windowTitle)
      .modifier(RemoveWindowTitleBarTitle())
      // An item-less `.unified` window toolbar (style set on the scene in `WorkroomApp`) is present
      // purely to (a) grow the title-bar to a taller single row and (b) let AppKit vertically center
      // the traffic lights in it — the "breathing room" above/below the chrome (issue #23). It carries
      // no controls: the chrome (leading controls · workroom tabs · trailing controls) lives in a
      // full-width `.left` titlebar accessory to the RIGHT of the lights (Chrome-style), which never
      // collapses into an overflow `»` (the tab strip is a ScrollView that just scrolls) and grows to
      // the taller bar. The clear principal item forces the (otherwise empty) toolbar to exist so it
      // sets the height; `.toolbarBackground(.hidden)` removes the toolbar's own material so the themed
      // window background (WindowBackgroundThemer) shows through the whole bar uniformly, incl. behind
      // the lights — instead of the toolbar's grey vibrancy.
      .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0) } }
      .toolbar(.visible, for: .windowToolbar)
      .toolbarBackground(.hidden, for: .windowToolbar)
      .background(TitlebarAccessoryHost { accessoryBarContent })
      .background(WindowBackgroundThemer())
      // Keep the root branch labels reasonably current: refresh when the app regains
      // focus (throttled, so rapid alt-tabbing doesn't fork a git/jj process per project).
      // Regaining focus also dismisses the now-visible terminal's notifications (you're looking at it).
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        store.dismissFocusedTerminalNotifications()
        Task { await store.reloadIfStale() }
      }
      // Publish selection state for menu-command enablement (see WorkroomCommands). Grouped into one
      // modifier so the long publisher chain stays a single, fast-to-type-check expression (SwiftUI
      // chokes on ~12 `.focusedSceneValue` calls inline).
      .modifier(
        MenuStateValues(
          // `workroomSelected`: while a setup script blocks the selected workroom's terminal, report
          // false so ⌘T can't open a (hidden) terminal behind the setup pane (Open/Reveal still work).
          workroomSelected: terminalInteractionAvailable,
          hasNotifications: !notifications.items.isEmpty,
          // `hasProjects`: "New Workroom" (⌘N) disabled with no projects (#81).
          hasProjects: !store.projects.isEmpty,
          // Go-menu Back/Forward (issue #26).
          canNavigateBack: store.canGoBack,
          canNavigateForward: store.canGoForward,
          // Run/Stop/Restart (issue #7) — run-state lives on the store, so these stay live.
          hasRunCommand: selectedHasRunCommand,
          runCommandActive: selectedRunCommandActive,
          hasRunTerminal: store.hasAnyRunTerminal,
          // Go-menu Previous/Next Workroom Tab (issue #29) — only meaningful with ≥2 tabs.
          multipleWorkroomTabs: store.orderedWorkroomTargets().count > 1,
          // Go-menu "Open in…" + ⌘O — enabled only with an editor and a valid selection.
          canOpenInEditor: store.canOpenInEditor,
          // View ▸ "Resize Workroom Splits Evenly" (#83) — only when the selected workroom is a live
          // member of a workroom-into-workroom split.
          workroomSplitVisible: store.isWorkroomSplitVisible))
  }

  /// The project path of the selected root or workroom (nil for no selection) — the run command is
  /// configured per project and runnable from either (issue #7).
  private var selectedRunProjectPath: String? {
    AppStore.projectPath(of: store.selectedTargetID)
  }
  /// Whether the selected workroom's project has a run command configured.
  private var selectedHasRunCommand: Bool {
    guard let path = selectedRunProjectPath else { return false }
    return store.hasRunCommand(forProject: path)
  }
  /// Whether the selected target's run command is currently running.
  private var selectedRunCommandActive: Bool {
    guard let target = store.selectedTarget else { return false }
    return store.isRunCommandRunning(for: target.id)
  }

  /// Pushes the chosen appearance onto the running app. nil (System) tells AppKit to
  /// follow the OS appearance and keep tracking it. Terminals follow the appearance too, but
  /// only those currently in a window get AppKit's change hook — so sweep them all explicitly
  /// (see `TerminalSessions.applyThemeToAll`).
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
        }
    }
    // The detail column (tab bar + region around the panes) uses the theme *panel* colour — a
    // subtle step off the terminal background (issue #36) — so the chrome reads as a distinct
    // surface framing the terminals rather than one flat colour.
    .background(ThemeService.shared.tokens.panel)
  }

  /// The content-local point for a chip drag at `global`, or nil when the cursor is still over the bar
  /// (→ a reorder, not a drop-into-content). The detail content frame spans the full window height —
  /// its top sits *under* the title bar — so a point still within the title-bar strip is a reorder, not
  /// a drop-into-pane (without this guard every horizontal reorder drag, staying at chip height, would
  /// be mistaken for a split — the chips could never be reordered).
  private func workroomChipLocal(_ global: CGPoint) -> CGPoint? {
    guard global.y >= WorkroomTitlebar.height else { return nil }
    guard detailContentFrame.contains(global) else { return nil }
    return CGPoint(x: global.x - detailContentFrame.minX, y: global.y - detailContentFrame.minY)
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
  private func workroomChipDropTarget(at global: CGPoint) -> (sid: SidebarID, edge: PaneEdge)? {
    guard let local = workroomChipLocal(global), let layout = workroomDropLayout() else {
      return nil
    }
    let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: detailContentFrame.size))
    guard let hit = PaneTreeLayout.dropTarget(at: local, panes: plan.panes) else { return nil }
    return (sid: hit.tab, edge: hit.edge)
  }

  /// Focus a workroom tab — mirrors `ProjectSidebar`'s selection setter (sets both the target and the
  /// New-Workroom project context). The split is persistent (like a terminal split): selecting a member
  /// shows the split, selecting a non-member shows that workroom solo *without* dissolving the split —
  /// it reappears when a member is reselected (`visibleWorkroomLayout`). The split dissolves only by
  /// removing members below two.
  private func selectWorkroomTab(_ sid: SidebarID) {
    store.selectedTargetID = sid
    store.selectedProjectID = AppStore.projectPath(of: sid)
  }

  @ViewBuilder
  private var detailContent: some View {
    if store.isCreationFocused, let creation = store.creation {
      // The creating slot owns the detail (issue #116): a loader through the pre-name phase (and all
      // the way to the terminal for a no-setup workroom), swapped for the streaming setup dialog once
      // a setup script starts. Scoped to this focused slot — selecting another workroom shows it.
      creationDetail(creation)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let target = store.selectedTarget {
      if target.isMissing {
        ContentUnavailableView(
          "Directory not found",
          systemImage: "questionmark.folder",
          description: Text(
            "\(target.title) points at a path that no longer exists.\n\(target.path)")
        )
      } else {
        // The focused target's terminal body — ALWAYS rendered through `WorkroomSplitView` (a no-split
        // case is just `.leaf(selected)`), so single↔split is a leaf-set change, never a structural swap
        // that would re-parent the surface and blank a pane (issue #23, the same lesson as
        // `WorkroomTerminalsView` always rendering through `PaneTreeView`). Title/toolbar follow the
        // focused member (`selectedTarget`).
        // The run/stop/restart + "Open in…" controls now live in the title-bar toolbar
        // (`TrailingTitlebarBar`, driven by `store.selectedTarget`), not a detail `.toolbar`. The
        // window title/subtitle are dropped too — the workroom tabs already name the current workroom.
        workroomSplitBody(focused: target)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      ContentUnavailableView(
        "Nothing selected",
        systemImage: "terminal",
        description: Text(
          "Select a project's root or a workroom to open a terminal in its directory, or create one."
        )
      )
    }
  }

  /// The creating slot's detail (issue #116): a centered loader until a setup script's dialog is ready,
  /// then the streaming setup dialog. A workroom with no setup script never reaches the dialog — the
  /// loader shows until the create completes (which clears `store.creation`) and the terminal mounts.
  @ViewBuilder
  private func creationDetail(_ creation: WorkroomCreation) -> some View {
    if creation.targetID != nil, creation.hasSetup {
      SetupOverlay(session: creation.session) { store.dismissCreation() }
    } else {
      CreationLoader()
    }
  }

  /// The workroom body: always `WorkroomSplitView`, with the layout being the split when the selected
  /// workroom is a member, else `.leaf(selected)` — the split is shown only when a member is focused but
  /// persists otherwise (`visibleWorkroomLayout`, mirroring the terminal split). One render path → no
  /// reparent on single↔split. Falls back to the bare terminal body if somehow there's no selection id.
  @ViewBuilder
  private func workroomSplitBody(focused: TerminalTarget) -> some View {
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
        onMove: { store.insertWorkroomSplit($0, beside: $1, edge: $2) }
      )
    } else {
      targetTerminalBody(focused)
    }
  }

  /// One target's terminal body. While this workroom is being created with a setup script
  /// (`isCreationBlocking`), the terminal is withheld — `WorkroomTerminalsView` mounts (and `.task`
  /// creates the first terminal) only once the setup dialog is dismissed. The dialog itself is drawn
  /// window-level over the whole detail (see `detail`), not here, so this is just the terminal.
  @ViewBuilder
  private func targetTerminalBody(_ target: TerminalTarget) -> some View {
    if !store.isCreationBlocking(target.id) {
      WorkroomTerminalsView(target: target, sessions: store.terminals)
    }
  }
}

/// Publishes the per-window menu-command enablement values as `focusedSceneValue`s in one place. A
/// `Commands` body doesn't re-evaluate when the shared store mutates, but it does track focused
/// values — so RootView recomputes these (it observes the store/sessions) and the menu reads them via
/// `@FocusedValue` (see `WorkroomCommands`). Collapsed into a `ViewModifier` so RootView's body stays a
/// single, fast-to-type-check expression (a dozen inline `.focusedSceneValue` calls blow the
/// type-checker's budget).
private struct MenuStateValues: ViewModifier {
  let workroomSelected: Bool
  let hasNotifications: Bool
  let hasProjects: Bool
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let hasRunCommand: Bool
  let runCommandActive: Bool
  let hasRunTerminal: Bool
  let multipleWorkroomTabs: Bool
  let canOpenInEditor: Bool
  let workroomSplitVisible: Bool

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.workroomSelected, workroomSelected)
      .focusedSceneValue(\.hasNotifications, hasNotifications)
      .focusedSceneValue(\.hasProjects, hasProjects)
      .focusedSceneValue(\.canNavigateBack, canNavigateBack)
      .focusedSceneValue(\.canNavigateForward, canNavigateForward)
      .focusedSceneValue(\.hasRunCommand, hasRunCommand)
      .focusedSceneValue(\.runCommandActive, runCommandActive)
      .focusedSceneValue(\.hasRunTerminal, hasRunTerminal)
      .focusedSceneValue(\.multipleWorkroomTabs, multipleWorkroomTabs)
      .focusedSceneValue(\.canOpenInEditor, canOpenInEditor)
      .focusedSceneValue(\.workroomSplitVisible, workroomSplitVisible)
  }
}

/// Remove the window bar's *visible* title while keeping `window.title` (from `.navigationTitle`) for
/// the Window menu / Mission Control. Unlike a non-empty `.navigationTitle` — which re-asserts
/// `titleVisibility = .visible` on every window update and lets AppKit fade the name across the bar —
/// `.toolbar(removing: .title)` removes the visible title declaratively, so there is nothing to flash.
/// (`.title` is macOS 15+, which is the app's minimum deployment target.)
private struct RemoveWindowTitleBarTitle: ViewModifier {
  func body(content: Content) -> some View {
    content.toolbar(removing: .title)
  }
}
