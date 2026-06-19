import AppKit
import Defaults
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  // Observed so the detail's workroom tab bar re-renders as terminals open/close (a tab appears when a
  // workroom gains its first terminal and disappears when it loses its last) — issue #23.
  @EnvironmentObject var terminals: TerminalSessions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Default(.theme) private var theme
  /// Whether the right-hand notifications inspector is open. `@Default` (not `@State`) so the
  /// View-menu command (WorkroomCommands) toggles the same value.
  @Default(.showNotifications) private var showNotifications

  /// Drives the add-project importer — set from `store.requestAddProject`, which both ⌘O and the
  /// sidebar's Add-Project buttons raise. Hosted here (vs the sidebar) so the ⌘O command presents it
  /// even if the sidebar is collapsed via the standard toggle.
  @State private var showImporter = false

  /// Presents the theme picker (issue #36), raised by the `Theme…` (⌘⇧K) command via notification.
  @State private var showThemePicker = false

  /// Presents the keyboard-shortcuts reference, raised by the `Keyboard Shortcuts…` command via
  /// notification (same menu-can't-anchor-a-sheet pattern as the theme picker).
  @State private var showKeyboardShortcuts = false

  /// Live preview of a workroom tab being dragged into the detail content to form a split (issue #23
  /// follow-up). Set by `WorkroomTabBar`'s drag, read by `WorkroomSplitView` to highlight the drop edge.
  @State private var workroomChipDrag: WorkroomPaneDrag?
  /// The detail content area's global frame, so a chip drag can be resolved against the workroom panes.
  @State private var detailContentFrame: CGRect = .zero

  /// True when the selected target can host a terminal right now: it exists, isn't missing,
  /// and isn't currently blocked by a running setup script.
  private var terminalInteractionAvailable: Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    if store.logs[target.id]?.blocking == true { return false }
    return true
  }

  /// The leading title-bar controls (sidebar toggle + history nav + quick terminal) hosted as an
  /// `NSTitlebarAccessoryViewController`, pinned just after the traffic lights. Env objects are
  /// injected inside the closure because the hosted tree lives outside the WindowGroup's environment.
  private var leadingTitlebar: some View {
    TitlebarAccessory(edge: .leading, identifier: .init("workroom.titlebarLeading")) {
      LeadingTitlebarBar()
        .environmentObject(store)
    }
  }

  /// The trailing title-bar controls (run/open-in + notifications bell + inspector toggle) hosted as
  /// an `NSTitlebarAccessoryViewController`, pinned to the window's true trailing edge.
  private var trailingTitlebar: some View {
    TitlebarAccessory(edge: .trailing, identifier: .init("workroom.titlebarTrailing")) {
      TrailingTitlebarBar()
        .environmentObject(store)
        .environmentObject(notifications)
    }
  }

  var body: some View {
    NavigationSplitView(
      columnVisibility: Binding(
        // Own the column visibility so the View ▸ Projects menu item can show a tick (the bar's
        // toggle, the auto-provided toolbar button, and a drag-collapse all round-trip through
        // `store.sidebarVisible`). `.detailOnly` is the only hidden state for a two-column split.
        get: { store.sidebarVisible ? .all : .detailOnly },
        set: { store.sidebarVisible = $0 != .detailOnly })
    ) {
      ProjectSidebar()
        // The sidebar column's title (for accessibility / the column header). Set here, not inside
        // `ProjectSidebar`, so the reveal overlay — which reuses `ProjectSidebar` — doesn't leak
        // "Projects" into the window titlebar when unpinned.
        .navigationTitle("Projects")
        // Capture the card's inner content width (before the card's own padding) so the edge-reveal
        // panel — which re-applies the same `sidebarCard` — matches the docked card exactly (issue #56).
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: SidebarWidthKey.self, value: geo.size.width)
          }
        )
        .onPreferenceChange(SidebarWidthKey.self) { width in
          if width > 0 { store.dockedSidebarWidth = width }
        }
        // No custom card here: macOS already renders the docked sidebar column as an inset floating
        // card. The edge-reveal panel (an overlay, which gets no native card) re-creates that look via
        // `sidebarCard` so the unpinned state matches.
        // Bound the sidebar column: a floor so a wide inspector can't crush it (clipping labels) and
        // a ceiling so it can't be dragged so wide it eats the main panel. Expressed as a
        // NavigationSplitView column constraint, which the split view honours as the real column
        // range (a plain `.frame(minWidth:)` is not treated as the column floor).
        .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        // Persist the user-dragged sidebar width across launches (issue #14) via the
        // underlying NSSplitView's autosave — SwiftUI offers no width binding.
        .background(SplitViewAutosave(name: "WorkroomSidebarSplit"))
    } detail: {
      // The inspector is a custom card laid out beside the detail (it pushes the detail narrower, like
      // the sidebar) rather than the native `.inspector` — which drew a separator line beside our card.
      // `InspectorColumn` reuses the same `sidebarCard` as the reveal, so pinned == unpinned.
      HStack(spacing: 0) {
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if showNotifications {
          InspectorColumn()
            .transition(.move(edge: .trailing))
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showNotifications)
    }
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
        showImporter = true
        store.requestAddProject = false
      }
    }
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        Task { await store.addProject(url) }
      }
    }
    .confirmationDialog(
      store.pendingDeletion.map { "Delete '\($0.workroom.name)'?" } ?? "Delete workroom?",
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
    // Project deletion uses a type-to-confirm sheet (not a one-tap dialog): it's a bigger,
    // optionally-cascading action, so it demands typing the project name. `.sheet(item:)`
    // rebuilds per pending identity, resetting the sheet's typed/toggle state.
    .sheet(item: $store.pendingProjectDeletion) { pending in
      DeleteProjectSheet(
        project: pending.project,
        onDelete: { withWorkrooms in
          store.pendingProjectDeletion = nil
          store.deleteProject(pending.project, deleteWorkrooms: withWorkrooms)
        },
        onCancel: { store.pendingProjectDeletion = nil })
    }
    // Edge-hover reveal of a collapsed sidebar (issue #56): each layer is active only while its
    // sidebar is closed, slides the same content in OVER the detail, and is inert otherwise. Applied
    // before the toast overlay so toasts keep z-order above a revealed panel. Packaged as a modifier
    // so this large `body` stays within the type-checker's budget.
    .modifier(
      EdgeRevealSidebars(
        sidebarVisible: store.sidebarVisible, inspectorVisible: showNotifications)
    )
    // Foreground toasts (issue #31): pinned bottom-right of the window, over the split + inspector.
    // Only ever populated while the inspector is closed, so it never overlaps the open inspector.
    .overlay(alignment: .bottomTrailing) { ToastStack() }
    .onAppear {
      // Wire the chokepoint's terminal step once: ThemeService owns theme application, the surface
      // iteration stays in TerminalSessions (issue #36).
      ThemeService.shared.onApplyTerminals = { [weak terminals = store.terminals] force in
        terminals?.applyThemeToAll(force: force)
      }
      applyAppearance()
    }
    .onChange(of: theme) { _ in applyAppearance() }
    .onReceive(NotificationCenter.default.publisher(for: .showThemePicker)) { _ in
      showThemePicker = true
    }
    .sheet(isPresented: $showThemePicker) {
      ThemePicker(presentedAsSheet: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
      showKeyboardShortcuts = true
    }
    .sheet(isPresented: $showKeyboardShortcuts) {
      KeyboardShortcutsView()
    }
    // No window title text — all the chrome lives in the title-bar accessories + the workroom tabs.
    .navigationTitle("")
    // Drop NavigationSplitView's auto sidebar toggle — `LeadingTitlebarBar` carries its own, leftmost
    // after the traffic lights. The now-itemless window toolbar is hidden in WindowBackgroundThemer
    // (its overflow chevron would otherwise linger); the traffic lights + accessories aren't part of
    // the toolbar, so they stay.
    .toolbar(removing: .sidebarToggle)
    .background(WindowBackgroundThemer())
    // The single unified title-bar toolbar: leading + trailing accessories sharing the native
    // title-bar row with the traffic lights (see `TitlebarBars`). Both hosted outside the
    // WindowGroup's environment, so each injects its env objects inside the closure.
    .background(leadingTitlebar)
    .background(trailingTitlebar)
    // Keep the root branch labels reasonably current: refresh when the app regains
    // focus (throttled, so rapid alt-tabbing doesn't fork a git/jj process per project).
    // Regaining focus also dismisses the now-visible terminal's notifications (you're looking at it).
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      store.dismissFocusedTerminalNotifications()
      Task { await store.reloadIfStale() }
    }
    // Publish selection state for menu-command enablement (see WorkroomCommands). While a
    // setup script blocks the selected workroom's terminal, report false so ⌘T can't open
    // a (hidden) terminal behind the setup pane; the toolbar's Open/Reveal still work.
    .focusedSceneValue(\.workroomSelected, terminalInteractionAvailable)
    // Drive the "Next Notification" menu command's enabled state.
    .focusedSceneValue(\.hasNotifications, !notifications.items.isEmpty)
    // Drive the Go-menu Back/Forward commands' enabled state (issue #26).
    .focusedSceneValue(\.canNavigateBack, store.canGoBack)
    .focusedSceneValue(\.canNavigateForward, store.canGoForward)
    // Drive the Run/Stop/Restart menu items (issue #7). Run-state lives on the store (OV-A), so
    // these stay live as the command starts/stops/exits.
    .focusedSceneValue(\.hasRunCommand, selectedHasRunCommand)
    .focusedSceneValue(\.runCommandActive, selectedRunCommandActive)
    .focusedSceneValue(\.hasRunTerminal, store.hasAnyRunTerminal)
    // Drive the Go-menu Previous/Next Workroom Tab items (issue #29) — only meaningful with ≥2 tabs.
    // RootView observes `terminals`, so this stays live as workrooms gain/lose their tabs.
    .focusedSceneValue(\.multipleWorkroomTabs, store.orderedWorkroomTargets().count > 1)
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
    // The workroom tab bar rides above the terminal whenever ≥1 workroom/root has a terminal (issue
    // #23). Tapping a tab selects that target, exactly like clicking it in the sidebar. It hides
    // entirely when nothing's open. Split members are pulled into a contiguous run so the bar can
    // bracket them (`displayedWorkroomTargets`, mirroring the terminal strip's `displayedTabIDs`).
    let tabs = store.displayedWorkroomTargets()
    VStack(spacing: 0) {
      if !tabs.isEmpty {
        WorkroomTabBar(
          tabs: tabs, selectedID: store.selectedTargetID, onSelect: { selectWorkroomTab($0) },
          chipPaneDrag: $workroomChipDrag,
          localize: { workroomChipLocal($0) },
          dropTarget: { workroomChipDropTarget(at: $0) })
        // A themed hairline directly beneath the tabs, separating the bar from the terminal below
        // (issue #36 — sources from the active theme rather than the system separator).
        ThemeService.shared.tokens.border.frame(height: 1)
      }
      detailContent
        // Always fill the remaining height so the tab bar above stays pinned to the top. The
        // terminal branch fills on its own, but the empty states (Nothing selected / Directory not
        // found) size to their content — without this the VStack would shrink to fit and center,
        // dropping the tab bar to the vertical middle when a workroom has terminals but nothing is
        // selected (issue #23 follow-up).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The detail content's global frame, so a chip dragged from the bar can be resolved against the
        // workroom panes below it (issue #23 follow-up) — mirrors WorkroomTerminalsView ↔ TerminalTabStrip.
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: DetailContentFrameKey.self, value: geo.frame(in: .global))
          }
        )
    }
    .onPreferenceChange(DetailContentFrameKey.self) { detailContentFrame = $0 }
    // The detail column (tab bar + region around the panes) uses the theme *panel* colour — a
    // subtle step off the terminal background (issue #36) — so the chrome reads as a distinct
    // surface framing the terminals rather than one flat colour.
    .background(ThemeService.shared.tokens.panel)
  }

  /// The content-local point for a chip drag at `global`, or nil when the cursor is still over the bar
  /// (→ a reorder, not a drop-into-content).
  private func workroomChipLocal(_ global: CGPoint) -> CGPoint? {
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
    if let target = store.selectedTarget {
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

  /// The workroom body: always `WorkroomSplitView`, with the layout being the split when the selected
  /// workroom is a member, else `.leaf(selected)` — the split is shown only when a member is focused but
  /// persists otherwise (`visibleWorkroomLayout`, mirroring the terminal split). One render path → no
  /// reparent on single↔split. Falls back to the bare terminal body if somehow there's no selection id.
  @ViewBuilder
  private func workroomSplitBody(focused: TerminalTarget) -> some View {
    if let selected = store.selectedTargetID {
      WorkroomSplitView(
        layout: store.visibleWorkroomLayout(for: selected),
        resolve: { store.target(for: $0) },
        focusedID: selected,
        externalDrag: workroomChipDrag,
        onFocus: { selectWorkroomTab($0) },
        onSetRatio: { store.setWorkroomSplitRatio($0, forSplit: $1) },
        onClose: { store.removeWorkroomSplitMember($0) }
      )
    } else {
      targetTerminalBody(focused)
    }
  }

  /// One target's terminal ZStack with its setup log (if any). While a setup script runs
  /// (`log.blocking`), the log floats over the pane and the terminal is withheld — `WorkroomTerminalsView`
  /// mounts (and `.task` creates the first terminal) only once the blocking log is dismissed. Only
  /// workrooms ever have a log; for a root, `logs[target.id]` is nil. Title/toolbar are owned by the
  /// caller (shared with the split path), so this is just the body.
  @ViewBuilder
  private func targetTerminalBody(_ target: TerminalTarget) -> some View {
    let isBlocking = store.logs[target.id]?.blocking == true
    ZStack {
      if !isBlocking {
        VStack(spacing: 0) {
          WorkroomTerminalsView(target: target, sessions: store.terminals)

          if let log = store.logs[target.id] {
            ThemeService.shared.tokens.border.frame(height: 1)
            ScriptLogPanel(session: log) { store.logs[target.id] = nil }
          }
        }
      }

      if let log = store.logs[target.id], log.blocking {
        SetupOverlay(session: log) {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            store.logs[target.id] = nil
          }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        .zIndex(1)
      }
    }
  }
}

/// The detail content area's global frame, published so `WorkroomTabBar`'s chip drag can localise a
/// cursor point against the workroom panes below the bar (issue #23 follow-up). Mirrors
/// `ContentFrameKey` in `WorkroomTerminalsView`, one level up.
private struct DetailContentFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

/// The docked Projects sidebar's measured width, published so the edge-hover reveal panel matches it
/// (issue #56). Mirrors `DetailContentFrameKey`: a non-zero reading wins.
private struct SidebarWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    let next = nextValue()
    if next != 0 { value = next }
  }
}
